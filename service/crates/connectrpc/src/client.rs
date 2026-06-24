//! StripeClient transport for async-stripe — feature-gated per target.
//!   feature "worker" → worker::Fetch (Cloudflare / wasm32)
//!   feature "native" → reqwest (tokio / hyper)
//! Same `StripeBackend` type either way; only the `execute` body differs, so the
//! handlers are transport-agnostic.

use bytes::Bytes;
use std::fmt::Display;
use std::future::Future;
use stripe_client_core::{CustomizedStripeRequest, StripeClient, StripeClientErr, StripeMethod};

const STRIPE_API_BASE: &str = "https://api.stripe.com/v1";

/// A Stripe client over whichever transport the active feature selects.
#[derive(Clone)]
pub struct StripeBackend {
    secret: String,
}

impl StripeBackend {
    /// Build from a Stripe secret (`sk_…`) or restricted (`rk_…`) key.
    pub fn new(secret: impl Into<String>) -> Self {
        Self { secret: secret.into() }
    }
}

/// Error type for the Stripe transport.
#[derive(Debug)]
pub struct StripeError(pub String);

impl Display for StripeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl StripeClientErr for StripeError {
    fn deserialize_err(msg: impl Display) -> Self {
        StripeError(format!("deserialize error: {msg}"))
    }
}

// ---- Cloudflare Workers backend (worker::Fetch; !Send→Send via SendFuture) ----
#[cfg(feature = "worker")]
mod worker_impl {
    use super::{
        Bytes, CustomizedStripeRequest, Future, StripeBackend, StripeClient, StripeError,
        StripeMethod, STRIPE_API_BASE,
    };
    use worker::send::SendFuture;
    use worker::wasm_bindgen::JsValue;
    use worker::{Fetch, Headers, Method, Request, RequestInit};

    impl From<worker::Error> for StripeError {
        fn from(e: worker::Error) -> Self {
            StripeError(format!("worker fetch error: {e}"))
        }
    }

    impl StripeClient for StripeBackend {
        type Err = StripeError;

        fn execute(
            &self,
            req: CustomizedStripeRequest,
        ) -> impl Future<Output = Result<Bytes, Self::Err>> + Send {
            let secret = self.secret.clone();
            SendFuture::new(async move {
                let (rb, _config) = req.into_pieces();
                let mut url = format!("{STRIPE_API_BASE}{}", rb.path);
                if let Some(q) = rb.query.as_ref() {
                    url.push('?');
                    url.push_str(q);
                }
                let method = match rb.method {
                    StripeMethod::Get => Method::Get,
                    StripeMethod::Post => Method::Post,
                    StripeMethod::Delete => Method::Delete,
                };
                let headers = Headers::new();
                headers.set("Authorization", &format!("Bearer {secret}"))?;
                if rb.body.is_some() {
                    headers.set("Content-Type", "application/x-www-form-urlencoded")?;
                }
                let mut init = RequestInit::new();
                init.with_method(method).with_headers(headers);
                if let Some(body) = rb.body {
                    init.with_body(Some(JsValue::from_str(&body)));
                }
                let request = Request::new_with_init(&url, &init)?;
                let mut resp = Fetch::Request(request).send().await?;
                let bytes = resp.bytes().await?;
                Ok(Bytes::from(bytes))
            })
        }
    }
}

// ---- Native backend (reqwest; futures are already Send) ----
#[cfg(feature = "native")]
mod native_impl {
    use super::{
        Bytes, CustomizedStripeRequest, Future, StripeBackend, StripeClient, StripeError,
        StripeMethod, STRIPE_API_BASE,
    };

    impl StripeClient for StripeBackend {
        type Err = StripeError;

        fn execute(
            &self,
            req: CustomizedStripeRequest,
        ) -> impl Future<Output = Result<Bytes, Self::Err>> + Send {
            let secret = self.secret.clone();
            async move {
                let (rb, _config) = req.into_pieces();
                let mut url = format!("{STRIPE_API_BASE}{}", rb.path);
                if let Some(q) = rb.query.as_ref() {
                    url.push('?');
                    url.push_str(q);
                }
                let http = reqwest::Client::new();
                let mut builder = match rb.method {
                    StripeMethod::Get => http.get(&url),
                    StripeMethod::Post => http.post(&url),
                    StripeMethod::Delete => http.delete(&url),
                }
                .bearer_auth(&secret);
                if let Some(body) = rb.body {
                    builder = builder
                        .header("content-type", "application/x-www-form-urlencoded")
                        .body(body);
                }
                let resp =
                    builder.send().await.map_err(|e| StripeError(format!("reqwest: {e}")))?;
                let bytes =
                    resp.bytes().await.map_err(|e| StripeError(format!("reqwest body: {e}")))?;
                Ok(bytes)
            }
        }
    }
}
