#!/usr/bin/env nu
# Verb-first dispatcher for the Stripe bootstrap layer.
#
#   nu scripts/bootstrap.nu show <thing>      # read-only display
#   nu scripts/bootstrap.nu apply <thing>     # mutate Stripe (idempotent)
#   nu scripts/bootstrap.nu test <flow>       # one-off test resources
#   nu scripts/bootstrap.nu teardown <slug>   # archive per-project state
#
# Implementations live in scripts/bootstrap/{show,apply,test,teardown,lib}.nu.
# This file is intentionally thin — the verb match is the entire surface.

use bootstrap/lib.nu *
use bootstrap/show.nu *
use bootstrap/apply.nu *
use bootstrap/test.nu *
use bootstrap/teardown.nu *

def main [
    verb: string = "show"
    sub?: string
    arg?: string
] {
    # mise's usage spec feeds empty strings (not null) for omitted optional
    # args. normalize_arg collapses that to null so `| default` works.
    let arg = (normalize_arg $arg)
    match $verb {
        "show" => {
            let s = ($sub | default "status")
            match $s {
                "status"           => { show_status }
                "account"          => { show_account }
                "countries"        => { print_countries }
                "country"          => { check_country ($arg | default "TH") }
                "tax-codes"        => { print_tax_codes }
                "tax-coverage"     => { print_tax_coverage }
                "tax"              => { check_tax_coverage ($arg | default "TH") }
                "launches"         => { print_launches }
                "projects"         => { print_projects }
                "payment-methods"  => { list_payment_methods }
                "scan"             => { print_scan }
                "flow"             => { print_flow }
                _ => {
                    print $"show: unknown subcommand '($s)'"
                    print "  show:  account | status | countries | country <ISO> | tax-codes | tax-coverage | tax <ISO>"
                    print "         launches | projects | payment-methods | scan | flow"
                    exit 1
                }
            }
        }
        "apply" => {
            let s = ($sub | default "all")
            match $s {
                "products"         => { seed_products }
                "prices"           => { seed_prices }
                "portal"           => { configure_portal }
                "webhook"          => { register_webhook }
                "payment-methods"  => { sync_payment_methods }
                "all"              => { seed_products ; seed_prices ; configure_portal ; sync_payment_methods ; register_webhook }
                _ => {
                    print $"apply: unknown subcommand '($s)'"
                    print "  apply: products | prices | portal | webhook | payment-methods | all"
                    exit 1
                }
            }
        }
        "test" => {
            let s = ($sub | default "customer")
            match $s {
                "customer"           => { test_customer }
                "checkout"           => { test_checkout ($arg | default "sports_coach_monthly_usd") "smp" }
                "checkout-payments"  => { test_checkout ($arg | default "sports_coach_monthly_usd") "payments" }
                "checkout-thai"      => { test_checkout_thai_buyer }
                "rpc-checkout"       => { ^nu scripts/test-rpc-checkout.nu ($arg | default "sports_coach_monthly_usd") }
                _ => {
                    print $"test: unknown subcommand '($s)'"
                    print "  test:  customer | checkout [lookup_key] | checkout-payments [lookup_key] | checkout-thai | rpc-checkout [lookup_key]"
                    exit 1
                }
            }
        }
        "teardown" => {
            if ($sub | is-empty) {
                print "✗ teardown requires a project slug — usage: nu bootstrap.nu teardown <slug>"
                exit 1
            }
            teardown_project $sub
        }
        _ => {
            print $"unknown verb: ($verb)"
            print "  verbs:  show | apply | test | teardown"
            exit 1
        }
    }
}
