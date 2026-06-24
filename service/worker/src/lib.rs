//! Cloudflare Worker entry — mounts stripe-connectrpc's CheckoutService over the
//! worker::Fetch Stripe transport, behind the SHARED Rauthy-OIDC → Cedar guard
//! (adopted from cf-connectrpc-middleware, not per-app auth).
//! Thin mount; all logic lives in stripe-connectrpc.

use std::sync::Arc;

use connectrpc::{ConnectRpcBody, ConnectRpcService, Router as RpcRouter};
use http_body_util::Full;
use stripe_connectrpc::{
    guard, BillingServer, BillingServiceExt, CatalogServer, CatalogServiceExt, CheckoutServer,
    CheckoutServiceExt, JwksVerifier, StripeBackend,
};
use tokio::sync::OnceCell;
use tower::Service;
use worker::{event, Context, Env, HttpRequest};

// The webhook DISPATCHER Durable Object (durable event log + fan-out + retry).
mod dispatcher;

// Build the Rauthy JWKS verifier once (fetched via worker::Fetch). Env:
// RAUTHY_ISSUER, RAUTHY_JWKS_URL, RAUTHY_AUD (optional).
static VERIFIER: OnceCell<Arc<JwksVerifier>> = OnceCell::const_new();
async fn verifier(env: &Env) -> worker::Result<Arc<JwksVerifier>> {
    VERIFIER
        .get_or_try_init(|| async {
            let issuer = env.var("RAUTHY_ISSUER")?.to_string();
            let jwks_url = env.var("RAUTHY_JWKS_URL")?.to_string();
            let aud = env.var("RAUTHY_AUD").ok().map(|v| v.to_string());
            let jwks = connectrpc_oidc::fetch::fetch_jwks(&jwks_url).await?;
            JwksVerifier::from_jwks_json(issuer, aud, &jwks)
                .map(Arc::new)
                .map_err(|e| worker::Error::RustError(format!("jwks: {e:?}")))
        })
        .await
        .cloned()
}

fn apply_cors(headers: &mut http::HeaderMap) {
    let set = |h: &mut http::HeaderMap, k: &'static str, v: &'static str| {
        if let Ok(val) = http::HeaderValue::from_str(v) {
            h.insert(k, val);
        }
    };
    set(headers, "access-control-allow-origin", "*");
    set(headers, "access-control-allow-methods", "POST, GET, OPTIONS");
    set(
        headers,
        "access-control-allow-headers",
        "authorization, content-type, connect-protocol-version, connect-timeout-ms, x-user-agent, x-grpc-web",
    );
    set(headers, "access-control-max-age", "86400");
}

#[event(fetch, respond_with_errors)]
async fn fetch(
    req: HttpRequest,
    env: Env,
    _ctx: Context,
) -> worker::Result<http::Response<ConnectRpcBody>> {
    console_error_panic_hook::set_once();

    if req.method() == http::Method::OPTIONS {
        let mut resp = http::Response::builder()
            .status(200)
            .body(ConnectRpcBody::Full(Full::new(bytes::Bytes::new())))
            .map_err(|e| worker::Error::RustError(format!("preflight: {e}")))?;
        apply_cors(resp.headers_mut());
        return Ok(resp);
    }

    if req.uri().path() == "/health" {
        return http::Response::builder()
            .status(200)
            .header(http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(ConnectRpcBody::Full(Full::new(bytes::Bytes::from("stripe ok\n"))))
            .map_err(|e| worker::Error::RustError(format!("health: {e}")));
    }

    // Sigma read/analytics ops — forwarded to the Dispatcher DO. /status (row
    // counts) and /backfill (seed the mirror from Stripe REST) are low-
    // sensitivity ops endpoints; the typed, data-returning RunQuery is the
    // guarded SigmaService RPC.
    if matches!(req.uri().path(), "/v1/sigma/status" | "/v1/sigma/backfill") {
        let (op, method) = if req.uri().path() == "/v1/sigma/backfill" {
            ("backfill", worker::Method::Post)
        } else {
            ("status", worker::Method::Get)
        };
        let stub = env
            .durable_object("DISPATCHER")?
            .id_from_name("global")?
            .get_stub()?;
        let headers = worker::Headers::new();
        headers.set("x-sigma-op", op)?;
        let mut init = worker::RequestInit::new();
        init.with_method(method).with_headers(headers);
        let do_req = worker::Request::new_with_init("https://dispatcher.local/", &init)?;
        let mut do_resp = stub.fetch_with_request(do_req).await?;
        let body = do_resp.text().await.unwrap_or_default();
        let mut resp = http::Response::builder()
            .status(do_resp.status_code())
            .header(http::header::CONTENT_TYPE, "application/json")
            .body(ConnectRpcBody::Full(Full::new(bytes::Bytes::from(body))))
            .map_err(|e| worker::Error::RustError(format!("sigma: {e}")))?;
        apply_cors(resp.headers_mut());
        return Ok(resp);
    }

    // Stripe webhook — verified by HMAC signature, NOT a Rauthy token, so it
    // sits OUTSIDE the guard. Verify, then durably hand the event to the
    // Dispatcher DO (which owns storage + fan-out + retry + dead-letter).
    if req.uri().path() == "/v1/webhook" {
        let sig = req
            .headers()
            .get("stripe-signature")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_string();
        let secret = env.secret("STRIPE_WEBHOOK_SECRET")?.to_string();
        let now = (js_sys::Date::now() / 1000.0) as i64;
        let body = http_body_util::BodyExt::collect(req.into_body())
            .await
            .map(|c| c.to_bytes())
            .unwrap_or_default();
        let payload = String::from_utf8_lossy(&body);

        // Bad signature → 400, no retry wanted.
        let ev = match stripe_connectrpc::verify_event(&payload, &sig, &secret, now) {
            Ok(ev) => ev,
            Err(e) => {
                let mut resp = http::Response::builder()
                    .status(400)
                    .body(ConnectRpcBody::Full(Full::new(bytes::Bytes::from(e))))
                    .map_err(|e| worker::Error::RustError(format!("webhook resp: {e}")))?;
                apply_cors(resp.headers_mut());
                return Ok(resp);
            }
        };

        // Verified → forward to the Dispatcher DO. If THIS fails we haven't
        // stored the event, so `?` propagates a 5xx and Stripe retries.
        let forward = serde_json::json!({
            "id": ev.id,
            "event_type": ev.event_type,
            "payload": payload,
        })
        .to_string();
        let stub = env
            .durable_object("DISPATCHER")?
            .id_from_name("global")?
            .get_stub()?;
        let mut init = worker::RequestInit::new();
        init.with_method(worker::Method::Post)
            .with_body(Some(forward.into()));
        let do_req = worker::Request::new_with_init("https://dispatcher.local/ingest", &init)?;
        stub.fetch_with_request(do_req).await?;

        let mut resp = http::Response::builder()
            .status(200)
            .body(ConnectRpcBody::Full(Full::new(bytes::Bytes::from(format!(
                "ok {}",
                ev.id
            )))))
            .map_err(|e| worker::Error::RustError(format!("webhook resp: {e}")))?;
        apply_cors(resp.headers_mut());
        return Ok(resp);
    }

    let client = StripeBackend::new(env.secret("STRIPE_SECRET_KEY")?.to_string());
    let router = RpcRouter::new();
    let router = Arc::new(CheckoutServer::new(client.clone())).register(router);
    let router = Arc::new(CatalogServer::new(client.clone())).register(router);
    let router = Arc::new(BillingServer::new(client)).register(router);

    // Shared guard: Rauthy JWT verify → Cedar authz → the ConnectRPC service.
    let verifier = verifier(&env).await?;
    let mut svc = guard(verifier, ConnectRpcService::new(router));

    let mut resp = svc
        .call(req)
        .await
        .map_err(|e| worker::Error::RustError(format!("rpc dispatch: {e}")))?;
    apply_cors(resp.headers_mut());
    Ok(resp)
}
