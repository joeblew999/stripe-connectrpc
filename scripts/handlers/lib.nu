#!/usr/bin/env nu
# Shared helpers for the dispatcher + dispatch-retry daemons.
#
# Topic vocabulary (Phase 3 — ADR-10 + ADR-12):
#   stripe.dispatch.attempted    — about to POST (per attempt)
#   stripe.dispatch.delivered    — consumer 2xx (terminal success)
#   stripe.dispatch.failed       — consumer non-2xx / network / timeout (per attempt)
#   stripe.dispatch.retry        — scheduled re-attempt; meta.next_attempt_at = ISO 8601
#   stripe.dispatch.dead-lettered — gave up after MAX_ATTEMPTS (terminal failure)

# Cap. After this many total attempts, dead-letter.
export const MAX_ATTEMPTS = 7

# Stripe-style backoff. Arg is the UPCOMING attempt number. Returns seconds.
#   attempt 2 (first retry)  →  30 seconds
#   attempt 3                →  5 minutes
#   attempt 4                →  30 minutes
#   attempt 5                →  2 hours
#   attempt 6                →  12 hours
#   attempt 7                →  24 hours
# Total elapsed for 7 attempts ≈ 1.6 days, matching Stripe's own webhook retry.
export def backoff_seconds [next_attempt: int]: nothing -> int {
    match $next_attempt {
        2 => 30
        3 => 300
        4 => 1800
        5 => 7200
        6 => 43200
        7 => 86400
        _ => 86400
    }
}

# Load consumer config for every project that declares one. Projects without
# a `consumer` block are skipped.
export def load_consumers [] {
    if not ("data/projects" | path exists) { return [] }
    ls data/projects | where type == "dir" | get name | each {|dir|
        let json_path = ([$dir "project.json"] | path join)
        if not ($json_path | path exists) { return null }
        let p = (open --raw $json_path | from json)
        let c = ($p | get --optional consumer)
        if ($c | is-empty) { return null }
        {
            slug:       $p.slug
            url:        $c.webhook_url
            secret_key: $c.signing_secret_keychain
            filters:    ($c.event_filters | default [])
        }
    } | compact
}

# True if `event_type` matches any pattern in `filters`.
# Patterns support a trailing wildcard like "checkout.session.async_payment_*".
# Empty filters list = match all.
export def event_matches [event_type: string, filters: list] {
    if ($filters | length) == 0 { return true }
    for f in $filters {
        if ($f | str ends-with "*") {
            let prefix = ($f | str substring 0..(($f | str length) - 2))
            if ($event_type | str starts-with $prefix) { return true }
        } else if $event_type == $f {
            return true
        }
    }
    false
}

# HMAC-SHA256 hex via openssl. Same primitive as routes/webhook.nu so
# consumers can reuse a verify helper.
export def hmac_sha256_hex [body: string, secret: string] {
    $body | ^openssl dgst -sha256 -hmac $secret -hex | str trim | parse -r '=\s*(?P<digest>[a-f0-9]+)\s*$' | get digest.0
}

# Resolve a keychain entry → secret string. Returns "" if fnox can't find it.
export def get_secret [name: string] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

# ----------------------------------------------------------------------------
# Core dispatch: POST + emit attempted + delivered|failed [+retry|+dead-lettered]
#
# This is the only place that knows the full attempt-outcome contract.
# Both dispatcher.nu (attempt=1 from new .verified) and dispatch-retry.nu
# (attempt=N≥2 from due .retry) call this.
# ----------------------------------------------------------------------------

export def dispatch_to_consumer [
    consumer: record,       # {slug, url, secret_key, filters}
    body: string,
    event: record,
    attempt: int,           # 1 = initial; 2..MAX_ATTEMPTS = retries
    verified_hash: string,  # CAS hash of the original .verified body (carried through retries)
] {
    let event_id   = ($event | get --optional id   | default "")
    let event_type = ($event | get --optional type | default "")

    # --- Config check: no signing secret = permanent operator-fix error.
    # Don't retry these; they need a `fnox set` to recover. Emit .failed +
    # .dead-lettered so the operator sees them via dispatch:dead-lettered.
    let secret = (get_secret $consumer.secret_key)
    if ($secret | str length) == 0 {
        let failed_meta = {
            project: $consumer.slug
            url:     $consumer.url
            event_id: $event_id
            event_type: $event_type
            error:   $"missing secret in keychain: ($consumer.secret_key)"
            attempt: $attempt
        }
        $body | xs append .xs-store/sock stripe.dispatch.failed --meta ($failed_meta | to json -r)
        let dl_meta = {
            project: $consumer.slug
            url:     $consumer.url
            event_id: $event_id
            event_type: $event_type
            attempts: $attempt
            reason:  "config: missing signing secret"
        }
        "" | xs append .xs-store/sock stripe.dispatch.dead-lettered --meta ($dl_meta | to json -r)
        print $"  ☠ ($consumer.slug) — DEAD-LETTERED: no signing secret (($consumer.secret_key))"
        return
    }

    # --- HMAC sign + emit attempted.
    let timestamp = (date now | format date "%s")
    let signed = $"($timestamp).($body)"
    let sig = (hmac_sha256_hex $signed $secret)
    let stripe_sig_header = $"t=($timestamp),v1=($sig)"

    let attempt_meta = {
        project: $consumer.slug
        url:     $consumer.url
        event_id: $event_id
        event_type: $event_type
        attempt: $attempt
    }
    $body | xs append .xs-store/sock stripe.dispatch.attempted --meta ($attempt_meta | to json -r)

    # --- POST.
    let r = (
        $body
        | ^curl -sS -X POST $consumer.url
            -H $"Stripe-Signature: ($stripe_sig_header)"
            -H "Content-Type: application/json"
            -H "User-Agent: stripe-smp-dispatcher/0.1"
            -w "\n%{http_code}"
            --max-time 10
            --data-binary @-
        | complete
    )
    let stdout = ($r.stdout | str trim)
    let last_nl = ($stdout | str index-of -e "\n")
    let status = (if $last_nl == -1 { $stdout } else { $stdout | str substring ($last_nl + 1).. } | into int)
    let resp_body = (if $last_nl == -1 { "" } else { $stdout | str substring 0..$last_nl } | str trim)

    let outcome_meta = {
        project: $consumer.slug
        url:     $consumer.url
        event_id: $event_id
        event_type: $event_type
        status: $status
        attempt: $attempt
    }

    # --- Success: terminal.
    if $status >= 200 and $status < 300 {
        $resp_body | xs append .xs-store/sock stripe.dispatch.delivered --meta ($outcome_meta | to json -r)
        print $"  ✓ ($consumer.slug) ← ($status)  attempt=($attempt)  ($event_type)"
        return
    }

    # --- Failure: log the per-attempt .failed, then schedule retry OR dead-letter.
    let failed_meta = ($outcome_meta | merge { error: $"non-2xx status: ($status)" })
    $resp_body | xs append .xs-store/sock stripe.dispatch.failed --meta ($failed_meta | to json -r)
    print $"  ✗ ($consumer.slug) ← ($status)  attempt=($attempt)  ($event_type)"

    if $attempt >= $MAX_ATTEMPTS {
        let dl_meta = {
            project: $consumer.slug
            url:     $consumer.url
            event_id: $event_id
            event_type: $event_type
            attempts: $attempt
            reason:  $"non-2xx after ($attempt) attempts"
        }
        "" | xs append .xs-store/sock stripe.dispatch.dead-lettered --meta ($dl_meta | to json -r)
        print $"  ☠ ($consumer.slug) DEAD-LETTERED after ($attempt) attempts"
    } else {
        let next_attempt = ($attempt + 1)
        let backoff = (backoff_seconds $next_attempt)
        let next_at = ((date now) + ($backoff * 1sec))
        let retry_meta = {
            project: $consumer.slug
            url:     $consumer.url
            event_id: $event_id
            event_type: $event_type
            attempt: $next_attempt
            next_attempt_at: ($next_at | format date "%+")
            verified_hash: $verified_hash
            previous_status: $status
        }
        "" | xs append .xs-store/sock stripe.dispatch.retry --meta ($retry_meta | to json -r)
        print $"  ↻ ($consumer.slug) retry scheduled: attempt=($next_attempt) in ($backoff)s"
    }
}
