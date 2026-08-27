--[[--------------------------------------------------------------------------
  PallyHelper  -  Holy Paladin helper for TBC (2.5.x / Anniversary)

  Feature 1: Boss swing timer + "cast now" advisor
    - Watches the combat log for the tracked enemy's melee swings.
    - Estimates the swing period (prefers the live UnitAttackSpeed of your
      target, falls back to the median of recent swing intervals).
    - Tells you when to START casting Flash/Holy Light so it LANDS just
      after the next swing.

  Feature 2: Adds-on-tank counter
    - Walks the visible enemy nameplates and counts how many are currently
      targeting the tank.
    - Needs enemy nameplates enabled in game (default key: V).
    - Tank = whoever you /ph settank on, else auto-detected from group roles.

  This is a v1 scaffold - see README.md for known limits and the roadmap.
----------------------------------------------------------------------------]]

local ADDON = ...

--=========================================================================
-- Saved settings
--=========================================================================
local DEFAULTS = {
  locked          = false,
  spell           = "flash",      -- "flash" | "holy"
  castTimeMsOverride = nil,        -- number (ms) or nil = auto from spellbook
  landOffset      = 0.15,          -- aim to land this many seconds AFTER the swing
  useBloodlust    = true,          -- shrink cast time while a 30% haste buff is up
  sound           = false,    -- off by default; /ph sound to enable
  fixedPeriod     = nil,      -- lock the swing period to this many sec (nil = measure)
  bigHitAlert     = true,     -- flash "HEAL NOW" when the tank eats a crushing / crit / huge hit
  bigHitSound     = true,     -- rare event, so a distinct sound is on by default; /ph bigsound to mute
  bigHitPct       = 0.22,     -- also alert on any hit >= this fraction of the tank's max health
  bigHitDuration  = 1.6,      -- how long the alert stays up (seconds)
  tankDebuffWatch = true,     -- show a line when the tank has an armor/damage-taken/-healing debuff
  dangerWarn      = true,     -- flag the swing bar red when the next hit could kill the tank
  dangerFactor    = 1.15,    -- "lethal" if tank HP <= recent biggest melee hit * this
  tankGUID        = nil,
  tankName        = nil,
  point           = { "CENTER", "CENTER", 0, 150 },  -- { point, relativePoint, x, y }
  shown           = true,
}

local DB  -- resolved in ADDON_LOADED

--=========================================================================
-- Small helpers
--=========================================================================
local GetTime = GetTime

local function median(t)
  local n = #t
  if n == 0 then return nil end
  local c = {}
  for i = 1, n do c[i] = t[i] end
  table.sort(c)
  if n % 2 == 1 then return c[(n + 1) / 2] end
  return (c[n / 2] + c[n / 2 + 1]) / 2
end

local function worldLatencySeconds()
  local _, _, _, lw = GetNetStats()
  return (lw or 0) / 1000
end

-- 30% haste buffs a holy paladin might actually have in TBC
local HASTE_BUFFS = {
  [2825]  = 0.70,  -- Bloodlust
  [32182] = 0.70,  -- Heroism
  [10060] = 0.80,  -- Power Infusion (20%)
}

local function hasteMultiplier()
  if not DB.useBloodlust then return 1 end
  for i = 1, 40 do
    local name, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
    if not name then break end
    local m = HASTE_BUFFS[spellId]
    if m then return m end
  end
  return 1
end

-- Cast time of the chosen heal, in seconds, including latency + haste guess.
local function healLeadSeconds()
  local ms = DB.castTimeMsOverride
  if not ms then
    local spellName = (DB.spell == "holy") and "Holy Light" or "Flash of Light"
    local _, _, _, castMs = GetSpellInfo(spellName)
    ms = castMs and castMs > 0 and castMs
         or ((DB.spell == "holy") and 2500 or 1500)   -- sane fallbacks
  end
  local cast = (ms / 1000) * hasteMultiplier()
  return cast + worldLatencySeconds()
end

--=========================================================================
-- Swing tracking (combat log)
--=========================================================================
-- swings[guid] = { last = <GetTime>, period = <sec|nil>, samples = {}, name = "" }
local swings = {}

-- tankHitters[mobGUID] = last time that mob damaged the tank (range-independent
-- count source, since nameplates only exist for nearby mobs)
local tankHitters = {}
local HITTER_WINDOW = 5   -- seconds since last hit before a mob stops counting

-- recent raw melee-hit amounts on the tank (for danger-swing prediction)
local tankMeleeHits = {}

-- forward declarations (used by the combat log handler, defined lower down)
local currentTankGUID, currentTankMaxHP, currentTankHP
local triggerBigHit

local function isTrackableEnemy(guid)
  if not guid then return false end
  local kind = strsplit("-", guid)
  return kind == "Creature" or kind == "Vehicle"
end

local function recordSwing(guid, name)
  local now = GetTime()
  local s = swings[guid]
  if s then
    local dt = now - s.last
    -- Skip this interval as a period sample if a cast happened since the last
    -- swing -- casts delay swings, so the gap is not a real weapon-speed reading.
    if not s.castDirty and dt > 0.3 and dt < 8 then
      s.samples[#s.samples + 1] = dt
      if #s.samples > 5 then table.remove(s.samples, 1) end
      s.period = median(s.samples)
    end
    s.castDirty = nil
    s.last = now
  else
    swings[guid] = { last = now, period = nil, samples = {}, name = name }
  end

  -- Prefer the live weapon speed when this enemy is our current target.
  if UnitGUID("target") == guid then
    local sp = UnitAttackSpeed("target")
    if sp and sp > 0 then swings[guid].period = sp end
  end
end

-- Parry-haste: when a mob parries, 40% of its weapon speed is shaved off the
-- current swing timer, but it can't be pushed below 20% of the weapon speed
-- remaining. If the swing is already inside that 20% floor, a parry does
-- nothing (it must never *delay* the swing). Multiple parries in one cycle
-- stack because each call re-reads the current timer.
local function applyParryHaste(guid)
  local s = swings[guid]
  if not s then return end
  local now       = GetTime()
  local period    = (DB and DB.fixedPeriod) or s.period or 2.0
  if period < 0.3 then period = 2.0 end
  local remaining = (s.last + period) - now
  if remaining <= 0.20 * period then return end
  local newRemaining = math.max(0.20 * period, remaining - 0.40 * period)
  s.last   = now + newRemaining - period   -- so (s.last + period) == now + newRemaining
  s.parryAt = now
end

local function onCombatLog()
  local _, sub, _, srcGUID, srcName, _, _, dstGUID = CombatLogGetCurrentEventInfo()

  if sub == "SWING_DAMAGE" then
    if isTrackableEnemy(srcGUID) then recordSwing(srcGUID, srcName) end

  elseif sub == "SWING_MISSED" then
    if isTrackableEnemy(srcGUID) then recordSwing(srcGUID, srcName) end
    -- 12th return of CombatLogGetCurrentEventInfo for SWING_MISSED is missType
    local missType = select(12, CombatLogGetCurrentEventInfo())
    if missType == "PARRY" and isTrackableEnemy(dstGUID) then
      applyParryHaste(dstGUID)
    end
  end

  -- --- track mobs hitting the tank (range-independent adds count) -------
  if sub == "UNIT_DIED" or sub == "PARTY_KILL" then
    tankHitters[dstGUID] = nil
  elseif currentTankGUID and dstGUID == currentTankGUID and isTrackableEnemy(srcGUID)
     and (sub == "SWING_DAMAGE" or sub == "SWING_MISSED"
       or sub == "SPELL_DAMAGE"  or sub == "SPELL_MISSED"
       or sub == "RANGE_DAMAGE"  or sub == "RANGE_MISSED"
       or sub == "SPELL_PERIODIC_DAMAGE") then
    tankHitters[srcGUID] = GetTime()
  end

  -- --- record melee hit sizes on the tank (danger-swing prediction) -----
  if currentTankGUID and dstGUID == currentTankGUID and sub == "SWING_DAMAGE" then
    local amt = select(12, CombatLogGetCurrentEventInfo())
    if type(amt) == "number" and amt > 0 then
      tankMeleeHits[#tankMeleeHits + 1] = amt
      if #tankMeleeHits > 6 then table.remove(tankMeleeHits, 1) end
    end
  end

  -- --- big hit on the tank ---------------------------------------------
  if not DB or not DB.bigHitAlert then return end
  if not currentTankGUID or dstGUID ~= currentTankGUID then return end

  local amount, critical, crushing
  if sub == "SWING_DAMAGE" then
    -- payload: 12 amount .. 18 critical, 19 glancing, 20 crushing
    local a, _, _, _, _, _, crit, _, crush = select(12, CombatLogGetCurrentEventInfo())
    amount, critical, crushing = a, crit, crush
  elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" then
    -- payload: 12 spellId,13 name,14 school, 15 amount .. 21 critical .. 23 crushing
    -- (periodic/DoT ticks are deliberately excluded so a big bleed doesn't spam)
    local _, _, _, a, _, _, _, _, _, crit, _, crush = select(12, CombatLogGetCurrentEventInfo())
    amount, critical, crushing = a, crit, crush
  else
    return
  end
  if type(amount) ~= "number" then return end

  local huge = currentTankMaxHP and currentTankMaxHP > 0
               and amount >= DB.bigHitPct * currentTankMaxHP
  if (crushing or critical or huge) and triggerBigHit then
    triggerBigHit(amount, crushing, critical)
  end
end

--=========================================================================
-- Which enemy are we timing?
--=========================================================================
local function activeEnemyGUID()
  if UnitExists("target") and UnitCanAttack("player", "target")
     and not UnitIsDead("target") then
    return UnitGUID("target")
  end
  for i = 1, 4 do
    local u = "boss" .. i
    if UnitExists(u) and not UnitIsDead(u) then return UnitGUID(u) end
  end
  return nil
end

-- A unit token (target / boss1-4 / focus) that resolves to this GUID, if any.
local function guidToEnemyUnit(guid)
  if not guid then return nil end
  if UnitGUID("target") == guid then return "target" end
  for i = 1, 4 do
    if UnitGUID("boss" .. i) == guid then return "boss" .. i end
  end
  if UnitGUID("focus") == guid then return "focus" end
  return nil
end

-- If the tracked enemy is mid-cast/channel: returns spellName, fractionDone,
-- secondsLeft. Otherwise nil.
local function enemyCastState(guid)
  local u = guidToEnemyUnit(guid)
  if not u then return nil end
  local name, _, _, startMS, endMS = UnitCastingInfo(u)
  if not name then
    name, _, _, startMS, endMS = UnitChannelInfo(u)
  end
  if not name or not endMS then return nil end
  local now   = GetTime()
  local left  = endMS / 1000 - now
  local total = (endMS - (startMS or endMS)) / 1000
  if left <= 0 then return nil end
  local frac = (total > 0) and (1 - left / total) or 0
  return name, frac, left
end

--=========================================================================
-- Tank resolution
--=========================================================================
-- The unit token for a nameplate frame. Field name varies by client, so try
-- the known variants.
local function plateUnit(p)
  return p.namePlateUnitToken
      or p.unit
      or (p.UnitFrame and p.UnitFrame.unit)
      or (p.namePlateUnitFrame and p.namePlateUnitFrame.unit)
end

-- Find a live unit token for a GUID (needed to read the tank's max health).
local function guidToUnit(guid)
  if not guid then return nil end
  for _, u in ipairs({ "target", "focus", "mouseover" }) do
    if UnitExists(u) and UnitGUID(u) == guid then return u end
  end
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local u = "raid" .. i
      if UnitGUID(u) == guid then return u end
    end
  elseif IsInGroup() then
    for i = 1, 4 do
      local u = "party" .. i
      if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
  end
  for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
    local u = plateUnit(plate)
    if u and UnitGUID(u) == guid then return u end
  end
  return nil
end

-- Returns: unitToken (or nil), guid (or nil), name (or nil)
local function resolveTankUnit()
  -- 1. explicit /ph settank
  if DB.tankGUID then
    return guidToUnit(DB.tankGUID), DB.tankGUID, DB.tankName
  end
  -- 2. first group member whose assigned role is TANK
  local function scan(prefix, count)
    for i = 1, count do
      local u = prefix .. i
      if UnitExists(u) and UnitGroupRolesAssigned(u) == "TANK" then
        return u, UnitGUID(u), UnitName(u)
      end
    end
  end
  local u, g, n
  if IsInRaid() then u, g, n = scan("raid", 40)
  elseif IsInGroup() then u, g, n = scan("party", 4) end
  if u then return u, g, n end
  -- 3. fallback: whoever your hostile target is swinging at is probably the tank
  if UnitExists("target") and UnitCanAttack("player", "target")
     and UnitExists("targettarget") and not UnitCanAttack("player", "targettarget")
     and not UnitIsUnit("targettarget", "player") then
    return "targettarget", UnitGUID("targettarget"), UnitName("targettarget")
  end
  return nil
end

-- Distinct mobs on the tank = union of:
--   a) creatures that have damaged the tank in the last HITTER_WINDOW seconds
--      (from the combat log -- works at any range), and
--   b) visible nameplate mobs whose target/top-threat is the tank
--      (catches in-range mobs that haven't swung yet).
-- Returns count, or nil if we don't know who the tank is.
local function countAddsOnTank(tankGUID, tankUnit)
  if not tankGUID and not tankUnit then return nil end

  local now  = GetTime()
  local seen = {}
  for g, t in pairs(tankHitters) do
    if now - t <= HITTER_WINDOW then seen[g] = true
    else tankHitters[g] = nil end
  end

  for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
    local u = plateUnit(plate)
    if u and UnitCanAttack("player", u) and not UnitIsDead(u) then
      local byTarget = tankGUID and UnitGUID(u .. "target") == tankGUID
      local byThreat = tankUnit and (UnitThreatSituation(u, tankUnit) or 0) >= 2
      if byTarget or byThreat then seen[UnitGUID(u) or u] = true end
    end
  end

  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  return count
end

-- Biggest recent melee hit on the tank -- our proxy for "how hard the next
-- swing could land". nil until we've seen a hit this fight.
local function dangerHitSize()
  local mx = 0
  for i = 1, #tankMeleeHits do
    if tankMeleeHits[i] > mx then mx = tankMeleeHits[i] end
  end
  return mx > 0 and mx or nil
end

--=========================================================================
-- Tank debuff watch  --  is the tank taking extra damage / unable to mitigate?
--=========================================================================
-- Two categories:
--   "amp" - armor shred / damage-taken up / healing-reduction
--   "loc" - loss of control: a stunned/feared/incapacitated paladin can't
--           block, dodge or parry, so every hit lands in full.
-- name(lower) -> { short label, severity }.  Highest severity wins the line.
local AMP_BY_NAME = {
  ["enfeeble"]              = { "ENFEEBLE - heals capped!", 100 }, -- Prince Malchezaar
  ["mortal strike"]        = { "Mortal Strike (-50% heals)", 90 },
  ["mortal wound"]         = { "Mortal Wound (-healing)",    90 },
  ["aimed shot"]           = { "Aimed Shot (-50% heals)",    88 },
  ["wound poison"]         = { "Wound Poison (-healing)",    86 },
  ["meteor slash"]         = { "Meteor Slash",               82 }, -- Brutallus
  ["flame buffet"]         = { "Flame Buffet",               78 }, -- Al'ar
  ["mark of hydross"]      = { "Mark of Hydross",            78 },
  ["mark of corruption"]   = { "Mark of Corruption",         78 }, -- Hydross
  ["sonic boom"]           = { "Sonic Boom",                 62 },
  ["curse of recklessness"]= { "Curse of Recklessness",      45 },
  ["annihilator"]          = { "Annihilator (armor)",        42 },
  ["faerie fire"]          = { "Faerie Fire",                40 },
  ["expose armor"]         = { "Expose Armor",               38 },
  ["sunder armor"]         = { "Sunder Armor",               32 },
}
-- name(lower) -> control type (common PvE ones; the tooltip check catches the rest)
local LOC_BY_NAME = {
  ["hammer of justice"] = "Stunned", ["war stomp"]        = "Stunned",
  ["knockdown"]         = "Stunned", ["bash"]             = "Stunned",
  ["charge"]            = "Stunned", ["ground slam"]      = "Stunned",  -- Gruul
  ["cave in"]           = "Stunned", ["shatter"]          = "Stunned",  -- Gruul
  ["intimidating shout"]= "Feared",  ["psychic scream"]   = "Feared",
  ["fear"]              = "Feared",  ["terrifying screech"] = "Feared",
}
local LOC_SEV = { Stunned = 95, Incapacitated = 93, Feared = 88 }

local scanTip = CreateFrame("GameTooltip", "PallyHelperScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

local catCache = {}   -- spellId -> "amp" | "loc" | false
local LOC_WORDS = {
  "stunned", "incapacitat", "unable to act", "asleep", "cannot act",
  "frozen", "feared", "in fear", "fleeing", "horrified", "banished",
  "hypnoti", "unable to move, attack",
}

-- "amp" | "loc" | false, from the debuff's tooltip text
local function classifyByTooltip(unit, index)
  scanTip:SetOwner(UIParent, "ANCHOR_NONE")
  scanTip:ClearLines()
  scanTip:SetUnitDebuff(unit, index)
  for i = 2, scanTip:NumLines() do
    local fs = _G["PallyHelperScanTipTextLeft" .. i]
    local t  = fs and fs:GetText()
    if t then
      t = t:lower()
      for _, w in ipairs(LOC_WORDS) do
        if t:find(w, 1, true) then return "loc" end
      end
      if (t:find("damage taken", 1, true) and t:find("increas", 1, true))
         or (t:find("armor", 1, true) and (t:find("reduc", 1, true)
             or t:find("decreas", 1, true) or t:find("lower", 1, true))) then
        return "amp"
      end
    end
  end
  return false
end

-- Returns: label, stacks, category ("amp"|"loc")   or nil
local function scanTankDebuffs(unit)
  if not unit or not UnitExists(unit) then return nil end
  local bLabel, bSev, bStacks, bCat
  for i = 1, 40 do
    local name, _, count, _, _, _, _, _, _, spellId = UnitDebuff(unit, i)
    if not name then break end
    local key = name:lower()
    local label, sev, cat

    local kl, ka = LOC_BY_NAME[key], AMP_BY_NAME[key]
    if kl then
      label, sev, cat = name .. " (" .. kl .. ")", (LOC_SEV[kl] or 90), "loc"
    elseif ka then
      label, sev, cat = ka[1], ka[2], "amp"
    elseif spellId then
      local c = catCache[spellId]
      if c == nil then c = classifyByTooltip(unit, i); catCache[spellId] = c end
      if c == "loc" then label, sev, cat = name, 84, "loc"
      elseif c == "amp" then label, sev, cat = name, 20, "amp" end
    end

    if label and sev > (bSev or -1) then
      bLabel, bSev, bStacks, bCat = label, sev, (count and count > 0) and count or 1, cat
    end
  end
  return bLabel, bStacks, bCat
end

--=========================================================================
-- Display
--=========================================================================
local anchor = CreateFrame("Frame", "PallyHelperAnchor", UIParent)
anchor:SetSize(224, 68)
anchor:SetClampedToScreen(true)
anchor:EnableMouse(true)
anchor:SetMovable(true)
anchor:RegisterForDrag("LeftButton")

local anchorBG = anchor:CreateTexture(nil, "BACKGROUND")
anchorBG:SetAllPoints()
anchorBG:SetColorTexture(0, 0, 0, 0.25)

local bar = CreateFrame("StatusBar", nil, anchor)
bar:SetPoint("TOPLEFT", 2, -2)
bar:SetPoint("TOPRIGHT", -2, -2)
bar:SetHeight(24)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)

local barBG = bar:CreateTexture(nil, "BACKGROUND")
barBG:SetAllPoints()
barBG:SetColorTexture(0, 0, 0, 0.6)

local marker = bar:CreateTexture(nil, "OVERLAY")
marker:SetColorTexture(1, 1, 1, 0.9)
marker:SetWidth(2)
marker:SetPoint("TOP", bar, "TOPLEFT", 0, 0)
marker:SetPoint("BOTTOM", bar, "BOTTOMLEFT", 0, 0)

local flash = bar:CreateTexture(nil, "OVERLAY")
flash:SetAllPoints()
flash:SetColorTexture(1, 1, 1, 1)
flash:SetBlendMode("ADD")
flash:SetAlpha(0)

local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
barText:SetPoint("CENTER")

local addsText = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
addsText:SetPoint("TOP", bar, "BOTTOM", 0, -3)

local tankDebuffText = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tankDebuffText:SetPoint("TOP", addsText, "BOTTOM", 0, -2)
tankDebuffText:SetTextColor(1, 0.55, 0.1)
tankDebuffText:Hide()

local alertFS = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
alertFS:SetPoint("BOTTOM", bar, "TOP", 0, 8)
do
  local f, _, fl = alertFS:GetFont()
  alertFS:SetFont(f, 24, fl and fl ~= "" and fl or "OUTLINE")
end
alertFS:SetTextColor(1, 0.1, 0.1)
alertFS:Hide()

anchor:SetScript("OnDragStart", function(self)
  if not DB.locked then self:StartMoving() end
end)
anchor:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  DB.point = { p, rp, x, y }
end)

local function applyPoint()
  anchor:ClearAllPoints()
  anchor:SetPoint(DB.point[1], UIParent, DB.point[2], DB.point[3], DB.point[4])
end

local function applyLockVisual()
  anchorBG:SetShown(not DB.locked)
end

local lastSoundSwing
local wasCastNow = false
local wasDanger = false
local flashAlpha = 0
local addsAcc = 0
local cachedAdds, cachedTankName
local cachedDebuff, cachedDebuffStacks, cachedDebuffCat

local bigHitUntil, bigHitMsg = 0, ""

-- assigns the forward-declared local
function triggerBigHit(amount, crushing, critical)
  local tag = crushing and "CRUSHING" or (critical and "CRIT" or "BIG HIT")
  local n = (amount and BreakUpLargeNumbers and BreakUpLargeNumbers(amount)) or amount or ""
  bigHitMsg   = ("!! HEAL NOW  -  %s %s !!"):format(tag, tostring(n))
  bigHitUntil = GetTime() + (DB.bigHitDuration or 1.6)
  if DB.bigHitSound then
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
  end
end

local function updateDisplay(elapsed)
  if not DB then return end   -- settings not loaded yet

  -- --- tank + adds counter (cheaper cadence) ---------------------------
  addsAcc = addsAcc + (elapsed or 0)
  if addsAcc >= 0.15 then
    addsAcc = 0
    local unit, guid, name = resolveTankUnit()
    currentTankGUID  = guid
    cachedTankName   = name
    if unit then
      currentTankMaxHP = UnitHealthMax(unit)   -- keep last known if out of range
      currentTankHP    = UnitHealth(unit)
    else
      currentTankHP    = nil
    end
    cachedAdds = countAddsOnTank(guid, unit)
    if DB.tankDebuffWatch then
      cachedDebuff, cachedDebuffStacks, cachedDebuffCat = scanTankDebuffs(unit)
    else
      cachedDebuff = nil
    end
  end

  -- --- big-hit alert -------------------------------------------------------
  if GetTime() < bigHitUntil then
    alertFS:SetText(bigHitMsg)
    alertFS:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 14)))
    alertFS:Show()
  elseif alertFS:IsShown() then
    alertFS:Hide()
  end
  if cachedAdds == nil then
    addsText:SetText("|cff888888adds on tank: n/a|r")
  else
    local c = cachedAdds
    local col = (c == 0 and "ff888888") or (c <= 2 and "ff40ff40")
             or (c <= 4 and "ffffff40") or "ffff4040"
    addsText:SetFormattedText("|c%sadds on tank: %d|r", col, c)
  end

  if cachedDebuff then
    if cachedDebuffCat == "loc" then
      tankDebuffText:SetTextColor(1, 0.25, 0.25)
      tankDebuffText:SetFormattedText("\226\154\160 CAN'T MITIGATE - %s", cachedDebuff)
    else
      tankDebuffText:SetTextColor(1, 0.55, 0.1)
      if cachedDebuffStacks and cachedDebuffStacks > 1 then
        tankDebuffText:SetFormattedText("\226\154\160 %s x%d", cachedDebuff, cachedDebuffStacks)
      else
        tankDebuffText:SetFormattedText("\226\154\160 %s", cachedDebuff)
      end
    end
    tankDebuffText:Show()
  elseif tankDebuffText:IsShown() then
    tankDebuffText:Hide()
  end

  -- --- swing timer ------------------------------------------------------
  local guid = activeEnemyGUID()
  local s = guid and swings[guid]
  if not s then
    bar:SetValue(0)
    bar:SetStatusBarColor(0.3, 0.3, 0.3)
    barText:SetText("no swing data")
    marker:Hide()
    wasCastNow, wasDanger = false, false
    return
  end

  -- Boss is casting: show the cast, hold the swing prediction, don't advise a
  -- heal into a swing that the cast is delaying anyway.
  local castName, castFrac, castLeft = enemyCastState(guid)
  if castName then
    s.castDirty = true
    bar:SetValue(castFrac)
    bar:SetStatusBarColor(0.6, 0.3, 0.9)
    barText:SetFormattedText("CASTING: %s  %.1fs", castName, castLeft)
    marker:Hide()
    wasCastNow, wasDanger = false, false
    if flashAlpha > 0 then
      flashAlpha = math.max(0, flashAlpha - (elapsed or 0) * 2.2)
      flash:SetAlpha(flashAlpha)
    end
    return
  end

  local now      = GetTime()
  local estimate = (not DB.fixedPeriod) and (s.period == nil)
  local period   = DB.fixedPeriod or s.period or 2.0
  if period < 0.3 then period = 2.0 end   -- guard against a bad sample
  local nextSw   = s.last + period
  local remain   = nextSw - now

  -- roll forward if we missed a swing (target out of melee, phase change, etc.)
  if remain < -0.35 then
    remain = remain + math.ceil((-0.35 - remain) / period) * period
  end

  local lead      = healLeadSeconds()
  local threshold = lead - DB.landOffset          -- start casting at this "remain"
  local castNow   = (remain <= threshold) and (remain > -0.35)

  local frac = 1 - (remain / period)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  bar:SetValue(frac)

  -- brief bolt when a parry just hastened this swing
  local parryTag = (s.parryAt and (now - s.parryAt) < 0.6) and "|cffffcc00\226\154\161|r " or ""

  -- danger swing: could the next hit kill the tank at its current health?
  local hitSize = dangerHitSize()
  local danger  = DB.dangerWarn and currentTankHP and currentTankHP > 0 and hitSize
                  and currentTankHP <= hitSize * (DB.dangerFactor or 1.15)

  if danger then
    bar:SetStatusBarColor(0.9, 0.05, 0.05)
    barText:SetFormattedText("%s!! LETHAL !!  %.1f", parryTag, remain)
    if not wasDanger then flashAlpha = 0.6 end
  elseif castNow then
    bar:SetStatusBarColor(0.1, 1, 0.1)
    barText:SetFormattedText("%sCAST NOW  (%.1f)", parryTag, remain)
    if not wasCastNow then
      flashAlpha = 0.55                        -- silent visual pop on the rising edge
      if DB.sound and lastSoundSwing ~= s.last then
        lastSoundSwing = s.last
        PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960, "Master")
      end
    end
  else
    bar:SetStatusBarColor(0.2, 0.4, 1)
    barText:SetFormattedText("%s%s%.1fs -> next hit", parryTag, estimate and "~" or "", remain)
  end
  wasCastNow = castNow
  wasDanger  = danger and true or false

  if flashAlpha > 0 then
    flashAlpha = math.max(0, flashAlpha - (elapsed or 0) * 2.2)   -- ~0.25s fade
    flash:SetAlpha(flashAlpha)
  end

  -- marker line at the "start casting" point
  local mfrac = 1 - (threshold / period)
  if mfrac < 0 then mfrac = 0 elseif mfrac > 1 then mfrac = 1 end
  marker:Show()
  marker:SetPoint("TOP",    bar, "TOPLEFT",    mfrac * bar:GetWidth(), 0)
  marker:SetPoint("BOTTOM", bar, "BOTTOMLEFT", mfrac * bar:GetWidth(), 0)
end

anchor:SetScript("OnUpdate", function(_, e) updateDisplay(e) end)

--=========================================================================
-- Slash commands
--=========================================================================
local function pos(msg) print("|cff33ff99PallyHelper|r: " .. msg) end

SLASH_PALLYHELPER1 = "/ph"
SlashCmdList.PALLYHELPER = function(msg)
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "" then
    DB.shown = not DB.shown
    anchor:SetShown(DB.shown)
    pos(DB.shown and "shown" or "hidden")

  elseif cmd == "lock" then
    DB.locked = not DB.locked
    applyLockVisual()
    pos(DB.locked and "locked" or "unlocked (drag to move)")

  elseif cmd == "settank" then
    if UnitExists("target") then
      DB.tankGUID = UnitGUID("target")
      DB.tankName = UnitName("target")
      pos("tank set to " .. DB.tankName)
    else
      pos("no target - target the tank first")
    end

  elseif cmd == "cleartank" then
    DB.tankGUID, DB.tankName = nil, nil
    pos("tank cleared (will auto-detect from group roles)")

  elseif cmd == "spell" then
    rest = rest:lower()
    if rest == "flash" or rest == "holy" then
      DB.spell = rest
      pos("advisor spell = " .. rest)
    else
      pos("usage: /ph spell flash | holy")
    end

  elseif cmd == "casttime" then
    if rest == "auto" or rest == "" then
      DB.castTimeMsOverride = nil
      pos("cast time = auto")
    else
      local n = tonumber(rest)
      if n then DB.castTimeMsOverride = n; pos("cast time override = " .. n .. " ms")
      else pos("usage: /ph casttime <ms> | auto") end
    end

  elseif cmd == "offset" then
    local n = tonumber(rest)
    if n then DB.landOffset = n; pos(("land offset = %.2fs after swing"):format(n))
    else pos("usage: /ph offset <seconds>  (e.g. 0.15)") end

  elseif cmd == "sound" then
    DB.sound = not DB.sound
    pos("cast-now sound " .. (DB.sound and "on" or "off"))

  elseif cmd == "fixedperiod" then
    if rest == "auto" or rest == "" then
      DB.fixedPeriod = nil
      pos("swing period = auto (measured)")
    else
      local n = tonumber(rest)
      if n and n > 0.3 then DB.fixedPeriod = n; pos(("swing period locked to %.2fs"):format(n))
      else pos("usage: /ph fixedperiod <seconds> | auto  (e.g. 2.0)") end
    end

  elseif cmd == "bighit" then
    DB.bigHitAlert = not DB.bigHitAlert
    pos("big-hit alert " .. (DB.bigHitAlert and "on" or "off"))

  elseif cmd == "bigsound" then
    DB.bigHitSound = not DB.bigHitSound
    pos("big-hit sound " .. (DB.bigHitSound and "on" or "off"))

  elseif cmd == "debuffs" then
    DB.tankDebuffWatch = not DB.tankDebuffWatch
    pos("tank debuff watch " .. (DB.tankDebuffWatch and "on" or "off"))

  elseif cmd == "danger" then
    DB.dangerWarn = not DB.dangerWarn
    pos("danger-swing warning " .. (DB.dangerWarn and "on" or "off"))

  elseif cmd == "dangerfactor" then
    local n = tonumber(rest)
    if n and n > 0 then DB.dangerFactor = n
      pos(("danger factor = %.2f  (LETHAL when tank HP <= biggest recent hit * %.2f)"):format(n, n))
    else pos("usage: /ph dangerfactor <number>  (e.g. 1.15)") end

  elseif cmd == "bigpct" then
    local n = tonumber(rest)
    if n and n > 0 then
      DB.bigHitPct = (n > 1) and (n / 100) or n
      pos(("big-hit threshold = %d%% of tank health"):format(math.floor(DB.bigHitPct * 100 + 0.5)))
    else
      pos("usage: /ph bigpct <percent>  (e.g. 22)")
    end

  elseif cmd == "diag" then
    local unit, guid, name = resolveTankUnit()
    pos(("tank: %s  guid=%s  unit=%s"):format(tostring(name), tostring(guid), tostring(unit)))
    pos(("in group=%s  in raid=%s  enemy nameplates CVar=%s")
        :format(tostring(IsInGroup()), tostring(IsInRaid()), tostring(GetCVar("nameplateShowEnemies"))))
    local plates = C_NamePlate.GetNamePlates()
    pos("visible nameplates: " .. #plates)
    local enemies, onTank = 0, 0
    for i, p in ipairs(plates) do
      local u = plateUnit(p)
      if not u then
        pos(("  #%d NO TOKEN (npUT=%s unit=%s UF.unit=%s)"):format(i,
            tostring(p.namePlateUnitToken), tostring(p.unit),
            tostring(p.UnitFrame and p.UnitFrame.unit)))
      else
        local canAtk = UnitCanAttack("player", u)
        local thr    = unit and UnitThreatSituation(u, unit)
        local tt     = UnitExists(u .. "target") and (UnitName(u .. "target") or "?") or "NONE"
        local hit    = canAtk and not UnitIsDead(u)
                       and ((guid and UnitGUID(u .. "target") == guid) or (thr and thr >= 2))
        if canAtk then enemies = enemies + 1 end
        if hit then onTank = onTank + 1 end
        pos(("  #%d %s=%s atk=%s react=%s combat=%s tgt=%s thr=%s hit=%s"):format(i,
            u, tostring(UnitName(u)), tostring(canAtk),
            tostring(UnitReaction("player", u)), tostring(UnitAffectingCombat(u)),
            tt, tostring(thr), tostring(hit and true or false)))
      end
    end
    local hitters, now = 0, GetTime()
    for _, t in pairs(tankHitters) do
      if now - t <= HITTER_WINDOW then hitters = hitters + 1 end
    end
    pos(("=> nameplate onTank=%d | combatlog hitters(<%ds)=%d | shown=%s")
        :format(onTank, HITTER_WINDOW, hitters, tostring(countAddsOnTank(guid, unit))))
    local dl, ds, dc = scanTankDebuffs(unit)
    pos(("tank debuff: [%s] %s%s"):format(tostring(dc), tostring(dl), (ds and ds > 1) and (" x" .. ds) or ""))
    pos(("tank HP=%s/%s | biggest recent melee hit=%s | lethal if HP<=%s")
        :format(tostring(currentTankHP), tostring(currentTankMaxHP), tostring(dangerHitSize()),
                dangerHitSize() and math.floor(dangerHitSize() * (DB.dangerFactor or 1.15)) or "n/a"))

  elseif cmd == "reset" then
    wipe(DB)                                   -- also clears nil-by-default keys
    for k, v in pairs(DEFAULTS) do DB[k] = v end
    DB.point = { DEFAULTS.point[1], DEFAULTS.point[2], DEFAULTS.point[3], DEFAULTS.point[4] }
    applyPoint()
    anchor:SetShown(DB.shown)
    applyLockVisual()
    pos("settings + position reset")

  else
    pos("commands: (none)=toggle  lock  settank  cleartank  spell flash|holy  casttime <ms>|auto  offset <s>  sound")
    pos("           fixedperiod <s>|auto  bighit  bigsound  bigpct <percent>  debuffs  danger  dangerfactor <n>  diag  reset")
  end
end

--=========================================================================
-- Boot
--=========================================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    PallyHelperDB = PallyHelperDB or {}
    DB = PallyHelperDB
    for k, v in pairs(DEFAULTS) do
      if DB[k] == nil then DB[k] = v end
    end

  elseif event == "PLAYER_LOGIN" then
    applyPoint()
    anchor:SetShown(DB.shown)
    applyLockVisual()

    local cl = CreateFrame("Frame")
    cl:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    cl:RegisterEvent("PLAYER_REGEN_ENABLED")   -- combat ended
    cl:SetScript("OnEvent", function(_, e)
      if e == "PLAYER_REGEN_ENABLED" then
        wipe(tankHitters); wipe(tankMeleeHits)
      else
        onCombatLog()
      end
    end)

    -- keep target weapon-speed fresh if it changes (slows/haste on the boss)
    local sp = CreateFrame("Frame")
    sp:RegisterUnitEvent("UNIT_ATTACK_SPEED", "target")
    sp:SetScript("OnEvent", function()
      local guid = UnitGUID("target")
      local s = guid and swings[guid]
      if s then
        local v = UnitAttackSpeed("target")
        if v and v > 0 then s.period = v end
      end
    end)

    pos("loaded. /ph for options.")
  end
end)
