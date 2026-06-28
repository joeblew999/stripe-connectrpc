# Upstream dependency tracking

The gateway layers over a few fast-moving upstreams. A pin is a **snapshot**, not
a freeze — upgrade when they move and it buys us something. This file is the map.

_Last checked: 2026-06-28._

## ConnectRPC stack

| Dep | We pin | Latest published | Source | Notes |
|---|---|---|---|---|
| `connectrpc` | **0.7** | **0.7.0** (2026-06-10) | [anthropics/connect-rust](https://github.com/anthropics/connect-rust) | The Tower-based protocol + server/router. Published crate is **unchanged** since our build. `main` is busy but **additive** (HTTP/2 keepalive, flow-control, timeout clamping, `with_max_concurrent_streams`) — no 0.8 tag yet, no API break. |
| `buffa` | **0.7** | **0.8.0** (2026-06-25) | [anthropics/buffa](https://github.com/anthropics/buffa) | The protobuf codegen lib. **Do NOT bump unilaterally** — 0.8 ("first-class editions") pairs with a future `connectrpc` 0.8; mixing buffa 0.8 with connectrpc 0.7 (which pulls buffa 0.7) splits versions and breaks generated code. |
| `connectrpc-build` | **0.7** | 0.7.0 | anthropics/connect-rust | build.rs codegen; moves with `connectrpc`. |
| `connectrpc-guard` (+ `-oidc`) | git rev `f4c15cb` | — | [cf-connectrpc-middleware](https://github.com/joeblew999/cf-connectrpc-middleware) | The shared auth/authz layer. Itself pins `connectrpc = "0.7"`. |

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

The middleware also pins `connectrpc = "0.7"` directly (its workspace), so it
*shares* the version rather than hiding it. A bump touches both repos.

### Deferred decision — "middleware owns connectrpc"
Re-exporting the connectrpc **runtime** surface from the middleware so consumers
import it from one place was considered (2026-06-28) and **deferred**: marginal
benefit (the codegen pin still lives here and moves in lockstep) for a
high-blast-radius change to the shared foundation, with no forced migration.
Revisit at the connectrpc 0.8 migration — that's the natural moment.

## Upgrade order when connectrpc 0.8 (with buffa 0.8) ships
1. Bump the **middleware** workspace `connectrpc`/`buffa` → re-release it.
2. Bump stripe's `connectrpc` / `buffa` / `connectrpc-build` + the
   `connectrpc-guard` rev.
3. `cargo build` (regenerates) → fix the handler-signature delta (the 0.6→0.7
   change was `OwnedView` → `ServiceRequest<'_, T>`; expect a similar one).
4. Re-run `catalog:verify` / `rauthy:verify` on both targets.
