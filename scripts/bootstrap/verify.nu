#!/usr/bin/env nu
# verify.nu — confirm Stripe-side state matches every JSONL declaration.
#
# Used by `mise run stripe:verify-state` (and folded into `tools:verify-all`).
# Run after `stripe:bootstrap` or `stripe:teardown` to prove the round-trip
# left Stripe in the state you expected.
#
# For each project in data/projects/*/:
#   - Every product in products.jsonl exists in Stripe with active=true AND
#     metadata.project == <slug>
#   - Every price in prices.jsonl is reachable by lookup_key, active=true,
#     same metadata tag
#
# Exits 0 if everything matches, 1 otherwise (so tools:verify-all catches drift).

use lib.nu *

export def verify_stripe_state [] {
    let expected_products = (list_projects | each {|p|
        let path = ([$p.dir "products.jsonl"] | path join)
        if not ($path | path exists) { return [] }
        open --raw $path | lines | each {|l| $l | from json | insert slug $p.slug}
    } | flatten)

    let expected_prices = (list_projects | each {|p|
        let path = ([$p.dir "prices.jsonl"] | path join)
        if not ($path | path exists) { return [] }
        open --raw $path | lines | each {|l| $l | from json | insert slug $p.slug}
    } | flatten)

    print "stripe state verification"
    print "========================="
    print $"  expected: (($expected_products | length)) products + (($expected_prices | length)) prices declared across data/projects/"
    print ""

    mut prod_ok = 0
    mut prod_bad = 0
    print "products:"
    for p in $expected_products {
        let r = (^stripe products retrieve $p.id | complete)
        let body = (try { $r.stdout | from json } catch { {} })
        let active = ($body | get --optional active | default null)
        let proj = ($body | get --optional metadata.project | default "")
        if $active == true and $proj == $p.slug {
            print $"  ✓ ($p.id)  active=true  project=($proj)"
            $prod_ok = $prod_ok + 1
        } else {
            print $"  ✗ ($p.id)  active=($active)  project='($proj)'  (expected slug='($p.slug)')"
            $prod_bad = $prod_bad + 1
        }
    }

    print ""
    mut price_ok = 0
    mut price_bad = 0
    print "prices:"
    for p in $expected_prices {
        let r = (^stripe prices list --lookup-keys $p.lookup_key --limit 1 | complete)
        let body = (try { $r.stdout | from json | get data | first } catch { {} })
        let active = ($body | get --optional active | default null)
        let proj = ($body | get --optional metadata.project | default "")
        if $active == true and $proj == $p.slug {
            print $"  ✓ ($p.lookup_key)  active=true  project=($proj)"
            $price_ok = $price_ok + 1
        } else {
            print $"  ✗ ($p.lookup_key)  active=($active)  project='($proj)'  (expected slug='($p.slug)')"
            $price_bad = $price_bad + 1
        }
    }

    print ""
    print "summary"
    print "-------"
    print $"  products: ($prod_ok) ok, ($prod_bad) bad"
    print $"  prices:   ($price_ok) ok, ($price_bad) bad"

    if $prod_bad > 0 or $price_bad > 0 {
        print ""
        print "state drift detected — run `mise run stripe:bootstrap` to reconcile"
        exit 1
    }

    print ""
    print "✓ Stripe state matches data/ declarations"
}
