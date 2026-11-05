# RustLedger-UI

A small local web app for viewing and editing a plaintext [beancount](https://beancount.github.io/docs/) ledger. It uses [`rledger`](https://github.com/rustledger/rustledger), the Rust implementation of beancount, to read and validate the ledger.

There is nothing to install besides Python 3 and `rledger`. The server uses only the Python standard library, and the interface is a single HTML file.

> This is a personal project. It is not financial, tax or accounting advice.

## Features

- **Register:** browse transactions with filters, a running balance and a fuzzy account picker.
- **Add transaction:** new transactions start with the `!` (pending) flag.
- **Edit and delete:** click a transaction's description to edit it.
- **Accounts:** list accounts, filter by type, and open new ones.
- **Reconcile:** pick an account, a statement end date and an ending balance, then tick off transactions until the difference is zero. Progress can be saved and finished later.

## Requirements

- Python 3
- [`rledger`](https://github.com/rustledger/rustledger) 0.24.0 on your `PATH`

## Run it

```sh
python3 server.py path/to/your.beancount
```

Then open <http://127.0.0.1:8750> in your browser.

- If you leave out the ledger path, it uses `journal.beancount` next to `server.py`.
- Use `--port 9000` to change the port.
- After changing `server.py`, restart the server. For changes to `index.html`, refresh the page.

## How it keeps your ledger safe

Every change goes through one routine that:

1. Checks the file hasn't changed since the page loaded. If it has, the save is refused.
2. Saves a backup copy in `.backups/`.
3. Writes the change.
4. Runs `rledger check`. If the ledger is no longer valid, it restores the backup.

The server only listens on `127.0.0.1` (your own computer), rejects requests from other web pages, and validates all input.

## Reconcile flags

Each posting can carry a flag in the file:

| Flag | Meaning                        |
| ---- | ------------------------------ |
| `?`  | Ticked in Reconcile, not final |
| `*`  | Reconciled                     |

A transaction changes from `!` to `*` once all its Assets and Liabilities postings are `*`.

## Notes

- Your ledger is your own data. Keep it backed up and try changes on a copy first.
