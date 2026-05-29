# data/

Four groups so files don't get out of control as projects grow.

```
data/
├── reference/             ← UPSTREAM — Stripe-sourced; hand-edit after eyeballing source
├── config/                ← OUR CONFIG — hand-curated; applied via `apply -- *`
├── projects/<slug>/       ← PER-CONSUMER — one dir per registered consumer
└── launches.jsonl         ← OUR STATE — project × jurisdiction × mode tracker
```

## `reference/` — Stripe-sourced

Facts about the Stripe platform, derived from Stripe's docs. Hand-edit only after eyeballing the source page (we removed the automated `data:check` task — see ADR).

| File | Rows | Source |
|---|---|---|
| `countries.jsonl` | 60 | <https://docs.stripe.com/payments/managed-payments/eligibility> |
| `tax-codes.jsonl` | 72 | SMP-eligible product tax codes |
| `tax-coverage.jsonl` | 82 | <https://docs.stripe.com/payments/managed-payments/tax-compliance> |

### Schema sketches

```jsonl
# countries.jsonl
{"code":"US","name":"United States","region":"americas","currency":"usd",
 "seller_modes":["smp","payments"],"payments_preview":false,"buyer_blocked_modes":[]}

# tax-coverage.jsonl
{"code":"JP","region":"asia-pacific","domestic_excluded":"all-domestic"}
{"code":"SG","region":"asia-pacific","domestic_excluded":"b2b-domestic"}
```

`seller_modes`: subset of `["smp", "payments", "paystack"]`.
`buyer_blocked_modes`: subset of `["smp"]` — modes that reject buyers from this country.
`domestic_excluded`: cross-border into the country works; domestic-from doesn't (JP, SG are the carve-outs).

## `config/` — our config

What we want Stripe to do on our behalf. Hand-edited, applied via `apply -- *`.

| File | Rows | Applied by |
|---|---|---|
| `payment-methods.jsonl` | 24 | `apply -- payment-methods` |
| `webhook-events.jsonl` | 9 | `apply -- webhook` (subscribed event types) |
| `stripe-config.jsonl` | 1 | `test -- checkout*` (pinned API version) |
| `portal-config.jsonl` | 10 | `apply -- portal` (Customer Portal features) |

### payment-methods.jsonl

```jsonl
{"method":"card","preference":"on","note":"…"}
{"method":"alipay","preference":"off","note":"Chinese travelers — flip on if needed"}
{"method":"promptpay","preference":"unavailable","note":"Requires Thai-registered seller"}
```

`preference`: `on` / `off` applied to the default `payment_method_configuration`; `unavailable` is documentation-only (Stripe blocks for our merchant country).

Per-country surfacing is automatic — Checkout Sessions without `payment_method_types` let Stripe pick from this pool. We don't reimplement routing.

### portal-config.jsonl

One row per form-encoded `-d` arg to `POST /v1/billing_portal/configurations`:

```jsonl
{"k":"features[subscription_cancel][enabled]","v":"true"}
{"k":"features[customer_update][allowed_updates][]","v":"email"}
```

## `projects/` — per consumer

Schema + how to add a project: **[data/projects/README.md](projects/README.md)**.

Current projects:
- `remy-sport/` — basketball SaaS. 3 products × 6 prices.
- `demo-app/` — proves multi-tenant isolation.

## launches.jsonl

Per `(project, country, mode)` market-entry tracker:

```jsonl
{"project":"remy-sport","country":"AU","mode":"smp","stage":"verified",
 "started":"2026-05-28","notes":"Sandbox payment landed end-to-end via HIL …"}
```

`stage`: `planning` / `blocked` / `awaiting-stripe` / `testing` / `verified` / `live` / `paused` / `available` / `not-applicable`.

## Cheat sheet

```sh
mise run show -- scan         # row counts across all groups
mise run show -- projects     # registered consumers + catalog sizes
mise run show -- countries    # countries by region + mode markers
mise run show -- tax-codes
mise run show -- launches
mise run show -- country AU   # one country's modes
mise run show -- tax JP       # one buyer country's tax coverage
```
