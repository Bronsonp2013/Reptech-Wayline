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

### 4. Build the image, and start only the database

**Order matters.** Starting `wayline-app` before the schema exists means it serves
500s against an empty database, fails its healthcheck, and can enter a restart
loop before you get to the migrate step. Build and migrate first, start last.

```bash
# Build the image, tagged so it can be rolled back to later.
IMAGE_TAG=$(date +%F) docker compose -f docker-compose.prod.yml \
  --env-file .env.production build

# Bring up Postgres alone and wait for it to report healthy.
docker compose -f docker-compose.prod.yml --env-file .env.production \
  up -d wayline-db
```

### 5. Migrate and seed — before the app serves anything

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npx prisma migrate deploy

docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npm run db:seed
```

> `migrate deploy` only applies pending migrations and never resets. **Never use
> `npm run db:migrate` here** — that is `prisma migrate dev`, which offers to drop
> the database on drift.

### 5b. Now start the app and the tunnel

```bash
IMAGE_TAG=$(date +%F) docker compose -f docker-compose.prod.yml \
  --env-file .env.production up -d
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

**Take the backup first.** A migration that fails halfway leaves the schema in a
state Prisma will not roll back for you — that dump is your only way out.

```bash
# 1. Pre-migration dump — this IS the rollback for a bad migration.
docker compose -f docker-compose.prod.yml --env-file .env.production \
  exec -T wayline-db pg_dump -U wayline wayline \
  | gzip > /volume1/backups/wayline-premigrate-$(date +%F-%H%M).sql.gz

# 2. Pull and build — build only, do NOT start the new code yet.
git pull
IMAGE_TAG=$(date +%F) docker compose -f docker-compose.prod.yml \
  --env-file .env.production build

# 3. Migrate BEFORE the new code serves traffic. Running `up -d` first would leave
#    new code talking to the old schema for however long you take to paste this —
#    e.g. every account read throwing `column "lastVisitAt" does not exist`.
docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npx prisma migrate deploy

# 4. Now roll the new image out.
IMAGE_TAG=$(date +%F) docker compose -f docker-compose.prod.yml \
  --env-file .env.production up -d
```

**If a migration fails partway**, Prisma marks it failed in `_prisma_migrations`
and every later `migrate deploy` refuses to run until it's resolved. Restore the
pre-migration dump (below), then clear the marker before retrying:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production \
  run --rm wayline-app npx prisma migrate resolve --rolled-back <migration_name>
```

### Rolling back a bad deploy

Because each build is tagged, the previous image is still on the NAS:

```bash
docker image ls wayline-app                    # find the previous tag
IMAGE_TAG=<previous-tag> docker compose -f docker-compose.prod.yml \
  --env-file .env.production up -d             # no --build: reuse the old image
```

If the **migration** was the problem, restore the pre-migration dump (see
Backups below) before starting the old image — an older app against a newer
schema will misbehave.

---

## Backups

Postgres data lives in the named volume `wayline-db-data`. Dump it on a schedule
to a protected NAS share:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production \
  exec -T wayline-db pg_dump -U wayline wayline | gzip > /volume1/backups/wayline-$(date +%F).sql.gz
```

### Schedule it (do this on day one, not "later")

Until this is scheduled, the only protection for Brian's book is a single Docker
volume. Save as `/volume1/scripts/wayline-backup.sh`, `chmod +x`, then add it in
**UGOS → Task Scheduler** as a daily job (e.g. 02:00):

```bash
#!/bin/bash
# Nightly Wayline backup with a 14-day rolling window.
# bash (not sh) because pipefail is essential here — see below.
set -euo pipefail

COMPOSE_DIR=/volume1/docker/wayline          # where docker-compose.prod.yml lives
BACKUP_DIR=/volume1/backups/wayline
STAMP=$(date +%F)
OUT="$BACKUP_DIR/wayline-$STAMP.sql.gz"

# A scheduler has no cwd and a minimal PATH — use absolute paths for both.
export PATH=/usr/local/bin:/usr/bin:/bin
mkdir -p "$BACKUP_DIR"
cd "$COMPOSE_DIR"

# Credentials come from the env file, not hardcoded, so rotating them doesn't
# silently break backups.
set -a; . ./.env.production; set +a

docker compose -f docker-compose.prod.yml --env-file .env.production \
  exec -T wayline-db pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
  | gzip > "$OUT"

# Sanity-check the size; an empty dump still compresses to a valid ~20-byte gzip.
test "$(stat -c%s "$OUT")" -gt 1000

find "$BACKUP_DIR" -name 'wayline-*.sql.gz' -mtime +14 -delete
```

Three details that are the difference between a backup and a comforting file:

- **`pipefail` is not optional.** The `> "$OUT"` redirect creates the file before
  `pg_dump` runs, and gzip happily compresses an empty stream. Without `pipefail`
  the script exits 0 on a failed dump and you bank a fortnight of valid-looking
  empty archives. This is the single most common way self-hosted backups fail.
- **Absolute paths and an explicit `PATH`.** UGOS Task Scheduler and cron give you
  neither a working directory nor `docker` on `PATH`; relative paths die instantly.
- **`-Fc` (custom format)** so `pg_restore` can do selective and parallel restores
  later. Restore with `pg_restore`, not `psql` — see below.

Adjust `COMPOSE_DIR`/`BACKUP_DIR` to wherever the stack and backup share actually
live on your NAS; `/volume1` is a convention, not a guarantee.

**Get a copy off the NAS.** Both the database volume and these dumps sit on one
appliance. An array failure, ransomware, or a bad firmware update takes the book
*and* every backup with it. Sync `$BACKUP_DIR` to cloud storage or an external
disk — this is the difference between a bad week and a lost book.

### Verify a restore — before you need it

**A backup you have never restored is not a backup.** Do this once now, into a
throwaway database rather than the live one:

```bash
C="docker compose -f docker-compose.prod.yml --env-file .env.production"

# Restore into a scratch DB, so a mistake can't touch production data.
$C exec -T wayline-db createdb -U wayline wayline_restore_test

gunzip -c /volume1/backups/wayline/wayline-YYYY-MM-DD.sql.gz | \
  $C exec -T wayline-db pg_restore -U wayline -d wayline_restore_test --exit-on-error

# Confirm the book actually came back, then drop the scratch DB.
$C exec -T wayline-db psql -U wayline -d wayline_restore_test -v ON_ERROR_STOP=1 \
  -c 'SELECT count(*) FROM "Account";'

$C exec -T wayline-db dropdb -U wayline wayline_restore_test
```

That account count is the whole point — it's the difference between having a
backup and believing you have one.

**Restore into a scratch database, never over the live one.** A plain dump piped
into an existing populated database produces a wall of "already exists" errors,
and `psql` without `ON_ERROR_STOP=1` **still exits 0** — so it looks like it
worked, you tick the box, and you have in fact still never validated a restore.
`--exit-on-error` and `ON_ERROR_STOP=1` above are what make failure visible.

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
- [ ] **`pg_dump` scheduled AND a restore verified.** Install the UGOS task from
      **Backups** below, then restore one dump into a scratch DB and check the account
      count. Until that's done the only protection for Brian's book is a Docker volume.
      A backup you have never restored is not a backup.
- [ ] **Container runs as `node`, not root.** Confirm with
      `docker compose -f docker-compose.prod.yml exec wayline-app id` → expect uid≠0.
- [ ] **Timezone is Central, not UTC.** Cadence is date-derived, so a UTC container can
      flip an account a day early near midnight. `TZ` is set in the compose file; confirm
      with `docker compose -f docker-compose.prod.yml exec wayline-app date` and spot-check
      that an account's next-due date matches what the UI shows.
- [ ] **First deploy is tagged.** Build with `IMAGE_TAG=$(date +%F)` so the *second*
      deploy has something to roll back to. `:latest` alone overwrites your only good image.

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
