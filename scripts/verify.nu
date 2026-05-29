#!/usr/bin/env nu
# stripe-smp environment verification.
#
#   nu scripts/verify.nu          # quick: tools + Stripe keychain entries
#   nu scripts/verify.nu --all    # exhaustive: run every non-interactive mise task
#
# This is a STRIPE project. The required surface is Stripe + the http-nu/xs
# runtime. The Cloudflare bits (wrangler, CF keychain entries, wasm target)
# are alternative-runtime extras — present in the repo for if/when we want
# the cf:* path, but NOT hard requirements for the project to work.

def main [--all] {
    if $all { verify_all } else { quick }
}

# ============================================================================
# Quick env check — tools + secrets
# ============================================================================

def check_cmd [name: string, cmd: list<string>, --optional] {
    let r = (run-external ...$cmd | complete)
    if $r.exit_code == 0 {
        print $"  ✓ ($name)"
        0
    } else if $optional {
        print $"  ⊘ ($name) — optional (cf:* alt runtime only)"
        0
    } else {
        print $"  ✗ ($name) — not found or failed"
        1
    }
}

def check_secret [name: string, --optional] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 and (($r.stdout | str trim | str length) > 0) {
        print $"  ✓ keychain: ($name)"
        0
    } else if $optional {
        print $"  ⊘ keychain: ($name) — optional (cf:* alt runtime only)"
        0
    } else {
        print $"  ✗ keychain: ($name) — run `mise run onboard`"
        1
    }
}

def quick [] {
    mut fails = 0

    print "stripe-smp environment check"
    print "============================"

    print "\nrequired tools (Stripe + http-nu/xs runtime):"
    $fails = $fails + (check_cmd "nushell"     ["nu", "--version"])
    $fails = $fails + (check_cmd "stripe-cli"  ["stripe", "--version"])
    $fails = $fails + (check_cmd "fnox"        ["fnox", "--version"])
    $fails = $fails + (check_cmd "pitchfork"   ["pitchfork", "--version"])
    $fails = $fails + (check_cmd "xs"          ["xs", "--version"])
    $fails = $fails + (check_cmd "http-nu"     ["http-nu", "--version"])

    print "\nrequired keychain (Stripe):"
    $fails = $fails + (check_secret "SMP_STRIPE_SECRET_KEY")
    $fails = $fails + (check_secret "SMP_STRIPE_WEBHOOK_SECRET")

    print "\noptional — cf:* alternative runtime:"
    $fails = $fails + (check_cmd "rust"          ["rustc", "--version"]      --optional)
    $fails = $fails + (check_cmd "cargo"         ["cargo", "--version"]      --optional)
    $fails = $fails + (check_cmd "worker-build"  ["worker-build", "--version"] --optional)
    $fails = $fails + (check_cmd "wrangler"      ["wrangler", "--version"]   --optional)
    let wasm = ((rustup target list --installed | complete).stdout | default "" | str contains "wasm32-unknown-unknown")
    if $wasm {
        print "  ✓ wasm32-unknown-unknown installed"
    } else {
        print "  ⊘ wasm32-unknown-unknown — optional (cf:* alt runtime only)"
    }
    $fails = $fails + (check_secret "CLOUDFLARE_API_TOKEN"  --optional)
    $fails = $fails + (check_secret "CLOUDFLARE_ACCOUNT_ID" --optional)

    print ""
    if $fails > 0 {
        print $"($fails) check\(s\) failed"
        exit 1
    } else {
        print "all checks passed — try: mise run dev:up"
    }
}

# ============================================================================
# Exhaustive verifier — run every non-interactive mise task, report PASS/FAIL
# ============================================================================

def verify_all [] {
    let cases = [
        # toolchain / display
        {name: "verify"}
        {name: "show",      args: ["account"]}
        {name: "show",      args: ["status"]}
        {name: "show",      args: ["countries"]}
        {name: "show",      args: ["country", "AU"]}
        {name: "show",      args: ["tax-codes"]}
        {name: "show",      args: ["tax-coverage"]}
        {name: "show",      args: ["tax", "AU"]}
        {name: "show",      args: ["launches"]}
        {name: "show",      args: ["projects"]}
        {name: "show",      args: ["payment-methods"]}
        {name: "show",      args: ["scan"]}
        {name: "show",      args: ["flow"]}

        # apply (idempotent — safe to re-run)
        {name: "apply",     args: ["products"]}
        {name: "apply",     args: ["prices"]}
        {name: "apply",     args: ["portal"]}
        {name: "apply",     args: ["payment-methods"]}
        {name: "apply",     args: ["webhook"], skip: true, note: "needs SMP_SERVICE_URL"}

        # test flows
        {name: "test",      args: ["customer"]}
        {name: "test",      args: ["checkout"]}
        {name: "test",      args: ["checkout-payments"]}
        {name: "test",      args: ["checkout-thai"]}
        {name: "test",      args: ["rpc-checkout"]}

        # xs
        {name: "xs:cat"}
        {name: "xs:last",   args: ["stripe.webhook.verified"]}
        {name: "xs:tail"}
        {name: "xs:counts"}
        {name: "xs:append", args: ["test.verify", "{\"ok\":true}"]}

        # dispatch (Phase 3a — outbound to consumers)
        {name: "dispatch:attempted"}
        {name: "dispatch:delivered"}
        {name: "dispatch:failed"}

        # rpc (Phase 3b — inbound /v1/checkout)
        {name: "rpc:intent"}
        {name: "rpc:created"}
        {name: "rpc:failed"}

        # dev daemons
        {name: "dev:status"}
        {name: "dev:logs",  skip: true, note: "blocks (tail -f)"}
        {name: "dev:tui",   skip: true, note: "interactive TUI"}
        {name: "dispatch:logs", skip: true, note: "blocks (tail -f)"}

        # stripe passthroughs
        {name: "stripe:trigger-completed"}
        {name: "stripe:login",  skip: true, note: "interactive browser"}
        {name: "stripe:listen", skip: true, note: "duplicate of pitchfork 'listen'"}

        # open:* (idempotent — never open browser if already configured)
        {name: "open:cf-account"}
        {name: "open:cf-tokens"}
        {name: "open:stripe-account"}
        {name: "open:stripe-dashboard"}
        {name: "open:stripe-keys"}
        {name: "open:stripe-onboard"}
        {name: "open:stripe-payment-methods"}
        {name: "open:stripe-products"}
        {name: "open:stripe-smp"}
        {name: "open:stripe-webhooks"}

        # cf:* (alternative runtime, retained)
        {name: "cf:cargo-check",       skip: true, note: "slow wasm build; alt runtime"}
        {name: "cf:cargo-build",       skip: true, note: "slow worker-build; alt runtime"}
        {name: "cf:cargo-clean",       skip: true, note: "destructive; alt runtime"}
        {name: "cf:worker-dev",        skip: true, note: "starts wrangler dev; alt runtime"}
        {name: "cf:worker-deploy",     skip: true, note: "deploys; alt runtime"}
        {name: "cf:worker-tail",       skip: true, note: "blocks; alt runtime"}
        {name: "cf:worker-secret-put", skip: true, note: "alt runtime"}

        # meta
        {name: "mise:install",  skip: true, note: "already run during setup"}
        {name: "onboard",       skip: true, note: "interactive prompts"}
        {name: "verify:all",    skip: true, note: "would self-recurse"}

        # dev daemon lifecycle — run LAST and bring daemons back up after
        {name: "dev:restart-http"}
        {name: "dev:restart-listen"}
        {name: "dev:restart-dispatcher"}
    ]

    mut pass = 0
    mut fail = 0
    mut skip = 0
    mut failures = []

    print $"running (($cases | length)) mise-task checks"
    print "===================="

    for c in $cases {
        let name = $c.name
        let args = ($c | get --optional args | default [])
        let want_skip = ($c | get --optional skip | default false)
        let note = ($c | get --optional note | default "")

        if $want_skip {
            let detail = if ($note | str length) > 0 { $"  — ($note)" } else { "" }
            print $"  SKIP  ($name) (($args | str join ' '))($detail)"
            $skip = $skip + 1
            continue
        }

        let cmd_args = if ($args | length) > 0 {
            ["run", $name, "--"] | append $args
        } else {
            ["run", $name]
        }

        let r = (run-external "mise" ...$cmd_args | complete)
        if $r.exit_code == 0 {
            print $"  PASS  ($name) (($args | str join ' '))"
            $pass = $pass + 1
        } else {
            print $"  FAIL  ($name) (($args | str join ' ')) — exit (($r.exit_code))"
            let tail = ($r.stdout | lines | last 3 | str join "\n          ")
            if ($tail | str length) > 0 {
                print $"          ($tail)"
            }
            $fail = $fail + 1
            $failures = ($failures | append {name: $name, args: $args, exit_code: $r.exit_code})
        }
    }

    print ""
    print "===================="
    print $"PASS=($pass)  FAIL=($fail)  SKIP=($skip)"

    if $fail > 0 {
        print ""
        print "failed tasks:"
        for f in $failures {
            print $"  - ($f.name) (($f.args | str join ' '))  (exit ($f.exit_code))"
        }
        exit 1
    }
}
