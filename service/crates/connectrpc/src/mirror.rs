//! The Stripe → SQLite mirror (ADR-14, brick 1) — runtime-agnostic.
//!
//! This is the read/analytics store behind [`SigmaService`](crate). It mirrors
//! Stripe resource objects into typed SQLite tables (one per resource), so the
//! account is queryable locally — our own Stripe Sigma / Data Pipeline.
//!
//! It is deliberately **runtime-agnostic**: the logic here (the resource
//! registry, schema, and upserts) speaks only to the [`SqlExec`] trait. The
//! Cloudflare backend (the Dispatcher Durable Object, `state.storage().sql()`)
//! and the native backend (plain SQLite via rusqlite) each implement `SqlExec`;
//! the SQL ports unchanged. No Cloudflare-only dependency, no CF Queues.
//!
//! Each table is `id` + a few hot, indexed columns (the fields you JOIN /
//! filter / aggregate on) + `data` (the full resource JSON). Anything not given
//! a hot column is still queryable via SQLite's `json_extract(data, '$.field')`,
//! so we get opensigma-style coverage without hand-maintaining ~200 columns.

use serde_json::Value;

/// A neutral SQL bind value — each backend converts to its own representation
/// (`SqlStorageValue` on the DO, rusqlite params natively).
#[derive(Debug, Clone)]
pub enum SqlValue {
    Text(String),
    Int(i64),
    Real(f64),
    Null,
}

/// The one thing the mirror needs from a runtime: execute a parameterized
/// statement. Counts/queries for `SigmaService` extend this later.
pub trait SqlExec {
    fn run(&self, sql: &str, params: &[SqlValue]) -> Result<(), String>;
}

#[derive(Clone, Copy)]
enum ColKind {
    Text,
    Int,
}

#[derive(Clone, Copy)]
struct Column {
    /// SQLite column name.
    name: &'static str,
    /// Dotted JSON path into the resource object, e.g. `"recurring.interval"`.
    path: &'static str,
    kind: ColKind,
}

#[derive(Clone, Copy)]
struct Resource {
    /// SQLite table name (plural), e.g. `"charges"`.
    table: &'static str,
    /// Stripe `object` discriminator, e.g. `"charge"` / `"checkout.session"`.
    object: &'static str,
    /// Hot, indexed columns. `id` + `data` + `updated_at` are implicit.
    columns: &'static [Column],
}

const fn t(name: &'static str, path: &'static str) -> Column {
    Column { name, path, kind: ColKind::Text }
}
const fn i(name: &'static str, path: &'static str) -> Column {
    Column { name, path, kind: ColKind::Int }
}

/// The mirrored resources — opensigma's billing core, registry-driven so adding
/// a resource is one entry, not a new upsert function.
const RESOURCES: &[Resource] = &[
    Resource { table: "customers", object: "customer", columns: &[
        t("email", "email"), t("name", "name"), i("created", "created") ] },
    Resource { table: "charges", object: "charge", columns: &[
        i("amount", "amount"), t("currency", "currency"), t("status", "status"),
        t("customer", "customer"), t("payment_intent", "payment_intent"),
        t("invoice", "invoice"), i("created", "created") ] },
    Resource { table: "payment_intents", object: "payment_intent", columns: &[
        i("amount", "amount"), t("currency", "currency"), t("status", "status"),
        t("customer", "customer"), i("created", "created") ] },
    Resource { table: "checkout_sessions", object: "checkout.session", columns: &[
        i("amount_total", "amount_total"), t("currency", "currency"),
        t("status", "status"), t("payment_status", "payment_status"),
        t("customer", "customer"), t("payment_intent", "payment_intent"),
        t("subscription", "subscription"), i("created", "created") ] },
    Resource { table: "invoices", object: "invoice", columns: &[
        t("customer", "customer"), t("subscription", "subscription"),
        t("status", "status"), i("total", "total"), i("amount_paid", "amount_paid"),
        t("currency", "currency"), t("number", "number"), i("created", "created") ] },
    Resource { table: "subscriptions", object: "subscription", columns: &[
        t("customer", "customer"), t("status", "status"),
        i("current_period_end", "current_period_end"), i("created", "created") ] },
    Resource { table: "prices", object: "price", columns: &[
        t("product", "product"), i("unit_amount", "unit_amount"),
        t("currency", "currency"), t("interval", "recurring.interval"),
        t("lookup_key", "lookup_key"), i("active", "active") ] },
    Resource { table: "products", object: "product", columns: &[
        t("name", "name"), i("active", "active"), i("created", "created") ] },
    Resource { table: "refunds", object: "refund", columns: &[
        i("amount", "amount"), t("currency", "currency"), t("status", "status"),
        t("charge", "charge"), t("payment_intent", "payment_intent"),
        i("created", "created") ] },
    Resource { table: "payouts", object: "payout", columns: &[
        i("amount", "amount"), t("currency", "currency"), t("status", "status"),
        i("arrival_date", "arrival_date"), i("created", "created") ] },
    Resource { table: "balance_transactions", object: "balance_transaction", columns: &[
        i("amount", "amount"), i("net", "net"), i("fee", "fee"),
        t("currency", "currency"), t("type", "type"), i("created", "created") ] },
    Resource { table: "disputes", object: "dispute", columns: &[
        i("amount", "amount"), t("currency", "currency"), t("status", "status"),
        t("charge", "charge"), t("reason", "reason"), i("created", "created") ] },
    Resource { table: "coupons", object: "coupon", columns: &[
        t("name", "name"), i("percent_off", "percent_off"),
        i("amount_off", "amount_off"), t("duration", "duration"), i("created", "created") ] },
    Resource { table: "promotion_codes", object: "promotion_code", columns: &[
        t("code", "code"), t("coupon", "coupon.id"), i("active", "active"),
        i("created", "created") ] },
    Resource { table: "setup_intents", object: "setup_intent", columns: &[
        t("customer", "customer"), t("status", "status"), i("created", "created") ] },
    Resource { table: "credit_notes", object: "credit_note", columns: &[
        t("customer", "customer"), t("invoice", "invoice"), i("total", "total"),
        t("status", "status"), i("created", "created") ] },
    Resource { table: "payment_methods", object: "payment_method", columns: &[
        t("type", "type"), t("customer", "customer"), i("created", "created") ] },
    Resource { table: "early_fraud_warnings", object: "early_fraud_warning", columns: &[
        t("charge", "charge"), t("fraud_type", "fraud_type"),
        i("actionable", "actionable"), i("created", "created") ] },
    Resource { table: "reviews", object: "review", columns: &[
        t("charge", "charge"), t("reason", "reason"), i("open", "open"),
        i("created", "created") ] },
];

/// The mirrored table names, for introspection (`ListTables` / status).
pub fn table_names() -> Vec<&'static str> {
    RESOURCES.iter().map(|r| r.table).collect()
}

/// `CREATE TABLE IF NOT EXISTS` + indexes for every mirrored resource. Idempotent.
pub fn ensure_schema(exec: &impl SqlExec) -> Result<(), String> {
    for r in RESOURCES {
        let mut cols = String::from("id TEXT PRIMARY KEY");
        for c in r.columns {
            let ty = match c.kind {
                ColKind::Text => "TEXT",
                ColKind::Int => "INTEGER",
            };
            cols.push_str(", ");
            cols.push_str(c.name);
            cols.push(' ');
            cols.push_str(ty);
        }
        cols.push_str(", data TEXT NOT NULL, updated_at INTEGER NOT NULL");
        exec.run(&format!("CREATE TABLE IF NOT EXISTS {} ({})", r.table, cols), &[])?;
        // Index the foreign-key-ish columns so JOIN/filter is cheap.
        for c in r.columns {
            if c.name == "customer"
                || c.name == "charge"
                || c.name == "payment_intent"
                || c.name == "subscription"
                || c.name == "invoice"
                || c.name == "product"
            {
                exec.run(
                    &format!(
                        "CREATE INDEX IF NOT EXISTS idx_{0}_{1} ON {0} ({1})",
                        r.table, c.name
                    ),
                    &[],
                )?;
            }
        }
    }
    Ok(())
}

/// Walk a dotted JSON path (`"recurring.interval"`) into an object.
fn dig<'a>(obj: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = obj;
    for seg in path.split('.') {
        cur = cur.get(seg)?;
    }
    Some(cur)
}

fn cell(obj: &Value, c: &Column) -> SqlValue {
    match dig(obj, c.path) {
        None | Some(Value::Null) => SqlValue::Null,
        Some(v) => match c.kind {
            ColKind::Int => {
                if let Some(n) = v.as_i64() {
                    SqlValue::Int(n)
                } else if let Some(b) = v.as_bool() {
                    SqlValue::Int(b as i64) // active/open/actionable booleans → 0/1
                } else {
                    SqlValue::Null
                }
            }
            ColKind::Text => match v {
                Value::String(s) => SqlValue::Text(s.clone()),
                other => SqlValue::Text(other.to_string()),
            },
        },
    }
}

/// Upsert one Stripe resource object (from an event's `data.object`, or a
/// backfill list item). Unknown object types are ignored (returns `false`).
pub fn apply_object(exec: &impl SqlExec, obj: &Value, now_ms: i64) -> Result<bool, String> {
    let object_type = match obj.get("object").and_then(Value::as_str) {
        Some(t) => t,
        None => return Ok(false),
    };
    let resource = match RESOURCES.iter().find(|r| r.object == object_type) {
        Some(r) => r,
        None => return Ok(false),
    };
    let id = match obj.get("id").and_then(Value::as_str) {
        Some(id) => id,
        None => return Ok(false),
    };

    // Column order: id, <hot cols...>, data, updated_at.
    let mut names = String::from("id");
    let mut placeholders = String::from("?");
    let mut updates = String::new();
    let mut params: Vec<SqlValue> = vec![SqlValue::Text(id.to_string())];
    for c in resource.columns {
        names.push_str(", ");
        names.push_str(c.name);
        placeholders.push_str(", ?");
        if !updates.is_empty() {
            updates.push_str(", ");
        }
        updates.push_str(&format!("{0}=excluded.{0}", c.name));
        params.push(cell(obj, c));
    }
    names.push_str(", data, updated_at");
    placeholders.push_str(", ?, ?");
    if !updates.is_empty() {
        updates.push_str(", ");
    }
    updates.push_str("data=excluded.data, updated_at=excluded.updated_at");
    params.push(SqlValue::Text(obj.to_string()));
    params.push(SqlValue::Int(now_ms));

    let sql = format!(
        "INSERT INTO {table} ({names}) VALUES ({placeholders}) \
         ON CONFLICT(id) DO UPDATE SET {updates}",
        table = resource.table,
    );
    exec.run(&sql, &params)?;
    Ok(true)
}

/// Apply a full Stripe webhook event payload: parse, pull `data.object`, upsert.
/// Returns true if a resource row was written.
pub fn apply_event(exec: &impl SqlExec, payload: &str, now_ms: i64) -> Result<bool, String> {
    let event: Value = serde_json::from_str(payload).map_err(|e| format!("event json: {e}"))?;
    match event.pointer("/data/object") {
        Some(obj) => apply_object(exec, obj, now_ms),
        None => Ok(false),
    }
}
