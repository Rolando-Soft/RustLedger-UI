module Ledger
  POSTING_RE = /\A(\s+)(?:([*!?])\s+)?([A-Z]\S*)(.*)\z/
  HEADER_RE = /\A(\d{4}-\d\d-\d\d\s+)!(\s)/

  # Change one posting line's own flag (nil, '?' or '*'), keeping amount columns aligned.
  def set_posting_flag(lines, lineno, account, expect, to)
    expect = nil if expect == ""
    to = nil if to == ""
    i = lineno - 1
    m = i >= 0 && i < lines.length ? POSTING_RE.match(lines[i]) : nil
    if m.nil? || m[3] != account || m[2] != expect
      raise Conflict, "Line #{lineno} no longer matches #{account}. Reload the list and try again."
    end
    indent, cur, acct, rest = m[1], m[2], m[3], m[4]
    return if to == cur
    gap = /\A(\s+)(\S.*)\z/.match(rest)  # whitespace before the amount, then the amount
    if to && !cur
      rest = gap[1][2..] + gap[2] if gap && gap[1].length >= 4
      lines[i] = "#{indent}#{to} #{acct}#{rest}"
    elsif cur && !to
      rest = "  " + gap[1] + gap[2] if gap
      lines[i] = "#{indent}#{acct}#{rest}"
    else
      lines[i] = "#{indent}#{to} #{acct}#{rest}"
    end
  end

  def reconcile_save(ledger, data)
    require_hash(ledger, data)
    account = parse_account(data["account"])
    changes = data["changes"]
    return { "ok" => true, "backup" => nil, "hash" => file_hash(ledger) } if py_falsy?(changes)
    raise InputError, "changes must be a list" unless changes.is_a?(Array)
    lines = read_text(ledger).split("\n", -1)
    changes.each do |c|
      raise InputError, "Each change must be an object" unless c.is_a?(Hash)
      frm = py_or(c["from"], nil)
      to = py_or(c["to"], nil)
      unless [nil, "?"].include?(frm) && [nil, "?"].include?(to)
        raise InputError, "Saving progress can only add or remove the ? mark"
      end
      set_posting_flag(lines, to_int(c["lineno"]), account, frm, to)
    end
    backup = commit(ledger, lines.join("\n"))
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger) }
  end

  def reconcile_finish(ledger, data)
    require_hash(ledger, data)
    account = parse_account(data["account"])
    through = parse_date(data["through"])
    statement_text = data.fetch("statement", "").to_s.strip
    raise InputError, "Enter the statement ending balance" unless AMOUNT_RE.match?(statement_text)
    statement = dec(statement_text)
    statement_places = dec_places(statement_text)
    currency = py_or(data["currency"], "USD").to_s
    raise InputError, "Invalid currency: #{currency}" unless CURRENCY_RE.match?(currency)

    every = posting_rows(ledger)
    rows = every.select { |r| r["account"] == account && r["date"] <= through && r["currency"] == currency }
    marked = rows.select { |r| r["state"] == "marked" }
    pending = rows.select { |r| r["state"] == "pending" }
    total_text = dec_sum(rows.reject { |r| r["state"] == "pending" }.map { |r| r["amount_text"] })
    total = dec(total_text)
    raise InputError, "Nothing is marked to reconcile" if marked.empty?
    if total != statement
      diff = dec_text(statement - total, [statement_places, dec_places(total_text)].max)
      raise InputError, "Cleared + marked is #{total_text}, statement is #{dec_text(statement, statement_places)} (difference #{diff})"
    end
    add_balance = !py_falsy?(data["balance_assertion"])
    if add_balance && !pending.empty?
      raise InputError, "A balance assertion needs every transaction through the statement date to be marked"
    end

    lines = read_text(ledger).split("\n", -1)
    marked.each { |r| set_posting_flag(lines, r["lineno"], account, r["posting_flag"], "*") }

    # A pending (`!`) transaction becomes `*` once every Assets/Liabilities posting in it is cleared.
    done = marked.map { |r| r["lineno"] }
    headers = {}
    query(ledger, "SELECT id, lineno, type FROM #entries").each { |tid, ln, kind| headers[tid] = ln if kind == "transaction" }
    promoted = 0
    marked.map { |r| r["id"] }.uniq.each do |tid|
      sheet = every.select { |r| r["id"] == tid && r["account"].start_with?(*BALANCE_SHEET) }
      next unless sheet.all? { |r| r["state"] == "cleared" || done.include?(r["lineno"]) }
      i = headers[tid] - 1
      next unless HEADER_RE.match?(lines[i])
      lines[i] = lines[i].sub(HEADER_RE) { "#{$1}*#{$2}" }
      promoted += 1
    end

    text = lines.join("\n")
    if add_balance
      day = (Date.iso8601(through) + 1).iso8601
      text = join_append(text, "#{day} balance #{account}  #{dec_text(statement, statement_places)} #{currency}\n")
    end
    backup = commit(ledger, text)
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger), "reconciled" => marked.length, "promoted" => promoted }
  end
end
