//! Brick 4 — the native SQLite backend for the Sigma mirror.
//!
//! Proves the dual-runtime claim: the SAME `stripe_connectrpc::mirror` logic
//! that runs inside the Cloudflare Durable Object runs here over plain rusqlite
//! SQLite — no Durable Object, no CF Queues. `stripe-native backfill [db]`.

use rusqlite::{Connection, ToSql};
use stripe_connectrpc::mirror::{self, SqlExec, SqlValue};

/// Adapts rusqlite to the runtime-agnostic [`SqlExec`] trait — the native twin
/// of the DO's `DoSql`.
pub struct Sqlite(pub Connection);

impl SqlExec for Sqlite {
    fn run(&self, sql: &str, params: &[SqlValue]) -> Result<(), String> {
        let owned: Vec<Box<dyn ToSql>> = params
            .iter()
            .map(|v| -> Box<dyn ToSql> {
                match v {
                    SqlValue::Text(s) => Box::new(s.clone()),
                    SqlValue::Int(n) => Box::new(*n),
                    SqlValue::Real(f) => Box::new(*f),
                    SqlValue::Null => Box::new(Option::<i64>::None),
                }
            })
            .collect();
        let refs: Vec<&dyn ToSql> = owned.iter().map(|b| b.as_ref()).collect();
        self.0
            .execute(sql, refs.as_slice())
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn boxed(s: String) -> Box<dyn std::error::Error> {
    s.into()
}

/// Backfill the mirror from Stripe's REST API into a local SQLite file, then
/// print per-table counts. No Rauthy, no Durable Object — pure native.
pub fn backfill(db_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("STRIPE_SECRET_KEY").map_err(|_| "set STRIPE_SECRET_KEY")?;
    let store = Sqlite(Connection::open(db_path)?);
    mirror::ensure_schema(&store).map_err(boxed)?;
    let now = now_ms();
    let mut total = 0u32;
    for path in mirror::BACKFILL_ENDPOINTS {
        let mut after: Option<String> = None;
        for _ in 0..50 {
            let mut url = format!("https://api.stripe.com{path}?limit=100");
            if let Some(a) = &after {
                url.push_str(&format!("&starting_after={a}"));
            }
            let resp = ureq::get(&url)
                .set("Authorization", &format!("Bearer {key}"))
                .call();
            let body: serde_json::Value = match resp {
                Ok(r) => r.into_json()?,
                Err(_) => break, // resource not enabled / error → skip it
            };
            let data = match body.get("data").and_then(|d| d.as_array()) {
                Some(d) if !d.is_empty() => d.clone(),
                _ => break,
            };
            for obj in &data {
                if mirror::apply_object(&store, obj, now).map_err(boxed)? {
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
    println!("backfilled {total} objects into {db_path}");
    for table in mirror::table_names() {
        let n: i64 = store
            .0
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap_or(0);
        if n > 0 {
            println!("  {table}: {n}");
        }
    }
    Ok(())
}
