# Upstream dependency tracking

The gateway layers over a few fast-moving upstreams. A pin is a **snapshot**, not
a freeze — upgrade when they move and it buys us something. This file is the map.

_Last checked: 2026-10-22._

## ConnectRPC stack

| Dep | We pin | Latest published | Source | Notes |
|---|---|---|---|---|
| `connectrpc` | **0.9.1** | **0.9.1** (2026-09-21) | [anthropics/connect-rust](https://github.com/anthropics/connect-rust) | The Tower-based protocol + server/router. Since 0.8 the JSON codec is the opt-in `json` feature: the serving hosts (`native/`, `worker/`) add `features = ["json"]` to `default-features = false`, else every `application/json` request is HTTP 415 (guarded by native's `connect_json_request_is_served` test). |
| `buffa` | **0.9.2** | **0.9.2** (2026-09-03) | [anthropics/buffa](https://github.com/anthropics/buffa) | The protobuf codegen lib. **Do NOT bump unilaterally** — it moves in lockstep with `connectrpc` (0.9.1 pulls buffa 0.9); mixing minors splits versions and breaks generated code. |
| `connectrpc-build` | **0.9.0** | 0.9.0 | anthropics/connect-rust | build.rs codegen; moves with `connectrpc`. |
| `connectrpc-guard` (+ `-oidc`) | git rev `58a3781` | — | [cf-connectrpc-middleware](https://github.com/joeblew999/cf-connectrpc-middleware) | The shared auth/authz layer. Itself pins `connectrpc = "0.9.1"`. |
| `worker` (+ `worker-macros`) | **0.8.7** | 0.8.7 (2026-09-25) | [cloudflare/workers-rs](https://github.com/cloudflare/workers-rs) | Paired with `worker-build =0.8.7` (wrangler.toml). That always passes `--force-enable-abort-handler`, so the release profile must not fully `strip` (see `service/Cargo.toml`). |

## How much does cf-connectrpc-middleware insulate us?

**Auth/authz only — not the protocol or codegen.**

- **Wrapped** (absorbed in the middleware, re-exported): `JwksVerifier`, `Session`,
  `CedarAuthorizer`, the guard, CF tracing/metrics/rate-limit. The 0.4→0.6→0.7
  `RequestContext`/`Session` churn landed there, not here.
- **NOT wrapped** (stripe imports straight from `connectrpc`): `ServiceRequest`,
  `RequestContext`, `ConnectError`, `Response`, `ServiceResult`,
  `ConnectRpcService`, `Router`, `register`, `ConnectRpcBody`.
- **Can't be wrapped**: codegen — `connectrpc-build` + `buffa` + `include_generated!()`
  run in *our* `build.rs` against *our* protos, generating code against connectrpc
  types directly. Every consumer touches this.

The middleware also pins `connectrpc = "0.9.1"` directly (its workspace), so it
*shares* the version rather than hiding it. A bump touches both repos.

### Deferred decision — "middleware owns connectrpc"
Re-exporting the connectrpc **runtime** surface from the middleware so consumers
import it from one place was considered (2026-06-28) and **deferred**: marginal
benefit (the codegen pin still lives here and moves in lockstep) for a
high-blast-radius change to the shared foundation, with no forced migration.
The 0.7→0.9 bump (2026-10-22) kept the direct imports; still deferred.

## Upgrade order for a connectrpc bump
1. Bump the **middleware** workspace `connectrpc`/`buffa` → re-release it.
2. Bump stripe's `connectrpc` / `buffa` / `connectrpc-build` + the
   `connectrpc-guard` rev. The lockfile must resolve exactly ONE `connectrpc`.
3. `cargo build` (regenerates) → fix the handler-signature delta (the 0.6→0.7
   change was `OwnedView` → `ServiceRequest<'_, T>`; 0.7→0.9 needed no handler
   change here, only the `json` feature and a `S::Future: Send` bound the
   middleware's `guard` now requires).
4. Re-run `catalog:verify` / `rauthy:verify` on both targets.
