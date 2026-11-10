# GET endpoints. Like server.py, reads take no lock.
class ReadsController < ApplicationController
  def register
    render json: Ledger.get_register(ledger)
  end

  def txn
    render json: Ledger.get_transaction(ledger, qs("lineno", 0))
  end

  def reconcile
    render json: Ledger.get_reconcile(ledger, qs("account"), qs("through"))
  end

  def accounts
    render json: Ledger.get_accounts(ledger)
  end

  def payees
    render json: Ledger.get_payees(ledger)
  end

  def recent
    render json: Ledger.get_recent(ledger)
  end

  private

  # Like parse_qs in server.py: a blank value counts as missing.
  def qs(key, default = nil)
    value = request.query_parameters[key]
    value.is_a?(String) && !value.empty? ? value : default
  end
end
