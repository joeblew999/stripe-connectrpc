# Task inventory

Single source of truth: every mise task → what it does → which script (or external CLI) → which data file(s) it reads or writes.

**39 mise tasks** organized into namespaces. Bootstrap surface collapsed to 4 verb tasks (`show`, `apply`, `test`, `teardown`); each dispatches into `scripts/bootstrap.nu` based on its positional argument.

## Verb tasks (the canonical bootstrap surface)

### `show <what> [arg]` — read-only display

| `<what>` | Reads | Notes |
|---|---|---|
| `account` | Stripe API `/v1/account` | mode/country/currency/capabilities |
| `status` | Stripe API (webhooks + products + prices + portal) | live snapshot |
| `projects` | `data/projects/*/project.json` | registered consumer projects |
| `countries` | `data/reference/countries.jsonl` | 60 jurisdictions grouped by region |
| `country <ISO>` | `data/reference/countries.jsonl` (filtered) | modes available for one country |
| `tax-codes` | `data/reference/tax-codes.jsonl` | 72 SMP-eligible product tax codes |
| `tax-coverage` | `data/reference/tax-coverage.jsonl` | 82 buyer countries with SMP tax handling |
| `tax <ISO>` | `data/reference/tax-coverage.jsonl` (filtered) | one buyer country's coverage |
| `launches` | `data/launches.jsonl` | per `(project, country, mode)` tracker |
| `payment-methods` | Stripe API `/v1/payment_method_configurations` | live-queried |
| `scan` | row counts across all `data/` groups | |
| `flow` | embedded doc string | end-to-end flow summary |

### `apply <what>` — mutate Stripe (idempotent)

| `<what>` | Reads | Writes (Stripe) |
|---|---|---|
| `products` | every `data/projects/<slug>/products.jsonl` | products with `metadata.project=<slug>`, `active=true` |
| `prices` | every `data/projects/<slug>/prices.jsonl` | prices with `lookup_key` + `metadata.project=<slug>` |
| `portal` | `data/config/portal-config.jsonl` | Customer Portal configuration |
| `webhook` | `data/config/webhook-events.jsonl` + keychain `SMP_SERVICE_URL` | webhook endpoint at `<service>/v1/webhook` |
| `payment-methods` | `data/config/payment-methods.jsonl` | `/v1/payment_method_configurations/<default>` toggles |
| `all` | all five above, in order | products → prices → portal → webhook |

### `teardown <slug>` — archive a project's state

| Action | Reads | Writes (Stripe) |
|---|---|---|
| | `data/projects/<slug>/{products,prices}.jsonl` | `active=false` on objects matching `metadata.project=<slug>` (cross-leak safe) |

### `test <flow> [arg]` — sandbox HIL flows

| `<flow>` | What it does |
|---|---|
| `customer` | Create a test customer in Stripe |
| `checkout [lookup_key]` | SMP-mode Checkout Session (`managed_payments[enabled]=true`); default key `sports_coach_monthly_usd` |
| `checkout-payments [lookup_key]` | Stripe Payments mode (we are MoR, `automatic_tax[enabled]=true`) |
| `checkout-thai` | Thai buyer flow: SMP + `locale=th` + `billing_address_collection=required` |

## Other namespaces

### `dev:*` — supervised daemons via pitchfork

| Task | Action |
|---|---|
| `dev:up` | start http-nu (+embedded xs) and stripe-listen |
| `dev:down` | stop both |
| `dev:status` | `pitchfork list` |
| `dev:logs` | tail both daemons interleaved |
| `dev:tui` | interactive dashboard |
| `dev:restart-http` | restart just http-nu (after handler.nu edits) |
| `dev:restart-listen` | restart just stripe listen (after rotating `whsec_`) |

### `xs:*` — event store operations (via UDS at `.xs-store/sock`)

| Task | Action |
|---|---|
| `xs:cat` | cat the event stream |
| `xs:last <topic>` | latest frame for a topic |
| `xs:append <topic> <body>` | append a test event |

### `data:*` — upstream reference sync

| Task | Action | Source |
|---|---|---|
| `data:check` | fetch upstream Stripe docs, diff vs `data/reference/*.jsonl` | eligibility.md + tax-compliance.md |
| `data:refresh` | apply diff (stub — manual edit after `check`) | — |

### `stripe:*` — Stripe CLI passthroughs

| Task | Wraps |
|---|---|
| `stripe:login` | `stripe login` (browser pairing) |
| `stripe:listen` | `stripe listen --forward-to http://localhost:8787/v1/webhook` |
| `stripe:trigger-completed` | `stripe trigger checkout.session.completed` |

### `open:*` — browser URL launchers

All map through `scripts/open.nu`.

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

### `cf:*` — Cloudflare path (alternative runtime, retained for later)

Not used by the current http-nu+xs runtime. Kept active so the Workers variant can be built and deployed on demand.

| Task | Wraps |
|---|---|
| `cf:cargo-check` | `cargo check --target wasm32-unknown-unknown` |
| `cf:cargo-build` | `worker-build --release` |
| `cf:cargo-clean` | `cargo clean ; rm -rf build` |
| `cf:worker-dev` | `scripts/worker-dev.nu` (regen `.dev.vars` from fnox, then `wrangler dev`) |
| `cf:worker-deploy` | `wrangler deploy` |
| `cf:worker-tail` | `wrangler tail` |
| `cf:worker-secret-put` | push STRIPE_* from fnox to wrangler secrets |

### `mise:*` + one-offs

| Task | Action |
|---|---|
| `mise:install` | `mise install` (installs every tool pinned in `[tools]`) |
| `onboard` | interactive: pull Stripe creds into macOS keychain via fnox |
| `verify` | check tool versions + keychain entries |

## Data ↔ Task index

Want to know "who reads/writes this JSONL?"

| File | Read by | Written by |
|---|---|---|
| `data/reference/countries.jsonl` | `show -- countries`, `show -- country <ISO>`, `data:check` | `data:refresh` (manual) |
| `data/reference/tax-codes.jsonl` | `show -- tax-codes`, `data:check` | `data:refresh` (manual) |
| `data/reference/tax-coverage.jsonl` | `show -- tax-coverage`, `show -- tax <ISO>`, `data:check` | `data:refresh` (manual) |
| `data/config/payment-methods.jsonl` | `apply -- payment-methods` | hand |
| `data/config/webhook-events.jsonl` | `apply -- webhook` | hand |
| `data/config/stripe-config.jsonl` | `test -- checkout*` | hand |
| `data/config/portal-config.jsonl` | `apply -- portal` | hand |
| `data/projects/<slug>/project.json` | `show -- projects`, future consumer-fan-out | hand |
| `data/projects/<slug>/products.jsonl` | `apply -- products`, `teardown -- <slug>` | hand |
| `data/projects/<slug>/prices.jsonl` | `apply -- prices`, `teardown -- <slug>` | hand |
| `data/launches.jsonl` | `show -- launches` | hand |
| `.xs-store/` | http-nu daemon (read+write), `xs:cat`/`last`/`append` (UDS) | http-nu handlers, xs CLI |

That's the whole surface — 39 mise tasks, 6 nushell scripts, 11 JSONL/JSON files, 1 xs event store. If something's not in this doc, it doesn't exist.
