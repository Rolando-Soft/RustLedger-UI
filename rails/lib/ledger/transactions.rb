module Ledger
  STR_RE = /"((?:[^"\\]|\\.)*)"/
  HDR_RE = /\A(\d{4}-\d\d-\d\d)\s+(\*|!|\?|txn|[A-Z])\s+(.*)\z/
  POSTING_FULL_RE = /\A(\s+)(?:([*!?])\s+)?([A-Z][A-Za-z0-9:-]*)(?:\s+(-?(?:\d+(?:\.\d*)?|\.\d+))\s+([A-Z][A-Z0-9'._-]*))?\s*\z/
  META_RE = /\A\s+[a-z][A-Za-z0-9_-]*:/
  COMMENT_RE = /\A\s+;/

  # Locate a transaction block and split it into form fields plus lines we must keep as they are.
  def parse_txn(lines, header_lineno)
    start = header_lineno - 1
    m = start >= 0 && start < lines.length ? HDR_RE.match(lines[start]) : nil
    raise Conflict, "Line #{header_lineno} is not a transaction any more. Reload and try again." unless m
    stop = start + 1
    stop += 1 while stop < lines.length && !lines[stop].strip.empty? && " \t".include?(lines[stop][0])
    t = { "start" => start, "end" => stop, "reason" => nil, "postings" => [], "head_extras" => [] }

    flag, rest = m[2], m[3]
    strings = rest.scan(STR_RE).map { |(s)| s.gsub(/\\(.)/) { $1 } }
    remainder = rest.gsub(STR_RE, "")
    tags = remainder.scan(%r{#([A-Za-z0-9_/.-]+)}).map(&:first)
    links = remainder.scan(%r{\^([A-Za-z0-9_/.-]+)}).map(&:first)
    leftover = remainder.gsub(%r{[#^][A-Za-z0-9_/.-]+}, "").strip
    flag = "*" if flag == "txn"
    if !["*", "!"].include?(flag)
      t["reason"] = "flag #{flag} is not supported by the form"
    elsif !leftover.empty? || strings.length > 2
      t["reason"] = "the first line has parts the form can't represent (comment or extra text)"
    end
    t.merge!("date" => m[1], "flag" => flag, "tags" => tags.join(" "), "links" => links.join(" "),
             "payee" => strings.length == 2 ? strings[0] : "", "narration" => strings.empty? ? "" : strings[-1])

    lines[(start + 1)...stop].each do |line|
      if COMMENT_RE.match?(line) || META_RE.match?(line)
        (t["postings"].empty? ? t["head_extras"] : t["postings"][-1]["extras"]) << line
        next
      end
      pm = POSTING_FULL_RE.match(line)
      unless pm
        t["reason"] ||= "this line isn't a plain posting: #{line.strip}"
        next
      end
      t["postings"] << { "orig" => t["postings"].length, "flag" => pm[2], "account" => pm[3],
                         "amount" => pm[4] || "", "currency" => pm[5] || "", "extras" => [] }
    end
    t
  end

  def build_edit(ledger, data)
    require_hash(ledger, data)
    lines = read_text(ledger).split("\n", -1)
    t = parse_txn(lines, to_int(data.fetch("lineno", 0)))
    raise InputError, "This transaction can't be edited here: " + t["reason"] if t["reason"]
    entry = format_entry(data)
    rendered = entry.chomp("\n").split("\n", -1)
    posts = entry_postings(data)
    out = [rendered[0]] + t["head_extras"]
    seen = []
    posts.zip(rendered.drop(1)).each do |p, line|
      orig = nil
      unless p["orig"].nil?
        o = p["orig"]
        if !o.is_a?(Integer) || o.negative? || o >= t["postings"].length || seen.include?(o)
          raise Conflict, "The postings no longer match the file. Reload and try again."
        end
        seen << o
        orig = t["postings"][o]
      end
      out << line
      out.concat(orig["extras"]) if orig
    end
    t["postings"].each_with_index do |op, i|
      if !seen.include?(i) && !op["extras"].empty?
        raise InputError, "The posting for #{op['account']} has comments or metadata; remove it in your editor instead"
      end
    end
    lines[t["start"]...t["end"]] = out
    [lines.join("\n"), entry]
  end

  def txn_edit(ledger, data)
    text, entry = build_edit(ledger, data)
    backup = commit(ledger, text)
    { "ok" => true, "text" => entry, "backup" => backup, "hash" => file_hash(ledger) }
  end

  def txn_edit_validate(ledger, data)
    text, entry = build_edit(ledger, data)
    code, out = check_text(ledger, text)
    { "text" => entry, "ok" => code == 0, "message" => out }
  end

  def txn_delete(ledger, data)
    require_hash(ledger, data)
    lines = read_text(ledger).split("\n", -1)
    t = parse_txn(lines, to_int(data.fetch("lineno", 0)))
    lines.slice!(t["start"]...t["end"])
    i = t["start"]
    if i < lines.length && lines[i].strip.empty? && (i.zero? || lines[i - 1].strip.empty?)
      lines.delete_at(i)  # don't leave a double blank line behind
    end
    backup = commit(ledger, lines.join("\n"))
    { "ok" => true, "backup" => backup, "hash" => file_hash(ledger) }
  end
end
