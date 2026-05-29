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
stripe.intent.<resource>.<verb>   consumer-initiated (planned, /v1/checkout)
stripe.api.<resource>.<verb>      Stripe response (planned)
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

**Open questions deferred:**
- Retry policy on `stripe.dispatch.failed` (today: none; just logged).
- Concurrent dispatch fan-out per project (today: serial).
- `event_filters` granularity (today: exact + trailing `*`).

## Revisions

- **2026-05-29** — Decision 10 added + ACCEPTED. Dispatcher live; full chain verified end-to-end with real Stripe trigger → consumer 200.
- **2026-05-29** — Repo restructure: scripts split into `scripts/{bootstrap,routes,handlers}/`; CF scaffold moved to `alt-runtime/cloudflare/`; ~45 mise tasks via verb dispatch.
- **2026-05-29** — Decision 9 added; runtime pivoted to http-nu + xs; Cloudflare retained as alt-runtime.
- **2026-05-28** — Decision 8 added (multi-project metadata namespacing).
- **2026-05-28** — Real $31.90 sandbox payment on AU-registered `acct_1QJrzxABkTiOs5on` end-to-end; 12 webhook events HMAC-verified.
