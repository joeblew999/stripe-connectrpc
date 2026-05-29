#!/usr/bin/env nu
# dispatcher.nu — Phase 3 consumer fan-out (ADR-10).
#
# Tails xs for `stripe.webhook.verified` frames, dispatches each to the
# matching consumer(s) via the shared dispatch_to_consumer helper. That
# helper handles attempt logging, success/failure recording, and retry
# scheduling — see scripts/handlers/lib.nu for the contract.
#
# Reads on startup:
#   data/projects/<slug>/project.json → consumer.{webhook_url, signing_secret_keychain, event_filters}
#
# Resolves at dispatch time (so secret rotation only needs a daemon restart):
#   fnox get <signing_secret_keychain> → HMAC secret
#
# Run as a pitchfork daemon. Sibling daemon `dispatch-retry` polls xs for
# scheduled re-attempts.

use lib.nu *

def dispatch_frame [frame: record, consumers: list] {
    let body = (try { xs cas .xs-store/sock $frame.hash } catch { "" })
    if ($body | str length) == 0 {
        print $"  · skip ($frame.id) — empty body"
        return
    }
    let event = (try { $body | from json } catch { {} })
    let event_type = ($event | get --optional type | default "")
    let event_project = ($event | get --optional data.object.metadata.project | default "")

    # Multi-tenant safety: if the Stripe event carries metadata.project, only
    # deliver to THAT project's consumer. If absent, broadcast (events not
    # originating from a checkout session won't have it — e.g. account.updated).
    let targets = if ($event_project | str length) > 0 {
        $consumers | where slug == $event_project
    } else {
        $consumers
    }

    if ($targets | length) == 0 {
        print $"  · ($frame.id) ($event_type) — no matching consumer (event project='($event_project)')"
        return
    }

    for c in $targets {
        if (event_matches $event_type $c.filters) {
            dispatch_to_consumer $c $body $event 1 $frame.hash
        } else {
            print $"  · ($c.slug) ← ($event_type) — filtered out"
        }
    }
}

def main [] {
    let consumers = (load_consumers)
    if ($consumers | length) == 0 {
        print "dispatcher: no consumer configs found in data/projects/*/project.json — exiting"
        exit 0
    }
    print $"dispatcher: tailing xs stripe.webhook.verified for (($consumers | length)) consumers:"
    for c in $consumers {
        print $"  - ($c.slug) → ($c.url)  filters=(($c.filters | length))"
    }
    print ""

    # Stream verified frames as they land.
    xs cat .xs-store/sock --follow -T stripe.webhook.verified
    | lines
    | each {|line|
        let frame = (try { $line | from json } catch { null })
        if ($frame | is-empty) { return }
        dispatch_frame $frame $consumers
    }
    | ignore
}
