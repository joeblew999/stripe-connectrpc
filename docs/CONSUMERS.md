# Consumer integration contract

How a consumer repo (e.g. `remy-sport`) receives webhook events from `stripe-smp`.
This is the public API surface for Phase 3 (ADR-10).

stripe-smp signs each event with HMAC-SHA256 using a per-consumer shared
secret and POSTs to your registered webhook URL. You verify the signature,
return 2xx, and you're done. Same primitive Stripe uses with smp itself —
if you've already implemented Stripe webhook verification, this is the
same code with a different secret.

---

## 1. Register your consumer

Add a `consumer` block to `data/projects/<your-slug>/project.json` in the
stripe-smp repo:

```json
{
  "slug": "remy-sport",
  "name": "Remy Sport",
  "consumer": {
    "webhook_url": "https://remy-sport.dev/webhooks/smp",
    "signing_secret_keychain": "SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET",
    "bearer_token_keychain":   "SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN",
    "event_filters": [
      "checkout.session.completed",
      "checkout.session.async_payment_*",
      "customer.subscription.*",
      "invoice.paid",
      "invoice.payment_failed",
      "charge.refunded"
    ]
  }
}
```

Field-by-field:

| Field | Required | Meaning |
|---|---|---|
| `webhook_url` | yes | Full HTTPS URL the dispatcher POSTs to |
| `signing_secret_keychain` | yes | macOS keychain item name on the smp host that holds the HMAC secret |
| `bearer_token_keychain` | future | Reserved for the future `/v1/checkout` consumer-RPC surface (not used by dispatcher) |
| `event_filters` | yes | Stripe `event.type` patterns this consumer wants. Trailing `*` is a wildcard. Empty list = all events. |

`event_filters` is an OR list — an event delivered if it matches **any** entry.

---

## 2. Generate and share the signing secret

On the stripe-smp host:

```sh
# Generate 32 random bytes, base64'd (or any opaque high-entropy string)
secret=$(openssl rand -base64 32)

# Store on smp side
fnox set -p keychain SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET "$secret"

# Restart the dispatcher so it picks up the new secret
mise run dev:restart-dispatcher

# Share with the consumer repo via your normal secret-distribution channel
echo "$secret"
```

Per `feedback-fnox-cross-repo-contract`: **the keychain item name IS the
cross-repo API**. If you rename `SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET`
on either side without coordinating, verification breaks silently.

---

## 3. Verify the signature in your consumer

stripe-smp sends a `Stripe-Signature` header in the exact format
Stripe uses:

```
Stripe-Signature: t=1779957572,v1=a82f48...
```

- `t` — Unix epoch seconds at dispatch time.
- `v1` — hex HMAC-SHA256 of `<t>.<raw-body>` using the shared secret.

### TypeScript (Workers, Vercel, Node)

```ts
async function verifySmpSignature(
  body: string,
  header: string,
  secret: string,
): Promise<boolean> {
  const parts = Object.fromEntries(
    header.split(",").map((p) => p.trim().split("=") as [string, string]),
  );
  const t = parts["t"];
  const sig = parts["v1"];
  if (!t || !sig) return false;

  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const computed = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`));
  const computedHex = [...new Uint8Array(computed)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // Constant-time compare
  if (computedHex.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < computedHex.length; i++) {
    diff |= computedHex.charCodeAt(i) ^ sig.charCodeAt(i);
  }
  return diff === 0;
}
```

### Rust (axum / actix / Workers)

```rust
use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

type HmacSha256 = Hmac<Sha256>;

fn verify_smp_signature(body: &str, header: &str, secret: &str) -> bool {
    let mut t = None;
    let mut sig = None;
    for pair in header.split(',') {
        let mut kv = pair.trim().splitn(2, '=');
        match (kv.next(), kv.next()) {
            (Some("t"),  Some(v)) => t = Some(v),
            (Some("v1"), Some(v)) => sig = Some(v),
            _ => {}
        }
    }
    let (Some(t), Some(sig)) = (t, sig) else { return false };

    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key");
    mac.update(format!("{t}.{body}").as_bytes());
    let computed = hex::encode(mac.finalize().into_bytes());

    computed.as_bytes().ct_eq(sig.as_bytes()).into()
}
```

---

## 4. Event payload

The POST body is the raw Stripe event JSON exactly as it arrived at smp —
no envelope, no re-encoding. Top-level fields you typically use:

```json
{
  "id":      "evt_1ABC...",
  "type":    "checkout.session.completed",
  "data":    { "object": { "id": "cs_test_...", "metadata": { "project": "remy-sport" } } },
  "created": 1779957572,
  ...
}
```

If `data.object.metadata.project` is set, smp delivers the event ONLY to that
project's consumer. If it's absent (common for account-level events like
`account.updated`), smp broadcasts to all registered consumers.

---

## 5. Response contract

| Consumer response | smp behavior |
|---|---|
| 2xx | Logged as `stripe.dispatch.delivered`. No retry. |
| 4xx / 5xx | Logged as `stripe.dispatch.failed`. Retry policy: TBD (currently no automatic retry). |
| Network error / timeout | Logged as `stripe.dispatch.failed` with `error` populated. |

The dispatcher times out the POST at 10 seconds. Keep handlers fast or
ack-then-process — the 2xx is the durability gate, not your business logic.

---

## 6. Inspect dispatch state from the CLI

On the smp host:

```sh
mise run dispatch:attempted       # what smp tried to send
mise run dispatch:delivered       # what consumers accepted
mise run dispatch:failed          # what bounced (with error field)
mise run dispatch:logs            # live dispatcher console
```

All of those queries hit the xs event store directly — no extra logging
infrastructure. Each dispatch produces 1× attempted + (1× delivered OR 1×
failed) frames.

---

## 7. Topics, summarized

These are the xs topics relevant to the contract:

| Topic | Emitted by | Purpose |
|---|---|---|
| `stripe.webhook.received` | `routes/webhook.nu` | Raw POST from Stripe (pre-verify) |
| `stripe.webhook.verified` | `routes/webhook.nu` | HMAC validated; dispatcher subscribes here |
| `stripe.webhook.invalid` | `routes/webhook.nu` | Signature mismatch (HTTP 400 response) |
| `stripe.dispatch.attempted` | `handlers/dispatcher.nu` | About to POST to a consumer |
| `stripe.dispatch.delivered` | `handlers/dispatcher.nu` | Consumer 2xx ack |
| `stripe.dispatch.failed` | `handlers/dispatcher.nu` | Consumer non-2xx, network error, or missing secret |

The substrate is xs; everything in this list is a CLI-inspectable event with
SCRU128 id, sha256 content-address, and structured `meta`.
