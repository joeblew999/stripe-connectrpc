import { useEffect, useState } from "react";
import { Button, Text } from "@cloudflare/kumo";
import {
  AuthHero,
  PageLoading,
  errorMessage,
  isRedirectCallback,
  useAuth,
} from "@joeblew999/kumo-connectrpc-kit";
import { checkoutClient } from "./client.js";
import { LoginCard } from "./LoginCard.js";

export function App() {
  const { state, completeRedirect, logout } = useAuth();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Land here after the Rauthy PKCE redirect (passkey / SSO path): finish the
  // exchange, then clean the ?code=... out of the URL.
  useEffect(() => {
    if (!isRedirectCallback()) return;
    completeRedirect()
      .then(() => window.history.replaceState({}, "", "/"))
      .catch((e) => setError(errorMessage(e, "sign-in failed")));
  }, [completeRedirect]);

  async function subscribe() {
    setLoading(true);
    setError(null);
    try {
      const res = await checkoutClient.createCheckoutSession({
        project: "remy-sport",
        lookupKey: "sports_coach_monthly_usd",
        successUrl: `${window.location.origin}/return?session={CHECKOUT_SESSION_ID}`,
        cancelUrl: `${window.location.origin}/cancel`,
      });
      window.location.href = res.url; // hosted Stripe Checkout
    } catch (e) {
      setError(errorMessage(e, "checkout failed"));
      setLoading(false);
    }
  }

  if (state.status === "loading") return <PageLoading label="loading" />;
  if (loading) return <PageLoading label="redirecting to stripe" />;

  return (
    <main style={{ maxWidth: 420, margin: "4rem auto", padding: "0 1rem" }}>
      <AuthHero eyebrow="remy-sport" title="Coach plan" lede="Monthly subscription, billed by Stripe." />
      <div style={{ marginTop: 24 }}>
        {state.status === "authenticated" ? (
          <div style={{ display: "grid", gap: 12 }}>
            <Text variant="secondary">Signed in.</Text>
            <Button onClick={subscribe}>Subscribe</Button>
            <Button onClick={logout}>Sign out</Button>
          </div>
        ) : (
          <LoginCard />
        )}
      </div>
      {error && (
        <div style={{ marginTop: 16 }}>
          <Text variant="secondary">{error}</Text>
        </div>
      )}
    </main>
  );
}
