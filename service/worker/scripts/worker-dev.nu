#!/usr/bin/env nu
# Run `wrangler dev` after materializing secrets/config from fnox into `.dev.vars`.
#
# wrangler dev does NOT read secrets from process env vars — it expects them
# in `.dev.vars` (gitignored). This script bridges fnox(keychain)/env → .dev.vars
# at startup so the user never hand-edits .dev.vars.
# Per [[feedback-secrets-fnox-mise]] this file is the materialization point,
# not a source of truth.
#
# Auth is the shared Rauthy-OIDC → Cedar guard, so the worker needs RAUTHY_*
# (NOT the old per-project SMP_CONSUMER_TOKENS — that's gone). The worker
# fetches Rauthy's JWKS at RAUTHY_JWKS_URL and verifies tokens for RAUTHY_ISSUER.

def get_env [name: string] {
    $env | get --optional $name | default ""
}

let lines = [
    $"STRIPE_SECRET_KEY=(get_env 'STRIPE_SECRET_KEY')"
    $"STRIPE_WEBHOOK_SECRET=(get_env 'STRIPE_WEBHOOK_SECRET')"
    $"RAUTHY_ISSUER=(get_env 'RAUTHY_ISSUER')"
    $"RAUTHY_JWKS_URL=(get_env 'RAUTHY_JWKS_URL')"
    $"RAUTHY_AUD=(get_env 'RAUTHY_AUD')"
]
$lines | str join "\n" | save -f .dev.vars
print "✓ .dev.vars regenerated (STRIPE_* + RAUTHY_* from fnox/env)"
print "  note: needs a reachable Rauthy (RAUTHY_ISSUER / RAUTHY_JWKS_URL) to verify tokens."
^wrangler dev
