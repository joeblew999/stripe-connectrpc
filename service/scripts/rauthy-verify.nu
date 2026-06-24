#!/usr/bin/env nu
# Prove stripe-connectrpc works behind the shared Rauthy → Cedar guard, locally.
# Reuses vm-uncloud's Rauthy (the ONE IdP runner — the SSOT) exactly like
# cf-connectrpc-middleware's `stack:local`, but drives stripe's CheckoutService
# (stripe-native, :8090) instead of the demo server. Password grant here = the
# same token the kit's Kumo login form mints; the PKCE/passkey flow yields the
# identical JWT, so the guard treats them the same.
#
#   mise run rauthy:verify          # up + verify (leaves Rauthy up to poke)
#   mise run rauthy:verify --down   # tear down
#
# Needs Docker + ../../vm-uncloud. STRIPE_SECRET_KEY comes from fnox (the task
# wraps this in `fnox exec`); the auth assertions hold regardless of Stripe.

const VMU = "../../vm-uncloud"
const RAUTHY = "http://localhost:8080"
const ISSUER = "http://localhost:8080/auth/v1/"
const SRV = "http://127.0.0.1:8090"
const PW = "LocalDevAdminPassword123456"

def main [--down] {
  if $down {
    print "tearing down ..."
    do { ^pkill -f stripe-native } | complete | ignore
    do { cd $VMU; ^mise run recipe:local rauthy --down } | complete | ignore
    print "down."
    return
  }
  if not ($VMU | path exists) { print -e $"missing ($VMU) — clone vm-uncloud next to stripe-connectrpc/"; exit 1 }

  # 1. Rauthy — the ONE IdP runner (reused, not duplicated)
  print "1/4 · Rauthy (vm-uncloud recipe:local) ..."
  do { cd $VMU; ^mise run recipe:local rauthy --down } | complete | ignore
  let up = (do { cd $VMU; ^mise run recipe:local rauthy } | complete)
  let secret = ($up.stdout ++ $up.stderr | lines
    | where ($it =~ "worker-client' secret:")
    | get 0? | default "" | parse -r "secret: (?<s>[A-Za-z0-9]+)" | get s.0? | default "")
  if ($secret | is-empty) { print -e "could not capture worker-client secret"; exit 1 }
  mut ready = false
  for _ in 0..30 { sleep 2sec; if (do { ^curl -fsS $"($RAUTHY)/auth/v1/.well-known/openid-configuration" } | complete).exit_code == 0 { $ready = true; break } }
  if not $ready { print -e "Rauthy didn't come up"; exit 1 }
  print "      ✓ Rauthy up + worker-client bootstrapped"

  # 2. mint a REAL user token (password grant)
  print "2/4 · minting a real user token ..."
  let body = $"grant_type=password&client_id=worker-client&client_secret=($secret)&username=admin@localhost&password=($PW)&scope=openid profile groups"
  let token = (^curl -fsS -X POST $"($RAUTHY)/auth/v1/oidc/token" -d $body | from json | get access_token)
  print "      ✓ token minted"

  # 3. stripe-native behind the guard (same crates/policies as the CF worker)
  print "3/4 · stripe-native (behind the Rauthy→Cedar guard) ..."
  ^cargo build -q -p stripe-native
  let job = (job spawn {||
    with-env { RAUTHY_ISSUER: $ISSUER, RAUTHY_JWKS_URL: $"($RAUTHY)/auth/v1/oidc/certs", RAUTHY_AUD: "worker-client", PORT: "8090" } {
      ^cargo run -q -p stripe-native
    }
  })
  mut listening = false
  for _ in 0..40 { sleep 1sec; if (do { ^curl -s -o /dev/null $SRV } | complete).exit_code == 0 { $listening = true; break } }
  if not $listening { print -e "stripe-native didn't bind :8090"; job kill $job; exit 1 }

  # 4. drive CheckoutService through the guard
  print "4/4 · driving CheckoutService through Rauthy → Cedar ..."
  let path = $"($SRV)/stripe.v1.CheckoutService/CreateCheckoutSession"
  let payload = '{"project":"verify","lookup_key":"verify-test","success_url":"https://example.com/ok","cancel_url":"https://example.com/no"}'
  def code [args: list] { (^curl -s -o /dev/null -w "%{http_code}" ...$args) }
  let no_tok = (code [-X POST -H "Content-Type: application/json" -d $payload $path])
  let bad_tok = (code [-X POST -H "Content-Type: application/json" -H "Authorization: Bearer not.a.real.jwt" -d $payload $path])
  let with_tok = (code [-X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $payload $path])
  let with_body = (^curl -s -X POST -H "Content-Type: application/json" -H $"Authorization: Bearer ($token)" -d $payload $path)

  mut fail = 0
  if $no_tok == "401" { print "      ✓ no token        → guard denies   [401]" } else { print $"      ✗ no token: expected 401 got ($no_tok)"; $fail = $fail + 1 }
  if $bad_tok == "401" { print "      ✓ garbage token   → guard denies   [401]" } else { print $"      ✗ garbage token: expected 401 got ($bad_tok)"; $fail = $fail + 1 }
  if $with_tok != "401" { print $"      ✓ real Rauthy tok → guard ADMITS  [($with_tok)]" } else { print "      ✗ real token was rejected by the guard [401]"; $fail = $fail + 1 }
  print $"      · handler response: ($with_body | str substring 0..220)"
  job kill $job

  if $fail > 0 { print -e "\nRAUTHY VERIFY FAILED"; exit 1 }
  print "\n══ stripe-connectrpc works behind Rauthy ══"
  print "  no/garbage token → 401 (guard); a real Rauthy token is admitted to the Stripe handler."
  print "  (handler then calls Stripe — 200 + cs_ URL if STRIPE_SECRET_KEY + lookup_key resolve; a Stripe"
  print "   error otherwise, but NOT an auth error — that's the proof the AuthN/Z layer passed.)"
  print "  down: mise run rauthy:verify --down"
}
