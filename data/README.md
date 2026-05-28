# data/

Declarative reference + bootstrap inputs. All scripts under `scripts/` and all `mise run bootstrap:*` / `data:*` tasks read these files.

Truth-source links:
- Eligibility: <https://docs.stripe.com/payments/managed-payments/eligibility>
- Tax codes: <https://docs.stripe.com/tax/tax-categories>
- General availability: <https://stripe.com/global>

## countries.jsonl — the one jurisdiction file

Every country we track sits here, with all axes on one row. **For each new project / market we launch into, this is the file to check first.**

```jsonl
{"code":"US","name":"United States","region":"americas","currency":"usd",
 "stripe_payments":"available","smp_seller":true,"smp_buyer_blocked":false}
```

| Field | Values | Meaning |
|---|---|---|
| `code` | ISO-3166-1 alpha-2 | Lookup key |
| `name` | string | Display name |
| `region` | `americas` / `europe` / `asia-pacific` / `middle-east` / `africa` | Stripe-docs grouping |
| `currency` | ISO-4217 lowercase, or `null` | Stripe default settlement currency for sellers; `null` for non-seller / blocked rows |
| `stripe_payments` | `available` / `preview` / `paystack` / `none` | Stripe Payments seller availability |
| `smp_seller` | bool | Account here can enable Managed Payments |
| `smp_buyer_blocked` | bool | Stripe rejects checkouts FROM buyers here (SMP) |

60 rows: 51 seller jurisdictions + 9 restricted buyer countries.

Run `mise run bootstrap:countries` to see the breakdown grouped by region with marker per row:
- `✓ smp` — full SMP seller country
- `·` — Stripe Payments only (we'd be MoR, not Stripe)
- `✗ blk` — blocked buyer country (no checkout to here under SMP)

## tax-codes.jsonl — **product** tax codes

72 Stripe tax codes (`txcd_…`) eligible under SMP, grouped by category (`saas`, `software`, `games`, `books`, `audio`, `video`, `training`, etc.). Products in `products.jsonl` MUST reference a code from here or `managed_payments[enabled]=true` will reject at checkout.

`mise run bootstrap:tax-codes` prints them grouped.

## tax-coverage.jsonl — **buyer-country** tax coverage

82 countries where Stripe handles indirect tax (VAT/GST/sales tax) under SMP — meaning when you sell to a buyer in one of these, Stripe calculates, collects, files, and remits the tax for you.

```jsonl
{"code":"TH","region":"asia-pacific","domestic_excluded":null}
{"code":"JP","region":"asia-pacific","domestic_excluded":"all-domestic"}
{"code":"SG","region":"asia-pacific","domestic_excluded":"b2b-domestic"}
```

`domestic_excluded` flags edge cases where Stripe handles **cross-border into** the country but NOT **domestic-from** it. JP (all domestic sales) and SG (B2B domestic) are the two such exceptions.

Look-up:
```sh
mise run check-tax -- TH        # Stripe handles tax there?
mise run bootstrap:tax-coverage  # full table grouped by region
```

Countries **absent** from this list: SMP can still take payment from buyers there (unless they're on the `buyer_blocked_modes` list in `countries.jsonl`), but YOU remain responsible for any indirect tax on those sales.

Source: <https://docs.stripe.com/payments/managed-payments/tax-compliance> (fetched 2026-05-28).

## products.jsonl

Sports SaaS tiers. Tax code on each row must appear in `tax-codes.jsonl`.

## prices.jsonl

One row per `(product × interval × currency)`. `lookup_key` is the stable handle consumer apps reference; smp resolves it to a Stripe `price_…` at checkout time.

## launches.jsonl

Per-`(project, country, mode)` launch tracker. Each row is one market we've decided to enter, blocked from entering, or are planning.

```jsonl
{"project":"smp","country":"TH","mode":"smp","stage":"blocked","started":"2026-05-28",
 "notes":"Thailand not on SMP seller list — decision pending"}
```

| Field | Values |
|---|---|
| `project` | repo/product name |
| `country` | ISO-3166-1 alpha-2 |
| `mode` | `smp` / `payments` (Stripe Payments without MoR) / `paystack` |
| `stage` | `planning` / `blocked` / `awaiting-stripe` / `testing` / `live` / `paused` |
| `started` | ISO-8601 date |
| `notes` | free text |

`mise run bootstrap:launches` shows the current state.

This file is the staging ground for the eventual onboarding-flow tooling (per-stage checklists, automated dispute monitoring, jurisdiction-specific tax registrations, etc.).

## Keeping data in sync

Stripe's eligibility list and tax codes change. Don't trust this repo without a check:

```sh
mise run data:check       # fetches upstream eligibility.md, diffs vs current
                          # prints + added / - removed for each axis
```

`data:refresh` (auto-write) is a stub — current workflow is: run `check`, eyeball the diff, edit JSONLs manually, commit. The parser will mature once we've seen a real upstream change to confirm it handles edge cases.

Quick state overview:
```sh
mise run data:scan        # row counts across all data/ files
```
