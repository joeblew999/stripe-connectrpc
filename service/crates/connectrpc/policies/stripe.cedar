// stripe-connectrpc authorization policies.
//
// A request only reaches Cedar after OidcLayer verified a valid Rauthy JWT, so
// the principal is always an authenticated User. These policies then decide
// WHAT that identity may do. Roles + scopes come from the token, mapped into
// `context` by guard::extract.

// Baseline: any authenticated caller may run the user-facing ops (start a
// checkout, open the billing portal for their customer). Keep this while there's
// a single trusted caller; tighten to per-project / per-customer (below) once
// consumers carry a `project:<slug>` scope from Rauthy.
@id("authed-user-facing-ops")
permit (
  principal is User,
  action in [
    Action::"stripe.v1.CheckoutService.CreateCheckoutSession",
    Action::"stripe.v1.BillingService.CreateBillingPortal",
    Action::"stripe.v1.BillingService.ListSubscriptions",
    Action::"stripe.v1.BillingService.CancelSubscription",
    Action::"stripe.v1.BillingService.ListInvoices",
    Action::"stripe.v1.BillingService.GetCustomer"
  ],
  resource is Api
);

// Provisioning is ADMIN-ONLY — the first real (non-stub) policy. Only a caller
// whose Rauthy token carries the `admin` role may write the catalog (create/
// update products). Replaces the implicit trust of the stripe-cli loaders.
@id("admin-only-ops")
permit (
  principal is User,
  action in [
    Action::"stripe.v1.CatalogService.UpsertProduct",
    Action::"stripe.v1.CatalogService.UpsertPrice",
    Action::"stripe.v1.BillingService.CreateRefund"
  ],
  resource is Api
)
when { context.roles.contains("admin") };

// Per-project tightening (activate by deleting the baseline above once Rauthy
// issues project scopes). A caller may only checkout if its token carries the
// matching project scope — so remy-sport's token can't create sessions for
// another project. The project arrives in the request body; enforcing it
// against the scope is the next step (extend guard::extract to surface the
// request's `project` field into context, then):
//
// @id("project-scoped-checkout")
// permit (
//   principal is User,
//   action == Action::"stripe.v1.CheckoutService.CreateCheckoutSession",
//   resource is Api
// )
// when { context.scopes.contains("checkout") &&
//        context.scopes.contains(context.project_scope) };
