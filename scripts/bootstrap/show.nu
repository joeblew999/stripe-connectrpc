#!/usr/bin/env nu
# show.nu — read-only display verbs. No Stripe mutation, no xs writes.
#
# Surface (via bootstrap.nu dispatcher):
#   show -- account | status | countries | country <ISO> | tax-codes | tax-coverage
#         | tax <ISO> | launches | projects | payment-methods | scan | flow

use lib.nu *

# =============================================================================
# Stripe account / status
# =============================================================================

export def show_account [] {
    print "=== Stripe account ==="
    let r = (^stripe accounts retrieve | complete)
    if $r.exit_code != 0 {
        print "✗ stripe accounts retrieve failed — is STRIPE_API_KEY set in env?"
        print "  Wrap commands in `fnox exec --` or `mise run stripe:account`."
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

export def show_status [] {
    print "=== Stripe webhook endpoints ==="
    ^stripe webhook_endpoints list --limit 10
    print "\n=== Stripe products (first 10) ==="
    ^stripe products list --limit 10
    print "\n=== Stripe prices (first 10) ==="
    ^stripe prices list --limit 10
    print "\n=== Billing portal configs ==="
    ^stripe billing_portal configurations list --limit 5
}

# =============================================================================
# Reference data — countries / tax-codes / tax-coverage
# =============================================================================

export def print_countries [] {
    let rows = (open --raw data/reference/countries.jsonl | lines | each {|l| $l | from json})
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

export def check_country [code: string] {
    let code_upper = ($code | str upcase)
    let rows = (open --raw data/reference/countries.jsonl | lines | each {|l| $l | from json})
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

export def print_tax_codes [] {
    let rows = (open --raw data/reference/tax-codes.jsonl | lines | each {|l| $l | from json})
    print $"SMP-eligible tax codes — total (($rows | length))"
    $rows
    | group-by group
    | items {|group, list|
        print $"\n($group) — (($list | length))"
        $list | each {|c| print $"  ($c.code)  ($c.name)" } | ignore
    }
    | ignore
}

export def print_tax_coverage [] {
    let rows = (open --raw data/reference/tax-coverage.jsonl | lines | each {|l| $l | from json})
    let excl = ($rows | where domestic_excluded != null | length)
    print $"SMP tax coverage — total (($rows | length)) countries"
    print $"  ($excl) have domestic-sale exclusions — Stripe does not cover intra-country tax there"
    print ""
    $rows
    | group-by region
    | items {|region, list|
        print $"\n($region) — (($list | length))"
        $list | each {|c|
            let suffix = if $c.domestic_excluded != null {
                $"  ⚠ domestic excluded: ($c.domestic_excluded)"
            } else { "" }
            print $"  ($c.code)($suffix)"
        } | ignore
    }
    | ignore
}

export def check_tax_coverage [code: string] {
    let code_upper = ($code | str upcase)
    let rows = (open --raw data/reference/tax-coverage.jsonl | lines | each {|l| $l | from json})
    let match = ($rows | where code == $code_upper)
    if ($match | length) == 0 {
        print $"  ($code_upper) — NOT in SMP tax-coverage list"
        print "  You can still sell to buyers there if not buyer-blocked, but YOU remain responsible for indirect tax."
        return
    }
    let m = ($match | first)
    print $"  ($code_upper) — Stripe handles tax under SMP [region: ($m.region)]"
    if $m.domestic_excluded != null {
        print $"  ⚠ domestic exception: ($m.domestic_excluded)"
        print "  Stripe DOES handle cross-border sales TO this country."
        print "  Stripe does NOT handle domestic sales FROM a seller in this country (you'd remit yourself)."
    }
}

# =============================================================================
# Project / launch tracking
# =============================================================================

export def print_launches [] {
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

export def print_projects [] {
    let projects = (list_projects)
    print $"registered projects: (($projects | length))"
    for p in $projects {
        let products_path = ([$p.dir "products.jsonl"] | path join)
        let prices_path = ([$p.dir "prices.jsonl"] | path join)
        let n_products = if ($products_path | path exists) {
            open --raw $products_path | lines | length
        } else { 0 }
        let n_prices = if ($prices_path | path exists) {
            open --raw $prices_path | lines | length
        } else { 0 }
        print $"  ✓ ($p.slug)"
        print $"      name:        ($p.name)"
        let domain = ($p | get --optional domain | default "—")
        let repo = ($p | get --optional github_repo | default "—")
        print $"      domain:      ($domain)"
        print $"      repo:        ($repo)"
        print $"      catalog:     ($n_products) products, ($n_prices) prices"
    }
}

# =============================================================================
# Payment methods — read live state of the account's default PM config
# =============================================================================

export def list_payment_methods [] {
    let configs = (^stripe get /v1/payment_method_configurations | complete)
    let body = (try { $configs.stdout | from json | get data } catch { [] })
    let default_cfg = ($body | where {|c| ($c | get --optional is_default) == true} | first)
    if ($default_cfg | is-empty) {
        print "✗ no default payment_method_configuration found"
        return
    }
    print $"default config: ($default_cfg.id)"
    print "enabled methods (preference=on):"
    let entries = ($default_cfg | columns | each {|k|
        let v = ($default_cfg | get $k)
        if ($v | describe | str starts-with "record") {
            let pref = ($v | get --optional display_preference.value | default "")
            let avail = ($v | get --optional available)
            if $pref == "on" {
                {method: $k, available: $avail}
            } else { null }
        } else { null }
    } | compact)
    for e in $entries {
        print $"  ✓ ($e.method) — available=($e.available)"
    }
}

# =============================================================================
# Cross-cutting: data scan + end-to-end flow notes
# =============================================================================

export def print_scan [] {
    let countries = (open --raw data/reference/countries.jsonl | lines | each {|l| $l | from json})
    let smp = ($countries | where {|c| "smp" in $c.seller_modes} | length)
    let payments = ($countries | where {|c| "payments" in $c.seller_modes} | length)
    let paystack = ($countries | where {|c| "paystack" in $c.seller_modes} | length)
    let blocked = ($countries | where {|c| ($c.buyer_blocked_modes | length) > 0} | length)
    let tax = (open --raw data/reference/tax-codes.jsonl | lines | length)
    let projects = (list_projects)
    let total_products = ($projects | each {|p|
        let path = ([$p.dir "products.jsonl"] | path join)
        if ($path | path exists) { open --raw $path | lines | length } else { 0 }
    } | math sum)
    let total_prices = ($projects | each {|p|
        let path = ([$p.dir "prices.jsonl"] | path join)
        if ($path | path exists) { open --raw $path | lines | length } else { 0 }
    } | math sum)
    let launches = (open --raw data/launches.jsonl | lines | length)
    let tax_cov = (open --raw data/reference/tax-coverage.jsonl | lines | length)

    print "data/ summary"
    print "============="
    print "reference/  (Stripe-sourced — hand-edit after eyeballing upstream)"
    print $"  countries.jsonl     (($countries | length)) rows — sellers: smp=($smp) payments=($payments) paystack=($paystack)  blocked-buyers=($blocked)"
    print $"  tax-codes.jsonl     ($tax) rows — SMP-eligible product tax codes"
    print $"  tax-coverage.jsonl  ($tax_cov) rows — buyer countries Stripe handles tax for under SMP"
    print ""
    print "projects/   (consumer apps — each with its own catalog)"
    for p in $projects {
        let products_path = ([$p.dir "products.jsonl"] | path join)
        let prices_path = ([$p.dir "prices.jsonl"] | path join)
        let np = if ($products_path | path exists) { open --raw $products_path | lines | length } else { 0 }
        let nx = if ($prices_path | path exists) { open --raw $prices_path | lines | length } else { 0 }
        print $"  ($p.slug)/        ($np) products, ($nx) prices"
    }
    print ""
    print "ours  (hand-curated)"
    print $"  launches.jsonl      ($launches) rows — per project × jurisdiction × mode"
}

export def print_flow [] {
    print "stripe-connectrpc end-to-end flow — http-nu + xs runtime"
    print "================================================="
    print ""
    print "Prereq: Stripe account is registered in one of the 38 SMP seller countries."
    print "        Run `mise run data:countries` to check the list."
    print ""
    print "1. Fresh-clone bootstrap"
    print "   mise run tools:install     # nushell + stripe-cli + xs + http-nu + pitchfork"
    print "   mise run tools:onboard     # interactive: Stripe creds into keychain"
    print "   mise run tools:verify      # tools + keychain entries"
    print ""
    print "2. Confirm Stripe account"
    print "   mise run stripe:account"
    print "     ▸ expect: mode=TEST, country=<supported>, charges_enabled=true"
    print ""
    print "3. Seed Stripe-side state (idempotent — safe to re-run)"
    print "   mise run stripe:bootstrap"
    print "     ▸ products + prices + portal + payment-methods + webhook"
    print "   mise run stripe:status"
    print "     ▸ snapshot of what landed"
    print ""
    print "4. Sandbox payment loop"
    print "   mise run daemons:up       # pitchfork starts http-nu + stripe listen + dispatcher"
    print "        copy printed whsec_… into keychain:"
    print "          fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_…'"
    print "          mise run daemons:restart-http"
    print "   mise run test:checkout"
    print "        ▸ prints checkout URL; open in browser"
    print "        ▸ pay with 4242 4242 4242 4242 (any future expiry/CVC)"
    print "        ▸ mise run xs:cat shows ~12 events as stripe.webhook.received + .verified"
    print "        ▸ dispatcher signs+POSTs each to each project's consumer.webhook_url"
    print ""
    print "5. Going live (later)"
    print "   - Activate the Stripe account (KYC, bank, tax id)"
    print "   - Enable Managed Payments in Dashboard → Settings → Payments → Managed Payments"
    print "   - Swap keychain to live: fnox set -p keychain SMP_STRIPE_SECRET_KEY 'sk_live_…'"
    print "   - Deploy http-nu+xs to a VPS (or cf:* for the alt runtime)"
    print "   - Run `mise run stripe:apply-webhook` against the deployed URL"
    print "   - Real-card test via mise run test:checkout"
}
