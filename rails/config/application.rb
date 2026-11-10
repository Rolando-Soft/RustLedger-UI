require_relative "boot"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"
require "tailwindcss-rails"

require_relative "../lib/ledger"

module LedgerRails
  class Application < Rails::Application
    config.load_defaults 8.1
    # Serve app/assets (the built Tailwind CSS) straight from the app; no precompile step.
    config.assets.server = true
    config.eager_load = true
    config.enable_reloading = false
    config.consider_all_requests_local = false

    # Only answer requests addressed to this machine (also blocks DNS-rebinding attacks).
    config.hosts = ["127.0.0.1", "localhost"]

    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :warn
  end
end
