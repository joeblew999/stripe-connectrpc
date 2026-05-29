# Setting up smp against a real Stripe account

One-time-per-account dance. After it, the daily loop is `mise run worker:dev` + `mise run stripe:listen` + `mise run test:checkout`.

A sandbox payment has been verified working end-to-end against the AU-registered account `acct_1QJrzxABkTiOs5on` (2026-05-28) — see [docs/ADR.md § Revisions](ADR.md#revisions). The steps below are the path any new contributor / fresh account follows to reach the same point.

## What lands in the keychain in the end

Four entries (via fnox, against the macOS keychain):

| Keychain item | Used by | Source |
|---|---|---|
| `SMP_STRIPE_SECRET_KEY` | Worker (`STRIPE_SECRET_KEY` binding) + stripe-cli (`STRIPE_API_KEY` alias) | Dashboard → Developers → API keys → Secret key (`sk_test_…` in dev, `sk_live_…` in prod) |
| `SMP_STRIPE_WEBHOOK_SECRET` | Worker HMAC verify (`STRIPE_WEBHOOK_SECRET` binding) | Local: `stripe listen` prints one on first run. Deployed: Dashboard → Webhooks → endpoint → Signing secret |
| `CLOUDFLARE_API_TOKEN` | wrangler deploy | dash.cloudflare.com → My Profile → API Tokens |
| `CLOUDFLARE_ACCOUNT_ID` | wrangler deploy | dash.cloudflare.com → right sidebar of any account page |

Optional (captured once deployed):
| Keychain item | Used by |
|---|---|
| `SMP_WORKER_URL` | `apply:webhook` (registers Stripe webhook endpoint pointed at it) |

`mise run onboard` walks you through populating these interactively, opening the right dashboard page in your browser before each prompt. `mise run verify` confirms they're all there.

## ⚠ Check your Stripe account country FIRST

SMP only works if the Stripe account is registered in one of **38 supported countries**. The list is narrower than Stripe's general availability — see <https://docs.stripe.com/payments/managed-payments/eligibility#supported-business-locations>.

Supported (verified 2026-05-28): AT, AU, BE, BG, CA, CH, CY, CZ, DE, DK, EE, ES, FI, FR, GB, GI, GR, HK, HR, HU, IE, IT, JP, LI, LT, LU, LV, MT, NL, NO, PL, PT, RO, SE, SG, SI, SK, US.

**Not** on the SMP seller list: TH, MY, NZ, AE, BR, MX, IN, ID, plus the 5 Paystack-Africa countries.

If your operation is in a non-supported country, you have three options:
1. **Register the Stripe account in a supported country** (an Australian Pty Ltd or Singapore Pte Ltd is the typical cross-border setup — needs local presence / bank account there).
2. **Drop to regular Stripe Payments instead of SMP.** You're MoR; you handle indirect tax. Stripe Tax calculates it. Use `mise run test:checkout-payments` instead of `test:checkout`.
3. **Wait** — Stripe hasn't published an extension timeline.

Run `mise run show:country -- <ISO>` to see what modes any country supports.

## Step 1 — Stripe account (manual, at stripe.com)

The CLI cannot create the account; KYC needs to happen in the browser.

1. **Sign up** at <https://dashboard.stripe.com/register>. Country must be on the SMP seller list above.
2. **Test mode is available immediately** — no activation required to play with sandbox payments. The dashboard top-right has a TEST / LIVE toggle. Stay in TEST until everything works end-to-end.
3. **Activate when ready for live** — Dashboard → Activate account. Country-specific requirements (business type, registration number, local bank account, tax ID).
4. **Enable Stripe Managed Payments**. SMP requires explicit account activation — Dashboard → Settings → Managed Payments. If you don't see the toggle, request access via Stripe support. SMP works in TEST mode for development before live activation.
5. (Optional) **Pair stripe-cli with your account**: `mise run stripe:login` — opens a browser, stores a restricted key in `~/.config/stripe/config.toml`. The stripe-cli will work even without `STRIPE_API_KEY` env var.

## Step 2 — Get the API key into fnox

Once your account exists:

1. `mise run open:stripe-keys` — opens dashboard at the API keys page.
2. Reveal the **Secret key** (`sk_test_…`).
3. Drop it into the keychain. **The `-p keychain` flag is critical** — without it fnox writes the value into `fnox.toml` as plaintext:

   ```sh
   fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_test_…'
   ```

(Or run `mise run onboard` and follow the interactive prompts.)

## Step 3 — Verify

```sh
mise run verify                  # tools + wasm target + keychain entries present
mise run show:account       # Stripe sees the key, account is correctly configured
```

`show:account` should print:

```
mode:               TEST
id:                 acct_…
country:            <one of the 38 SMP countries>
default_currency:   <local currency>
charges_enabled:    true
```

If `charges_enabled: false`, finish account activation first. If the call errors with auth issue, the keychain key is wrong.

## Step 4 — Seed Stripe-side state

```sh
mise run apply:all
```

Runs (in order): for every project under `data/projects/<slug>/`: products → prices, each tagged `metadata.project=<slug>`. Then portal config. Then webhook endpoint (skipped if `SMP_WORKER_URL` isn't set — fine for first local test, we use `stripe listen` instead).

`apply:all` is fully idempotent — re-running tags any missing metadata on existing objects, never duplicates state.

Verify with stripe-cli:
```sh
fnox exec -- stripe products list --limit 10 | jq '.data[] | {id, name, metadata}'
```

You should see your three sports products with `metadata: {project: "remy-sport"}`.

## Step 5 — First sandbox payment (real card not needed — test card works)

Three terminals:

```sh
# T1 — local Worker
mise run worker:dev

# T2 — tunnel Stripe → localhost:8787/v1/webhook + capture whsec
mise run stripe:listen
#   ▸ first line printed: "Ready! Your webhook signing secret is whsec_…"
#   ▸ copy it ONCE:
#       fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'
#   ▸ Ctrl-C T1 and re-run `mise run worker:dev` so `.dev.vars` is regenerated

# T3 — create a real Checkout Session
mise run test:checkout
#   ▸ prints checkout.stripe.com/c/pay/... URL
#   ▸ open in browser
#   ▸ pay with TEST card 4242 4242 4242 4242, any future expiry, any CVC
#   ▸ T1 logs ~12 webhook events: customer.created, customer.subscription.created,
#     invoice.paid, payment_intent.succeeded, checkout.session.completed, …
#     all HMAC-verified by async-stripe-webhook on wasm32 and acked 200.
```

That's the first sandbox payment landed — see ADR Revisions for the actual numbers from 2026-05-28's run.

## Going live (later)

When you're ready for real cards:

1. Account fully activated, `charges_enabled: true` for live mode.
2. SMP enabled in live mode (separate toggle from test mode in the dashboard).
3. Swap the keychain entry to live: `fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_live_…'`.
4. Deploy: `mise run worker:deploy`. Capture the URL: `fnox set -p keychain SMP_WORKER_URL 'https://smp.<sub>.workers.dev'`.
5. Register the live webhook: `mise run apply:webhook` — creates a Stripe webhook endpoint pointed at your deployed Worker, returns a fresh `whsec_…`. Store it: `fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'`. Push to wrangler: `mise run worker:secret-put`.
6. `mise run test:checkout` against the deployed Worker — pay with a real card.

The data files (`data/projects/<slug>/*.jsonl` and `data/reference/*.jsonl`) are mode-agnostic; live mode reuses everything except the keys and the deployed Worker URL.
