# stripe-smp

Stripe Managed Payments shared service ([stripe.com/managed-payments](https://stripe.com/managed-payments)). Stripe is merchant of record; consumer apps call smp instead of Stripe.

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
