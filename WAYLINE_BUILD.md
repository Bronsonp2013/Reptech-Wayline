# WAYLINE — Full Build Spec & Claude Code Session Plan

> ⚠️ **Superseded in part.** Where this document conflicts with
> `WAYLINE_MASTER_PLAN.md` or `WAYLINE_CADENCE_PATCH.md`, those files win.
> Known correction: three interaction types (`visit` / `call` / `catalogs_updated`);
> **only visits reset the cadence clock.**

> **What this document is.** A complete, self-contained spec for building Wayline
> from scratch as a production web app, plus a session-by-session plan for driving
> Claude Code. Save this file to your computer. In each Claude Code session, point
> Claude Code at this file and work the numbered steps for that session.
>
> **How to use it with Claude Code:**
> 1. Put this file at the root of an empty project folder (e.g. `~/wayline/WAYLINE_BUILD.md`).
> 2. Open Claude Code in that folder.
> 3. Start each session by saying: *"Read WAYLINE_BUILD.md. We're doing Session N. Follow the steps for that session only. Ask me before making structural decisions not covered by the spec."*
> 4. At the end of each session, have Claude Code update the **BUILD LOG** at the bottom.

---

## 1. PRODUCT SUMMARY

Wayline is a field-sales territory and cadence tracker for manufacturer's reps.
It answers two questions: **"who needs me and when"** (contact cadence) and
**"is this drive worth it"** (territory + trip planning).

**First user:** Brian, a furniture rep covering a Texas territory.
**Growth path:** Brian → other furniture reps → manufacturer's reps broadly.
Build single-user in feel, but multi-tenant in architecture from day one.

**Explicit non-goals for v1:** not a CRM, not an order-entry system, not a
routing engine that competes with Google Maps, not a team/admin tool. Wayline
decides *who is worth a stop* and hands the driving off to Google Maps / Waze.

---

## 2. LOCKED DECISIONS

These are settled. Claude Code should not re-litigate them.

| Area | Decision |
|---|---|
| Stack | **Next.js (App Router) full-stack** — one codebase, API routes + React frontend |
| Language | **TypeScript** throughout |
| Database | **PostgreSQL** |
| ORM | **Prisma** (type-safe, easy migrations, portable) |
| Auth | **Email + password, session-based**, secure from day one. Multi-tenant: every row scoped to a `user_id`. |
| Multi-tenancy | Built in now (schema + query scoping). Only Brian's account exists at launch. |
| Billing | **Deferred.** Schema is multi-tenant-ready; Stripe wired when onboarding rep #2. |
| Maps | **Leaflet + OpenStreetMap** (CARTO dark tiles) |
| Geocoding | **Background batch queue.** Nominatim now; structured as a swappable boundary so **Google Places API** drops in later. |
| GPS accuracy | Standard (`enableHighAccuracy: false`). One-line switch to high-accuracy later. |
| Timezones | All US timezones selectable per user; default America/Chicago (Brian). |
| Platform | Responsive web app, **iOS-first layout**, works on Android. Installable as a **PWA**. |
| Hosting | **Self-hosted in Docker on a UGreen DXP4800 Pro**, reached from the field via **Cloudflare Tunnel** (free, HTTPS, no open ports). |
| Contact logging | Logs timestamp **and** action type (visit / call / catalogs_updated). **Only 'visit' resets the cadence clock**; the other two are history-only. |
| Deferred to post-v1 | Data export, CRM integrations, offline mode, push notifications, Stripe billing. |

---

## 3. ARCHITECTURE

```
┌─────────────────────────────────────────────┐
│  UGreen DXP4800 Pro  (Docker host)           │
│                                              │
│  ┌────────────────┐   ┌───────────────────┐  │
│  │ wayline-app    │   │ wayline-db        │  │
│  │ Next.js (Node) │──▶│ PostgreSQL 16     │  │
│  │ :3000          │   │ :5432 (internal)  │  │
│  └────────────────┘   └───────────────────┘  │
│         ▲                                     │
│         │ (internal network only)            │
│  ┌────────────────┐                          │
│  │ cloudflared    │  Cloudflare Tunnel       │
│  │ (tunnel agent) │  → https://wayline.<you> │
│  └────────────────┘                          │
└─────────────────────────────────────────────┘
              ▲
              │ HTTPS
      Brian's phone (PWA), in the field
```

- **No ports exposed to the internet.** Cloudflare Tunnel connects outbound; the
  app is reachable at a public HTTPS hostname but nothing is open on your home network.
- **Postgres is never exposed** outside the Docker network.
- **Everything is three containers** managed by one `docker-compose.yml`.

---

## 4. DATA MODEL (Prisma schema)

```prisma
// schema.prisma — reference; Claude Code will generate & migrate this

model User {
  id           String   @id @default(cuid())
  email        String   @unique
  passwordHash String
  name         String?
  timezone     String   @default("America/Chicago")
  createdAt    DateTime @default(now())
  accounts     Account[]
  sessions     Session[]
}

model Session {
  id        String   @id @default(cuid())
  userId    String
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  expiresAt DateTime
  createdAt DateTime @default(now())
}

model Account {
  id           String    @id @default(cuid())
  userId       String                            // tenant scope — every query filters by this
  user         User      @relation(fields: [userId], references: [id], onDelete: Cascade)
  name         String
  city         String?
  address      String?
  lat          Float?
  lng          Float?
  cadenceDays  Int       @default(180)
  lastVisitAt  DateTime?                         // advanced ONLY by a 'visit' log
  source       String?                           // 'gps' | 'nominatim' | 'import' | 'none'
  confidence   String?                           // 'exact' | 'approx' | 'none'
  contactName  String?
  geocodeState String    @default("idle")        // 'idle' | 'queued' | 'done' | 'failed'
  createdAt    DateTime  @default(now())
  updatedAt    DateTime  @updatedAt
  contactLogs  ContactLog[]

  @@index([userId])
}

model ContactLog {
  id        String   @id @default(cuid())
  accountId String
  account   Account  @relation(fields: [accountId], references: [id], onDelete: Cascade)
  loggedAt  DateTime @default(now())
  action    String   // 'visit' | 'call' | 'catalogs_updated' — only 'visit' resets cadence
  notes     String?
}

model GeocodeJob {
  id        String   @id @default(cuid())
  accountId String
  status    String   @default("queued")          // 'queued' | 'running' | 'done' | 'failed'
  attempts  Int      @default(0)
  createdAt DateTime @default(now())
}
```

**Tenant rule (critical for security):** every account/contact query MUST filter
by the authenticated `userId`. No endpoint ever returns another user's data.

---

## 5. FEATURE SET (v1 ship definition)

### Accounts
- Add one account: name (required), city, address, cadence (90/180/365), contact name.
- **GPS capture:** "Use my location" sets an exact pin, skips geocoding.
- **Delete** with confirm.
- **Detail sheet:** status, last visit, next due, location source, cadence editor, log visit / log call / catalogs updated, delete.

### Cadence engine (the core loop)
- Status from `lastVisitAt + cadenceDays` vs. today:
  overdue (<0 days left), due (≤14), soon (≤30), current (>30).
- **Log visit** sets `lastVisitAt = now()` and writes a `ContactLog` row. **Log call**
  and **Catalogs updated** write a `ContactLog` row only — they never advance the clock.
- Status colors: rust (overdue) / amber (due/soon) / sage (current).

### List view
- Rows: status dot, name, city, last-visit label.
- Sort: overdue-first / A–Z / by city / longest gap.
- Filter: all / overdue / due / current (drives list AND map).
- Tap row → detail. `+` button → add to trip selection.

### Map view
- Leaflet + OSM, real-coordinate pins (solid exact, dashed approximate).
- Button-toggled **freehand lasso** → point-in-polygon selection.
- Filter-aware. Tap pin → detail.

### Trip / selection
- Selection built by lasso (map) or `+` (list) or seed-by-city.
- Greedy nearest-neighbour ordering; leg + total mileage.
- Export: **Google Maps** multi-stop (≤10 waypoints), **Waze** single-destination.
- "Needs location" list for selected accounts without a pin.

### Import
- CSV upload/paste: flexible header detection (name, city, address, lat, lng, cadence).
- Rows with coordinates plot immediately; address-only rows are **queued for background geocoding**.
- Preview with confidence badges before commit.
- (Google Takeout place-ID resolution is **post-v1**, via Google Places API.)

### Background geocoding
- On import/add without coords, enqueue a `GeocodeJob`.
- A worker processes the queue, throttled ~1 req/sec (Nominatim courtesy limit),
  updates `lat/lng/confidence/source/geocodeState`.
- UI shows per-account state ("locating…", "approx", "needs location") and can retry failures.
- **Boundary:** geocoding lives behind one server module (`lib/geocode.ts`) with a
  single `geocode(address, city)` function. Swapping Nominatim → Google Places is
  editing that one file only.

### Persistence & sync
- All data in PostgreSQL, scoped per user.
- Every action persists immediately via API.
- Filter/sort/selection are session-only (reset on reload); accounts hydrate from DB.

### Visual design
- Dark warm theme. Bg #1c1410, cards #2c211a, lines #3d2f25.
- Brass accent #c79a5b → #e8c98a. Text #f3e9df / #b09a87 / #7c6a5b.
- Status: rust #c5613f, amber #d9a23f, sage #7fa06a.
- 12–16px radii, subtle dot glows, Inter/system sans, iOS-first spacing.

---

## 6. API SURFACE (Next.js route handlers)

All routes require an authenticated session except auth/login and auth/register.
All account routes are scoped to the session's `userId`.

```
POST   /api/auth/register        { email, password, name, timezone }
POST   /api/auth/login           { email, password } → sets session cookie
POST   /api/auth/logout
GET    /api/auth/me

GET    /api/accounts             ?filter=&sort=      → user's accounts
POST   /api/accounts             create (queues geocode if address & no coords)
GET    /api/accounts/:id
PATCH  /api/accounts/:id         update (cadence, contact, name, coords, …)
DELETE /api/accounts/:id
POST   /api/accounts/:id/log     { action: 'visit' | 'call' | 'catalogs_updated', notes? }

POST   /api/import/preview       CSV text/file → parsed rows + confidence counts
POST   /api/import/commit        rows → create accounts, enqueue geocode jobs

POST   /api/geocode/retry/:id    re-queue a failed account
GET    /api/geocode/status       queued/running/done counts (for progress UI)

POST   /api/trips/google-maps    { accountIds[] } → { url }
POST   /api/trips/waze           { accountId }    → { url }
```

**Security requirements (build these in, don't bolt on):**
- Passwords hashed with **argon2** or **bcrypt** (never plaintext).
- Session tokens: httpOnly, Secure, SameSite=Lax cookies; server-side session records; expiry + rotation.
- All inputs validated with **zod** at the route boundary.
- Rate-limit auth endpoints (login/register) to blunt brute force.
- CSRF protection on state-changing routes.
- Every DB query for accounts/logs filters by `userId` — add a helper so it can't be forgotten.
- Security headers (CSP, HSTS, X-Frame-Options) via Next.js config / middleware.
- Secrets (DB URL, session secret) only in env vars, never committed.

---

## 7. FROM-SCRATCH BUILD ORDER (Session by session)

> Target: shippable in ~4 weeks. Each session is scoped to finish cleanly and leave
> the app runnable. Do sessions in order; don't start a later one until the prior
> session's "Done when" checks pass.

### SESSION 0 — Project scaffold & local run *(short)*
1. Init a Next.js + TypeScript app (App Router) in this folder.
2. Add Prisma, zod, argon2 (or bcrypt), the auth/session libs, Leaflet, papaparse.
3. Add `docker-compose.yml` with `wayline-app` + `wayline-db` (Postgres 16) for **local** dev.
4. Create `.env.example` (DB URL, SESSION_SECRET, etc.) and a real `.env` (gitignored).
5. Add ESLint + Prettier + a basic test runner (Vitest).
**Done when:** `docker compose up` brings up Postgres, `npm run dev` serves a placeholder page, and Prisma connects.

### SESSION 1 — Database & auth
1. Write the full Prisma schema from §4; run the first migration.
2. Implement register/login/logout/me with hashed passwords + server-side sessions + secure cookies.
3. Add zod validation and rate-limiting on auth routes.
4. Seed **Brian's user** (email you provide) via a seed script.
5. Add a `requireUser()` helper that every protected route/query uses for tenant scoping.
6. Unit-test: password hashing, session issue/expire, tenant scoping (user A can't read user B).
**Done when:** you can register/login via API, cookies are secure, and cross-tenant access is provably blocked by a test.

### SESSION 2 — Account CRUD + cadence engine
1. Implement `/api/accounts` GET/POST/PATCH/DELETE and `/api/accounts/:id/log`, all `userId`-scoped.
2. Implement cadence status derivation server-side (overdue/due/soon/current) and expose it on account reads.
3. Log-interaction writes a `ContactLog`; it updates `lastVisitAt` **only** when `action === 'visit'`.
4. Unit-test the cadence math (the transitions: logging a **visit** flips overdue→current; logging a **call** does not; never-visited stays overdue; cadence change re-derives).
**Done when:** full account lifecycle works via API and cadence status is correct and tested.

### SESSION 3 — Frontend: list + detail + cadence UI
1. Build the app shell (tabs: List / Map / Selection / Import), dark theme tokens from §5.
2. List view: rows, sort, filter (client reads the scoped API), empty "Start your book" state.
3. Detail sheet: facts grid, **Log visit** (brass primary) plus **Log call** / **Catalogs updated** (secondary), cadence selector, delete.
4. Add-account form: name/city/address/cadence + **GPS capture** button.
5. Wire everything to the API; confirm persistence across reload.
**Done when:** Brian can add, view, log a visit / call / catalogs-updated, edit cadence, and delete from the UI, and it persists in Postgres.

### SESSION 4 — Map + lasso + trip export
1. Map view (Leaflet + CARTO dark), real-coordinate pins colored by status, solid/dashed by confidence.
2. Button-toggled freehand lasso with pointer capture; point-in-polygon selection; filter-aware.
3. Tap pin → detail. `+`/lasso build the selection.
4. Selection view: nearest-neighbour ordering, mileage, **Google Maps** + **Waze** export, needs-location list.
5. Unit-test point-in-polygon (incl. concave) and the Google Maps URL builder (waypoints, ≤10 cap, single-stop).
**Done when:** Brian can draw an area, get a selection, and open it in Google Maps/Waze; math is tested.

### SESSION 5 — Import + background geocoding
1. `/api/import/preview` + `/api/import/commit` with flexible CSV header detection (papaparse).
2. `lib/geocode.ts` boundary + a queue worker that drains `GeocodeJob` throttled ~1/sec (Nominatim), with HTTP-status and NaN guards.
3. Progress UI (`/api/geocode/status`) and per-account retry.
4. Confirm the boundary is a clean single-file swap point for Google Places later.
**Done when:** a CSV import commits instantly and pins fill in over time; failures are visible and retryable.

### SESSION 6 — PWA, hardening, QA
1. Make it an installable PWA (manifest, icons, service worker for install only — no offline sync in v1).
2. Add security headers/CSP/HSTS, finalize CSRF, re-check tenant scoping across every route.
3. Full QA pass on a phone: GPS, add, log, lasso, export, import.
4. Fix bugs; write a short README for running and updating.
**Done when:** installs to a phone home screen, passes a security self-review, and the core loop works end-to-end on Brian's Android.

### SESSION 7 — Deploy to UGreen (Docker + Cloudflare Tunnel)
1. Production `docker-compose.yml`: `wayline-app` (built image), `wayline-db` (Postgres with a named volume + backup note), `cloudflared`.
2. Set production env/secrets; run migrations against the prod DB; seed Brian's user.
3. Configure the **Cloudflare Tunnel** to a hostname (e.g. `wayline.<yourdomain>`), HTTPS only, nothing else exposed.
4. Verify from Brian's phone off home Wi-Fi (cellular): install PWA, log in, run a real trip.
5. Document the update procedure (pull, rebuild, migrate) and a Postgres backup command.
**Done when:** Brian uses it in the field over cellular, data persists, and you know how to update and back it up.

---

## 8. UGREEN DXP4800 PRO — DEPLOYMENT NOTES

- The DXP4800 Pro runs Docker. Manage containers via **Portainer** (nice UI) or the terminal.
- Run all three services from **one `docker-compose.yml`** (app, db, cloudflared).
- **Postgres:** use a named Docker volume for the data dir; it must not be exposed outside the compose network. Add a scheduled `pg_dump` to a NAS share for backups.
- **Cloudflare Tunnel:** requires a free Cloudflare account and a domain (or a Cloudflare-managed subdomain). The `cloudflared` container authenticates outbound — **no port forwarding, no open inbound ports**. This is the secure part: your home network stays closed.
- **Updates:** `git pull` → `docker compose build wayline-app` → `docker compose up -d` → run any new Prisma migration.
- **Resource use:** Next.js + Postgres is light; the N100 and RAM in the DXP4800 Pro handle it comfortably for a single user and well beyond.

---

## 9. THINGS YOU (BRONSON) OWN, NOT CLAUDE CODE

- Buying / setting up the UGreen and enabling Docker.
- Creating the Cloudflare account + adding a domain, and running the one-time tunnel auth.
- Providing Brian's login email for the seed script.
- Deciding, later, when to wire Stripe + the Google Places API (both have clean insertion points already in the spec).

---

## 10. POST-V1 BACKLOG (do not build yet)

- Stripe billing ($20/mo; $192/yr at 20% off annual); single tier first, tiers later.
- Google Places API for accurate pins + Takeout place-ID resolution (swap `lib/geocode.ts`).
- Multi-user onboarding UX (invite, per-rep isolation is already in the schema).
- Persistent named trips; cadence history/analytics; data export (CSV/PDF); offline mode; push notifications.

---

## 11. BUILD LOG (Claude Code updates this each session)

| Session | Date | What shipped | Follow-ups / notes |
|---|---|---|---|
| 0 | 2026-07-01 | Next.js 16 (App Router, TS) scaffold; deps installed (Prisma 7, zod, @node-rs/argon2, Leaflet + react-leaflet, papaparse); dev `docker-compose.yml` runs Postgres 16; `.env`/`.env.example` with gitignore; ESLint + Prettier + Vitest wired; branded placeholder page + `/api/health` proving Prisma↔Postgres; theme tokens ported to CSS vars; git initialized. **Done-when verified:** `docker compose up` → healthy Postgres, `npm run dev` serves the page, `/api/health` = `{"status":"ok","db":{"ok":true}}`, `npm test` green, ESLint clean. | **Version drift from training:** Next **16.2.9** (Turbopack dev default) + Prisma **7.8.0**. Prisma 7 removed `url` from the schema datasource — CLI URL lives in `prisma.config.ts`, runtime connects via **@prisma/adapter-pg** (`lib/db.ts`). Choices (confirmed w/ Bronson): CSS variables + CSS Modules (no Tailwind); `@node-rs/argon2`; no `src/` dir; dev compose is **Postgres-only** (full app + `cloudflared` stack deferred to Session 7). Dev DB uses host port **5433** (5432 taken by another local Postgres). `npm audit` shows moderate advisories — triage in Session 6. Initial git commit not yet made (awaiting go-ahead). |
| 1 | 2026-07-07 | Full Prisma schema (User, Session, Account, ContactLog, GeocodeJob) + first migration `session1_full_model`. Auth: argon2id password hashing (`lib/auth/password.ts`), server-side sessions with opaque high-entropy tokens stored as SHA-256 hashes + httpOnly/SameSite=Lax cookies, rotation on login, logout invalidation, expiry with self-cleanup (`lib/auth/session.ts`). `requireUser()`/`getCurrentUser()` gate (`lib/auth/requireUser.ts`); tenant-scoped data layer (`lib/data/accounts.ts`) that injects `userId` on every query. Routes register/login/logout/me with zod validation, in-memory per-IP + per-account rate limiting, anti-enumeration (identical 401 + timing-equalized argon2 on unknown email). Seed script (`prisma/seed.ts`, `npm run db:seed`, env-driven). **Done-when verified:** 18 tests green incl. DB-backed **cross-tenant isolation** (A cannot read/update/delete/log B's accounts) and session expiry/rotation; `tsc --noEmit` + ESLint clean; live API drive proved register→me→login→logout→me with correct cookie flags and generic errors. | **Prisma 7 gotcha:** `prisma migrate dev` did NOT refresh the generated client — it kept the Session-0 empty `runtimeDataModel`, so all model delegates (`prisma.user`) were `undefined`. Fix: `rm -rf generated/prisma && npx prisma generate` after schema changes (add to workflow). **Added `tokenHash` to Session** (not in §4 draft) to store only hashed tokens. **const-enum trap:** `Algorithm.Argon2id` breaks under `isolatedModules`; use numeric `2 as Algorithm`. **Port clash:** an unrelated Express app squats on :3000 (PID reuse left a stale `.next/dev/lock`); ran dev on **:3100**. **Brian's user seeded** (`bprachyl61@gmail.com`) and login-verified live. CSP/HSTS/CSRF headers still deferred to Session 6 per plan. |
| 2 | 2026-07-07 | Account CRUD + cadence engine. Routes: `GET/POST /api/accounts`, `GET/PATCH/DELETE /api/accounts/:id`, `POST /api/accounts/:id/log` — all `userId`-scoped via `requireUser` + the data layer, returning 404 (not 403) for another tenant's id. Cadence derived server-side in `lib/cadence.ts` (`deriveCadence`: overdue<0, due 0–14, soon 15–30, current >30; never-contacted=overdue; colors rust/amber/sage) and attached to every read via `lib/accounts/view.ts` (`serializeAccount`/`shapeList` handle filter=all/overdue/due/soon/current and sort=overdue-first/name/city/longest-gap in memory). zod schemas (`lib/accounts/schemas.ts`) validate coord ranges + finiteness, both-or-neither lat/lng, bounded cadence, action enum, and reject unknown fields. Location bookkeeping shared by create/patch (`lib/accounts/location.ts`): coords → confidence `exact`/geocodeState `done`; address-only → `queued`; neither → `idle`. Log-contact writes ContactLog + advances lastContact in one txn. **Done-when verified:** 33 tests green (cadence transitions incl. overdue→current on log, cadence-change re-derive, boundary days; list filter/sort) + `tsc`/ESLint clean; live drive as Brian proved create (both location paths), list, log (status flip), PATCH cadence re-derive, filter, validation 400s, unauth 401, and **API-level cross-tenant 404s** for all four ops. Test data cleaned; Brian's book left empty for Session-5 import. | **Next 16 async params:** dynamic route handlers take `{ params }: { params: Promise<{ id: string }> }` — must `await params`. **Turbopack cache corruption:** running two `next dev` on the same project dir concurrently panicked turbo-persistence (`range end index out of range`) and hung route compiles; fix = kill ALL next processes, `rm -rf .next`, start ONE. `pkill -f "next dev"` misses the running server (renamed `next-server`) — kill by the PID holding the port. Filter/sort run in memory after cadence derivation (can't filter a derived status in SQL) — fine at single-rep scale. |
| 3 | 2026-07-07 | Frontend: list + detail + cadence UI. `lib/store.ts` — the frontend data-client boundary (WAYLINE.md): typed methods (me/login/logout, list/get/create/update/delete/logContact) wrapping the APIs; feature code never calls `fetch`. Auth gate (`components/AuthGate.tsx`) shown when unauthenticated; `app/page.tsx` is a server component that reads the session and renders AuthGate or `<App>`. App shell (`components/App.tsx`): header + Saving…/✓ Saved indicator + sign-out, filter chips (All/Overdue/Due/Current), linked tabs (List/Map/Selection/Import). List (`AccountList.tsx`) with client-side sort over server cadence, city headers, "no pin" badge, +/✓ selection toggle, and Start-your-book / nothing-matches empty states. Add form (`AddAccountForm.tsx`) with GPS capture (standard accuracy per §2). Detail sheet (`DetailSheet.tsx`): facts grid, brass Log-contact, cadence selector, delete-behind-confirm. Ported from `WAYLINE_UI_REFERENCE.jsx` to CSS Modules + CSS-var theme (data-driven status colors via a `--sc` custom prop). Map/Selection/Import are honest placeholders (Sessions 4–5). **Done-when verified:** live browser drive as Brian — add → view → log-contact (overdue→Current flip) → edit cadence (next-due re-derived) → delete, all persisting across a full page reload; empty states, mobile 375px layout, and no-console-errors checked; 33 tests + `tsc` + ESLint clean. | Login UI was built this session (not in the §7 step list) because the scoped API needs a session — required infrastructure. **JSX whitespace trap:** `turns {name} green` dropped the space after the expression; use a template literal (`{\`…${name}…\`}`) for interpolated copy. Wide side-by-side (list+map) layout deferred to Session 4 with the map — narrow tabbed shell works at all widths for now. Filter/sort are client-side over server-provided cadence (instant chips, no refetch). Delete uses `window.confirm` (matches reference); fine for v1. |
| 4 | 2026-07-07 | Map + lasso + trip export. `lib/trip.ts` (pure/tested): `pointInPolygon` (ray-cast, concave-safe), `googleMapsUrl` (origin/dest/waypoints, ≤10 cap), `wazeUrl`, `haversineMiles`, and new `planRoute` (greedy nearest-neighbour ordering + per-leg + total miles — the prototype had no trip builder). `components/TerritoryMap.tsx`: Leaflet (npm pkg, not CDN) + CARTO `dark_all` tiles, status-colored divIcon pins (solid=exact, dashed=approx, brass ring=selected), pin labels HTML-escaped, tap-pin→detail, filter-aware. Freehand lasso ported exactly (pointer capture, SVG stroke, point-in-polygon in container space) — replaces selection; `+` on the list accumulates. `MapPanel.tsx` loads it `ssr:false` (leaflet needs window). `SelectionPanel.tsx`: ordered stops with numbered brass badges + leg mileage, summary (count/mappable/total mi), Google Maps (whole route) + per-stop Waze, needs-location block. Wired into App (Map/Selection tabs, `drawMode`, replace-vs-accumulate selection). **Done-when verified:** 46 tests green (13 new trip incl. concave PIP, waypoint/≤10 cap, NN ordering) + `tsc`/ESLint clean; live drive with 5 seeded TX accounts — map + pins render, **simulated lasso drag selected all 5 via point-in-polygon**, Selection built a 477-mi NN route (Houston→Austin×2→San Antonio→Dallas), and the Google Maps URL (origin+3 waypoints+dest) and Waze links were correct. Test accounts cleaned; book left empty. | Used **vanilla Leaflet imperatively** (matches the prototype) — `react-leaflet` is installed but unused; candidate for removal. CARTO tile host + Leaflet inline marker styles will need CSP allowances in Session 6. Wide side-by-side (list+map) layout still deferred — tabbed shell works at all widths. Lasso auto-test: dispatch PointerEvents on the `__overlay` div with `offsetX/Y` overridden (Leaflet's own `leaflet-overlay-pane` also matches `[class*=overlay]` but is 0×0 — target `__overlay`). |
| 5 | 2026-07-07 | Import + background geocoding. `lib/geocode.ts` — THE swap boundary (server-only): `geocodeOne(account)⇒{lat,lng,confidence,source}` hits Nominatim (fixed endpoint, encoded query, UA header), coords→exact, address→geocoded/low (by importance), no-address→needsLocation; **throws GeocodeTransientError on 429/5xx/network** (retry) vs terminal miss; NaN/range-guarded so it never stores a bad pin. `lib/geocodeWorker.ts` — in-process queue drainer, one job at a time, ~1.1s throttle, ≤3 attempts, then geocodeState `failed`+confidence `needsLocation`. `lib/import.ts` — papaparse CSV with fuzzy header detection (name/title, city, address/street, lat, lng/lon, cadence), row/cell caps, malformed rows skipped with a count. Routes: `/api/import/{preview,commit}`, `/api/geocode/status`, `/api/geocode/retry/:id` — all userId-scoped. `ImportView.tsx` (paste/upload, confidence-badged preview, commit); App polls `/geocode/status` while queued>0 (Locating N… indicator) and refreshes pins; DetailSheet gains a "Locate from address" retry. Location vocab centralized in `lib/accounts/location.ts`. **Done-when verified:** 65 tests green (+10 CSV parse incl. aliases/skip/NaN-guard/quoted, +9 geocodeOne incl. 429/5xx-throw, 4xx-miss, NaN, low-importance) + `tsc`/ESLint clean; live import of a mixed CSV committed instantly and the worker geocoded 2 addresses via **real Nominatim** (Dallas/Austin) → pins appeared; DB confirmed source=geocode/confidence=low/state=done and address-less row stayed idle. Test data cleaned. | Used **vanilla Leaflet**-style direct provider call in geocodeOne (not a `/api/geocode` proxy) — matches WAYLINE_BUILD.md §5's "one server module" and §6 (which lists only geocode status/retry, no bare `/api/geocode`). In-process worker assumes **one Node process** (v1/NAS) — multi-instance needs a locking queue behind the same enqueue/kick interface. **`GeocodeJob` has no FK cascade** to Account (plain accountId) → orphan jobs on delete; worker tolerates it (marks done if account gone), but add a relation+cascade in Session 6. `TabPlaceholder` removed (all tabs now real). |
| 6 | 2026-07-09 | PWA + hardening + QA. **Security headers** (`next.config.ts`): HSTS, X-Content-Type-Options nosniff, X-Frame-Options DENY, Referrer-Policy, Permissions-Policy (geolocation=(self) for GPS, else deny). **CSP + CSRF** in `proxy.ts` (Next 16 renamed middleware→proxy): per-request script **nonce** + `strict-dynamic` (no unsafe-inline scripts; `unsafe-eval` dev-only), `style-src 'unsafe-inline'` (inline style attrs can't be nonced), `img-src` allows CARTO tiles, `frame-ancestors 'none'`, everything else `'self'`; CSRF = same-origin check rejecting cross-origin API mutations (403). **PWA**: `app/manifest.ts` (standalone, warm-dark), brass-W PNG icons (192/512/apple, generated via sharp), install-only service worker (`public/sw.js`, no offline cache) registered by `components/ServiceWorker.tsx`. **GeocodeJob→Account FK cascade** migration (Session-5 follow-up). README rewritten (setup/scripts/security/update). **npm audit:** 5 moderate, all dev-only (prisma dev-deps→hono, build-time postcss) — the only "fix" downgrades Next to 9.x; triaged/accepted. **Done-when verified:** 65 tests green + tsc/ESLint clean; live: app loads + hydrates under the nonce CSP with **zero console violations**, CARTO tiles + Leaflet dynamic-import load fine, all 5 headers + CSP present on responses, **CSRF 403 on foreign Origin** (same-origin passes to 400/validation), manifest/sw.js/icons serve 200, SW registered. | Nonce CSP requires dynamic rendering — fine, `/` is already force-dynamic. `proxy.ts` uses `btoa` not `Buffer` (Edge runtime). Real phone install + on-device GPS/lasso QA is Bronson's to do post-deploy (can't drive a physical device here). `pg_dump` backup routine lands with the prod stack in Session 7. Two follow-ups accepted for v1: CSRF host-compare assumes Cloudflare preserves Host (revisit if the tunnel rewrites it); `unsafe-inline` styles unavoidable with inline style attributes. |
| 7 | 2026-07-09 | **Deploy artifacts staged** (on-NAS deploy deferred — awaiting the UGreen's hard drives). `Dockerfile` (multi-stage deps→build→runner; full deps kept so the image also runs `prisma migrate deploy`/`db:seed`; native modules built in-container), `.dockerignore`, `docker-compose.prod.yml` (app + Postgres + `cloudflared`, **nothing published** — cloudflared reaches `wayline-app:3000` internally, DB on the compose network only, named volume `wayline-db-data`), `.env.production.example`, and `DEPLOY.md` (one-time setup, Cloudflare token tunnel → `wayline-app:3000`, migrate/seed/book-load, updates, `pg_dump` backup + restore-verify). `.gitignore` keeps `.env.production` secret while committing the template. **Verified (no NAS needed):** `docker compose -f docker-compose.prod.yml config` valid; **image builds clean** (linux argon2/sharp compiled, in-container prisma generate + `next build`, proxy/middleware recognized); the built image **runs `next start` and serves** (root 200) with the **production CSP** (`upgrade-insecure-requests`, no `unsafe-eval`) and connects via the runtime `DATABASE_URL`. | On-NAS steps remain (Bronson's, post-hardware): install drives + enable Docker, create the Cloudflare tunnel/token + public hostname, `compose up` + migrate + seed, load the book into prod, verify from a phone off-Wi-Fi, schedule the `pg_dump` cron. Container-to-container DB is guaranteed by compose service DNS (an ad-hoc `docker run` hit a Docker-Desktop `EAI_AGAIN` quirk — not an artifact issue). **Data note:** Dorann Prachyl's 232-account book is loaded in the **dev** DB (real cadence; 230 city-level pins); re-loads into prod at deploy. |
| R1 | 2026-08-06 | **Review + remediation pass** (no feature work). **Secrets:** untracked `.env` — it reached the public repo via GitHub's web uploader, which bypasses `.gitignore`, exposing `SESSION_SECRET`, dev DB creds and a seed password (contradicting §7); also untracked `files.zip`, `tsconfig.tsbuildinfo`, `next-env.d.ts` and replaced the real email in `.env.production.example`. **`proxy.ts`:** `Origin: null` / malformed Origin made `new URL()` throw → 500 instead of the intended 403 (both now block); same-origin check widened from `/api/`-only to every non-safe method, since Server Actions POST to page routes. **Dockerfile:** runs as the `node` user (§9 required non-root; it ran as uid 0) and prunes devDependencies from the runner — `prisma`, `tsx`, `dotenv` moved to `dependencies` so the image still runs `migrate deploy`/`db:seed` (`prisma.config.ts` imports `dotenv/config`). **Deps:** Next **16.2.9 → 16.3.0**, `npm audit fix`, and all three Prisma packages aligned at **7.9.1** (audit fix moved the CLI alone, and a CLI/client skew is exactly the Session-1 generation trap). **CI:** added `.github/workflows/ci.yml` — install, `migrate deploy`, regenerate client, tsc, lint, format, tests against a real Postgres, and `npm audit --omit=dev --audit-level=high`. **Verified:** `proxy.ts` typechecks clean under 16.3.0 and passes an 8-case Origin drive (same-origin, cross-origin, opaque, malformed, absent, GET-exempt, both page-route directions); `npm audit` **0 vulnerabilities**. | **Session 6's "5 moderate, all dev-only" audit triage was stale** — by 2026-08 Next 16.2.9 carried 9 advisories incl. `GHSA-6gpp-xcg3-4w24` (**Middleware/Proxy bypass**, i.e. a bypass of this app's CSP+CSRF layer), Server-Action SSRF, and cache confusion. 16.3.0 clears all of them; re-check `npm audit` before each deploy rather than trusting a past triage. **Unverified here:** the Dockerfile (no Docker daemon in the review env) and CI (needs the source) — both need a real build before the NAS deploy. **Still open:** the leaked secrets are untracked but NOT rotated and remain in `main`'s history; `app/`, `lib/`, `components/`, `prisma/`, `tests/`, `public/` are still absent from the repo, so the tree cannot build. |
| 6.5 | 2026-08-08 | **PARTIAL — docs only.** Cadence semantics correction per `WAYLINE_CADENCE_PATCH.md`. **Done:** patch spec committed to the repo root; superseded banners added verbatim to WAYLINE.md / WAYLINE_BUILD.md / WAYLINE_PRODUCT.md (§8a); WAYLINE.md data model → `lastVisitAt` + 3-type enum, cadence sentence now "latest **visit**" (§8b); WAYLINE_BUILD.md §2 locked-decisions row, §4 schema (`lastVisitAt`, action comment), §4/§5 status formula + log-visit/call/catalogs wording, §6 log route body, Session 2 steps 3–4 and Session 3 step 3 + both done-when lines (§8c); WAYLINE_PRODUCT.md §4 scope, §5 Interaction log + Account + Status, §6 "Log visit — today", §9 acceptance (§8d). §8e `git rm --cached` of `.env`/`files.zip`/`tsconfig.tsbuildinfo`/`next-env.d.ts` already landed in the review pass (commit d35517d). | **NOT DONE — §2–§7 are blocked, not skipped.** The application source has never been pushed to this repo: `app/`, `lib/`, `components/`, `prisma/`, `tests/`, `public/` are all absent (the 2026-08-06 web upload carried root-level files only). So the schema migration + data backfill (§2), `deriveCadence`/log-transaction visit-gating (§3), zod enum + route body (§4), the three-button DetailSheet and `store.logInteraction` (§5), all six test cases (§6), and the warn-window constant extraction (§7) have **no files to edit**. The docs now describe behavior the code does not implement — that gap closes only when the source lands and §2–§7 run. **Also outstanding:** `WAYLINE_MASTER_PLAN.md` was not supplied, so it is not committed even though the new banners reference it; and §8e's precondition — rotating `SESSION_SECRET`, the Postgres password and the seed credentials leaked in `fed1619` — has not been confirmed done. **Deviation logged:** three further `lastContact` references in WAYLINE_PRODUCT.md (Account concept, Status formula, §7 data model) were not enumerated in §8d but were corrected under §5's copy sweep — leaving them would have contradicted the new banner. Historical BUILD LOG rows (Sessions 0–7) were left verbatim: they record what shipped at the time, and rewriting them would falsify the log. |
