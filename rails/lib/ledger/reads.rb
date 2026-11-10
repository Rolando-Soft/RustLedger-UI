module Ledger
  def get_accounts(ledger)
    rows = query(ledger, "SELECT account, open, close, currencies FROM #accounts")
    balances = {}
    begin
      query(ledger, "SELECT account, sum(position) GROUP BY account").each do |account, pos|
        balances[account] = ((pos || {})["positions"] || []).map { |p| { "amount" => p["number"], "currency" => p["currency"] } }
      end
    rescue StandardError
      # balances are a nicety; the list still works without them
    end
    rows.sort_by { |r| r[0] }.map do |a, o, c, cur|
      { "account" => a, "open" => o, "closed" => c, "currencies" => cur || [], "balance" => balances.fetch(a, []) }
    end
  end

  def transactions(ledger)
    rows = query(ledger, "SELECT id, date, flag, payee, narration, account, number, currency FROM #postings")
    heads = {}
    query(ledger, "SELECT id, lineno, filename, type FROM #entries").each do |tid, ln, fn, kind|
      next unless kind == "transaction"
      heads[tid] = resolve(fn) == ledger ? ln : nil  # included files can't be edited here
    end
    txns = {}
    rows.each do |tid, d, flag, payee, narration, account, number, currency|
      t = (txns[tid] ||= { "date" => d, "flag" => flag, "payee" => payee || "", "narration" => narration || "",
                           "postings" => [], "lineno" => heads[tid] })
      t["postings"] << { "account" => account, "amount" => number, "currency" => currency }
    end
    txns.sort_by { |tid, t| [t["date"], tid] }
  end

  # Most recent transaction per payee, for prefill.
  def get_payees(ledger)
    latest = {}
    transactions(ledger).each { |_, t| latest[t["payee"]] = t unless t["payee"].empty? }
    latest
  end

  # Every transaction in the file, oldest first, with each posting's reconciliation state.
  def get_register(ledger)
    heads = {}
    query(ledger, "SELECT id, lineno, filename, type FROM #entries").each do |tid, ln, fn, kind|
      heads[tid] = ln if kind == "transaction" && resolve(fn) == ledger
    end
    txns = {}
    posting_rows(ledger).each do |r|
      t = (txns[r["id"]] ||= { "lineno" => heads[r["id"]], "date" => r["date"], "flag" => r["txn_flag"],
                               "payee" => r["payee"], "narration" => r["narration"], "postings" => [] })
      t["postings"] << { "account" => r["account"], "amount" => r["amount_text"], "currency" => r["currency"],
                         "flag" => r["posting_flag"], "state" => r["state"] }
    end
    txns.values.each_with_index.sort_by { |t, i| [t["date"], t["lineno"] || 0, i] }.map(&:first)
  end

  def get_recent(ledger, n = 5)
    transactions(ledger).map { |_, t| t }.last(n).reverse
  end

  # ---- reconciliation: flags on individual postings ----
  # State of a posting: `*` cleared, `?` marked (ticked off, not final), otherwise pending.
  # A transaction-level `*` counts as cleared for postings with no flag of their own.
  def posting_rows(ledger)
    rows = query(ledger, "SELECT id, lineno, filename, date, flag, payee, narration, posting_flag, account, number, currency FROM #postings")
    out = []
    rows.each do |tid, lineno, fn, d, flag, payee, narration, pflag, account, number, currency|
      next unless resolve(fn) == ledger  # postings from included files are read-only here
      eff = py_or(pflag, flag == "*" ? "*" : nil)
      out << { "id" => tid, "lineno" => lineno, "date" => d, "txn_flag" => flag, "payee" => payee || "",
               "narration" => narration || "", "posting_flag" => pflag, "account" => account,
               "amount" => dec(number), "amount_text" => number, "currency" => currency,
               "state" => { "*" => "cleared", "?" => "marked" }.fetch(eff, "pending") }
    end
    out
  end

  def parse_account(value)
    account = clean_str(value, "Account")
    unless ACCOUNT_RE.match?(account) && account.start_with?(*BALANCE_SHEET)
      raise InputError, "Choose an Assets or Liabilities account"
    end
    account
  end

  def get_reconcile(ledger, account, through)
    account = parse_account(account)
    through = parse_date(through)
    all_rows = posting_rows(ledger)
    others = {}
    all_rows.each { |r| (others[r["id"]] ||= []) << r["account"] }
    rows = all_rows.select { |r| r["account"] == account && r["date"] <= through }
    currencies = rows.map { |r| r["currency"] }.uniq.sort
    currency = currencies.first || "USD"
    rows = rows.select { |r| r["currency"] == currency }.sort_by { |r| [r["date"], r["lineno"]] }
    cleared = dec_sum(rows.select { |r| r["state"] == "cleared" }.map { |r| r["amount_text"] })
    out_rows = rows.map do |r|
      { "lineno" => r["lineno"], "date" => r["date"], "payee" => r["payee"], "narration" => r["narration"],
        "amount" => r["amount_text"], "state" => r["state"], "locked" => r["state"] == "cleared",
        "posting_flag" => r["posting_flag"], "other" => others[r["id"]].reject { |a| a == account } }
    end
    { "hash" => file_hash(ledger), "currency" => currency, "ignored_currencies" => currencies.drop(1),
      "cleared" => cleared, "rows" => out_rows }
  end

  def get_transaction(ledger, lineno)
    lineno = to_int(lineno)
    t = parse_txn(read_text(ledger).split("\n", -1), lineno)
    { "hash" => file_hash(ledger), "lineno" => lineno, "editable" => t["reason"].nil?, "reason" => t["reason"] }
      .merge(t.slice("date", "flag", "payee", "narration", "tags", "links"))
      .merge("postings" => t["postings"].map { |p| p.slice("orig", "flag", "account", "amount", "currency") })
  end
end
