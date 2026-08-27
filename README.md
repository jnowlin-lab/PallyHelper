# PallyHelper (v0.1)

Holy Paladin helper for **WoW TBC / Anniversary (2.5.x)**.

- **Swing timer + cast advisor** – times the tracked enemy's melee swings and
  tells you when to *start* casting so the heal *lands* just after the next hit.
- **Big-hit alert** – flashes a red **HEAL NOW** over the bar the instant the
  tank eats a crushing blow, a melee crit, a big special, or any hit over a
  set % of their health.
- **Adds-on-tank counter** – counts visible enemy nameplates whose current
  target is the tank.

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
| `/ph diag` | dump tank/nameplate/threat state to chat (use when the adds count looks wrong) |
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
- **Parry-haste** (boss parries the tank → its next swing is sooner) is only
  *approximated*. Fights where the tank parries a lot will drift.
- **Dynamic haste** other than Bloodlust/Heroism/Power Infusion is not
  modelled. Use `/ph casttime` to fine-tune, or add spell IDs to
  `HASTE_BUFFS` in the Lua.
- Boss special attacks / swing resets are not detected.
- Nameplate target detection depends on the client updating
  `nameplateNtarget`; a mob just off-screen won't be counted.

---

## Roadmap (things we can add next)

- [ ] Detect the tank automatically as "the unit the boss is targeting".
- [ ] Big-hit alert: also watch consecutive non-crush hits that stack into a danger window.
- [ ] Show a second bar for `boss1` while your target is an add.
- [ ] Per-boss saved weapon speeds (skip the 2-swing warmup).
- [ ] Better parry-haste model (track the tank's parry events + 40%/20% rule).
- [ ] "Time to next danger swing" using recent hit sizes vs tank health.
- [ ] Option to also count adds targeting *you* (holy pally pulls via heals).
- [ ] Ace3 options panel instead of slash commands.
- [ ] Sound/where-to via LibSharedMedia; TellMeWhen-style glow on the action button.
