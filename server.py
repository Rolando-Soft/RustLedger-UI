#!/usr/bin/env python3
"""Tiny local web UI for adding transactions to a beancount file via rledger.

Usage: python3 server.py [LEDGER] [--port 8750]
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import threading
from datetime import datetime, timedelta
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
LOCK = threading.Lock()

ACCOUNT_RE = re.compile(r"^[A-Z][A-Za-z0-9-]*(:[A-Z0-9][A-Za-z0-9-]*)+$")
AMOUNT_RE = re.compile(r"^-?(\d+(\.\d+)?|\.\d+)$")
CURRENCY_RE = re.compile(r"^[A-Z][A-Z0-9'._-]{0,22}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_/.-]+$")


class InputError(Exception):
    pass


class Conflict(Exception):
    """The file no longer matches what the page was looking at."""


def rledger(*args):
    p = subprocess.run(["rledger", *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def query(ledger, bql):
    code, out = rledger("query", "-f", "json", str(ledger), bql)
    if code != 0:
        raise RuntimeError(out)
    return json.loads(out)["rows"]


def check(ledger):
    return rledger("check", "-C", str(ledger))


def clean_str(value, label):
    value = (value or "").strip()
    if any(c in value for c in "\r\n"):
        raise InputError(f"{label} cannot contain line breaks")
    return value


def quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_entry(data):
    """Validate user input and render a beancount transaction as text."""
    try:
        d = datetime.strptime(str(data.get("date", "")), "%Y-%m-%d").date()
    except ValueError:
        raise InputError("Date must be YYYY-MM-DD")
    flag = data.get("flag", "!")
    if flag not in ("*", "!"):
        raise InputError("Flag must be * or !")
    payee = clean_str(data.get("payee"), "Payee")
    narration = clean_str(data.get("narration"), "Narration")

    tags = []
    for raw, prefix, label in ((data.get("tags"), "#", "Tag"), (data.get("links"), "^", "Link")):
        for t in (raw or "").replace(",", " ").split():
            t = t.lstrip("#^")
            if not TAG_RE.match(t):
                raise InputError(f"Invalid {label.lower()}: {t}")
            tags.append(prefix + t)

    header = f"{d.isoformat()} {flag}"
    if payee:
        header += f" {quote(payee)} {quote(narration)}"
    else:
        header += f" {quote(narration)}"
    if tags:
        header += " " + " ".join(tags)

    postings = [p for p in data.get("postings", []) if (p.get("account") or "").strip()]
    if len(postings) < 2:
        raise InputError("At least two postings are required")
    lines = [header]
    blanks = 0
    for p in postings:
        account = p["account"].strip()
        if not ACCOUNT_RE.match(account):
            raise InputError(f"Invalid account name: {account}")
        pflag = str(p.get("pflag") or "").strip()
        if pflag not in ("", "!", "?", "*"):
            raise InputError("Posting flag must be blank, !, ? or *")
        label = f"{pflag} {account}" if pflag else account
        amount = str(p.get("amount") or "").strip()
        currency = str(p.get("currency") or "USD").strip().upper()
        if not amount:
            blanks += 1
            lines.append(f"  {label}")
            continue
        if not AMOUNT_RE.match(amount):
            raise InputError(f"Invalid amount: {amount}")
        if not CURRENCY_RE.match(currency):
            raise InputError(f"Invalid currency: {currency}")
        lines.append(f"  {label:<48}{amount:>12} {currency}")
    if blanks > 1:
        raise InputError("Only one posting may leave its amount blank")
    return "\n".join(lines) + "\n"


ACCOUNT_TYPES = ["Assets", "Liabilities", "Equity", "Income", "Expenses"]


def format_account(data):
    """Validate input and render an `open` directive."""
    try:
        d = datetime.strptime(str(data.get("date", "")), "%Y-%m-%d").date()
    except ValueError:
        raise InputError("Date must be YYYY-MM-DD")
    account = clean_str(data.get("account"), "Account")
    if not ACCOUNT_RE.match(account) or account.split(":")[0] not in ACCOUNT_TYPES:
        raise InputError("Account must look like Assets:Bank:Checking (type first)")
    currencies = [c.upper() for c in str(data.get("currencies") or "").replace(",", " ").split()]
    for c in currencies:
        if not CURRENCY_RE.match(c):
            raise InputError(f"Invalid currency: {c}")
    line = f"{d.isoformat()} open {account}"
    if currencies:
        line += " " + ",".join(currencies)
    return line + "\n"


def join_append(existing, entry):
    sep = "" if not existing else ("\n" if existing.endswith("\n") else "\n\n")
    return existing + sep + entry


def append_text(path, entry):
    return join_append(path.read_text() if path.exists() else "", entry)


def check_text(ledger, text):
    """Check what the ledger would be with this text, without touching the real file."""
    with tempfile.TemporaryDirectory() as tmp:
        probe = Path(tmp) / ledger.name
        probe.write_text(text)
        return check(probe)


def validate(ledger, entry):
    return check_text(ledger, append_text(ledger, entry))


def commit(ledger, new_text):
    """Write new_text over the ledger with a backup; restore it if rledger rejects the result."""
    code, out = check(ledger)
    if code != 0:
        raise InputError("The ledger already has errors; fix them first:\n" + out)
    backups = ledger.parent / ".backups"
    backups.mkdir(exist_ok=True)
    backup = backups / f"{ledger.name}.{datetime.now():%Y%m%d-%H%M%S-%f}"
    shutil.copy2(ledger, backup)
    ledger.write_text(new_text)
    code, out = check(ledger)
    if code != 0:
        shutil.copy2(backup, ledger)
        raise InputError("Rejected by rledger check (file restored):\n" + out)
    return backup.name


def save(ledger, entry):
    return commit(ledger, append_text(ledger, entry))


def get_accounts(ledger):
    rows = query(ledger, "SELECT account, open, close, currencies FROM #accounts")
    balances = {}
    try:
        for account, pos in query(ledger, "SELECT account, sum(position) GROUP BY account"):
            balances[account] = [
                {"amount": p["number"], "currency": p["currency"]}
                for p in (pos or {}).get("positions", [])
            ]
    except Exception:
        pass  # balances are a nicety; the list still works without them
    return [
        {"account": a, "open": o, "closed": c, "currencies": cur or [], "balance": balances.get(a, [])}
        for a, o, c, cur in sorted(rows)
    ]


def transactions(ledger):
    rows = query(
        ledger,
        "SELECT id, date, flag, payee, narration, account, number, currency FROM #postings",
    )
    heads = {
        tid: ln if Path(fn).resolve() == ledger else None  # included files can't be edited here
        for tid, ln, fn, kind in query(ledger, "SELECT id, lineno, filename, type FROM #entries")
        if kind == "transaction"
    }
    txns = {}
    for tid, d, flag, payee, narration, account, number, currency in rows:
        t = txns.setdefault(
            tid,
            {"date": d, "flag": flag, "payee": payee or "", "narration": narration or "", "postings": [],
             "lineno": heads.get(tid)},
        )
        t["postings"].append({"account": account, "amount": number, "currency": currency})
    return sorted(txns.items(), key=lambda kv: (kv[1]["date"], kv[0]))


def get_payees(ledger):
    """Most recent transaction per payee, for prefill."""
    latest = {}
    for _, t in transactions(ledger):
        if t["payee"]:
            latest[t["payee"]] = t
    return latest


def get_register(ledger):
    """Every transaction in the file, oldest first, with each posting's reconciliation state."""
    heads = {
        tid: ln
        for tid, ln, fn, kind in query(ledger, "SELECT id, lineno, filename, type FROM #entries")
        if kind == "transaction" and Path(fn).resolve() == ledger
    }
    txns = {}
    for r in posting_rows(ledger):
        t = txns.setdefault(r["id"], {
            "lineno": heads.get(r["id"]), "date": r["date"], "flag": r["txn_flag"],
            "payee": r["payee"], "narration": r["narration"], "postings": [],
        })
        t["postings"].append({
            "account": r["account"], "amount": str(r["amount"]), "currency": r["currency"],
            "flag": r["posting_flag"], "state": r["state"],
        })
    return sorted(txns.values(), key=lambda t: (t["date"], t["lineno"] or 0))


def get_recent(ledger, n=5):
    return [t for _, t in transactions(ledger)][-n:][::-1]


# ---- reconciliation: flags on individual postings ----
# State of a posting: `*` cleared, `?` marked (ticked off, not final), otherwise pending.
# A transaction-level `*` counts as cleared for postings with no flag of their own.

POSTING_RE = re.compile(r"^(\s+)(?:([*!?])\s+)?([A-Z]\S*)(.*)$")
HEADER_RE = re.compile(r"^(\d{4}-\d\d-\d\d\s+)!(\s)")
BALANCE_SHEET = ("Assets:", "Liabilities:")


def file_hash(ledger):
    return hashlib.sha256(ledger.read_bytes()).hexdigest()


def require_hash(ledger, data):
    if data.get("hash") != file_hash(ledger):
        raise Conflict("The ledger changed on disk since this page loaded. Reload the list and try again.")


def posting_rows(ledger):
    rows = query(
        ledger,
        "SELECT id, lineno, filename, date, flag, payee, narration, posting_flag, account, number, currency FROM #postings",
    )
    out = []
    for tid, lineno, fn, d, flag, payee, narration, pflag, account, number, currency in rows:
        if Path(fn).resolve() != ledger:
            continue  # postings from included files are read-only here
        eff = pflag or ("*" if flag == "*" else None)
        out.append({
            "id": tid, "lineno": lineno, "date": d, "txn_flag": flag, "payee": payee or "",
            "narration": narration or "", "posting_flag": pflag, "account": account,
            "amount": Decimal(number), "currency": currency,
            "state": {"*": "cleared", "?": "marked"}.get(eff, "pending"),
        })
    return out


def parse_account(value):
    account = clean_str(value, "Account")
    if not ACCOUNT_RE.match(account) or not account.startswith(BALANCE_SHEET):
        raise InputError("Choose an Assets or Liabilities account")
    return account


def parse_date(value):
    try:
        return datetime.strptime(str(value), "%Y-%m-%d").date().isoformat()
    except ValueError:
        raise InputError("Date must be YYYY-MM-DD")


def get_reconcile(ledger, account, through):
    account, through = parse_account(account), parse_date(through)
    all_rows = posting_rows(ledger)
    others = {}
    for r in all_rows:
        others.setdefault(r["id"], []).append(r["account"])
    rows = [r for r in all_rows if r["account"] == account and r["date"] <= through]
    currencies = sorted({r["currency"] for r in rows})
    currency = currencies[0] if currencies else "USD"
    rows = [r for r in rows if r["currency"] == currency]
    rows.sort(key=lambda r: (r["date"], r["lineno"]))
    return {
        "hash": file_hash(ledger),
        "currency": currency,
        "ignored_currencies": currencies[1:],
        "cleared": str(sum((r["amount"] for r in rows if r["state"] == "cleared"), Decimal(0))),
        "rows": [
            {
                "lineno": r["lineno"], "date": r["date"], "payee": r["payee"], "narration": r["narration"],
                "amount": str(r["amount"]), "state": r["state"],
                "locked": r["state"] == "cleared",
                "posting_flag": r["posting_flag"],
                "other": [a for a in others[r["id"]] if a != account],
            }
            for r in rows
        ],
    }


def set_posting_flag(lines, lineno, account, expect, to):
    """Change one posting line's own flag (None, '?' or '*'), keeping amount columns aligned."""
    i = lineno - 1
    m = POSTING_RE.match(lines[i]) if 0 <= i < len(lines) else None
    if not m or m.group(3) != account or (m.group(2) or None) != expect:
        raise Conflict(f"Line {lineno} no longer matches {account}. Reload the list and try again.")
    indent, _, acct, rest = m.groups()
    cur = m.group(2)
    if (to or None) == (cur or None):
        return
    gap = re.match(r"^(\s+)(\S.*)$", rest)  # whitespace before the amount, then the amount
    if to and not cur:
        if gap and len(gap.group(1)) >= 4:
            rest = gap.group(1)[2:] + gap.group(2)
        lines[i] = f"{indent}{to} {acct}{rest}"
    elif cur and not to:
        if gap:
            rest = "  " + gap.group(1) + gap.group(2)
        lines[i] = f"{indent}{acct}{rest}"
    else:
        lines[i] = f"{indent}{to} {acct}{rest}"


def reconcile_save(ledger, data):
    require_hash(ledger, data)
    account = parse_account(data.get("account"))
    if not data.get("changes"):
        return {"ok": True, "backup": None, "hash": file_hash(ledger)}
    lines = ledger.read_text().split("\n")
    for c in data.get("changes", []):
        frm, to = c.get("from") or None, c.get("to") or None
        if frm not in (None, "?") or to not in (None, "?"):
            raise InputError("Saving progress can only add or remove the ? mark")
        set_posting_flag(lines, int(c["lineno"]), account, frm, to)
    backup = commit(ledger, "\n".join(lines))
    return {"ok": True, "backup": backup, "hash": file_hash(ledger)}


def reconcile_finish(ledger, data):
    require_hash(ledger, data)
    account = parse_account(data.get("account"))
    through = parse_date(data.get("through"))
    statement = str(data.get("statement", "")).strip()
    if not AMOUNT_RE.match(statement):
        raise InputError("Enter the statement ending balance")
    statement = Decimal(statement)
    currency = str(data.get("currency") or "USD")
    if not CURRENCY_RE.match(currency):
        raise InputError(f"Invalid currency: {currency}")

    every = posting_rows(ledger)
    rows = [r for r in every if r["account"] == account and r["date"] <= through and r["currency"] == currency]
    marked = [r for r in rows if r["state"] == "marked"]
    pending = [r for r in rows if r["state"] == "pending"]
    total = sum((r["amount"] for r in rows if r["state"] != "pending"), Decimal(0))
    if not marked:
        raise InputError("Nothing is marked to reconcile")
    if total != statement:
        raise InputError(f"Cleared + marked is {total}, statement is {statement} (difference {statement - total})")
    add_balance = bool(data.get("balance_assertion"))
    if add_balance and pending:
        raise InputError("A balance assertion needs every transaction through the statement date to be marked")

    lines = ledger.read_text().split("\n")
    for r in marked:
        set_posting_flag(lines, r["lineno"], account, r["posting_flag"], "*")

    # A pending (`!`) transaction becomes `*` once every Assets/Liabilities posting in it is cleared.
    done = {r["lineno"] for r in marked}
    headers = {tid: ln for tid, ln, kind in query(ledger, "SELECT id, lineno, type FROM #entries") if kind == "transaction"}
    promoted = 0
    for tid in {r["id"] for r in marked}:
        sheet = [r for r in every if r["id"] == tid and r["account"].startswith(BALANCE_SHEET)]
        if all(r["state"] == "cleared" or r["lineno"] in done for r in sheet):
            i = headers[tid] - 1
            m = HEADER_RE.match(lines[i])
            if m:
                lines[i] = HEADER_RE.sub(r"\g<1>*\g<2>", lines[i], count=1)
                promoted += 1

    text = "\n".join(lines)
    if add_balance:
        day = (datetime.strptime(through, "%Y-%m-%d") + timedelta(days=1)).date().isoformat()
        text = join_append(text, f"{day} balance {account}  {statement} {currency}\n")
    backup = commit(ledger, text)
    return {"ok": True, "backup": backup, "hash": file_hash(ledger), "reconciled": len(marked), "promoted": promoted}


# ---- editing and deleting existing transactions ----

STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
HDR_RE = re.compile(r"^(\d{4}-\d\d-\d\d)\s+(\*|!|\?|txn|[A-Z])\s+(.*)$")
POSTING_FULL_RE = re.compile(
    r"^(\s+)(?:([*!?])\s+)?([A-Z][A-Za-z0-9:-]*)(?:\s+(-?(?:\d+(?:\.\d*)?|\.\d+))\s+([A-Z][A-Z0-9'._-]*))?\s*$"
)
META_RE = re.compile(r"^\s+[a-z][A-Za-z0-9_-]*:")
COMMENT_RE = re.compile(r"^\s+;")


def parse_txn(lines, header_lineno):
    """Locate a transaction block and split it into form fields plus lines we must keep as they are."""
    start = header_lineno - 1
    m = HDR_RE.match(lines[start]) if 0 <= start < len(lines) else None
    if not m:
        raise Conflict(f"Line {header_lineno} is not a transaction any more. Reload and try again.")
    end = start + 1
    while end < len(lines) and lines[end].strip() and lines[end][0] in " \t":
        end += 1
    t = {"start": start, "end": end, "reason": None, "postings": [], "head_extras": []}

    flag, rest = m.group(2), m.group(3)
    strings = [re.sub(r"\\(.)", r"\1", x) for x in STR_RE.findall(rest)]
    remainder = STR_RE.sub("", rest)
    tags = re.findall(r"#([A-Za-z0-9_/.-]+)", remainder)
    links = re.findall(r"\^([A-Za-z0-9_/.-]+)", remainder)
    leftover = re.sub(r"[#^][A-Za-z0-9_/.-]+", "", remainder).strip()
    if flag == "txn":
        flag = "*"
    if flag not in ("*", "!"):
        t["reason"] = f"flag {flag} is not supported by the form"
    elif leftover or len(strings) > 2:
        t["reason"] = "the first line has parts the form can't represent (comment or extra text)"
    t.update({
        "date": m.group(1), "flag": flag, "tags": " ".join(tags), "links": " ".join(links),
        "payee": strings[0] if len(strings) == 2 else "", "narration": strings[-1] if strings else "",
    })

    for line in lines[start + 1:end]:
        if COMMENT_RE.match(line) or META_RE.match(line):
            (t["postings"][-1]["extras"] if t["postings"] else t["head_extras"]).append(line)
            continue
        pm = POSTING_FULL_RE.match(line)
        if not pm:
            t["reason"] = t["reason"] or f"this line isn't a plain posting: {line.strip()}"
            continue
        t["postings"].append({
            "orig": len(t["postings"]), "flag": pm.group(2), "account": pm.group(3),
            "amount": pm.group(4) or "", "currency": pm.group(5) or "", "extras": [],
        })
    return t


def get_transaction(ledger, lineno):
    t = parse_txn(ledger.read_text().split("\n"), int(lineno))
    return {
        "hash": file_hash(ledger), "lineno": int(lineno), "editable": t["reason"] is None, "reason": t["reason"],
        **{k: t[k] for k in ("date", "flag", "payee", "narration", "tags", "links")},
        "postings": [{k: p[k] for k in ("orig", "flag", "account", "amount", "currency")} for p in t["postings"]],
    }


def build_edit(ledger, data):
    require_hash(ledger, data)
    lines = ledger.read_text().split("\n")
    t = parse_txn(lines, int(data.get("lineno", 0)))
    if t["reason"]:
        raise InputError("This transaction can't be edited here: " + t["reason"])
    entry = format_entry(data)
    rendered = entry.rstrip("\n").split("\n")
    posts = [p for p in data["postings"] if (p.get("account") or "").strip()]
    out, seen = rendered[:1] + t["head_extras"], set()
    for p, line in zip(posts, rendered[1:]):
        orig = None
        if p.get("orig") is not None:
            o = p["orig"]
            if not isinstance(o, int) or not 0 <= o < len(t["postings"]) or o in seen:
                raise Conflict("The postings no longer match the file. Reload and try again.")
            seen.add(o)
            orig = t["postings"][o]
        out.append(line)
        if orig:
            out.extend(orig["extras"])
    for i, op in enumerate(t["postings"]):
        if i not in seen and op["extras"]:
            raise InputError(f"The posting for {op['account']} has comments or metadata; remove it in your editor instead")
    lines[t["start"]:t["end"]] = out
    return "\n".join(lines), entry


def txn_edit(ledger, data):
    text, entry = build_edit(ledger, data)
    backup = commit(ledger, text)
    return {"ok": True, "text": entry, "backup": backup, "hash": file_hash(ledger)}


def txn_edit_validate(ledger, data):
    text, entry = build_edit(ledger, data)
    code, out = check_text(ledger, text)
    return {"text": entry, "ok": code == 0, "message": out}


def txn_delete(ledger, data):
    require_hash(ledger, data)
    lines = ledger.read_text().split("\n")
    t = parse_txn(lines, int(data.get("lineno", 0)))
    del lines[t["start"]:t["end"]]
    i = t["start"]
    if i < len(lines) and not lines[i].strip() and (i == 0 or not lines[i - 1].strip()):
        del lines[i]  # don't leave a double blank line behind
    backup = commit(ledger, "\n".join(lines))
    return {"ok": True, "backup": backup, "hash": file_hash(ledger)}


class Handler(BaseHTTPRequestHandler):
    ledger: Path

    def log_message(self, fmt, *args):
        pass

    def send(self, status, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        url = urlparse(self.path)
        qs = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/api/register":
                return self.send(200, get_register(self.ledger))
            if url.path == "/api/transaction":
                return self.send(200, get_transaction(self.ledger, qs.get("lineno", 0)))
            if url.path == "/api/reconcile":
                return self.send(200, get_reconcile(self.ledger, qs.get("account"), qs.get("through")))
            if self.path in ("/", "/index.html"):
                return self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
            if self.path == "/api/accounts":
                return self.send(200, get_accounts(self.ledger))
            if self.path == "/api/payees":
                return self.send(200, get_payees(self.ledger))
            if self.path == "/api/recent":
                return self.send(200, get_recent(self.ledger))
            self.send(404, {"error": "not found"})
        except Conflict as e:
            self.send(409, {"error": str(e)})
        except InputError as e:
            self.send(400, {"error": str(e)})
        except Exception as e:
            self.send(500, {"error": str(e)})

    def do_POST(self):
        routes = {
            "/api/validate": (format_entry, True),
            "/api/transactions": (format_entry, False),
            "/api/accounts/validate": (format_account, True),
            "/api/accounts": (format_account, False),
        }
        actions = {
            "/api/reconcile/save": reconcile_save,
            "/api/reconcile/finish": reconcile_finish,
            "/api/transactions/edit": txn_edit,
            "/api/transactions/edit/validate": txn_edit_validate,
            "/api/transactions/delete": txn_delete,
        }
        if self.path not in routes and self.path not in actions:
            return self.send(404, {"error": "not found"})
        # Reject cross-site requests: only the page we serve may post.
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin")
        if origin and origin.split("://", 1)[-1] != host:
            return self.send(403, {"error": "forbidden origin"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
            if self.path in actions:
                with LOCK:
                    return self.send(200, actions[self.path](self.ledger, data))
            formatter, dry_run = routes[self.path]
            entry = formatter(data)
            with LOCK:
                if dry_run:
                    code, out = validate(self.ledger, entry)
                    return self.send(200, {"text": entry, "ok": code == 0, "message": out})
                backup = save(self.ledger, entry)
            self.send(200, {"text": entry, "ok": True, "backup": backup})
        except Conflict as e:
            self.send(409, {"error": str(e)})
        except InputError as e:
            self.send(400, {"error": str(e)})
        except Exception as e:
            self.send(500, {"error": str(e)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ledger", nargs="?", default=str(HERE / "journal.beancount"))
    ap.add_argument("--port", type=int, default=8750)
    args = ap.parse_args()
    Handler.ledger = Path(args.ledger).resolve()
    if not Handler.ledger.exists():
        raise SystemExit(f"Ledger not found: {Handler.ledger}")
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Serving {Handler.ledger} at http://127.0.0.1:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
