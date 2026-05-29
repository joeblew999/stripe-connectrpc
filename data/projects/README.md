# data/projects/

One subdirectory per consumer project that uses smp. Each project gets its own catalog of products + prices, and **every Stripe object created on its behalf is tagged with `metadata.project=<slug>`** so the Stripe Dashboard / queries can filter by project.

## Layout

```
data/projects/
└── <slug>/
    ├── project.json         # {slug, name, domain, github_repo, …}
    ├── products.jsonl       # what the project sells
    └── prices.jsonl         # priced per (product × interval × currency)
```

`<slug>` is the directory name. It must match the `slug` field inside `project.json`.

## project.json schema

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
    "webhook_url": "https://remy-sport.dev/webhooks/smp",
    "signing_secret_keychain": "SMP_CONSUMER_REMY_SPORT_SIGNING_SECRET",
    "bearer_token_keychain": "SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN",
    "event_filters": ["checkout.session.completed", "customer.subscription.*", "invoice.paid"]
  }
}
```

| Field | Purpose |
|---|---|
| `slug` | The Stripe metadata value: `metadata.project=<slug>` on every object |
| `name` | Display name |
| `description` | Plain-English what-it-is |
| `domain` | Project's primary web domain |
| `owner` | GitHub username/org |
| `github_repo` | Source repo for the consumer app |
| `started` | ISO-8601 date the project was registered with smp |
| `consumer.webhook_url` | Where smp POSTs signed events for this consumer (CF Queues fan-out target) |
| `consumer.signing_secret_keychain` | fnox keychain item holding the HMAC signing secret smp uses when posting to `webhook_url` |
| `consumer.bearer_token_keychain` | fnox keychain item holding the bearer token this consumer presents on inbound RPC calls to smp |
| `consumer.event_filters` | Subset of `data/config/webhook-events.jsonl` this consumer cares about. Glob patterns supported (e.g. `customer.subscription.*`) |

## How bootstrap iterates projects

`scripts/bootstrap.nu` (subcommands `products`, `prices`) loops over every `data/projects/*/` directory, reads its `project.json`, then seeds its catalog with `metadata.project=<slug>` on every create. Existing Stripe objects get **backfilled** with the metadata if missing — re-running `apply:products` is always safe.

## Cross-checking which project owns a Stripe object

```sh
# Filter products by project
mise exec -- stripe products list --limit 100 \
  | jq '.data[] | select(.metadata.project == "remy-sport") | {id, name, metadata}'

# Or fetch a single product and confirm the tag
fnox exec -- stripe products retrieve sports_coach | jq '.metadata'
```

## Adding a second project

1. `mkdir data/projects/<new-slug>` + write `project.json`
2. Create `products.jsonl` and `prices.jsonl` (same schema as the existing remy-sport ones)
3. `mise run apply:products && mise run apply:prices`

That's it. New project lives alongside, all its Stripe objects tagged with its slug.
