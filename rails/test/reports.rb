#!/usr/bin/env ruby
# Report checks: each Rails report (page and JSON twin) on the reports fixture, compared with rledger's own
# output on the same scratch file (`rledger report`, `rledger query`, `rledger check -f json`).
# Usage (via test/run_reports.sh): bundle exec ruby test/reports.rb LEDGER PORT RAILS_DIR BROKEN_LEDGER
require "json"
require "net/http"
require "bigdecimal"
require "open3"
require "date"

LEDGER = ARGV.fetch(0)
PORT = Integer(ARGV.fetch(1))
RAILS_DIR = ARGV.fetch(2)
BROKEN = ARGV.fetch(3)
COUNTS = {}

def check(group, name)
  problems = []
  begin
    yield problems
  rescue StandardError => e
    problems << "#{e.class}: #{e.message}"
  end
  c = (COUNTS[group] ||= { pass: 0, fail: 0 })
  if problems.empty?
    c[:pass] += 1
    puts "PASS  [#{group}] #{name}"
  else
    c[:fail] += 1
    puts "FAIL  [#{group}] #{name}\n      " + problems.join("\n      ")
  end
end

def get(path)
  res = Net::HTTP.start("127.0.0.1", PORT) { |h| h.request(Net::HTTP::Get.new(path)) }
  [res.code.to_i, res.body.to_s, res]
end

def api(path)
  code, body = get(path)
  raise "GET #{path} gave #{code}: #{body[0, 300]}" unless code == 200
  JSON.parse(body)
end

def bql(q)
  out, err, st = Open3.capture3("rledger", "query", "-f", "json", LEDGER, q)
  raise "rledger query failed: #{err}" unless st.success?
  JSON.parse(out)["rows"]
end

def rreport(name)
  out, err, st = Open3.capture3("rledger", "report", LEDGER, name, "-f", "json")
  raise "rledger report #{name} failed: #{err}" unless st.success?
  JSON.parse(out)
end

# {currency => amount} as numbers, zeros dropped.
def nmap(map)
  map.to_h { |c, v| [c, BigDecimal(v.to_s)] }.reject { |_, v| v.zero? }
end

def neg(map)
  map.transform_values { |v| -v }
end

# Rows [account, currency, total] -> {account => {currency => number}}, zeros dropped.
def acct_map(rows)
  rows.each_with_object({}) { |(a, c, t), h| (h[a] ||= {})[c] = BigDecimal(t.to_s) }
      .transform_values { |m| m.reject { |_, v| v.zero? } }.reject { |_, m| m.empty? }
end

# rledger report's account list -> {account => {currency => number}}.
def report_map(list)
  acct_map(list.map { |r| [r["account"], r["currency"], r["amount"]] })
end

# Tree rows -> {account => own balance}, accounts with no own balance dropped.
def leaves(rows)
  rows.to_h { |r| [r["account"], nmap(r["balance"])] }.reject { |_, m| m.empty? }
end

def same(problems, label, got, want)
  problems << "#{label}: rails #{got.inspect}, rledger #{want.inspect}" unless got == want
end

def page(problems, path, text)
  code, body = get(path)
  problems << "status #{code}" unless code == 200
  problems << "page does not include #{text.inspect}" unless body.include?(text)
  problems << "page has no Tailwind stylesheet link" unless body.match?(%r{/assets/tailwind-[0-9a-f]+\.css})
end

60.times do
  get("/api/accounts")
  break
rescue SystemCallError
  sleep 0.5
end

# ---- income statement (R1)
check("income", "accounts match rledger report income") do |p|
  r = api("/api/reports/income-statement")
  same(p, "accounts", leaves(r["income"] + r["expenses"]), report_map(rreport("income")["accounts"]))
end
check("income", "net income is minus rledger's net_income (the app keeps ledger signs)") do |p|
  r = api("/api/reports/income-statement")
  same(p, "net income", nmap(r["net_income"]), neg(nmap(rreport("income")["net_income"])))
end
check("income", "2024 income total matches rledger query") do |p|
  r = api("/api/reports/income-statement?from=2024-01-01&to=2024-12-31")
  want = bql("SELECT currency, sum(number) AS t WHERE account ~ '^Income:' AND date >= 2024-01-01 AND date <= 2024-12-31 GROUP BY currency")
  same(p, "income 2024", nmap(r["income_total"]), nmap(want.to_h))
end
check("income", "monthly net incomes add up to the net income") do |p|
  r = api("/api/reports/income-statement")
  sum = Hash.new(BigDecimal("0"))
  r["months"].each { |m| m["net"].each { |c, v| sum[c] += BigDecimal(v) } }
  same(p, "months", sum.reject { |_, v| v.zero? }, nmap(r["net_income"]))
end
check("income", "page renders") { |p| page(p, "/reports/income-statement", "Net income") }

# ---- balance sheet (R2)
check("balance", "accounts match rledger report balsheet") do |p|
  r = api("/api/reports/balance-sheet")
  same(p, "accounts", leaves(r["assets"] + r["liabilities"] + r["equity"]), report_map(rreport("balsheet")["accounts"]))
end
check("balance", "net worth matches rledger report balsheet") do |p|
  same(p, "net worth", nmap(api("/api/reports/balance-sheet")["net_worth"]), nmap(rreport("balsheet")["net_worth"]))
end
check("balance", "assets + liabilities + equity + net income is zero") do |p|
  same(p, "check", nmap(api("/api/reports/balance-sheet")["check"]), {})
end
check("balance", "as of 2023-12-31 matches rledger query") do |p|
  r = api("/api/reports/balance-sheet?to=2023-12-31")
  want = acct_map(bql("SELECT account, currency, sum(number) AS t WHERE account ~ '^(Assets|Liabilities|Equity):' AND date <= 2023-12-31 GROUP BY account, currency"))
  same(p, "accounts", leaves(r["assets"] + r["liabilities"] + r["equity"]), want)
end
check("balance", "page renders") { |p| page(p, "/reports/balance-sheet", "Net income, not yet closed into equity") }

# ---- trial balance (R3)
check("trial", "every account matches rledger query") do |p|
  r = api("/api/reports/trial-balance")
  same(p, "accounts", leaves(r["rows"]), acct_map(bql("SELECT account, currency, sum(number) AS t GROUP BY account, currency")))
end
check("trial", "grand total is zero") do |p|
  same(p, "total", nmap(api("/api/reports/trial-balance")["total"]), {})
end
check("trial", "2024 period matches rledger query") do |p|
  r = api("/api/reports/trial-balance?from=2024-01-01&to=2024-12-31")
  want = acct_map(bql("SELECT account, currency, sum(number) AS t WHERE date >= 2024-01-01 AND date <= 2024-12-31 GROUP BY account, currency"))
  same(p, "accounts", leaves(r["rows"]), want)
end
check("trial", "page renders") { |p| page(p, "/reports/trial-balance", "Grand total") }

# ---- journal (R4)
check("journal", "entry count matches rledger #entries") do |p|
  same(p, "count", api("/api/reports/journal")["count"], bql("SELECT id FROM #entries").length)
end
check("journal", "transaction filter count matches rledger") do |p|
  same(p, "count", api("/api/reports/journal?type=transaction")["count"], bql("SELECT id FROM #entries WHERE type = 'transaction'").length)
end
check("journal", "newest entry first") do |p|
  same(p, "first date", api("/api/reports/journal")["entries"].first["date"], bql("SELECT max(date) FROM #entries").first.first)
end
check("journal", "a pad entry shows its own line") do |p|
  e = api("/api/reports/journal?type=pad")["entries"].first || {}
  p << "pad text was #{e["text"].inspect}" unless e["text"].to_s.include?("pad Assets:Bank:Savings Equity:Opening-Balances")
end
check("journal", "unknown entry type is refused") do |p|
  code, = get("/api/reports/journal?type=bogus")
  same(p, "status", code, 400)
end
check("journal", "a huge or non-numeric page number is refused") do |p|
  same(p, "huge", get("/api/reports/journal?page=1000000000000000000000000000000").first, 400)
  same(p, "text", get("/reports/journal?page=abc").first, 400)
end
check("journal", "page renders") { |p| page(p, "/reports/journal", "Paycheck") }

# ---- account page (R5)
check("account", "balance of Assets:Bank matches rledger query") do |p|
  r = api("/api/reports/account/Assets:Bank")
  want = bql("SELECT currency, sum(number) AS t WHERE account ~ '^Assets:Bank(:|$)' GROUP BY currency")
  same(p, "balance", nmap(r["balance"]), nmap(want.to_h))
end
check("account", "newest posting carries the final running balance") do |p|
  r = api("/api/reports/account/Assets:Bank")
  row = r["journal"].first
  same(p, "running", BigDecimal(row["balance"]), nmap(r["balance"])[row["currency"]])
end
check("account", "monthly changes add up to the balance") do |p|
  r = api("/api/reports/account/Assets:Bank")
  sum = Hash.new(BigDecimal("0"))
  r["months"].each { |m| m["change"].each { |c, v| sum[c] += BigDecimal(v) } }
  same(p, "months", sum.reject { |_, v| v.zero? }, nmap(r["balance"]))
end
check("account", "sub-accounts are listed") do |p|
  got = api("/api/reports/account/Assets:Bank")["accounts"].map { |a| a["account"] }
  same(p, "accounts", got, ["Assets:Bank:Checking", "Assets:Bank:Savings"])
end
check("account", "root account works") do |p|
  r = api("/api/reports/account/Expenses")
  want = bql("SELECT currency, sum(number) AS t WHERE account ~ '^Expenses(:|$)' GROUP BY currency")
  same(p, "balance", nmap(r["balance"]), nmap(want.to_h))
end
check("account", "unknown or invalid account is refused") do |p|
  same(p, "unknown", get("/api/reports/account/Assets:Nope").first, 400)
  same(p, "invalid", get("/api/reports/account/assets").first, 400)
end
check("account", "page renders") { |p| page(p, "/reports/account/Assets:Bank:Checking", "Balance at month end") }

# ---- statistics (R6)
check("stats", "entries per type match rledger") do |p|
  got = api("/api/reports/statistics")["entries_by_type"].to_h { |x| [x["type"], x["count"]] }
  same(p, "types", got, bql("SELECT type, count(*) AS n FROM #entries GROUP BY type").to_h)
end
check("stats", "postings per account match rledger") do |p|
  got = api("/api/reports/statistics")["postings_by_account"].to_h { |x| [x["account"], x["count"]] }
  same(p, "postings", got, bql("SELECT account, count(*) AS n GROUP BY account").to_h)
end
check("stats", "balance lines match current balances") do |p|
  got = api("/api/reports/statistics")["balance_directives"].lines.to_h { |l| a = l.split; [[a[2], a[4]], BigDecimal(a[3])] }
  want = acct_map(bql("SELECT account, currency, sum(number) AS t WHERE account ~ '^(Assets|Liabilities):' AND date < #{Date.today.iso8601} GROUP BY account, currency"))
         .flat_map { |a, m| m.map { |c, v| [[a, c], v] } }.to_h
  same(p, "balances", got, want)
end
check("stats", "page renders") { |p| page(p, "/reports/statistics", "Balance lines for today") }

# ---- errors (R7)
check("errors", "clean ledger: counts match rledger check -f json") do |p|
  r = api("/api/reports/errors")
  out, = Open3.capture3("rledger", "check", "-C", "-f", "json", LEDGER)
  w = JSON.parse(out)
  same(p, "counts", [r["error_count"], r["warning_count"], r["diagnostics"].length],
       [w["error_count"], w["warning_count"], w["diagnostics"].length])
end
check("errors", "broken scratch file: same diagnostics as rledger") do |p|
  out, err, st = Open3.capture3("bundle", "exec", "ruby", "-e",
                                'require "./config/environment"; print Ledger.check_errors(ARGV[0]).to_json', BROKEN, chdir: RAILS_DIR)
  raise "helper failed: #{err}" unless st.success?
  got = JSON.parse(out)
  raw, = Open3.capture3("rledger", "check", "-C", "-f", "json", BROKEN)
  w = JSON.parse(raw)
  same(p, "error count", got["error_count"], w["error_count"])
  same(p, "diagnostics", got["diagnostics"].map { |d| [d["line"], d["code"], d["message"]] },
       w["diagnostics"].map { |d| [d["line"], d["code"], d["message"]] })
end
check("errors", "page renders") { |p| page(p, "/reports/errors", "No errors") }

# ---- events (R8)
check("events", "events match rledger #events") do |p|
  got = api("/api/reports/events")["types"].flat_map { |t| t["events"].map { |e| [e["date"], t["type"], e["description"]] } }.sort
  same(p, "events", got, bql("SELECT date, type, description FROM #events").sort)
end
check("events", "period filter keeps only 2024") do |p|
  got = api("/api/reports/events?from=2024-01-01&to=2024-12-31")["types"].flat_map { |t| t["events"].map { |e| e["description"] } }
  same(p, "events", got, ["Porto"])
end
check("events", "page renders") { |p| page(p, "/reports/events", "Lisbon") }

# ---- prices (R9)
check("prices", "prices match rledger #prices") do |p|
  got = api("/api/reports/commodities")["pairs"].flat_map { |pr| pr["prices"].map { |x| [x["date"], pr["base"], pr["quote"], BigDecimal(x["price"])] } }.sort
  want = bql("SELECT date, currency, amount FROM #prices").map { |d, c, a| [d, c, a["currency"], BigDecimal(a["number"])] }.sort
  same(p, "prices", got, want)
end
check("prices", "page renders") { |p| page(p, "/reports/commodities", "EUR in USD") }

# ---- general
check("general", "/reports goes to the income statement") do |p|
  code, _, res = get("/reports")
  same(p, "status", code, 302)
  p << "location #{res["Location"].inspect}" unless res["Location"].to_s.end_with?("/reports/income-statement")
end
check("general", "main page links to the reports") do |p|
  _, body = get("/")
  p << "no /reports link" unless body.include?('href="/reports"')
end
check("general", "start date after end date is refused") do |p|
  same(p, "status", get("/api/reports/income-statement?from=2024-02-01&to=2024-01-01").first, 400)
end
check("general", "a bad date gives a plain 400 page") do |p|
  code, body = get("/reports/trial-balance?from=junk")
  same(p, "status", code, 400)
  p << "no plain message" unless body.include?("Date must be YYYY-MM-DD")
end

puts
COUNTS.each { |g, c| puts format("%-8s %d passed, %d failed", g, c[:pass], c[:fail]) }
passed = COUNTS.values.sum { |c| c[:pass] }
failed = COUNTS.values.sum { |c| c[:fail] }
puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
