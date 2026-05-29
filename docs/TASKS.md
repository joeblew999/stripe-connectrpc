# Task inventory

Every mise task → what it does → which script (or external CLI) → which data file(s).

**~45 mise tasks** total. Bootstrap surface is 4 verb tasks; each dispatches in `scripts/bootstrap.nu` based on positional arg.

## Verb tasks (the canonical bootstrap surface)

### `show -- <what> [arg]` — read-only

| `<what>` | Reads | Notes |
|---|---|---|
| `account` | Stripe `/v1/account` | mode/country/capabilities |
| `status` | Stripe (webhooks + products + prices + portal) | live snapshot |
| `projects` | `data/projects/*/project.json` | registered consumer projects |
| `countries` | `data/reference/countries.jsonl` | 60 jurisdictions by region |
| `country <ISO>` | `data/reference/countries.jsonl` | one country's modes |
| `tax-codes` | `data/reference/tax-codes.jsonl` | 72 SMP-eligible product tax codes |
| `tax-coverage` | `data/reference/tax-coverage.jsonl` | 82 buyer countries |
| `tax <ISO>` | `data/reference/tax-coverage.jsonl` | one buyer country's coverage |
| `launches` | `data/launches.jsonl` | per `(project, country, mode)` tracker |
| `payment-methods` | Stripe `/v1/payment_method_configurations` | live |
| `scan` | row counts across `data/` | |
| `flow` | embedded doc | end-to-end flow summary |

### `apply -- <what>` — mutate Stripe (idempotent)

| `<what>` | Reads | Writes (Stripe) |
|---|---|---|
| `products` | `data/projects/<slug>/products.jsonl` | products tagged `metadata.project=<slug>` |
| `prices` | `data/projects/<slug>/prices.jsonl` | prices with lookup_key + project metadata |
| `portal` | `data/config/portal-config.jsonl` | Customer Portal configuration |
| `webhook` | `data/config/webhook-events.jsonl` + keychain `SMP_SERVICE_URL` | endpoint at `<service>/v1/webhook` |
| `payment-methods` | `data/config/payment-methods.jsonl` | `payment_method_configurations` toggles |
| `all` | all five, in order | webhook step warn-skips if `SMP_SERVICE_URL` absent (Phase 4) |

### `teardown -- <slug>` — archive

Sets `active=false` on Stripe products+prices matching `metadata.project=<slug>` (cross-leak safe — never touches another project's objects).

### `test -- <flow> [arg]` — sandbox HIL

| `<flow>` | What |
|---|---|
| `customer` | Create test customer |
| `checkout [lookup_key]` | SMP-mode Checkout Session (`managed_payments[enabled]=true`); default `sports_coach_monthly_usd` |
| `checkout-payments [lookup_key]` | Stripe Payments mode (we are MoR, `automatic_tax[enabled]=true`) |
| `checkout-thai` | SMP + `locale=th` + `billing_address_collection=required` |

## Daemon ops

### `dev:*` — pitchfork supervision

| Task | Action |
|---|---|
| `dev:up` | start http (+xs) + listen + dispatcher |
| `dev:down` | stop all three |
| `dev:status` | `pitchfork list` |
| `dev:logs` | tail all three |
| `dev:tui` | interactive pitchfork dashboard |
| `dev:restart-http` | restart just http-nu (after handler.nu / routes/*.nu) |
| `dev:restart-listen` | restart stripe-listen (after rotating whsec_) |
| `dev:restart-dispatcher` | restart dispatcher (after dispatcher.nu / consumer block edits) |

### `xs:*` — event store

| Task | Action |
|---|---|
| `xs:cat` | cat the stream (via UDS) |
| `xs:last <topic>` | latest frame for topic |
| `xs:append <topic> <body>` | append test event |
| `xs:tail` | recent 20 frames via HTTP `/events` |
| `xs:counts` | group by topic + count |

### `dispatch:*` — Phase 3 fan-out inspection

| Task | Reads |
|---|---|
| `dispatch:logs` | `pitchfork logs dispatcher` |
| `dispatch:attempted` | xs `stripe.dispatch.attempted` |
| `dispatch:delivered` | xs `stripe.dispatch.delivered` |
| `dispatch:failed` | xs `stripe.dispatch.failed` |

### `stripe:*` — stripe-cli passthroughs

| Task | Wraps |
|---|---|
| `stripe:login` | browser pairing |
| `stripe:listen` | `stripe listen --forward-to http://localhost:8787/v1/webhook` (duplicate of pitchfork `listen` daemon) |
| `stripe:trigger-completed` | `stripe trigger checkout.session.completed` |

### `open:*` — browser launchers (idempotent — only open if state missing)

Each probes whether the underlying thing is already configured; skips the browser open if so.

| Task | Probes for | URL if needed |
|---|---|---|
| `open:stripe-keys` | `SMP_STRIPE_SECRET_KEY` in keychain | dashboard.stripe.com/test/apikeys |
| `open:stripe-webhooks` | `SMP_STRIPE_WEBHOOK_SECRET` in keychain | dashboard.stripe.com/test/webhooks |
| `open:stripe-account` / `-onboard` / `-smp` / `-dashboard` | account `charges_enabled && details_submitted` | various |
| `open:stripe-products` | any product has `metadata.project=*` | dashboard.stripe.com/test/products |
| `open:stripe-payment-methods` | any webhook endpoint exists | dashboard.stripe.com/test/settings/payment_methods |
| `open:cf-tokens` / `-account` | `CLOUDFLARE_*` in keychain | dash.cloudflare.com/* |

### `cf:*` — alternative runtime (Cloudflare Workers)

Lives in `alt-runtime/cloudflare/`; mise tasks set `dir = "alt-runtime/cloudflare"`. Not needed for the primary http-nu+xs runtime.

| Task | Wraps |
|---|---|
| `cf:cargo-check` | `cargo check --target wasm32-unknown-unknown` |
| `cf:cargo-build` | `worker-build --release` |
| `cf:cargo-clean` | `cargo clean ; rm -rf build` |
| `cf:worker-dev` | regen `.dev.vars` from fnox + `wrangler dev` |
| `cf:worker-deploy` | `wrangler deploy` |
| `cf:worker-tail` | `wrangler tail` |
| `cf:worker-secret-put` | push STRIPE_* from fnox → wrangler secrets |

### Meta

| Task | Action |
|---|---|
| `mise:install` | install every tool pinned in `[tools]` |
| `onboard` | interactive secret prompts → keychain |
| `verify` | quick: tools + Stripe keychain entries |
| `verify:all` | exhaustive: run every non-interactive mise task, report PASS/FAIL/SKIP |

## Data ↔ Task index

| File | Read by | Written by |
|---|---|---|
| `data/reference/countries.jsonl` | `show -- countries`, `show -- country` | hand (after eyeballing source) |
| `data/reference/tax-codes.jsonl` | `show -- tax-codes` | hand |
| `data/reference/tax-coverage.jsonl` | `show -- tax-coverage`, `show -- tax` | hand |
| `data/config/payment-methods.jsonl` | `apply -- payment-methods` | hand |
| `data/config/webhook-events.jsonl` | `apply -- webhook` | hand |
| `data/config/stripe-config.jsonl` | `test -- checkout*` | hand |
| `data/config/portal-config.jsonl` | `apply -- portal` | hand |
| `data/projects/<slug>/project.json` | `show -- projects`, dispatcher | hand |
| `data/projects/<slug>/products.jsonl` | `apply -- products`, `teardown -- <slug>` | hand |
| `data/projects/<slug>/prices.jsonl` | `apply -- prices`, `teardown -- <slug>` | hand |
| `data/launches.jsonl` | `show -- launches`, `show -- scan` | hand |
| `.xs-store/sock` | http-nu, dispatcher, `xs:*` CLI | http-nu handlers + dispatcher |
