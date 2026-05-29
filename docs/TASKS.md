# Task inventory

Single source of truth: every mise task → which nushell script (or external CLI) → which data file(s) it reads or writes.

Verb-first namespace grammar:
- **`show:…`** — read-only display. No side effects on Stripe or files. Safe to run anytime.
- **`apply:…`** — mutates Stripe state. Idempotent — re-running ensures the JSONL's declared state is what Stripe has.
- **`teardown:…`** — archives Stripe state per project (Stripe doesn't allow deletes, only `active=false`).
- **`data:…`** — sync `data/reference/` against upstream Stripe docs.
- **`dev:…`** — supervise the dev daemons via pitchfork.
- **`test:…`** — one-off Stripe resources for sandbox HIL flows.
- **`open:…`** — launch a dashboard page in your default browser.
- **`stripe:…`** / **`worker:…`** / **`cargo:…`** / **`mise:…`** — thin passthroughs to the underlying CLI.
- **`onboard`** / **`verify`** — bootstrap-meta one-offs (no namespace).

## show: — read-only display

| Task | Script function | Reads |
|---|---|---|
| `show:account` | `bootstrap.nu#show_account` | Stripe API (`/v1/account`) |
| `show:status` | `bootstrap.nu#show_status` | Stripe API (webhook endpoints + products + prices + portal configs) |
| `show:projects` | `bootstrap.nu#print_projects` | `data/projects/*/project.json` |
| `show:countries` | `bootstrap.nu#print_countries` | `data/reference/countries.jsonl` |
| `show:country <ISO>` | `bootstrap.nu#check_country` | `data/reference/countries.jsonl` (filtered) |
| `show:tax-codes` | `bootstrap.nu#print_tax_codes` | `data/reference/tax-codes.jsonl` |
| `show:tax-coverage` | `bootstrap.nu#print_tax_coverage` | `data/reference/tax-coverage.jsonl` |
| `show:tax <ISO>` | `bootstrap.nu#check_tax_coverage` | `data/reference/tax-coverage.jsonl` (filtered) |
| `show:payment-methods` | `bootstrap.nu#list_payment_methods` | Stripe API (`/v1/payment_method_configurations`) |
| `show:launches` | `bootstrap.nu#print_launches` | `data/launches.jsonl` |
| `show:scan` | `bootstrap.nu#print_scan` | row counts across all `data/` groups |
| `show:flow` | `bootstrap.nu#print_flow` | embedded docs string |

## apply: — mutate Stripe via stripe-cli

| Task | Script function | Reads | Writes (Stripe) |
|---|---|---|---|
| `apply:products` | `bootstrap.nu#seed_products` | `data/projects/*/products.jsonl` | products with `metadata.project=<slug>`, ensured `active=true` |
| `apply:prices` | `bootstrap.nu#seed_prices` | `data/projects/*/prices.jsonl` | prices with lookup_key + `metadata.project=<slug>` |
| `apply:portal` | `bootstrap.nu#configure_portal` | `data/config/portal-config.jsonl` | Customer Portal configuration |
| `apply:webhook` | `bootstrap.nu#register_webhook` | `data/config/webhook-events.jsonl` + keychain `SMP_WORKER_URL` | webhook endpoint at `<worker>/v1/webhook` |
| `apply:payment-methods` | `bootstrap.nu#sync_payment_methods` | `data/config/payment-methods.jsonl` | `/v1/payment_method_configurations/<default>` toggles |
| `apply:all` | composes all four above | (everything above) | (everything above) |

## teardown: — archive project state

| Task | Script function | Reads | Writes |
|---|---|---|---|
| `teardown:project <slug>` | `bootstrap.nu#teardown_project` | `data/projects/<slug>/{products,prices}.jsonl` | `active=false` on products + prices, guarded by `metadata.project` match (cross-leak safe) |

## data: — upstream reference sync

| Task | Script function | Reads | Writes |
|---|---|---|---|
| `data:check` | `data-refresh.nu#diff_remote` | fetches `eligibility.md` + `tax-compliance.md`; reads all 3 `data/reference/*.jsonl` | (read-only diff) |
| `data:refresh` | `data-refresh.nu` apply branch | stub — manual edit after `check` |

## dev: — pitchfork supervision

| Task | Action |
|---|---|
| `dev:up` | start worker + stripe-listen daemons |
| `dev:down` | stop both |
| `dev:status` | `pitchfork list` |
| `dev:logs` | tail both daemons interleaved |
| `dev:tui` | interactive dashboard |
| `dev:restart-worker` | restart just wrangler dev (after src/.dev.vars edits) |
| `dev:restart-listen` | restart just stripe listen (after rotating `whsec_`) |

Config: `pitchfork.toml` — defines the two daemons + their readiness probes.

## test: — sandbox HIL flows

| Task | Script function | Reads | Writes (Stripe) |
|---|---|---|---|
| `test:checkout [lookup_key]` | `bootstrap.nu#test_checkout` (smp) | `data/config/stripe-config.jsonl` + Stripe API | Checkout Session with `managed_payments[enabled]=true` |
| `test:checkout-payments [lookup_key]` | `bootstrap.nu#test_checkout` (payments) | same | Checkout Session with `automatic_tax[enabled]=true` (we are MoR) |
| `test:checkout-thai` | `bootstrap.nu#test_checkout_thai_buyer` | same | Checkout Session with `locale=th`, `billing_address_collection=required` |
| `test:customer` | `bootstrap.nu#test_customer` | — | one test customer in Stripe |

## open: — browser URL launchers

All map through `scripts/open.nu`; no script function, just `open`/`xdg-open`/`start` on the right URL.

| Task | URL |
|---|---|
| `open:stripe-keys` | dashboard.stripe.com/test/apikeys |
| `open:stripe-account` | dashboard.stripe.com/settings/account |
| `open:stripe-onboard` | dashboard.stripe.com/account/onboarding |
| `open:stripe-smp` | dashboard.stripe.com/settings/managed-payments |
| `open:stripe-webhooks` | dashboard.stripe.com/test/webhooks |
| `open:stripe-payment-methods` | dashboard.stripe.com/test/settings/payment_methods |
| `open:stripe-products` | dashboard.stripe.com/test/products |
| `open:stripe-dashboard` | dashboard.stripe.com/test |
| `open:cf-tokens` | dash.cloudflare.com/profile/api-tokens |
| `open:cf-account` | dash.cloudflare.com |

## stripe: / worker: / cargo: / mise: — passthroughs

Thin wrappers around the underlying CLI. No JSONL involvement, no script functions.

| Task | Wraps |
|---|---|
| `stripe:listen` | `stripe listen --forward-to http://localhost:8787/v1/webhook` |
| `stripe:login` | `stripe login` (browser pairing) |
| `stripe:trigger-completed` | `stripe trigger checkout.session.completed` |
| `worker:dev` | `scripts/worker-dev.nu` (regen `.dev.vars` from fnox, then `wrangler dev`) |
| `worker:deploy` | `wrangler deploy` |
| `worker:tail` | `wrangler tail` |
| `worker:secret-put` | `wrangler secret put STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` from fnox |
| `cargo:check` | `cargo check --target wasm32-unknown-unknown` |
| `cargo:build` | `worker-build --release` |
| `cargo:clean` | `cargo clean ; rm -rf build` |
| `mise:install` | `mise install` (every tool pinned in `[tools]`) |

## one-offs

| Task | Script | Reads / Writes |
|---|---|---|
| `onboard` | `scripts/onboard.nu` | interactive — pulls CF + Stripe creds + writes to macOS keychain via fnox |
| `verify` | `scripts/verify.nu` | reads keychain entries + checks tool versions + checks wasm target |

## Data ↔ Task index

Want to know "who reads/writes this JSONL?"

| File | Read by | Written by |
|---|---|---|
| `data/reference/countries.jsonl` | `show:countries`, `show:country`, `data:check` | `data:refresh` (manual) |
| `data/reference/tax-codes.jsonl` | `show:tax-codes`, `data:check` | `data:refresh` (manual) |
| `data/reference/tax-coverage.jsonl` | `show:tax-coverage`, `show:tax`, `data:check` | `data:refresh` (manual) |
| `data/config/payment-methods.jsonl` | `apply:payment-methods` | hand |
| `data/config/webhook-events.jsonl` | `apply:webhook` | hand |
| `data/config/stripe-config.jsonl` | `test:checkout*` | hand |
| `data/config/portal-config.jsonl` | `apply:portal` | hand |
| `data/projects/<slug>/project.json` | `show:projects`, future consumer-fan-out | hand |
| `data/projects/<slug>/products.jsonl` | `apply:products`, `teardown:project` | hand |
| `data/projects/<slug>/prices.jsonl` | `apply:prices`, `teardown:project` | hand |
| `data/launches.jsonl` | `show:launches` | hand |

That's the whole surface — 54 tasks, 6 nushell scripts, 11 JSONL/JSON files. If something's not in this doc, it doesn't exist.
