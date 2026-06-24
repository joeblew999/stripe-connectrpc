import { createClient } from "@connectrpc/connect";
import { makeTransport } from "@joeblew999/kumo-connectrpc-kit";
import { CheckoutService } from "../gen/stripe/v1/checkout_pb.js";

// The stripe ConnectRPC service URL. The bearer token is NO LONGER a static env
// value — it's the Rauthy JWT obtained at login (the kit's AuthProvider stamps
// it via setAuthToken on every request). The service sits behind the
// Rauthy → Cedar guard, so an unauthenticated call is rejected with 401.
const STRIPE_URL = import.meta.env.VITE_STRIPE_URL ?? "http://localhost:8787";

export const transport = makeTransport(STRIPE_URL);
export const checkoutClient = createClient(CheckoutService, transport);

// stripe has no whoami RPC — the session IS the Rauthy token. This trivial
// identity satisfies the kit's AuthProvider (which re-validates on mount); the
// guard does the real token check on every RPC. A project WITH an identity
// service would return its `whoami()` here instead.
export interface StripeIdentity {
  signedIn: true;
}
export async function whoami(): Promise<StripeIdentity | null> {
  return { signedIn: true };
}
