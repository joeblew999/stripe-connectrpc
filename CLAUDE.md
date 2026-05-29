# CLAUDE.md

Context for Claude (and humans) working in this repo.

## What this is

**stripe-smp** — Stripe Managed Payments shared service. The runtime is **http-nu + xs** (cablehead's stack); the bootstrap layer is mise + nushell + fnox + stripe-cli driven by JSONL. The Cloudflare Workers scaffold lives under `alt-runtime/cloudflare/` and is retained as an alternative runtime for if/when we want CDN edge deployment.

Stripe is merchant of record. Consumer apps call smp; smp owns the Stripe account, the keys, and the webhook surface. Web apps never embed Stripe.js.

## Stack

- **xs** (cablehead/cross-stream) — embedded event store, append-only stream + topic indexing.
- **http-nu** (cablehead) — HTTP server, dispatches routes to nushell handler closures via `use http-nu/router`.
- **nushell** — every handler + every bootstrap script + the dispatcher.
- **stripe-cli** — Stripe API calls for the bootstrap layer + webhook tunnel forwarding (`stripe listen`).
- **pitchfork** — supervises three daemons: `http`, `listen`, `dispatcher` (see `pitchfork.toml`).
- **fnox** — macOS keychain → env vars, scoped via `fnox exec --`.
- **mise** — tool versions + the entire task surface.

Runtime is OS-neutral and lives entirely on your laptop or any VPS — no vendor lock-in.

## Layout

```
scripts/
├── bootstrap.nu              ← thin verb dispatcher (≈90 lines)
├── bootstrap/
│   ├── lib.nu                ← shared: stripe_config, list_projects, normalize_arg
│   ├── show.nu               ← read-only display verbs
│   ├── apply.nu              ← mutate Stripe state from JSONL (idempotent)
│   ├── test.nu               ← sandbox HIL flows
│   └── teardown.nu           ← per-project archive (cross-leak safe)
├── handler.nu                ← http-nu closure (≈25 lines) — composes routes
├── routes/
│   ├── health.nu             ← GET /health
│   ├── events.nu             ← GET /events, GET /events/last
│   ├── webhook.nu            ← POST /v1/webhook + HMAC verify (Stripe → smp)
│   └── checkout.nu           ← POST /v1/checkout + Bearer auth (consumer → smp)
├── handlers/
│   ├── lib.nu                ← shared: dispatch_to_consumer (HMAC sign + POST + outcome events)
│   ├── dispatcher.nu         ← Phase 3a: tails .verified, dispatches at attempt=1
│   └── dispatch-retry.nu     ← Phase 3 retry (ADR-12): polls .retry, re-dispatches with backoff
├── open.nu                   ← idempotent browser launcher
├── verify.nu                 ← env check (quick) + verify:all (exhaustive)
└── onboard.nu                ← interactive secret prompts

alt-runtime/
└── cloudflare/               ← alt runtime (cf:* tasks); cargo/src/wrangler live here

docs/
├── ADR.md                    ← Decisions 1–10 (latest: consumer fan-out model)
├── SETUP.md                  ← Stripe account walkthrough
├── TASKS.md                  ← task → script → data matrix
└── CONSUMERS.md              ← Phase 3 consumer integration contract

data/
├── reference/                ← Stripe-sourced (hand-edited)
├── config/                   ← our config; applied via `apply -- *`
├── projects/<slug>/          ← per consumer app: project.json + products/prices.jsonl
└── launches.jsonl            ← per-market-entry tracker
```

## Conventions

- **mise tasks are the entry points.** Avoid running raw `nu`, `xs`, `http-nu`, `stripe` outside `mise x --` or `fnox exec --` (mise shim activation can fail otherwise).
- **Verb tasks are the canonical bootstrap surface:**
  - `mise run show -- <what> [arg]` — read-only Stripe + local data display
  - `mise run apply -- <what>` — mutate Stripe state from JSONL (idempotent)
  - `mise run teardown -- <slug>` — archive a project's Stripe state
  - `mise run test -- <flow> [arg]` — sandbox HIL flows
- **Declarative data is JSONL** under `data/`:
  - `data/reference/*.jsonl` — Stripe-sourced; hand-edit after eyeballing the source page.
  - `data/config/*.jsonl` — our config; applied to Stripe via `apply -- *`.
  - `data/projects/<slug>/` — one dir per consumer app; `project.json` + `products.jsonl` + `prices.jsonl`. The `consumer` block is the Phase 3 contract — see `docs/CONSUMERS.md`.
  - `data/launches.jsonl` — per-market-entry tracker.
- **Every Stripe object carries `metadata.project=<slug>`** for multi-tenancy under one Stripe account. Cross-leak protection: scripts only act on objects matching the project's metadata. The dispatcher uses the same metadata to route a Stripe event to the right consumer.
- **Runtime events flow into xs.** Route handlers (under `scripts/routes/`) append to xs topics. The dispatcher (`scripts/handlers/dispatcher.nu`) tails those topics and fans out.
- **Secrets via fnox keychain.** Always use `fnox set -p keychain NAME 'value'` (the `-p keychain` is non-negotiable — without it fnox writes plaintext into `fnox.toml`).
- **Each pitchfork daemon is wrapped in `fnox exec --`** so handlers see `STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY`, and per-consumer signing-secret keychain items.

## Event topics

| Topic | Emitted by | Notes |
|---|---|---|
| `stripe.intent.session.create` | `routes/checkout.nu` | Authenticated `POST /v1/checkout` audit (consumer-RPC inbound) |
| `stripe.api.session.created` | `routes/checkout.nu` | Stripe returned a checkout URL |
| `stripe.api.session.failed` | `routes/checkout.nu` | Stripe rejected the session create |
| `stripe.webhook.received` | `routes/webhook.nu` | Raw POST from Stripe (pre-verify) |
| `stripe.webhook.verified` | `routes/webhook.nu` | HMAC validated; dispatcher subscribes here |
| `stripe.webhook.invalid` | `routes/webhook.nu` | Signature mismatch; HTTP 400 response |
| `stripe.dispatch.attempted` | `handlers/dispatcher.nu` + `dispatch-retry.nu` | About to POST to a consumer (one per attempt) |
| `stripe.dispatch.delivered` | both | Consumer 2xx ack (terminal) |
| `stripe.dispatch.failed` | both | Consumer non-2xx / network / timeout (one per attempt) |
| `stripe.dispatch.retry` | both | Re-attempt scheduled; meta has `next_attempt_at` + `verified_hash` |
| `stripe.dispatch.dead-lettered` | both | Gave up after 7 attempts or fatal config error (terminal) |

## How to find anything

The system is CLI-discoverable — prefer running commands over reading docs:

| Question | Command |
|---|---|
| What tasks exist? | `mise tasks` |
| How do I set up + run end-to-end? | `mise run show -- flow` |
| What data files are there, and what's in them? | `mise run show -- scan` |
| What projects are registered? | `mise run show -- projects` |
| What's the live Stripe state? | `mise run show -- account` / `show -- status` |
| Does my install work? | `mise run verify` / `verify:all` |

The only docs that don't self-document via CLI:

- `docs/ADR.md` — architecture decisions (rationale not derivable from code). Decision 9 = runtime pivot, 10 = fan-out, 11 = `/v1/checkout`.
- `docs/CONSUMERS.md` — integration contract for *other* repos. They can't introspect smp's CLI.

## Status

Phase 1 (bootstrap) + Phase 2 (runtime) + Phase 3a (dispatcher) + Phase 3b (`/v1/checkout` consumer-RPC) all live locally. The architectural loop is now closed in both directions: consumers POST to `/v1/checkout` to create Stripe Checkout Sessions (Decision 11), and the dispatcher fans verified Stripe webhooks back to per-project consumer URLs (Decision 10). Real prior $31.90 sandbox payment landed end-to-end. Next milestones: Phase 4 deploy target (VPS or `cf:*`), Phase 5 first consumer (`remy-sport`) wires up bearer + HMAC verify.
