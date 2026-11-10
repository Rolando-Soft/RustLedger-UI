module Ledger
  # ---- Reports: read-only. RustFava's reports were the reference for what each one shows. ----
  # Amounts keep the ledger's signs (income and liabilities negative). Periods are plain date filters.
  JOURNAL_TYPES = %w[transaction open close balance pad note document event price custom commodity query].freeze
  JOURNAL_PAGE_SIZE = 100

  # Optional inclusive period; blank means open-ended. Returns ISO dates or nil.
  def report_period(from, to)
    from = from.to_s.strip.empty? ? nil : parse_date(from)
    to = to.to_s.strip.empty? ? nil : parse_date(to)
    raise InputError, "The start date is after the end date" if from && to && from > to
    [from, to]
  end

  # BQL conditions for the period (the dates passed parse_date, so they are plain YYYY-MM-DD).
  def period_where(from, to)
    parts = []
    parts << "date >= #{from}" if from
    parts << "date <= #{to}" if to
    parts
  end

  def in_period?(date, from, to)
    (from.nil? || date >= from) && (to.nil? || date <= to)
  end

  # Account order everywhere: Assets, Liabilities, Equity, Income, Expenses, then by name, parents before children.
  def account_sort_key(account)
    parts = account.split(":")
    [ACCOUNT_TYPES.index(parts.first) || ACCOUNT_TYPES.length, parts]
  end

  # {account => {currency => total}} for the postings matching the BQL conditions.
  def account_totals(ledger, conditions)
    where = conditions.empty? ? "" : " WHERE " + conditions.join(" AND ")
    out = {}
    query(ledger, "SELECT account, currency, sum(number) AS total#{where} GROUP BY account, currency").each do |account, currency, total|
      (out[account] ||= {})[currency] = total.to_s
    end
    out
  end

  # Adds {currency => amount} maps; currencies that come to zero are left out (an empty map means zero).
  def add_amounts(maps)
    by_cur = {}
    maps.each { |m| m.each { |cur, n| (by_cur[cur] ||= []) << n } }
    by_cur.sort.to_h { |cur, ns| [cur, dec_sum(ns)] }.reject { |_, v| dec(v).zero? }
  end

  def section_total(totals, root)
    add_amounts(totals.select { |a, _| a.start_with?(root + ":") }.values)
  end

  # Rows of an account tree, in account order: every account with postings plus its parents.
  # "balance" is the account's own amount, "total" includes its sub-accounts (RustFava's balance_children).
  def account_tree(totals, roots = ACCOUNT_TYPES)
    names = {}
    totals.each_key do |account|
      parts = account.split(":")
      next unless roots.include?(parts.first)
      parts.length.times { |i| names[parts[0..i].join(":")] = true }
    end
    names.keys.sort_by { |a| account_sort_key(a) }.map do |a|
      inside = totals.select { |k, _| k == a || k.start_with?(a + ":") }.values
      { "account" => a, "name" => a.split(":").last, "depth" => a.count(":"),
        "balance" => add_amounts([totals[a] || {}]), "total" => add_amounts(inside) }
    end
  end

  # R1. Income and expenses for the period, net income, and month-by-month totals.
  def income_statement(ledger, from, to)
    from, to = report_period(from, to)
    conditions = period_where(from, to) + ["account ~ '^(Income|Expenses):'"]
    totals = account_totals(ledger, conditions)
    income = section_total(totals, "Income")
    expenses = section_total(totals, "Expenses")
    months = {}
    query(ledger, "SELECT year(date) AS y, month(date) AS m, root(account, 1) AS t, currency, sum(number) AS total WHERE " +
                  conditions.join(" AND ") + " GROUP BY y, m, t, currency").each do |y, m, t, cur, total|
      row = (months[format("%04d-%02d", y, m)] ||= { "Income" => {}, "Expenses" => {} })
      row[t][cur] = total.to_s
    end
    { "from" => from, "to" => to,
      "income" => account_tree(totals, ["Income"]), "expenses" => account_tree(totals, ["Expenses"]),
      "income_total" => income, "expenses_total" => expenses, "net_income" => add_amounts([income, expenses]),
      "months" => months.sort.map do |month, r|
        { "month" => month, "income" => add_amounts([r["Income"]]), "expenses" => add_amounts([r["Expenses"]]),
          "net" => add_amounts([r["Income"], r["Expenses"]]) }
      end }
  end

  # R2. Assets, liabilities and equity as of a date, plus the computed net-income line and month-end net worth.
  def balance_sheet(ledger, to)
    _from, to = report_period(nil, to)
    totals = account_totals(ledger, period_where(nil, to))
    sheet = totals.select { |a, _| a.start_with?("Assets:", "Liabilities:", "Equity:") }
    net = add_amounts(totals.select { |a, _| a.start_with?("Income:", "Expenses:") }.values)
    assets, liabilities, equity = %w[Assets Liabilities Equity].map { |s| section_total(totals, s) }
    running = []
    months = []
    monthly = query(ledger, "SELECT year(date) AS y, month(date) AS m, currency, sum(number) AS total WHERE " +
                            (period_where(nil, to) + ["account ~ '^(Assets|Liabilities):'"]).join(" AND ") +
                            " GROUP BY y, m, currency")
    monthly.group_by { |y, m, _, _| format("%04d-%02d", y, m) }.sort.each do |month, rows|
      running << rows.to_h { |_, _, cur, total| [cur, total.to_s] }
      months << { "month" => month, "net_worth" => add_amounts(running) }
    end
    { "to" => to,
      "assets" => account_tree(sheet, ["Assets"]), "liabilities" => account_tree(sheet, ["Liabilities"]),
      "equity" => account_tree(sheet, ["Equity"]),
      "assets_total" => assets, "liabilities_total" => liabilities, "equity_total" => equity,
      "net_income" => net, "equity_with_income" => add_amounts([equity, net]),
      "net_worth" => add_amounts([assets, liabilities]),
      "check" => add_amounts([assets, liabilities, equity, net]),  # empty (zero) when the ledger balances
      "months" => months.reverse }
  end

  # R3. Every account for the period, and the grand total (zero per currency in a balanced ledger).
  def trial_balance(ledger, from, to)
    from, to = report_period(from, to)
    totals = account_totals(ledger, period_where(from, to))
    { "from" => from, "to" => to, "rows" => account_tree(totals), "total" => add_amounts(totals.values) }
  end

  # R4. Every entry, newest first, optionally of one type, a page at a time.
  def journal(ledger, type, page)
    type = type.to_s.strip
    raise InputError, "Unknown entry type: #{type}" unless type.empty? || JOURNAL_TYPES.include?(type)
    page = page.to_s.strip.empty? ? "1" : page.to_s.strip
    raise InputError, "Page must be a whole number from 1 up" unless page.match?(/\A\d{1,6}\z/) && page.to_i >= 1
    page = page.to_i
    rows = query(ledger, "SELECT id, type, date, flag, payee, narration, filename, lineno FROM #entries")
    rows = rows.select { |r| type.empty? || r[1] == type }
    rows = rows.each_with_index.sort_by { |r, i| [r[2], i] }.reverse.map(&:first)
    shown = rows.slice((page - 1) * JOURNAL_PAGE_SIZE, JOURNAL_PAGE_SIZE) || []
    wanted = shown.select { |r| r[1] == "transaction" }.to_h { |r| [r[0], []] }
    unless wanted.empty?
      query(ledger, "SELECT id, account, number, currency, posting_flag FROM #postings").each do |id, account, number, currency, pflag|
        wanted[id] << { "account" => account, "amount" => number, "currency" => currency, "flag" => pflag } if wanted.key?(id)
      end
    end
    sources = {}
    entries = shown.map do |id, kind, date, flag, payee, narration, filename, lineno|
      path = resolve(filename)
      text = nil
      if kind != "transaction" && path && lineno.to_i.positive?
        lines = (sources[path] ||= read_loaded(path).split("\n", -1))
        text = lines[lineno - 1].to_s.strip[0, 200]  # #entries has no details for these; show the entry's own line
      end
      { "id" => id, "type" => kind, "date" => date, "flag" => flag, "payee" => payee || "", "narration" => narration || "",
        "text" => text, "postings" => wanted[id] || [] }
    end
    { "type" => type, "page" => page, "pages" => [(rows.length + JOURNAL_PAGE_SIZE - 1) / JOURNAL_PAGE_SIZE, 1].max,
      "count" => rows.length, "entries" => entries }
  end

  # R5. One account (or a parent such as Assets:Bank, or a root such as Assets) with its sub-accounts:
  # postings with a running balance, the period's tree, and month-by-month change and month-end balance.
  def account_report(ledger, account, from, to)
    account = clean_str(account, "Account")
    account = parse_account_name(account) unless ACCOUNT_TYPES.include?(account)
    from, to = report_period(from, to)
    match = "account ~ '^#{account}(:|$)'"  # the name passed ACCOUNT_RE: letters, digits, ':' and '-' only
    accounts = query(ledger, "SELECT account, open, close FROM #accounts")
               .select { |a, _, _| a == account || a.start_with?(account + ":") }
    raise InputError, "#{account} is not an account in this ledger" if accounts.empty?
    rows = query(ledger, "SELECT id, date, flag, payee, narration, account, number, currency FROM #postings WHERE " +
                         ([match] + period_where(nil, to)).join(" AND "))
    running = {}
    month_change = {}
    month_balance = {}
    journal = []
    rows.each_with_index.sort_by { |r, i| [r[1], r[0], i] }.each do |(_id, date, flag, payee, narration, acct, number, currency), _i|
      running[currency] = dec_sum([running[currency] || "0", number])
      month = date[0, 7]
      month_balance[month] = running.dup
      next if from && date < from
      ((month_change[month] ||= {})[currency] ||= []) << number
      journal << { "date" => date, "flag" => flag, "payee" => payee || "", "narration" => narration || "",
                   "account" => acct, "amount" => number, "currency" => currency, "balance" => running[currency] }
    end
    months = month_change.keys.sort.reverse.map do |m|
      { "month" => m, "change" => add_amounts(month_change[m].map { |cur, ns| { cur => dec_sum(ns) } }),
        "balance" => add_amounts([month_balance[m]]) }
    end
    totals = account_totals(ledger, [match] + period_where(from, to))
    { "account" => account, "from" => from, "to" => to,
      "accounts" => accounts.sort_by { |a, _, _| account_sort_key(a) }.map { |a, o, c| { "account" => a, "open" => o, "closed" => c } },
      "balance" => add_amounts([running]),
      "tree" => account_tree(totals).select { |r| r["account"] == account || r["account"].start_with?(account + ":") },
      "months" => months, "journal" => journal.reverse }
  end

  # R6. Counts, date range, and today's balances written as `balance` lines ready to copy.
  def statistics(ledger)
    types = query(ledger, "SELECT type, count(*) AS n FROM #entries GROUP BY type")
            .map { |t, n| { "type" => t, "count" => n } }.sort_by { |r| [-r["count"], r["type"]] }
    postings = query(ledger, "SELECT account, count(*) AS n GROUP BY account")
               .map { |a, n| { "account" => a, "count" => n } }.sort_by { |r| account_sort_key(r["account"]) }
    first, last = query(ledger, "SELECT min(date), max(date) FROM #entries").fetch(0)
    day = Date.today.iso8601
    # A balance line checks the start of its day, so only postings dated before today count.
    lines = account_totals(ledger, ["account ~ '^(Assets|Liabilities):'", "date < #{day}"]).sort_by { |a, _| account_sort_key(a) }.flat_map do |account, m|
      add_amounts([m]).map { |cur, n| "#{day} balance #{account}  #{n} #{cur}\n" }
    end
    { "entries_by_type" => types, "postings_by_account" => postings, "first_date" => first, "last_date" => last,
      "balance_directives" => lines.join }
  end

  # R7. What `rledger check` reports, from its JSON output.
  def check_errors(ledger)
    out, err, _status = Open3.capture3("rledger", "check", "-C", "-f", "json", ledger.to_s)
    data = begin
      JSON.parse(out)
    rescue JSON::ParserError
      raise "rledger check did not return JSON: #{(out + err).strip[0, 500]}"
    end
    { "error_count" => data["error_count"] || 0, "warning_count" => data["warning_count"] || 0,
      "diagnostics" => (data["diagnostics"] || []).map do |d|
        { "file" => File.basename(d["file"].to_s), "line" => d["line"], "severity" => d["severity"],
          "code" => d["code"], "message" => d["message"] }
      end }
  end

  # R8. Event entries (e.g. location, employer), grouped by type, newest first.
  def events(ledger, from, to)
    from, to = report_period(from, to)
    rows = query(ledger, "SELECT date, type, description FROM #events").select { |d, _, _| in_period?(d, from, to) }
    { "from" => from, "to" => to,
      "types" => rows.group_by { |_, t, _| t }.sort.map do |t, rs|
        { "type" => t, "events" => rs.sort_by(&:first).reverse.map { |d, _, desc| { "date" => d, "description" => desc } } }
      end }
  end

  # R9. Price history per currency pair, newest first.
  def commodities(ledger, from, to)
    from, to = report_period(from, to)
    rows = query(ledger, "SELECT date, currency, amount FROM #prices").select { |d, _, _| in_period?(d, from, to) }
    pairs = rows.group_by { |_, cur, amt| [cur, (amt || {})["currency"]] }.sort_by { |k, _| k.map(&:to_s) }.map do |(base, quote), rs|
      { "base" => base, "quote" => quote,
        "prices" => rs.sort_by(&:first).reverse.map { |d, _, amt| { "date" => d, "price" => (amt || {})["number"].to_s } } }
    end
    { "from" => from, "to" => to, "pairs" => pairs }
  end
end
