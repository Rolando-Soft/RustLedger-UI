ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
ENV["RAILS_ENV"] ||= "production"

# No sessions or cookies are used; Rails still wants a secret, so make a throwaway one per start.
require "securerandom"
ENV["SECRET_KEY_BASE"] ||= SecureRandom.hex(64)

require "bundler/setup"
