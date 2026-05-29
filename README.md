# stripe-smp

Stripe Managed Payments shared service ([stripe.com/managed-payments](https://stripe.com/managed-payments)). Stripe is merchant of record; consumer apps call smp instead of Stripe.

## Setup

```sh
mise run mise:install   # nushell + stripe-cli + xs + http-nu + pitchfork + fnox
mise run onboard        # Stripe creds → keychain
mise run dev:up         # start 4 daemons: http + listen + dispatcher + dispatch-retry
```

## After dev:up

```sh
# Test the loop
mise run test -- checkout         # Stripe Checkout URL, pay with 4242…
mise run test -- rpc-checkout     # smoke POST /v1/checkout from the CLI

# See what happened
mise run xs:counts                # events per topic
mise run xs:tail                  # last 20 events
mise run dispatch:delivered       # consumer 2xx
mise run dispatch:failed          # bounces

# Trigger a synthetic Stripe event
mise run stripe:trigger-completed

# Inspect Stripe state
mise run show -- status           # webhooks / products / prices / portal
mise run show -- projects         # registered consumers
```

## Docs

- [docs/ADR.md](docs/ADR.md) — architecture decisions
- [docs/CONSUMERS.md](docs/CONSUMERS.md) — integration contract for consumer repos
