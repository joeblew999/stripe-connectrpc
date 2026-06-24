import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@cloudflare/kumo/styles/standalone";
import { AuthProvider } from "@joeblew999/kumo-connectrpc-kit";
import { App } from "./App.js";
import { whoami } from "./client.js";

// Rauthy OIDC config. Use a PUBLIC Rauthy client for a browser SPA (PKCE, no
// secret) — register it in vm-uncloud/recipes/rauthy/bootstrap.nuon with the
// app's redirect_uri. The confidential `worker-client` is for backends.
const issuer = import.meta.env.VITE_RAUTHY_ISSUER ?? "http://localhost:8080/auth/v1/";
const clientId = import.meta.env.VITE_RAUTHY_CLIENT ?? "web-spa";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AuthProvider
      whoami={whoami}
      oidc={{ issuer, clientId, redirectUri: `${location.origin}/callback` }}
    >
      <App />
    </AuthProvider>
  </StrictMode>,
);
