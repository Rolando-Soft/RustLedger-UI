#!/usr/bin/env ruby
# Parity test: the same requests go to server.py and to the Rails app, each serving its own copy of
# the same scratch ledger. After every step the status codes, the JSON bodies and the two ledger files
# must match. Usage (normally via test/run_parity.sh): ruby test/parity.rb SCRATCH_DIR PY_PORT RB_PORT
require "json"
require "net/http"
require "digest"
require "shellwords"

SCRATCH = ARGV.fetch(0)
PORTS = { py: Integer(ARGV.fetch(1)), rb: Integer(ARGV.fetch(2)) }.freeze
FILES = { py: File.join(SCRATCH, "py", "t.beancount"), rb: File.join(SCRATCH, "rb", "t.beancount") }.freeze
RESULTS = { pass: 0, fail: 0 }

def wait_for(port)
  60.times do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/accounts"))
    return
  rescue SystemCallError
    sleep 0.5
  end
  abort "server on port #{port} did not start"
end

def http(side, method, path, body: nil, raw: nil, headers: {})
  port = PORTS.fetch(side)
  req = method == :get ? Net::HTTP::Get.new(path) : Net::HTTP::Post.new(path)
  if method == :post
    req["Content-Type"] = "application/json"
    req.body = raw || JSON.generate(body || {})
  end
  headers.each { |k, v| req[k] = v.gsub("PORT", port.to_s) }
  res = Net::HTTP.start("127.0.0.1", port) { |h| h.request(req) }
  { status: res.code.to_i, body: res.body.to_s, type: res["Content-Type"].to_s }
end

# Paths differ between the two copies (and temp folders differ per run): keep only the file name.
def norm(value)
  case value
  when Hash then value.to_h { |k, v| [k, k == "backup" ? (v && "<backup>") : norm(v)] }
  when Array then value.map { |v| norm(v) }
  when String then value.gsub(%r{[^\s"':]*/((?:t|inc)\.beancount)}, '\1')
  else value
  end
end

def ledger_hash
  Digest::SHA256.file(FILES[:py]).hexdigest
end

def line_of(fragment)
  i = File.read(FILES[:py]).split("\n", -1).index { |l| l.include?(fragment) }
  abort "fixture line not found: #{fragment}" unless i
  i + 1
end

def record(name, problems, status)
  if problems.empty?
    RESULTS[:pass] += 1
    puts "PASS  #{name} (#{status})"
  else
    RESULTS[:fail] += 1
    puts "FAIL  #{name}\n      " + problems.join("\n      ")
  end
end

def json?(res)
  res[:type].start_with?("application/json")
end

# Same request to both servers; compare.
def step(name, method, path, expect:, body: nil, raw: nil, headers: {})
  py = http(:py, method, path, body: body, raw: raw, headers: headers)
  rb = http(:rb, method, path, body: body, raw: raw, headers: headers)
  problems = []
  problems << "python status #{py[:status]}, expected #{expect}" if py[:status] != expect
  problems << "rails status #{rb[:status]}, expected #{expect}" if rb[:status] != expect
  if json?(py) && json?(rb)
    jp = norm(JSON.parse(py[:body]))
    jr = norm(JSON.parse(rb[:body]))
    if expect == 500
      problems << "rails 500 body has no error text" unless jr.is_a?(Hash) && jr["error"].is_a?(String)
    elsif jp != jr
      problems << "body differs\n        python: #{JSON.generate(jp)[0, 700]}\n        rails:  #{JSON.generate(jr)[0, 700]}"
    end
  elsif !json?(py) && !json?(rb)
    problems << "page bodies differ" if py[:body] != rb[:body]
  else
    problems << "content types differ: python #{py[:type]}, rails #{rb[:type]}"
  end
  problems << "ledger files differ after this step" if File.binread(FILES[:py]) != File.binread(FILES[:rb])
  record(name, problems, rb[:status])
end

# Rails-only checks (behaviour that is new or deliberately different).
def rails_only(name, method, path, expect:, headers: {}, includes: nil)
  rb = http(:rb, method, path, headers: headers)
  problems = []
  problems << "rails status #{rb[:status]}, expected #{expect}" if rb[:status] != expect
  problems << "body does not include #{includes.inspect}" if includes && !rb[:body].include?(includes)
  record(name, problems, rb[:status])
  rb
end

PORTS.each_value { |p| wait_for(p) }
abort "the two scratch copies differ before the test" if File.binread(FILES[:py]) != File.binread(FILES[:rb])

ok_entry = {
  "date" => "2024-02-03", "flag" => "!", "payee" => "Cafe", "narration" => "Coffee", "tags" => "treat", "links" => "",
  "postings" => [
    { "account" => "Expenses:Food", "amount" => "4.75", "currency" => "USD" },
    { "account" => "Assets:Bank:Checking", "amount" => "", "currency" => "USD" },
  ],
}

# ---- page and reads
page = rails_only "GET / (Tailwind page)", :get, "/", expect: 200, includes: 'id="navReg"'
css = page[:body][%r{/assets/tailwind-[0-9a-f]+\.css}]
record("page links the built Tailwind stylesheet", css ? [] : ["no /assets/tailwind-<digest>.css link in the page"], page[:status])
rails_only "GET the Tailwind stylesheet", :get, css || "/assets/tailwind.css", expect: 200, includes: "--color-accent"
rails_only "GET /index.html", :get, "/index.html", expect: 200, includes: 'id="navReg"'
step "GET accounts", :get, "/api/accounts", expect: 200
step "GET register", :get, "/api/register", expect: 200
step "GET recent", :get, "/api/recent", expect: 200
step "GET payees", :get, "/api/payees", expect: 200
step "GET transaction (grocer)", :get, "/api/transaction?lineno=#{line_of('"Weekly shop"')}", expect: 200
step "GET transaction (not a transaction line)", :get, "/api/transaction?lineno=1", expect: 409
step "GET reconcile checking", :get, "/api/reconcile?account=Assets:Bank:Checking&through=2024-12-31", expect: 200
step "GET reconcile wrong account type", :get, "/api/reconcile?account=Expenses:Food&through=2024-12-31", expect: 400
step "GET reconcile bad date", :get, "/api/reconcile?account=Assets:Bank:Checking&through=2024-13-01", expect: 400
step "GET unknown path", :get, "/api/nope", expect: 404
step "POST unknown path", :post, "/api/nope", body: {}, expect: 404

# ---- add a transaction
step "validate entry", :post, "/api/validate", body: ok_entry, expect: 200
step "validate newline in payee", :post, "/api/validate", body: ok_entry.merge("payee" => "Ca\nfe"), expect: 400
step "validate one posting", :post, "/api/validate", body: ok_entry.merge("postings" => ok_entry["postings"].first(1)), expect: 400
step "validate bad amount", :post, "/api/validate",
     body: ok_entry.merge("postings" => [{ "account" => "Expenses:Food", "amount" => "4.7.5" }, ok_entry["postings"][1]]), expect: 400
step "validate two blank amounts", :post, "/api/validate",
     body: ok_entry.merge("postings" => [{ "account" => "Expenses:Food", "amount" => "" }, ok_entry["postings"][1]]), expect: 400
step "forbidden origin", :post, "/api/transactions", body: ok_entry, headers: { "Origin" => "http://evil.example" }, expect: 403
step "same origin allowed", :post, "/api/validate", body: ok_entry, headers: { "Origin" => "http://127.0.0.1:PORT" }, expect: 200
step "add transaction", :post, "/api/transactions", body: ok_entry, expect: 200
step "add with unopened account (rolled back)", :post, "/api/transactions",
     body: ok_entry.merge("postings" => [{ "account" => "Expenses:Nope", "amount" => "1.00" }, ok_entry["postings"][1]]), expect: 400
step "bad JSON body", :post, "/api/validate", raw: "{not json", expect: 500
step "JSON array body", :post, "/api/validate", raw: "[]", expect: 400

# ---- add an account
acct = { "date" => "2024-01-01", "account" => "Expenses:Coffee", "currencies" => "usd" }
step "validate account", :post, "/api/accounts/validate", body: acct, expect: 200
step "add account", :post, "/api/accounts", body: acct, expect: 200
step "add account bad name", :post, "/api/accounts", body: acct.merge("account" => "expenses:coffee"), expect: 400

# ---- edit a transaction
cafe = line_of('"Cafe" "Coffee"')
step "GET transaction (cafe)", :get, "/api/transaction?lineno=#{cafe}", expect: 200
edit = ok_entry.merge("hash" => ledger_hash, "lineno" => cafe, "postings" => [
  { "account" => "Expenses:Food", "amount" => "5.25", "currency" => "USD", "pflag" => "", "orig" => 0 },
  { "account" => "Assets:Bank:Checking", "amount" => "", "currency" => "USD", "pflag" => "", "orig" => 1 },
])
step "validate edit", :post, "/api/transactions/edit/validate", body: edit, expect: 200
step "edit transaction", :post, "/api/transactions/edit", body: edit, expect: 200
step "edit with stale hash", :post, "/api/transactions/edit", body: edit.merge("hash" => "0" * 64), expect: 409

# ---- reconcile
grocer = line_of("Assets:Bank:Checking     -42.10 USD")
rent = line_of("Assets:Bank:Checking    -500.00 USD")
changes = [{ "lineno" => grocer, "from" => nil, "to" => "?" }, { "lineno" => rent, "from" => nil, "to" => "?" }]
step "reconcile save", :post, "/api/reconcile/save",
     body: { "hash" => ledger_hash, "account" => "Assets:Bank:Checking", "changes" => changes }, expect: 200
step "reconcile save, mark already there", :post, "/api/reconcile/save",
     body: { "hash" => ledger_hash, "account" => "Assets:Bank:Checking", "changes" => changes }, expect: 409
step "reconcile save, star not allowed", :post, "/api/reconcile/save",
     body: { "hash" => ledger_hash, "account" => "Assets:Bank:Checking",
             "changes" => [{ "lineno" => grocer, "from" => "?", "to" => "*" }] }, expect: 400
step "GET reconcile after save", :get, "/api/reconcile?account=Assets:Bank:Checking&through=2024-01-31", expect: 200
finish = { "account" => "Assets:Bank:Checking", "through" => "2024-01-31", "currency" => "USD" }
step "reconcile finish, wrong statement", :post, "/api/reconcile/finish",
     body: finish.merge("hash" => ledger_hash, "statement" => "1900"), expect: 400
step "reconcile finish with balance assertion", :post, "/api/reconcile/finish",
     body: finish.merge("hash" => ledger_hash, "statement" => "1957.9", "balance_assertion" => true), expect: 200
step "GET register after reconcile", :get, "/api/register", expect: 200

# ---- delete a transaction
step "delete transaction", :post, "/api/transactions/delete",
     body: { "hash" => ledger_hash, "lineno" => line_of('"Grocer" "Top-up"') }, expect: 200

# ---- delete, close and edit accounts
step "delete check, unused account", :post, "/api/accounts/delete/validate", body: { "account" => "Expenses:Unused" }, expect: 200
step "delete unused account", :post, "/api/accounts/delete", body: { "hash" => ledger_hash, "account" => "Expenses:Unused" }, expect: 200
step "delete check, used account", :post, "/api/accounts/delete/validate", body: { "account" => "Assets:Bank:Checking" }, expect: 200
step "delete used account refused", :post, "/api/accounts/delete",
     body: { "hash" => ledger_hash, "account" => "Assets:Bank:Checking" }, expect: 400
step "delete check, account from included file", :post, "/api/accounts/delete/validate", body: { "account" => "Assets:Cash" }, expect: 400
step "close unused account", :post, "/api/accounts/close",
     body: { "hash" => ledger_hash, "account" => "Expenses:Coffee", "date" => "2024-03-01" }, expect: 200
step "close it again", :post, "/api/accounts/close",
     body: { "hash" => ledger_hash, "account" => "Expenses:Coffee", "date" => "2024-03-02" }, expect: 400
step "close account with a balance", :post, "/api/accounts/close",
     body: { "hash" => ledger_hash, "account" => "Income:Salary", "date" => "2024-03-01" }, expect: 400
step "close before open date", :post, "/api/accounts/close",
     body: { "hash" => ledger_hash, "account" => "Liabilities:Card", "date" => "2023-12-01" }, expect: 400
rename = { "account" => "Liabilities:Card", "new_account" => "Liabilities:CreditCard", "date" => "2024-01-01" }
step "rename check, unused account", :post, "/api/accounts/edit/validate", body: rename, expect: 200
step "rename unused account", :post, "/api/accounts/edit", body: rename.merge("hash" => ledger_hash), expect: 200
step "rename stale hash", :post, "/api/accounts/edit", body: rename.merge("hash" => "0" * 64), expect: 409
step "open date after first use", :post, "/api/accounts/edit/validate",
     body: { "account" => "Expenses:Food", "new_account" => "Expenses:Food", "date" => "2024-02-01" }, expect: 400
step "rename used account", :post, "/api/accounts/edit/validate",
     body: { "account" => "Expenses:Food", "new_account" => "Expenses:Groceries", "date" => "2024-01-01" }, expect: 400
step "nothing to change", :post, "/api/accounts/edit/validate",
     body: { "account" => "Expenses:Rent", "new_account" => "Expenses:Rent", "date" => "2024-01-01" }, expect: 400
step "GET accounts at the end", :get, "/api/accounts", expect: 200

# ---- Rails-only checks
rails_only "unknown Host header blocked (DNS rebinding guard)", :get, "/api/accounts",
           headers: { "Host" => "evil.example:PORT" }, expect: 403

# ---- backups and final files
bk = PORTS.keys.to_h { |s| [s, Dir[File.join(SCRATCH, s.to_s, ".backups", "*")].sort.map { |f| File.binread(f) }] }
record("backups: same count and same contents",
       bk[:py] == bk[:rb] ? [] : ["python #{bk[:py].size} backups, rails #{bk[:rb].size}, or their contents differ"], bk[:rb].size)
FILES.each do |side, f|
  out = `rledger check -C #{f.shellescape} 2>&1`
  record("rledger check on the #{side} copy", $?.success? ? [] : [out.strip], $?.exitstatus)
end
puts "\n#{RESULTS[:pass]} passed, #{RESULTS[:fail]} failed"
exit(RESULTS[:fail].zero? ? 0 : 1)
