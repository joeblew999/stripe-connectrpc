//! The Cloudflare read backend for `SigmaService` — forwards queries to the
//! Dispatcher DO (which owns the mirror SQLite). The native twin is rusqlite.
//!
//! `Stub` is `Send`; wrapping it in `SendWrapper` makes `DoStore` `Send + Sync`
//! so it satisfies `SigmaServer<S>`'s bound, and each forward future is made
//! `Send` with `SendFuture` (the `!Send` DO-stub call is asserted single-thread,
//! same trick the rest of the gateway uses).

use std::future::Future;

use serde::Deserialize;
use stripe_connectrpc::{QueryResult, SigmaStore};
use worker::send::{SendFuture, SendWrapper};
use worker::{Headers, Method, Request, RequestInit, Stub};

pub struct DoStore {
    pub stub: SendWrapper<Stub>,
}

#[derive(Deserialize)]
struct DoQueryResult {
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl SigmaStore for DoStore {
    fn query(
        &self,
        sql: &str,
        limit: u32,
    ) -> impl Future<Output = Result<QueryResult, String>> + Send {
        let body = serde_json::json!({ "sql": sql, "limit": limit }).to_string();
        let stub = &*self.stub;
        SendFuture::new(async move {
            let headers = Headers::new();
            headers.set("x-sigma-op", "query").map_err(|e| e.to_string())?;
            let mut init = RequestInit::new();
            init.with_method(Method::Post)
                .with_body(Some(body.into()))
                .with_headers(headers);
            let req = Request::new_with_init("https://dispatcher.local/", &init)
                .map_err(|e| e.to_string())?;
            let mut resp = stub
                .fetch_with_request(req)
                .await
                .map_err(|e| e.to_string())?;
            let parsed: DoQueryResult = resp.json().await.map_err(|e| e.to_string())?;
            Ok(QueryResult {
                columns: parsed.columns,
                rows: parsed.rows,
            })
        })
    }

    fn counts(&self) -> impl Future<Output = Result<Vec<(String, i64)>, String>> + Send {
        let stub = &*self.stub;
        SendFuture::new(async move {
            let headers = Headers::new();
            headers.set("x-sigma-op", "status").map_err(|e| e.to_string())?;
            let mut init = RequestInit::new();
            init.with_method(Method::Get).with_headers(headers);
            let req = Request::new_with_init("https://dispatcher.local/", &init)
                .map_err(|e| e.to_string())?;
            let mut resp = stub
                .fetch_with_request(req)
                .await
                .map_err(|e| e.to_string())?;
            let obj: serde_json::Map<String, serde_json::Value> =
                resp.json().await.map_err(|e| e.to_string())?;
            Ok(obj
                .into_iter()
                .map(|(k, v)| (k, v.as_i64().unwrap_or(0)))
                .collect())
        })
    }
}
