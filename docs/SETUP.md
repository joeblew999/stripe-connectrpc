# Stripe account setup

One-time dance. After it, `mise run dev:up` + `mise run test -- checkout` is the daily loop.

A real $31.90 sandbox payment + 9/9 webhook-event delivery has been verified end-to-end against AU-registered account `acct_1QJrzxABkTiOs5on`. Steps below get any fresh account to the same point.

## Country eligibility (check FIRST)

SMP requires the Stripe account to be registered in one of **38 supported countries**. List: <https://docs.stripe.com/payments/managed-payments/eligibility#supported-business-locations>. Excluded: TH, MY, NZ, AE, BR, MX, IN, ID, and the 5 Paystack-Africa countries.

```sh
mise run show -- country AU      # what modes does <ISO> support?
```

If your operation is in a non-supported country:
1. Register the Stripe account in a supported one (AU Pty Ltd or SG Pte Ltd is the typical cross-border setup).
2. Or drop to regular Stripe Payments — you become MoR, you handle tax. Use `mise run test -- checkout-payments` instead of `test -- checkout`.

## Required keychain entries

Two for the primary runtime:

| Item | Used by | Source |
|---|---|---|
| `SMP_STRIPE_SECRET_KEY` | stripe-cli + handler.nu | Dashboard → Developers → API keys → Secret key (`sk_test_…` / `sk_live_…`) |
| `SMP_STRIPE_WEBHOOK_SECRET` | `routes/webhook.nu` HMAC verify | Local: `mise run dev:up` prints one on first run via `stripe listen`. Deployed: Dashboard → Webhooks → endpoint → Signing secret |

Optional (once deployed):

| Item | Used by |
|---|---|
| `SMP_SERVICE_URL` | `apply -- webhook` (registers Stripe webhook at `<url>/v1/webhook`) |
| `SMP_CONSUMER_<SLUG>_SIGNING_SECRET` | dispatcher → consumer HMAC sign — one per consumer ([CONSUMERS.md](CONSUMERS.md)) |

Alt-runtime (`cf:*` only):

| Item | Used by |
|---|---|
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | wrangler deploy |

`mise run onboard` walks you through populating these. `mise run verify` confirms.

## Setup steps

**1. Create the Stripe account** — <https://dashboard.stripe.com/register>. Country must be on the SMP seller list. Test mode is usable immediately; no activation needed for sandbox.

**2. Pair stripe-cli** (optional but recommended): `mise run stripe:login` — browser flow.

**3. Get the secret key into the keychain:**
```sh
mise run open:stripe-keys                # only opens browser if key not yet in keychain
fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_test_…'   # -p keychain is non-negotiable
```

**4. Verify:**
```sh
mise run verify              # tools + keychain
mise run show -- account     # mode=TEST, country, charges_enabled=true
```

**5. Seed Stripe state:**
```sh
mise run apply -- all        # products + prices + portal + payment-methods (idempotent)
```

Webhook registration is skipped until `SMP_SERVICE_URL` is set (Phase 4 — once you deploy).

**6. First sandbox payment:**
```sh
mise run dev:up              # http + listen + dispatcher daemons
# first run: copy whsec_ from `dev:logs` output into keychain:
fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'
mise run dev:restart-http    # handler picks up the new env var

mise run test -- checkout    # prints checkout.stripe.com URL
# pay with 4242 4242 4242 4242, any future expiry, any CVC
```

`mise run xs:counts` shows the topic deltas land in xs. `mise run dispatch:delivered` shows consumer fan-out outcomes (Phase 3).

## Going live

1. Activate the account (KYC, bank, tax id) — `charges_enabled: true` in live mode.
2. Enable SMP in live mode (Dashboard → Settings → Managed Payments).
3. Swap keychain to live: `fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_live_…'`.
4. Deploy http-nu+xs (Phase 4 — see future deploy doc) → capture URL → `fnox set -p keychain SMP_SERVICE_URL '…'`.
5. `mise run apply -- webhook` → captures `whsec_` → set `SMP_STRIPE_WEBHOOK_SECRET` for live.
6. Real-card test via `mise run test -- checkout`.

The data files (`data/projects/<slug>/*` and `data/reference/*`) are mode-agnostic; live mode reuses everything except keys and deployed URL.
