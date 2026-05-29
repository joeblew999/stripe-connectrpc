# stripe-smp architecture decisions

Single ADR. When a decision flips, edit in place and add a dated entry under "Revisions" at the bottom.

## Context

Shared backend for taking payments via Stripe Managed Payments (Stripe is merchant of record — absorbs global indirect tax). Web apps NEVER embed Stripe.js or handle cards; all user-facing payment UI is Stripe-hosted (Checkout + Customer Portal). smp is the only place Stripe API keys live; consumer apps call smp for ops actions and billing-state queries.

## Decisions

### 1. Stack: workers-rs + async-stripe runtime-free sub-crates — **SUPERSEDED BY DECISION 9**

Originally: Rust Cloudflare Worker (`wasm32-unknown-unknown`) using [arlyon/async-stripe](https://github.com/arlyon/async-stripe) v1.0.0-rc.5 split sub-crates (`-types`, `-shared`, `-client-core`, `-webhook`, `-checkout`). Outbound via `worker::Fetch` through a `StripeClient` trait impl. Retained as alt-runtime under `cf:*` tasks (`alt-runtime/cloudflare/`).

### 2. User flow: Stripe-hosted only

Web app never embeds Stripe.js / Elements / publishable keys / card forms. Web app calls smp → smp creates a Checkout Session with `managed_payments[enabled]=true` → user redirected to `checkout.stripe.com/...` → pays on Stripe's domain → Stripe webhooks smp. Self-serve (update card, cancel sub) via Stripe Customer Portal.

Why: zero PCI surface. Stripe handles MoR liability + tax.

### 3. Storage — **SUPERSEDED BY DECISION 9**

Originally D1 (events dedup + customers + consumers tables). Now: xs (append-only event store) is the authoritative log. D1 still applies for the alt `cf:*` runtime.

### 4. Delivery to consumer apps — **SUPERSEDED BY DECISION 10**

Originally: D1 + CF Queues + signed webhooks. Now: xs subscribers + dispatcher daemon + signed webhooks. Same auth pattern (HMAC-SHA256), different transport.

### 5. Consumer-facing API: ConnectRPC + one HTTP outlier

smp exposes ConnectRPC for ops/queries (CreateCheckoutSession, CreateBillingPortal, CancelSubscription, ListSubscriptions, ListInvoices, CreateRefund, GetCustomer). The non-RPC endpoint is `POST /v1/webhook` for Stripe's form-encoded HMAC-signed webhook.

### 6. Bootstrap: stripe-cli + nushell + per-project JSONL

Stripe-side state (webhook endpoints, products, prices) bootstrapped via [stripe-cli](https://github.com/stripe/stripe-cli) driven by nushell scripts reading JSONL. async-stripe is library-only. Idempotent declarative state via data files in the repo.

### 7. Secrets: fnox → keychain → mise

Per-repo `fnox.toml` maps env var names to keychain items. `mise run onboard` populates interactively. `fnox exec --` injects env vars for any Stripe-touching command. For the alt-runtime `cf:*` path, `scripts/worker-dev.nu` additionally materializes `.dev.vars` from fnox for `wrangler dev`.

### 8. Multi-project model: directory + metadata, single Stripe account

One dir per project under `data/projects/<slug>/` with `project.json`, `products.jsonl`, `prices.jsonl`. Every Stripe object carries `metadata.project=<slug>` for Dashboard/queries filtering. One Stripe account hosts everything — **no Stripe Connect** (which is for marketplaces with separate merchant entities). Adding a project = `mkdir + apply -- all`.

## Country & tax-code eligibility (verified 2026-05-28)

SMP eligibility is **strictly narrower** than general Stripe availability. Sources: <https://docs.stripe.com/payments/managed-payments/eligibility>, <https://docs.stripe.com/payments/managed-payments/tax-compliance>.

- **SMP seller countries:** 38, in `data/reference/countries.jsonl` with `seller_modes` containing `"smp"`. Excluded: TH, MY, NZ, AE, BR, MX, IN, ID, and the 5 Paystack-Africa countries.
- **SMP buyer reach:** 195+ minus 9 restricted (AC, CN, CU, IR, XK, KP, RU, SY, TA) — flagged via `buyer_blocked_modes`.
- **Eligible tax codes:** 72 (digital goods/services only) — `tax-codes.jsonl`. Physical goods, professional services, live in-person events excluded.
- **Tax coverage:** 82 buyer countries Stripe handles VAT/GST for — `tax-coverage.jsonl`. Carve-outs: JP (all domestic), SG (B2B domestic).
- **Other:** direct integrations only (no Connect platforms / Express accounts), fully automated digital products (no human-in-loop coaching).

If the Stripe account is in a non-SMP country, the options are (a) register in a supported country, (b) drop to regular Stripe Payments (we become MoR, we handle tax), (c) wait. `mise run show -- account` reports the account country; `mise run show -- country <ISO>` shows what modes work for any country.

## Decision 9 — Runtime: http-nu + xs — 2026-05-29

The primary runtime is [http-nu](https://github.com/cablehead/http-nu) hosting an embedded [xs](https://github.com/cablehead/xs) event store. The Cloudflare Workers runtime (Decision 1) is the alternative under `cf:*` tasks.

**Why pivot:**
- Bootstrap is already nushell-first; the Cloudflare runtime was the only Rust-shaped piece forcing wasm32 dep-tree contortions.
- The runtime model is event-sourced — xs is built for it; D1+Queues would have been a reimplementation.
- No vendor lock-in: runs on a laptop, VPS, or Tailnet node.

**Implications:**
- Decision 3 (D1) replaced for primary runtime — events live in xs (append-only, content-addressable, topic-indexed).
- Decision 4 (Queues) replaced — see Decision 10.
- Decision 5 (ConnectRPC) still applies — http-nu can serve ConnectRPC-shaped routes.
- Decision 7 — `.dev.vars` is now `cf:*`-only. The http-nu daemon is wrapped in `fnox exec --` so `routes/webhook.nu` inherits `STRIPE_WEBHOOK_SECRET` directly.

**Topic naming:**

```
stripe.webhook.received        raw inbound from /v1/webhook
stripe.webhook.verified        HMAC valid
stripe.webhook.invalid         HMAC failed
stripe.dispatch.attempted      about to POST to consumer  ┐
stripe.dispatch.delivered      consumer 2xx                ├─ Decision 10
stripe.dispatch.failed         consumer non-2xx / error   ┘
stripe.intent.session.create   authenticated POST /v1/checkout (audit)  ┐
stripe.api.session.created     Stripe returned a URL                     ├─ /v1/checkout
stripe.api.session.failed      Stripe rejected the session create       ┘
```

HMAC verify: `routes/webhook.nu` shells to `openssl dgst -sha256 -hmac <secret>` (nushell has no native HMAC; openssl is everywhere). Signed-payload format is Stripe's standard: `timestamp.body`, hex-hmac-sha256, compared to `v1=…`.

## Decision 10 — Consumer fan-out: webhook push + dual-emit to xs — 2026-05-29

**Status:** ACCEPTED. Implemented in `scripts/handlers/dispatcher.nu`; supervised by pitchfork as the `dispatcher` daemon. Consumer integration contract in [CONSUMERS.md](CONSUMERS.md).

**Choice:** A (webhook push) over B (xs subscription) and C (ConnectRPC server-stream). The dispatcher tails `stripe.webhook.verified`, signs+POSTs to each project's `consumer.webhook_url`, records `stripe.dispatch.attempted` / `.delivered` / `.failed` back to xs. xs remains the authoritative log; HTTP push is the delivery transport.

**Why A:**
- Phase 5 reality: consumer apps run on Workers/Vercel/Fly — not co-located with smp. B is dead across the WAN.
- Failure modes familiar: HTTP webhook push is the pattern Stripe → smp already uses; we invert it for smp → consumer.
- xs stays internal — option B would leak xs as a public surface.
- Dual-emit gives audit + replay for free: `stripe.dispatch.failed` events are the retry queue.

**Commits us to:**
- Per-project keychain lookup at dispatch time (`fnox get $consumer.signing_secret_keychain`).
- xs as the queue (no Redis / CF Queues / NATS).
- Consumer-side verify helper in [CONSUMERS.md](CONSUMERS.md) (TS + Rust).

**Open questions resolved in Decision 12 (below):**
- ~~Retry policy on `stripe.dispatch.failed`~~ — implemented as Stripe-style backoff + dead-letter via a `dispatch-retry` daemon.

**Still open:**
- Concurrent dispatch fan-out per project (today: serial).
- `event_filters` granularity (today: exact + trailing `*`).

## Decision 11 — `POST /v1/checkout` consumer-RPC + bearer auth — 2026-05-29

**Status:** ACCEPTED. Implemented in `scripts/routes/checkout.nu`. Closes the loop opened by Decision 10 — consumers now both RECEIVE events from smp (Decision 10) AND CALL INTO smp to initiate them.

**Auth:** `Authorization: Bearer <token>`. The expected token is resolved at request time via `fnox get <project.consumer.bearer_token_keychain>`. Per-consumer; rotates by setting a new keychain value and restarting the http daemon. Constant-time-ish hex compare to prevent timing attacks.

**Why bearer not HMAC for the inbound side:**
- Symmetric simplicity: outbound is HMAC (matches Stripe's pattern); inbound is bearer (matches every Stripe API call the consumer would otherwise make directly).
- Bearer + TLS is what Stripe themselves use for inbound auth — consumers don't need a separate signing scheme just for talking to smp.
- HMAC verify on every consumer request would be ~20 lines of consumer code for ~no security improvement over `Authorization: Bearer` over TLS.

**Why `lookup_key` not `price_id`:**
- Consumers shouldn't know Stripe price IDs. `lookup_key` is the catalog identifier that survives price replacement (Stripe lets you reassign `lookup_key` to a new price).
- smp resolves it via `stripe prices list --lookup-keys` at request time. One extra Stripe call; trivial latency.

**Audit guarantee:** every authenticated request appends `stripe.intent.session.create` to xs BEFORE the Stripe call. Even if Stripe rejects, the intent is logged. The Stripe response (success or failure) appends `stripe.api.session.created` or `.failed`. Replay-friendly.

**What this commits us to:**
- Every consumer flow that creates Stripe state goes through smp — consumers never call Stripe directly. Mirrors the rule for outbound (smp is the only place sk_ keys live).
- Bearer token rotation is a `fnox set` + `dev:restart-http`. No downstream coordination.

**What this rules out:**
- Public, unauthenticated routes for creating Stripe state. If a future use-case needs unauth (e.g. a public donation page), it gets its own dedicated route with its own per-route auth model.

## Decision 12 — Retry + dead-letter on dispatch failure — 2026-05-29

**Status:** ACCEPTED. Implemented in `scripts/handlers/lib.nu` (shared) + `scripts/handlers/dispatch-retry.nu` (poll daemon). Supervised by pitchfork as the `dispatch-retry` daemon alongside the existing `dispatcher`.

**Problem:** Decision 10 fanned events out to consumers with HMAC + POST but didn't retry on failure. A consumer down for 30 seconds during a deploy would lose its events permanently. Stripe's own webhook system retries for ~3 days; we were strictly worse than Stripe at being a webhook deliverer.

**Solution:**

When a dispatch fails (non-2xx, network error, timeout), `dispatch_to_consumer` emits BOTH:
1. `stripe.dispatch.failed` (per-attempt outcome — same as before)
2. `stripe.dispatch.retry` with metadata: `{event_id, project, url, event_type, attempt: N+1, next_attempt_at: <ISO 8601>, verified_hash}`

The `dispatch-retry` daemon polls xs every 15s for `.retry` frames where:
- `now >= next_attempt_at`
- No later `.delivered` / `.dead-lettered` exists for the same `(event_id, project)`
- This frame is the highest `attempt` for its `(event_id, project)` (no superseding retry)

For each due retry, it fetches the body from CAS via `verified_hash` and calls the same `dispatch_to_consumer` helper the initial-dispatch path uses. Outcome → either `.delivered` (terminal success), another `.retry` (still under cap), or `.dead-lettered` (cap reached).

**Backoff schedule** (matches Stripe's own webhook retry curve):

| Attempt | Delay | Cumulative |
|---|---|---|
| 1 | — | 0s |
| 2 | 30s | 30s |
| 3 | 5m | ~5.5m |
| 4 | 30m | ~36m |
| 5 | 2h | ~2.6h |
| 6 | 12h | ~14.6h |
| 7 | 24h | ~38.6h |

After 7 total attempts (~1.6 days), `.dead-lettered` is emitted and the chain stops.

**Config errors (missing signing secret) skip retry.** If `fnox get <signing_secret_keychain>` returns empty, we emit `.failed` + immediate `.dead-lettered` with `reason: "config: missing signing secret"`. Retrying with the same missing secret would just re-fail; the operator needs to `fnox set` + `dev:restart-dispatcher`.

**Why xs as the queue, not Redis / CF Queues / NATS:**
- xs is already part of the runtime — adding a queue technology doubles the moving parts for ~nothing gained.
- Retries are scheduling, and `next_attempt_at` is just a timestamp in event metadata. The poll loop is 30 lines.
- Replay-friendliness: every retry attempt is a recorded event. `mise run dispatch:retry` shows the whole pending schedule.

**End-to-end verified:**
- Initial dispatch fails (URL refused) → `.failed (attempt=1)` + `.retry (attempt=2, +30s)`.
- 30s later, `dispatch-retry` picks up the retry → `.attempted (attempt=2)` → `.failed (attempt=2)` + `.retry (attempt=3, +5m)`.
- 5 minutes later, attempt=3 fires → `.failed (attempt=3)` + `.retry (attempt=4, +30m)`.
- Synthetic injection at `attempt=7` → dispatched → failed → `.dead-lettered` with `reason: "non-2xx after 7 attempts"`.

## Revisions

- **2026-05-29** — Decision 12 added + ACCEPTED. Retry + dead-letter live; full backoff chain verified through attempt 3, dead-letter verified via synthetic attempt=7 injection.
- **2026-05-29** — Decision 11 added + ACCEPTED. `/v1/checkout` live; full consumer-RPC loop verified (happy path 201 + two 401 auth-wall probes pass).
- **2026-05-29** — Decision 10 added + ACCEPTED. Dispatcher live; full chain verified end-to-end with real Stripe trigger → consumer 200.
- **2026-05-29** — Repo restructure: scripts split into `scripts/{bootstrap,routes,handlers}/`; CF scaffold moved to `alt-runtime/cloudflare/`; ~55 mise tasks via verb dispatch.
- **2026-05-29** — Decision 9 added; runtime pivoted to http-nu + xs; Cloudflare retained as alt-runtime.
- **2026-05-28** — Decision 8 added (multi-project metadata namespacing).
- **2026-05-28** — Real $31.90 sandbox payment on AU-registered `acct_1QJrzxABkTiOs5on` end-to-end; 12 webhook events HMAC-verified.
