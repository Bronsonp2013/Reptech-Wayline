# Pushing the application source

Everything in Sessions 1–6 — auth, cadence engine, map + lasso, CSV import,
geocode worker, PWA, 65 tests — exists only on your laptop. This repo holds
30 files: root configs and docs. This document is the exact sequence to marry
the two.

**Target:** `Bronsonp2013/Reptech-Wayline` (the existing repo).
**Run everything below on the laptop that has the source.**

> **Never use GitHub's web uploader for this.** It ignores `.gitignore` and does
> not recurse into folders. That single fact caused both the `.env` leak and the
> missing source. Git CLI only.

---

## Step 0 — Two things on github.com, before anything else

These are independent of the push, but the leak is live right now.

**0a. Make the repo private.**
Settings → General → scroll to Danger Zone → *Change visibility* → Private.

**0b. Rotate the three leaked secrets.** Commit `fed1619` published a real
`.env` to a public repo. The file is untracked now, but the blob is still
readable in history — I confirmed it today. Untracking did not un-leak it.

```bash
openssl rand -hex 32        # new SESSION_SECRET
```

Then set a new Postgres password and a new seed login in your local `.env`.
**If that seed password is reused anywhere personal, change it there first** —
that matters more than this repo does.

Going private does not un-leak it either; anyone who cloned it still has it.
Rotation is the only thing that ends the exposure.

---

## Step 1 — Work out what your source folder is

In the folder on your laptop that has `app/`, `lib/`, `components/`:

```bash
git remote -v
```

- **Prints a github.com URL** → you have a clone. Go to **Step 2A**.
- **Prints nothing, or "not a git repository"** → loose files. Go to **Step 2B**.

---

## Step 2A — Your folder is already a clone

The repo gained 6 commits your copy predates (security fixes, Next 16.3 bump,
CI gate, DEPLOY.md hardening). Bring them in first, or the push is rejected.

```bash
git fetch origin
git checkout main
git pull origin claude/wayline-source-push-35stdz
```

(That branch is `main` plus this document and the preflight script, so one pull
gets you the six commits *and* the tooling below.)

Conflicts should be confined to config and docs — `package.json`,
`package-lock.json`, `Dockerfile`, `next.config.ts`, `proxy.ts`, `README.md`,
both compose files. **Take the repo's side on all of them**; those versions are
newer and carry the security fixes:

```bash
git checkout --theirs package.json package-lock.json Dockerfile \
  next.config.ts proxy.ts README.md docker-compose.yml docker-compose.prod.yml
git add -A
git commit          # accept the merge message
```

If a conflict lands in a file under `app/`, `lib/`, or `components/`, stop and
tell me — that shouldn't happen and means the trees are more tangled than
expected.

Now skip to **Step 3**.

---

## Step 2B — Your folder is loose files

Clone the repo beside it, then copy the source in.

```bash
cd ~                                  # or wherever you keep projects
git clone https://github.com/Bronsonp2013/Reptech-Wayline.git wayline-push
cd wayline-push
git pull origin claude/wayline-source-push-35stdz
```

Copy only the source directories from your working folder — **not** config files,
**not** `node_modules`, **not** `.env`:

```bash
SRC=~/path/to/your/wayline            # <-- edit this
for d in app components lib prisma tests public; do
  [ -d "$SRC/$d" ] && cp -R "$SRC/$d" . && echo "copied $d"
done
```

If you have other source files at the root (`middleware.ts`, `instrumentation.ts`,
a `styles/` folder, etc.), copy those individually too. Do **not** copy
`package.json`, `Dockerfile`, `next.config.ts`, `proxy.ts`, or either compose
file — this repo's versions are newer.

---

## Step 3 — Format, then preflight

CI runs `prettier --check .` and fails the whole run on a formatting difference.
Your local files almost certainly predate this repo's Prettier config, so
normalize first:

```bash
npm install
npm run format
```

Then run the guard:

```bash
bash scripts/preflight-push.sh
```

It checks that no real `.env` is staged, that no CSV/XLSX customer data is
tracked (Brian's book is PII), that `node_modules` and build output are excluded,
that no high-entropy secret sits in a tracked file, and that the source
directories are actually present.

**Do not push until it exits green.** It is the guard against a repeat of
`fed1619`.

---

## Step 4 — Commit and push

```bash
git add -A
git status                  # eyeball the file list one last time
git commit -m "Add application source (Sessions 1-6)"
git push -u origin main
```

If the push fails on a network error, retry — wait 2s, then 4s, then 8s.

---

## Step 5 — What happens next

The moment `prisma/schema.prisma` lands, CI stops skipping and runs the full
12-step pipeline by itself. No switch to flip.

**Expect the first run to be red.** Those steps have never executed anywhere —
not on your laptop, not in CI. That is the gate working, not breaking. The three
most likely failures, in order:

1. **`Format check`** — anything `npm run format` missed.
2. **`Build production image`** — `docker build` has never run against the
   current `Dockerfile`, which now prunes dev dependencies and drops to the
   `node` user.
3. **`Build`** — `next build` catches Server/Client boundary violations that
   `tsc --noEmit` does not.

Post the failure and I'll work through it from here. Once the source is in the
repo I can read it, run it, and fix CI directly — which is the whole point of
getting it pushed.

---

## Troubleshooting

**`! [rejected] main -> main (fetch first)`**
Someone (me) pushed while you were working. `git pull origin main`, resolve as
in Step 2A, push again.

**`prisma.user is undefined`**
Prisma 7 doesn't reliably refresh the generated client on migrate:
```bash
rm -rf generated/prisma && npm run db:generate
```

**Do not run `npm run db:migrate` against anything real.** It is
`prisma migrate dev`, which offers to *reset the database* on drift. Production
is `prisma migrate deploy`.

**Preflight flags a file you think is fine.** Tell me which line — don't just
delete the check. It flagged `fed1619`-class problems by design.
