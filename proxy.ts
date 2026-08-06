// proxy.ts — Next 16's request middleware (renamed from middleware.ts).
// Two hardening concerns (WAYLINE_SECURITY.md §6):
//
//  1. CSRF: state-changing API requests must be same-origin. With SameSite=Lax
//     cookies this closes the residual top-level-POST hole. We reject when an
//     Origin header is present and its host doesn't match the request host.
//
//  2. CSP: a per-request nonce for scripts (Next auto-applies it to its own
//     script tags via 'strict-dynamic'), so no 'unsafe-inline' for scripts.
//     style-src must stay 'unsafe-inline' — inline style attributes (our status
//     colors, Leaflet marker positions) can't carry a nonce. img-src allows the
//     CARTO tile host; everything else is locked to 'self'.

import { NextResponse, type NextRequest } from "next/server";

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // --- CSRF: same-origin enforcement on API mutations ---
  if (pathname.startsWith("/api/") && !SAFE_METHODS.has(request.method)) {
    const origin = request.headers.get("origin");
    const host = request.headers.get("host");
    if (origin && new URL(origin).host !== host) {
      return NextResponse.json({ error: "Cross-origin request blocked." }, { status: 403 });
    }
  }

  // --- CSP with a per-request nonce ---
  // btoa (not Buffer) — proxy runs on the Edge runtime.
  const nonce = btoa(crypto.randomUUID());
  const isDev = process.env.NODE_ENV === "development";
  const csp = [
    `default-src 'self'`,
    // 'unsafe-eval' only in dev (React uses eval for better error stacks).
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? " 'unsafe-eval'" : ""}`,
    // Inline style attributes can't be nonced → 'unsafe-inline' is required.
    `style-src 'self' 'unsafe-inline'`,
    `img-src 'self' blob: data: https://*.basemaps.cartocdn.com`,
    `font-src 'self'`,
    `connect-src 'self'`,
    `worker-src 'self'`,
    `manifest-src 'self'`,
    `object-src 'none'`,
    `base-uri 'self'`,
    `form-action 'self'`,
    `frame-ancestors 'none'`,
    // Don't upgrade on http://localhost in dev — it would break local subresources.
    ...(isDev ? [] : ["upgrade-insecure-requests"]),
  ].join("; ");

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-nonce", nonce);
  requestHeaders.set("Content-Security-Policy", csp);

  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set("Content-Security-Policy", csp);
  return response;
}

export const config = {
  // Run on pages + API, but skip Next's static assets and the favicon.
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
