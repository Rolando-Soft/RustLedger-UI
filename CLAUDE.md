# Accounting: local web UI for a beancount ledger

A dependency-free local web app for a plaintext beancount ledger, using the Rust implementation `rledger` (0.24.0).
The user is not a developer by trade, so explain changes plainly. Replies about the user's finances are not licensed advice; say so.

## Files

- `server.py`: Python stdlib HTTP server (`http.server`, `subprocess`). Run `python3 server.py [LEDGER] [--port 8750]`; the ledger defaults to `journal.beancount` next to the script. Python changes need a server restart. Frontend-only changes need only a page refresh.
- `index.html`: the whole UI (CSS and JS inline, vanilla JS). Tabs, in order: Register (default), Add transaction, Accounts, Reconcile.
- `journal.beancount`: test data (not tracked by git). Still change it only through the app or the user's editor.
- `ynab.beancount`: 2.7 MB YNAB import. Read-only; query it with `rledger query`.
- `.backups/`: automatic backup before every write. `.*.cache` and `__pycache__` are generated and safe to delete.

## How the server works

- Reads via `rledger query -f json` (BQL, system tables `#postings`, `#entries`, `#accounts`). Use `rledger check -C` to bypass the cache.
- Every write goes through `commit()`: sha256 hash check (HTTP 409 on conflict), backup, write, `rledger check`, rollback on failure.
- Security: binds to 127.0.0.1, Origin check on POST, regex validation of input, newlines rejected.
- Exceptions: `InputError` (400), `Conflict` (409).

## Features and conventions

- **Transactions:** add, edit and delete (edit opens from a link on the description in Register or Recent; there is no edit button). New transactions default to the `!` pending flag.
- **Posting flags:** per posting, in the file as `? Account` or `* Account`. `?` means ticked in Reconcile but not final; `*` means reconciled. A transaction is promoted from `!` to `*` when all its Assets/Liabilities postings are `*`. The edit form has a per-posting flag select (blank, `?`, `*`; `!` only if already present).
- **Reconcile:** pick an Assets/Liabilities account, a statement end date and ending balance; tick transactions; Save progress writes `?`; Finish writes `*` when the difference is zero; optional `balance` assertion dated the day after the statement end. Filters: period, Hide reconciled, Hide ticked. "+ Add transaction" jumps to the Add form and returns to Reconcile with ticks kept.
- **Register:** filters, running balance, fuzzy account picker, nowrap Date/Amount/Balance columns, ellipsis on Description. Empty descriptions show "(no description)".
- **Accounts:** list with type filter, new-account form. Shared account order everywhere: Assets, Liabilities, Equity, Income, Expenses, then alphabetical.

## Testing

Test against scratch ledgers, never the real one. Put temporary files in the session scratchpad. The fuzzy account picker was only unit-tested in Node, not in a browser.

## Ideas offered, not built

Ledger switcher dropdown; fuzzy picker in the Add form; close-account button.
