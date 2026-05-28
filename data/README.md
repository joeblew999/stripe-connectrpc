# data/

Three groups of JSONL — separated so they don't get out of control as we grow.

```
data/
├── reference/             ← UPSTREAM — Stripe-sourced; do not hand-edit
│   ├── countries.jsonl
│   ├── tax-codes.jsonl
│   └── tax-coverage.jsonl
├── projects/              ← PER-CONSUMER — one dir per registered consumer app
│   └── <slug>/
│       ├── project.json
│       ├── products.jsonl
│       └── prices.jsonl
└── launches.jsonl         ← OURS — project × jurisdiction × mode tracker
```

## `reference/` — Stripe-sourced, refreshable

Derived from Stripe's docs. **Facts about the Stripe platform**, not us. Refreshed via `mise run data:check` which fetches the canonical pages, diffs against local, and reports added/removed entries.

**Rule: do not hand-edit `reference/*.jsonl`.** Edit only as part of an upstream sync.

### reference/countries.jsonl — 60 rows

Per country (ISO-3166-1 alpha-2): seller modes, buyer-blocked modes, currency.

```jsonl
{"code":"US","name":"United States","region":"americas","currency":"usd",
 "seller_modes":["smp","payments"],"payments_preview":false,"buyer_blocked_modes":[]}
```

| Field | Values |
|---|---|
| `seller_modes` | Subset of `["smp", "payments", "paystack"]` — what an account in this country can use |
| `payments_preview` | true for IN/ID (Stripe Payments invite-only) |
| `buyer_blocked_modes` | Subset of `["smp"]` — modes that reject buyers from this country |

Sources: <https://docs.stripe.com/payments/managed-payments/eligibility> (SMP fields), <https://stripe.com/global> (Payments fields), curated currencies.

### reference/tax-codes.jsonl — 72 rows

SMP-eligible **product** tax codes (`txcd_…`) grouped by category. Products in `projects/<slug>/products.jsonl` MUST reference a code from here or `managed_payments[enabled]=true` rejects at checkout.

Source: <https://docs.stripe.com/payments/managed-payments/eligibility#eligible-tax-codes>.

### reference/tax-coverage.jsonl — 82 rows

**Buyer** countries where Stripe handles indirect tax (VAT/GST/sales tax) under SMP — Stripe calculates, collects, files, remits.

```jsonl
{"code":"TH","region":"asia-pacific","domestic_excluded":null}
{"code":"JP","region":"asia-pacific","domestic_excluded":"all-domestic"}
{"code":"SG","region":"asia-pacific","domestic_excluded":"b2b-domestic"}
```

`domestic_excluded`: edge cases where Stripe handles cross-border into the country but NOT domestic-from it. JP (all domestic) and SG (B2B domestic) are the two such carve-outs.

Source: <https://docs.stripe.com/payments/managed-payments/tax-compliance>.

## `projects/` — one dir per consumer app

Each subdir is a consumer project that uses smp. Every Stripe object created on its behalf carries `metadata.project=<slug>` so dashboard / queries filter cleanly.

Layout, schema, and "how to add a second project" are documented in **[data/projects/README.md](projects/README.md)**.

Current projects:
- **`remy-sport/`** — first consumer; basketball SaaS platform. 3 products (Player / Coach / Club), 6 prices (each × month/year, USD).

## launches.jsonl — OURS, hand-curated

Per `(project, country, mode)` launch tracker. Each row = one market decision.

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
| `notes` | Free text — typically what was verified, blockers, or follow-ups |

## Common look-ups

```sh
mise run data:scan                # row counts across all data/ groups
mise run bootstrap:projects       # registered consumer projects + catalog sizes
mise run bootstrap:countries      # countries grouped by region with mode markers
mise run bootstrap:tax-codes      # tax codes grouped by category
mise run bootstrap:tax-coverage   # buyer-side tax-handled countries
mise run bootstrap:launches       # market-entry tracker
mise run check-country -- AU      # what modes does country X support as seller?
mise run check-tax -- TH          # is country Y tax-covered as a buyer?
mise run data:check               # diff reference/ vs upstream Stripe docs
```
