module Ledger
  # The single write path (commit() in server.py). Every change to the ledger file goes through here:
  # the ledger must pass `rledger check` first, a backup is made in .backups/ next to it, the new text
  # is written, `rledger check` runs again, and the backup is put back if the new text is rejected.
  # Callers check the page's sha256 (require_hash) before building new_text, as in server.py.
  class Commit
    def self.call(ledger, new_text)
      new(ledger).call(new_text)
    end

    def initialize(ledger)
      @ledger = ledger
    end

    # Returns the backup's file name.
    def call(new_text)
      code, out = Ledger.check(@ledger)
      raise InputError, "The ledger already has errors; fix them first:\n" + out unless code == 0
      backups = File.join(File.dirname(@ledger), ".backups")
      FileUtils.mkdir_p(backups)
      backup = File.join(backups, "#{File.basename(@ledger)}.#{Time.now.strftime('%Y%m%d-%H%M%S-%6N')}")
      FileUtils.cp(@ledger, backup, preserve: true)
      begin
        File.write(@ledger, new_text)
      rescue StandardError
        FileUtils.cp(backup, @ledger, preserve: true)  # a failed or partial write must not leave a broken ledger
        raise
      end
      code, out = Ledger.check(@ledger)
      unless code == 0
        FileUtils.cp(backup, @ledger, preserve: true)
        raise InputError, "Rejected by rledger check (file restored):\n" + out
      end
      File.basename(backup)
    end
  end

  def commit(ledger, new_text)
    Commit.call(ledger, new_text)
  end
end
