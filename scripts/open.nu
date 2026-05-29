#!/usr/bin/env nu
# Open the right Stripe / Cloudflare dashboard page in the user's default
# browser. Saves the "where do I find that thing again" lookup.
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
        # Stripe — get the API key, set up the account
        "stripe-keys":            "https://dashboard.stripe.com/test/apikeys"
        "stripe-account":         "https://dashboard.stripe.com/settings/account"
        "stripe-onboard":         "https://dashboard.stripe.com/account/onboarding"
        "stripe-smp":             "https://dashboard.stripe.com/settings/managed-payments"
        "stripe-smp-docs":        "https://docs.stripe.com/payments/managed-payments/set-up"
        "stripe-webhooks":        "https://dashboard.stripe.com/test/webhooks"
        "stripe-products":        "https://dashboard.stripe.com/test/products"
        "stripe-customers":       "https://dashboard.stripe.com/test/customers"
        "stripe-dashboard":       "https://dashboard.stripe.com/test"
        "stripe-payment-methods": "https://dashboard.stripe.com/test/settings/payment_methods"

        # Cloudflare — get the API token + account id
        "cf-tokens":              "https://dash.cloudflare.com/profile/api-tokens"
        "cf-account":             "https://dash.cloudflare.com"
        "cf-workers":             "https://dash.cloudflare.com/?to=/:account/workers-and-pages"
    }

    if ($page | is-empty) {
        print "open: <page>\n"
        print "available pages:"
        $pages | columns | each {|p| print $"  ($p)" } | ignore
        exit 1
    }

    let url = ($pages | get --optional $page)
    if ($url | is-empty) {
        print $"unknown page: ($page)"
        exit 1
    }
    open_url $url
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
