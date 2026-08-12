# Wayline

Field-sales territory & cadence tracker for manufacturer's reps. _Never miss an
account, never waste a trip._

It answers two questions and nothing else: **who needs me and when** (contact
cadence — the home surface) and **is this drive worth it** (map / territory).
Single-user v1, but multi-tenant in the schema from day one.

Built to the specs in this folder:

- **WAYLINE_BUILD.md** — stack, schema, API, 8-session build order, deployment (+ BUILD LOG)
- **WAYLINE_PRODUCT.md** — vision, scope, non-goals, success criteria
- **WAYLINE_DESIGN.md** — colors, type, components, interaction rules
- **WAYLINE_SECURITY.md** — tenant isolation, auth, hardening checklist
- **WAYLINE_UI_REFERENCE.jsx.txt** — working visual/interaction prototype

## Stack

Next.js 16 (App Router) · TypeScript · PostgreSQL 16 · Prisma 7 (pg driver
adapter) · Leaflet + OpenStreetMap/CARTO · argon2id auth · Nominatim geocoding.
Styling is plain CSS variables + CSS Modules (no Tailwind).

## What works (Sessions 1–6)

Email+password auth with server-side sessions · account CRUD · derived cadence
status (overdue/due/soon/current) · list with filter+sort · detail sheet with
log-contact / cadence / delete · GPS capture · Leaflet map with status pins and a
freehand lasso · nearest-neighbour trip ordering with Google Maps + Waze export ·
CSV import with background geocoding · installable PWA.

## Local development

Prereqs: Node 20+, Docker Desktop.

```bash
# 1. Environment — copy the template and fill in secrets
cp .env.example .env
#    Set SESSION_SECRET (openssl rand -hex 32) and, to seed the user,
#    SEED_USER_EMAIL / SEED_USER_PASSWORD.

# 2. Install (also runs `prisma generate`)
npm install

# 3. Start Postgres (docker) — bound to 127.0.0.1:5433, never exposed
npm run db:up

# 4. Apply migrations and seed the single user
npm run db:migrate
npm run db:seed

# 5. Run the app
npm run dev                 # http://localhost:3000
```

`GET /api/health` returns live DB connectivity as JSON.

> **Prisma 7 note:** after any change to `prisma/schema.prisma`, run
> `npm run db:migrate` **and** `npm run db:generate` — `migrate dev` does not
> always refresh the generated client. If model access (`prisma.user`) is
> suddenly `undefined`, regenerate: `rm -rf generated/prisma && npm run db:generate`.

## Scripts

| Script                            | What it does                            |
| --------------------------------- | --------------------------------------- |
| `npm run dev`                     | Next dev server                         |
| `npm run build` / `start`         | Production build / serve                |
| `npm test` / `test:watch`         | Vitest                                  |
| `npm run lint`                    | ESLint                                  |
| `npm run format` / `format:check` | Prettier                                |
| `npm run db:up` / `db:down`       | Start / stop the dev Postgres container |
| `npm run db:migrate`              | Prisma migrate (dev)                    |
| `npm run db:seed`                 | Create/update the seeded user           |
| `npm run db:generate`             | Regenerate the Prisma client            |
| `npm run db:studio`               | Prisma Studio                           |

## Security posture

- Passwords argon2id-hashed; opaque server-side sessions (SHA-256-hashed tokens,
  httpOnly + SameSite=Lax cookies, rotation on login); login rate-limited.
- Every account/log/geocode query is scoped by `userId`; cross-tenant access is
  covered by a test (`tests/auth/tenant.test.ts`).
- All request bodies validated with zod; all DB access via Prisma (parameterized).
- Security headers in `next.config.ts`; CSP with a per-request script nonce and
  CSRF same-origin checks in `proxy.ts`.
- Secrets live only in `.env` (gitignored). Postgres is never published outside
  the Docker network. Geocoding runs server-side behind `lib/geocode.ts`.

## Updating (self-hosted)

**Follow [`DEPLOY.md`](DEPLOY.md) — do not improvise the update from memory.** It is
the single authority for the production sequence (backup → build → migrate → start)
and for rollback.

> ⚠️ **Never run `npm run db:migrate` against production.** It is
> `prisma migrate dev`, a *development* command: it uses a shadow database and, on
> any schema drift, offers to **reset the database** — i.e. drop Brian's book.
> Production migrations are `prisma migrate deploy`, which only applies pending
> migrations and never resets. Likewise, every production `docker compose` command
> needs `-f docker-compose.prod.yml --env-file .env.production`; a bare
> `docker compose up -d` starts the **dev** stack.

Full deployment (Docker Compose + Cloudflare Tunnel on the UGreen NAS, plus the
`pg_dump` backup routine) is Session 7 — see `WAYLINE_BUILD.md` §7–§8.

## Build status

See the **BUILD LOG** table at the bottom of `WAYLINE_BUILD.md`.
