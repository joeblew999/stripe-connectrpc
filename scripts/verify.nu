#!/usr/bin/env nu
# smp environment verification — tools, target, keychain entries.

mut fails = 0

def check_cmd [name: string, cmd: list<string>] {
    # `complete` captures stdout + stderr + exit_code; the old
    # --redirect-combine flag was removed in nushell 0.106+.
    let r = (run-external ...$cmd | complete)
    if $r.exit_code == 0 {
        print $"  ✓ ($name)"
        0
    } else {
        print $"  ✗ ($name) — not found or failed"
        1
    }
}

def check_secret [name: string] {
    let r = (do { fnox get $name } | complete)
    if $r.exit_code == 0 and (($r.stdout | str trim | str length) > 0) {
        print $"  ✓ keychain: ($name)"
        0
    } else {
        print $"  ✗ keychain: ($name) — run `mise run onboard`"
        1
    }
}

print "smp environment check"
print "====================="

print "\ntools:"
$fails = $fails + (check_cmd "rust"          ["rustc", "--version"])
$fails = $fails + (check_cmd "cargo"         ["cargo", "--version"])
$fails = $fails + (check_cmd "wrangler"      ["wrangler", "--version"])
$fails = $fails + (check_cmd "worker-build"  ["worker-build", "--version"])
$fails = $fails + (check_cmd "fnox"          ["fnox", "--version"])
$fails = $fails + (check_cmd "stripe-cli"    ["stripe", "--version"])

print "\nwasm target:"
let wasm = ((rustup target list --installed) | str contains "wasm32-unknown-unknown")
if $wasm {
    print "  ✓ wasm32-unknown-unknown installed"
} else {
    print "  ✗ wasm32-unknown-unknown missing — run: rustup target add wasm32-unknown-unknown"
    $fails = $fails + 1
}

print "\nkeychain:"
$fails = $fails + (check_secret "CLOUDFLARE_API_TOKEN")
$fails = $fails + (check_secret "CLOUDFLARE_ACCOUNT_ID")
$fails = $fails + (check_secret "SMP_STRIPE_SECRET_KEY")
$fails = $fails + (check_secret "SMP_STRIPE_WEBHOOK_SECRET")

print ""
if $fails > 0 {
    print $"($fails) check\(s\) failed"
    exit 1
} else {
    print "all checks passed — try: mise run worker:dev"
}
