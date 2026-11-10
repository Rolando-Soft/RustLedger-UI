Rails.application.routes.draw do
  get "/", to: "pages#index"
  get "/index.html", to: "pages#index", format: false

  get "/api/register", to: "reads#register"
  get "/api/transaction", to: "reads#txn"
  get "/api/reconcile", to: "reads#reconcile"
  get "/api/accounts", to: "reads#accounts"
  get "/api/payees", to: "reads#payees"
  get "/api/recent", to: "reads#recent"

  post "/api/validate", to: "writes#validate_entry"
  post "/api/transactions", to: "writes#add_transaction"
  post "/api/accounts/validate", to: "writes#validate_account"
  post "/api/accounts", to: "writes#add_account"
  post "/api/reconcile/save", to: "writes#reconcile_save"
  post "/api/reconcile/finish", to: "writes#reconcile_finish"
  post "/api/transactions/edit", to: "writes#txn_edit"
  post "/api/transactions/edit/validate", to: "writes#txn_edit_validate"
  post "/api/transactions/delete", to: "writes#txn_delete"
  post "/api/accounts/delete/validate", to: "writes#account_delete_validate"
  post "/api/accounts/delete", to: "writes#account_delete"
  post "/api/accounts/close", to: "writes#account_close"
  post "/api/accounts/edit/validate", to: "writes#account_edit_validate"
  post "/api/accounts/edit", to: "writes#account_edit"

  # Reports (read-only pages) and their JSON twins.
  get "/reports", to: "reports#index"
  get "/reports/income-statement", to: "reports#income_statement"
  get "/reports/balance-sheet", to: "reports#balance_sheet"
  get "/reports/trial-balance", to: "reports#trial_balance"
  get "/reports/journal", to: "reports#journal"
  get "/reports/account/:name", to: "reports#account", constraints: { name: %r{[^/]+} }, format: false
  get "/reports/statistics", to: "reports#statistics"
  get "/reports/errors", to: "reports#error_list"
  get "/reports/events", to: "reports#events"
  get "/reports/commodities", to: "reports#commodities"

  get "/api/reports/income-statement", to: "reports_api#income_statement"
  get "/api/reports/balance-sheet", to: "reports_api#balance_sheet"
  get "/api/reports/trial-balance", to: "reports_api#trial_balance"
  get "/api/reports/journal", to: "reports_api#journal"
  get "/api/reports/account/:name", to: "reports_api#account", constraints: { name: %r{[^/]+} }, format: false
  get "/api/reports/statistics", to: "reports_api#statistics"
  get "/api/reports/errors", to: "reports_api#error_list"
  get "/api/reports/events", to: "reports_api#events"
  get "/api/reports/commodities", to: "reports_api#commodities"

  match "*path", to: "application#not_found", via: :all, format: false
end
