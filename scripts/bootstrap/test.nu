#!/usr/bin/env nu
# test.nu — sandbox HIL flows. Creates test resources in Stripe.
#
# Surface (via bootstrap.nu dispatcher):
#   test -- customer
#   test -- checkout [lookup_key]
#   test -- checkout-payments [lookup_key]
#   test -- checkout-thai

use lib.nu *

# =============================================================================
# Test customer
# =============================================================================

export def test_customer [] {
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

# =============================================================================
# Checkout sessions — SMP mode and Stripe Payments mode
# =============================================================================

export def test_checkout [lookup_key: string, mode: string] {
    # Resolve price by lookup_key.
    let listing = (^stripe prices list --lookup-keys $lookup_key --limit 1 | complete)
    if $listing.exit_code != 0 {
        print $"✗ failed to list prices: ($listing.stdout)"
        exit 1
    }
    let prices = ($listing.stdout | from json | get data)
    if ($prices | length) == 0 {
        print $"✗ no price found for lookup_key=($lookup_key)"
        print "  Run: mise run stripe:apply-prices"
        exit 1
    }
    let price_id = ($prices | first | get id)
    print $"using price ($price_id) for lookup_key ($lookup_key) — mode=($mode)"

    # SMP requires Stripe API version 2025-03-31.basil or later. The account
    # default is currently older, so we pin per-request via header. Version
    # sourced from data/config/stripe-config.jsonl.
    let api_version = (stripe_config "api_version")
    mut args = [
        "post" "/v1/checkout/sessions"
        "--stripe-version" $api_version
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
    print "Make sure `mise run daemons:up` has http-nu + stripe-listen running so the"
    print "post-payment webhook reaches smp."
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
export def test_checkout_thai_buyer [] {
    print "creating Checkout Session for a THAI BUYER on the AU-registered SMP account..."
    print "  — PromptPay isn't available to AU merchants (Thailand-merchant-only method)"
    print "  — Thai buyer's experience: card / Apple Pay / Link, page in Thai"
    print "  — SMP handles Thai 7% VAT automatically once buyer enters TH address"
    print ""

    # Resolve the same price the SMP HIL used.
    let listing = (^stripe prices list --lookup-keys sports_coach_monthly_usd --limit 1 | complete)
    let prices = (try { $listing.stdout | from json | get data } catch { [] })
    if ($prices | length) == 0 {
        print "✗ no price for sports_coach_monthly_usd — run mise run stripe:apply-prices"
        exit 1
    }
    let price_id = ($prices | first | get id)

    let api_version = (stripe_config "api_version")
    let r = (^stripe post /v1/checkout/sessions
        --stripe-version $api_version
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
    print "  6. xs records the full event fan-out (checkout.session.completed, etc)."
}
