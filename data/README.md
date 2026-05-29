# data/

Four clearly-separated groups so files don't get out of control as we grow.

```
data/
├── reference/             ← UPSTREAM — Stripe-sourced; refreshed via `data:check`
│   ├── countries.jsonl
│   ├── tax-codes.jsonl
│   └── tax-coverage.jsonl
├── config/                ← OUR CONFIG — hand-curated; never auto-refreshed
│   ├── payment-methods.jsonl
│   ├── webhook-events.jsonl
│   ├── stripe-config.jsonl
│   └── portal-config.jsonl
├── projects/              ← PER-CONSUMER — one dir per registered consumer app
│   └── <slug>/
│       ├── project.json
│       ├── products.jsonl
│       └── prices.jsonl
└── launches.jsonl         ← OUR STATE — project × jurisdiction × mode tracker
```

The split between `reference/` and `config/` is load-bearing — `mise run data:check` only touches `reference/`. Editing `config/` files is the normal way to change what Stripe does on our behalf (event subscriptions, portal features, payment-method pool, API version pin).

## `reference/` — Stripe-sourced, refreshable

Facts about the Stripe platform, derived from Stripe's docs. Refreshed via `mise run data:check` which fetches the canonical pages, diffs against local, reports added/removed entries. **Rule: do not hand-edit `reference/*.jsonl`.**

### reference/countries.jsonl — 60 rows

Per country (ISO-3166-1 alpha-2): seller modes, buyer-blocked modes, currency.

```jsonl
{"code":"US","name":"United States","region":"americas","currency":"usd",
 "seller_modes":["smp","payments"],"payments_preview":false,"buyer_blocked_modes":[]}
```

| Field | Values |
|---|---|
| `seller_modes` | Subset of `["smp", "payments", "paystack"]` |
| `payments_preview` | true for IN/ID (Stripe Payments invite-only) |
| `buyer_blocked_modes` | Subset of `["smp"]` — modes that reject buyers from this country |

Sources: <https://docs.stripe.com/payments/managed-payments/eligibility> (SMP fields), <https://stripe.com/global> (Payments fields), curated currencies.

### reference/tax-codes.jsonl — 72 rows

SMP-eligible **product** tax codes (`txcd_…`) grouped by category. Products in `projects/<slug>/products.jsonl` MUST reference a code from here.

Source: <https://docs.stripe.com/payments/managed-payments/eligibility#eligible-tax-codes>.

### reference/tax-coverage.jsonl — 82 rows

**Buyer** countries where Stripe handles indirect tax (VAT/GST/sales tax) under SMP.

```jsonl
{"code":"TH","region":"asia-pacific","domestic_excluded":null}
{"code":"JP","region":"asia-pacific","domestic_excluded":"all-domestic"}
{"code":"SG","region":"asia-pacific","domestic_excluded":"b2b-domestic"}
```

`domestic_excluded`: cross-border into the country works, domestic-from doesn't. JP and SG are the two carve-outs.

Source: <https://docs.stripe.com/payments/managed-payments/tax-compliance>.

## `config/` — our config, hand-curated

What we want Stripe to do on our behalf. Hand-edited, applied via `mise run bootstrap:*` tasks. **Never** touched by `data:check`.

### config/payment-methods.jsonl — 24 rows

Declarative pool of Stripe payment methods we want on the account.

```jsonl
{"method":"card","preference":"on","note":"…"}
{"method":"alipay","preference":"off","note":"Chinese travelers — flip on if needed"}
{"method":"promptpay","preference":"unavailable","note":"Requires Thai-registered seller"}
```

`preference`: `on` / `off` applied via `mise run bootstrap:sync-payment-methods`; `unavailable` is documentation-only (Stripe blocks the method for our merchant country).

Per-country routing is automatic — Checkout Sessions without `payment_method_types` let Stripe pick from this pool based on buyer location + currency. We don't recreate routing logic locally.

### config/webhook-events.jsonl — 9 rows

Stripe events smp subscribes to. Read by `bootstrap:webhook` when registering the endpoint.

```jsonl
{"event":"checkout.session.completed","why":"Primary post-payment signal …"}
```

Add a row → run `mise run bootstrap:webhook` → endpoint is recreated with the expanded event list.

### config/stripe-config.jsonl — 1 row

Pinned Stripe API version (`2025-03-31.basil`) — used by `test_checkout` to override the account default. Update when Stripe publishes a newer pinned version.

### config/portal-config.jsonl — 10 rows

Customer Portal config: one row per form-encoded `-d` arg passed to `POST /v1/billing_portal/configurations`.

```jsonl
{"k":"features[subscription_cancel][enabled]","v":"true"}
{"k":"features[customer_update][allowed_updates][]","v":"email"}
```

Edit JSONL → `mise run bootstrap:portal` recreates the config. Idempotent.

## `projects/` — one dir per consumer app

Each subdir is a consumer project that uses smp. Every Stripe object created on its behalf carries `metadata.project=<slug>` so dashboard / queries filter cleanly.

Schema and "how to add a project" — **[data/projects/README.md](projects/README.md)**.

Current projects:
- **`remy-sport/`** — basketball SaaS platform. 3 products × 6 prices.
- **`demo-app/`** — second consumer; exists to prove project isolation.

## launches.jsonl — our state, hand-curated

Per `(project, country, mode)` market-entry tracker.

```jsonl
{"project":"remy-sport","country":"AU","mode":"smp","stage":"verified",
 "started":"2026-05-28","notes":"Sandbox payment landed end-to-end via HIL …"}
```

| Field | Values |
|---|---|
| `project` | Must match a `data/projects/<slug>/` directory |
| `country` | ISO-3166-1 alpha-2 |
| `mode` | `smp` / `payments` / `paystack` |
| `stage` | `planning` / `blocked` / `awaiting-stripe` / `testing` / `verified` / `live` / `paused` / `available` / `not-applicable` |
| `started` | ISO-8601 date |
| `notes` | Free text |

## Cheat sheet

```sh
mise run data:scan                # row counts across all four groups
mise run data:check               # diff reference/ against upstream Stripe docs

mise run bootstrap:projects       # registered consumer projects + catalog sizes
mise run bootstrap:countries      # countries grouped by region with mode markers
mise run bootstrap:tax-codes      # tax codes grouped by category
mise run bootstrap:tax-coverage   # buyer-side tax-handled countries
mise run bootstrap:launches       # market-entry tracker

mise run check-country -- AU      # what modes does country X support as seller?
mise run check-tax -- TH          # is country Y tax-covered as a buyer?
```
