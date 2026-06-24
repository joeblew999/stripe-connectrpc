# stripe-connectrpc

A **ConnectRPC Stripe gateway** — projects codegen a typed client (and a Kumo GUI) from the proto and call this gateway instead of Stripe directly. It runs on **Cloudflare Workers and native** from one `service/` codebase (transport swapped by Cargo feature). Stripe is merchant of record; the gateway owns the keys + the webhook surface, so consumer apps never embed Stripe.js.

> Renamed 2026-06-23 to `stripe-connectrpc` (was `stripe-smp`, originally `smp`). Crates/proto/env are now `stripe-*`. Old GitHub URLs redirect. ("SMP" still appears where it means Stripe's *Managed Payments* product — that's intentional.)

## Live deployment

| | URL |
|---|---|
| **Worker** (CF) | **https://stripe-connectrpc.gedw99.workers.dev** |
| Health | https://stripe-connectrpc.gedw99.workers.dev/health → `stripe ok` |
| Webhook (Stripe → gateway) | `POST https://stripe-connectrpc.gedw99.workers.dev/v1/webhook` (HMAC-verified) |
| ConnectRPC (Rauthy+Cedar guarded) | `/stripe.v1.CheckoutService/*`, `/CatalogService/*`, `/BillingService/*` |

The Worker is named after the repo (`stripe-connectrpc`, **not** `smp`) so it's trivial to track in the CF dashboard. The webhook half is live and needs no auth (Stripe signs by HMAC); the RPC routes sit behind the shared Rauthy-OIDC → Cedar guard.

### Webhook DISPATCHER (Durable Object → portable store)

Verified events are handed to the **Dispatcher**, which durably stores every event in SQLite (the event log = the read/analytics store), fans out to consumers, retries via alarms with backoff, and dead-letters on exhaustion. The store is designed **runtime-agnostic**: the Durable Object is the Cloudflare backend; native runs the same logic over plain SQLite (no CF Queues — pagination/retry uses DO alarms on CF and a tokio loop natively, so it ports cleanly).

### Read/analytics: `SigmaService` — our own Stripe Sigma

The mirror is exposed as a typed ConnectRPC **`SigmaService`** ([proto](service/crates/connectrpc/proto/stripe/v1/sigma.proto)) — named after, and replacing, [Stripe Sigma](https://stripe.com/sigma) ([pricing](https://stripe.com/sigma/pricing)) and [Stripe Data Pipeline](https://stripe.com/data-pipeline) ([pricing](https://stripe.com/data-pipeline/pricing)). Like Sigma it speaks SQL (`RunQuery`); unlike it, the surface is a typed contract behind the shared Rauthy→Cedar guard, with codegen'd clients + Kumo GUI, and it runs on **CF and native**. This is our dual-runtime, ConnectRPC-native take on [opensigma](https://github.com/choyiny/opensigma)'s Stripe→D1 mirror — opensigma is reference (it has no API; you query its D1 directly), we ship a typed service.

## Building blocks

- [arlyon/async-stripe](https://github.com/arlyon/async-stripe) — the Rust Stripe client (CF + native backends).
- [choyiny/opensigma](https://github.com/choyiny/opensigma) — reference for the read/analytics mirror (Sigma + Data Pipeline replacement); we build our own dual-runtime equivalent rather than adopt its CF-Queues coupling.
- [stripe/stripe-cli](https://github.com/stripe/stripe-cli) — Stripe API + webhook triggers for the bootstrap layer.
- [joeblew999/cf-connectrpc-middleware](https://github.com/joeblew999/cf-connectrpc-middleware) — the shared ConnectRPC auth/authz middleware (Rauthy OIDC + Cedar) this gateway adopts.
- [connyay/connectrpc-workers](https://github.com/connyay/connectrpc-workers) — the upstream ConnectRPC-on-Workers runtime the middleware tracks.
- [joeblew999/google_maps @ feat/cloudflare-workers](https://github.com/joeblew999/google_maps/tree/feat/cloudflare-workers) — the dual-runtime (CF + native) pattern this `service/` codebase mirrors.

## mise tasks

Every mise task is `<noun>:<verb>` so paired operations read obviously together:

| noun | what it operates on | example pair |
|---|---|---|
| `tools:*`     | toolchain + secrets                            | `tools:install` / `tools:onboard` |
| `daemons:*`   | pitchfork-supervised runtime                    | `daemons:up` / `daemons:down` |
| `stripe:*`    | Stripe-side state                               | `stripe:bootstrap` / `stripe:teardown` |
| `data:*`      | local JSONL inspection                          | `data:scan` / `data:projects` |
| `test:*`      | sandbox HIL flows                               | `test:checkout` / `test:rpc-checkout` |
| `xs:*`        | event store ops                                 | `xs:cat` / `xs:counts` |
| `dispatch:*`  | outbound consumer fan-out audit                 | `dispatch:delivered` / `dispatch:failed` |
| `rpc:*`       | inbound consumer-RPC audit                      | `rpc:intent` / `rpc:created` |
| `open:*`      | idempotent browser launchers                    | `open:stripe-keys` |
| `cf:*`        | alternative runtime (Cloudflare Workers)        | `cf:worker-deploy` |

## Setup

```sh
mise run tools:install        # nushell + stripe-cli + xs + http-nu + pitchfork + fnox + wrangler
mise run tools:onboard        # Stripe creds → keychain (interactive)
mise run stripe:bootstrap     # push data/ to Stripe: products + prices + portal + payment-methods
mise run stripe:verify-state  # confirm Stripe matches data/ (active=true, metadata.project tagged)
mise run daemons:down         # ensure daemons stopped
rm -rf .xs-store/             # clear local event store
mise run daemons:up           # start 4 daemons: http + listen + dispatcher + dispatch-retry
```

Reverse the Stripe-side push:

```sh
mise run stripe:teardown                        # archive every project's products + prices
mise run stripe:teardown-project -- remy-sport  # or just one project
mise run stripe:verify-state                    # now expects active=false → exits 1 (drift detected)
```

## After `daemons:up`

```sh
# Test the loop
mise run test:checkout              # Stripe Checkout URL, pay with 4242…
mise run test:rpc-checkout          # smoke POST /v1/checkout from the CLI

# See what happened
mise run xs:counts                  # events per topic
mise run xs:tail                    # last 20 events
mise run dispatch:delivered         # consumer 2xx
mise run dispatch:failed            # bounces

# Trigger a synthetic Stripe event
mise run stripe:trigger-completed

# Inspect Stripe state
mise run stripe:status              # webhooks / products / prices / portal
mise run data:projects              # registered consumers
```

## Docs

- [docs/ADR.md](docs/ADR.md) — architecture decisions
- [docs/CONSUMERS.md](docs/CONSUMERS.md) — integration contract for consumer repos
