# Setting up smp against a real Stripe account

This is the one-time-per-account dance. After it, the daily loop is `mise run worker:dev` + `mise run stripe:listen` + `mise run test:checkout`.

## What we need from Stripe in the end

Two secrets in the macOS keychain (via fnox):

| Keychain item | Used by | Source |
|---|---|---|
| `SMP_STRIPE_SECRET_KEY` | Worker (Stripe API calls) + stripe-cli (alias `STRIPE_API_KEY`) | Dashboard → Developers → API keys → Secret key (sk_test_… in dev, sk_live_… in prod) |
| `SMP_STRIPE_WEBHOOK_SECRET` | Worker (HMAC verify) | For local: `stripe listen` prints one. For deployed: Dashboard → Webhooks → endpoint → Signing secret |

Plus Cloudflare:

| Keychain item | Source |
|---|---|
| `CLOUDFLARE_API_TOKEN` | dash.cloudflare.com → My Profile → API Tokens |
| `CLOUDFLARE_ACCOUNT_ID` | dash.cloudflare.com → right sidebar of any account page |

`mise run onboard` walks you through populating these interactively. `mise run verify` confirms they're all there.

## ⚠ Thailand isn't on the SMP seller list

**Important constraint to resolve before going further.**

Stripe's general country list (stripe.com/global, 51 countries) is for Stripe Payments. **Managed Payments has a narrower seller list — 38 countries — and Thailand is not on it.** Source: <https://docs.stripe.com/payments/managed-payments/eligibility#supported-business-locations>.

SMP seller countries: AT, AU, BE, BG, CA, CH, CY, CZ, DE, DK, EE, ES, FI, FR, GB, GI, GR, HK, HR, HU, IE, IT, JP, LI, LT, LU, LV, MT, NL, NO, PL, PT, RO, SE, SG, SI, SK, US.

Options:
1. **Register the Stripe account in a supported country** (SG and HK are closest to TH operationally — requires a local business presence / bank account there).
2. **Use regular Stripe Payments instead of SMP.** You're merchant of record; you handle indirect tax. Stripe Tax can calculate it, but you remit. This loses the main reason we picked SMP — only viable if the seller-MoR overhead is acceptable.
3. **Wait** — Stripe hasn't published a Thailand SMP timeline.

Run `mise run bootstrap:countries` to see the full list with markers.

If you proceed with a non-supported country anyway, `mise run bootstrap:account` will report the country and you can decide whether to abandon SMP. The rest of this doc assumes the Stripe account is registered in a supported country.

## Step 1 — Stripe account (manual, at stripe.com)

The CLI cannot create the account; KYC needs to happen in the browser.

1. **Sign up** at <https://dashboard.stripe.com/register>. Country must be on the SMP seller list above.
2. **Test mode is available immediately** — no activation required to play with sandbox payments. The dashboard top-right has a TEST / LIVE toggle. Stay in TEST until everything works end-to-end.
3. **Activate when ready for live** — Dashboard → Activate account. Country-specific requirements (business type, registration number, local bank account, tax ID).
4. **Enable Stripe Managed Payments**. SMP requires explicit account activation — look in Dashboard → Settings → Payments → Managed Payments. If you don't see the toggle, request access via Stripe support. SMP works in TEST mode for development before live activation.

## Step 2 — Get the API key into fnox

Once your account exists:

1. Dashboard → Developers → API keys → reveal the **Secret key** (`sk_test_…`).
2. Drop it into the keychain (`-p keychain` is critical — without it fnox writes the value into `fnox.toml` as plaintext):

   ```sh
   fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_test_…'
   ```

3. (Optional, nice-to-have) Pair the stripe-cli with your account so it can do convenience things (`stripe listen`, `stripe trigger`) without re-using the secret key:

   ```sh
   mise run stripe:login
   ```

   This opens a browser, pairs with the dashboard, and stores a *restricted* key in `~/.config/stripe/config.toml`. Useful if you'd rather not have the full secret key in keychain… but for our setup both routes end up working because `fnox.toml` aliases `STRIPE_API_KEY → SMP_STRIPE_SECRET_KEY` and stripe-cli prefers env vars over its config file.

## Step 3 — Verify

```sh
mise run verify           # tools + wasm target + keychain entries present
mise run bootstrap:account
```

`bootstrap:account` calls `stripe accounts retrieve` with the keychain key. You should see:

```
mode:               TEST
id:                 acct_…
country:            TH
default_currency:   thb
charges_enabled:    true
```

If `charges_enabled: false`, finish account activation first. If the call errors with auth issue, the keychain key is wrong.

## Step 4 — Seed Stripe-side state

```sh
mise run bootstrap:all
```

Runs (in order): products → prices → portal → webhook endpoint. Idempotent. The webhook step needs `SMP_WORKER_URL` in the keychain — skip it for the first local test (we use `stripe listen` instead).

## Step 5 — First real payment (test mode, real card not required)

Three terminals:

```sh
# T1
mise run worker:dev

# T2 — also captures whsec_ to copy into keychain
mise run stripe:listen
#   ▸ first line printed: "Ready! Your webhook signing secret is whsec_…"
#   ▸ copy it ONCE:
#       fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'
#   ▸ restart T1 so the Worker picks up the new secret

# T3
mise run test:checkout
#   ▸ prints checkout.stripe.com/c/pay/... URL
#   ▸ open in browser
#   ▸ pay with TEST card 4242 4242 4242 4242, any future expiry, any CVC
#   ▸ T1 logs the checkout.session.completed event from Stripe
```

That's it — first sandbox payment landed.

## Going live (later)

When you're ready for a real Thai card to actually charge:

1. Account fully activated, charges_enabled: true.
2. SMP enabled on the live mode (separate toggle from test mode).
3. Swap the keychain entry: `fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_live_…'`.
4. Deploy: `mise run worker:deploy`. Capture the URL: `fnox set -p keychain SMP_WORKER_URL 'https://smp.<sub>.workers.dev'`.
5. Register the live webhook: `mise run bootstrap:webhook`. Capture the `whsec_` it returns: `fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'`. Push: `mise run worker:secret-put`.
6. `mise run test:checkout` against the deployed Worker — pay with a real card.

The data files (`data/*.jsonl`) are mode-agnostic; live mode reuses everything except the keys and the deployed Worker URL.
