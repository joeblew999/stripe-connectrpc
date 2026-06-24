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
use stripe_connectrpc::mirror::{self, SqlExec, SqlValue};
use worker::{
    durable_object, Date, DurableObject, Env, Fetch, Headers, Method, Request, RequestInit,
    Response, Result, SqlStorage, SqlStorageValue, State,
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

/// Adapts the Durable Object's SQLite to the runtime-agnostic `SqlExec` trait,
/// so the shared `mirror` logic runs unchanged on Cloudflare.
struct DoSql(SqlStorage);

impl SqlExec for DoSql {
    fn run(&self, sql: &str, params: &[SqlValue]) -> std::result::Result<(), String> {
        let binds: Vec<SqlStorageValue> = params
            .iter()
            .map(|p| match p {
                SqlValue::Text(s) => SqlStorageValue::from(s.clone()),
                SqlValue::Int(n) => SqlStorageValue::from(*n),
                SqlValue::Real(f) => SqlStorageValue::from(*f),
                SqlValue::Null => SqlStorageValue::Null,
            })
            .collect();
        self.0
            .exec(sql, Some(binds))
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
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

    /// POST /ingest — store a verified event (raw log + typed mirror), then arm
    /// the dispatcher.
    async fn ingest(&self, mut req: Request) -> Result<Response> {
        let ev: ForwardedEvent = req.json().await?;
        let now = Date::now().as_millis() as i64;
        self.ensure_schema()?;
        // Raw event log — INSERT OR IGNORE → idempotent on Stripe's event id
        // (Stripe retries the same id, and so will our own dispatcher).
        self.state.storage().sql().exec(
            "INSERT OR IGNORE INTO events (id, event_type, payload, received_at) \
             VALUES (?, ?, ?, ?)",
            vec![
                ev.id.into(),
                ev.event_type.into(),
                ev.payload.clone().into(),
                now.into(),
            ],
        )?;
        // Typed resource mirror — the SigmaService read/analytics store. Same
        // logic native runs over plain SQLite; here it's the DO's SQLite.
        let store = DoSql(self.state.storage().sql());
        mirror::ensure_schema(&store).map_err(worker::Error::RustError)?;
        mirror::apply_event(&store, &ev.payload, now).map_err(worker::Error::RustError)?;
        // Wake the dispatcher ASAP, unless an alarm is already pending.
        if self.state.storage().get_alarm().await?.is_none() {
            self.state.storage().set_alarm(Duration::from_secs(0)).await?;
        }
        Response::ok("stored")
    }

    /// GET /status — row counts per mirrored table (ops view + the data behind
    /// SigmaService.GetSyncStatus).
    async fn status(&self) -> Result<Response> {
        let store = DoSql(self.state.storage().sql());
        mirror::ensure_schema(&store).map_err(worker::Error::RustError)?;
        let mut counts = serde_json::Map::new();
        for table in mirror::table_names() {
            let rows: Vec<Count> = self
                .state
                .storage()
                .sql()
                .exec(&format!("SELECT count(*) AS c FROM {table}"), None)?
                .to_array()?;
            counts.insert(
                table.to_string(),
                rows.first().map(|c| c.c).unwrap_or(0).into(),
            );
        }
        Response::from_json(&serde_json::Value::Object(counts))
    }

    /// POST /backfill — seed the mirror from Stripe's REST API (ADR-14 brick 2).
    /// Paginates each list endpoint and upserts every object. Synchronous here
    /// (fine for the test account); large accounts would page via alarms.
    async fn backfill(&self) -> Result<Response> {
        let key = self.env.secret("STRIPE_SECRET_KEY")?.to_string();
        let store = DoSql(self.state.storage().sql());
        mirror::ensure_schema(&store).map_err(worker::Error::RustError)?;
        let now = Date::now().as_millis() as i64;
        let mut total = 0u32;
        for path in mirror::BACKFILL_ENDPOINTS {
            let mut after: Option<String> = None;
            for _ in 0..20 {
                let url = match &after {
                    Some(a) => {
                        format!("https://api.stripe.com{path}?limit=100&starting_after={a}")
                    }
                    None => format!("https://api.stripe.com{path}?limit=100"),
                };
                let headers = Headers::new();
                headers.set("Authorization", &format!("Bearer {key}"))?;
                let mut init = RequestInit::new();
                init.with_method(Method::Get).with_headers(headers);
                let req = Request::new_with_init(&url, &init)?;
                let mut resp = Fetch::Request(req).send().await?;
                if resp.status_code() != 200 {
                    break; // resource not enabled on this account — skip it
                }
                let body: serde_json::Value = resp.json().await?;
                let data = match body.get("data").and_then(|d| d.as_array()) {
                    Some(d) if !d.is_empty() => d,
                    _ => break,
                };
                for obj in data {
                    if mirror::apply_object(&store, obj, now).map_err(worker::Error::RustError)? {
                        total += 1;
                    }
                }
                let has_more = body.get("has_more").and_then(|h| h.as_bool()).unwrap_or(false);
                let last = data.last().and_then(|o| o.get("id")).and_then(|i| i.as_str());
                match (has_more, last) {
                    (true, Some(id)) => after = Some(id.to_string()),
                    _ => break,
                }
            }
        }
        Response::from_json(&serde_json::json!({ "backfilled": total }))
    }
}

impl DurableObject for Dispatcher {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        // The Worker tags the forwarded request with `x-sigma-op` (the URL path
        // does not survive the DO stub hop). Default = ingest a verified event.
        let op = req
            .headers()
            .get("x-sigma-op")
            .ok()
            .flatten()
            .unwrap_or_default();
        match op.as_str() {
            "status" => self.status().await,
            "backfill" => self.backfill().await,
            _ => self.ingest(req).await,
        }
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
