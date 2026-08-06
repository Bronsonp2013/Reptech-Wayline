# WAYLINE — Security Spec

> Security requirements for Wayline. These are not optional and not "phase 2."
> Build them in from the first sessions. Claude Code should treat every item here
> as a requirement, and the Session 6 hardening pass should verify each one.
>
> Guiding rule: **Wayline is multi-tenant from day one. The single worst failure is
> one user seeing or altering another user's data.** Everything below serves that.

---

## 1. THREAT MODEL (what we're defending against)

| Threat | Concern | Primary defense |
|---|---|---|
| Cross-tenant data access | User A reads/writes User B's accounts | Mandatory `userId` scoping on every query (§4) |
| Credential theft / brute force | Guessed or stuffed passwords | Strong hashing + rate limiting + lockout (§3) |
| Session hijacking | Stolen/forged session cookie | httpOnly+Secure+SameSite cookies, server-side sessions, rotation (§3) |
| Injection (SQL/NoSQL) | Malicious input reaching the DB | Parameterized queries via Prisma; zod validation (§5) |
| XSS | Injected script in the UI | React escaping + strict CSP; never `dangerouslySetInnerHTML` on user data (§6) |
| CSRF | Forged state-changing requests | SameSite cookies + CSRF tokens on mutations (§6) |
| Secret leakage | DB creds / session secret exposed | Env-only secrets, never committed; rotate on suspicion (§7) |
| SSRF via geocoding | App tricked into calling internal hosts | Fixed geocoder endpoint, validated inputs, no user-supplied URLs (§8) |
| Exposed database | Postgres reachable from internet | DB bound to Docker network only; no published port (§9) |
| Location-data exposure | GPS/customer locations leaked | Same tenant scoping + transport encryption; treat as sensitive (§10) |

Out of scope for v1 defense (documented, accepted): nation-state actors, DDoS
(Cloudflare Tunnel provides some shielding), and physical access to the NAS.

---

## 2. SECURITY PRINCIPLES

1. **Deny by default.** Every route requires an authenticated session unless
   explicitly public (only `register`, `login`). Every data query is scoped to the
   caller's tenant unless explicitly global (there are none in v1).
2. **Never trust input.** Validate and type every request body/param at the
   boundary with zod before it reaches business logic or the DB.
3. **Least privilege.** The app's DB user has only the rights it needs. No
   superuser. No direct DB exposure.
4. **Secrets live in the environment, never in code or git.** 
5. **Fail safe and quiet.** On auth/permission failure, return a generic error;
   don't leak whether an email exists, whether a record exists for another tenant, etc.
6. **Make the safe path the easy path.** Provide a `requireUser()` helper and a
   scoped-query helper so a developer *cannot* accidentally write an unscoped query.

---

## 3. AUTHENTICATION & SESSIONS

**Passwords**
- Hash with **argon2id** (preferred) or **bcrypt** (cost ≥ 12). Never store or log plaintext.
- Enforce a minimum length (≥ 10 chars); reject known-breached/common passwords if feasible.
- Never reveal whether an email exists: login and register return generic messages.

**Sessions**
- Server-side session records (the `Session` table); the cookie holds an opaque,
  high-entropy token, not user data.
- Cookie flags: **httpOnly, Secure, SameSite=Lax**, scoped path, sensible expiry.
- **Rotate** the session token on login (prevent fixation); invalidate server-side on logout.
- Absolute + idle expiry; expired sessions are rejected and cleaned up.

**Brute-force / abuse**
- **Rate-limit** `login` and `register` (per-IP and per-account). Exponential backoff
  or temporary lockout after repeated failures.
- Log auth failures (without logging passwords) for later review.

**Registration (v1)**
- Only Brian exists at launch; seed him via a script. If self-registration is
  enabled later, add email verification before it's exposed publicly.

---

## 4. TENANT ISOLATION (the most important section)

- **Every** `Account`, `ContactLog`, and geocode operation is scoped to the
  authenticated `userId`. There is no code path that returns another tenant's data.
- Implement a single helper, e.g. `requireUser(req)` → returns the session user or
  throws 401; and a data-access layer where account queries **always** take `userId`
  and inject `where: { userId }`. Feature code should not be able to query accounts
  without going through it.
- On `GET/PATCH/DELETE /api/accounts/:id`: fetch **with** the `userId` filter, so a
  valid id belonging to another tenant returns 404 (not 403 — don't confirm existence).
- **Test it explicitly (Session 1):** create user A and user B; assert that A cannot
  read, update, delete, or log-contact on any of B's accounts, by id. This test must
  exist and pass before any UI is built on top.

---

## 5. INPUT VALIDATION & DATA HANDLING

- Validate every request with **zod** schemas at the route boundary: types, lengths,
  enums (`action` ∈ {contact, catalog_drop}; `cadenceDays` ∈ {90,180,365} or a bounded int).
- Reject unexpected fields; don't mass-assign request bodies onto DB models.
- All DB access through **Prisma** (parameterized) — never string-built SQL.
- Sanitize/normalize CSV import: cap row count and cell length; never `eval`; treat
  every cell as untrusted text. Malformed rows are skipped with a visible count, not
  silently trusted.
- Coordinates: validate `lat ∈ [-90,90]`, `lng ∈ [-180,180]`, reject NaN before store.

---

## 6. WEB HARDENING (headers, XSS, CSRF)

- **Content-Security-Policy:** restrict `default-src 'self'`; allow only the needed
  map tile/host origins and Leaflet CDN (or self-host Leaflet to keep CSP tight).
  No inline scripts where avoidable; no `unsafe-eval`.
- **HSTS** (Strict-Transport-Security) — enforce HTTPS (Cloudflare Tunnel is HTTPS).
- **X-Frame-Options: DENY** / `frame-ancestors 'none'` — no clickjacking.
- **X-Content-Type-Options: nosniff**, **Referrer-Policy: strict-origin-when-cross-origin**.
- **XSS:** rely on React's escaping; never pass user/content data to
  `dangerouslySetInnerHTML`. Map pin labels (account names) render as text nodes /
  properly escaped, not raw HTML injection.
- **CSRF:** with SameSite=Lax cookies, add anti-CSRF tokens (or origin checks) on all
  state-changing routes (POST/PATCH/DELETE).
- Set security headers in Next.js middleware/config so they apply globally.

---

## 7. SECRETS & CONFIGURATION

- All secrets in **environment variables**: `DATABASE_URL`, `SESSION_SECRET`
  (high-entropy, ≥ 32 bytes), any future API keys.
- `.env` is **gitignored**; commit only `.env.example` with placeholder values.
- Never log secrets or full request bodies containing credentials.
- Rotate `SESSION_SECRET` and DB credentials if a leak is suspected (rotating the
  session secret invalidates all sessions — acceptable).
- When Google Places / Stripe arrive: their keys live server-side only, behind the
  API, never shipped to the browser.

---

## 8. GEOCODING / OUTBOUND REQUESTS

- Geocoding calls go to a **fixed, known endpoint** (Nominatim now) from the server,
  never to a user-supplied URL — prevents SSRF.
- Validate/encode the query; enforce the courtesy rate limit (~1 req/sec) and handle
  non-OK HTTP (429/5xx) as a clean miss, not a crash.
- The geocoding boundary (`lib/geocode.ts`) is the only place that makes these calls;
  swapping to Google Places later keeps the same validation and server-only key handling.

---

## 9. INFRASTRUCTURE & DEPLOYMENT (UGreen + Docker + Cloudflare Tunnel)

- **No inbound ports opened** on the home network. **Cloudflare Tunnel**
  (`cloudflared`) makes an outbound connection; the app is reachable only via the
  Cloudflare HTTPS hostname. This is the core of the deployment's security.
- **PostgreSQL is never published** to the host or internet — it's on the internal
  Docker Compose network, reachable only by the app container.
- Run containers as **non-root** where possible; keep base images minimal and updated.
- **Backups:** scheduled `pg_dump` to a protected NAS share; verify a restore at least once.
- **Updates:** rebuild and redeploy promptly when dependencies have security patches
  (`npm audit` in CI/local before deploy). Keep the UGreen firmware and Docker current.
- Cloudflare account itself is a sensitive credential — protect it with a strong,
  unique password and 2FA.

---

## 10. PRIVACY & SENSITIVE DATA

- Treat **customer names + locations + Brian's GPS** as sensitive. They're protected
  by the same tenant scoping and HTTPS transport; don't put them in URLs/query strings
  or logs.
- Collect only what the product needs; no third-party analytics/trackers in v1.
- GPS is captured only on explicit user action ("Use my location") and stored as a
  coordinate on the account — not continuously tracked.
- When multi-user/billing arrive, revisit: data-retention, account deletion (cascade
  is already modeled), and a basic privacy policy.

---

## 11. SESSION-6 HARDENING CHECKLIST (verify before ship)

- [ ] Passwords hashed with argon2id/bcrypt; no plaintext anywhere; login/register don't leak account existence.
- [ ] Sessions: opaque token, httpOnly+Secure+SameSite, server-side records, rotation on login, expiry + logout invalidation.
- [ ] Rate limiting + lockout on auth endpoints.
- [ ] **Cross-tenant test passes:** user A cannot read/update/delete/log user B's accounts (by id).
- [ ] Every account/log/geocode query is `userId`-scoped via the shared helper.
- [ ] zod validation on every route; unexpected fields rejected; no mass-assignment.
- [ ] All DB access via Prisma; no raw string SQL.
- [ ] CSP, HSTS, X-Frame-Options, nosniff, Referrer-Policy set globally.
- [ ] No `dangerouslySetInnerHTML` on user data; pin labels safely escaped.
- [ ] CSRF protection on all mutations.
- [ ] Secrets only in env; `.env` gitignored; `SESSION_SECRET` strong.
- [ ] Geocoding hits a fixed endpoint, validates input, handles 429/5xx, respects rate limit.
- [ ] Postgres not published to host/internet; app runs behind Cloudflare Tunnel with no open inbound ports.
- [ ] `npm audit` clean (or known/acceptably triaged); base images updated.
- [ ] `pg_dump` backup scheduled and a restore verified once.
- [ ] Coordinates validated (range + NaN) before storage; no sensitive data in URLs or logs.
```
