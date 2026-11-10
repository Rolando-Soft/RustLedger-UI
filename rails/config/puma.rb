# Local only: bind to 127.0.0.1, never to all interfaces.
port_number = Integer(ENV.fetch("PORT", "8760"))
bind "tcp://127.0.0.1:#{port_number}"
threads 1, 5
workers 0   # one process: Ledger::LOCK (a Mutex) must see every write, even if WEB_CONCURRENCY is set
environment ENV.fetch("RAILS_ENV", "production")
