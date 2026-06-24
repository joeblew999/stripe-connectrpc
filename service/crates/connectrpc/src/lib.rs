//! stripe ConnectRPC — a slim, typed facade over async-stripe that runs on
//! Cloudflare Workers (`worker`) and native tokio/hyper (`native`).
//!
//! Pattern lifted from joeblew999/google_maps feat/cloudflare-workers.

#![allow(refining_impl_trait)]

pub mod proto {
    connectrpc::include_generated!();
}

// Always available (incl. for client-only consumers generating typed clients).
pub use proto::stripe::v1::{
    BillingServiceClient, CancelSubscriptionRequest, CancelSubscriptionResponse,
    CatalogServiceClient, CheckoutServiceClient, CreateBillingPortalRequest,
    CreateBillingPortalResponse, CreateCheckoutSessionRequest, CreateCheckoutSessionResponse,
    CreateRefundRequest, CreateRefundResponse, GetCustomerRequest, GetCustomerResponse, Invoice,
    ListInvoicesRequest, ListInvoicesResponse, ListSubscriptionsRequest, ListSubscriptionsResponse,
    Subscription, UpsertPriceRequest, UpsertPriceResponse, UpsertProductRequest,
    UpsertProductResponse,
};
// SigmaService — the read/analytics surface (ADR-14). Proto + typed client land
// now; the server impl arrives with the resource-table mirror it reads from.
pub use proto::stripe::v1::{
    GetSyncStatusRequest, GetSyncStatusResponse, ListTablesRequest, ListTablesResponse, Row,
    RunQueryRequest, RunQueryResponse, SigmaServiceClient, Table, TableStatus,
};

pub mod client;
pub use client::{StripeBackend, StripeError};

// The Stripe -> SQLite mirror (ADR-14): runtime-agnostic resource tables behind
// the SqlExec trait. The DO (CF) and native both feed it. Server-side only.
#[cfg(feature = "_server")]
pub mod mirror;

// Server side (CF or native).
#[cfg(feature = "_server")]
pub use proto::stripe::v1::{BillingServiceExt, CatalogServiceExt, CheckoutServiceExt};
#[cfg(feature = "_server")]
mod server;
#[cfg(feature = "_server")]
pub use server::CheckoutServer;
#[cfg(feature = "_server")]
mod catalog;
#[cfg(feature = "_server")]
pub use catalog::CatalogServer;
#[cfg(feature = "_server")]
mod billing;
#[cfg(feature = "_server")]
pub use billing::BillingServer;
// Stripe webhook ingestion (signature verify + parse) — sits OUTSIDE the guard
// (Stripe authenticates via HMAC signature, not a Rauthy token).
#[cfg(feature = "_server")]
mod webhook;
#[cfg(feature = "_server")]
pub use webhook::{verify_event, WebhookEvent};
// Auth/authz is the SHARED Rauthy-OIDC → Cedar guard, adopted from
// cf-connectrpc-middleware (NOT a per-app TokenAuthLayer). Hosts build the
// JwksVerifier and call `guard`.
#[cfg(feature = "_server")]
mod guard;
#[cfg(feature = "_server")]
pub use guard::{authorizer, guard, JwksVerifier};
