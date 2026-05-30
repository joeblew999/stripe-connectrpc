#!/usr/bin/env nu
# Smoke test the full consumer-RPC loop: POST /v1/checkout → bearer auth →
# Stripe Checkout Session create → 201 with session URL. Also probes the 401
# rejection path so the auth wall is provably alive.
#
# Usage:  mise run test:rpc-checkout [lookup_key]
#
# Side effects (visible via mise run rpc:*):
#   stripe.intent.session.create   (audit, post-auth)
#   stripe.api.session.created     (Stripe returned a URL)

const PROJECT    = "remy-sport"
const BEARER_KEY = "SMP_CONSUMER_REMY_SPORT_BEARER_TOKEN"
const URL        = "http://localhost:8787/v1/checkout"

def get_secret [name: string] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

# POST and split the curl "\n<status>" footer from the body.
def post_checkout [auth: string, body: string] {
    let r = (
        $body
        | ^curl -sS -X POST $URL
            -H $"Authorization: ($auth)"
            -H "Content-Type: application/json"
            -w "\n%{http_code}"
            --max-time 15
            --data-binary @-
        | complete
    )
    let stdout = ($r.stdout | str trim)
    let last_nl = ($stdout | str index-of -e "\n")
    let status = (if $last_nl == -1 { $stdout } else { $stdout | str substring ($last_nl + 1).. } | into int)
    let resp_body = (if $last_nl == -1 { "" } else { $stdout | str substring 0..$last_nl } | str trim)
    {status: $status body: $resp_body}
}

def main [lookup_key: string = "sports_coach_monthly_usd"] {
    let token = (get_secret $BEARER_KEY)
    if ($token | str length) == 0 {
        print $"✗ no bearer token in keychain (($BEARER_KEY))"
        print "  Generate one:"
        print $"    fnox set -p keychain ($BEARER_KEY) (\(openssl rand -hex 32\))"
        exit 1
    }

    let req_body = ({
        project: $PROJECT
        lookup_key: $lookup_key
        success_url: "http://localhost:8787/health?session={CHECKOUT_SESSION_ID}"
        cancel_url:  "http://localhost:8787/health?canceled=1"
        metadata:    {scenario: "test-rpc-checkout"}
    } | to json -r)

    # --- happy path ---
    print $"POST ($URL)"
    print $"  project=($PROJECT)  lookup_key=($lookup_key)"
    let ok = (post_checkout $"Bearer ($token)" $req_body)
    if $ok.status != 201 {
        print $"✗ expected 201, got ($ok.status)"
        print $ok.body
        exit 1
    }
    let parsed = (try { $ok.body | from json } catch { {} })
    let session_id  = ($parsed | get --optional session_id | default "")
    let session_url = ($parsed | get --optional url | default "")
    if ($session_id | str length) == 0 or ($session_url | str length) == 0 {
        print "✗ response missing session_id or url:"
        print $ok.body
        exit 1
    }
    print $"  ✓ ($ok.status)  session=($session_id)"
    print $"    url: ($session_url | str substring 0..80)..."
    print ""

    # --- auth wall: missing header → 401 ---
    print "auth probe — no header:"
    let no_auth = (post_checkout "" $req_body)
    if $no_auth.status != 401 {
        print $"  ✗ expected 401, got ($no_auth.status)"
        exit 1
    }
    print $"  ✓ ($no_auth.status)  ($no_auth.body)"

    # --- auth wall: wrong token → 401 ---
    print "auth probe — bad token:"
    let bad_auth = (post_checkout "Bearer wrong-token-here" $req_body)
    if $bad_auth.status != 401 {
        print $"  ✗ expected 401, got ($bad_auth.status)"
        exit 1
    }
    print $"  ✓ ($bad_auth.status)  ($bad_auth.body)"
    print ""

    print "all checks passed."
    print ""
    print "Open the URL to pay with 4242 4242 4242 4242. The post-payment webhook"
    print "will flow back through routes/webhook.nu → xs → dispatcher → consumer."
}
