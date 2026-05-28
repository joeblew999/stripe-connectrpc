#!/usr/bin/env nu
# Refresh smp's reference data from Stripe's canonical docs.
#
#   nu scripts/data-refresh.nu check    # fetch, diff vs current files, no writes
#   nu scripts/data-refresh.nu apply    # stub — current refresh is manual after `check`
#
# Source: https://docs.stripe.com/payments/managed-payments/eligibility.md

const ELIG_URL = "https://docs.stripe.com/payments/managed-payments/eligibility.md"

def main [
    mode: string = "check"
] {
    match $mode {
        "check" => { diff_remote }
        "apply" => {
            print "apply is a stub — run `check`, eyeball the diff, edit data/*.jsonl by hand."
        }
        _ => {
            print "usage: nu scripts/data-refresh.nu [check|apply]"
            exit 1
        }
    }
}

def fetch_md [] {
    let tmp = "/tmp/smp-elig-refresh.md"
    let r = (^curl -sLf $ELIG_URL -o $tmp | complete)
    if $r.exit_code != 0 {
        print $"✗ fetch failed: ($r.stderr)"
        exit 1
    }
    $tmp
}

def parse_smp_sellers [path: string] {
    let text = (open --raw $path)
    mut in_section = false
    mut codes = []
    for line in ($text | lines) {
        if ($line | str starts-with "## Product eligibility") { break }
        if ($line | str contains "Supported business locations") {
            $in_section = true
            continue
        }
        if not $in_section { continue }
        let t = ($line | str trim)
        if ($t | str starts-with "- ") {
            let body = ($t | str substring 2..)
            if ($body | str length) == 2 and ($body | str upcase) == $body {
                $codes = ($codes | append $body)
            }
        }
    }
    $codes
}

def parse_restricted [path: string] {
    let text = (open --raw $path)
    mut in_section = false
    mut names = []
    for line in ($text | lines) {
        if ($line | str starts-with "## ") and $in_section { break }
        if ($line | str contains "### Restricted countries") {
            $in_section = true
            continue
        }
        if not $in_section { continue }
        let t = ($line | str trim)
        if ($t | str starts-with "- ") {
            $names = ($names | append ($t | str substring 2..))
        }
    }
    $names
}

def parse_tax_codes [path: string] {
    open --raw $path
    | lines
    | where ($it | str starts-with "| `txcd_")
    | each {|line|
        let parts = ($line | split row '|' | each {|c| $c | str trim})
        {
            code: ($parts | get 1 | str replace -ar '`' '')
            name: ($parts | get 2)
        }
    }
}

def diff_remote [] {
    print $"fetching ($ELIG_URL) ..."
    let path = (fetch_md)
    print "parsing ..."

    let remote_sellers = (parse_smp_sellers $path | sort)
    let remote_restricted = (parse_restricted $path | sort)
    let remote_tax_codes = (parse_tax_codes $path | get code | sort)

    let local_sellers = (
        open --raw data/countries.jsonl
        | lines
        | each {|l| $l | from json}
        | where {|c| "smp" in $c.seller_modes}
        | get code
        | sort
    )
    let local_restricted = (
        open --raw data/countries.jsonl
        | lines
        | each {|l| $l | from json}
        | where {|c| "smp" in $c.buyer_blocked_modes}
        | get name
        | sort
    )
    let local_tax_codes = (
        open --raw data/tax-codes.jsonl
        | lines
        | each {|l| $l | from json}
        | get code
        | sort
    )

    print "\n                                upstream   local"
    print $"  SMP seller countries:            (($remote_sellers | length))         (($local_sellers | length))"
    print $"  Restricted buyer countries:       (($remote_restricted | length))          (($local_restricted | length))"
    print $"  Eligible tax codes:              (($remote_tax_codes | length))         (($local_tax_codes | length))"

    print "\n=== diff ==="
    diff_set "SMP seller countries" $local_sellers $remote_sellers
    diff_set "Restricted buyer countries" $local_restricted $remote_restricted
    diff_set "Eligible tax codes" $local_tax_codes $remote_tax_codes
}

def diff_set [label: string, local: list, remote: list] {
    let added = ($remote | where {|c| $c not-in $local})
    let removed = ($local | where {|c| $c not-in $remote})
    if ($added | length) == 0 and ($removed | length) == 0 {
        print $"  ✓ ($label) — in sync"
    } else {
        print $"  Δ ($label):"
        if ($added | length) > 0 {
            print $"      + added upstream: ($added | str join ', ')"
        }
        if ($removed | length) > 0 {
            print $"      - removed upstream: ($removed | str join ', ')"
        }
    }
}
