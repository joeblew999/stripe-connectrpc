# stripe-smp

Stripe Managed Payments shared service. **Stripe is merchant of record** ([stripe.com/managed-payments](https://stripe.com/managed-payments)) — Stripe absorbs global indirect tax. smp is the only place Stripe API keys live; consumer apps call smp instead of Stripe.

Stack: **http-nu + xs + nushell + stripe-cli + pitchfork + fnox + mise**. Cloudflare Workers retained as alt-runtime under `cf:*` tasks (`alt-runtime/cloudflare/`).

## Status — functionally complete

| | What | |
|---|---|---|
| 1 | Bootstrap — JSONL → Stripe via stripe-cli (`show / apply / test / teardown`) | ✓ |
| 2 | Runtime — http-nu + xs + `/v1/webhook` HMAC verify | ✓ |
| 3a | Consumer fan-out — dispatcher tails xs, signs+POSTs to consumer webhooks ([ADR-10](docs/ADR.md)) | ✓ |
| 3b | Consumer-RPC — `POST /v1/checkout` bearer-auth; smp creates the Checkout Session ([ADR-11](docs/ADR.md)) | ✓ |
| 3c | Retry + dead-letter — Stripe-style backoff (30s→24h, 7 attempts), xs IS the queue ([ADR-12](docs/ADR.md)) | ✓ |

`mise run verify:all` = **51 PASS / 0 FAIL / 16 SKIP**. Real $31.90 sandbox payment landed end-to-end; full bidirectional contract verified; retry chain verified through attempt 3; dead-letter verified via synthetic attempt=7 injection.

## Self-documenting CLI

```sh
mise tasks                          # every task this repo exposes
mise run show -- flow               # end-to-end setup + dev loop walkthrough
mise run show -- scan               # data/ layout + row counts
mise run show -- projects           # registered consumers
mise run show -- account            # current Stripe account state
mise run verify                     # toolchain + keychain check
mise run verify:all                 # exhaustive: every non-interactive task
```

Onboarding:

```sh
mise run mise:install               # nushell + stripe-cli + xs + http-nu + pitchfork + fnox + wrangler
mise run onboard                    # interactive: Stripe creds → macOS keychain via fnox
mise run dev:up                     # http (+xs) + listen + dispatcher daemons
mise run test -- checkout           # sandbox payment with test card 4242…
mise run test -- rpc-checkout       # POST /v1/checkout smoke test (201 + two 401 probes)
```

## Docs that don't self-document

The repo is otherwise CLI-discoverable; these three exist because they describe things outside the running system:

- **[docs/ADR.md](docs/ADR.md)** — architecture decisions; rationale not derivable from code.
- **[docs/CONSUMERS.md](docs/CONSUMERS.md)** — integration contract for *other* repos that need to call smp / receive events from smp. They can't introspect smp's CLI.
- **[CLAUDE.md](CLAUDE.md)** — context for Claude sessions.
