# Report pages (read-only, Tailwind). A bad date or name shows a plain message with status 400.
class ReportsController < ActionController::Base
  layout "application"

  # Declared first so the InputError handler below wins for bad input.
  rescue_from StandardError do |e|
    @error = "Something went wrong while making this report: #{e.message}"
    render "reports/error", status: 500
  end

  rescue_from Ledger::InputError do |e|
    @error = e.message
    render "reports/error", status: 400
  end

  def index
    redirect_to "/reports/income-statement"
  end

  def income_statement
    @r = Ledger.income_statement(ledger, params[:from], params[:to])
  end

  def balance_sheet
    @r = Ledger.balance_sheet(ledger, params[:to])
  end

  def trial_balance
    @r = Ledger.trial_balance(ledger, params[:from], params[:to])
  end

  def journal
    @r = Ledger.journal(ledger, params[:type], params[:page])
  end

  def account
    @r = Ledger.account_report(ledger, params[:name], params[:from], params[:to])
  end

  def statistics
    @r = Ledger.statistics(ledger)
  end

  def error_list
    @r = Ledger.check_errors(ledger)
  end

  def events
    @r = Ledger.events(ledger, params[:from], params[:to])
  end

  def commodities
    @r = Ledger.commodities(ledger, params[:from], params[:to])
  end

  private

  def ledger
    Rails.application.config.x.ledger_path or raise "LEDGER_FILE is not set (start the app with config.ru)"
  end
end
