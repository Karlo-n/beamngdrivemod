local M = {}

local random = math.random

local memory = require('trafficAI/core/memory')
local stateMachine = require('trafficAI/core/stateMachine')
local conditions = require('trafficAI/environment/conditions')

-- How a driver feels about the trip, as it changes. Three things move it: what other drivers
-- do to them (stress), how much time they are losing (pressure), and who did it (grudge).
-- The same event lands differently on different people: a hot-tempered driver who is cut up
-- closes the gap and speeds up, a calm one drops back and slows down. Everything here ends
-- in two numbers the rest of the model already uses, a speed multiplier and a gap multiplier.

local STRESS_DECAY = 1 / 50     -- about fifty seconds to shake off a fright completely
local PRESSURE_GAIN = 1 / 110   -- per second of being held up
local PRESSURE_EASE = 1 / 180   -- per second of flowing freely
local CUT_GAP = 0.55            -- fraction of the desired gap that counts as being cut up

local function clamp(v, lo, hi)
  return v < lo and lo or (v > hi and hi or v)
end

local function stopAhead(pcp)
  return pcp.signalDist >= 0 and pcp.signalDist < 60
    and (pcp.signalAction == 2 or pcp.signalAction == 3 or pcp.signalAction == 4)
end

function M.update(d, ctx, pcp, dt)
  local at, p = d.at, d.p
  local limit = ctx.limit or 0
  local waiting = stopAhead(pcp)

  -- Held up means stuck behind somebody slow, not sitting at a red light. Nobody loses
  -- their temper over an ordinary red; the old rule had the impatient at full frustration
  -- three seconds into every one.
  local held = limit > 0 and ctx.speed < limit * 0.6 and pcp.leadId ~= 0 and pcp.leadGap >= 0
    and pcp.leadGap < 45 and not waiting

  -- Time pressure: every delay costs something, twice as much to someone already late.
  if held or (waiting and ctx.speed < 1) then
    at.pressure = at.pressure + dt * PRESSURE_GAIN * (d.mood == 'hurried' and 2 or 1)
  else
    at.pressure = at.pressure - dt * PRESSURE_EASE
  end
  local ceiling = d.mood == 'relaxed' and 0.3 or 1
  at.pressure = clamp(at.pressure, d.mood == 'hurried' and 0.25 or 0, ceiling)

  if held then
    d.frustration = d.frustration + dt * (0.006 + (1 - p.patience) * 0.03) * (1 + at.pressure)
    if d.frustration > 1 then d.frustration = 1 end
  else
    d.frustration = d.frustration - dt * 0.04
    if d.frustration < 0 then d.frustration = 0 end
  end

  -- ---- things that happen to the driver
  local stress = at.stress - dt * STRESS_DECAY

  -- Somebody pulled in close in front. A new leader, much nearer than the gap this driver
  -- keeps, while moving: that is being cut up, and it is remembered against them.
  local lead = pcp.leadId
  if lead ~= 0 and lead ~= at.lastLead and at.lastLead ~= 0 and ctx.speed > 6
    and pcp.leadGap >= 0 and pcp.leadGap < d.cf.desiredGap * CUT_GAP
    and (at.lastLeadGap < 0 or pcp.leadGap < at.lastLeadGap - 3) then
    memory.add(d.mem, d.clock, lead, memory.CUT_OFF, 0.8 + (1 - p.tolerance) * 0.8)
    stress = stress + 0.12 + (1 - p.tolerance) * 0.16
  end
  at.lastLead, at.lastLeadGap = lead, pcp.leadGap

  -- The car ahead braking hard, close.
  if lead ~= 0 and pcp.leadDecel > 4 and pcp.leadGap < d.cf.desiredGap then
    stress = stress + dt * 0.5
  end
  -- Being sat on from behind wears on people steadily.
  if pcp.rearGap >= 0 and pcp.rearGap < 3 + ctx.speed * 0.3 and pcp.rearSpeed > ctx.speed - 1 then
    stress = stress + dt * (0.02 + (1 - p.tolerance) * 0.03)
  end
  -- A horn nearby, once per blast.
  if at.hornTimer > 0 then at.hornTimer = at.hornTimer - dt end
  if pcp.hornNearby and at.hornTimer <= 0 then
    at.hornTimer = 3
    stress = stress + 0.06 + (1 - p.confidence) * 0.06
  end
  -- A near miss, once per emergency manoeuvre.
  local emergency = d.ev.active and d.ev.level == 2
  if emergency and not at.nearMiss then stress = stress + 0.3 end
  at.nearMiss = emergency

  at.stress = clamp(stress, 0, 1)

  -- ---- what they do about it
  local hot = p.temper * 0.6 + p.aggression * 0.4
  local speedMult, gapMult
  if hot > 0.55 then
    -- Takes it out on the road: faster, closer.
    speedMult = 1 + at.stress * 0.06 + at.pressure * 0.06
    gapMult = 1 - at.stress * 0.2 - at.pressure * 0.12
  else
    -- Takes it as a warning: slower, further back. Being late still pushes a little.
    speedMult = 1 - at.stress * 0.08 + at.pressure * 0.04
    gapMult = 1 + at.stress * 0.3 - at.pressure * 0.05
  end
  if d.mood == 'relaxed' then
    speedMult = speedMult * 0.97
    gapMult = gapMult * 1.08
  end

  -- The driver in front has history with this one. The memory was always written and never
  -- read; this is where it finally counts for something.
  local grudge = lead ~= 0 and memory.grudge(d.mem, d.clock, lead) or 0
  at.grudge = grudge
  if grudge > 0.3 then
    if hot > 0.55 then
      gapMult = gapMult * (1 - clamp(grudge * 0.15, 0, 0.3))
      d.frustration = clamp(d.frustration + dt * 0.05, 0, 1)
    else
      gapMult = gapMult * (1 + clamp(grudge * 0.2, 0, 0.4))
    end
  end

  at.speedMult = clamp(speedMult, 0.85, 1.12)
  at.gapMult = clamp(gapMult, 0.6, 1.6)
  -- Shortens how long they will sit behind someone before trying to pass.
  at.urge = clamp(at.pressure * 0.3 + (hot > 0.55 and at.stress * 0.2 or 0), 0, 0.5)

  -- ---- mood follows
  if d.frustration >= 0.75 and p.temper >= 0.6 then
    stateMachine.escalate(d, 'frustrated')
  end
  if at.stress > 0.7 then
    stateMachine.escalate(d, hot > 0.6 and 'aggressive' or 'nervous')
  end
end

-- Lapses of attention and judgement. Each one is an existing driver state that nothing ever
-- switched on: a glance at a phone, nodding off at night, not knowing the way, drink.
function M.episodes(d, ctx, pcp, dt)
  local ep, dd = d.ep, d.d

  -- Drink is not an episode, it is the whole trip.
  if d.drunk then
    if d.state ~= 'drunk' and d.stateDef.pri <= 3 then stateMachine.set(d, 'drunk') end
    return
  end

  -- Not knowing the area shows at junctions: slow down, hesitate, work out where to go.
  if ep.lostCooldown > 0 then
    ep.lostCooldown = ep.lostCooldown - dt
  elseif dd.familiarity < 0.3 and pcp.signalDist >= 0 and pcp.signalDist < 70 and ctx.speed > 4 then
    ep.lostCooldown = 50 + random() * 60
    if random() < 0.25 + (0.3 - dd.familiarity) * 1.5 then
      stateMachine.escalate(d, 'lost', 5 + random() * 7)
    end
  end

  ep.timer = ep.timer - dt
  if ep.timer > 0 then return end
  ep.timer = 22 + random() * 50
  if ctx.speed < 1 and d.state ~= 'normal' then return end

  -- Nodding off: at night, on a driver who set out tired.
  if conditions.night and (d.mood == 'tired' or d.state == 'tired') and random() < 0.3 then
    stateMachine.escalate(d, 'drowsy', 4 + random() * 6)
    return
  end
  -- Eyes off the road. Short, and far more often for some drivers than others.
  if random() < dd.distractible * 0.55 then
    stateMachine.escalate(d, 'distracted', 3 + random() * 4.5)
  end
end

function M.reset(d)
  local at = d.at
  at.stress, at.grudge, at.speedMult, at.gapMult, at.urge = 0, 0, 1, 1, 0
  at.pressure = d.mood == 'hurried' and 0.4 or 0
  at.lastLead, at.lastLeadGap, at.hornTimer, at.nearMiss = 0, -1, 0, false
  d.ep.timer, d.ep.lostCooldown = 8 + random() * 30, 0
end

return M
