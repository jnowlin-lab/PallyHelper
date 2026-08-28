# PallyHelper (v0.1)

Holy Paladin helper for **WoW TBC / Anniversary (2.5.x)**.

- **Swing timer + cast advisor** – times the tracked enemy's melee swings and
  tells you when to *start* casting so the heal *lands* just after the next hit.
- **Big-hit alert** – flashes a red **HEAL NOW** over the bar the instant the
  tank eats a crushing blow, a melee crit, a big special, or any hit over a
  set % of their health.
- **Danger-swing warning** – the swing bar goes red **!! LETHAL !!** when the
  tank's current health is at or below the biggest melee hit they've taken this
  fight (× a headroom factor) — i.e. the next swing could kill them.
- **Action-button glow** – the Blizzard spell-alert glow lights up your Flash /
  Holy Light action button during the CAST NOW window, so you don't have to
  watch the bar.
- **Personal cast bar** – your own cast bar sits directly under the swing bar,
  with a yellow tick showing where the tracked enemy's next swing lands on your
  cast's timeline, so you can see the two line up.
- **Adds-on-tank counter** – how many mobs are on the tank (combat-log based,
  works at any range).
- **Tank-debuff watch** – a line when the tank has a debuff that makes it take
  more damage: armor shred / damage-taken up / healing-reduction (Sunder,
  Faerie Fire, Meteor Slash, Mark of Hydross, Enfeeble, Mortal Strike, …),
  **or** loss of control (stun / fear / incapacitate) — a stunned paladin
  can't block, dodge or parry, so every hit lands full.

---

## Install

1. Copy the `PallyHelper` folder into:
   `World of Warcraft\_classic_\Interface\AddOns\`
   (so you have `...\Interface\AddOns\PallyHelper\PallyHelper.toc`)
2. On the character screen, open **AddOns** and enable it. Tick
   **"Load out of date AddOns"** if it shows as out of date.
3. `/reload` or log in.

### Fix the version number if it says "out of date"

In game run:

```
/run print((select(4, GetBuildInfo())))
```

Put that number in the first line of `PallyHelper.toc` (`## Interface:`).

### How the adds counter works

Enemy nameplates (default key `V`) help but are **not required**. The count is
the union of two sources:

1. **Combat log** — any creature that has damaged the tank in the last 5s.
   Range-independent, so it works even when you're healing from the back and
   the mobs have no nameplate. This is the main source.
2. **Nameplates** — visible mobs whose target or top threat (status ≥ 2) is the
   tank. Adds in-range mobs that haven't swung yet.

Because source 1 needs the tank hit at least once, a brand-new add shows up
about one swing after it reaches the tank.

**The tank** is resolved in this order: `/ph settank` → a group member with the
`TANK` role assigned → *(fallback)* the unit your hostile target is attacking
(`targettarget`). If none of those work the display shows `n/a` — run
`/ph diag` to see what's missing.

---

## Commands

| Command | Effect |
|---|---|
| `/ph` | show / hide the window |
| `/ph lock` | lock/unlock (unlock shows a grey box you can drag) |
| `/ph settank` | set the tank to your current target |
| `/ph cleartank` | clear it; fall back to group role auto-detect |
| `/ph spell flash\|holy` | which heal the advisor plans around |
| `/ph casttime <ms>\|auto` | override the cast time (auto = read from spellbook) |
| `/ph offset <seconds>` | how far *after* the swing you want the heal to land (default 0.15) |
| `/ph sound` | toggle the "cast now" sound (off by default; the bar also does a silent white flash on the rising edge) |
| `/ph fixedperiod <s>\|auto` | lock the swing period to a fixed value (e.g. `2.0`) instead of measuring |
| `/ph bighit` | toggle the big-hit **HEAL NOW** alert (on by default) |
| `/ph bigsound` | toggle the big-hit sound (on by default – it's a rare event, so it isn't the annoying one) |
| `/ph bigpct <percent>` | alert on any hit ≥ this % of the tank's max health (default 22) |
| `/ph debuffs` | toggle the tank-debuff watch line (on by default) |
| `/ph danger` | toggle the **!! LETHAL !!** danger-swing warning (on by default) |
| `/ph dangerfactor <n>` | headroom on the danger check (default 1.15) |
| `/ph glow` | toggle the action-button glow; reports how many buttons it found |
| `/ph castbar` | toggle your personal cast bar under the swing bar (on by default) |
| `/ph diag` | dump tank/nameplate/threat/debuff/danger state to chat |
| `/ph reset` | reset settings + position |

---

## How the swing timer works

1. Every `SWING_DAMAGE` / `SWING_MISSED` in the combat log from the tracked
   enemy is a landed swing – we store the timestamp.
2. The **swing period** is taken from `UnitAttackSpeed("target")` when the
   tracked enemy is your target (most accurate, updates with haste/slows), and
   otherwise from the **median of the last 5 measured intervals**.
3. Predicted next swing = `lastSwing + period`.
4. Lead time = heal cast time (spellbook or override) × haste buff factor +
   your world latency.
5. When `timeUntilNextSwing <= leadTime - landOffset`, the bar turns green and
   says **CAST NOW**. The white marker line on the bar is that start point.

The tracked enemy is your **current attackable target**, or `boss1..4` if you
have no target.

Most TBC bosses swing on a flat **2.0s** timer, so that is the fallback and the
value you'd lock with `/ph fixedperiod 2.0`. Measuring still matters for
dual-wielders, and for bosses that get hasted or slowed mid-fight.

**While the boss is casting**, the bar turns purple and shows
`CASTING: <spell> <secs>` instead of a swing prediction, and no CAST NOW prompt
is given (casts delay the next swing, so timing a heal into it is unreliable).
The gap that spans a cast is not used as a swing-period sample. When the cast
ends the normal prediction resumes and recalibrates on the next real swing.
Cast detection needs a unit for the boss (`target`, `boss1..4`, or `focus`).

## How the personal cast bar works

A thin `StatusBar` under the swing bar, driven by `UnitCastingInfo` /
`UnitChannelInfo` on the player. While you cast, a **yellow tick** marks where
the tracked enemy's next swing falls on your cast's timeline
(`(castElapsed + swingRemaining) / castTotal`, clamped to the bar):

- tick near/at the **right edge** → your heal finishes right around the hit —
  the timing you want.
- tick well **inside** the bar → the hit lands before your heal completes.

Hidden when you're not casting, or with `/ph castbar`. No tick while the boss
is casting (no swing prediction then).

## How the action-button glow works

On login and whenever your bars change (`ACTIONBAR_SLOT_CHANGED`,
`LEARNED_SPELL_IN_TAB`, `UPDATE_MACROS`), it scans the standard action bars plus
Bartender4 / Dominos / ElvUI button names for a slot holding the advisor spell
(`Flash of Light` or `Holy Light`). During the CAST NOW / LETHAL window it calls
`ActionButton_ShowOverlayGlow` on those buttons and hides it otherwise.

`/ph glow` toggles it and tells you how many buttons it matched — `0` means the
spell isn't on a recognised bar (macros aren't parsed). Only the exact spell is
matched, so a macro or a different rank on the bar won't glow.

## How the danger-swing warning works

Every `SWING_DAMAGE` on the tank is recorded (last 6). `dangerHitSize()` is the
biggest of those — a proxy for how hard the next swing could land (a crushing
blow is already in there if one happened). Each frame:

```
LETHAL  ⇔  tank current HP  ≤  dangerHitSize() × dangerFactor
```

`dangerFactor` defaults to **1.15** (`/ph dangerfactor`). When true the swing
bar turns solid red and reads `!! LETHAL !! <secs>`, overriding CAST NOW.

Needs a live unit for the tank to read current HP (group / nameplate /
`targettarget`); resets each fight. It's a heuristic, not a guarantee — an
un-seen crush or a stacked special can still exceed the estimate.

## How the tank-debuff watch works

Every ~0.15s it scans the tank's debuffs (needs a live unit for the tank — in
your group, or the `targettarget` fallback). Two categories:

- **amp** — armor shred / damage-taken up / −healing. Flagged if the name is in
  `AMP_BY_NAME` or the tooltip says "damage taken … increas…" / "armor … reduc…".
  Shown orange as `⚠ <name> xN` (N = stacks).
- **loc** — stun / fear / incapacitate. Flagged if the name is in `LOC_BY_NAME`
  or the tooltip says "stunned", "incapacitated", "unable to act", "asleep",
  "feared", etc. Shown red as `⚠ CAN'T MITIGATE - <name>`.

Only the single most severe debuff is shown. Tooltip results are cached per
spell, so the scan is cheap after the first sighting. Add missing spells to
`AMP_BY_NAME` / `LOC_BY_NAME` in the Lua.

## How the big-hit alert works

On every combat-log damage event **to the tank** (`SWING_DAMAGE`,
`SPELL_DAMAGE`, `RANGE_DAMAGE` – DoT ticks are ignored so bleeds don't spam),
it fires the alert if the hit was a **crushing blow**, a **crit**, or **≥
`bigpct`% of the tank's max health**. The alert shows the hit type and amount,
pulses for `bigHitDuration` (1.6s), and plays the raid-warning sound unless you
`/ph bigsound` it off.

The % check needs a live unit for the tank (in your group / on a nameplate) to
read max health; the crushing/crit checks work regardless.

### Known limitations / rough edges

- **First ~2 swings** have no measured period – it assumes 2.0s and shows a
  `~` until it has data.
- **Parry-haste** (boss parries the tank → its next swing is sooner) is modelled
  with the real rule: a parry shaves 40% of the weapon speed off the swing
  timer, floored at 20% remaining, and never delays a swing. Stacks per parry.
  A yellow `⚡` shows on the bar for ~0.6s when it fires. Still approximate — it
  uses the measured/locked period as "weapon speed".
- **Dynamic haste** other than Bloodlust/Heroism/Power Infusion is not
  modelled. Use `/ph casttime` to fine-tune, or add spell IDs to
  `HASTE_BUFFS` in the Lua.
- Boss special attacks / swing resets are not detected.
- Nameplate target detection depends on the client updating
  `nameplateNtarget`; a mob just off-screen won't be counted.

---

## Roadmap (things we can add next)

- [ ] Show a second bar for `boss1` while your target is an add.
- [ ] Per-boss saved weapon speeds (skip the 2-swing warmup).
- [ ] Option to also count adds targeting *you* (holy pally pulls via heals).
- [ ] Ace3 options panel instead of slash commands.
- [ ] Parse macros when matching the glow button.
- [ ] Sound/media via LibSharedMedia.
