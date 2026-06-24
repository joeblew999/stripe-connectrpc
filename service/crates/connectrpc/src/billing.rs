//! `BillingService` — the subscription/billing lifecycle ops a consuming app
//! needs after checkout. Same typed async-stripe pattern as checkout/catalog.

use connectrpc::{ConnectError, RequestContext, Response, ServiceRequest, ServiceResult};
use stripe_billing::billing_portal_session::CreateBillingPortalSession;
use stripe_billing::invoice::ListInvoice;
use stripe_billing::subscription::{CancelSubscription, ListSubscription};
use stripe_core::customer::{RetrieveCustomer, RetrieveCustomerReturned};
use stripe_core::refund::CreateRefund;

use crate::client::StripeBackend;
use crate::proto::stripe::v1::{
    BillingService, CancelSubscriptionRequest, CancelSubscriptionResponse, CreateBillingPortalRequest,
    CreateBillingPortalResponse, CreateRefundRequest, CreateRefundResponse, GetCustomerRequest,
    GetCustomerResponse, Invoice, ListInvoicesRequest, ListInvoicesResponse,
    ListSubscriptionsRequest, ListSubscriptionsResponse, Subscription,
};

// Same worker/native await bridge as the other handlers.
#[cfg(feature = "worker")]
macro_rules! exec_await {
    ($e:expr) => {{ ::worker::send::IntoSendFuture::into_send($e).await }};
}
#[cfg(not(feature = "worker"))]
macro_rules! exec_await {
    ($e:expr) => {{ $e.await }};
}

/// ConnectRPC billing-lifecycle service backed by a Stripe transport.
pub struct BillingServer {
    client: StripeBackend,
}

impl BillingServer {
    #[must_use]
    pub const fn new(client: StripeBackend) -> Self {
        Self { client }
    }
}

impl BillingService for BillingServer {
    async fn create_billing_portal(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, CreateBillingPortalRequest>,
    ) -> ServiceResult<CreateBillingPortalResponse> {
        if request.customer.is_empty() || request.return_url.is_empty() {
            return Err(ConnectError::invalid_argument(
                "customer and return_url are required",
            ));
        }

        let session = exec_await!(CreateBillingPortalSession::new()
            .customer(request.customer.to_string())
            .return_url(request.return_url.to_string())
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe create billing portal: {e}")))?;

        Ok(Response::new(CreateBillingPortalResponse {
            url: session.url,
            ..Default::default()
        }))
    }

    async fn list_subscriptions(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, ListSubscriptionsRequest>,
    ) -> ServiceResult<ListSubscriptionsResponse> {
        if request.customer.is_empty() {
            return Err(ConnectError::invalid_argument("customer is required"));
        }
        let list = exec_await!(ListSubscription::new()
            .customer(request.customer.to_string())
            .limit(100)
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe list subscriptions: {e}")))?;

        let subscriptions = list
            .data
            .into_iter()
            .map(|s| Subscription {
                id: s.id.to_string(),
                status: s.status.as_str().to_string(),
                ..Default::default()
            })
            .collect();
        Ok(Response::new(ListSubscriptionsResponse {
            subscriptions,
            ..Default::default()
        }))
    }

    async fn cancel_subscription(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, CancelSubscriptionRequest>,
    ) -> ServiceResult<CancelSubscriptionResponse> {
        if request.subscription.is_empty() {
            return Err(ConnectError::invalid_argument("subscription is required"));
        }
        let sub = exec_await!(CancelSubscription::new(request.subscription.to_string())
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe cancel subscription: {e}")))?;

        Ok(Response::new(CancelSubscriptionResponse {
            id: sub.id.to_string(),
            status: sub.status.as_str().to_string(),
            ..Default::default()
        }))
    }

    async fn list_invoices(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, ListInvoicesRequest>,
    ) -> ServiceResult<ListInvoicesResponse> {
        if request.customer.is_empty() {
            return Err(ConnectError::invalid_argument("customer is required"));
        }
        let list = exec_await!(ListInvoice::new()
            .customer(request.customer.to_string())
            .limit(100)
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe list invoices: {e}")))?;

        let invoices = list
            .data
            .into_iter()
            .map(|i| Invoice {
                id: i.id.map(|x| x.to_string()).unwrap_or_default(),
                status: i.status.map(|s| s.as_str().to_string()).unwrap_or_default(),
                total: i.total,
                number: i.number.unwrap_or_default(),
                hosted_invoice_url: i.hosted_invoice_url.unwrap_or_default(),
                ..Default::default()
            })
            .collect();
        Ok(Response::new(ListInvoicesResponse {
            invoices,
            ..Default::default()
        }))
    }

    async fn get_customer(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, GetCustomerRequest>,
    ) -> ServiceResult<GetCustomerResponse> {
        if request.customer.is_empty() {
            return Err(ConnectError::invalid_argument("customer is required"));
        }
        let returned =
            exec_await!(RetrieveCustomer::new(request.customer.to_string()).send(&self.client))
                .map_err(|e| ConnectError::internal(format!("stripe get customer: {e}")))?;
        // Retrieve can return a deleted customer (id only).
        let resp = match returned {
            RetrieveCustomerReturned::Customer(c) => GetCustomerResponse {
                id: c.id.to_string(),
                email: c.email.unwrap_or_default(),
                name: c.name.unwrap_or_default(),
                ..Default::default()
            },
            RetrieveCustomerReturned::DeletedCustomer(d) => GetCustomerResponse {
                id: d.id.to_string(),
                ..Default::default()
            },
        };
        Ok(Response::new(resp))
    }

    async fn create_refund(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, CreateRefundRequest>,
    ) -> ServiceResult<CreateRefundResponse> {
        if request.payment_intent.is_empty() && request.charge.is_empty() {
            return Err(ConnectError::invalid_argument(
                "one of payment_intent or charge is required",
            ));
        }
        let mut refund = CreateRefund::new();
        if !request.payment_intent.is_empty() {
            refund = refund.payment_intent(request.payment_intent.to_string());
        }
        if !request.charge.is_empty() {
            refund = refund.charge(request.charge.to_string());
        }
        if request.amount > 0 {
            refund = refund.amount(request.amount);
        }
        let r = exec_await!(refund.send(&self.client))
            .map_err(|e| ConnectError::internal(format!("stripe create refund: {e}")))?;
        Ok(Response::new(CreateRefundResponse {
            id: r.id.to_string(),
            status: r.status.unwrap_or_default(),
            amount: r.amount,
            ..Default::default()
        }))
    }
}
