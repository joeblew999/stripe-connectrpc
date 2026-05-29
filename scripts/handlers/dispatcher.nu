#!/usr/bin/env nu
# dispatcher.nu — Phase 3 consumer fan-out (ADR-10).
#
# Tails xs for `stripe.webhook.verified` frames, signs each event with the
# per-project consumer secret, POSTs to consumer.webhook_url, records the
# outcome back into xs.
#
# Topics emitted:
#   stripe.dispatch.attempted   — about to POST (meta: project, event_type, url)
#   stripe.dispatch.delivered   — consumer returned 2xx (meta: project, status, attempt)
#   stripe.dispatch.failed      — consumer non-2xx or network error (meta: …, error)
#
# Run as a pitchfork daemon (see pitchfork.toml `[daemons.dispatcher]`).
# Restart picks up changes to per-project consumer config + this script.
#
# Reads on startup:
#   data/projects/<slug>/project.json → consumer.{webhook_url, signing_secret_keychain, event_filters}
#
# Resolves at dispatch time (not boot — so secret rotation only needs handler restart):
#   fnox get <signing_secret_keychain> → HMAC secret
#
# CLI inspection from any shell:
#   mise run xs:last -- stripe.dispatch.delivered
#   mise run xs:cat | where topic =~ 'stripe.dispatch'

# ----------------------------------------------------------------------------
# Project routing table
# ----------------------------------------------------------------------------

# Load consumer config for every project that declares one. Projects without
# a `consumer` block are skipped (they're applied to Stripe but smp doesn't
# fan out to them).
def load_consumers [] {
    if not ("data/projects" | path exists) { return [] }
    ls data/projects | where type == "dir" | get name | each {|dir|
        let json_path = ([$dir "project.json"] | path join)
        if not ($json_path | path exists) { return null }
        let p = (open --raw $json_path | from json)
        let c = ($p | get --optional consumer)
        if ($c | is-empty) { return null }
        {
            slug:    $p.slug
            url:     $c.webhook_url
            secret_key:  $c.signing_secret_keychain
            filters: ($c.event_filters | default [])
        }
    } | compact
}

# True if `event_type` matches any pattern in `filters`. Patterns support a
# trailing wildcard like "checkout.session.async_payment_*".
def event_matches [event_type: string, filters: list] {
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
# consumers see the same wire format Stripe uses.
def hmac_sha256_hex [body: string, secret: string] {
    $body | ^openssl dgst -sha256 -hmac $secret -hex | str trim | parse -r '=\s*(?P<digest>[a-f0-9]+)\s*$' | get digest.0
}

# Resolve a keychain entry name → secret string at dispatch time (not boot).
# Returns empty string if fnox can't find it; caller logs + skips.
def get_secret [name: string] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

# ----------------------------------------------------------------------------
# Dispatch one verified event to one consumer
# ----------------------------------------------------------------------------

def dispatch_one [event: record, body: string, consumer: record] {
    let secret = (get_secret $consumer.secret_key)
    if ($secret | str length) == 0 {
        let failed_meta = {
            project: $consumer.slug
            url:     $consumer.url
            error:   $"missing secret in keychain: ($consumer.secret_key)"
            event_id: ($event | get --optional id | default "")
        }
        $body | xs append .xs-store/sock stripe.dispatch.failed --meta ($failed_meta | to json -r)
        print $"  ✗ ($consumer.slug) — no signing secret in keychain (($consumer.secret_key))"
        return
    }

    let timestamp = (date now | format date "%s")
    let signed = $"($timestamp).($body)"
    let sig = (hmac_sha256_hex $signed $secret)
    # Same shape Stripe uses, so consumers can reuse a verify helper.
    let stripe_sig_header = $"t=($timestamp),v1=($sig)"

    let attempt_meta = {
        project: $consumer.slug
        url:     $consumer.url
        event_id: ($event | get --optional id | default "")
        event_type: ($event | get --optional type | default "")
    }
    $body | xs append .xs-store/sock stripe.dispatch.attempted --meta ($attempt_meta | to json -r)

    # `curl -w '%{http_code}' -o -` writes body then a trailing 3-digit code.
    # We split on the last newline.
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

    let meta = {
        project: $consumer.slug
        url:     $consumer.url
        event_id: ($event | get --optional id | default "")
        event_type: ($event | get --optional type | default "")
        status: $status
        attempt: 1
    }

    if $status >= 200 and $status < 300 {
        $resp_body | xs append .xs-store/sock stripe.dispatch.delivered --meta ($meta | to json -r)
        print $"  ✓ ($consumer.slug) ← ($status)  ($event | get --optional type | default '?')"
    } else {
        let failed_meta = ($meta | merge { error: $"non-2xx status: ($status)" })
        $resp_body | xs append .xs-store/sock stripe.dispatch.failed --meta ($failed_meta | to json -r)
        print $"  ✗ ($consumer.slug) ← ($status)  ($event | get --optional type | default '?')"
    }
}

# ----------------------------------------------------------------------------
# Dispatch one verified frame to all eligible consumers
# ----------------------------------------------------------------------------

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
            dispatch_one $event $body $c
        } else {
            print $"  · ($c.slug) ← ($event_type) — filtered out"
        }
    }
}

# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------

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

    # Stream verified frames as they land. `xs cat --follow -T <topic>` blocks
    # forever and emits a JSON frame per line as new appends happen.
    xs cat .xs-store/sock --follow -T stripe.webhook.verified
    | lines
    | each {|line|
        let frame = (try { $line | from json } catch { null })
        if ($frame | is-empty) { return }
        dispatch_frame $frame $consumers
    }
    | ignore
}
