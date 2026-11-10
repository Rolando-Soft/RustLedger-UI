module Ledger
  # The postings the form filled in (rows with an account), as format_entry and build_edit both select them.
  def entry_postings(data)
    Array(data["postings"]).select { |p| p.is_a?(Hash) && !py_or(p["account"], "").to_s.strip.empty? }
  end

  # Validate user input and render a beancount transaction as text.
  def format_entry(data)
    d = parse_date(data.fetch("date", ""))
    flag = data.key?("flag") ? data["flag"] : "!"
    raise InputError, "Flag must be * or !" unless ["*", "!"].include?(flag)
    payee = clean_str(data["payee"], "Payee")
    narration = clean_str(data["narration"], "Narration")

    tags = []
    [[data["tags"], "#", "Tag"], [data["links"], "^", "Link"]].each do |raw, prefix, label|
      py_or(raw, "").to_s.tr(",", " ").split.each do |t|
        t = t.sub(/\A[#^]+/, "")
        raise InputError, "Invalid #{label.downcase}: #{t}" unless TAG_RE.match?(t)
        tags << prefix + t
      end
    end

    header = "#{d} #{flag}"
    header += payee.empty? ? " #{quote(narration)}" : " #{quote(payee)} #{quote(narration)}"
    header += " " + tags.join(" ") unless tags.empty?

    postings = entry_postings(data)
    raise InputError, "At least two postings are required" if postings.length < 2
    lines = [header]
    blanks = 0
    postings.each do |p|
      account = p["account"].to_s.strip
      raise InputError, "Invalid account name: #{account}" unless ACCOUNT_RE.match?(account)
      pflag = py_or(p["pflag"], "").to_s.strip
      raise InputError, "Posting flag must be blank, !, ? or *" unless ["", "!", "?", "*"].include?(pflag)
      label = pflag.empty? ? account : "#{pflag} #{account}"
      amount = py_or(p["amount"], "").to_s.strip
      currency = py_or(p["currency"], "USD").to_s.strip.upcase
      if amount.empty?
        blanks += 1
        lines << "  #{label}"
        next
      end
      raise InputError, "Invalid amount: #{amount}" unless AMOUNT_RE.match?(amount)
      raise InputError, "Invalid currency: #{currency}" unless CURRENCY_RE.match?(currency)
      lines << "  #{label.ljust(48)}#{amount.rjust(12)} #{currency}"
    end
    raise InputError, "Only one posting may leave its amount blank" if blanks > 1
    lines.join("\n") + "\n"
  end

  # Validate input and render an `open` directive.
  def format_account(data)
    d = parse_date(data.fetch("date", ""))
    account = clean_str(data["account"], "Account")
    unless ACCOUNT_RE.match?(account) && ACCOUNT_TYPES.include?(account.split(":")[0])
      raise InputError, "Account must look like Assets:Bank:Checking (type first)"
    end
    currencies = py_or(data["currencies"], "").to_s.tr(",", " ").split.map(&:upcase)
    currencies.each { |c| raise InputError, "Invalid currency: #{c}" unless CURRENCY_RE.match?(c) }
    line = "#{d} open #{account}"
    line += " " + currencies.join(",") unless currencies.empty?
    line + "\n"
  end

  def validate(ledger, entry)
    check_text(ledger, append_text(ledger, entry))
  end

  def save(ledger, entry)
    commit(ledger, append_text(ledger, entry))
  end
end
