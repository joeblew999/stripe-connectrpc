# Consumer integration contract

How a consumer repo (e.g. `remy-sport`) receives webhook events from stripe-smp. Public API surface for Phase 3 ([ADR-10](ADR.md)).

stripe-smp signs each event with HMAC-SHA256 and POSTs to your webhook URL. You verify the signature, return 2xx. Same primitive Stripe uses with smp itself — if you've implemented Stripe webhook verification before, this is the same code with a different secret.

## 1. Register your consumer

Add a `consumer` block to `data/projects/<your-slug>/project.json`:

```json
"consumer": {
  "webhook_url":              "https://remy-sport.dev/webhooks/smp",
  "signing_secret_keychain":  "SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET",
  "bearer_token_keychain":    "SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN",
  "event_filters": [
    "checkout.session.completed",
    "checkout.session.async_payment_*",
    "customer.subscription.*",
    "invoice.paid",
    "invoice.payment_failed",
    "charge.refunded"
  ]
}
```

- `event_filters` is an OR list; trailing `*` is a wildcard. Empty = all events.
- `bearer_token_keychain` is reserved for the future `/v1/checkout` consumer-RPC route.
- Per `feedback-fnox-cross-repo-contract`: **the keychain item name IS the cross-repo API**. Renaming it on either side without coordination breaks verification silently.

## 2. Generate and share the signing secret

On the smp host:

```sh
secret=$(openssl rand -hex 32)
fnox set -p keychain SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET "$secret"
mise run dev:restart-dispatcher           # picks up new keychain entry
echo "$secret"                            # share via your normal secret channel
```

## 3. Verify the signature

stripe-smp sends `Stripe-Signature: t=<unix>,v1=<hex-hmac-sha256>` — the exact format Stripe uses. The signed payload is `<t>.<raw-body>`.

### TypeScript (Workers, Vercel, Node)

```ts
async function verify(body: string, header: string, secret: string): Promise<boolean> {
  const m = Object.fromEntries(header.split(",").map(p => p.trim().split("=") as [string, string]));
  if (!m.t || !m.v1) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${m.t}.${body}`));
  const hex = [...new Uint8Array(mac)].map(b => b.toString(16).padStart(2, "0")).join("");
  // constant-time compare
  if (hex.length !== m.v1.length) return false;
  let d = 0; for (let i = 0; i < hex.length; i++) d |= hex.charCodeAt(i) ^ m.v1.charCodeAt(i);
  return d === 0;
}
```

### Rust (axum / actix / Workers)

```rust
use hmac::{Hmac, Mac}; use sha2::Sha256; use subtle::ConstantTimeEq;
type HmacSha256 = Hmac<Sha256>;

fn verify(body: &str, header: &str, secret: &str) -> bool {
    let mut t = None; let mut sig = None;
    for p in header.split(',') {
        let mut kv = p.trim().splitn(2, '=');
        match (kv.next(), kv.next()) {
            (Some("t"),  Some(v)) => t = Some(v),
            (Some("v1"), Some(v)) => sig = Some(v),
            _ => {}
        }
    }
    let (Some(t), Some(sig)) = (t, sig) else { return false };
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(format!("{t}.{body}").as_bytes());
    hex::encode(mac.finalize().into_bytes()).as_bytes().ct_eq(sig.as_bytes()).into()
}
```

## 4. Event payload

The POST body is the raw Stripe event JSON exactly as it arrived at smp — no envelope, no re-encoding.

```json
{
  "id":      "evt_1ABC...",
  "type":    "checkout.session.completed",
  "data":    { "object": { "id": "cs_test_...", "metadata": { "project": "remy-sport" } } },
  "created": 1779957572
}
```

If `data.object.metadata.project` is set, smp delivers ONLY to that project's consumer. Absent → broadcast to all registered consumers (common for account-level events like `account.updated`).

## 5. Response contract

| Consumer response | smp behavior |
|---|---|
| 2xx | Logged as `stripe.dispatch.delivered`. No retry. |
| 4xx / 5xx / network error / 10s timeout | Logged as `stripe.dispatch.failed` with `error` meta. Currently no automatic retry. |

The dispatcher times out at 10 seconds. Keep handlers fast or ack-then-process — the 2xx is the durability gate.

## 6. Inspect from the CLI

On the smp host:

```sh
mise run dispatch:attempted    # what smp tried to send
mise run dispatch:delivered    # consumer 2xx
mise run dispatch:failed       # bounces with error meta
mise run dispatch:logs         # live dispatcher console
```

All read directly from xs — no extra logging infra.

## 7. Topics, summarized

| Topic | Emitted by | Purpose |
|---|---|---|
| `stripe.webhook.received` | `routes/webhook.nu` | Raw POST from Stripe (pre-verify) |
| `stripe.webhook.verified` | `routes/webhook.nu` | HMAC valid; dispatcher subscribes here |
| `stripe.webhook.invalid` | `routes/webhook.nu` | Signature mismatch (HTTP 400 response) |
| `stripe.dispatch.attempted` | `handlers/dispatcher.nu` | About to POST to a consumer |
| `stripe.dispatch.delivered` | `handlers/dispatcher.nu` | Consumer 2xx ack |
| `stripe.dispatch.failed` | `handlers/dispatcher.nu` | Consumer non-2xx, network error, or missing secret |
