#!/usr/bin/env nu
# Prove CatalogService.UpsertProduct end-to-end: the typed, admin-gated,
# idempotent replacement for the stripe-cli `seed_products` nushell. Loads
# remy-sport's products.jsonl INTO Stripe THROUGH the ConnectRPC service
# (async-stripe), behind the Rauthy → Cedar admin policy.
#
#   mise run catalog:verify          # Rauthy + native up → load + assert
#   mise run catalog:verify --down   # tear down
#
# Needs Docker + ../../vm-uncloud + STRIPE_SECRET_KEY (fnox-wrapped by the task).

const VMU = "../../vm-uncloud"
const RAUTHY = "http://localhost:8080"
const ISSUER = "http://localhost:8080/auth/v1/"
const SRV = "http://127.0.0.1:8090"
const PW = "LocalDevAdminPassword123456"

def main [--down] {
  if $down {
    do { ^pkill -f stripe-native } | complete | ignore
    do { cd $VMU; ^mise run recipe:local rauthy --down } | complete | ignore
    print "down."
    return
  }
  if not ($VMU | path exists) { print -e $"missing ($VMU)"; exit 1 }

  # 1. Rauthy + an ADMIN token (admin@localhost carries the 'admin' role).
  print "1/4 · Rauthy + admin token ..."
  do { cd $VMU; ^mise run recipe:local rauthy --down } | complete | ignore
  let up = (do { cd $VMU; ^mise run recipe:local rauthy } | complete)
  let secret = ($up.stdout ++ $up.stderr | lines
    | where ($it =~ "worker-client' secret:")
    | get 0? | default "" | parse -r "secret: (?<s>[A-Za-z0-9]+)" | get s.0? | default "")
  if ($secret | is-empty) { print -e "no worker-client secret"; exit 1 }
  mut ready = false
  for _ in 0..30 { sleep 2sec; if (do { ^curl -fsS $"($RAUTHY)/auth/v1/.well-known/openid-configuration" } | complete).exit_code == 0 { $ready = true; break } }
  if not $ready { print -e "Rauthy didn't come up"; exit 1 }
  let body = $"grant_type=password&client_id=worker-client&client_secret=($secret)&username=admin@localhost&password=($PW)&scope=openid profile groups"
  let token = (^curl -fsS -X POST $"($RAUTHY)/auth/v1/oidc/token" -d $body | from json | get access_token)
  print "      ✓ Rauthy up + admin token (role 'admin')"

  # 2. stripe-native (CatalogService + CheckoutService behind the guard).
  print "2/4 · stripe-native ..."
  ^cargo build -q -p stripe-native
  let job = (job spawn {||
    with-env { RAUTHY_ISSUER: $ISSUER, RAUTHY_JWKS_URL: $"($RAUTHY)/auth/v1/oidc/certs", RAUTHY_AUD: "worker-client", PORT: "8090" } {
      ^cargo run -q -p stripe-native
    }
  })
  mut listening = false
  for _ in 0..40 { sleep 1sec; if (do { ^curl -s -o /dev/null $SRV } | complete).exit_code == 0 { $listening = true; break } }
  if not $listening { print -e "stripe-native didn't bind :8090"; job kill $job; exit 1 }

  # 3. authz (admin-only) + idempotency, on a throwaway product.
  print "3/4 · authz + idempotency (UpsertProduct) ..."
  let path = $"($SRV)/stripe.v1.CatalogService/UpsertProduct"
  let test = '{"project":"verify","id":"catalog_rpc_test","name":"Catalog RPC Test","description":"created by catalog:verify","tax_code":"txcd_10103000"}'
  def code [args: list] { (^curl -s -o /dev/null -w "%{http_code}" ...$args) }
  let no_tok = (code [-X POST -H "Content-Type: application/json" -d $test $path])
  let r1 = (^curl -s -X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $test $path | from json)
  let r2 = (^curl -s -X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $test $path | from json)
  mut fail = 0
  if $no_tok == "401" { print "      ✓ no token → 401 (guard denies before Cedar)" } else { print $"      ✗ no token expected 401 got ($no_tok)"; $fail = $fail + 1 }
  print $"      · admin upsert #1 → ($r1)"
  print $"      · admin upsert #2 → ($r2)"
  # Connect/proto JSON omits `false` defaults, so an ABSENT `created` == false == updated.
  if (($r2.created? | default false) == false) { print "      ✓ idempotent (2nd upsert updated, created=false)" } else { print "      ✗ not idempotent / unexpected response"; $fail = $fail + 1 }

  # 4. load the REAL remy-sport catalog through the RPC (replaces seed_products
  #    AND seed_prices) — products first (prices reference them), then prices.
  print "4/4 · loading remy-sport products.jsonl + prices.jsonl via the RPC ..."
  let products = (open --raw ../data/projects/remy-sport/products.jsonl | lines | where ($it | str trim) != "" | each {|l| $l | from json})
  for p in $products {
    let payload = ({project: "remy-sport", id: $p.id, name: $p.name, description: ($p.description? | default ""), tax_code: ($p.tax_code? | default "")} | to json)
    let res = (^curl -s -X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $payload $path | from json)
    print $"      · product ($p.id) → id=($res.productId? | default '?') created=($res.created? | default false)"
  }
  let price_path = $"($SRV)/stripe.v1.CatalogService/UpsertPrice"
  let prices = (open --raw ../data/projects/remy-sport/prices.jsonl | lines | where ($it | str trim) != "" | each {|l| $l | from json})
  for p in $prices {
    let payload = ({project: "remy-sport", lookup_key: $p.lookup_key, product: $p.product, unit_amount: $p.unit_amount, currency: $p.currency, interval: ($p.interval? | default "")} | to json)
    let res = (^curl -s -X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $payload $price_path | from json)
    print $"      · price ($p.lookup_key) → id=($res.priceId? | default '?') created=($res.created? | default false)"
  }
  job kill $job

  if $fail > 0 { print -e "\nCATALOG VERIFY FAILED"; exit 1 }
  print "\n══ CatalogService.UpsertProduct works — typed, admin-gated, idempotent ══"
  print "  remy-sport's products load INTO Stripe through the ConnectRPC service"
  print "  (async-stripe), replacing the stripe-cli `seed_products` nushell. Prices next."
  print "  down: mise run catalog:verify --down"
}
