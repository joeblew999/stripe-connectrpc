//! Brick 4 — the native SQLite backend for the Sigma mirror.
//!
//! Proves the dual-runtime claim: the SAME `stripe_connectrpc::mirror` logic
//! that runs inside the Cloudflare Durable Object runs here over plain rusqlite
//! SQLite — no Durable Object, no CF Queues. `stripe-native backfill [db]`.

use std::sync::Mutex;

use rusqlite::{Connection, ToSql};
use stripe_connectrpc::mirror::{self, SqlExec, SqlValue};
use stripe_connectrpc::{QueryResult, SigmaStore};

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

/// The native read backend for `SigmaService` — plain rusqlite. The twin of the
/// worker's DoStore; both satisfy `stripe_connectrpc::SigmaStore`. `Mutex` makes
/// it `Sync` (and the futures `Send`) — fine for a read store.
pub struct SqliteStore(pub Mutex<Connection>);

impl SqliteStore {
    pub fn open(db_path: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self(Mutex::new(Connection::open(db_path)?)))
    }
}

fn value_to_string(v: &rusqlite::types::Value) -> String {
    use rusqlite::types::Value;
    match v {
        Value::Null => String::new(),
        Value::Integer(i) => i.to_string(),
        Value::Real(f) => f.to_string(),
        Value::Text(s) => s.clone(),
        Value::Blob(_) => "<blob>".to_string(),
    }
}

impl SigmaStore for SqliteStore {
    async fn query(&self, sql: &str, limit: u32) -> Result<QueryResult, String> {
        let conn = self.0.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
        let columns: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let n = columns.len();
        let mut cursor = stmt.query([]).map_err(|e| e.to_string())?;
        let mut rows = Vec::new();
        while let Some(row) = cursor.next().map_err(|e| e.to_string())? {
            let mut cells = Vec::with_capacity(n);
            for i in 0..n {
                let v: rusqlite::types::Value = row.get(i).map_err(|e| e.to_string())?;
                cells.push(value_to_string(&v));
            }
            rows.push(cells);
            if rows.len() >= limit as usize {
                break;
            }
        }
        Ok(QueryResult { columns, rows })
    }

    async fn counts(&self) -> Result<Vec<(String, i64)>, String> {
        let conn = self.0.lock().map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for table in mirror::table_names() {
            let c: i64 = conn
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap_or(0);
            out.push((table.to_string(), c));
        }
        Ok(out)
    }
}

/// `stripe-native query <db> <sql>` — run a read-only query through the native
/// SigmaStore and print it. Proves the RunQuery path on real mirror data, no
/// Rauthy, no Durable Object.
pub async fn query_cli(db_path: &str, sql: &str) -> Result<(), Box<dyn std::error::Error>> {
    if !stripe_connectrpc::is_read_only(sql) {
        return Err("only a single read-only SELECT/WITH is allowed".into());
    }
    let store = SqliteStore::open(db_path)?;
    let res = store.query(sql, 50).await.map_err(boxed)?;
    println!("{}", res.columns.join(" | "));
    println!("{}", "-".repeat(res.columns.join(" | ").len().max(3)));
    for row in &res.rows {
        println!("{}", row.join(" | "));
    }
    println!("({} rows)", res.rows.len());
    Ok(())
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
