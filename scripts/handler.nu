# http-nu handler closure. Receives a request record, returns the response.
# Has access to .cat / .append / .last / .cas because http-nu was started
# with --store .xs-store.
#
# Routes:
#   GET  /health      → liveness probe
#   POST /v1/webhook  → Stripe webhook receiver: HMAC verify + append to xs
#   POST /v1/checkout → consumer RPC scaffold (501 not yet implemented)
#
# Topics appended to xs:
#   stripe.webhook.received  — raw inbound (pre-verify)
#   stripe.webhook.verified  — HMAC validated against STRIPE_WEBHOOK_SECRET
#   stripe.webhook.invalid   — signature mismatch / missing header

use http-nu/router *

# HMAC-SHA256 hex via openssl. Returns the hex digest as a string.
def hmac_sha256_hex [body: string, secret: string] {
    $body | ^openssl dgst -sha256 -hmac $secret -hex | str trim | parse -r '=\s*(?P<digest>[a-f0-9]+)\s*$' | get digest.0
}

# Verify Stripe-Signature header against STRIPE_WEBHOOK_SECRET.
# Returns {valid: bool, timestamp: int, error?: string}.
def verify_stripe_signature [sig_header: string, body: string, secret: string] {
    if ($sig_header | is-empty) { return {valid: false, timestamp: 0, error: "missing Stripe-Signature"} }
    if ($secret | is-empty)     { return {valid: false, timestamp: 0, error: "STRIPE_WEBHOOK_SECRET not in env"} }
    let parts = ($sig_header | split row "," | each {|p| $p | str trim | parse -r '^(?P<k>[^=]+)=(?P<v>.+)$' | get 0})
    let t_row = ($parts | where k == "t" | first)
    let v_row = ($parts | where k == "v1" | first)
    if ($t_row | is-empty) or ($v_row | is-empty) {
        return {valid: false, timestamp: 0, error: "malformed Stripe-Signature header"}
    }
    let timestamp = ($t_row.v | into int)
    let v1_sig   = ($v_row.v)
    let signed_payload = $"($timestamp).($body)"
    let computed = (hmac_sha256_hex $signed_payload $secret)
    if $computed == $v1_sig {
        {valid: true, timestamp: $timestamp}
    } else {
        {valid: false, timestamp: $timestamp, error: "signature mismatch"}
    }
}

{|req|
    dispatch $req [
        (route {method: "GET" path: "/health"} {|req ctx|
            "smp ok"
        })

        (route {method: "POST" path: "/v1/webhook"} {|req ctx|
            let body = ($in | default "" | into string)
            let sig  = ($req.headers? | get --optional "stripe-signature" | default "")
            let secret = ($env | get --optional "STRIPE_WEBHOOK_SECRET" | default "")

            # 1. Always record the raw inbound — useful for audit + debugging.
            $body | .append "stripe.webhook.received" --meta {
                signature: $sig
                received_at: (date now | format date "%+")
                bytes: ($body | str length)
            }

            # 2. Verify HMAC, append .verified or .invalid based on result.
            let v = (verify_stripe_signature $sig $body $secret)
            if $v.valid {
                $body | .append "stripe.webhook.verified" --meta {
                    timestamp: $v.timestamp
                    verified_at: (date now | format date "%+")
                }
                "verified"
            } else {
                $body | .append "stripe.webhook.invalid" --meta {
                    reason: $v.error
                    received_at: (date now | format date "%+")
                }
                $"invalid signature: ($v.error)" | metadata set {merge {http.response: {status: 400}}}
            }
        })

        (route {method: "POST" path: "/v1/checkout"} {|req ctx|
            # Consumer RPC scaffold — verify bearer, parse JSON, emit
            # stripe.intent.session.create, await reply, return URL.
            "not yet implemented" | metadata set {merge {http.response: {status: 501}}}
        })

        (route true {|req ctx|
            $"no route for ($req.method) ($req.path)"
            | metadata set {merge {http.response: {status: 404}}}
        })
    ]
}
