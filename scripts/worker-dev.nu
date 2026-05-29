#!/usr/bin/env nu
# Run `wrangler dev` after materializing secrets from fnox into `.dev.vars`.
#
# wrangler dev does NOT read secrets from process env vars — it expects them
# in `.dev.vars` (gitignored). This script bridges fnox(keychain) → .dev.vars
# at startup so the user never hand-edits .dev.vars.
# Per [[feedback-secrets-fnox-mise]] this file is the materialization point,
# not a source of truth.

def get_env [name: string] {
    $env | get --optional $name | default ""
}

let lines = [
    $"STRIPE_SECRET_KEY=(get_env 'STRIPE_SECRET_KEY')"
    $"STRIPE_WEBHOOK_SECRET=(get_env 'STRIPE_WEBHOOK_SECRET')"
]
$lines | str join "\n" | save -f .dev.vars
print "✓ .dev.vars regenerated from fnox keychain"
^wrangler dev
