#!/usr/bin/env nu
# Shared helpers for the bootstrap layer (show / apply / test / teardown).
# Public functions are `export def` and imported via `use scripts/bootstrap/lib.nu *`.

# Read a key from data/config/stripe-config.jsonl. Each row is
# {"key": "...", "value": "...", "note": "..."}. Loaded once per call.
export def stripe_config [key: string] {
    let rows = (open --raw data/config/stripe-config.jsonl | lines | each {|l| $l | from json})
    let match = ($rows | where key == $key | first)
    if ($match | is-empty) {
        print $"✗ missing stripe-config key: ($key)"
        exit 1
    }
    $match.value
}

# Enumerate every data/projects/<slug>/ directory that has a project.json.
# Returns a list of records: project.json content merged with {dir: <path>}.
export def list_projects [] {
    if not ("data/projects" | path exists) {
        return []
    }
    ls data/projects | where type == "dir" | get name | each {|dir|
        let json_path = ([$dir "project.json"] | path join)
        if ($json_path | path exists) {
            let p = (open --raw $json_path | from json)
            $p | merge { dir: $dir }
        } else {
            null
        }
    } | compact
}

# Normalize an arg that may be null OR an empty string (mise's usage spec
# feeds empty strings for omitted optional args) into null so `| default`
# operators downstream work as intended.
export def normalize_arg [arg: any] {
    if ($arg == null) { return null }
    if (($arg | describe) == "string" and (($arg | str length) == 0)) { return null }
    $arg
}
