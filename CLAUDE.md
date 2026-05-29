# CLAUDE.md

Context for Claude (and humans) working in this repo.

## What this is

**stripe-smp** — Stripe Managed Payments shared service. The runtime is **http-nu + xs** (cablehead's stack); the bootstrap layer is mise + nushell + fnox + stripe-cli driven by JSONL. The Cloudflare Workers scaffold (`src/`, `wrangler.toml`, `cf:*` tasks) is retained as an alternative runtime for if/when we want CDN edge deployment.

Stripe is merchant of record. Consumer apps call smp; smp owns the Stripe account, the keys, and the webhook surface. Web apps never embed Stripe.js.

## Stack

- **xs** (cablehead/cross-stream) — embedded event store, append-only stream + topic indexing.
- **http-nu** (cablehead) — HTTP server, dispatches routes to nushell handler closures via `use http-nu/router`.
- **nushell** — handlers (`scripts/handler.nu`), bootstrap (`scripts/bootstrap.nu`), data refresh, onboarding, verify.
- **stripe-cli** — Stripe API calls for the bootstrap layer + webhook tunnel forwarding (`stripe listen`).
- **pitchfork** — supervises `http-nu` + `stripe listen` as daemons (see `pitchfork.toml`).
- **fnox** — macOS keychain → env vars, scoped via `fnox exec --`.
- **mise** — tool versions + the entire task surface.

Runtime is OS-neutral and lives entirely on your laptop or any VPS — no vendor lock-in.

## Conventions

- **mise tasks are the entry points.** Avoid running raw `nu`, `xs`, `http-nu`, `stripe` outside `mise x --` or `fnox exec --` (mise shim activation can fail otherwise).
- **Verb tasks are the canonical bootstrap surface:**
  - `mise run show -- <what> [arg]` — read-only Stripe + local data display
  - `mise run apply -- <what>` — mutate Stripe state from JSONL (idempotent)
  - `mise run teardown -- <slug>` — archive a project's Stripe state
  - `mise run test -- <flow> [arg]` — sandbox HIL flows
- **Declarative data is JSONL** under `data/`:
  - `data/reference/*.jsonl` — Stripe-sourced; refresh via `data:check`, never hand-edit.
  - `data/config/*.jsonl` — our config; applied to Stripe via `apply -- *`.
  - `data/projects/<slug>/` — one dir per consumer app; `project.json` + `products.jsonl` + `prices.jsonl`.
  - `data/launches.jsonl` — per-market-entry tracker.
- **Every Stripe object carries `metadata.project=<slug>`** for multi-tenancy under one Stripe account. Cross-leak protection: scripts only act on objects matching the project's metadata.
- **Runtime events flow into xs.** `scripts/handler.nu` is the http-nu handler closure. Routes append events to xs topics (`stripe.webhook.received`, `.verified`, `.invalid`). Future routes will emit `stripe.intent.*` and `stripe.api.*` events for consumer fan-out + audit.
- **Secrets via fnox keychain.** Always use `fnox set -p keychain NAME 'value'` (the `-p keychain` is non-negotiable — without it fnox writes plaintext into `fnox.toml`).
- **The pitchfork `http` daemon is wrapped in `fnox exec --`** so handler.nu sees `STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY` for HMAC verify + API calls.

## Where the data and the logic intersect

The substrate is **xs**. Every interesting thing becomes an event:

```
Stripe webhook  ──► /v1/webhook  ──► handler.nu HMAC-verifies  ──► .append xs
Consumer RPC    ──► /v1/checkout ──► handler.nu emits intent   ──► .append xs
                                                                       │
                                                                       ▼
                                                       projections (read views)
                                                       handler subscribers (fan-out, audit)
```

Bootstrap (the apply / show / teardown layer) is declarative and one-way (JSONL → Stripe). The runtime is event-sourced — the event log is the authoritative state.

## Required reading before changes

- `docs/ADR.md` — Architecture decisions (runtime pivot, multi-project namespacing, event-substrate, etc.) — Decision 9 captures the http-nu+xs pivot.
- `docs/SETUP.md` — Stripe account setup with country-eligibility caveats.
- `docs/TASKS.md` — Task inventory + data-flow matrix.
- `data/projects/README.md` — per-project layout schema.
- `data/README.md` — reference / config / projects / launches data dictionary.

## Status

End-to-end pipeline verified on http-nu+xs: 7/7 events from a `stripe trigger checkout.session.completed` fixture HMAC-verified and appended to xs as `stripe.webhook.verified`. Real prior $31.90 sandbox payment also landed end-to-end on the AU-registered account through the bootstrap + Stripe integration. Next milestones: dispatcher handler for consumer fan-out, `stripe.intent.*` events for RPC mutations, optional Cloudflare deploy via `cf:*` tasks.
