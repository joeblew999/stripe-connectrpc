#!/usr/bin/env nu
# Stripe-side bootstrap + test helpers — drives the official `stripe` CLI.
# async-stripe is library-only (no Rust CLI), so JSONL → Stripe state is
# nushell + stripe-cli.
#
# All subcommands are idempotent (check-then-create).
# Run via mise: `mise run bootstrap:<subcommand>` or `mise run test:<subcommand>`.
# Direct: `nu scripts/bootstrap.nu <subcommand> [arg]`.

def main [
    cmd: string = "status"
    arg?: string
] {
    match $cmd {
        # Setup
        "products"      => { seed_products }
        "prices"        => { seed_prices }
        "webhook"       => { register_webhook }
        "portal"        => { configure_portal }
        "all"           => { seed_products ; seed_prices ; configure_portal ; register_webhook }

        # Info
        "status"        => { show_status }
        "account"       => { show_account }
        "countries"     => { print_countries }
        "tax-codes"     => { print_tax_codes }
        "launches"      => { print_launches }
        "scan"          => { print_scan }
        "flow"          => { print_flow }

        # Test loop
        "test-customer"          => { test_customer }
        "test-checkout"          => { test_checkout ($arg | default "sports_coach_monthly_usd") "smp" }
        "test-checkout-payments" => { test_checkout ($arg | default "sports_coach_monthly_usd") "payments" }
        "check-country"          => { check_country ($arg | default "TH") }

        _ => {
            print $"unknown subcommand: ($cmd)"
            print ""
            print "setup:  products | prices | webhook | portal | all"
            print "info:   status | account | countries | tax-codes | launches | scan | flow"
            print "        check-country <ISO>"
            print "test:   test-customer"
            print "        test-checkout          [lookup_key]   (SMP mode)"
            print "        test-checkout-payments [lookup_key]   (Stripe Payments — we are MoR)"
            exit 1
        }
    }
}

# =============================================================================
# Setup
# =============================================================================

def seed_products [] {
    let rows = (open --raw data/products.jsonl | lines | each {|l| $l | from json})
    print $"seeding (($rows | length)) products from data/products.jsonl"
    for p in $rows {
        let exists = (^stripe products retrieve $p.id err> (std null-device) | complete)
        if $exists.exit_code == 0 {
            print $"  ✓ ($p.id) already exists"
            continue
        }
        let r = (^stripe products create
            --id $p.id
            --name $p.name
            --description $p.description
            -d $"tax_code=($p.tax_code)"
            | complete)
        if $r.exit_code == 0 {
            print $"  ✓ created ($p.id)"
        } else {
            print $"  ✗ failed ($p.id): ($r.stdout)"
        }
    }
}

def seed_prices [] {
    let rows = (open --raw data/prices.jsonl | lines | each {|l| $l | from json})
    print $"seeding (($rows | length)) prices from data/prices.jsonl"
    for p in $rows {
        let listing = (^stripe prices list --lookup-keys $p.lookup_key --limit 1 | complete)
        let existing_count = if $listing.exit_code == 0 {
            try { ($listing.stdout | from json | get data | length) } catch { 0 }
        } else { 0 }
        if $existing_count > 0 {
            print $"  ✓ ($p.lookup_key) already exists"
            continue
        }
        let r = (^stripe prices create
            --lookup-key $p.lookup_key
            --product $p.product
            --unit-amount $p.unit_amount
            --currency $p.currency
            -d $"recurring[interval]=($p.interval)"
            | complete)
        if $r.exit_code == 0 {
            print $"  ✓ created ($p.lookup_key)"
        } else {
            print $"  ✗ failed ($p.lookup_key): ($r.stdout)"
        }
    }
}

def register_webhook [] {
    let url_r = (do { fnox get SMP_WORKER_URL } | complete)
    if $url_r.exit_code != 0 or (($url_r.stdout | str trim | str length) == 0) {
        print "✗ SMP_WORKER_URL not in keychain"
        print "  Deploy first: mise run worker:deploy"
        print "  Or set: fnox set -p keychain SMP_WORKER_URL 'https://smp.<sub>.workers.dev'"
        exit 1
    }
    let endpoint = $"(($url_r.stdout | str trim))/v1/webhook"

    # Skip if an endpoint with this URL already exists.
    let listing = (^stripe webhook_endpoints list --limit 100 | complete)
    let dup = if $listing.exit_code == 0 {
        try {
            ($listing.stdout | from json | get data | where url == $endpoint | length)
        } catch { 0 }
    } else { 0 }
    if $dup > 0 {
        print $"  ✓ webhook endpoint for ($endpoint) already exists"
        return
    }

    print $"creating Stripe webhook endpoint at ($endpoint) ..."
    let events = [
        "checkout.session.completed"
        "checkout.session.async_payment_succeeded"
        "checkout.session.async_payment_failed"
        "customer.subscription.created"
        "customer.subscription.updated"
        "customer.subscription.deleted"
        "invoice.paid"
        "invoice.payment_failed"
        "charge.refunded"
    ]
    let event_args = ($events | each {|e| ["-e" $e]} | flatten)

    let r = (^stripe webhook_endpoints create --url $endpoint ...$event_args | complete)
    if $r.exit_code == 0 {
        print "✓ created."
        print "  Capture `whsec_...` from output above and run:"
        print "    fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_...'"
        print "    mise run worker:secret-put"
    } else {
        print "✗ stripe webhook_endpoints create failed:"
        print $r.stdout
        exit 1
    }
}

def configure_portal [] {
    # Skip if a default portal config already exists.
    let listing = (^stripe billing_portal/configurations list --is-default=true --limit 1 | complete)
    let count = if $listing.exit_code == 0 {
        try { ($listing.stdout | from json | get data | length) } catch { 0 }
    } else { 0 }
    if $count > 0 {
        print "  ✓ default Customer Portal already configured"
        return
    }

    print "configuring default Stripe Customer Portal ..."
    let r = (^stripe post /v1/billing_portal/configurations
        -d "business_profile[headline]=Manage your sports subscription"
        -d "features[subscription_cancel][enabled]=true"
        -d "features[subscription_cancel][mode]=at_period_end"
        -d "features[subscription_update][enabled]=true"
        -d "features[subscription_update][default_allowed_updates][]=price"
        -d "features[payment_method_update][enabled]=true"
        -d "features[invoice_history][enabled]=true"
        -d "features[customer_update][enabled]=true"
        -d "features[customer_update][allowed_updates][]=email"
        -d "features[customer_update][allowed_updates][]=address"
        | complete)
    if $r.exit_code == 0 {
        print "  ✓ Customer Portal configured"
    } else {
        print $"  ✗ portal config failed: ($r.stdout)"
        exit 1
    }
}

# =============================================================================
# Info
# =============================================================================

def show_account [] {
    print "=== Stripe account ==="
    let r = (^stripe accounts retrieve | complete)
    if $r.exit_code != 0 {
        print "✗ stripe accounts retrieve failed — is STRIPE_API_KEY set in env?"
        print "  Wrap commands in `fnox exec --` or `mise run bootstrap:account`."
        exit 1
    }
    let acct = ($r.stdout | from json)
    let livemode = if ($acct | get --optional livemode | default false) { "LIVE" } else { "TEST" }
    print $"  mode:               ($livemode)"
    print $"  id:                 ($acct.id)"
    print $"  country:            ($acct | get --optional country | default '-')"
    print $"  default_currency:   ($acct | get --optional default_currency | default '-')"
    print $"  charges_enabled:    ($acct | get --optional charges_enabled | default false)"
    print $"  payouts_enabled:    ($acct | get --optional payouts_enabled | default false)"
    print $"  details_submitted:  ($acct | get --optional details_submitted | default false)"
    if $livemode == "TEST" {
        print "\n  Using test mode — perfect for sandbox payment loops."
    }
}

def show_status [] {
    print "=== Stripe webhook endpoints ==="
    ^stripe webhook_endpoints list --limit 10
    print "\n=== Stripe products (first 10) ==="
    ^stripe products list --limit 10
    print "\n=== Stripe prices (first 10) ==="
    ^stripe prices list --limit 10
    print "\n=== Billing portal configs ==="
    ^stripe billing_portal/configurations list --limit 5
}

def print_countries [] {
    let rows = (open --raw data/countries.jsonl | lines | each {|l| $l | from json})
    let smp_count = ($rows | where {|c| "smp" in $c.seller_modes} | length)
    let pay_count = ($rows | where {|c| "payments" in $c.seller_modes} | length)
    let paystack_count = ($rows | where {|c| "paystack" in $c.seller_modes} | length)
    let blocked_count = ($rows | where {|c| ($c.buyer_blocked_modes | length) > 0} | length)
    print $"jurisdictions tracked: (($rows | length))"
    print $"  seller modes available:"
    print $"    smp:        ($smp_count)"
    print $"    payments:   ($pay_count)"
    print $"    paystack:   ($paystack_count)"
    print $"  buyer-blocked any mode:   ($blocked_count)"
    $rows
    | group-by region
    | items {|region, list|
        print $"\n($region) — (($list | length))"
        $list | each {|c|
            let modes = if ($c.seller_modes | length) == 0 {
                if ($c.buyer_blocked_modes | length) > 0 {
                    "✗ blocked-buyer"
                } else {
                    "·"
                }
            } else {
                $c.seller_modes | str join ","
            }
            let preview = if $c.payments_preview { "*" } else { " " }
            let cur = ($c.currency | default "—")
            print $"  ($c.code)  ($cur | fill -a left -c ' ' -w 4)  ($modes | fill -a left -c ' ' -w 18)($preview) ($c.name)"
        } | ignore
    }
    | ignore
    print "\n  modes legend: smp = Stripe Managed Payments (Stripe is MoR)"
    print "                payments = Stripe Payments (we are MoR, we handle tax)"
    print "                paystack = via Paystack integration (separate API)"
    print "                * = payments seller in preview/invite-only"
}

# Show what modes are available for a given country code.
def check_country [code: string] {
    let code_upper = ($code | str upcase)
    let rows = (open --raw data/countries.jsonl | lines | each {|l| $l | from json})
    let matched = ($rows | where code == $code_upper)
    if ($matched | length) == 0 {
        print $"  ($code_upper) — not in countries.jsonl"
        print "  (Stripe sells to ~195 countries; absent = buyer-allowed under SMP, no seller relationship)"
        return
    }
    let c = ($matched | first)
    print $"  ($c.code) — ($c.name) [($c.region)]"
    print $"    currency:            (($c.currency | default '—'))"
    print $"    seller modes:        (($c.seller_modes | str join ', ' | default '(none)'))"
    if $c.payments_preview {
        print "    payments preview:    yes — invite-only"
    }
    print $"    buyer blocked under: (($c.buyer_blocked_modes | str join ', ' | default '(none)'))"
    print ""
    if "smp" in $c.seller_modes {
        print "  ✓ SMP available — Stripe is merchant of record, handles tax in 80+ countries"
    } else {
        print "  ✗ SMP not available — register in a SMP seller country, OR use payments mode"
    }
    if "payments" in $c.seller_modes {
        print "  ✓ Stripe Payments available — we are MoR, we handle tax (Stripe Tax can calculate)"
    }
}

def print_tax_codes [] {
    let rows = (open --raw data/tax-codes.jsonl | lines | each {|l| $l | from json})
    print $"SMP-eligible tax codes — total (($rows | length))"
    $rows
    | group-by group
    | items {|group, list|
        print $"\n($group) — (($list | length))"
        $list | each {|c| print $"  ($c.code)  ($c.name)" } | ignore
    }
    | ignore
}

def print_scan [] {
    let countries = (open --raw data/countries.jsonl | lines | each {|l| $l | from json})
    let smp = ($countries | where {|c| "smp" in $c.seller_modes} | length)
    let payments = ($countries | where {|c| "payments" in $c.seller_modes} | length)
    let paystack = ($countries | where {|c| "paystack" in $c.seller_modes} | length)
    let blocked = ($countries | where {|c| ($c.buyer_blocked_modes | length) > 0} | length)
    let tax = (open --raw data/tax-codes.jsonl | lines | length)
    let products = (open --raw data/products.jsonl | lines | length)
    let prices = (open --raw data/prices.jsonl | lines | length)
    let launches = (open --raw data/launches.jsonl | lines | length)

    print "data/ summary"
    print "============="
    print $"countries.jsonl    (($countries | length)) rows  — sellers: smp=($smp) payments=($payments) paystack=($paystack)  blocked-buyers=($blocked)"
    print $"tax-codes.jsonl    ($tax) rows  — SMP-eligible Stripe tax codes"
    print $"products.jsonl     ($products) rows  — sports SaaS tiers"
    print $"prices.jsonl       ($prices) rows  — per product/interval/currency"
    print $"launches.jsonl     ($launches) rows  — project × jurisdiction tracker"
}

def print_flow [] {
    print "smp end-to-end flow — supported-country Stripe account"
    print "======================================================"
    print ""
    print "Prereq: Stripe account is registered in one of the 38 SMP seller countries."
    print "        Run `mise run bootstrap:countries` to check the list."
    print ""
    print "1. Fresh-clone bootstrap"
    print "   mise run mise:install     # rust 1.88 + wrangler + worker-build + nu + stripe-cli"
    print "   mise run onboard          # interactive: CF + Stripe creds into keychain"
    print "   mise run verify           # tools + wasm32 target + keychain entries"
    print ""
    print "2. Confirm Stripe account"
    print "   mise run bootstrap:account"
    print "     ▸ expect: mode=TEST, country=<supported>, charges_enabled=true"
    print ""
    print "3. Seed Stripe-side state (idempotent — safe to re-run)"
    print "   mise run bootstrap:all"
    print "     ▸ products (3) + prices (6) + portal (1) + webhook (skipped until deployed)"
    print "   mise run bootstrap:status"
    print "     ▸ snapshot of what landed"
    print ""
    print "4. Sandbox payment loop — three terminals"
    print "   T1:  mise run worker:dev"
    print "   T2:  mise run stripe:listen"
    print "        copy printed whsec_… into keychain:"
    print "          fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'"
    print "        restart T1 so it picks up the new secret"
    print "   T3:  mise run test:checkout"
    print "        ▸ prints checkout URL; open in browser"
    print "        ▸ pay with 4242 4242 4242 4242 (any future expiry/CVC)"
    print "        ▸ T1 logs the checkout.session.completed event"
    print ""
    print "5. Going live (later)"
    print "   - Activate the Stripe account (KYC, bank, tax id)"
    print "   - Enable Managed Payments in Dashboard → Settings → Payments → Managed Payments"
    print "   - Swap keychain to live: fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_live_…'"
    print "   - mise run worker:deploy  → capture URL → fnox set SMP_WORKER_URL '…'"
    print "   - mise run bootstrap:webhook  → capture whsec_ → mise run worker:secret-put"
    print "   - mise run test:checkout against the deployed worker; real card"
}

def print_launches [] {
    let rows = (open --raw data/launches.jsonl | lines | each {|l| $l | from json})
    print $"launches tracked: (($rows | length))"
    for r in $rows {
        let mark = match $r.stage {
            "live"      => "✓"
            "blocked"   => "✗"
            "planning"  => "○"
            "paused"    => "⏸"
            _           => "·"
        }
        print $"  ($mark)  ($r.project)/($r.country) [($r.mode)] — ($r.stage)"
        if ($r.notes | str length) > 0 {
            print $"       ($r.notes)"
        }
    }
}

# =============================================================================
# Test loop — single payment end-to-end via sandbox
# =============================================================================

def test_customer [] {
    print "creating test customer ..."
    let r = (^stripe customers create
        --email "smp-test@example.com"
        --name "SMP Test Customer"
        -d "metadata[smp_test]=true"
        | complete)
    if $r.exit_code == 0 {
        let cust = ($r.stdout | from json)
        print $"  ✓ created customer ($cust.id)"
        print $"    email: ($cust.email)"
    } else {
        print $"  ✗ failed: ($r.stdout)"
        exit 1
    }
}

def test_checkout [lookup_key: string, mode: string] {
    # Resolve price by lookup_key.
    let listing = (^stripe prices list --lookup-keys $lookup_key --limit 1 | complete)
    if $listing.exit_code != 0 {
        print $"✗ failed to list prices: ($listing.stdout)"
        exit 1
    }
    let prices = ($listing.stdout | from json | get data)
    if ($prices | length) == 0 {
        print $"✗ no price found for lookup_key=($lookup_key)"
        print "  Run: mise run bootstrap:prices"
        exit 1
    }
    let price_id = ($prices | first | get id)
    print $"using price ($price_id) for lookup_key ($lookup_key) — mode=($mode)"

    mut args = [
        "post" "/v1/checkout/sessions"
        "-d" "mode=subscription"
        "-d" $"line_items[0][price]=($price_id)"
        "-d" "line_items[0][quantity]=1"
        "-d" "success_url=http://localhost:8787/health?session={CHECKOUT_SESSION_ID}"
        "-d" "cancel_url=http://localhost:8787/health?canceled=1"
    ]
    if $mode == "smp" {
        $args = ($args | append ["-d" "managed_payments[enabled]=true"])
        print "creating Checkout Session with managed_payments.enabled=true ..."
    } else {
        # Plain Stripe Payments mode — we are MoR. Enable Stripe Tax so taxes
        # are calculated; we remain responsible for remittance.
        $args = ($args | append ["-d" "automatic_tax[enabled]=true"])
        print "creating Checkout Session (Stripe Payments mode, automatic_tax enabled) ..."
    }

    let r = (^stripe ...$args | complete)
    if $r.exit_code != 0 {
        print $"✗ failed: ($r.stdout)"
        print ""
        if $mode == "smp" {
            print "  If you see 'managed_payments is not enabled for this account':"
            print "  - Confirm the Stripe account is in a SMP seller country (`mise run bootstrap:account`)"
            print "  - Enable SMP in Dashboard → Settings → Payments → Managed Payments"
            print "  - Or use Stripe Payments mode: `mise run test:checkout-payments`"
        } else {
            print "  If you see 'automatic_tax: tax registrations required':"
            print "  - Register at least one tax jurisdiction in Dashboard → Tax → Registrations"
            print "  - Or drop `automatic_tax` for unbilled testing (edit scripts/bootstrap.nu)"
        }
        exit 1
    }
    let session = ($r.stdout | from json)
    print $"  ✓ session ($session.id)"
    print ""
    print "Open this URL in your browser:"
    print $"  ($session.url)"
    print ""
    print "Test card: 4242 4242 4242 4242 — any future expiry, any CVC, any zip."
    print "Make sure `mise run worker:dev` AND `mise run stripe:listen` are running"
    print "so the post-payment webhook reaches smp."
}
