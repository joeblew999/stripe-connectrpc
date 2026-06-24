//! Stripe webhook ingestion — verify the signature + parse the event.
//!
//! Stripe authenticates webhooks with an HMAC signature (the `Stripe-Signature`
//! header + the `whsec_…` secret), NOT a Rauthy token — so the webhook endpoint
//! sits OUTSIDE the OIDC→Cedar guard. async-stripe-webhook's verify is pure
//! RustCrypto (hmac+sha2), so it builds for the CF worker too.
//!
//! `verify_event` takes `now` (current unix seconds) from the caller rather than
//! reading the clock, because `Webhook::construct_event`'s `Utc::now()` panics on
//! `wasm32-unknown-unknown` — the worker passes a JS-`Date` time, native passes
//! `SystemTime` (mirrors connectrpc-oidc's wasm-clock handling).

use stripe_webhook::Webhook;

/// The minimal verified event a host needs to dispatch on. (The full typed
/// `stripe_webhook::Event` stays internal until the dispatcher needs the body.)
#[derive(Debug, Clone)]
pub struct WebhookEvent {
    pub id: String,
    /// The Stripe event type, e.g. `checkout.session.completed`.
    pub event_type: String,
}

/// Verify a Stripe webhook signature against `secret` and parse the event.
/// `payload` is the RAW request body; `sig` is the `Stripe-Signature` header;
/// `now` is the current unix time in seconds (caller-supplied for wasm safety).
pub fn verify_event(
    payload: &str,
    sig: &str,
    secret: &str,
    now: i64,
) -> Result<WebhookEvent, String> {
    let event = Webhook::construct_event_with_timestamp(payload, sig, secret, now)
        .map_err(|e| format!("webhook verification failed: {e}"))?;
    Ok(WebhookEvent {
        id: event.id.to_string(),
        event_type: format!("{:?}", event.type_),
    })
}
