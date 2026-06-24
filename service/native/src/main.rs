//! Native host — the SAME stripe-connectrpc CheckoutService + shared Rauthy-OIDC →
//! Cedar `guard` as the CF worker, on a hyper/tokio runtime. The only
//! platform-specific bits: ureq JWKS fetch + the hyper serve loop.
//! Mirrors cf-connectrpc-middleware's examples/rauthy-cedar/server.
//!
//! Env: STRIPE_SECRET_KEY, RAUTHY_ISSUER, RAUTHY_JWKS_URL, RAUTHY_AUD (optional),
//!      PORT (default 8090).

use std::sync::Arc;

use connectrpc::{ConnectRpcService, Router as RpcRouter};
use hyper::server::conn::http1;
use hyper_util::rt::TokioIo;
use hyper_util::service::TowerToHyperService;
use stripe_connectrpc::{
    guard, BillingServer, BillingServiceExt, CatalogServer, CatalogServiceExt, CheckoutServer,
    CheckoutServiceExt, JwksVerifier, SigmaServer, SigmaServiceExt, StripeBackend,
};
use tokio::net::TcpListener;

mod sigma;

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // `stripe-native backfill [db]` runs the native Sigma mirror backfill
    // (brick 4) — plain SQLite, no Durable Object, no Rauthy. The default path
    // below serves the guarded RPC and needs Rauthy.
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("backfill") {
        let db = args.get(2).cloned().unwrap_or_else(|| "sigma.db".to_string());
        return sigma::backfill(&db);
    }
    if args.get(1).map(String::as_str) == Some("query") {
        let db = args.get(2).cloned().unwrap_or_else(|| "sigma.db".to_string());
        let sql = args.get(3).cloned().unwrap_or_default();
        return sigma::query_cli(&db, &sql).await;
    }

    let key = std::env::var("STRIPE_SECRET_KEY").unwrap_or_default();
    let issuer = std::env::var("RAUTHY_ISSUER").expect("set RAUTHY_ISSUER");
    let jwks_url = std::env::var("RAUTHY_JWKS_URL").expect("set RAUTHY_JWKS_URL");
    let aud = std::env::var("RAUTHY_AUD").ok();
    let port: u16 = env_or("PORT", "8090").parse().unwrap();

    println!("fetching JWKS from {jwks_url} ...");
    let jwks = ureq::get(&jwks_url).call()?.into_string()?;
    let verifier = Arc::new(JwksVerifier::from_jwks_json(&issuer, aud, &jwks)?);

    let client = StripeBackend::new(key);
    let router = RpcRouter::new();
    let router = Arc::new(CheckoutServer::new(client.clone())).register(router);
    let router = Arc::new(CatalogServer::new(client.clone())).register(router);
    let router = Arc::new(BillingServer::new(client)).register(router);
    // SigmaService reads the native mirror (rusqlite). Same guarded surface as
    // the worker's DO-backed SigmaService.
    let sigma_db = env_or("SIGMA_DB", "sigma.db");
    let router = Arc::new(SigmaServer::new(sigma::SqliteStore::open(&sigma_db)?)).register(router);
    let svc = guard::<_, hyper::body::Incoming>(verifier, ConnectRpcService::new(router));

    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    println!("stripe-connectrpc (native, oidc→cedar) on http://127.0.0.1:{port}  (issuer {issuer})");

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async move {
            loop {
                let (stream, _) = listener.accept().await.expect("accept");
                let io = TokioIo::new(stream);
                let hyper_svc = TowerToHyperService::new(svc.clone());
                tokio::task::spawn_local(async move {
                    if let Err(e) = http1::Builder::new().serve_connection(io, hyper_svc).await {
                        eprintln!("conn error: {e}");
                    }
                });
            }
        })
        .await;
    Ok(())
}
