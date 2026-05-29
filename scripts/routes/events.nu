#!/usr/bin/env nu
# Event inspection — read xs from any shell via curl + jq.
#
#   GET /events?limit=N&topic=T   recent N frames (filtered by topic if given)
#   GET /events/last?topic=T      single most-recent frame (optional topic)
#
# .cat is available because http-nu was started with --store, which embeds xs
# and bridges xs commands into the handler closure scope.

use http-nu/router *

export def events_list_route [] {
    route {method: "GET" path: "/events"} {|req ctx|
        let limit = ($req.query? | get --optional limit | default "20" | into int)
        let topic = ($req.query? | get --optional topic | default "")
        let frames = if ($topic | is-empty) {
            .cat | last $limit
        } else {
            .cat -T $topic | last $limit
        }
        $frames
        | metadata set {merge {http.response: {headers: {Content-Type: "application/json"}}}}
    }
}

export def events_last_route [] {
    route {method: "GET" path: "/events/last"} {|req ctx|
        let topic = ($req.query? | get --optional topic | default "")
        let frame = if ($topic | is-empty) {
            .cat | last 1
        } else {
            .cat -T $topic | last 1
        }
        $frame
        | metadata set {merge {http.response: {headers: {Content-Type: "application/json"}}}}
    }
}
