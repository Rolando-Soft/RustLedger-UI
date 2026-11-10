# JSON twins of the report pages (same data the pages show). Errors map as in ApplicationController.
class ReportsApiController < ApplicationController
  def income_statement
    render json: Ledger.income_statement(ledger, qs("from"), qs("to"))
  end

  def balance_sheet
    render json: Ledger.balance_sheet(ledger, qs("to"))
  end

  def trial_balance
    render json: Ledger.trial_balance(ledger, qs("from"), qs("to"))
  end

  def journal
    render json: Ledger.journal(ledger, qs("type"), qs("page"))
  end

  def account
    render json: Ledger.account_report(ledger, params[:name], qs("from"), qs("to"))
  end

  def statistics
    render json: Ledger.statistics(ledger)
  end

  def error_list
    render json: Ledger.check_errors(ledger)
  end

  def events
    render json: Ledger.events(ledger, qs("from"), qs("to"))
  end

  def commodities
    render json: Ledger.commodities(ledger, qs("from"), qs("to"))
  end

  private

  def qs(key)
    value = request.query_parameters[key]
    value.is_a?(String) && !value.empty? ? value : nil
  end
end
