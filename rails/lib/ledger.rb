require "json"
require "open3"
require "digest"
require "fileutils"
require "tmpdir"
require "date"
require "bigdecimal"

# Ruby port of the logic in server.py. Method names match the Python functions.
module Ledger
  extend self

  class InputError < StandardError; end   # HTTP 400

  class Conflict < StandardError; end     # HTTP 409: the file no longer matches what the page was looking at
end

require_relative "ledger/core"
require_relative "ledger/commit"
require_relative "ledger/entries"
require_relative "ledger/reads"
require_relative "ledger/reconcile"
require_relative "ledger/transactions"
require_relative "ledger/accounts"
require_relative "ledger/reports"
