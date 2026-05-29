# data/projects/

One subdirectory per consumer project that uses smp. Every Stripe object created on its behalf carries `metadata.project=<slug>` for multi-tenancy + cross-leak safety.

## Layout

```
data/projects/<slug>/
├── project.json     # identity + Phase 3 consumer block
├── products.jsonl   # what the project sells
└── prices.jsonl     # priced per (product × interval × currency)
```

`<slug>` is the directory name and must match the `slug` field inside `project.json`.

## project.json

```json
{
  "slug": "remy-sport",
  "name": "Remy Sport",
  "description": "…",
  "domain": "remy-sport.dev",
  "owner": "joeblew999",
  "github_repo": "https://github.com/joeblew999/remy-sport",
  "started": "2026-05-28",
  "consumer": {
    "webhook_url":              "https://remy-sport.dev/webhooks/smp",
    "signing_secret_keychain":  "SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET",
    "bearer_token_keychain":    "SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN",
    "event_filters":            ["checkout.session.completed", "customer.subscription.*", "invoice.paid"]
  }
}
```

The `consumer` block is the Phase 3 dispatch contract. Full field semantics + HMAC verify code: **[docs/CONSUMERS.md](../../docs/CONSUMERS.md)**.

| Field | Purpose |
|---|---|
| `slug` | The Stripe metadata value (`metadata.project=<slug>`). |
| `consumer.webhook_url` | Where the dispatcher POSTs HMAC-signed Stripe events. |
| `consumer.signing_secret_keychain` | fnox keychain item holding the per-consumer HMAC secret. |
| `consumer.bearer_token_keychain` | Reserved for future `/v1/checkout` consumer-RPC auth. |
| `consumer.event_filters` | Stripe `event.type` patterns. Trailing `*` wildcards supported. Empty = all events. |

## How bootstrap iterates projects

`apply -- products` and `apply -- prices` loop every `data/projects/*/` dir, read `project.json`, seed the catalog with `metadata.project=<slug>` on every create. Existing Stripe objects get **backfilled** with metadata if missing — re-running is always safe.

## Cross-check which project owns a Stripe object

```sh
fnox exec -- stripe products list --limit 100 \
  | jq '.data[] | select(.metadata.project == "remy-sport") | {id, name, metadata}'

# or search by metadata (Stripe Search API)
fnox exec -- stripe products search --query "metadata['project']:'remy-sport'" --limit 5
```

## Add a new project

1. `mkdir data/projects/<slug>/` + write `project.json` (slug must match dir).
2. Write `products.jsonl` + `prices.jsonl` (schema matches remy-sport).
3. `mise run apply -- products && mise run apply -- prices`
4. Phase 3 (if registering as a consumer): set the signing secret, restart dispatcher:
   ```sh
   fnox set -p keychain SMP_CONSUMER_<SLUG>_SIGNING_SECRET "$(openssl rand -hex 32)"
   mise run dev:restart-dispatcher
   ```

That's it.
