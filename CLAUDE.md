# CLAUDE.md

Context for Claude (and humans) working in this repo.

## What this is

**stripe-smp** — Stripe Managed Payments shared service on Cloudflare Workers (Rust / wasm32). Stripe is merchant of record. Consumer apps call smp; smp owns the Stripe account, the keys, and the webhook surface. Web apps never embed Stripe.js.

## Stack

- Workers-rs on `wasm32-unknown-unknown` + arlyon/async-stripe runtime-free sub-crates (`-types`, `-shared`, `-client-core`, `-webhook`, `-checkout`).
- Bootstrap layer = mise + fnox + nushell + stripe-cli + pitchfork.
- Secrets via fnox → macOS keychain → mise → wrangler (`.dev.vars` materialized from fnox at `worker:dev` start).
- Tasks orchestrated through `mise.toml`; scripts in `nushell` for OS neutrality.

## Conventions

- **mise tasks are the entry points** — `mise run dev:up` / `bootstrap:all` / `test:checkout` / etc. Avoid running raw `stripe`, `wrangler`, `cargo` outside `mise x --` or `fnox exec --` (mise shim activation breaks otherwise).
- **Data is declarative JSONL** under `data/`:
  - `data/reference/*.jsonl` — Stripe-sourced, refresh via `mise run data:check`, never hand-edit.
  - `data/projects/<slug>/` — one dir per consumer app; `project.json` + `products.jsonl` + `prices.jsonl`.
  - `data/launches.jsonl` — per (project × country × mode) tracker.
- **Every Stripe object carries `metadata.project=<slug>`** for multi-tenancy under one Stripe account. Cross-leak protection: scripts only act on objects matching the project's metadata.
- **Secrets via fnox keychain.** Always use `fnox set -p keychain NAME 'value'` (the `-p keychain` is non-negotiable — without it fnox writes plaintext into `fnox.toml`).
- **Never hand-edit `.dev.vars`** — it's regenerated from fnox at `worker:dev` startup.

## Required reading before changes

- `docs/ADR.md` — 8 architecture decisions including multi-project namespacing, D1+Queues (no DO), `.dev.vars` materialization.
- `docs/SETUP.md` — Stripe account setup with country-eligibility caveats.
- `data/projects/README.md` — per-project layout schema.
- `data/README.md` — reference / projects / launches data dictionary.

## Status

Real sandbox payment landed end-to-end (AU-registered account, $29 + $2.90 SMP-handled tax). Inbound webhook + HMAC verify proven on wasm32. Outbound `StripeClient` adapter (worker::Fetch), D1 persistence, ConnectRPC service, CF Queues fan-out, and deploy are the next milestones — see the README "Worker endpoints" section.
