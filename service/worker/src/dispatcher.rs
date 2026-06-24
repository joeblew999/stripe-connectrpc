//! The webhook DISPATCHER Durable Object.
//!
//! A stateless Worker can't own retry timers or a durable dead-letter, so the
//! dispatcher is a DO. It:
//!   1. durably stores every verified Stripe event in SQLite (`events`) — the
//!      event log, which doubles as the queryable read/analytics store (the
//!      thing opensigma exists to provide);
//!   2. fans each event out to the configured consumers over HTTP;
//!   3. retries failures via an alarm with backoff;
//!   4. dead-letters events that exhaust `MAX_ATTEMPTS` (kept in the log,
//!      `dispatched = 2`, for inspection).
//!
//! Consumers come from the `CONSUMER_URLS` var (comma-separated). No consumers
//! configured = nothing to deliver = the event is just logged (analytics).

use std::time::Duration;

use serde::Deserialize;
use worker::{
    durable_object, Date, DurableObject, Env, Fetch, Method, Request, RequestInit, Response,
    Result, State,
};

/// Give up (dead-letter) after this many failed delivery rounds.
const MAX_ATTEMPTS: i64 = 5;
/// Backoff between retry rounds while events remain pending.
const RETRY_BACKOFF: Duration = Duration::from_secs(30);

#[durable_object]
pub struct Dispatcher {
    state: State,
    env: Env,
}

/// What the Worker forwards after verifying the webhook signature.
#[derive(Deserialize)]
struct ForwardedEvent {
    id: String,
    event_type: String,
    payload: String,
}

/// A pending row read back for delivery.
#[derive(Deserialize)]
struct EventRow {
    id: String,
    payload: String,
    attempts: i64,
}

#[derive(Deserialize)]
struct Count {
    c: i64,
}

impl Dispatcher {
    fn ensure_schema(&self) -> Result<()> {
        // dispatched: 0 = pending, 1 = delivered, 2 = dead-lettered.
        self.state.storage().sql().exec(
            "CREATE TABLE IF NOT EXISTS events (\
                 id TEXT PRIMARY KEY, \
                 event_type TEXT NOT NULL, \
                 payload TEXT NOT NULL, \
                 received_at INTEGER NOT NULL, \
                 attempts INTEGER NOT NULL DEFAULT 0, \
                 dispatched INTEGER NOT NULL DEFAULT 0)",
            None,
        )?;
        Ok(())
    }

    fn consumers(&self) -> Vec<String> {
        self.env
            .var("CONSUMER_URLS")
            .map(|v| v.to_string())
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    }

    /// POST a payload to one consumer; returns true on a 2xx.
    async fn deliver(url: &str, payload: &str) -> bool {
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_body(Some(payload.to_string().into()));
        match Request::new_with_init(url, &init) {
            Ok(req) => matches!(
                Fetch::Request(req).send().await,
                Ok(resp) if resp.status_code() < 300
            ),
            Err(_) => false,
        }
    }
}

impl DurableObject for Dispatcher {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let ev: ForwardedEvent = req.json().await?;
        self.ensure_schema()?;
        // INSERT OR IGNORE → idempotent on Stripe's event id (Stripe retries the
        // same id, and so will our own dispatcher).
        self.state.storage().sql().exec(
            "INSERT OR IGNORE INTO events (id, event_type, payload, received_at) \
             VALUES (?, ?, ?, ?)",
            vec![
                ev.id.into(),
                ev.event_type.into(),
                ev.payload.into(),
                (Date::now().as_millis() as i64).into(),
            ],
        )?;
        // Wake the dispatcher ASAP, unless an alarm is already pending.
        if self.state.storage().get_alarm().await?.is_none() {
            self.state.storage().set_alarm(Duration::from_secs(0)).await?;
        }
        Response::ok("stored")
    }

    async fn alarm(&self) -> Result<Response> {
        self.ensure_schema()?;
        let consumers = self.consumers();

        let rows: Vec<EventRow> = self
            .state
            .storage()
            .sql()
            .exec(
                "SELECT id, payload, attempts FROM events \
                 WHERE dispatched = 0 ORDER BY received_at LIMIT 20",
                None,
            )?
            .to_array()?;

        for row in rows {
            // Empty consumer set = nothing to deliver = treat as delivered (the
            // event is logged for analytics).
            let mut delivered = true;
            for url in &consumers {
                if !Self::deliver(url, &row.payload).await {
                    delivered = false;
                }
            }
            let sql = self.state.storage().sql();
            if delivered {
                sql.exec("UPDATE events SET dispatched = 1 WHERE id = ?", vec![row.id.into()])?;
            } else {
                let attempts = row.attempts + 1;
                let dispatched = if attempts >= MAX_ATTEMPTS { 2 } else { 0 };
                sql.exec(
                    "UPDATE events SET attempts = ?, dispatched = ? WHERE id = ?",
                    vec![attempts.into(), (dispatched as i64).into(), row.id.into()],
                )?;
            }
        }

        // Anything still pending → reschedule with backoff.
        let pending: Vec<Count> = self
            .state
            .storage()
            .sql()
            .exec("SELECT COUNT(*) AS c FROM events WHERE dispatched = 0", None)?
            .to_array()?;
        if pending.first().map(|p| p.c).unwrap_or(0) > 0 {
            self.state.storage().set_alarm(RETRY_BACKOFF).await?;
        }
        Response::ok("dispatched")
    }
}
