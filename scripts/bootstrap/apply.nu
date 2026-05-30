#!/usr/bin/env nu
# apply.nu — mutate Stripe state from JSONL. Every operation is idempotent.
# Re-running brings the world to the declared state without duplicating.
#
# Surface (via bootstrap.nu dispatcher):
#   apply -- products | prices | portal | webhook | payment-methods | all

use lib.nu *

# =============================================================================
# Products — seed from data/projects/<slug>/products.jsonl with metadata.project
# =============================================================================

export def seed_products [] {
    let projects = (list_projects)
    print $"seeding products across (($projects | length)) project dirs"
    for proj in $projects {
        seed_products_for_project $proj
    }
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

# =============================================================================
# Prices — seed from data/projects/<slug>/prices.jsonl by lookup_key
# =============================================================================

export def seed_prices [] {
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

# =============================================================================
# Customer Portal config
# =============================================================================

export def configure_portal [] {
    # Skip if a default portal config already exists.
    let listing = (^stripe billing_portal configurations list --is-default=true --limit 1 | complete)
    let count = if $listing.exit_code == 0 {
        try { ($listing.stdout | from json | get data | length) } catch { 0 }
    } else { 0 }
    if $count > 0 {
        print "  ✓ default Customer Portal already configured"
        return
    }

    print "configuring default Stripe Customer Portal from data/config/portal-config.jsonl ..."
    # Declarative config: each line is one form-encoded -d arg. Edit the JSONL
    # to add/remove features; the next configure_portal run picks it up.
    let pairs = (open --raw data/config/portal-config.jsonl | lines | each {|l| $l | from json})
    let args = ($pairs | each {|p| ["-d" $"($p.k)=($p.v)"]} | flatten)
    let r = (^stripe post /v1/billing_portal/configurations ...$args | complete)
    if $r.exit_code == 0 {
        print "  ✓ Customer Portal configured"
    } else {
        print $"  ✗ portal config failed: ($r.stdout)"
        exit 1
    }
}

# =============================================================================
# Webhook endpoint registration
# =============================================================================

export def register_webhook [] {
    let url_r = (do { fnox get SMP_SERVICE_URL } | complete)
    if $url_r.exit_code != 0 or (($url_r.stdout | str trim | str length) == 0) {
        # Warn-and-skip rather than fail: apply -- all should succeed when the
        # service hasn't been deployed yet (Phase 4 work). The webhook step
        # only matters once SMP_SERVICE_URL is populated.
        print "  ⊘ webhook step skipped — SMP_SERVICE_URL not in keychain (Phase 4)"
        print "    Deploy http-nu+xs to a VPS, then:"
        print "      fnox set -p keychain SMP_SERVICE_URL 'https://smp.example.com'"
        print "      mise run stripe:apply-webhook"
        return
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
    # Event list is declarative — sourced from data/config/webhook-events.jsonl
    # so it can be edited without touching this script.
    let events = (open --raw data/config/webhook-events.jsonl | lines | each {|l| $l | from json | get event})
    print $"  subscribing to (($events | length)) event types from config/webhook-events.jsonl"
    let event_args = ($events | each {|e| ["-e" $e]} | flatten)

    let r = (^stripe webhook_endpoints create --url $endpoint ...$event_args | complete)
    if $r.exit_code == 0 {
        print "✓ created."
        print "  Capture `whsec_...` from output above and run:"
        print "    fnox set -p keychain SMP_STRIPE_WEBHOOK_SECRET 'whsec_...'"
        print "    mise run daemons:restart-http"
    } else {
        print "✗ stripe webhook_endpoints create failed:"
        print $r.stdout
        exit 1
    }
}

# =============================================================================
# Payment-method configuration reconcile
# =============================================================================

# Reconcile data/config/payment-methods.jsonl → Stripe account.
# For each row with preference="on" or "off", set the matching value on the
# default payment_method_configuration. Skip "unavailable" entries (those
# are documentation — methods Stripe blocks for our merchant country).
#
# Stripe routes methods per buyer automatically when checkout sessions use
# automatic_payment_methods=true. This sync just controls the pool — which
# methods CAN appear at all. Per-country surfacing is Stripe's job.
export def sync_payment_methods [] {
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

    let want = (open --raw data/config/payment-methods.jsonl | lines | each {|l| $l | from json})
    print $"  ($want | length) methods declared in config/payment-methods.jsonl"

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
