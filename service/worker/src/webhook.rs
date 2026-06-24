//! Inbound Stripe webhook receiver.

use stripe_webhook::Webhook;
use worker::*;

pub async fn handle(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let signature = match req.headers().get("Stripe-Signature")? {
        Some(s) => s,
        None => return Response::error("missing Stripe-Signature", 400),
    };

    let secret = ctx.env.secret("STRIPE_WEBHOOK_SECRET")?.to_string();
    let payload = req.text().await?;

    match Webhook::construct_event(&payload, &signature, &secret) {
        Ok(event) => {
            console_log!("stripe event {} ({:?})", event.id, event.type_);
            Response::ok("received")
        }
        Err(err) => {
            console_error!("webhook signature verification failed: {err}");
            Response::error("invalid signature", 400)
        }
    }
}
