#!/usr/bin/env nu
# POST /v1/checkout — consumer RPC scaffold.
# Future shape: verify bearer, parse JSON, emit stripe.intent.session.create,
# await reply, return URL. Today: 501 placeholder.

use http-nu/router *

export def checkout_route [] {
    route {method: "POST" path: "/v1/checkout"} {|req ctx|
        "not yet implemented" | metadata set {merge {http.response: {status: 501}}}
    }
}
