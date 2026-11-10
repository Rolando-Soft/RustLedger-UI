# JSON API base: maps errors exactly like server.py (InputError 400, Conflict 409, anything else 500).
class ApplicationController < ActionController::API
  rescue_from StandardError do |e|
    render json: { error: e.message }, status: 500
  end
  rescue_from Ledger::InputError do |e|
    render json: { error: e.message }, status: 400
  end
  rescue_from Ledger::Conflict do |e|
    render json: { error: e.message }, status: 409
  end

  def not_found
    render json: { error: "not found" }, status: 404
  end

  private

  def ledger
    Rails.application.config.x.ledger_path or raise "LEDGER_FILE is not set (start the app with config.ru)"
  end
end
