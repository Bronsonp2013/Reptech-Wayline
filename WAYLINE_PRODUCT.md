# WAYLINE — Product Spec

> The "what and why" behind Wayline. Pair with `WAYLINE_BUILD.md` (the how) and
> `WAYLINE_DESIGN.md` (the look). When a feature decision is ambiguous during a
> build session, this document is the tie-breaker.

---

## 1. VISION

Wayline is a field-sales territory and cadence tracker for manufacturer's reps.
It exists to answer two questions well and nothing else:

1. **"Who needs me and when?"** — surface which accounts are falling out of their
   contact cadence, so no relationship goes cold and no obligation is missed.
2. **"Is this drive worth it?"** — help batch the right accounts into an efficient
   day, so time and fuel aren't wasted on one-off runs or dead addresses.

Everything in v1 serves those two questions. Features that don't are out of scope.

---

## 2. THE PROBLEM (why this exists)

Brian is a furniture manufacturer's rep covering a Texas territory. Today he has:
- **No system that tells him who's overdue** for contact — he reconstructs it by hand.
- **Wasted drives** to addresses that turned out vacated or inactive.
- **No efficient way to batch stops** into a sensible route for a day on the road.
- **A qualify-first need:** many designers are appointment-only, so he must confirm
  an account is active (usually by phone) before driving out.

Wayline replaces the mental math and scattered notes with one tool that keeps the
cadence clock, holds real locations, and turns "who's due near each other" into a
drive he can hand to Google Maps or Waze.

---

## 3. USERS & GROWTH PATH

- **Launch user:** Brian (single user). The v1 experience is tuned for him.
- **Growth path:** Brian → other furniture reps → manufacturer's reps broadly.
- **Architectural implication:** build **multi-tenant from day one** (each rep sees
  only their own book) even though only Brian exists at launch. Keep the data model
  **generic** — no brand-, employer-, or furniture-specific fields baked into the
  core — so the same product serves other reps without a schema change.

---

## 4. SCOPE

### In scope (v1)
- Account book with per-account contact cadence.
- Cadence engine that flags overdue / due / current.
- Contact logging (resets the cadence clock; records action type).
- Map of the territory with real-coordinate pins.
- Lasso selection → trip building → hand-off to Google Maps / Waze.
- Manual single-account add (with GPS capture) and bulk CSV import.
- Background geocoding of addresses.
- Secure multi-tenant accounts and persistence.

### Explicitly NOT in scope (v1 non-goals)
- **Not a CRM** — no deal pipelines, no full contact records, no activity feeds.
- **Not order entry** — Wayline never touches orders or catalogs-as-inventory.
- **Not a routing engine** — it selects *who* to visit; Google Maps/Waze do the driving.
- **Not a team/admin tool** — no manager dashboards or cross-rep views.
- **Deferred:** Stripe billing, Google Places API, Takeout place-ID resolution,
  data export, CRM integrations, offline mode, push notifications, persistent
  named trips, analytics.

Keeping these out is a feature. Scope creep is the main risk to shipping in a month.

---

## 5. CORE CONCEPTS

### Account
A place Brian sells to or wants to: name, optional city/address, a location
(lat/lng from GPS or geocoding), a **cadence** (how often it should be contacted),
and a **last-contact** timestamp. Optionally a contact name.

### Cadence
How many days between contacts for this account: **90 / 180 / 365** presets.
Different account types warrant different rhythms (a top retailer every 90 days;
a quiet designer every 365). Cadence is **per-account and editable** — this is what
makes Wayline a product rather than a one-off list.

### Status (derived, never stored stale)
From `lastContact + cadenceDays` vs. today:
- **Overdue** — past due (or never contacted).
- **Due now** — within 14 days of due.
- **Due soon** — within 30 days.
- **Current** — more than 30 days of runway.
Status drives color everywhere (rust / amber / sage).

### Contact log
Logging a contact sets `lastContact = today` and records the **action type**
(`contact` or `catalog_drop`) so a catalog drop-off is distinct from a qualifying
call/visit. This is the core loop — the single action that moves an account from
red back to green.

### Trip selection
An ad-hoc set of accounts Brian is considering for a day, built by drawing a lasso
on the map, tapping `+` on list rows, or seeding a city. Ordered by a simple
nearest-neighbour heuristic and exported to a maps app. The selection is
session-scoped in v1 (persistent named trips are post-v1).

### Location & confidence
An account's pin comes from GPS (exact), geocoding (approx), or nothing yet
(needs location). Confidence is shown honestly — approximate pins look different,
and location-less accounts surface in a "needs location" list rather than vanishing.

---

## 6. KEY FLOWS

### Log a contact (the heartbeat)
Open account → "Log contact — today" → cadence clock resets, status flips toward
sage. This is the most-used action; it's one tap from the detail sheet.

### Add an account in the field
`+ Add account` → name/city/address/cadence → optionally "Use my location" for an
exact pin → Save. **Save commits immediately**; if only an address was given,
geocoding happens in the background so a flaky signal never loses the entry.

### Plan a day
Filter to Overdue → on the map, draw a lasso around a city or corridor → review the
selection (with mileage) → "Open in Google Maps" for the multi-stop drive, or grab a
single Waze link per stop. Qualify-first: Brian calls ahead before committing the drive.

### Bring in the book
Import tab → paste/upload CSV → preview (rows flagged exact / will-geocode /
no-location) → commit. Accounts appear instantly; pins fill in as the background
geocoder works through the queue.

---

## 7. DATA MODEL (product view)

Per account: `name`, `city`, `address`, `lat`, `lng`, `confidence`, `source`,
`cadenceDays`, `lastContact`, `contactName`, `geocodeState`, plus a history of
`ContactLog` entries (`action`, `loggedAt`, `notes`). Every account belongs to a
`user` (tenant). Nothing brand- or employer-specific lives in the core model.

(Full technical schema is in `WAYLINE_BUILD.md` §4.)

---

## 8. PRINCIPLES & HARD-WON LEARNINGS

- **Time-driven first, map second.** The list is home; the map complements it. An
  earlier iteration over-weighted the map and was corrected.
- **Detail access must be direct.** Tap an account → see it. Don't bury detail
  behind selection controls (this was corrected once — don't reintroduce it).
- **Lasso replaces, `+` accumulates.** Two natural gestures for two jobs; never
  make one tap do both.
- **Clean swap boundaries.** Geocoding lives behind one function; persistence behind
  one module. Backend upgrades (Google Places, real DB) must not touch feature code.
- **Save can't depend on the network.** Adds commit locally/immediately; geocoding
  is best-effort on top. A dead zone never loses data.
- **Keep the model generic.** Protect the growth path by refusing to hardcode
  Brian-specific specifics.
- **Real map libraries for geography.** SVG map hacks failed repeatedly; Leaflet +
  OpenStreetMap is the correct path.

---

## 9. SUCCESS CRITERIA (v1 is "done" when…)

- [ ] Brian can add accounts (manually with GPS, or by CSV import).
- [ ] Addresses geocode in the background; pins appear without blocking.
- [ ] The list shows accurate cadence status with sort + filter.
- [ ] Logging a contact resets the clock and flips the status color.
- [ ] Cadence is editable per account.
- [ ] The map shows real pins; the lasso selects an area.
- [ ] A selection exports to Google Maps (multi-stop) and Waze (single).
- [ ] Accounts with no location surface in a "needs location" list.
- [ ] All data persists per user and survives reload.
- [ ] Each user sees only their own accounts (tenant isolation verified).
- [ ] It installs to a phone home screen and works in the field over cellular.

---

## 10. POST-V1 ROADMAP (prioritized)

1. **Persistent named trips** — save "today's plan" so it survives closing the app.
2. **Google Places API** — accurate pins + resolve Google Takeout place-IDs.
3. **Stripe billing** — $20/mo, $192/yr (20% off annual); single tier first.
4. **Multi-user onboarding** — invite flow (isolation already in the schema).
5. **Cadence history / light analytics** — contact patterns, coverage over time.
6. **Data export** — CSV/PDF of the book and activity.
7. **Offline mode** — cache + queue actions, sync on reconnect.
8. **Push notifications** — "Account X just went overdue."
```
