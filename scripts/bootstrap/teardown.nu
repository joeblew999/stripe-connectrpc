#!/usr/bin/env nu
# teardown.nu — archive per-project Stripe state.
# Cross-leak safe: only touches objects whose metadata.project matches the
# requested slug. Stripe can't truly delete products/prices; this sets
# active=false. apply -- products re-activates.
#
# Surface (via bootstrap.nu dispatcher):
#   teardown -- <project-slug>

use lib.nu *

export def teardown_all [] {
    let projects = (list_projects)
    if ($projects | length) == 0 {
        print "no projects found in data/projects/"
        return
    }
    print $"=== teardown all (($projects | length)) projects ==="
    print ""
    for p in $projects {
        teardown_project $p.slug
        print ""
    }
    print "All projects torn down."
    print "Note: portal config + payment-methods config + webhook endpoint remain"
    print "  on the Stripe account — those are account-wide, not per-project."
    print "  To restore: mise run stripe:bootstrap"
}

export def teardown_project [slug: string] {
    let proj_dir = ([("data/projects") $slug] | path join)
    let proj_json = ([$proj_dir "project.json"] | path join)
    if not ($proj_json | path exists) {
        print $"✗ no project at ($proj_dir)"
        exit 1
    }
    let project = (open --raw $proj_json | from json)
    if $project.slug != $slug {
        print $"✗ project.slug='($project.slug)' does not match directory name '($slug)'"
        exit 1
    }
    print $"=== teardown ($project.slug) — ($project.name) ==="

    # Deactivate prices first (more conservative ordering — even though Stripe
    # allows archiving products with active prices, prices-then-products is
    # the cleaner sequence for state machines).
    let prices_path = ([$proj_dir "prices.jsonl"] | path join)
    if ($prices_path | path exists) {
        let rows = (open --raw $prices_path | lines | each {|l| $l | from json})
        print $"  ($rows | length) prices declared in project"
        for p in $rows {
            let listing = (^stripe prices list --lookup-keys $p.lookup_key --limit 10 | complete)
            let listed = (try { $listing.stdout | from json | get data } catch { [] })
            if ($listed | length) == 0 {
                print $"    · ($p.lookup_key) — not in Stripe, skipping"
                continue
            }
            for existing in $listed {
                let proj_meta = ($existing | get --optional metadata.project | default "")
                # Cross-leak guard: never touch a price tagged for another project.
                if $proj_meta != $project.slug {
                    print $"    ⚠ SKIP ($existing.id) — metadata.project='($proj_meta)' != '($project.slug)'"
                    continue
                }
                let r = (^stripe post $"/v1/prices/($existing.id)" -d "active=false" | complete)
                let body = (try { $r.stdout | from json } catch { {} })
                if (($body | get --optional active) == false) {
                    print $"    ✓ deactivated ($existing.id) [($p.lookup_key)]"
                } else {
                    print $"    ✗ failed to deactivate ($existing.id)"
                }
            }
        }
    }

    let products_path = ([$proj_dir "products.jsonl"] | path join)
    if ($products_path | path exists) {
        let rows = (open --raw $products_path | lines | each {|l| $l | from json})
        print $"  ($rows | length) products declared in project"
        for p in $rows {
            let retrieve = (^stripe products retrieve $p.id | complete)
            let body = (try { $retrieve.stdout | from json } catch { {} })
            if (($body | get --optional id) != $p.id) {
                print $"    · ($p.id) — not in Stripe, skipping"
                continue
            }
            let proj_meta = ($body | get --optional metadata.project | default "")
            if $proj_meta != $project.slug {
                print $"    ⚠ SKIP ($p.id) — metadata.project='($proj_meta)' != '($project.slug)'"
                continue
            }
            let r = (^stripe post $"/v1/products/($p.id)" -d "active=false" | complete)
            let upd_body = (try { $r.stdout | from json } catch { {} })
            if (($upd_body | get --optional active) == false) {
                print $"    ✓ archived ($p.id)"
            } else {
                print $"    ✗ failed to archive ($p.id)"
            }
        }
    }

    print ""
    print "  Done. To restore: mise run stripe:apply-products — re-activates archived items."
}
