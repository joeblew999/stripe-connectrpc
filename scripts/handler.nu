# http-nu handler closure. Thin composer over per-route files.
#
# Routes live under scripts/routes/. Each file exports a `*_route []` function
# that returns a `route ...` value. handler.nu collects them and feeds them
# to `dispatch` plus a catch-all 404.
#
# Side-effect topics appended to xs:
#   stripe.webhook.received   — raw inbound to /v1/webhook (pre-verify)
#   stripe.webhook.verified   — HMAC validated
#   stripe.webhook.invalid    — signature mismatch / missing header (response 400)

use http-nu/router *
use routes/health.nu *
use routes/events.nu *
use routes/webhook.nu *
use routes/checkout.nu *

{|req|
    dispatch $req [
        (health_route)
        (events_list_route)
        (events_last_route)
        (webhook_route)
        (checkout_route)

        # Catch-all 404.
        (route true {|req ctx|
            $"no route for ($req.method) ($req.path)"
            | metadata set {merge {http.response: {status: 404}}}
        })
    ]
}
