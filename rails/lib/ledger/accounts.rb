module Ledger
  # ---- deleting and closing accounts ----
  # Beancount has no "delete account": deleting means removing the `open` line. That is only safe when
  # nothing else names the account. `rledger check` misses names in `custom` lines and metadata, so we
  # scan the text of every loaded file ourselves as well.
  INCLUDE_RE = /^(\s*include\s+)"([^"]+)"/
  OPEN_HEAD_RE = /\A\d{4}-\d\d-\d\d(\s+open\s+)/
  USE_RE = /\A(\d{4}-\d\d-\d\d)\s+(balance|pad|note|document|close|custom)\s(.*)\z/

  def parse_account_name(value)
    account = clean_str(value, "Account")
    unless ACCOUNT_RE.match?(account) && ACCOUNT_TYPES.include?(account.split(":")[0])
      raise InputError, "Account must look like Assets:Bank:Checking (type first)"
    end
    account
  end

  # Matches the exact account name, not a longer one (Assets:Bank never matches Assets:Bank:Checking).
  def name_re(account)
    /(?<![A-Za-z0-9:-])#{Regexp.escape(account)}(?![A-Za-z0-9:-])/
  end

  def open_re(account)
    /\A\d{4}-\d\d-\d\d\s+open\s+#{Regexp.escape(account)}(?=\s|\z)/
  end

  # The main file first, then every included file that has entries.
  def loaded_files(ledger)
    files = [ledger]
    query(ledger, "SELECT filename FROM #entries").each do |(fn)|
      next if fn.nil? || fn.to_s.empty?  # entries rledger generates itself (e.g. the transaction for a `pad`) have no file
      p = resolve(fn)
      next if File.directory?(p)  # never a ledger file; a missing or unreadable real file still reaches read_loaded
      files << p unless files.include?(p)
    end
    files
  end

  def ref_kind(line)
    m = /\A\d{4}-\d\d-\d\d\s+(\S+)/.match(line)
    return { "*" => "transaction", "!" => "transaction", "txn" => "transaction" }.fetch(m[1], m[1]) if m
    return "metadata" if META_RE.match?(line)
    return "posting" if " \t".include?(line[0, 1])
    "other"
  end

  # Text of a loaded ledger file; a plain error instead of a crash when it can't be read.
  def read_loaded(path)
    read_text(path)
  rescue SystemCallError, IOError => e
    reason = e.message.sub(/ @ .*/m, "")
    raise InputError, "Could not read #{File.basename(path)} (#{reason}). Check that the file exists and can be opened, then try again."
  end

  # Every line in every loaded file that names the account, except full-line comments and `skip`
  # (0-based line numbers in the main file: the open line and its metadata).
  def find_account_refs(ledger, account, skip = [])
    pat = name_re(account)
    refs = []
    loaded_files(ledger).each do |path|
      read_loaded(path).split("\n", -1).each_with_index do |line, i|
        next if path == ledger && skip.include?(i)
        next if line.lstrip.start_with?(";") || !pat.match?(line)
        refs << { "file" => File.basename(path), "line" => i + 1, "kind" => ref_kind(line),
                  "text" => line.strip[0, 160], "raw" => line }  # "text" is for display; "raw" is the whole line
      end
    end
    refs
  end

  def account_info(ledger, account)
    rows = {}
    query(ledger, "SELECT account, open, close FROM #accounts").each { |a, o, c| rows[a] = [o, c] }
    raise InputError, "#{account} is not an open or closed account in this ledger" unless rows.key?(account)
    q = "SELECT count(*), max(date) FROM #postings WHERE account = '#{account}'"  # name passed ACCOUNT_RE
    count, last = query(ledger, q).fetch(0)
    bal = []
    query(ledger, "SELECT account, sum(position) WHERE account = '#{account}' GROUP BY account").each do |_a, pos|
      bal = ((pos || {})["positions"] || []).map { |p| { "amount" => p["number"], "currency" => p["currency"] } }
    end
    { "open" => rows[account][0], "closed" => rows[account][1], "postings" => count || 0, "last" => last,
      "balance" => bal, "zero" => bal.all? { |b| dec(b["amount"]).zero? },
      "children" => rows.keys.select { |a| a.start_with?(account + ":") }.sort }
  end

  # 0-based [start, end) of the account's `open` line plus the comments/metadata indented under it,
  # in the main file. `verb` finishes the message for accounts opened in an included file.
  def find_open_block(ledger, lines, account, verb)
    rx = open_re(account)
    found = lines.each_index.select { |i| rx.match?(lines[i]) }
    if found.empty?
      loaded_files(ledger).drop(1).each do |p|
        if read_loaded(p).split("\n", -1).any? { |l| rx.match?(l) }
          raise InputError, "#{account} is opened in the included file #{File.basename(p)}; #{verb} it there in your editor"
        end
      end
      raise InputError, "Could not find the open line for #{account} in #{File.basename(ledger)}"
    end
    raise InputError, "#{account} is opened more than once in #{File.basename(ledger)}; fix that in your editor" if found.length > 1
    start = found[0]
    stop = start + 1
    stop += 1 while stop < lines.length && !lines[stop].strip.empty? && " \t".include?(lines[stop][0])
    [start, stop]
  end

  def ref_summary(refs)
    kinds = Hash.new(0)
    refs.each { |r| kinds[r["kind"]] += 1 }
    kinds.sort.map { |k, n| "#{n} #{k}#{n != 1 && k != 'metadata' ? 's' : ''}" }.join(", ")
  end

  def ref_lines(refs)
    out = "\n" + refs.first(5).map { |r| "  #{r['file']}:#{r['line']}  #{r['text']}" }.join("\n")
    out += "\n  ...and #{refs.length - 5} more" if refs.length > 5
    out
  end

  # Work out what deleting an account would do: the new text plus the reasons it is blocked, if any.
  def build_account_delete(ledger, data)
    account = parse_account_name(data["account"])
    info = account_info(ledger, account)
    lines = read_text(ledger).split("\n", -1)
    start, stop = find_open_block(ledger, lines, account, "remove")
    removed = lines[start...stop].join("\n")
    refs = find_account_refs(ledger, account, (start...stop).to_a)
    reasons = []
    reasons << "it was closed on #{info['closed']} (closed accounts keep their history)" if info["closed"]
    if !refs.empty?
      reasons << "it is mentioned on #{refs.length} other line#{refs.length != 1 ? 's' : ''} (#{ref_summary(refs)})"
    elsif info["postings"].to_i.positive?
      reasons << "it has #{info['postings']} posting(s)"
    end
    lines.slice!(start...stop)
    if start < lines.length && lines[start].strip.empty? && (start.zero? || lines[start - 1].strip.empty?)
      lines.delete_at(start)  # don't leave a double blank line behind
    end
    { "account" => account, "text" => lines.join("\n"), "removed" => removed, "refs" => refs,
      "reasons" => reasons, "info" => info }
  end

  def blocked_message(d)
    msg = "#{d['account']} can't be deleted: " + d["reasons"].join("; ") + "."
    msg += ref_lines(d["refs"]) unless d["refs"].empty?
    msg
  end

  # Like check_text, but rewrites relative `include` paths so included files still load from the temp copy.
  def check_text_includes(ledger, text)
    fixed = text.gsub(INCLUDE_RE) do
      head, inc = $1, $2
      path = inc.start_with?("/") ? inc : File.join(File.dirname(ledger), inc)
      "#{head}\"#{path}\""
    end
    check_text(ledger, fixed)
  end

  def account_delete_validate(ledger, data)
    d = build_account_delete(ledger, data)
    info = d["info"]
    warning = info["children"].empty? ? "" : "#{info['children'].length} sub-account(s) will remain, e.g. #{info['children'][0]}"
    out = { "account" => d["account"], "hash" => file_hash(ledger), "removes" => d["removed"], "refs" => d["refs"].first(20),
            "ref_count" => d["refs"].length, "closed" => info["closed"], "balance" => info["balance"],
            "last_activity" => info["last"], "opened" => info["open"],
            "can_close" => !info["closed"] && info["zero"], "warning" => warning }
    return out.merge("ok" => false, "blocked" => true, "message" => blocked_message(d)) unless d["reasons"].empty?
    code, msg = check_text_includes(ledger, d["text"])
    out.merge("ok" => code == 0, "blocked" => false, "message" => msg)
  end

  def account_delete(ledger, data)
    require_hash(ledger, data)
    d = build_account_delete(ledger, data)
    raise InputError, blocked_message(d) unless d["reasons"].empty?
    backup = commit(ledger, d["text"])
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger), "removed" => d["removed"] }
  end

  def account_close(ledger, data)
    require_hash(ledger, data)
    account = parse_account_name(data["account"])
    day = parse_date(data["date"])
    info = account_info(ledger, account)
    raise InputError, "#{account} is already closed (on #{info['closed']})" if info["closed"]
    unless info["zero"]
      bal = info["balance"].map { |b| "#{b['amount']} #{b['currency']}" }.join(", ")
      raise InputError, "#{account} still has a balance of #{bal}. Move it to zero before closing."
    end
    raise InputError, "The close date can't be before the account was opened (#{info['open']})" if day < info["open"]
    if info["last"] && day < info["last"]
      raise InputError, "The close date can't be before the last transaction on #{info['last']}"
    end
    entry = "#{day} close #{account}\n"
    backup = commit(ledger, append_text(ledger, entry))
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger), "text" => entry }
  end

  # ---- editing an account: its open date and name ----
  # Only the `open` line changes; its currencies, comment and indented metadata stay as they are.
  # A new name is allowed only when nothing else mentions the account, so no other line needs rewriting.

  # The date of a directive that takes the account as an argument, else nil. Quoted text and
  # trailing comments are ignored, so a note or narration that only mentions the name doesn't count.
  def use_date(line, account)
    m = USE_RE.match(line.strip)
    return nil unless m
    args = m[3].gsub(STR_RE, " ").split(";", 2)[0] || ""
    name_re(account).match?(args) ? m[1] : nil
  end

  def build_account_edit(ledger, data)
    account = parse_account_name(data["account"])
    new_account = parse_account_name(data["new_account"])
    day = parse_date(data["date"])
    info = account_info(ledger, account)
    if info["closed"]
      raise InputError, "#{account} was closed on #{info['closed']}. Closed accounts keep their history and can't be edited here."
    end
    lines = read_text(ledger).split("\n", -1)
    start, stop = find_open_block(ledger, lines, account, "change")
    renamed = new_account != account
    raise InputError, "Nothing to change: the date and the name are the same as now." if day == info["open"] && !renamed
    refs = find_account_refs(ledger, account, (start...stop).to_a)
    if renamed
      existing = query(ledger, "SELECT account FROM #accounts").map(&:first)
      raise InputError, "There is already an account called #{new_account}. Pick a different name." if existing.include?(new_account)
      unless refs.empty?
        msg = "#{account} can't be renamed because it is used on #{refs.length} other line#{refs.length != 1 ? 's' : ''} " \
              "in your ledger (#{ref_summary(refs)}). Renaming here only works for an account nothing uses yet, so that no " \
              "other lines have to be rewritten. You can still change its open date."
        raise InputError, msg + ref_lines(refs)
      end
      taken = find_account_refs(ledger, new_account)
      unless taken.empty?
        r = taken[0]
        more = taken.length > 1 ? " (and #{taken.length - 1} more line#{taken.length != 2 ? 's' : ''})" : ""
        raise InputError, "The name #{new_account} is already mentioned in #{r['file']}:#{r['line']}#{more}:\n  #{r['text']}\n" \
                          "Renaming to it would make that text point at this account. " \
                          "Pick a different name, or remove that mention first."
      end
    end
    used = query(ledger, "SELECT date FROM #postings WHERE account = '#{account}'").map(&:first)  # name passed ACCOUNT_RE
    used += refs.map { |r| use_date(r["raw"], account) }.compact
    first = used.min
    if first && day > first
      raise InputError, "The open date can't be after #{first}, the first day #{account} is used. Pick #{first} or earlier."
    end
    old = lines[start]
    head = OPEN_HEAD_RE.match(old)
    rest = old[open_re(account).match(old).end(0)..]
    lines[start] = "#{day}#{head[1]}#{new_account}#{rest}"
    children = renamed ? info["children"] : []
    { "account" => account, "new_account" => new_account, "text" => lines.join("\n"),
      "old" => old, "new" => lines[start], "children" => children }
  end

  def account_edit_validate(ledger, data)
    d = build_account_edit(ledger, data)
    code, msg = check_text_includes(ledger, d["text"])
    warning = d["children"].empty? ? "" : "#{d['children'].length} sub-account(s) keep their old name, e.g. #{d['children'][0]}"
    { "ok" => code == 0, "message" => msg, "hash" => file_hash(ledger), "old" => d["old"], "text" => d["new"], "warning" => warning }
  end

  def account_edit(ledger, data)
    require_hash(ledger, data)
    d = build_account_edit(ledger, data)
    backup = commit(ledger, d["text"])
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger), "old" => d["old"], "text" => d["new"] }
  end
end
