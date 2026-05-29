#!/usr/bin/env nu
# dispatch-retry.nu — process scheduled re-attempts (Phase 3, retry policy).
#
# Polls xs every 15s for stripe.dispatch.retry frames whose
# meta.next_attempt_at has passed AND no later .delivered / .dead-lettered
# exists for the same (event_id, project). Re-dispatches via the same
# dispatch_to_consumer helper the initial-dispatch path uses.
#
# This is xs-as-queue (ADR-10): no Redis, no CF Queues. The event store IS
# the durable scheduling substrate.
#
# Topics consumed:   stripe.dispatch.retry
# Topics inspected:  stripe.dispatch.delivered, stripe.dispatch.dead-lettered
# Topics emitted:    via dispatch_to_consumer (attempted, delivered, failed, retry, dead-lettered)

use lib.nu *

const POLL_INTERVAL = 15sec

# Build the key used to dedupe retries: (event_id, project) uniquely
# identifies one dispatch chain.
def retry_key [meta: record] {
    let eid = ($meta | get --optional event_id | default "")
    let proj = ($meta | get --optional project  | default "")
    $"($eid)|($proj)"
}

# Find retries that are due now AND not superseded.
#
# "Superseded" = either:
#   - a later .retry with higher attempt exists for the same key
#     (means we already re-dispatched once after this one)
#   - a .delivered or .dead-lettered exists for the same key
#     (terminal outcome)
def find_due_retries [] {
    let now = (date now)

    let retries = (
        (^xs cat .xs-store/sock -T stripe.dispatch.retry | complete).stdout
        | lines | each {|l| try { $l | from json } catch { null }} | compact
    )
    if ($retries | length) == 0 { return [] }

    let terminals = (
        (^xs cat .xs-store/sock -T stripe.dispatch.delivered | complete).stdout
        | lines | each {|l| try { $l | from json } catch { null }} | compact
        | append (
            (^xs cat .xs-store/sock -T stripe.dispatch.dead-lettered | complete).stdout
            | lines | each {|l| try { $l | from json } catch { null }} | compact
        )
    )
    let terminal_keys = ($terminals | each {|f| retry_key $f.meta} | uniq)

    # For each retry key, find the highest attempt number we've scheduled.
    let max_attempt_by_key = (
        $retries
        | group-by {|f| retry_key $f.meta}
        | items {|key, fs|
            let max = ($fs | each {|f| $f.meta | get --optional attempt | default 0} | math max)
            {key: $key, max: $max}
        }
    )

    $retries | where {|f|
        let k = (retry_key $f.meta)
        # Skip if terminal outcome already exists.
        if $k in $terminal_keys { return false }
        # Skip if this isn't the latest retry for the key.
        let max_for_key = (
            $max_attempt_by_key
            | where key == $k
            | get max.0?
            | default 0
        )
        let this_attempt = ($f.meta | get --optional attempt | default 0)
        if $this_attempt < $max_for_key { return false }
        # Skip if not yet due.
        let next_at_str = ($f.meta | get --optional next_attempt_at | default "")
        if ($next_at_str | str length) == 0 { return false }
        let next_at = (try { $next_at_str | into datetime } catch { null })
        if $next_at == null { return false }
        $now >= $next_at
    }
}

def process_retry [retry_frame: record, consumers: list] {
    let m = $retry_frame.meta
    let project = ($m | get --optional project | default "")
    let consumer = ($consumers | where slug == $project | first)
    if ($consumer | is-empty) {
        # Consumer config was removed since the retry was scheduled. Dead-letter
        # because we can never deliver — meta.url is stale but there's nothing
        # to do but record the situation for the operator.
        let dl_meta = {
            project: $project
            event_id: ($m | get --optional event_id | default "")
            event_type: ($m | get --optional event_type | default "")
            attempts: ($m | get --optional attempt | default 0)
            reason: "consumer config removed since retry scheduled"
        }
        "" | xs append .xs-store/sock stripe.dispatch.dead-lettered --meta ($dl_meta | to json -r)
        print $"  ☠ ($project) — consumer config gone; dead-lettering ($retry_frame.id)"
        return
    }
    let verified_hash = ($m | get --optional verified_hash | default "")
    if ($verified_hash | str length) == 0 {
        let dl_meta = {
            project: $project
            event_id: ($m | get --optional event_id | default "")
            event_type: ($m | get --optional event_type | default "")
            attempts: ($m | get --optional attempt | default 0)
            reason: "retry frame missing verified_hash"
        }
        "" | xs append .xs-store/sock stripe.dispatch.dead-lettered --meta ($dl_meta | to json -r)
        print $"  ☠ ($project) — retry has no verified_hash; dead-lettering"
        return
    }
    let body = (try { (^xs cas .xs-store/sock $verified_hash | complete).stdout } catch { "" })
    if ($body | str length) == 0 {
        let dl_meta = {
            project: $project
            event_id: ($m | get --optional event_id | default "")
            event_type: ($m | get --optional event_type | default "")
            attempts: ($m | get --optional attempt | default 0)
            reason: $"body not in CAS for hash=($verified_hash)"
        }
        "" | xs append .xs-store/sock stripe.dispatch.dead-lettered --meta ($dl_meta | to json -r)
        print $"  ☠ ($project) — body missing from CAS; dead-lettering"
        return
    }
    let event = (try { $body | from json } catch { {} })
    let attempt = ($m | get --optional attempt | default 1)
    print $"  ↺ ($retry_frame.id) retry attempt=($attempt) → ($consumer.slug)"
    dispatch_to_consumer $consumer $body $event $attempt $verified_hash
}

def main [] {
    let consumers = (load_consumers)
    if ($consumers | length) == 0 {
        print "dispatch-retry: no consumer configs found — exiting"
        exit 0
    }
    print $"dispatch-retry: polling xs every ($POLL_INTERVAL) for due retries"
    print $"  consumers: (($consumers | length))   max attempts: ($MAX_ATTEMPTS)"
    print ""

    loop {
        let due = (find_due_retries)
        let n = ($due | length)
        if $n > 0 {
            print $"($n) due retries:"
            for r in $due {
                process_retry $r $consumers
            }
        }
        sleep $POLL_INTERVAL
    }
}
