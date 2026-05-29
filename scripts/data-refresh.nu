#!/usr/bin/env nu
# Refresh smp's reference data from Stripe's canonical docs.
#
#   nu scripts/data-refresh.nu check    # fetch all sources, diff vs local
#   nu scripts/data-refresh.nu apply    # stub — current refresh is manual after `check`
#
# ONLY touches data/reference/*.jsonl — `data/config/*.jsonl` is our config
# and is deliberately out of scope here.
#
# Sources covered:
#   - data/reference/countries.jsonl    (SMP seller list + restricted buyers)
#                                       ← eligibility.md
#   - data/reference/tax-codes.jsonl    (SMP-eligible product tax codes)
#                                       ← eligibility.md
#   - data/reference/tax-coverage.jsonl (buyer countries Stripe handles tax for)
#                                       ← tax-compliance.md

const ELIG_URL = "https://docs.stripe.com/payments/managed-payments/eligibility.md"
const TAX_URL  = "https://docs.stripe.com/payments/managed-payments/tax-compliance.md"

def main [
    mode: string = "check"
] {
    match $mode {
        "check" => { diff_remote }
        "apply" => {
            print "apply is a stub — run `check`, eyeball the diff, edit data/reference/*.jsonl by hand."
        }
        _ => {
            print "usage: nu scripts/data-refresh.nu [check|apply]"
            exit 1
        }
    }
}

def fetch_to [url: string, path: string] {
    let r = (^curl -sLf $url -o $path | complete)
    if $r.exit_code != 0 {
        print $"✗ fetch failed for ($url): ($r.stderr)"
        exit 1
    }
}

# ============================================================================
# eligibility.md parsers — SMP sellers, restricted buyers, eligible tax codes
# ============================================================================

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
        ($parts | get 1 | str replace -ar '`' '')
    }
}

# ============================================================================
# tax-compliance.md parser — countries Stripe handles tax for (cross-border)
# ============================================================================

# The page has sections like "### Asia Pacific", "### Europe", etc. each with
# a bullet list of country codes. We collect codes from any section under
# "## Supported countries for tax coverage" and stop at "## Unsupported …".
def parse_tax_coverage [path: string] {
    let text = (open --raw $path)
    mut in_supported = false
    mut codes = []
    for line in ($text | lines) {
        if ($line | str starts-with "## Supported countries") {
            $in_supported = true
            continue
        }
        if ($line | str starts-with "## Unsupported countries") {
            $in_supported = false
            break
        }
        if not $in_supported { continue }
        let t = ($line | str trim)
        if ($t | str starts-with "- ") {
            let body = ($t | str substring 2..)
            if ($body | str length) == 2 and ($body | str upcase) == $body {
                $codes = ($codes | append $body)
            }
        }
    }
    $codes | uniq
}

# ============================================================================
# Diff
# ============================================================================

def diff_remote [] {
    print "fetching upstream ..."
    let elig_path = "/tmp/smp-refresh-eligibility.md"
    let tax_path  = "/tmp/smp-refresh-tax-compliance.md"
    fetch_to $ELIG_URL $elig_path
    fetch_to $TAX_URL  $tax_path
    print "parsing ..."

    let remote_sellers     = (parse_smp_sellers $elig_path | sort)
    let remote_restricted  = (parse_restricted  $elig_path | sort)
    let remote_tax_codes   = (parse_tax_codes   $elig_path | sort)
    let remote_tax_cov     = (parse_tax_coverage $tax_path | sort)

    let local_sellers = (
        open --raw data/reference/countries.jsonl
        | lines | each {|l| $l | from json}
        | where {|c| "smp" in $c.seller_modes}
        | get code | sort
    )
    let local_restricted = (
        open --raw data/reference/countries.jsonl
        | lines | each {|l| $l | from json}
        | where {|c| "smp" in $c.buyer_blocked_modes}
        | get name | sort
    )
    let local_tax_codes = (
        open --raw data/reference/tax-codes.jsonl
        | lines | each {|l| $l | from json}
        | get code | sort
    )
    let local_tax_cov = (
        open --raw data/reference/tax-coverage.jsonl
        | lines | each {|l| $l | from json}
        | get code | sort
    )

    print ""
    print "                                  upstream   local"
    print $"  SMP seller countries:              (($remote_sellers | length))         (($local_sellers | length))"
    print $"  Restricted buyer countries:         (($remote_restricted | length))          (($local_restricted | length))"
    print $"  Eligible tax codes:                (($remote_tax_codes | length))         (($local_tax_codes | length))"
    print $"  Tax-coverage buyer countries:      (($remote_tax_cov | length))         (($local_tax_cov | length))"

    print "\n=== diff ==="
    diff_set "SMP seller countries"        $local_sellers     $remote_sellers
    diff_set "Restricted buyer countries"  $local_restricted  $remote_restricted
    diff_set "Eligible tax codes"          $local_tax_codes   $remote_tax_codes
    diff_set "Tax-coverage buyer countries" $local_tax_cov    $remote_tax_cov
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
