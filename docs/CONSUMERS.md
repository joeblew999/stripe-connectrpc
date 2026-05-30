# Consumer integration contract

How a consumer repo (e.g. `remy-sport`) talks to stripe-smp in **both directions**. Public API surface for Phase 3 ([ADR-10](ADR.md)).

Two routes:
- **`POST /v1/checkout`** — consumer asks smp to create a Stripe Checkout Session. Bearer auth. Returns a hosted checkout URL the consumer redirects the user to.
- **`POST <consumer.webhook_url>`** — smp signs+POSTs Stripe events to the consumer. HMAC-SHA256 verification using a per-consumer shared secret. Same wire format Stripe uses with smp itself.

If you've implemented Stripe webhook verification before, the inbound side is the same code with a different secret. The outbound side (calling smp) is plain JSON + bearer token.

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
- Per `feedback-fnox-cross-repo-contract`: **the keychain item name IS the cross-repo API**. Renaming it on either side without coordination breaks verification silently.

## 2. Generate + share the two secrets

The consumer needs two per-consumer secrets — both random hex from `openssl rand -hex 32`:

```sh
# Signing secret (smp HMAC-signs outbound events to your webhook_url with this)
fnox set -p keychain SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET "$(openssl rand -hex 32)"

# Bearer token (consumer presents this on inbound POST /v1/checkout)
fnox set -p keychain SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN  "$(openssl rand -hex 32)"

mise run daemons:restart-http         # picks up new bearer token for /v1/checkout
mise run daemons:restart-dispatcher   # picks up new signing secret for outbound

# Share both with the consumer via your normal secret-distribution channel.
```

---

# Inbound: `POST /v1/checkout`

The consumer calls this when a user clicks "Subscribe". smp creates the Stripe Checkout Session and returns the URL.

## Request

```
POST /v1/checkout
Authorization: Bearer <consumer-bearer-token>
Content-Type: application/json
```

```json
{
  "project":        "remy-sport",
  "lookup_key":     "sports_coach_monthly_usd",
  "success_url":    "https://app.remy-sport.dev/return?session={CHECKOUT_SESSION_ID}",
  "cancel_url":     "https://app.remy-sport.dev/canceled",
  "customer_email": "user@example.com",
  "metadata":       { "user_id": "u123" }
}
```

`customer_email` + `metadata` are optional. `metadata` is passed through to Stripe (smp always also sets `metadata.project=<slug>` so the resulting webhook dispatches back to the right consumer).

## Response

**`201 Created`** on success:

```json
{
  "session_id": "cs_test_a1k3g1...",
  "url":        "https://checkout.stripe.com/c/pay/cs_test_a1k3g1..."
}
```

Redirect the user's browser to `url`. They pay on Stripe's domain; smp's `/v1/webhook` receives the result; the dispatcher POSTs it back to your `webhook_url`.

Error responses:

| Status | When |
|---|---|
| `400` | Missing required field, invalid JSON |
| `401` | Missing / malformed / wrong bearer token |
| `404` | Project slug unknown, or no Stripe price for `lookup_key` |
| `502` | Stripe API rejected the session create |
| `503` | smp config error (per-consumer bearer secret not in smp's keychain) |

## TypeScript client example

```ts
const res = await fetch("https://smp.example.com/v1/checkout", {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${SMP_CONSUMER_BEARER_TOKEN}`,
    "Content-Type":  "application/json",
  },
  body: JSON.stringify({
    project:     "remy-sport",
    lookup_key:  "sports_coach_monthly_usd",
    success_url: `${origin}/return?session={CHECKOUT_SESSION_ID}`,
    cancel_url:  `${origin}/canceled`,
    metadata:    { user_id: userId },
  }),
});
if (res.status !== 201) throw new Error(`smp checkout: ${res.status}`);
const { url } = await res.json();
return Response.redirect(url, 303);
```

---

# Outbound: webhook signature verify

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
| 2xx | Logged as `stripe.dispatch.delivered`. Chain terminates. |
| 4xx / 5xx / network error / 10s timeout | Logged as `stripe.dispatch.failed`. A `stripe.dispatch.retry` is scheduled with Stripe-style backoff. After 7 total attempts (~1.6 days), `stripe.dispatch.dead-lettered` is emitted and the chain terminates. |

The dispatcher times out at 10 seconds. Keep handlers fast or ack-then-process — the 2xx is the durability gate.

**Retry backoff** (matches Stripe's own webhook retry curve, so consumers who already handle Stripe webhook retries have the same operational model):

| Attempt | Delay after previous |
|---|---|
| 2 | 30 seconds |
| 3 | 5 minutes |
| 4 | 30 minutes |
| 5 | 2 hours |
| 6 | 12 hours |
| 7 | 24 hours |

The retry chain is **idempotent on the consumer side** — implement your handler so a repeated `event_id` is a no-op (e.g. dedupe on `event.id`). If you 2xx an event you've already processed, that's the right answer.

## 6. Inspect from the CLI

On the smp host:

```sh
# Inbound: /v1/checkout consumer-RPC
mise run rpc:intent              # authenticated requests
mise run rpc:created             # Stripe returned a URL
mise run rpc:failed              # Stripe rejected the session create

# Outbound: dispatcher → consumer
mise run dispatch:attempted      # what smp tried to send (per attempt)
mise run dispatch:delivered      # consumer 2xx (terminal)
mise run dispatch:failed         # bounces with error meta (per attempt)
mise run dispatch:retry          # scheduled re-attempts (next_attempt_at meta)
mise run dispatch:dead-lettered  # gave up after 7 attempts (terminal)
mise run dispatch:logs           # live dispatcher console
```

All read directly from xs — no extra logging infra. Smoke-test the inbound side:
```sh
mise run test:rpc-checkout     # 201 happy path + two 401 auth-wall probes
```

## 7. Topics, summarized

| Topic | Emitted by | Purpose |
|---|---|---|
| `stripe.intent.session.create` | `routes/checkout.nu` | Authenticated `POST /v1/checkout` audit |
| `stripe.api.session.created` | `routes/checkout.nu` | Stripe returned a checkout URL |
| `stripe.api.session.failed` | `routes/checkout.nu` | Stripe rejected the session create |
| `stripe.webhook.received` | `routes/webhook.nu` | Raw POST from Stripe (pre-verify) |
| `stripe.webhook.verified` | `routes/webhook.nu` | HMAC valid; dispatcher subscribes here |
| `stripe.webhook.invalid` | `routes/webhook.nu` | Signature mismatch (HTTP 400 response) |
| `stripe.dispatch.attempted` | `handlers/dispatcher.nu` + `dispatch-retry.nu` | About to POST to a consumer (one per attempt) |
| `stripe.dispatch.delivered` | both | Consumer 2xx ack (terminal) |
| `stripe.dispatch.failed` | both | Consumer non-2xx / network / timeout (one per attempt) |
| `stripe.dispatch.retry` | both | Re-attempt scheduled; meta has `next_attempt_at` + `attempt` + `verified_hash` |
| `stripe.dispatch.dead-lettered` | both | Gave up after `MAX_ATTEMPTS` or fatal config error (terminal) |
