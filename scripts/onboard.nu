#!/usr/bin/env nu
# smp onboarding — interactive collection of CF + Stripe creds into the
# macOS keychain via fnox. Idempotent: already-set values are kept.
#
# Auto-opens the relevant dashboard page in the browser before each
# prompt, so you can copy the value directly without hunting for it.

# Cross-platform open (duplicated from scripts/open.nu — small enough
# that inlining beats nushell-module import dance).
def open_url [url: string] {
    let os = $nu.os-info.name
    match $os {
        "macos"   => { ^open $url }
        "linux"   => { ^xdg-open $url }
        "windows" => { ^cmd /c start $url }
        _ => { print $"  open manually: ($url)" }
    }
}

def ensure_secret [name: string, prompt: string, hint: string, url: string] {
    let r = (do { fnox get $name } | complete)
    let already = ($r.exit_code == 0 and (($r.stdout | str trim | str length) > 0))
    if $already {
        print $"  ✓ ($name) already in keychain"
        return
    }
    print $"\n  ($prompt)"
    if not ($hint | is-empty) { print $"    hint:   ($hint)" }
    if not ($url | is-empty) {
        print $"    opening: ($url)"
        open_url $url
        sleep 800ms
    }
    let value = (input -s $"    paste here, then press enter — ($name): ")
    print ""
    if ($value | str trim | is-empty) {
        print $"  · skipped — ($name) not set"
        return
    }
    fnox set -p keychain $name $value
    print $"  ✓ stored ($name) in keychain"
}

print "smp onboarding"
print "=============="
print "Each prompt opens the right dashboard page in your browser."
print "Already-set values are kept — re-run any time to fill gaps."

ensure_secret "CLOUDFLARE_API_TOKEN" \
    "Cloudflare API token" \
    "Create a token with Workers Scripts + Account Settings perms" \
    "https://dash.cloudflare.com/profile/api-tokens"

ensure_secret "CLOUDFLARE_ACCOUNT_ID" \
    "Cloudflare account ID" \
    "Right sidebar of any account page in the CF dashboard" \
    "https://dash.cloudflare.com"

ensure_secret "SMP_STRIPE_SECRET_KEY" \
    "Stripe secret key (sk_test_... for now)" \
    "Click 'Reveal test key' next to the Secret key row" \
    "https://dashboard.stripe.com/test/apikeys"

ensure_secret "SMP_STRIPE_WEBHOOK_SECRET" \
    "Stripe webhook signing secret (whsec_...)" \
    "Skip for now — `mise run stripe:listen` prints one on first run" \
    ""

print "\nDone."
print "Next: mise run verify  → mise run bootstrap:account"
