# Start with: LEDGER_FILE=/path/to/file.beancount PORT=8760 bundle exec puma -C config/puma.rb
require_relative "config/environment"

ledger = ENV["LEDGER_FILE"].to_s
abort "Set LEDGER_FILE to the beancount file to serve, e.g. LEDGER_FILE=/path/to/test.beancount" if ledger.empty?
abort "Ledger not found: #{File.expand_path(ledger)}" unless File.file?(ledger)
Rails.application.config.x.ledger_path = File.realpath(ledger)
puts "Serving #{Rails.application.config.x.ledger_path}"

run Rails.application
Rails.application.load_server
