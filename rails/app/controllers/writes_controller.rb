# POST endpoints. Every write ends in Ledger.commit (Ledger::Commit), under Ledger::LOCK.
class WritesController < ApplicationController
  before_action :check_origin

  def validate_entry
    dry_run(Ledger.format_entry(body))
  end

  def add_transaction
    save_entry(Ledger.format_entry(body))
  end

  def validate_account
    dry_run(Ledger.format_account(body))
  end

  def add_account
    save_entry(Ledger.format_account(body))
  end

  def reconcile_save = run_action(:reconcile_save)
  def reconcile_finish = run_action(:reconcile_finish)
  def txn_edit = run_action(:txn_edit)
  def txn_edit_validate = run_action(:txn_edit_validate)
  def txn_delete = run_action(:txn_delete)
  def account_delete_validate = run_action(:account_delete_validate)
  def account_delete = run_action(:account_delete)
  def account_close = run_action(:account_close)
  def account_edit_validate = run_action(:account_edit_validate)
  def account_edit = run_action(:account_edit)

  private

  # Reject cross-site requests: only the page we serve may post (same rule as server.py).
  def check_origin
    origin = request.get_header("HTTP_ORIGIN")
    return if origin.nil? || origin.empty?
    head, sep, tail = origin.partition("://")
    target = sep.empty? ? head : tail
    render json: { error: "forbidden origin" }, status: 403 if target != request.get_header("HTTP_HOST").to_s
  end

  def body
    @body ||= begin
      raw = request.raw_post.to_s
      data = JSON.parse(raw.empty? ? "{}" : raw)
      raise Ledger::InputError, "The request must be a JSON object" unless data.is_a?(Hash)
      data
    end
  end

  def dry_run(entry)
    code, out = Ledger.locked { Ledger.validate(ledger, entry) }
    render json: { text: entry, ok: code == 0, message: out }
  end

  def save_entry(entry)
    backup = Ledger.locked { Ledger.save(ledger, entry) }
    render json: { text: entry, ok: true, backup: backup }
  end

  def run_action(name)
    data = body
    render json: Ledger.locked { Ledger.public_send(name, ledger, data) }
  end
end
