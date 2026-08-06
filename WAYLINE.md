# Wayline

Field-sales cadence + territory tracker. Single-user v1 for Brian, a furniture manufacturer's rep in Texas. It answers two questions and nothing else: **"who needs me and when"** (cadence — the primary axis) and **"is this drive worth it"** (map/territory — the complementary axis). Time-driven first; the map is never the primary view.

Fuller product spec, if present, lives in `docs/SPEC.md`.

## Non-goals (do NOT build these)

Not a CRM. Not a routing/optimization engine. Not order entry. Not a team tool. Never hardcode furniture-brand specifics — the data model stays generic so the product can grow (Brian → furniture reps → manufacturer's reps).

## Stack

- Next.js (App Router) + TypeScript — one full-stack codebase.
- PostgreSQL via Prisma.
- Leaflet + OpenStreetMap / CARTO tiles for the map. Do NOT use SVG maps — that approach was tried and abandoned three times.
- Backend geocoding: Nominatim now (throttled ~1 req/sec, queued), swappable to Google Geocoding/Places later without touching feature code.
- Deploy: Docker Compose (app + postgres) on a UGreen DXP4800 Pro (UGOS Pro), exposed via Cloudflare Tunnel for HTTPS.
- Auth: email + password, single user, no public signup. Multi-tenant-ready (every account row has `userId`).

## Reference implementation

`wayline-map.jsx` (the prototype we ported) is the source of truth for UI and interaction. Port its behavior, don't rebuild it — especially the freehand lasso (point-in-polygon + pointer capture), the geocoding boundary, and the Google Maps / Waze export logic. All proven; preserve exactly.

## The two swap boundaries — respect them

- `lib/store.ts` — the only module that talks to the backend/DB. Feature code calls `store`, never `fetch` directly. Keep its method signatures stable.
- `lib/geocode.ts` → `geocodeOne(account) => { lat, lng, confidence, source }` — the ONLY place a geocoding provider is called. It hits `/api/geocode`. Feature code never calls a provider directly.

## Data model

```
User       { id, email, passwordHash, timezone }
Account    { id, userId, name, city, address, lat, lng,
             confidence, source, cadenceDays, lastContactedAt }
ContactLog { id, accountId, at, type }        // type: "contact" | "catalog_drop"
```

Cadence status is DERIVED (compare now − latest ContactLog.at to cadenceDays) in `lib/cadence.ts`. Never store status as a column. `confidence` ∈ exact | geocoded | low | needsLocation. `source` ∈ gps | import | geocode | manual.

## Directory map

```
app/api/{accounts,contacts,geocode,auth}/route.ts   # route handlers
app/                                                 # pages / UI routes
components/                                           # ported artifact UI
lib/{store,geocode,cadence}.ts                        # the boundaries + logic
prisma/schema.prisma
docker-compose.yml   .env.example
```

## Commands

- `npm run dev` — dev server
- `npm run build` / `npm start` — production build / serve
- `npm run lint` — ESLint
- `npx prisma migrate dev` — apply migrations · `npx prisma studio` — inspect DB
- `docker compose up -d` — run app + postgres (local or on the NAS)

Keep this list accurate as the project evolves.

## Rules that prevent repeated mistakes

- ESM imports only; prefer named exports.
- Geocoding runs server-side only — a provider key NEVER reaches the frontend.
- GPS beats address when both are present: set the pin immediately at "exact" confidence and skip geocoding.
- A failed geocode stores `confidence: needsLocation` — never a bad/NaN pin.
- Never publish the Postgres port. Hash passwords (argon2). Rate-limit login.
- Account detail must be reachable directly (tap row or pin), never buried behind a selection control. The lasso is the only multi-select path.
