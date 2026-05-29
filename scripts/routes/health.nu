#!/usr/bin/env nu
# GET /health — liveness probe.

use http-nu/router *

export def health_route [] {
    route {method: "GET" path: "/health"} {|req ctx|
        "smp ok"
    }
}
