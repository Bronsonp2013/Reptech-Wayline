# Wayline — Deployment Runbook (Session 7)

Self-hosted on a **UGreen DXP4800 Pro** (UGOS Pro / Docker), reached from the
field over an outbound-only **Cloudflare Tunnel** — no inbound ports opened on the
home network, Postgres never exposed.

Artifacts in this repo: [`Dockerfile`](Dockerfile),
[`docker-compose.prod.yml`](docker-compose.prod.yml),
[`.env.production.example`](.env.production.example).

---

## What you own first (not code)

1. **UGreen NAS** set up with its drives installed and **Docker enabled** (UGOS Pro
   → App Center → Docker). _(Blocked until the NAS hard drives arrive.)_
2. A **Cloudflare account** + a domain (or a Cloudflare-managed subdomain), with the
   domain's nameservers on Cloudflare.

---

## One-time setup

### 1. Get the code onto the NAS

```bash
git clone <your-repo-url> wayline && cd wayline
# (or copy the folder to a Docker share on the NAS)
```

### 2. Create the production env

```bash
cp .env.production.example .env.production
```

Edit `.env.production` and set:

- `POSTGRES_PASSWORD` — a strong random password (and mirror it inside `DATABASE_URL`)
- `SESSION_SECRET` — `openssl rand -hex 32`
- `SEED_USER_PASSWORD` — the login password for the seeded user
- `TUNNEL_TOKEN` — from the next step

### 3. Create the Cloudflare Tunnel

In the **Zero Trust dashboard** → **Networks → Tunnels → Create a tunnel**
(choose **Cloudflared**):

1. Name it (e.g. `wayline`), **Save**.
2. Copy the **tunnel token** it shows → paste into `TUNNEL_TOKEN` in `.env.production`.
   (We run cloudflared from Docker, so you don't need to install the connector it suggests.)
3. Under **Public Hostnames**, add:
   - **Subdomain/domain:** e.g. `wayline.yourdomain.com`
   - **Service:** `HTTP` → `wayline-app:3000`
4. **Save**.

### 4. Build and start the stack

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build
```

### 5. Migrate, then seed the user

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npx prisma migrate deploy

docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npm run db:seed
```

### 6. Load the account book (optional)

The book can be loaded into the prod DB the same way it was loaded in dev, or
entered via the **Import** tab in the app. Ask Claude Code to regenerate the
loader against the production `DATABASE_URL` when you're ready.

### 7. Verify from a phone, off Wi-Fi

Open `https://wayline.yourdomain.com` on cellular, log in, and **Add to Home
Screen** to install the PWA. Run the core loop: add → log contact → map/lasso →
export → import.

---

## Updating

```bash
git pull
docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build
docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npx prisma migrate deploy   # if there are new migrations
```

---

## Backups

Postgres data lives in the named volume `wayline-db-data`. Dump it on a schedule
to a protected NAS share:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production \
  exec -T wayline-db pg_dump -U wayline wayline | gzip > /volume1/backups/wayline-$(date +%F).sql.gz
```

Add that as a scheduled task in UGOS (or cron). **Verify a restore once:**

```bash
gunzip -c wayline-YYYY-MM-DD.sql.gz | \
  docker compose -f docker-compose.prod.yml --env-file .env.production \
  exec -T wayline-db psql -U wayline -d wayline
```

---

## Carried risks — verify these during the deploy

Consciously accepted during Sessions 5–6 and fine for v1, but they were buried in
BUILD LOG cells where nobody re-reads them. Each is either a check to run here or a
constraint to respect. Tick them as part of Session 7.

- [ ] **Host header through the tunnel.** The CSRF defense in `proxy.ts` compares the
      `Origin` host against the request `Host`. If Cloudflare Tunnel rewrites `Host`,
      every same-origin mutation starts 403-ing. **Verify once, live:** log in over the
      public hostname and log an interaction. A 403 here means the tunnel is rewriting —
      compare against the public hostname instead of `Host`.
- [ ] **Single Node process only.** The geocode worker (`lib/geocodeWorker.ts`) drains
      its queue in-process with no lock. Scaling `wayline-app` past one replica would
      double-geocode and burn the Nominatim courtesy limit. Multi-instance needs a
      locking queue behind the same enqueue/kick interface — don't scale until then.
- [ ] **`npm audit` before every deploy — do not trust a past triage.** Session 6 recorded
      "5 moderate, all dev-only, accepted"; by 2026-08 that had gone stale and Next 16.2.9
      was carrying 9 advisories, including a **Middleware/Proxy bypass**
      (`GHSA-6gpp-xcg3-4w24`) — a bypass of the CSP + CSRF layer in `proxy.ts` itself.
      Fixed by the 16.3.0 bump; the tree is clean as of 2026-08-08. CI runs
      `npm audit --omit=dev --audit-level=high`, but re-run it at deploy time too.
- [ ] **`pg_dump` scheduled AND a restore verified.** Until the cron below exists, the
      only protection for Brian's book is the Docker volume. A backup you have never
      restored is not a backup.
- [ ] **Container runs as `node`, not root.** Confirm with
      `docker compose -f docker-compose.prod.yml exec wayline-app id` → expect uid≠0.

Accepted permanently, no action needed:

- **`style-src 'unsafe-inline'`** in the CSP. Unavoidable while status colors and Leaflet
  marker positions ride on inline `style` attributes — those can't carry a nonce. Scripts
  are still nonce-gated with `strict-dynamic`, which is where the real XSS risk lives.

---

## Security invariants (don't regress these)

- **No published ports** on either DB or app — only cloudflared talks outward.
- `.env.production` is gitignored; secrets never enter the image (build-time
  placeholders are overwritten by runtime env).
- `NODE_ENV=production` turns on Secure cookies and the strict CSP.
- Protect the Cloudflare account with a strong password + 2FA — it's the front door.
