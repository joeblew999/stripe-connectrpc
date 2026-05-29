# http-nu handler closure. Receives a request record, returns the response.
# Has access to .cat / .append / .last / .cas because http-nu was started
# with --store .xs-store.
#
# Routes:
#   GET  /health      → liveness probe
#   POST /v1/webhook  → Stripe webhook receiver (append to xs)
#   POST /v1/checkout → consumer RPC scaffold (not yet implemented)

use http-nu/router *

{|req|
    dispatch $req [
        (route {method: "GET" path: "/health"} {|req ctx|
            "smp ok"
        })

        (route {method: "POST" path: "/v1/webhook"} {|req ctx|
            # `from string` reads the request body off the pipeline.
            let body = ($in | default "" | into string)
            let sig = ($req.headers? | get --optional "stripe-signature" | default "")

            if ($sig | is-empty) {
                "missing Stripe-Signature" | metadata set {merge {http.response: {status: 400}}}
            } else {
                # Append the raw inbound event. A separate handler (or
                # subscriber) will verify HMAC and emit downstream events.
                $body | .append "stripe.webhook.received" --meta {
                    signature: $sig
                    received_at: (date now | format date "%+")
                    bytes: ($body | str length)
                }
                "received"
            }
        })

        (route {method: "POST" path: "/v1/checkout"} {|req ctx|
            # Consumer RPC scaffold. Real impl will: verify bearer token,
            # parse JSON body, emit stripe.intent.session.create, await
            # a stripe.api.session.created reply, return {url, session_id}.
            "not yet implemented" | metadata set {merge {http.response: {status: 501}}}
        })

        (route true {|req ctx|
            $"no route for ($req.method) ($req.path)"
            | metadata set {merge {http.response: {status: 404}}}
        })
    ]
}
