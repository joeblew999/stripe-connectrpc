//! stripe-connectrpc's adoption of the shared `connectrpc-guard`. The guard
//! composition (OidcLayer → CedarLayer) and the Session→Cedar extractor live in
//! the middleware now — this file holds ONLY what's stripe's: its Cedar policy
//! files + its resource name. That's the "auth/authz for free" contract.

use std::convert::Infallible;
use std::sync::{Arc, OnceLock};

use connectrpc::ConnectRpcBody;
use connectrpc_guard::CedarAuthorizer;
use http::Response;
use tower::Service;

// Re-export so the hosts name the verifier without a direct connectrpc-oidc dep.
pub use connectrpc_guard::JwksVerifier;

/// The Cedar authorizer, loaded once from the bundled stripe policies.
pub fn authorizer() -> Arc<CedarAuthorizer> {
    static A: OnceLock<Arc<CedarAuthorizer>> = OnceLock::new();
    A.get_or_init(|| {
        connectrpc_guard::load_authorizer(
            include_str!("../policies/stripe.cedarschema"),
            include_str!("../policies/stripe.cedar"),
        )
        .expect("bundled stripe policies must load")
    })
    .clone()
}

/// Wrap a ConnectRPC service with the shared guard, parameterised for stripe:
/// stripe's policies, resource `Api::"stripe"`, and `/health` public. The hosts
/// (worker + native) build the `JwksVerifier` and call this — nothing else.
pub fn guard<S, B>(
    verifier: Arc<JwksVerifier>,
    inner: S,
) -> impl Service<http::Request<B>, Response = Response<ConnectRpcBody>, Error = Infallible> + Clone
where
    S: Service<http::Request<B>, Response = Response<ConnectRpcBody>, Error = Infallible> + Clone,
    B: 'static,
{
    connectrpc_guard::guard(verifier, authorizer(), "stripe", &["/health"], inner)
}
