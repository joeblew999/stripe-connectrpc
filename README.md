# smp

Stripe Managed Payments shared service on Cloudflare Workers (Rust / wasm32).

Stripe is the merchant of record — see [stripe.com/managed-payments](https://stripe.com/managed-payments). smp is the only place Stripe API keys live; consumer apps call smp for both ops actions (refund, cancel, portal) and billing-state queries. The web app never embeds Stripe.js; all user-facing payment UIs are Stripe-hosted (Checkout + Customer Portal).

## Stack

- `workers-rs` 0.8 on `wasm32-unknown-unknown`.
- [arlyon/async-stripe](https://github.com/arlyon/async-stripe) v1.0.0-rc.5 runtime-free sub-crates:
  - `async-stripe-checkout` — managed Checkout Sessions (`managed_payments[enabled]=true`).
  - `async-stripe-webhook` — inbound HMAC signature verification (sync, wasm-clean).
  - `async-stripe-client-core` — request builders + API version pin (`2025-03-31.basil`).
- `worker::Fetch` executes outbound Stripe HTTP via a small `StripeClient` adapter (forthcoming).
- Secrets via [fnox](https://github.com/fnox-dev/fnox) → macOS keychain → mise → wrangler.
- Tasks orchestrated through `mise.toml`; scripts in `nushell` for OS neutrality.

## Onboarding (fresh clone)

```sh
mise run mise:install   # rust, wrangler, worker-build, stripe-cli, nushell
mise run onboard        # interactive: collect CF + Stripe creds into keychain
mise run verify         # confirm tools, target, keychain entries
```

For a first-time Stripe account (incl. Thailand-specific notes), see **[docs/SETUP.md](docs/SETUP.md)**.

## Dev loop

```sh
mise run cargo:check        # type-check against wasm32
mise run worker:dev         # wrangler dev with fnox-resolved env

# In another terminal:
mise run stripe:listen      # forward Stripe webhooks to localhost:8787/v1/webhook
mise run stripe:trigger-completed   # send a test checkout.session.completed
```

## Deploy

```sh
mise run worker:secret-put  # push STRIPE_* secrets to wrangler
mise run worker:deploy      # deploy
```

## Endpoints (v0 bare minimum)

- `GET  /health`     — liveness probe
- `POST /v1/webhook` — Stripe → smp; HMAC-verified, logs the event, acks 200

The ConnectRPC service (checkout / portal / refund / subscription / customer queries), D1 persistence, and CF Queues-based delivery to consumer apps land in subsequent commits.

## Stripe-side bootstrap (one-time per account)

After `mise run onboard` populates the keychain:

```sh
mise run bootstrap:account     # confirm test mode + capabilities
mise run bootstrap:all         # products + prices + portal + webhook
mise run bootstrap:status      # snapshot of everything just created
```

All idempotent — re-run any time. Driven by `data/*.jsonl` + the official Stripe CLI.

## End-to-end sandbox payment

In three terminals (Stripe test mode):

```sh
# Terminal 1 — local Worker
mise run worker:dev

# Terminal 2 — forward Stripe webhooks → localhost:8787/v1/webhook
mise run stripe:listen
#   ▸ prints `whsec_...` on first run.
#   ▸ copy it once: fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_...'

# Terminal 3 — create a Checkout Session URL
mise run test:checkout         # default: sports_coach_monthly_usd
#   ▸ prints a checkout.stripe.com URL
#   ▸ open in browser
#   ▸ pay with test card 4242 4242 4242 4242 (any future expiry / CVC / zip)
#   ▸ Terminal 1 logs the checkout.session.completed event from smp
```

Pick a different tier:
```sh
nu scripts/bootstrap.nu test-checkout sports_player_yearly_usd
```
