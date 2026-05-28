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

Why: a single Stripe account with metadata namespacing is the simplest scheme that scales to many internal projects without onboarding each as a Stripe Connect sub-account. Adding a second project is `mkdir data/projects/<slug> && bootstrap:all` — no new accounts, no new secrets.

## Country & tax-code eligibility (verified 2026-05-28)

SMP eligibility is **strictly narrower** than general Stripe availability — verified against <https://docs.stripe.com/payments/managed-payments/eligibility>.

- **SMP seller countries**: 38, captured in `data/reference/countries.jsonl` with `seller_modes` containing `"smp"`. Notably **excluded**: TH, MY, NZ, AE, BR, MX, IN, ID, and the 5 Paystack-Africa countries.
- **SMP buyer reach**: 195+ countries minus 9 restricted (AC, CN, CU, IR, XK, KP, RU, SY, TA) — flagged in the same `countries.jsonl` via `buyer_blocked_modes`.
- **SMP eligible tax codes**: 72, all in the digital-goods / digital-services range — `data/reference/tax-codes.jsonl`. Products MUST use one of these. Physical goods, professional services, and live-in-person events are excluded.
- **SMP tax coverage** (where Stripe handles VAT/GST for buyers): 82 countries — `data/reference/tax-coverage.jsonl`. Two carve-outs: JP (all domestic), SG (B2B domestic).
- **Other product constraints**: direct integrations only (no Connect platforms / Express accounts), fully automated digital products (no live human-in-loop coaching).

Implication: an SMP rollout is gated on the Stripe account being registered in one of the 38 supported countries. If the operation is based in a non-supported country, the choice is (a) incorporate a Stripe account elsewhere, (b) drop to regular Stripe Payments (we become MoR, we handle tax), or (c) wait for Stripe to extend SMP. `mise run bootstrap:account` reports the account country; `mise run check-country -- <ISO>` shows what modes work for any country.

## Revisions

- **2026-05-28** — Decision 8 added (multi-project model). All Stripe objects now carry `metadata.project=<slug>`. `data/products.jsonl` and `data/prices.jsonl` moved under `data/projects/remy-sport/`.
- **2026-05-28** — Decision 7 expanded to cover `.dev.vars` materialization for `wrangler dev` (wrangler doesn't read process env vars for secrets).
- **2026-05-28** — Real SMP sandbox payment verified end-to-end on the AU-registered Stripe account `acct_1QJrzxABkTiOs5on`. $29 base + $2.90 SMP-handled tax = $31.90 charged. 12 webhook events HMAC-verified by `async-stripe-webhook` on wasm32 in `wrangler dev`.
