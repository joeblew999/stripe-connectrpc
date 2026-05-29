# Stripe SMP

Stripe Managed Payments shared service on **http-nu + xs** — nushell HTTP front-end backed by cablehead's event store. Cloudflare Workers retained as an alternative runtime under `cf:*` tasks; see [docs/ADR.md](docs/ADR.md).

Stripe is the merchant of record — see [stripe.com/managed-payments](https://stripe.com/managed-payments). smp is the only place Stripe API keys live; consumer apps call smp for both ops actions (refund, cancel, portal) and billing-state queries. The web app never embeds Stripe.js; all user-facing payment UIs are Stripe-hosted (Checkout + Customer Portal).

## Phases

| Phase | What | Status | Reference |
|---|---|---|---|
| **1** | Bootstrap layer — JSONL → Stripe via stripe-cli; show / apply / test / teardown verbs | ✓ done | [ADR §6](docs/ADR.md) |
| **2** | Runtime — http-nu + xs, /v1/webhook with HMAC verify, events in xs | ✓ done | [ADR §9](docs/ADR.md) |
| **3** | Consumer fan-out — dispatcher tails xs, signs+POSTs to consumer.webhook_url | ✓ live | [ADR §10](docs/ADR.md) · [CONSUMERS.md](docs/CONSUMERS.md) |
| **4** | Deploy — pitchfork on a VPS supervising http-nu + stripe-listen + dispatcher | TBD | — |
| **5** | Cross-repo wiring — first consumer (`remy-sport`) verifies HMAC, processes events | TBD | [CONSUMERS.md](docs/CONSUMERS.md) |

**Verification:** real $31.90 sandbox payment on the AU-registered account flowed end-to-end (Stripe → stripe listen → http-nu → HMAC verify → xs). 7/7 events from `stripe trigger checkout.session.completed` HMAC-validated. Dispatcher (Phase 3) is running and producing `stripe.dispatch.attempted` / `.delivered` / `.failed` frames for each verified event.

## Stack

- **xs** (cablehead/cross-stream) — embedded event store, append-only stream with topic indexing.
- **http-nu** (cablehead) — HTTP server that dispatches routes to nushell handler closures; `--store` makes it host the xs store inline.
- **nushell** — every handler + every bootstrap script.
- **stripe-cli** — both for HTTP API calls (apply tasks) and webhook tunnel forwarding.
- **pitchfork** — supervises http-nu + stripe-listen as auto-restarting daemons.
- **fnox** — macOS keychain backend for secrets; env vars in scope of every Stripe-touching command.
- **mise** — single source of truth for tool versions + tasks.

Runs entirely off your laptop or any VPS. No vendor lock-in for the runtime.

## Onboarding (fresh clone)

```sh
mise run mise:install   # xs, http-nu, pitchfork, nushell, stripe-cli (versions pinned)
mise run onboard        # interactive: collect Stripe creds into keychain
mise run verify         # confirm tools + keychain entries
```

For a first-time Stripe account walkthrough (account country requirement, SMP activation, API key into fnox), see **[docs/SETUP.md](docs/SETUP.md)**.

## Dev loop

```sh
mise run dev:up                  # pitchfork starts http-nu (:8787 + embedded xs) + stripe listen + dispatcher
mise run dev:logs                # tail all daemons
mise run dev:status              # which daemons are running
mise run dev:tui                 # interactive pitchfork dashboard
mise run dev:down                # stop everything

mise run dev:restart-http        # after editing scripts/handler.nu or scripts/routes/*.nu
mise run dev:restart-listen      # after rotating the webhook signing secret
mise run dev:restart-dispatcher  # after editing scripts/handlers/dispatcher.nu or any project consumer block
```

Inspect the event stream:
```sh
mise run xs:cat                                      # all frames
mise run xs:last -- stripe.webhook.verified          # latest of a topic
mise run xs:append -- some.topic 'body text'         # write a test frame
```

Inspect Phase 3 dispatcher state:
```sh
mise run dispatch:attempted   # what smp tried to send to consumers
mise run dispatch:delivered   # what consumers acked with 2xx
mise run dispatch:failed      # what bounced (status + error meta)
mise run dispatch:logs        # live dispatcher console
```

Stripe passthroughs:
```sh
mise run stripe:trigger-completed   # synthetic checkout.session.completed
mise run stripe:login               # pair stripe-cli with your account (once)
```

## Verb tasks for the bootstrap layer

39 mise tasks total. Stripe-side state is driven by 4 verb tasks that dispatch on a positional argument:

```sh
mise run show -- account              # Stripe account info (mode/country/capabilities)
mise run show -- status               # snapshot: webhooks, products, prices, portal
mise run show -- projects             # registered consumer projects
mise run show -- countries            # 60 jurisdictions grouped by region
mise run show -- country AU           # one country's mode availability
mise run show -- tax-codes            # 72 SMP-eligible product tax codes
mise run show -- tax-coverage         # 82 buyer countries Stripe handles tax for
mise run show -- tax TH               # tax coverage for one buyer country
mise run show -- launches             # market-entry tracker
mise run show -- payment-methods      # what's enabled on this account (live API)
mise run show -- scan                 # data/ summary
mise run show -- flow                 # end-to-end flow notes

mise run apply -- products            # seed products from data/projects/<slug>/products.jsonl
mise run apply -- prices              # seed prices from data/projects/<slug>/prices.jsonl
mise run apply -- portal              # configure Customer Portal from data/config/portal-config.jsonl
mise run apply -- webhook             # register Stripe webhook endpoint at SMP_SERVICE_URL
mise run apply -- payment-methods     # reconcile data/config/payment-methods.jsonl → Stripe
mise run apply -- all                 # all five above, in order

mise run teardown -- <slug>           # archive products + prices for one project (cross-leak safe)

mise run test -- customer             # create a test customer
mise run test -- checkout             # SMP-mode Checkout Session, prints URL
mise run test -- checkout-payments    # Stripe Payments mode (we are MoR)
mise run test -- checkout-thai        # Thai buyer (locale=th, address required)
```

The full task → script → data matrix lives in [docs/TASKS.md](docs/TASKS.md).

## End-to-end sandbox payment

```sh
mise run dev:up
#   ▸ pitchfork starts http-nu + stripe listen
#   ▸ first run: copy printed whsec_ into the keychain:
#       fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_...'
#       mise run dev:restart-http   # so handler.nu picks up the new env var

mise run test -- checkout
#   ▸ default lookup_key: sports_coach_monthly_usd (Remy Sport)
#   ▸ prints checkout.stripe.com/c/pay/... URL
#   ▸ open in browser, pay with test card 4242 4242 4242 4242
#   ▸ mise run xs:cat shows ~12 events as stripe.webhook.received + .verified
```

## Stripe Atlas

[Stripe Atlas](https://dashboard.stripe.com/register/atlas) — incorporate a US company (Delaware C-Corp) through Stripe.

**Why this might matter for smp:** Atlas gives you a US-registered Stripe account, which is one of the 38 SMP seller countries.

**Why we don't need it today:** the currently-operating Stripe account is AU-registered, which is *also* an SMP seller country. We aren't using any payment method that requires a country-specific local company:

- Card / Apple Pay / Link → global, no local company needed
- PromptPay / iDEAL / Bancontact / Pix / etc. → would require a local seller country, but **we don't offer them**

Stripe Atlas would become relevant only if we wanted to additionally accept US-specific methods (e.g. ACH Direct Debit, Cash App Pay) and didn't already have a US presence.

[Carta × Stripe Atlas partnership](https://carta.com/product-updates/carta-stripe-atlas-api-partnership/) — pushes Atlas cap-table details into Carta automatically.

## Data layout

```
data/
├── reference/                       ← UPSTREAM Stripe docs; hand-edit after eyeballing source
│   ├── countries.jsonl              # 60 rows
│   ├── tax-codes.jsonl              # 72 rows
│   └── tax-coverage.jsonl           # 82 rows
├── config/                          ← OUR CONFIG; applied via `apply -- *`
│   ├── payment-methods.jsonl        # 24 rows
│   ├── webhook-events.jsonl         # 9 rows (events smp subscribes to)
│   ├── stripe-config.jsonl          # pinned API version
│   └── portal-config.jsonl          # Customer Portal feature config
├── projects/                        ← PER CONSUMER APP
│   ├── remy-sport/                  # first consumer
│   │   ├── project.json             # {slug, name, domain, consumer: {…}}
│   │   ├── products.jsonl
│   │   └── prices.jsonl
│   └── demo-app/                    # second (proves isolation)
└── launches.jsonl                   ← project × country × mode tracker
```

All Stripe objects created by `apply -- *` are tagged `metadata.project=<slug>` so the Stripe Dashboard / queries filter by project. See [data/projects/README.md](data/projects/README.md) and [data/README.md](data/README.md).

## Event-sourced runtime

The bootstrap layer above (`apply` / `show` / `teardown`) is **declarative** — JSONL → Stripe via API. The runtime is **event-sourced** — every inbound webhook, every API call result, every consumer interaction becomes an event in xs.

Topics currently emitted by `scripts/handler.nu`:

| Topic | When |
|---|---|
| `stripe.webhook.received` | Any POST to /v1/webhook (raw, pre-verify) |
| `stripe.webhook.verified` | HMAC validated against `STRIPE_WEBHOOK_SECRET` |
| `stripe.webhook.invalid` | Signature mismatch / missing header (response is 400) |

Future topics (not yet emitted, in design):
- `stripe.intent.*` for consumer-initiated mutations (RPC → emit intent)
- `stripe.api.*` for handler responses from Stripe (created, archived, …)
- `stripe.webhook.dispatched.<consumer>` for fan-out to consumer webhook URLs

The architecture decision and event-substrate trade-offs are in [docs/ADR.md](docs/ADR.md) (Decision 9).

## Cloudflare path (alternative runtime, retained for later)

The Workers/wasm32 scaffold lives under `alt-runtime/cloudflare/` (`Cargo.toml`, `src/`, `wrangler.toml`, `scripts/worker-dev.nu`). `cf:*` tasks let you build and deploy that variant if you ever want smp behind Cloudflare's edge. Same data layer (`data/`), same bootstrap tooling — only the runtime changes.

```sh
mise run cf:cargo-check       # cargo check the Workers wasm32 build
mise run cf:cargo-build       # worker-build --release
mise run cf:worker-dev        # wrangler dev locally
mise run cf:worker-deploy     # deploy to Cloudflare
mise run cf:worker-secret-put # push STRIPE_* from fnox → wrangler secrets
```

See `alt-runtime/cloudflare/` for the Worker implementation.

## Documentation

- [docs/ADR.md](docs/ADR.md) — Architecture decisions (runtime pivot, event-substrate, multi-project model, consumer fan-out)
- [docs/SETUP.md](docs/SETUP.md) — Stripe account setup walkthrough (country eligibility, API key into fnox)
- [docs/TASKS.md](docs/TASKS.md) — Task inventory + data-flow matrix
- [docs/CONSUMERS.md](docs/CONSUMERS.md) — Phase 3 consumer integration contract (HMAC verify, event_filters, response semantics)
- [CLAUDE.md](CLAUDE.md) — Context for Claude sessions working in this repo
- [data/README.md](data/README.md) — Data dictionary for reference/config/projects/launches
