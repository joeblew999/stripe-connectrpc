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
        "teardown"      => {
            if ($arg | is-empty) {
                print "✗ teardown requires a project slug: nu scripts/bootstrap.nu teardown <slug>"
                exit 1
            }
            teardown_project $arg
        }

        # Info
        "status"        => { show_status }
        "account"       => { show_account }
        "countries"     => { print_countries }
        "tax-codes"     => { print_tax_codes }
        "tax-coverage"  => { print_tax_coverage }
        "launches"      => { print_launches }
        "projects"      => { print_projects }
        "scan"          => { print_scan }
        "flow"          => { print_flow }

        # Test loop
        "test-customer"          => { test_customer }
        "test-checkout"          => { test_checkout ($arg | default "sports_coach_monthly_usd") "smp" }
        "test-checkout-payments" => { test_checkout ($arg | default "sports_coach_monthly_usd") "payments" }
        "test-checkout-thai"     => { test_checkout_thai_buyer }
        "payment-methods"        => { list_payment_methods }
        "sync-payment-methods"   => { sync_payment_methods }
        "check-country"          => { check_country ($arg | default "TH") }
        "check-tax"              => { check_tax_coverage ($arg | default "TH") }

        _ => {
            print $"unknown subcommand: ($cmd)"
            print ""
            print "setup:    products | prices | webhook | portal | all"
            print "teardown: teardown <slug>   (archives products+prices for one project)"
            print "info:   status | account | countries | tax-codes | tax-coverage | launches | projects | scan | flow"
            print "        check-country <ISO>"
            print "        check-tax <ISO>           (is buyer country covered by SMP tax?)"
            print "test:   test-customer"
            print "        test-checkout          [lookup_key]   (SMP mode)"
            print "        test-checkout-payments [lookup_key]   (Stripe Payments — we are MoR)"
            print "        test-checkout-thai                    (Thai buyer; SMP w/ locale=th + address required)"
            print "info:   payment-methods                       (what Stripe payment methods are enabled on this account)"
            exit 1
        }
    }
}

# =============================================================================
# Setup
# =============================================================================

# Iterate every data/projects/<slug>/ directory and seed its products with
# metadata.project=<slug>. If a product already exists in Stripe, ensure
# the metadata is set (backfill safely). Re-running is always idempotent.
def seed_products [] {
    let projects = (list_projects)
    print $"seeding products across (($projects | length)) project dirs"
    for proj in $projects {
        seed_products_for_project $proj
    }
}

def list_projects [] {
    if not ("data/projects" | path exists) {
        return []
    }
    ls data/projects | where type == "dir" | get name | each {|dir|
        let json_path = ([$dir "project.json"] | path join)
        if ($json_path | path exists) {
            let p = (open --raw $json_path | from json)
            $p | merge { dir: $dir }
        } else {
            null
        }
    } | compact
}

def seed_products_for_project [project: record] {
    let products_path = ([$project.dir "products.jsonl"] | path join)
    if not ($products_path | path exists) {
        print $"  · ($project.slug) — no products.jsonl, skipping"
        return
    }
    let rows = (open --raw $products_path | lines | each {|l| $l | from json})
    print $"  project ($project.slug):  (($rows | length)) products"
    for p in $rows {
        let exists = (^stripe products retrieve $p.id | complete)
        let exists_body = (try { $exists.stdout | from json } catch { {} })
        let already = (($exists_body | get --optional id) == $p.id)

        if $already {
            # Always ensure metadata.project is set AND active=true. This makes
            # bootstrap the inverse of teardown — re-running brings archived
            # products back. Idempotent: same result whether already-good or
            # being re-activated after teardown.
            let current = ($exists_body | get --optional metadata.project | default "")
            let active = ($exists_body | get --optional active | default true)
            if $current == $project.slug and $active {
                print $"    ✓ ($p.id) — already tagged + active"
                continue
            }
            let upd = (^stripe post $"/v1/products/($p.id)"
                -d $"metadata[project]=($project.slug)"
                -d "active=true"
                | complete)
            let upd_body = (try { $upd.stdout | from json } catch { {} })
            if (($upd_body | get --optional id) == $p.id) {
                let was_inactive = if not $active { " (re-activated)" } else { "" }
                let backfilled = if $current != $project.slug { " (metadata backfilled)" } else { "" }
                print $"    ✓ ($p.id) — ensured tag + active($was_inactive)($backfilled)"
            } else {
                print $"    ✗ ($p.id) — failed to update"
            }
            continue
        }

        let r = (^stripe post /v1/products
            -d $"id=($p.id)"
            -d $"name=($p.name)"
            -d $"description=($p.description)"
            -d $"tax_code=($p.tax_code)"
            -d $"metadata[project]=($project.slug)"
            | complete)
        let resp = (try { $r.stdout | from json } catch { {} })
        if (($resp | get --optional id) == $p.id) {
            print $"    ✓ created ($p.id)"
        } else {
            let msg = ($resp | get --optional error.message | default $r.stdout)
            print $"    ✗ ($p.id) failed: ($msg)"
        }
    }
}

def seed_prices [] {
    let projects = (list_projects)
    print $"seeding prices across (($projects | length)) project dirs"
    for proj in $projects {
        seed_prices_for_project $proj
    }
}

def seed_prices_for_project [project: record] {
    let prices_path = ([$project.dir "prices.jsonl"] | path join)
    if not ($prices_path | path exists) {
        print $"  · ($project.slug) — no prices.jsonl, skipping"
        return
    }
    let rows = (open --raw $prices_path | lines | each {|l| $l | from json})
    print $"  project ($project.slug):  (($rows | length)) prices"
    for p in $rows {
        let listing = (^stripe prices list --lookup-keys $p.lookup_key --limit 1 | complete)
        let listed = (try { $listing.stdout | from json | get data } catch { [] })
        if ($listed | length) > 0 {
            let existing = ($listed | first)
            let current = ($existing | get --optional metadata.project | default "")
            let active = ($existing | get --optional active | default true)
            if $current == $project.slug and $active {
                print $"    ✓ ($p.lookup_key) — already tagged + active"
                continue
            }
            let upd = (^stripe post $"/v1/prices/($existing.id)"
                -d $"metadata[project]=($project.slug)"
                -d "active=true"
                | complete)
            let upd_body = (try { $upd.stdout | from json } catch { {} })
            if (($upd_body | get --optional id) == $existing.id) {
                let was_inactive = if not $active { " (re-activated)" } else { "" }
                print $"    ✓ ($p.lookup_key) — ensured tag + active($was_inactive)"
            } else {
                print $"    ✗ ($p.lookup_key) — failed to update"
            }
            continue
        }
        let r = (^stripe post /v1/prices
            -d $"product=($p.product)"
            -d $"unit_amount=($p.unit_amount)"
            -d $"currency=($p.currency)"
            -d $"recurring[interval]=($p.interval)"
            -d $"lookup_key=($p.lookup_key)"
            -d $"metadata[project]=($project.slug)"
            | complete)
        let resp = (try { $r.stdout | from json } catch { {} })
        if ((($resp | get --optional id) | default "") | str starts-with "price_") {
            print $"    ✓ created ($p.lookup_key) → (($resp.id))"
        } else {
            let msg = ($resp | get --optional error.message | default $r.stdout)
            print $"    ✗ ($p.lookup_key) failed: ($msg)"
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

# Tear down one project's Stripe-side state. Archives products + prices
# (Stripe can't delete them, only set active=false). Cross-leak protection:
# we ONLY touch objects whose metadata.project matches the requested slug.
# Combined with "we only iterate THIS project's products.jsonl", an object
# tagged for a different project is double-skipped.
def teardown_project [slug: string] {
    let proj_dir = ([("data/projects") $slug] | path join)
    let proj_json = ([$proj_dir "project.json"] | path join)
    if not ($proj_json | path exists) {
        print $"✗ no project at ($proj_dir)"
        exit 1
    }
    let project = (open --raw $proj_json | from json)
    if $project.slug != $slug {
        print $"✗ project.slug='($project.slug)' does not match directory name '($slug)'"
        exit 1
    }
    print $"=== teardown ($project.slug) — ($project.name) ==="

    # Deactivate prices first (more conservative ordering — even though Stripe
    # allows archiving products with active prices, prices-then-products is
    # the cleaner sequence for state machines).
    let prices_path = ([$proj_dir "prices.jsonl"] | path join)
    if ($prices_path | path exists) {
        let rows = (open --raw $prices_path | lines | each {|l| $l | from json})
        print $"  ($rows | length) prices declared in project"
        for p in $rows {
            let listing = (^stripe prices list --lookup-keys $p.lookup_key --limit 10 | complete)
            let listed = (try { $listing.stdout | from json | get data } catch { [] })
            if ($listed | length) == 0 {
                print $"    · ($p.lookup_key) — not in Stripe, skipping"
                continue
            }
            for existing in $listed {
                let proj_meta = ($existing | get --optional metadata.project | default "")
                # Cross-leak guard: never touch a price tagged for another project.
                if $proj_meta != $project.slug {
                    print $"    ⚠ SKIP ($existing.id) — metadata.project='($proj_meta)' != '($project.slug)'"
                    continue
                }
                let r = (^stripe post $"/v1/prices/($existing.id)" -d "active=false" | complete)
                let body = (try { $r.stdout | from json } catch { {} })
                if (($body | get --optional active) == false) {
                    print $"    ✓ deactivated ($existing.id) [($p.lookup_key)]"
                } else {
                    print $"    ✗ failed to deactivate ($existing.id)"
                }
            }
        }
    }

    let products_path = ([$proj_dir "products.jsonl"] | path join)
    if ($products_path | path exists) {
        let rows = (open --raw $products_path | lines | each {|l| $l | from json})
        print $"  ($rows | length) products declared in project"
        for p in $rows {
            let retrieve = (^stripe products retrieve $p.id | complete)
            let body = (try { $retrieve.stdout | from json } catch { {} })
            if (($body | get --optional id) != $p.id) {
                print $"    · ($p.id) — not in Stripe, skipping"
                continue
            }
            let proj_meta = ($body | get --optional metadata.project | default "")
            if $proj_meta != $project.slug {
                print $"    ⚠ SKIP ($p.id) — metadata.project='($proj_meta)' != '($project.slug)'"
                continue
            }
            let r = (^stripe post $"/v1/products/($p.id)" -d "active=false" | complete)
            let upd_body = (try { $r.stdout | from json } catch { {} })
            if (($upd_body | get --optional active) == false) {
                print $"    ✓ archived ($p.id)"
            } else {
                print $"    ✗ failed to archive ($p.id)"
            }
        }
    }

    print ""
    print "  Done. To restore: mise run bootstrap:products — re-activates archived items."
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

# Show what modes are available for a given country code.
def check_country [code: string] {
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

def print_tax_codes [] {
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

def print_scan [] {
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
    print "reference/  (Stripe-sourced — refresh via `mise run data:check`)"
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

def print_tax_coverage [] {
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

# Check whether a given buyer-country is covered by SMP tax (Stripe handles it).
def check_tax_coverage [code: string] {
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

def print_projects [] {
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

# Thai buyer on the AU-registered SMP account.
#
# The reality, verified via the Payment Method Configurations API on this
# account: PromptPay is NOT available to an AU-registered merchant — it is
# Thailand-merchant-only. The AU account's enabled methods for any buyer
# (Thai or otherwise) are: card, Apple Pay, Link.
#
# So this task simulates exactly what a Thai buyer sees: the same SMP
# Checkout Session you'd give any global buyer, with:
#   - locale=th             (page rendered in Thai)
#   - billing_address_collection=required  (forces the address form so the
#     buyer can pick Thailand as their country — SMP then applies 7% Thai
#     VAT under merchant-of-record)
#
# To accept PromptPay, the seller account would need to be Thailand-
# registered — which means LOSING SMP (TH isn't on SMP's seller list), so
# the operation drops to Stripe Payments mode where we become MoR.
def test_checkout_thai_buyer [] {
    print "creating Checkout Session for a THAI BUYER on the AU-registered SMP account..."
    print "  — PromptPay isn't available to AU merchants (Thailand-merchant-only method)"
    print "  — Thai buyer's experience: card / Apple Pay / Link, page in Thai"
    print "  — SMP handles Thai 7% VAT automatically once buyer enters TH address"
    print ""

    # Resolve the same price the SMP HIL used.
    let listing = (^stripe prices list --lookup-keys sports_coach_monthly_usd --limit 1 | complete)
    let prices = (try { $listing.stdout | from json | get data } catch { [] })
    if ($prices | length) == 0 {
        print "✗ no price for sports_coach_monthly_usd — run mise run bootstrap:prices"
        exit 1
    }
    let price_id = ($prices | first | get id)

    # No payment_method_types — Stripe routes methods per buyer automatically.
    let r = (^stripe post /v1/checkout/sessions
        --stripe-version "2025-03-31.basil"
        -d "mode=subscription"
        -d $"line_items[0][price]=($price_id)"
        -d "line_items[0][quantity]=1"
        -d "managed_payments[enabled]=true"
        -d "locale=th"
        -d "billing_address_collection=required"
        -d "success_url=http://localhost:8787/health?session={CHECKOUT_SESSION_ID}"
        -d "cancel_url=http://localhost:8787/health?canceled=1"
        -d "metadata[project]=remy-sport"
        -d "metadata[buyer_region]=thailand"
        -d "metadata[scenario]=thai-buyer-au-merchant"
        | complete)

    let body = (try { $r.stdout | from json } catch { {} })
    let api_err = ($body | get --optional error)
    if $api_err != null {
        print $"✗ Stripe API error: (($api_err.message))"
        exit 1
    }
    let session_id = ($body | get --optional id | default "")
    let session_url = ($body | get --optional url | default "")
    print $"  ✓ session ($session_id)"
    print ""
    print "Open this URL in your browser — page renders in Thai:"
    print $"  ($session_url)"
    print ""
    print "Steps:"
    print "  1. The Checkout page is in Thai (locale=th)."
    print "  2. Available payment methods: Card / Apple Pay / Link"
    print "     (PromptPay is not offered — AU merchant cannot accept it.)"
    print "  3. In the address form, choose Country = Thailand."
    print "  4. Pay with test card 4242 4242 4242 4242."
    print "  5. SMP applies 7% Thai VAT — invoice shows base + tax breakdown."
    print "  6. Worker logs the full event fan-out (checkout.session.completed, etc)."
}

# Reconcile data/reference/payment-methods.jsonl → Stripe account.
# For each row with preference="on" or "off", set the matching value on the
# default payment_method_configuration. Skip "unavailable" entries (those
# are documentation — methods Stripe blocks for our merchant country).
#
# Stripe routes methods per buyer automatically when checkout sessions use
# automatic_payment_methods=true. This sync just controls the pool — which
# methods CAN appear at all. Per-country surfacing is Stripe's job.
def sync_payment_methods [] {
    let configs = (^stripe get /v1/payment_method_configurations | complete)
    let body = (try { $configs.stdout | from json | get data } catch { [] })
    let default_cfg = ($body | where {|c| ($c | get --optional is_default) == true and ($c | get --optional parent) != null} | first)
    if ($default_cfg | is-empty) {
        # Fall back to any default config without parent.
        let alt = ($body | where {|c| ($c | get --optional is_default) == true} | first)
        if ($alt | is-empty) {
            print "✗ no default payment_method_configuration on this account"
            exit 1
        }
    }
    let cfg_id = ($default_cfg.id)
    print $"reconciling against payment_method_configuration ($cfg_id) ..."

    let want = (open --raw data/reference/payment-methods.jsonl | lines | each {|l| $l | from json})
    print $"  ($want | length) methods declared in reference/payment-methods.jsonl"

    for m in $want {
        if $m.preference == "unavailable" {
            print $"  · ($m.method) — skipped, documented as not available to this merchant"
            continue
        }
        let r = (^stripe post $"/v1/payment_method_configurations/($cfg_id)"
            -d $"($m.method)[display_preference][preference]=($m.preference)"
            | complete)
        let resp = (try { $r.stdout | from json } catch { {} })
        let err = ($resp | get --optional error)
        if $err != null {
            let msg = ($err | get --optional message | default "")
            print $"  · ($m.method) — skipped: ($msg)"
            continue
        }
        let new_pref = ($resp | get $m.method | get --optional display_preference.value | default "?")
        print $"  ✓ ($m.method) → ($new_pref)"
    }

    print ""
    print "Checkout Sessions created without payment_method_types will auto-select"
    print "from this pool per buyer location and currency — Stripe owns the routing."
}

# Print the enabled-method snapshot from the live payment_method_configuration
# (queries Stripe directly, not a local file — this IS the source of truth).
def list_payment_methods [] {
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

    # SMP requires Stripe API version 2025-03-31.basil or later. The account
    # default is currently 2024-10-28.acacia, so we pin per-request via header.
    mut args = [
        "post" "/v1/checkout/sessions"
        "--stripe-version" "2025-03-31.basil"
        "-d" "mode=subscription"
        "-d" $"line_items[0][price]=($price_id)"
        "-d" "line_items[0][quantity]=1"
        "-d" "success_url=http://localhost:8787/health?session={CHECKOUT_SESSION_ID}"
        "-d" "cancel_url=http://localhost:8787/health?canceled=1"
    ]
    # Don't pass `payment_method_types=[…]` at all. When omitted, Stripe
    # auto-selects from the account's configured payment-method pool based
    # on the buyer's currency, location, and the merchant country. This is
    # the canonical way to get per-country routing — Stripe's own engine.
    # `automatic_payment_methods` is a PaymentIntent param, not a Checkout
    # Session one, so we don't pass it here.
    if $mode == "smp" {
        $args = ($args | append ["-d" "managed_payments[enabled]=true"])
        print "creating Checkout Session — SMP mode; Stripe auto-selects payment methods per buyer ..."
    } else {
        # Plain Stripe Payments mode — we are MoR. Enable Stripe Tax so taxes
        # are calculated; we remain responsible for remittance.
        $args = ($args | append ["-d" "automatic_tax[enabled]=true"])
        print "creating Checkout Session — Stripe Payments mode (we are MoR); automatic_tax on ..."
    }

    let r = (^stripe ...$args | complete)
    let body = (try { $r.stdout | from json } catch { {} })
    let api_err = ($body | get --optional error)
    if $api_err != null {
        print $"✗ Stripe API error: (($api_err.message))"
        let code = ($api_err | get --optional code | default "")
        if ($code | str length) > 0 {
            print $"  code: ($code)"
        }
        print ""
        if $mode == "smp" {
            print "  If 'managed_payments not enabled' — Stripe Managed Payments isn't"
            print "  activated on the account yet. Either enable it in the dashboard"
            print "  (mise run open:stripe-smp) or use the Payments-mode fallback:"
            print "    mise run test:checkout-payments"
        }
        exit 1
    }
    let session_id = ($body | get --optional id | default "")
    let session_url = ($body | get --optional url | default "")
    if ($session_url | str length) == 0 {
        print $"✗ unexpected response — no `url` field:"
        print $r.stdout
        exit 1
    }
    print $"  ✓ session ($session_id)"
    print ""
    print "Open this URL in your browser:"
    print $"  ($session_url)"
    print ""
    print "Test card: 4242 4242 4242 4242 — any future expiry, any CVC, any zip."
    print "Make sure `mise run worker:dev` AND `mise run stripe:listen` are running"
    print "so the post-payment webhook reaches smp."
}
