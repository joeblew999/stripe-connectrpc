import { useState } from "react";
import type { CSSProperties, FormEvent } from "react";
import { Button, Text } from "@cloudflare/kumo";
import { errorMessage, useAuth } from "@joeblew999/kumo-connectrpc-kit";

/**
 * The recommended hybrid login: ONE card, BOTH flows.
 *  - email + password  → `loginWithPassword` (ROPC, in-app, no redirect)
 *  - passkey / SSO     → `loginWithRedirect` (authorization_code + PKCE on
 *                        Rauthy's hosted page — the ONLY way to do passkeys/MFA)
 * Both mint the same Rauthy JWT; the server guard verifies it identically.
 */
export function LoginCard() {
  const { loginWithPassword, loginWithRedirect } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onPassword(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await loginWithPassword(email, password);
    } catch (err) {
      setError(errorMessage(err, "sign-in failed"));
      setBusy(false);
    }
  }

  async function onPasskey() {
    setError(null);
    try {
      await loginWithRedirect(); // navigates to Rauthy; page unloads
    } catch (err) {
      setError(errorMessage(err, "redirect failed"));
    }
  }

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <form onSubmit={onPassword} style={{ display: "grid", gap: 10 }}>
        <input
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
          style={inputStyle}
        />
        <input
          type="password"
          placeholder="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
          style={inputStyle}
        />
        <Button type="submit" disabled={busy}>
          {busy ? "signing in…" : "Sign in"}
        </Button>
      </form>

      <div style={{ textAlign: "center", opacity: 0.55 }}>
        <Text variant="secondary">or</Text>
      </div>

      <Button onClick={onPasskey}>Sign in with passkey / SSO</Button>

      {error && <Text variant="secondary">{error}</Text>}
    </div>
  );
}

const inputStyle: CSSProperties = {
  padding: "9px 11px",
  borderRadius: 8,
  border: "1px solid var(--color-kumo-border, #333)",
  background: "transparent",
  color: "inherit",
  font: "inherit",
};
