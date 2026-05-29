# Stripe SMP

Stripe Managed Payments shared service on Cloudflare Workers (Rust / wasm32).

Stripe is the merchant of record — see [stripe.com/managed-payments](https://stripe.com/managed-payments). smp is the only place Stripe API keys live; consumer apps call smp for both ops actions (refund, cancel, portal) and billing-state queries. The web app never embeds Stripe.js; all user-facing payment UIs are Stripe-hosted (Checkout + Customer Portal).

**Status:** real sandbox payment landed end-to-end (AU-registered Stripe account, $29 SaaS subscription + $2.90 SMP-handled tax = $31.90 charged). All 12 webhook events HMAC-verified on wasm32 in the smp Worker.

## Stripe Atlas

[Stripe Atlas](https://dashboard.stripe.com/register/atlas) — incorporate a US company (Delaware C-Corp) through Stripe.

**Why this might matter for smp:** Atlas gives you a US-registered Stripe account, which is one of the 38 SMP seller countries. Combined with SMP, that account can sell globally with Stripe as MoR.

**Why we don't need it today:** the currently-operating Stripe account is AU-registered, which is *also* an SMP seller country. We aren't using any payment method that requires a country-specific local company:

- Card / Apple Pay / Link → global, no local company needed
- PromptPay / iDEAL / Bancontact / Pix / etc. → would require a local seller country, but **we don't offer them**

Stripe Atlas would become relevant only if we wanted to additionally accept US-specific methods (e.g. ACH Direct Debit, Cash App Pay) and didn't already have a US presence. Out of scope for now.

[Carta × Stripe Atlas partnership](https://carta.com/product-updates/carta-stripe-atlas-api-partnership/) — pushes Atlas cap-table details into Carta automatically. Useful when (if) we incorporate.



## Stack

- `workers-rs` 0.8 on `wasm32-unknown-unknown`.
- [arlyon/async-stripe](https://github.com/arlyon/async-stripe) v1.0.0-rc.5 runtime-free sub-crates:
  - `async-stripe-checkout` — managed Checkout Sessions (`managed_payments[enabled]=true`).
  - `async-stripe-webhook` — inbound HMAC signature verification (sync, wasm-clean).
  - `async-stripe-client-core` — request builders + API version pin (`2025-03-31.basil`).
- `worker::Fetch` will execute outbound Stripe HTTP via a small `StripeClient` adapter (forthcoming; for now bootstrap calls go through stripe-cli from your laptop).
- Secrets via [fnox](https://github.com/fnox-dev/fnox) → macOS keychain → mise → wrangler (.dev.vars materialized from fnox at `worker:dev` startup).
- Tasks orchestrated through `mise.toml`; scripts in `nushell` for OS neutrality.

## Onboarding (fresh clone)

```sh
mise run mise:install   # rust, wrangler, worker-build, stripe-cli, nushell (versions pinned)
mise run onboard        # interactive: collect CF + Stripe creds into keychain
mise run verify         # confirm tools, target, keychain entries
```

For a first-time Stripe account walkthrough (account country requirement, SMP activation, API key into fnox), see **[docs/SETUP.md](docs/SETUP.md)**.

## Dev loop

Two long-running daemons (`wrangler dev` + `stripe listen`) are supervised by [pitchfork](https://github.com/jdx/pitchfork) — config in `pitchfork.toml`. One command starts both, auto-restart on crash (DNS blips, etc.).

```sh
mise run dev:up         # start worker + stripe listen
mise run dev:logs       # tail both
mise run dev:status     # which are running
mise run dev:tui        # interactive dashboard
mise run dev:down       # stop both
```

Single-daemon control:
```sh
mise run dev:restart-worker   # after editing src/ or .dev.vars
mise run dev:restart-listen   # after rotating the webhook signing secret
```

Other:
```sh
mise run cargo:check                # type-check against wasm32
mise run stripe:trigger-completed   # synthetic checkout.session.completed
```

## Stripe-side bootstrap (one-time per account)

```sh
mise run bootstrap:account     # confirm test mode + country + capabilities
mise run bootstrap:all         # products + prices + portal + webhook (per project)
mise run bootstrap:status      # snapshot of everything Stripe-side
mise run bootstrap:projects    # list registered consumer projects
```

All idempotent — re-running tags any missing `metadata.project=<slug>` on existing objects, never duplicates state.

## End-to-end sandbox payment (Human-in-the-loop, verified working)

One supervised pair + one shell for the checkout (Stripe test mode):

```sh
mise run dev:up
#   ▸ pitchfork starts wrangler dev (:8787) + stripe listen
#   ▸ first run: copy printed whsec_ into the keychain:
#       fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_...'
#       mise run dev:restart-worker   # so .dev.vars regenerates

mise run test:checkout
#   ▸ default lookup_key: sports_coach_monthly_usd (Remy Sport)
#   ▸ prints checkout.stripe.com/c/pay/... URL
#   ▸ open in browser, pay with test card 4242 4242 4242 4242
#   ▸ mise run dev:logs  → shows ~12 events:
#     customer.created, customer.subscription.created, invoice.paid,
#     payment_intent.succeeded, checkout.session.completed, …
#     all HMAC-verified and acked 200 by smp.
```

Stripe Payments mode (we are MoR, no SMP):
```sh
mise run test:checkout-payments
```

Pick a different tier:
```sh
nu scripts/bootstrap.nu test-checkout sports_player_yearly_usd
```

## Repo layout

```
stripe-smp/
├── Cargo.toml / Cargo.lock          # Rust crate (workers-rs + async-stripe)
├── wrangler.toml                    # Cloudflare Worker config
├── pitchfork.toml                   # supervised dev daemons (worker + listen)
├── fnox.toml                        # secrets routing — keychain → env
├── mise.toml                        # all task entry points + tool versions
├── src/                             # Worker code (Rust)
├── scripts/                         # nushell — bootstrap, onboard, verify, open, refresh
└── data/
    ├── reference/                   ← Stripe-sourced; refresh via `mise run data:check`
    │   ├── countries.jsonl          # 60 rows — seller + buyer eligibility per country
    │   ├── tax-codes.jsonl          # 72 rows — SMP-eligible product tax codes
    │   ├── tax-coverage.jsonl       # 82 rows — buyer countries where Stripe handles tax
    │   ├── payment-methods.jsonl    # 24 rows — desired account-pool methods
    │   └── webhook-events.jsonl     #  9 rows — events smp subscribes to from Stripe
    ├── projects/                    ← one dir per consumer app
    │   ├── remy-sport/              # first consumer (basketball SaaS)
    │   │   ├── project.json         # {slug, name, domain, consumer: {webhook_url, secrets, filters}}
    │   │   ├── products.jsonl
    │   │   └── prices.jsonl
    │   └── demo-app/                # second consumer (proves isolation)
    │       ├── project.json
    │       ├── products.jsonl
    │       └── prices.jsonl
    └── launches.jsonl               ← project × country × mode tracker
```

All Stripe objects created by bootstrap are tagged `metadata.project=<slug>` so the Stripe Dashboard / queries can filter by project. Adding a third consumer: `mkdir data/projects/<slug>/`, drop the three files, run `bootstrap:products` + `bootstrap:prices`. Per-project teardown (cross-leak safe): `mise run bootstrap:teardown -- <slug>`. See [data/projects/README.md](data/projects/README.md) and [data/README.md](data/README.md).

## Worker endpoints (v0)

- `GET  /health`     — liveness probe
- `POST /v1/webhook` — Stripe → smp; HMAC-verified, logs the event, acks 200

Outbound `StripeClient` adapter, ConnectRPC consumer surface, D1 persistence, and CF Queues-based delivery to consumer apps land in subsequent commits.

## Deploy (later)

```sh
mise run worker:secret-put  # push STRIPE_* secrets to wrangler
mise run worker:deploy      # deploy to Cloudflare
```

Capture the resulting URL: `fnox set -p keychain SMP_WORKER_URL 'https://smp.<sub>.workers.dev'`. Then `mise run bootstrap:webhook` registers the Stripe webhook endpoint pointed at it. See [docs/SETUP.md § Going live](docs/SETUP.md#going-live-later).
