# stripe-smp

Stripe Managed Payments shared service. **Stripe is merchant of record** ([stripe.com/managed-payments](https://stripe.com/managed-payments)) — Stripe absorbs global indirect tax. smp is the only place Stripe API keys live; consumer apps call smp instead of Stripe.

Runtime: **http-nu + xs** (cablehead's stack). Cloudflare Workers retained as alt-runtime under `cf:*` tasks; lives in `alt-runtime/cloudflare/`.

## Phases

| | What | Status |
|---|---|---|
| **1** | Bootstrap — JSONL → Stripe via stripe-cli (`show / apply / test / teardown`) | ✓ done |
| **2** | Runtime — http-nu + xs + `/v1/webhook` HMAC verify | ✓ done |
| **3a** | Consumer fan-out — dispatcher tails xs, signs+POSTs to consumer webhooks ([ADR-10](docs/ADR.md)) | ✓ live |
| **3b** | Consumer-RPC — `POST /v1/checkout` bearer-auth; smp creates the Checkout Session ([ADR-11](docs/ADR.md)) | ✓ live |
| **4** | Deploy to a VPS (pitchfork supervising the 3 daemons) | TBD |
| **5** | First consumer (`remy-sport`) wires up bearer + HMAC verify | TBD |

End-to-end verified: real $31.90 sandbox payment + 9/9 trigger events HMAC-verified → xs → dispatcher → consumer 200. `POST /v1/checkout` returns a Stripe Checkout URL on 201; 401 on missing/wrong bearer. `mise run verify:all` = 44 PASS / 0 FAIL / 16 SKIP.

## Stack (mise installs all of it)

`nushell` · `stripe-cli` · `xs` · `http-nu` · `pitchfork` · `fnox` · `wrangler` (alt-runtime only)

## Onboarding

```sh
mise run mise:install        # pulls every tool pinned in [tools]
mise run onboard             # interactive: Stripe creds → macOS keychain via fnox
mise run verify              # toolchain + keychain check
```

See **[docs/SETUP.md](docs/SETUP.md)** for Stripe account walkthrough (country eligibility, SMP activation).

## Dev loop

```sh
mise run dev:up              # pitchfork starts http (+ embedded xs) + listen + dispatcher
mise run dev:status          # daemon state
mise run dev:logs            # tail all three
mise run dev:down            # stop everything

mise run dev:restart-http        # after handler.nu / routes/*.nu edits
mise run dev:restart-listen      # after rotating whsec_
mise run dev:restart-dispatcher  # after dispatcher.nu / consumer block edits
```

CLI inspection (no browser, no playwright):

```sh
mise run xs:cat                                      # whole event stream
mise run xs:last -- stripe.webhook.verified          # latest of a topic
mise run xs:counts                                   # frame counts per topic
mise run rpc:intent / rpc:created / rpc:failed       # /v1/checkout consumer-RPC audit
mise run dispatch:delivered / dispatch:failed        # outbound fan-out to consumers
```

## Bootstrap verbs

```sh
mise run show -- <what> [arg]       # account|status|projects|countries|country|tax-codes|tax|launches|payment-methods|scan|flow
mise run apply -- <what>            # products|prices|portal|webhook|payment-methods|all  (all are idempotent)
mise run teardown -- <slug>         # archive a project's products+prices (cross-leak safe)
mise run test -- <flow> [arg]       # customer|checkout|checkout-payments|checkout-thai|rpc-checkout
```

Full task → script → data matrix in **[docs/TASKS.md](docs/TASKS.md)**.

## Data layout

```
data/
├── reference/       # Stripe-sourced — countries / tax-codes / tax-coverage
├── config/          # our config — payment-methods / webhook-events / portal / stripe-config
├── projects/<slug>/ # per consumer app — project.json + products.jsonl + prices.jsonl
└── launches.jsonl   # project × country × mode tracker
```

Every Stripe object created carries `metadata.project=<slug>` for multi-tenancy. See [data/README.md](data/README.md) + [data/projects/README.md](data/projects/README.md).

## Cloudflare alt-runtime

Workers/wasm32 scaffold under `alt-runtime/cloudflare/`. Build/deploy via `cf:cargo-check` / `cf:cargo-build` / `cf:worker-dev` / `cf:worker-deploy` / `cf:worker-secret-put`. Same `data/` layer; only the runtime changes.

## Docs

- [docs/ADR.md](docs/ADR.md) — architecture decisions (10)
- [docs/SETUP.md](docs/SETUP.md) — Stripe account setup
- [docs/TASKS.md](docs/TASKS.md) — task / script / data matrix
- [docs/CONSUMERS.md](docs/CONSUMERS.md) — Phase 3 consumer integration contract
- [CLAUDE.md](CLAUDE.md) — Claude session context
