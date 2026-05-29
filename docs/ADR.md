# smp architecture decisions

Status: accepted — 2026-05-28
Single ADR. When a decision flips, edit in place and add a dated entry under "Revisions" at the bottom.

## Context

We need a shared backend that takes payments via Stripe Managed Payments (Stripe is merchant of record — absorbs global indirect tax). The web app must NEVER embed Stripe.js or handle cards directly; all user-facing payment UI is Stripe-hosted (Checkout + Customer Portal). smp is the only place Stripe API keys live; consumer apps call smp for both ops actions and billing-state queries.

## Decisions

### 1. Stack: workers-rs + async-stripe runtime-free sub-crates

Deploy as a Rust Cloudflare Worker (`wasm32-unknown-unknown`). Use [arlyon/async-stripe](https://github.com/arlyon/async-stripe) v1.0.0-rc.5 split sub-crates: `-types`, `-shared`, `-client-core`, `-webhook`, `-checkout`. Outbound HTTP via `worker::Fetch` through a small `StripeClient` trait impl (~50 LOC, forthcoming). The locked `async-stripe` HTTP client (tokio/hyper) is deliberately NOT used — it doesn't compile to wasm32.

Why: types and request builders codegen from Stripe's OpenAPI weekly — we get every API change for free. The runtime-free split (April 2026) made this combo possible. Verified to compile against wasm32 on 2026-05-28 and to verify real Stripe-signed webhook payloads end-to-end against a TEST mode account on the same day.

### 2. User flow: Stripe-hosted only

Web app never embeds Stripe.js / Elements / publishable keys / card forms. Web app calls smp → smp creates a Checkout Session with `managed_payments[enabled]=true` → web app redirects user to `checkout.stripe.com/...`. User pays on Stripe's domain. Stripe webhooks smp. Web app self-serve (update card, cancel sub) goes through Stripe Customer Portal (also Stripe-hosted).

Why: zero PCI surface for us. Stripe handles MoR liability + tax. Web app stays simple.

### 3. Storage: D1; no Durable Objects yet

D1 will hold: `events` (webhook idempotency dedup on Stripe `event.id`), `customers` (external_id → stripe_customer_id mapping), `consumers` (consumer-app registry with bearer-token hash + signing secret). Not yet implemented; current Worker only logs.

No DO in v1. Add a per-customer DO ONLY when one of these fires:
- A streaming RPC need lands (live billing-state dashboard).
- Observed contention on a single customer creates real ordering bugs.

Neither is load-bearing today. D1 unique-index dedup is correctness-equivalent to DO-based dedup for our event volume.

### 4. Delivery to consumer apps: D1 + CF Queues + signed webhooks

When Stripe webhooks land, smp: (a) verifies HMAC, (b) writes to D1 with `event.id` unique constraint, (c) enqueues to CF Queue. Queue consumer reads, POSTs to each registered consumer's webhook URL with consumer-specific HMAC-SHA256 signature. Retries handled by the Queue layer.

Why: Stripe gets fast 2xx. Consumer downtime doesn't drop events. Same auth pattern Stripe uses with us — consumers learn it once.

### 5. Consumer-facing API: ConnectRPC + one HTTP outlier

smp exposes ConnectRPC methods for ops and queries (CreateCheckoutSession, CreateBillingPortal, CancelSubscription, ListSubscriptions, ListInvoices, CreateRefund, GetCustomer). The one non-RPC endpoint is `POST /v1/webhook` for Stripe's HMAC-signed form-encoded webhook — can't speak ConnectRPC there.

Why: matches the connectrpc-cedar pattern. Consumer apps generate typed clients from the `.proto`.

### 6. Bootstrap: stripe-cli + nushell + per-project JSONL

Stripe-side state (webhook endpoints, products, prices, tax registrations) is bootstrapped via [stripe-cli](https://github.com/stripe/stripe-cli) driven by nushell scripts that read JSONL data files. async-stripe is library-only — no Rust CLI. stripe-cli (Go) is the official tool and handles this need.

Why: idempotent declarative state via data files in the repo. No Rust CLI to maintain.

### 7. Secrets: fnox → keychain → mise → wrangler (via `.dev.vars` materialization)

Per repo `fnox.toml` maps env var names (CLOUDFLARE_API_TOKEN, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_API_KEY alias) to keychain items (CLOUDFLARE_* shared across repos, SMP_STRIPE_* per-repo). `mise run onboard` populates the keychain interactively. `mise run worker:secret-put` pushes STRIPE_* to wrangler secrets for `wrangler deploy`.

For `wrangler dev`: secrets must be in `.dev.vars` (wrangler dev doesn't read env vars). `scripts/worker-dev.nu` materializes `.dev.vars` from fnox-resolved env at startup. `.dev.vars` is gitignored — it's a materialization point, never a source of truth. Never hand-edit it.

### 8. Multi-project model: directory + metadata, single Stripe account

Each consumer app is a project. One directory per project under `data/projects/<slug>/` with its own `project.json`, `products.jsonl`, `prices.jsonl`. Every Stripe object created on a project's behalf carries `metadata.project=<slug>` so the Stripe Dashboard / API queries can filter cleanly. One Stripe account hosts everything — **no Stripe Connect** (which is for marketplaces with separate merchant entities, not internal project namespacing).

Why: a single Stripe account with metadata namespacing is the simplest scheme that scales to many internal projects without onboarding each as a Stripe Connect sub-account. Adding a second project is `mkdir data/projects/<slug> && apply:all` — no new accounts, no new secrets.

## Country & tax-code eligibility (verified 2026-05-28)

SMP eligibility is **strictly narrower** than general Stripe availability — verified against <https://docs.stripe.com/payments/managed-payments/eligibility>.

- **SMP seller countries**: 38, captured in `data/reference/countries.jsonl` with `seller_modes` containing `"smp"`. Notably **excluded**: TH, MY, NZ, AE, BR, MX, IN, ID, and the 5 Paystack-Africa countries.
- **SMP buyer reach**: 195+ countries minus 9 restricted (AC, CN, CU, IR, XK, KP, RU, SY, TA) — flagged in the same `countries.jsonl` via `buyer_blocked_modes`.
- **SMP eligible tax codes**: 72, all in the digital-goods / digital-services range — `data/reference/tax-codes.jsonl`. Products MUST use one of these. Physical goods, professional services, and live-in-person events are excluded.
- **SMP tax coverage** (where Stripe handles VAT/GST for buyers): 82 countries — `data/reference/tax-coverage.jsonl`. Two carve-outs: JP (all domestic), SG (B2B domestic).
- **Other product constraints**: direct integrations only (no Connect platforms / Express accounts), fully automated digital products (no live human-in-loop coaching).

Implication: an SMP rollout is gated on the Stripe account being registered in one of the 38 supported countries. If the operation is based in a non-supported country, the choice is (a) incorporate a Stripe account elsewhere, (b) drop to regular Stripe Payments (we become MoR, we handle tax), or (c) wait for Stripe to extend SMP. `mise run show:account` reports the account country; `mise run show:country -- <ISO>` shows what modes work for any country.

## Revisions

- **2026-05-29** — **Runtime pivoted to http-nu + xs** (cablehead's stack). Decision 1 (workers-rs as primary runtime) is now in second place; the http-nu+xs runtime is primary because it's OS-neutral, requires no Rust toolchain, runs anywhere from laptop to VPS, and the bootstrap layer was already nushell-first. Decision 4 (D1+Queues for delivery) is replaced by xs streams + nushell subscribers. `.dev.vars` materialization in Decision 7 only applies to the retained `cf:*` Cloudflare path. End-to-end pipeline re-verified on the new runtime: 7/7 HMAC-verified events from a Stripe trigger landed in xs as `stripe.webhook.verified`. The Cloudflare Workers scaffold (`src/`, `wrangler.toml`, `Cargo.toml`) is retained under `cf:*` tasks for if/when CDN edge deployment is wanted. Decision 9 (next entry) captures this in full.
- **2026-05-29** — Decision 9 added (mise task surface collapsed to verb-form). 23 `show:*` / `apply:*` / `test:*` / `teardown:*` named tasks collapsed into 4 verb tasks (`show`, `apply`, `test`, `teardown`) that take a positional subcommand. Bootstrap script's main now does verb-first dispatch; backward-compat flat dispatch retained. Net: 55 tasks → 39.
- **2026-05-28** — Decision 8 added (multi-project model). All Stripe objects now carry `metadata.project=<slug>`. `data/products.jsonl` and `data/prices.jsonl` moved under `data/projects/remy-sport/`.
- **2026-05-28** — Decision 7 expanded to cover `.dev.vars` materialization for `wrangler dev` (wrangler doesn't read process env vars for secrets).
- **2026-05-28** — Real SMP sandbox payment verified end-to-end on the AU-registered Stripe account `acct_1QJrzxABkTiOs5on`. $29 base + $2.90 SMP-handled tax = $31.90 charged. 12 webhook events HMAC-verified by `async-stripe-webhook` on wasm32 in `wrangler dev`. (Initial verification on the Cloudflare runtime; same flow re-verified on http-nu+xs.)

## Decision 9 — Runtime pivot: http-nu + xs (cablehead stack)

**Date:** 2026-05-29

The primary runtime is now [http-nu](https://github.com/cablehead/http-nu) hosting an embedded [xs](https://github.com/cablehead/xs) event store. The Cloudflare Workers runtime (Decision 1) is retained as an alternative path under `cf:*` mise tasks.

### Why pivot

- **Bootstrap is already nushell-first.** The apply/show/teardown layer was 100% nushell + stripe-cli + JSONL. The Cloudflare runtime was the only Rust-shaped piece, and it forced us to bend around Workers constraints (wasm32 dep tree, async-stripe runtime-free fork, `.dev.vars` materialization).
- **The runtime model is event-sourced.** That's what xs is built for. D1+Queues would have been a reimplementation of the same model on Cloudflare primitives.
- **No vendor lock-in for the runtime.** Runs on a laptop, a VPS, a Tailnet node — wherever http-nu fits.
- **Aligns with existing project tooling** (http-nu push-native, http-nu email-native).

### What changes architecturally

- **Decision 1 (workers-rs stack)** is now an alternative path retained behind `cf:*` tasks. The Cargo crate, src/, and wrangler.toml stay in the repo for deploy-on-demand.
- **Decision 3 (D1 storage)** is replaced for the primary runtime: events live in xs (append-only, content-addressable, topic-indexed). D1 still applies if you take the `cf:*` path.
- **Decision 4 (Queues fan-out)** is replaced: xs subscribers handle consumer fan-out. Same model (signed HTTP POSTs to consumer webhook URLs), just driven by xs subscriptions instead of CF Queues.
- **Decision 5 (ConnectRPC consumer-facing surface)** still applies — http-nu can serve ConnectRPC-shaped routes; future consumer-RPC routes will live in `scripts/handler.nu`.
- **Decision 7 (`.dev.vars`)** is now Cloudflare-path-only. The http-nu daemon is wrapped in `fnox exec --` (see `pitchfork.toml`) so handler.nu inherits `STRIPE_WEBHOOK_SECRET` etc. directly from the keychain.

### Topic naming

```
stripe.webhook.received         raw inbound from /v1/webhook
stripe.webhook.verified         HMAC valid
stripe.webhook.invalid          HMAC failed / missing header

stripe.intent.<resource>.<verb> consumer-initiated (planned)
                                e.g. stripe.intent.session.create
stripe.api.<resource>.<verb>    Stripe response (planned)
                                e.g. stripe.api.session.created
stripe.webhook.dispatched.<consumer>   per-consumer fan-out attempt (planned)
stripe.webhook.delivered.<consumer>    successful delivery
stripe.webhook.dead-letter.<consumer>  delivery failure beyond retry budget
```

### HMAC verification

`scripts/handler.nu` does the verify inline, openssl-shelled (`openssl dgst -sha256 -hmac <secret>`). nushell doesn't have HMAC natively; openssl is on every macOS / Linux box. The signed-payload format is Stripe's standard: `timestamp.body`, hex-hmac-sha256, compared to `v1=…` in the Stripe-Signature header.

### What's not yet built

- ~~Dispatcher handler subscribing to `stripe.webhook.verified` and fanning out to per-project `webhook_url` + per-consumer signing secret.~~ **DONE** — see Decision 10 + `scripts/handlers/dispatcher.nu`.
- `/v1/checkout` route emitting `stripe.intent.session.create` and awaiting `stripe.api.session.created` reply.
- Replay / drift detection / projections.
- Automatic retry policy on `stripe.dispatch.failed` (currently no retry — failed events are logged but not re-driven).

These are mechanical follow-ons of the event substrate, not architectural changes.

## Decision 10 — Consumer fan-out model (Phase 3) — 2026-05-29

**Status:** ACCEPTED 2026-05-29. Implemented in `scripts/handlers/dispatcher.nu`; supervised by pitchfork as the `dispatcher` daemon. Consumer integration contract documented in `docs/CONSUMERS.md`.

### Context

The runtime (Decision 9) lands verified Stripe events in xs as `stripe.webhook.verified`, tagged with `metadata.project=<slug>`. Phase 3 is delivering those events to the right consumer app (e.g. remy-sport on Workers). The `consumer` block already exists in each `data/projects/<slug>/project.json` as forward-looking schema:

```json
"consumer": {
  "webhook_url":               "https://remy-sport.example/_internal/stripe-smp",
  "signing_secret_keychain":   "REMY_SPORT_SMP_WEBHOOK_SECRET",
  "bearer_token_keychain":     "REMY_SPORT_SMP_BEARER_TOKEN",
  "event_filters":             ["checkout.session.completed", "invoice.paid"]
}
```

No code reads it yet. We need to pick the delivery mechanism.

### Options

**A. Webhook push (smp → consumer HTTP POST).** Dispatcher subscribes to xs, signs each event with the consumer's HMAC secret, POSTs to `consumer.webhook_url`. Retries with exponential backoff stored back into xs as `stripe.dispatch.*` events. Consumer can run anywhere (CF Worker, Vercel, Fly, Hetzner). Same auth pattern Stripe uses with us — consumers learn HMAC verify once.

**B. xs subscription (consumer reads xs directly).** Consumer process opens a long-lived connection to smp's xs (UDS locally, TCP across hosts) and subscribes filtered by `metadata.project=<slug>`. Zero retry logic on smp. Requires the consumer to be co-located with — or have network reachability to — smp's xs. Couples consumers to xs as a public-ish API surface.

**C. ConnectRPC server-stream (smp.Subscribe).** Consumer calls `smp.Subscribe({project, since_id})` over ConnectRPC, gets a typed server-stream of intents/events. smp implements the stream by tailing xs. Plays well with `connectrpc-cedar`. Long-lived HTTP/2 connections.

### Decision

**Pick A (webhook push), dual-emit to xs.** The dispatcher subscribes to `stripe.webhook.verified`, signs+POSTs to each project's `consumer.webhook_url`, and appends the dispatch attempt (success or failure) as `stripe.dispatch.attempted` / `.delivered` / `.failed` events back to xs. xs remains the authoritative log; HTTP push is the delivery transport.

### Why A over B and C

- **Phase 5 reality:** consumer apps (remy-sport, etc.) will run on Workers / Fly / Vercel — not co-located with smp. Option B is dead on arrival across the WAN. Option C works but requires a per-language SDK + long-lived stream management.
- **Failure modes are familiar:** HTTP webhook push is the pattern Stripe → smp already uses. We invert it for smp → consumer. Same retry/idempotency/HMAC verify code on the consumer side.
- **xs stays internal:** option B leaks xs as a public surface, which constrains us to xs's wire protocol forever. Webhook push keeps the contract at HTTP+HMAC+JSON.
- **Dual-emit gives audit + replay for free:** the same xs we use as substrate becomes the dispatch log. `stripe.dispatch.failed` events with consumer 5xx + attempt count are the retry queue. Re-running the dispatcher tails from the last `.delivered` SCRU128.

### What this commits us to

- A new handler subscriber: `scripts/handlers/dispatcher.nu` (or wherever we land after splitting handler.nu). Subscribes to `stripe.webhook.verified`, iterates registered projects, filters by `event_filters`, posts.
- Per-project keychain item lookup at dispatch time: `fnox get $project.consumer.signing_secret_keychain`. Cross-repo contract per `feedback-fnox-cross-repo-contract`.
- A retry policy: 3 attempts with 1s / 30s / 5min backoff, then dead-letter as `stripe.dispatch.dead-lettered`. Backoff state lives in xs metadata.
- A consumer-side verify helper (eventual): publish a small Rust/TS snippet showing the HMAC verify so consumers don't reinvent.
- No persistent queue infrastructure (Redis / CF Queues / NATS). xs IS the queue.

### What this rules out

- B and C above. If a future consumer truly needs streaming (live dashboard tail), C can be added on top of A — the events are already in xs.
- Polling the dispatcher externally — the dispatcher is xs-subscriber-driven.

### Open questions deferred to implementation

- Concurrent dispatch fan-out per project (one connection at a time vs. many) — start with one, add concurrency only if observed latency demands it.
- Exact backoff curve — pick from operating Stripe → us numbers, not theory.
- Per-event-type filtering granularity — the `event_filters` array suggests exact `event.type` match. Wildcards later if needed.
