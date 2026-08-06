# WAYLINE — Design Spec

> Visual system and interaction model for Wayline. Pair this with `WAYLINE_BUILD.md`
> during the UI sessions (3 and 4). The working `wayline-map.jsx` artifact is the
> living reference; this document is the written source of truth behind it.

---

## 1. DESIGN PRINCIPLES

1. **Legible at a glance, one-handed.** Brian uses this in a truck, at a stop,
   between meetings. Status must read in a half-second; primary actions must be
   thumb-reachable. Never make him hunt.
2. **Time-driven first, territory second.** The list (who needs me and when) is
   the home surface; the map is a complementary view, not the star. An earlier
   build over-weighted the map — don't repeat that.
3. **Confident and premium, not generic SaaS.** Warm, dark, brass-accented. It
   should feel like a considered tool, not a dashboard template.
4. **One gesture, one meaning.** Tapping an account = see/act on it. The lasso =
   build a multi-stop day. The `+` = add to a trip selection. These never collide.
5. **Honest states.** "No pin," "approx," "needs location," "saving," "not saved"
   are shown plainly. Never fake certainty the data doesn't have.

---

## 2. COLOR SYSTEM

```
Background base      #1c1410   deep warm brown-black
Background raised    #241a14   subtle lift (sticky bars, sheets)
Card                 #2c211a
Card hover/high      #352820
Hairline / border    #3d2f25

Ink (primary text)   #f3e9df   warm off-white
Ink dim              #b09a87   secondary text
Ink faint            #7c6a5b   tertiary / captions

Brass                #c79a5b   accent base
Brass highlight      #e8c98a   accent light (gradients, active)
Brass gradient       linear-gradient(120deg, #e8c98a, #c79a5b)

Status — overdue     #c5613f   rust
Status — due/soon    #d9a23f   amber
Status — current     #7fa06a   sage
```

**Usage rules**
- Brass gradient: the wordmark and the single primary action on a surface
  (e.g. "Log contact — today"). Don't scatter it; one hero action per view.
- Status colors: the account dot, the status pill, and the left border accent on
  cards. Rust/amber/sage carry meaning — never use them decoratively.
- Destructive (delete): rust text on transparent with a rust hairline border,
  never a filled rust button (avoid alarm; it's a deliberate, not primary, action).
- Backgrounds stack shallow: base → raised → card → card-high. Keep contrast gentle.

---

## 3. TYPOGRAPHY

- **Family:** Inter, then system sans (`system-ui, -apple-system, sans-serif`).
- **Scale (px):**
  - Wordmark / screen title: 25–26, weight 800, letter-spacing -0.5
  - Section / sheet title: 18–21, weight 700–800
  - Row title (account name): 14.5, weight 600
  - Body / labels: 13–13.5
  - Subline / meta: 11.5–12.5, ink-faint
  - Micro-labels (ALL-CAPS field labels): 10.5–11, letter-spacing 0.5–0.6
- **Numbers that matter** (counts, mileage, stat values): weight 700–800, slightly
  larger, in ink or brass — they're glanceable anchors.

---

## 4. SHAPE, SPACING, MOTION

- **Radii:** cards 14, chips/pills 999 (full), buttons 10–12, inputs 10, sheets 22 (top corners).
- **Padding:** cards 14–16; screen gutters 16; sheet 22.
- **Gaps:** 8 between chips, 12 between cards, 10–14 in grids.
- **Dot glow:** status dots carry a soft `0 0 8px <color>88` glow so they read on dark.
- **Motion:** subtle only.
  - Rows rise in: 8px translate + fade, ~0.5s, tiny stagger.
  - Detail sheet: slide up 40px + fade, ~0.28s, ease-out cubic.
  - Respect `prefers-reduced-motion` — disable animations when set.
- **Touch targets:** minimum 44×44 effective; the `+`/action buttons are ≥30px with padding.

---

## 5. LAYOUT & RESPONSIVENESS

- **Mobile-first, iOS-first spacing.** Design at ~390px width; scale up.
- **Narrow (phone):** List / Map / Selection / Import are **linked tabs** that
  share filter + selection state. Switching tabs feels like turning one object over.
- **Wide (≥900px):** List and Map sit **side by side** (list left ~340–440px, map
  right, sticky), with Selection beneath the map and Import below. Same shared state.
- **Sticky:** the filter bar and tab bar stick to the top with a blurred translucent
  base (`#1c1410f2`, backdrop-blur) so context stays while scrolling.

---

## 6. CORE COMPONENTS

### Status dot
Small filled circle with glow. Hollow/dashed variant = approximate location.
Color = cadence status.

### Status pill
`<dot> Label` in the status color on a tinted background (`<color>1c`) with a
`<color>44` hairline. Used in the detail sheet header and, compactly, on cards.

### Account row (list)
```
[status dot]  Account Name           [ + ]
              Status · City · last contacted 3 mo ago
```
- Tap the name/main area → **open detail**.
- The `+`/`✓` on the right → toggle into the **trip selection** (separate button).
- "no pin" mini-badge (amber outline) when the account has no coordinates.
- Selected rows get a faint brass wash (`#c79a5b14`).

### Account card (alt, richer view)
Left border in the status color; name + city/contact; two meta lines
(last contact, catalog/next-due); a big brass primary action + a small `⋯` menu.

### Detail sheet (bottom sheet)
- Header: name + city, status pill.
- 2×2 **facts grid:** Last contact / Next due / Location / On map.
- **Primary:** "Log contact — today" (brass gradient, full width). Caption explains
  it resets the cadence clock and turns the account green.
- **Cadence selector:** 90 / 180 / 365 segmented buttons; active = brass.
- **Delete:** rust outline button near the bottom, behind a confirm.
- Close on backdrop tap or Close button.

### Filter chips
All / Overdue / Due / Current. Active = brass tint + brass border + brass-hi text.
Drives BOTH the list and the map, and constrains what the lasso can catch.

### Sort chips (list)
Overdue first / A–Z / By city / Longest gap. "By city" inserts light ALL-CAPS
city headers into the list.

### Map
- Leaflet + OpenStreetMap **CARTO dark** tiles (`dark_all`), so the map matches the
  warm-dark shell rather than fighting it.
- Pins: 14–16px status-colored dot + name label with text-shadow for legibility.
  Solid = exact; dashed ring = approximate. Selected pins get a brass ring + glow.
- "✏ Draw area" button top-right; when active, the map locks and a status ribbon
  reads "Draw a loop around the accounts you want."
- Lasso stroke: dashed brass path, translucent brass fill.

### Selection / trip view
- Ordered stop list with numbered brass badges and leg mileage between stops.
- Summary band: stop count + total miles + "Route on map →".
- Export: "Open in Google Maps" (brass, multi-stop) and per-stop "Waze" links.
- "Needs location" block (rust-tinted) for selected accounts without a pin.

### Add-account form
Name (required), City, Address, a "📍 Use my current location" button (turns sage
"✓ Location captured" on success), and a 90/180/365 cadence picker. Save is a brass
gradient button; disabled until a name exists.

### Empty states
- No accounts at all: "Start your book" with a primary add button + import pointer.
- Filtered to nothing: "Nothing matches this filter" with a gentle nudge.
Empty states are calm and instructive, never blank.

---

## 7. INTERACTION MODEL (the rules that keep it coherent)

| Gesture | Result |
|---|---|
| Tap account row (main area) | Open detail sheet |
| Tap map pin | Open detail sheet |
| Tap `+` / `✓` on a row | Toggle account into trip selection |
| Draw lasso on map | Replace selection with accounts inside the loop |
| Seed a city (trip view) | Add that city's due/overdue accounts to selection |
| Change filter | Re-scope list + map + what the lasso can catch |
| Log contact (detail) | Reset cadence clock → status flips toward sage |

- **Detail is a single-account concept.** Lassoing many is a different mode
  (trip/export); don't try to show detail for a multi-selection.
- **Lasso replaces; `+` accumulates.** Drawing an area means "show me this region";
  tapping `+` means "add this one." Each does what's natural for it.
- **Save is implicit.** No save buttons; actions persist immediately with a quiet
  "Saving… / ✓ Saved" indicator.

---

## 8. VOICE & MICROCOPY

- Plain, rep-friendly, confident. "never miss an account, never waste a trip."
- Say what a control does in the rep's terms: "Resets the cadence clock and turns
  [Name] green until it's due again."
- Name honest states without drama: "approx pin," "needs a location,"
  "Google Maps takes up to 10 stops — the first 10 go."
- No jargon, no exclamation-heavy hype, no emoji beyond the two functional ones
  (📍 location, ✏ draw).

---

## 9. ACCESSIBILITY

- Maintain contrast: ink on base passes; don't drop meaningful text to ink-faint.
- Status is never color-only — always paired with a label ("Overdue," "Due").
- Every icon-only control has an `aria-label` / title.
- Honor `prefers-reduced-motion`.
- Hit targets ≥44px effective; inputs 16px font to avoid iOS zoom-on-focus.
```
