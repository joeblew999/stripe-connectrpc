#!/usr/bin/env nu
# Open the right Stripe / Cloudflare dashboard page in the user's default
# browser — but ONLY if the thing that page lets you set up is not already
# configured. This is the "idempotency" rule: re-running open:* should be
# a no-op when everything is already in place.
#
# Usage:  nu scripts/open.nu <page>
# Or via mise:  mise run open:<page>
#
# All Stripe URLs default to TEST MODE. Swap /test/ → /live/ in the URLs
# below when you're ready for production.

def main [
    page: string = ""
] {
    let pages = {
        # --- Stripe ---
        "stripe-keys": {
            url: "https://dashboard.stripe.com/test/apikeys",
            needed: {|| needs_keychain "SMP_STRIPE_SECRET_KEY" },
            already: "SMP_STRIPE_SECRET_KEY already in keychain"
        }
        "stripe-account": {
            url: "https://dashboard.stripe.com/settings/account",
            needed: {|| needs_stripe_account_setup },
            already: "Stripe account already activated (charges_enabled + details_submitted)"
        }
        "stripe-onboard": {
            url: "https://dashboard.stripe.com/account/onboarding",
            needed: {|| needs_stripe_account_setup },
            already: "Stripe account already onboarded"
        }
        "stripe-smp": {
            url: "https://dashboard.stripe.com/settings/managed-payments",
            needed: {|| needs_stripe_account_setup },
            already: "Stripe account ready — SMP enablement is per-checkout-session, no dashboard toggle needed"
        }
        "stripe-smp-docs": {
            url: "https://docs.stripe.com/payments/managed-payments/set-up",
            needed: {|| needs_stripe_account_setup },  # only opens if account isn't ready
            already: "Stripe account already set up — docs page not needed"
        }
        "stripe-webhooks": {
            url: "https://dashboard.stripe.com/test/webhooks",
            needed: {|| needs_keychain "SMP_STRIPE_WEBHOOK_SECRET" },
            already: "SMP_STRIPE_WEBHOOK_SECRET already in keychain (from `stripe listen` or dashboard endpoint)"
        }
        "stripe-products": {
            url: "https://dashboard.stripe.com/test/products",
            needed: {|| needs_stripe_products },
            already: "Stripe products already seeded — re-apply with `mise run stripe:apply-products`"
        }
        "stripe-customers": {
            url: "https://dashboard.stripe.com/test/customers",
            needed: {|| needs_stripe_account_setup },
            already: "Stripe account ready — list customers via `stripe customers list` instead"
        }
        "stripe-dashboard": {
            url: "https://dashboard.stripe.com/test",
            needed: {|| needs_stripe_account_setup },
            already: "Stripe account ready — drive from CLI instead of dashboard"
        }
        "stripe-payment-methods": {
            url: "https://dashboard.stripe.com/test/settings/payment_methods",
            needed: {|| needs_stripe_payment_methods },
            already: "Stripe payment methods config already synced via `apply -- payment-methods`"
        }

        # --- Cloudflare ---
        "cf-tokens": {
            url: "https://dash.cloudflare.com/profile/api-tokens",
            needed: {|| needs_keychain "CLOUDFLARE_API_TOKEN" },
            already: "CLOUDFLARE_API_TOKEN already in keychain"
        }
        "cf-account": {
            url: "https://dash.cloudflare.com",
            needed: {|| needs_keychain "CLOUDFLARE_ACCOUNT_ID" },
            already: "CLOUDFLARE_ACCOUNT_ID already in keychain"
        }
        "cf-workers": {
            url: "https://dash.cloudflare.com/?to=/:account/workers-and-pages",
            needed: {|| (needs_keychain "CLOUDFLARE_API_TOKEN") or (needs_keychain "CLOUDFLARE_ACCOUNT_ID") },
            already: "Cloudflare already wired — `mise run cf:worker-tail` shows live state"
        }
    }

    if ($page | is-empty) {
        print "open: <page>\n"
        print "available pages (open if not already configured):"
        $pages | columns | each {|p| print $"  ($p)" } | ignore
        exit 1
    }

    let entry = ($pages | get --optional $page)
    if ($entry | is-empty) {
        print $"unknown page: ($page)"
        exit 1
    }

    let need_to_open = (do $entry.needed)
    if $need_to_open {
        open_url $entry.url
    } else {
        print $"  ✓ ($entry.already) — skipping browser open."
        print $"    url if you still want it: ($entry.url)"
    }
}

# --- idempotency probes ---

# True iff fnox doesn't have a non-empty value for this keychain entry.
def needs_keychain [name: string] {
    let r = (do { fnox get $name } | complete)
    not ($r.exit_code == 0 and (($r.stdout | str trim | str length) > 0))
}

# True iff the Stripe account isn't activated yet (no charges_enabled +
# details_submitted). Returns true (= open the browser) if we can't reach
# Stripe at all, so the user gets a chance to set keys up.
def needs_stripe_account_setup [] {
    let env_ok = ("STRIPE_API_KEY" in $env or "STRIPE_SECRET_KEY" in $env)
    if not $env_ok { return true }
    let r = (^stripe accounts retrieve | complete)
    if $r.exit_code != 0 { return true }
    let acct = (try { $r.stdout | from json } catch { {} })
    let ce = ($acct | get --optional charges_enabled | default false)
    let ds = ($acct | get --optional details_submitted | default false)
    not ($ce and $ds)
}

# True iff Stripe has zero products carrying metadata.project=* — i.e.
# `apply -- products` has never run. Uses the Stripe Search API which DOES
# support metadata filtering (the list endpoint does not).
def needs_stripe_products [] {
    # Iterate local project dirs and ask Stripe if any product exists for each.
    if not ("data/projects" | path exists) { return true }
    let slugs = (ls data/projects | where type == "dir" | get name | each {|d| $d | path basename })
    if ($slugs | length) == 0 { return true }
    for slug in $slugs {
        let q = $"metadata['project']:'($slug)'"
        let r = (^stripe products search --query $q --limit 1 | complete)
        if $r.exit_code == 0 {
            let data = (try { $r.stdout | from json | get data } catch { [] })
            if ($data | length) > 0 { return false }   # at least one slug seeded → done
        }
    }
    true
}

# True iff our payment-method config hasn't been applied. We can't read
# back the merchant-level enabled-PM set from the API in a single call, so
# we use a presence heuristic: does the local config exist and has at least
# one configured PM. Once the local JSONL is there, opening the dashboard
# adds no information — the dashboard view is just a different surface on
# the same data.
def needs_stripe_payment_methods [] {
    let path = "data/config/payment-methods.jsonl"
    if not ($path | path exists) { return true }
    let lines = (try { open --raw $path | lines | where ($it | str length) > 0 } catch { [] })
    ($lines | length) == 0
}

# Cross-platform browser-open. Nushell has no built-in; detect OS and
# pick the right shell command. Per [[feedback-nushell-for-os-neutrality]]
# we never hardcode paths.
export def open_url [url: string] {
    print $"opening: ($url)"
    let os = $nu.os-info.name
    match $os {
        "macos"   => { ^open $url }
        "linux"   => { ^xdg-open $url }
        "windows" => { ^cmd /c start $url }
        _ => {
            print $"  (unsupported OS: ($os) — open manually)"
        }
    }
}
