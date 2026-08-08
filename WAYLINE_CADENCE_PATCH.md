# WAYLINE — Cadence Semantics Correction (Session 6.5)

> **What this is.** A surgical patch session for Claude Code. The repo's docs and the
> built code (Sessions 1–6) implement a **two-type** contact model where *any* logged
> contact resets the cadence clock. That contradicts a locked product decision made
> after those docs were written. This file specifies the exact corrections — schema,
> logic, API, UI, tests, and doc edits.
>
> **How to run it:** "Read WAYLINE_CADENCE_PATCH.md. Execute all steps. Ask before
> deviating. Update the BUILD LOG in WAYLINE_BUILD.md when done."
>
> **Precedence:** Where this file conflicts with WAYLINE.md, WAYLINE_BUILD.md,
> WAYLINE_PRODUCT.md, or any other repo doc, **this file wins**. It implements
> decisions from WAYLINE_MASTER_PLAN.md.

---

## 1. THE LOCKED RULE (do not re-litigate)

There are **three** interaction types, not two:

| Type | Enum value | Resets cadence clock? |
|---|---|---|
| Visit (face-to-face) | `visit` | **YES — the only one** |
| Call | `call` | No — history only |
| Catalogs Updated | `catalogs_updated` | No — history only |

Cadence status is derived from the **most recent VISIT** only. A call or catalog
update never moves an account out of overdue. This is the entire point of the
product: no account silently lapses its required *face-to-face* cadence.

---

## 2. SCHEMA MIGRATION (`prisma/schema.prisma`)

**2a. ContactLog action values.** Change the comment/contract and migrate data:

```prisma
model ContactLog {
  ...
  action    String   // 'visit' | 'call' | 'catalogs_updated'
  ...
}
```

Data migration (in the generated SQL migration):

```sql
UPDATE "ContactLog" SET "action" = 'visit'             WHERE "action" = 'contact';
UPDATE "ContactLog" SET "action" = 'catalogs_updated'  WHERE "action" = 'catalog_drop';
```

Mapping rationale: every historical `contact` in Dorann/Brian's data came from the
call-log dedupe of *visits*, so `contact → visit` is correct. `catalog_drop` maps 1:1.

**2b. Rename `Account.lastContact` → `Account.lastVisitAt`.**
Use `@map` or an explicit `ALTER TABLE ... RENAME COLUMN` migration so data survives.
Semantics change with the name: this column is advanced **only** when a `visit` is
logged. Calls and catalog updates write a ContactLog row and touch nothing else.

---

## 3. LOGIC (`lib/cadence.ts`, log-contact transaction)

- `deriveCadence` reads `lastVisitAt` (or the latest ContactLog **where
  action = 'visit'** — keep whichever source the code already uses, but filtered
  to visits). Never-visited = overdue, as before.
- The log-interaction transaction: advance `lastVisitAt` **only if
  action === 'visit'**; otherwise insert the ContactLog row alone.
- Status buckets (overdue / due / soon / current) and day thresholds are unchanged
  by this patch. (See §7 for the warn-window follow-up.)

---

## 4. API + VALIDATION

- `POST /api/accounts/:id/log` body becomes
  `{ action: 'visit' | 'call' | 'catalogs_updated', notes? }`.
- Update the zod action enum in `lib/accounts/schemas.ts`.
- No new endpoints. Tenant scoping unchanged.

---

## 5. UI (`DetailSheet.tsx`, `lib/store.ts`, copy)

- Detail sheet: replace the single brass **Log contact** button with three actions.
  **Log visit** keeps the brass primary treatment; **Log call** and **Catalogs
  updated** are secondary. All three stay in the detail sheet — dashboard rows
  remain read-only (locked rule: rows inform, sheets act).
- Rename `store.logContact` → `store.logInteraction(id, action, notes?)` (or keep
  the name but require the action param — no default). Feature code still never
  calls `fetch` directly.
- Copy sweep: "last contact" → "last visit" everywhere status/next-due is shown.
  Interaction *history* (if/where listed) shows all three types.
- Microcopy on the secondary actions, so field behavior is unambiguous:
  "Logged to history — doesn't reset the visit clock."

---

## 6. TESTS (update + add)

Update the Session-2 cadence tests and add these cases — they are the acceptance
core of this patch:

1. Logging a **visit** flips overdue → current and re-derives next-due. (Exists;
   retarget from `contact` to `visit`.)
2. Logging a **call** on an overdue account: ContactLog row written, account
   **stays overdue**, `lastVisitAt` unchanged.
3. Logging **catalogs_updated**: same as #2.
4. Account with an old visit + a recent call derives status from the **visit** date.
5. zod rejects the legacy `contact` / `catalog_drop` action values (400).
6. Migration mapping covered by a data-shape test if the harness allows; otherwise
   verify manually in Prisma Studio post-migrate and note it in the build log.

**Done when:** full suite green (65+ new cases), `tsc` + ESLint clean, and a live
drive shows: overdue account → Log call → still overdue; → Log visit → current.

---

## 7. FOLLOW-UP FLAGGED, NOT IN THIS PATCH: warn window

Locked rule: cadence days **and warn window** are configurable globally and
per-account. `cadenceDays` is per-account already; the due (0–14) / soon (15–30)
windows are hardcoded in `lib/cadence.ts`. Do **not** build configurability in this
session — just extract the two thresholds into named constants in one place and add
a `// TODO(warn-window): make configurable per WAYLINE_MASTER_PLAN.md` marker.

---

## 8. DOC PATCHES (exact edits)

### 8a. Banner — add verbatim at the top of WAYLINE.md, WAYLINE_BUILD.md, and WAYLINE_PRODUCT.md

```markdown
> ⚠️ **Superseded in part.** Where this document conflicts with
> `WAYLINE_MASTER_PLAN.md` or `WAYLINE_CADENCE_PATCH.md`, those files win.
> Known correction: three interaction types (`visit` / `call` / `catalogs_updated`);
> **only visits reset the cadence clock.**
```

### 8b. WAYLINE.md

- Data model block: `type: "contact" | "catalog_drop"` →
  `type: "visit" | "call" | "catalogs_updated"  // only 'visit' resets the clock`
- `lastContactedAt` → `lastVisitAt` in the Account line.
- Cadence sentence: "compare now − latest ContactLog.at to cadenceDays" →
  "compare now − latest **visit** to cadenceDays".

### 8c. WAYLINE_BUILD.md

- §2 Locked Decisions, "Contact logging" row →
  `Logs timestamp **and** action type (visit / call / catalogs_updated). **Only 'visit' resets the cadence clock**; the other two are history-only.`
- §4 schema comment: `// 'contact' | 'catalog_drop'` →
  `// 'visit' | 'call' | 'catalogs_updated' — only 'visit' resets cadence`
- §4/§5: `lastContact` → `lastVisitAt` wherever the field is named; the status
  formula line becomes `lastVisitAt + cadenceDays vs. today`.
- §6 API: log route body → `{ action: 'visit' | 'call' | 'catalogs_updated', notes? }`
- Session 2 step 4 & acceptance checklist: "log flips overdue→current" →
  "logging a **visit** flips overdue→current; logging a **call** does not".

### 8d. WAYLINE_PRODUCT.md

- Line ~54: "Contact logging (resets the cadence clock…)" →
  "Interaction logging: **visits reset the cadence clock**; calls and catalog
  updates log to history only."
- Line ~98 ("…call/visit. This is the core loop…"): remove "call/" — the core
  loop action is the visit.
- Line ~117: "Log contact — today" → "Log visit — today".
- Acceptance ~172: "Logging a contact resets the clock" →
  "Logging a **visit** resets the clock; logging a call or catalog update does not."

### 8e. Housekeeping (same commit)

- Commit `WAYLINE_MASTER_PLAN.md` to the repo root (Bronson supplies the file).
- `git rm --cached .env files.zip tsconfig.tsbuildinfo next-env.d.ts` — they're
  gitignored but tracked from the web upload. **Secrets in `.env` must already be
  rotated before this lands** (Postgres password, SESSION_SECRET, seed credentials).

---

## BUILD LOG entry template

`| 6.5 | <date> | Cadence semantics correction per WAYLINE_CADENCE_PATCH.md: 3-type interaction enum, visit-only clock reset, lastContact→lastVisitAt migration, UI split into Log visit / Log call / Catalogs updated, docs patched + superseded banners. Tests: <n> green incl. call-does-not-reset. | <notes> |`
