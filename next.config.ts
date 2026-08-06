import type { NextConfig } from "next";

// Static security headers (WAYLINE_SECURITY.md §6). CSP + per-request nonce live
// in proxy.ts; these are the constant ones applied to every response.
const securityHeaders = [
  // Force HTTPS for 2 years incl. subdomains (Cloudflare Tunnel terminates TLS).
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" }, // belt-and-suspenders with frame-ancestors 'none'
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  // Only this app may use geolocation (needed for GPS capture); deny the rest.
  { key: "Permissions-Policy", value: "geolocation=(self), camera=(), microphone=(), payment=()" },
];

const nextConfig: NextConfig = {
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
