//! `CatalogService` — typed, idempotent Stripe provisioning. The replacement
//! for the stripe-cli nushell loaders (`scripts/bootstrap/apply.nu`): the same
//! retrieve-by-id → create/update + `metadata.project` tagging, but in Rust via
//! async-stripe, running on CF or native, behind the Cedar admin policy.

use std::collections::HashMap;

use connectrpc::{ConnectError, RequestContext, Response, ServiceRequest, ServiceResult};
use stripe_product::price::{
    CreatePrice, CreatePriceRecurring, CreatePriceRecurringInterval, ListPrice, UpdatePrice,
};
use stripe_product::product::{CreateProduct, RetrieveProduct, UpdateProduct};

use crate::client::StripeBackend;
use crate::proto::stripe::v1::{
    CatalogService, UpsertPriceRequest, UpsertPriceResponse, UpsertProductRequest,
    UpsertProductResponse,
};

// Same worker/native bridge as server.rs: worker::Fetch futures are !Send.
#[cfg(feature = "worker")]
macro_rules! exec_await {
    ($e:expr) => {{ ::worker::send::IntoSendFuture::into_send($e).await }};
}
#[cfg(not(feature = "worker"))]
macro_rules! exec_await {
    ($e:expr) => {{ $e.await }};
}

/// ConnectRPC provisioning service backed by a Stripe transport.
pub struct CatalogServer {
    client: StripeBackend,
}

impl CatalogServer {
    #[must_use]
    pub const fn new(client: StripeBackend) -> Self {
        Self { client }
    }
}

impl CatalogService for CatalogServer {
    async fn upsert_product(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, UpsertProductRequest>,
    ) -> ServiceResult<UpsertProductResponse> {
        if request.id.is_empty() || request.name.is_empty() {
            return Err(ConnectError::invalid_argument("id and name are required"));
        }

        // metadata.project = the multi-tenant isolation tag (every product
        // carries which project owns it).
        let mut metadata = HashMap::new();
        metadata.insert("project".to_string(), request.project.to_string());

        // Idempotency by stable id (mirrors `stripe products retrieve <id>`).
        let exists =
            exec_await!(RetrieveProduct::new(request.id.to_string()).send(&self.client)).is_ok();

        if exists {
            // Ensure name/description/tax_code + metadata.project + active=true.
            let mut upd = UpdateProduct::new(request.id.to_string())
                .active(true)
                .name(request.name.to_string())
                .metadata(metadata);
            if !request.description.is_empty() {
                upd = upd.description(request.description.to_string());
            }
            if !request.tax_code.is_empty() {
                upd = upd.tax_code(request.tax_code.to_string());
            }
            let p = exec_await!(upd.send(&self.client))
                .map_err(|e| ConnectError::internal(format!("stripe update product: {e}")))?;
            Ok(Response::new(UpsertProductResponse {
                product_id: p.id.to_string(),
                created: false,
                ..Default::default()
            }))
        } else {
            let mut create = CreateProduct::new(request.name.to_string())
                .id(request.id.to_string())
                .active(true)
                .metadata(metadata);
            if !request.description.is_empty() {
                create = create.description(request.description.to_string());
            }
            if !request.tax_code.is_empty() {
                create = create.tax_code(request.tax_code.to_string());
            }
            let p = exec_await!(create.send(&self.client))
                .map_err(|e| ConnectError::internal(format!("stripe create product: {e}")))?;
            Ok(Response::new(UpsertProductResponse {
                product_id: p.id.to_string(),
                created: true,
                ..Default::default()
            }))
        }
    }

    async fn upsert_price(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, UpsertPriceRequest>,
    ) -> ServiceResult<UpsertPriceResponse> {
        if request.lookup_key.is_empty() || request.product.is_empty() {
            return Err(ConnectError::invalid_argument(
                "lookup_key and product are required",
            ));
        }

        let mut metadata = HashMap::new();
        metadata.insert("project".to_string(), request.project.to_string());

        // Idempotency by lookup_key (mirrors `stripe prices list --lookup-keys`).
        let existing = exec_await!(ListPrice::new()
            .lookup_keys(vec![request.lookup_key.to_string()])
            .limit(1)
            .send(&self.client))
        .map_err(|e| ConnectError::internal(format!("stripe list prices: {e}")))?;

        if let Some(price) = existing.data.into_iter().next() {
            // Amount/currency/interval are immutable in Stripe — only ensure the
            // price is active + tagged with metadata.project.
            let p = exec_await!(UpdatePrice::new(price.id)
                .active(true)
                .metadata(metadata)
                .send(&self.client))
            .map_err(|e| ConnectError::internal(format!("stripe update price: {e}")))?;
            Ok(Response::new(UpsertPriceResponse {
                price_id: p.id.to_string(),
                created: false,
                ..Default::default()
            }))
        } else {
            let currency = request
                .currency
                .parse::<stripe_types::Currency>()
                .map_err(|_| ConnectError::invalid_argument("unknown currency"))?;
            let mut create = CreatePrice::new(currency)
                .product(request.product.to_string())
                .unit_amount(request.unit_amount)
                .lookup_key(request.lookup_key.to_string())
                .metadata(metadata)
                .active(true);
            if !request.interval.is_empty() {
                let interval = match request.interval {
                    "day" => CreatePriceRecurringInterval::Day,
                    "week" => CreatePriceRecurringInterval::Week,
                    "month" => CreatePriceRecurringInterval::Month,
                    "year" => CreatePriceRecurringInterval::Year,
                    other => {
                        return Err(ConnectError::invalid_argument(format!(
                            "unknown interval '{other}'"
                        )))
                    }
                };
                create = create.recurring(CreatePriceRecurring::new(interval));
            }
            let p = exec_await!(create.send(&self.client))
                .map_err(|e| ConnectError::internal(format!("stripe create price: {e}")))?;
            Ok(Response::new(UpsertPriceResponse {
                price_id: p.id.to_string(),
                created: true,
                ..Default::default()
            }))
        }
    }
}
