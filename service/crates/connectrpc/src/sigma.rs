//! `SigmaService` server (ADR-14 brick 3) — the typed read/analytics surface
//! over the mirror. Generic over a [`SigmaStore`] so it runs on both runtimes:
//! the worker forwards queries to the Dispatcher DO; native queries rusqlite.

use std::future::Future;

use connectrpc::{ConnectError, RequestContext, Response, ServiceRequest, ServiceResult};

use crate::proto::stripe::v1::{
    GetSyncStatusRequest, GetSyncStatusResponse, ListTablesRequest, ListTablesResponse, Row,
    RunQueryRequest, RunQueryResponse, SigmaService, Table, TableStatus,
};

/// A dynamic query result — column names + stringified rows (SQLite is
/// dynamically typed, so cells come back as text).
pub struct QueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

/// The read backend `SigmaService` queries. CF forwards to the Dispatcher DO;
/// native runs rusqlite. The futures are `Send` either way — the worker impl
/// wraps its `!Send` DO-stub call in `worker::send::SendFuture`, the same trick
/// the rest of the gateway uses — so one bound serves both runtimes.
pub trait SigmaStore {
    /// Run a read-only SQL query, capped at `limit` rows.
    fn query(
        &self,
        sql: &str,
        limit: u32,
    ) -> impl Future<Output = Result<QueryResult, String>> + Send;
    /// Row count per mirrored table (in `mirror::table_names()` order).
    fn counts(&self) -> impl Future<Output = Result<Vec<(String, i64)>, String>> + Send;
}

/// Row cap applied when the request leaves `limit` unset.
const DEFAULT_LIMIT: u32 = 1000;

/// Reject anything that isn't a single read-only `SELECT`/`WITH` — no writes, no
/// DDL, no statement chaining. SigmaService is read-only by contract.
pub fn is_read_only(sql: &str) -> bool {
    let s = sql.trim().trim_end_matches(';').trim();
    if s.contains(';') {
        return false; // no chained statements
    }
    let head = s.to_ascii_lowercase();
    head.starts_with("select") || head.starts_with("with")
}

/// The `SigmaService` server, generic over its read backend.
pub struct SigmaServer<S> {
    store: S,
}

impl<S> SigmaServer<S> {
    #[must_use]
    pub const fn new(store: S) -> Self {
        Self { store }
    }
}

impl<S: SigmaStore + Send + Sync + 'static> SigmaService for SigmaServer<S> {
    async fn run_query(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, RunQueryRequest>,
    ) -> ServiceResult<RunQueryResponse> {
        if !is_read_only(request.sql) {
            return Err(ConnectError::invalid_argument(
                "only a single read-only SELECT/WITH statement is allowed",
            ));
        }
        let limit = if request.limit == 0 {
            DEFAULT_LIMIT
        } else {
            request.limit
        };
        let result = self
            .store
            .query(request.sql, limit)
            .await
            .map_err(|e| ConnectError::internal(format!("sigma query: {e}")))?;
        let truncated = result.rows.len() as u32 >= limit;
        Ok(Response::new(RunQueryResponse {
            columns: result.columns,
            rows: result
                .rows
                .into_iter()
                .map(|values| Row {
                    values,
                    ..Default::default()
                })
                .collect(),
            truncated,
            ..Default::default()
        }))
    }

    async fn list_tables(
        &self,
        _ctx: RequestContext,
        _request: ServiceRequest<'_, ListTablesRequest>,
    ) -> ServiceResult<ListTablesResponse> {
        let counts = self
            .store
            .counts()
            .await
            .map_err(|e| ConnectError::internal(format!("sigma counts: {e}")))?;
        Ok(Response::new(ListTablesResponse {
            tables: counts
                .into_iter()
                .map(|(name, row_count)| Table {
                    name,
                    row_count,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }))
    }

    async fn get_sync_status(
        &self,
        _ctx: RequestContext,
        _request: ServiceRequest<'_, GetSyncStatusRequest>,
    ) -> ServiceResult<GetSyncStatusResponse> {
        let counts = self
            .store
            .counts()
            .await
            .map_err(|e| ConnectError::internal(format!("sigma status: {e}")))?;
        Ok(Response::new(GetSyncStatusResponse {
            tables: counts
                .into_iter()
                .map(|(name, row_count)| TableStatus {
                    name,
                    row_count,
                    last_event_at: 0,
                    backfilling: false,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }))
    }
}
