# smp architecture decisions

Status: accepted — 2026-05-28
Single ADR. When a decision flips, edit in place and add a dated entry under "Revisions" at the bottom.

## Context

We need a shared backend that takes payments via Stripe Managed Payments (Stripe is merchant of record — absorbs global indirect tax). The web app must NEVER embed Stripe.js or handle cards directly; all user-facing payment UI is Stripe-hosted (Checkout + Customer Portal). smp is the only place Stripe API keys live; consumer apps call smp for both ops actions and billing-state queries.

## Decisions

### 1. Stack: workers-rs + async-stripe runtime-free sub-crates

Deploy as a Rust Cloudflare Worker (`wasm32-unknown-unknown`). Use [arlyon/async-stripe](https://github.com/arlyon/async-stripe) v1.0.0-rc.5 split sub-crates: `-types`, `-shared`, `-client-core`, `-webhook`, `-checkout`. Outbound HTTP via `worker::Fetch` through a small `StripeClient` trait impl (~50 LOC, forthcoming). The locked `async-stripe` HTTP client (tokio/hyper) is deliberately NOT used — it doesn't compile to wasm32.

Why: types and request builders codegen from Stripe's OpenAPI weekly — we get every API change for free. The runtime-free split (April 2026) made this combo possible. Verified to compile against wasm32 on 2026-05-28.

### 2. User flow: Stripe-hosted only

Web app never embeds Stripe.js / Elements / publishable keys / card forms. Web app calls smp → smp creates a Checkout Session with `managed_payments[enabled]=true` → web app redirects user to `checkout.stripe.com/...`. User pays on Stripe's domain. Stripe webhooks smp. Web app self-serve (update card, cancel sub) goes through Stripe Customer Portal (also Stripe-hosted).

Why: zero PCI surface for us. Stripe handles MoR liability + tax. Web app stays simple.

### 3. Storage: D1; no Durable Objects yet

D1 holds: `events` (webhook idempotency dedup on Stripe `event.id`), `customers` (external_id → stripe_customer_id mapping), `consumers` (consumer-app registry with bearer-token hash + signing secret).

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

### 6. Bootstrap: stripe-cli + nushell + JSONL data files

Stripe-side state (webhook endpoints, products, prices, tax registrations) is bootstrapped via [stripe-cli](https://github.com/stripe/stripe-cli) driven by nushell scripts that read JSONL data files. async-stripe is library-only — no Rust CLI. stripe-cli (Go) is the official tool and handles this need.

Why: idempotent declarative state via data files in the repo. No Rust CLI to maintain.

### 7. Secrets: fnox → keychain → mise → wrangler

Per repo `fnox.toml` maps env var names (CLOUDFLARE_API_TOKEN, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET) to keychain items (CLOUDFLARE_* shared across repos, SMP_STRIPE_* per-repo). `mise run onboard` populates the keychain interactively. `mise run worker:secret-put` pushes STRIPE_* to wrangler secrets. Never hand-edit `.dev.vars`.

## Country & tax-code eligibility (verified 2026-05-28)

SMP eligibility is **strictly narrower** than general Stripe availability — verified against <https://docs.stripe.com/payments/managed-payments/eligibility>.

- **SMP seller countries**: 38, captured in `data/countries.jsonl` with `smp_seller: true/false`. Notably **excluded**: TH, MY, NZ, AE, BR, MX, IN, ID, and the 5 Paystack-Africa countries.
- **SMP buyer reach**: 195+ countries minus 9 restricted (AC, CN, CU, IR, XK, KP, RU, SY, TA) — `data/restricted-buyer-countries.jsonl`.
- **SMP eligible tax codes**: 73, all in the digital-goods / digital-services range — `data/tax-codes.jsonl`. Products MUST use one of these. Physical goods, professional services, and live-in-person events are excluded.
- **Other product constraints**: direct integrations only (no Connect platforms / Express accounts), fully automated digital products (no live human-in-loop coaching).

Implication: an SMP rollout is gated on the Stripe account being registered in one of the 38 supported countries. If the operation is based in a non-supported country, the choice is (a) incorporate a Stripe account elsewhere, (b) drop to regular Stripe Payments (we become MoR, we handle tax), or (c) wait for Stripe to extend SMP.

## Revisions

_None yet._
