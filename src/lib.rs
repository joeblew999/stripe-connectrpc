//! smp — Stripe Managed Payments shared service.
//!
//! Bare-minimum scaffold:
//!   GET  /health       — liveness check
//!   POST /v1/webhook   — Stripe → smp, HMAC-verified, logs and acks
//!
//! Outbound Stripe API client (via `worker::Fetch` adapter implementing
//! `stripe_client_core::StripeClient`), the ConnectRPC consumer surface,
//! D1 persistence, and CF Queues delivery to consumer apps land in
//! subsequent commits.

use worker::*;

mod webhook;

#[event(fetch)]
async fn main(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    console_error_panic_hook::set_once();

    Router::new()
        .get("/health", |_, _| Response::ok("smp ok"))
        .post_async("/v1/webhook", |req, ctx| async move { webhook::handle(req, ctx).await })
        .run(req, env)
        .await
}
