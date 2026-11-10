module Ledger
  LOCK = Mutex.new

  ACCOUNT_RE = /\A[A-Z][A-Za-z0-9-]*(:[A-Z0-9][A-Za-z0-9-]*)+\z/
  AMOUNT_RE = /\A-?(\d+(\.\d+)?|\.\d+)\z/
  CURRENCY_RE = /\A[A-Z][A-Z0-9'._-]{0,22}\z/
  TAG_RE = %r{\A[A-Za-z0-9_/.-]+\z}
  DATE_RE = /\A(\d{4})-(\d{1,2})-(\d{1,2})\z/
  ACCOUNT_TYPES = %w[Assets Liabilities Equity Income Expenses].freeze
  BALANCE_SHEET = ["Assets:", "Liabilities:"].freeze

  # Serializes writes and dry runs (LOCK in server.py).
  def locked(&block)
    LOCK.synchronize(&block)
  end

  def rledger(*args)
    out, err, status = Open3.capture3("rledger", *args)
    [status.exitstatus || -1, (out + err).force_encoding(Encoding::UTF_8).strip]
  end

  def query(ledger, bql)
    code, out = rledger("query", "-f", "json", ledger.to_s, bql)
    raise out unless code == 0
    JSON.parse(out)["rows"]
  end

  def check(ledger)
    rledger("check", "-C", ledger.to_s)
  end

  # Python truthiness, so `x or y` and bool(x) behave as they did in server.py.
  def py_falsy?(value)
    value.nil? || value == false || value == 0 || (value.respond_to?(:empty?) && value.empty?)
  end

  def py_or(value, default)
    py_falsy?(value) ? default : value
  end

  def clean_str(value, label)
    raise InputError, "#{label} must be text" if !value.nil? && !value.is_a?(String)
    value = (value || "").strip
    raise InputError, "#{label} cannot contain line breaks" if value.include?("\r") || value.include?("\n")
    value
  end

  def quote(value)
    '"' + value.gsub("\\") { "\\\\" }.gsub('"') { "\\\"" } + '"'
  end

  # YYYY-MM-DD (month and day may have one digit, as Python's strptime allows); returns the ISO date.
  def parse_date(value)
    m = DATE_RE.match(value.to_s)
    raise InputError, "Date must be YYYY-MM-DD" if m.nil? || m[1].to_i.zero?
    Date.new(m[1].to_i, m[2].to_i, m[3].to_i).iso8601
  rescue Date::Error
    raise InputError, "Date must be YYYY-MM-DD"
  end

  def to_int(value)
    return value if value.is_a?(Integer)
    return value.to_i if value.is_a?(Float)
    Integer(value.to_s.strip, 10)
  rescue ArgumentError, TypeError
    raise InputError, "Line number must be a whole number"
  end

  # ---- decimals: Python's Decimal keeps decimal places ("12.50" stays "12.50"); BigDecimal does not.
  # Arithmetic is done with BigDecimal and results are printed with the places Decimal would use.
  def dec(text)
    BigDecimal(text.to_s.sub(/\A(-?)\./) { "#{$1}0." })
  end

  def dec_places(text)
    frac = text.to_s.split(".", 2)[1]
    frac ? frac.length : 0
  end

  def dec_text(value, places)
    sign = value.negative? ? "-" : ""
    whole, frac = value.abs.to_s("F").split(".", 2)
    frac = (frac || "").ljust(places, "0")[0, places]
    places.zero? ? "#{sign}#{whole}" : "#{sign}#{whole}.#{frac}"
  end

  # Sum of decimal strings, printed like Python's sum(..., Decimal(0)).
  def dec_sum(texts)
    texts = texts.to_a
    total = texts.sum(BigDecimal("0")) { |t| dec(t) }
    dec_text(total, texts.map { |t| dec_places(t) }.max || 0)
  end

  # ---- files
  # Like Python's read_text(): UTF-8, and \r\n or \r become \n.
  def read_text(path)
    File.read(path, encoding: "UTF-8", universal_newline: true)
  end

  def file_hash(ledger)
    Digest::SHA256.file(ledger).hexdigest
  end

  def require_hash(ledger, data)
    return if data["hash"] == file_hash(ledger)
    raise Conflict, "The ledger changed on disk since this page loaded. Reload the list and try again."
  end

  # Like Path(fn).resolve(); nil for entries that have no file.
  def resolve(filename)
    return nil if filename.nil? || filename.to_s.empty?
    path = File.expand_path(filename.to_s)
    File.exist?(path) ? File.realpath(path) : path
  end

  def join_append(existing, entry)
    sep = existing.empty? ? "" : (existing.end_with?("\n") ? "\n" : "\n\n")
    existing + sep + entry
  end

  def append_text(path, entry)
    join_append(File.exist?(path) ? read_text(path) : "", entry)
  end

  # Check what the ledger would be with this text, without touching the real file.
  def check_text(ledger, text)
    Dir.mktmpdir do |tmp|
      probe = File.join(tmp, File.basename(ledger))
      File.write(probe, text)
      check(probe)
    end
  end
end
