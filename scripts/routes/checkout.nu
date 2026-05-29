#!/usr/bin/env nu
# POST /v1/checkout — consumer-RPC: create a Stripe Checkout Session on a
# consumer's behalf. Closes the loop opened by /v1/webhook + dispatcher.
#
# Surface:
#   POST /v1/checkout
#   Authorization: Bearer <consumer-token>
#   Content-Type: application/json
#   {
#     "project":        "remy-sport",
#     "lookup_key":     "sports_coach_monthly_usd",
#     "success_url":    "https://app/_/return?session={CHECKOUT_SESSION_ID}",
#     "cancel_url":     "https://app/_/canceled",
#     "customer_email": "user@example.com",   (optional)
#     "metadata":       { "user_id": "u123" } (optional, passed through)
#   }
#
# Response 201:
#   {"session_id":"cs_test_...","url":"https://checkout.stripe.com/c/pay/..."}
#
# xs events appended:
#   stripe.intent.session.create   post-auth, pre-Stripe (audit log)
#   stripe.api.session.created     Stripe responded 2xx
#   stripe.api.session.failed      Stripe API error / smp couldn't reach Stripe

use http-nu/router *

# ----------------------------------------------------------------------------
# Helpers (private to this module)
# ----------------------------------------------------------------------------

# Parse "Authorization: Bearer <token>". Returns "" if absent / malformed.
def parse_bearer [auth_header: string] {
    if ($auth_header | is-empty) { return "" }
    let parts = ($auth_header | split row " " | each {|p| $p | str trim} | where ($it | str length) > 0)
    if ($parts | length) != 2 { return "" }
    if (($parts | first) | str downcase) != "bearer" { return "" }
    $parts | last
}

# Look up a keychain entry via fnox. Returns "" if not found.
def get_secret [name: string] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

# Load data/projects/<slug>/project.json. Returns null if missing OR no consumer block.
def load_project_with_consumer [slug: string] {
    let json_path = ([("data/projects") $slug "project.json"] | path join)
    if not ($json_path | path exists) { return null }
    let p = (open --raw $json_path | from json)
    if (($p | get --optional consumer) | is-empty) { return null }
    $p
}

# Read pinned Stripe API version from data/config/stripe-config.jsonl.
def get_api_version [] {
    let rows = (try { open --raw data/config/stripe-config.jsonl | lines | each {|l| $l | from json} } catch { [] })
    let m = ($rows | where key == "api_version" | first)
    if ($m | is-empty) { "" } else { $m.value }
}

# Constant-time-ish string equality (both inputs are hex, so length+XOR is plenty).
def secrets_equal [a: string, b: string] {
    if ($a | str length) != ($b | str length) { return false }
    mut diff = 0
    let len = ($a | str length)
    for i in 0..<$len {
        let x = ($a | str substring $i..($i + 1))
        let y = ($b | str substring $i..($i + 1))
        if $x != $y { $diff = ($diff + 1) }
    }
    $diff == 0
}

# ----------------------------------------------------------------------------
# Pure handler — returns {status: int, body: record}. No I/O metadata here.
# The route closure applies HTTP metadata at the tail so values propagate
# correctly through the if/else chain.
# ----------------------------------------------------------------------------

def handle_checkout [req: record, body: record, raw_body: string] {
    let project_slug = ($body | get --optional project | default "")
    let lookup_key   = ($body | get --optional lookup_key | default "")
    let success_url  = ($body | get --optional success_url | default "")
    let cancel_url   = ($body | get --optional cancel_url | default "")
    let required = {project: $project_slug, lookup_key: $lookup_key, success_url: $success_url, cancel_url: $cancel_url}
    let missing = ($required | columns | where {|k| ($required | get $k | str length) == 0})
    if ($missing | length) > 0 {
        return {status: 400, body: {error: $"missing required field: (($missing | first))"}}
    }

    let project = (load_project_with_consumer $project_slug)
    if ($project | is-empty) {
        return {status: 404, body: {error: $"no project '($project_slug)' or no consumer block"}}
    }

    # Bearer auth.
    let auth_header = ($req.headers? | get --optional "authorization" | default "")
    let token = (parse_bearer $auth_header)
    if ($token | str length) == 0 {
        return {status: 401, body: {error: "missing or malformed Authorization header"}}
    }
    let expected = (get_secret $project.consumer.bearer_token_keychain)
    if ($expected | str length) == 0 {
        return {status: 503, body: {error: $"smp config: bearer token not in keychain (($project.consumer.bearer_token_keychain))"}}
    }
    if not (secrets_equal $token $expected) {
        return {status: 401, body: {error: "unauthorized"}}
    }

    # Audit intent — every authenticated request lands in xs even if Stripe later errors.
    let intent_meta = {
        project: $project_slug
        lookup_key: $lookup_key
        received_at: (date now | format date "%+")
    }
    $raw_body | .append "stripe.intent.session.create" --meta $intent_meta

    # Resolve price by lookup_key.
    let listing = (^stripe prices list --lookup-keys $lookup_key --limit 1 | complete)
    if $listing.exit_code != 0 {
        "" | .append "stripe.api.session.failed" --meta ($intent_meta | merge { error: "stripe prices list failed" })
        return {status: 502, body: {error: "stripe API: prices list failed"}}
    }
    let prices = (try { $listing.stdout | from json | get data } catch { [] })
    if ($prices | length) == 0 {
        "" | .append "stripe.api.session.failed" --meta ($intent_meta | merge { error: $"no price for lookup_key=($lookup_key)" })
        return {status: 404, body: {error: $"no price for lookup_key '($lookup_key)'"}}
    }
    let price_id = ($prices | first | get id)

    # Build Stripe Checkout Session args. SMP mode, api_version pinned, project metadata tagged.
    let api_version = (get_api_version)
    mut args = [
        "post" "/v1/checkout/sessions"
        "--stripe-version" $api_version
        "-d" "mode=subscription"
        "-d" "managed_payments[enabled]=true"
        "-d" $"line_items[0][price]=($price_id)"
        "-d" "line_items[0][quantity]=1"
        "-d" $"success_url=($success_url)"
        "-d" $"cancel_url=($cancel_url)"
        "-d" $"metadata[project]=($project_slug)"
    ]
    let customer_email = ($body | get --optional customer_email | default "")
    if ($customer_email | str length) > 0 {
        $args = ($args | append ["-d" $"customer_email=($customer_email)"])
    }
    let extra_meta = ($body | get --optional metadata | default {})
    if ($extra_meta | describe | str starts-with "record") and not ($extra_meta | is-empty) {
        for k in ($extra_meta | columns) {
            let v = ($extra_meta | get $k | into string)
            $args = ($args | append ["-d" $"metadata[($k)]=($v)"])
        }
    }

    let r = (^stripe ...$args | complete)
    let resp = (try { $r.stdout | from json } catch { {} })
    let api_err = ($resp | get --optional error)
    if $api_err != null {
        let err_msg = ($api_err | get --optional message | default "stripe error")
        let err_code = ($api_err | get --optional code | default "")
        $r.stdout | .append "stripe.api.session.failed" --meta ($intent_meta | merge { error: $err_msg, stripe_code: $err_code })
        return {status: 502, body: {error: $"stripe API: ($err_msg)"}}
    }
    let session_id  = ($resp | get --optional id | default "")
    let session_url = ($resp | get --optional url | default "")
    if ($session_url | str length) == 0 {
        $r.stdout | .append "stripe.api.session.failed" --meta ($intent_meta | merge { error: "stripe response missing url" })
        return {status: 502, body: {error: "stripe response missing url"}}
    }

    $r.stdout | .append "stripe.api.session.created" --meta {
        project: $project_slug
        session_id: $session_id
        lookup_key: $lookup_key
    }

    {status: 201, body: {session_id: $session_id, url: $session_url}}
}

# ----------------------------------------------------------------------------
# Route — applies HTTP metadata at the tail expression.
# ----------------------------------------------------------------------------

export def checkout_route [] {
    route {method: "POST" path: "/v1/checkout"} {|req ctx|
        let raw_body = ($in | default "" | into string)
        let parsed = (try { $raw_body | from json } catch { null })
        let result = if $parsed == null {
            {status: 400, body: {error: "invalid JSON body"}}
        } else {
            handle_checkout $req $parsed $raw_body
        }
        $result.body | to json -r
        | metadata set {merge {http.response: {status: $result.status, headers: {Content-Type: "application/json"}}}}
    }
}
