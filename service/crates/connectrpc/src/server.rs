//! The ConnectRPC server: `CheckoutServer` impl of the generated
//! `CheckoutService` trait. Mirrors google_maps' server/mod.rs — handlers are
//! transport-agnostic; the worker/native split is the one-line `exec_await!`.

use std::collections::HashMap;

use connectrpc::{ConnectError, RequestContext, Response, ServiceRequest, ServiceResult};
use stripe_checkout::checkout_session::{CreateCheckoutSession, CreateCheckoutSessionLineItems};
use stripe_product::price::ListPrice;

use crate::client::StripeBackend;
use crate::proto::stripe::v1::{
    CheckoutService, CreateCheckoutSessionRequest, CreateCheckoutSessionResponse,
};

// The worker/native bridge: worker::Fetch futures are !Send, so on CF we wrap
// with IntoSendFuture; natively a plain .await. (Copied from google_maps.)
#[cfg(feature = "worker")]
macro_rules! exec_await {
    ($e:expr) => {{ ::worker::send::IntoSendFuture::into_send($e).await }};
}
#[cfg(not(feature = "worker"))]
macro_rules! exec_await {
    ($e:expr) => {{ $e.await }};
}

/// ConnectRPC service backed by a Stripe transport.
pub struct CheckoutServer {
    client: StripeBackend,
}

impl CheckoutServer {
    #[must_use]
    pub const fn new(client: StripeBackend) -> Self {
        Self { client }
    }
}

impl CheckoutService for CheckoutServer {
    async fn create_checkout_session(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, CreateCheckoutSessionRequest>,
    ) -> ServiceResult<CreateCheckoutSessionResponse> {
        if request.lookup_key.is_empty() || request.success_url.is_empty() {
            return Err(ConnectError::invalid_argument(
                "lookup_key and success_url are required",
            ));
        }

        // 1. Resolve the price by its lookup_key (the project's prices.jsonl key).
        let prices = exec_await!(ListPrice::new()
            .active(true)
            .lookup_keys(vec![request.lookup_key.to_string()])
            .limit(1)
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe list prices: {e}")))?;

        let price = prices.data.into_iter().next().ok_or_else(|| {
            ConnectError::not_found(format!(
                "no active price with lookup_key '{}'",
                request.lookup_key
            ))
        })?;

        // 2. Mode follows the price: recurring → subscription, else one-off payment.
        let mode = if price.recurring.is_some() {
            stripe_shared::CheckoutSessionMode::Subscription
        } else {
            stripe_shared::CheckoutSessionMode::Payment
        };

        // 3. One line item for that price.
        let mut item = CreateCheckoutSessionLineItems::new();
        item.price = Some(price.id.to_string());
        item.quantity = Some(1);

        // 4. Scope the session to the project (multi-tenancy under one account).
        let mut metadata = HashMap::new();
        metadata.insert("project".to_string(), request.project.to_string());

        // 5. Build + create the hosted Checkout Session.
        let mut create = CreateCheckoutSession::new()
            .line_items(vec![item])
            .mode(mode)
            .success_url(request.success_url)
            .metadata(metadata);
        if !request.cancel_url.is_empty() {
            create = create.cancel_url(request.cancel_url);
        }
        if !request.customer_email.is_empty() {
            create = create.customer_email(request.customer_email);
        }

        let session = exec_await!(create.send(&self.client))
            .map_err(|e| ConnectError::internal(format!("stripe create session: {e}")))?;

        Ok(Response::new(CreateCheckoutSessionResponse {
            session_id: session.id.to_string(),
            url: session.url.unwrap_or_default(),
            ..Default::default()
        }))
    }
}
