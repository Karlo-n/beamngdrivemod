local M = {}

local sqrt = math.sqrt
local format = string.format

local base = require('trafficAI/behaviors/baseBehavior')
local driver = require('trafficAI/core/driver')
local idm = require('trafficAI/models/idm')

local PROJECT = 0.9 -- seconds of acceleration folded into the speed we hand to ai.lua
local SEND_EPS = 0.4 -- m/s
local MIN_GAP = 0.5
local URGENCY_MAX = 2.5
local GRIP_DECEL = 6.5 -- m/s2; above this ABS starts cycling and it is audible
-- Drivers rate -1.0 to -1.5 m/s2 as comfortable braking; what actually reads as harsh is
-- the jerk at the start of it, so both the level and its rate of onset are limited. Both are
-- per driver (comfortDecel, brakeJerk).
local JERK_EMERGENCY = 9
local EMERGENCY_TTC = 2.5

-- ai.lua drives with its own PID, so IDM output is expressed as a speed cap ('limit' mode
-- takes min(routeSpeed, physically possible)) rather than a throttle value we cannot set.
local function push(id, cf, speed)
  if cf.sentSpeed >= 0 and speed > cf.sentSpeed - SEND_EPS and speed < cf.sentSpeed + SEND_EPS then return end
  cf.sentSpeed = speed
  base.send(id, format('ai.setSpeedMode("limit") ai.setSpeed(%.2f)', speed))
end

function M.update(d, ctx, pcp, dt)
  local cf, dd = d.cf, d.d
  cf.released = false
  local v = ctx.speed
  local v0 = driver.desiredSpeed(d, ctx.limit) * d.ot.speedBoost * d.pu.speedBoost
  if v0 < 2 then v0 = 2 end

  local a, b = dd.maxAccel, dd.maxDecel
  local s0 = dd.gapMin
  local T = driver.headway(d)

  -- While squeezing past a wreck, that wreck must stop counting as a leader, or the model
  -- would brake to a stop against the very obstacle it has already decided it can clear.
  local sq = d.sq
  local leadId, leadGap, leadSpeed = pcp.leadId, pcp.leadGap, pcp.leadSpeed
  -- Not just the one obstacle: a queue of stopped cars would otherwise stop us dead the
  -- moment the first one is cleared, which is why the manoeuvre stalled halfway through.
  if sq.active and (leadId == sq.ignoreId or leadSpeed < 0.6) then
    leadId, leadGap, leadSpeed = 0, -1, 0
  end
  -- Same idea while overtaking: the car we are alongside must not brake us to a stop.
  if d.ot.ignoreId ~= 0 and leadId == d.ot.ignoreId then
    leadId, leadGap, leadSpeed = 0, -1, 0
  end
  -- And a driver deliberately running someone down is not going to brake for them.
  if d.pu.mode == 1 and d.pu.phase == 1 and leadId == d.pu.targetId then
    leadId, leadGap, leadSpeed = 0, -1, 0
  end
  -- A car that has only just become the leader is seen as it is; the lag is for changes in
  -- a speed already being watched. Carrying the old value over read as phantom braking.
  if leadId ~= cf.leaderId then cf.laggedSpeed = leadSpeed end
  cf.leaderId, cf.gap, cf.leaderSpeed = leadId, leadGap, leadSpeed

  -- Eyes on the road? Everything that depends on noticing something early hangs off this.
  local alert = d.state ~= 'distracted' and d.state ~= 'drowsy' and d.state ~= 'drunk'

  local accel
  if leadId == 0 then
    cf.desiredGap = idm.desiredGap(v, s0, T)
    accel = idm.accel(v, v0, nil, 0, a, b, s0, T)
  else
    -- Reaction time as a first-order lag on the leader's perceived speed: a slow driver
    -- keeps acting on a stale speed for a moment after the leader brakes.
    local react = driver.reaction(d)
    -- Brake lights are noticed far sooner than a gap slowly closing. Anyone actually
    -- watching the road reacts to them in under half the usual time.
    if alert and pcp.leadDecel > 2 then react = react * 0.45 end
    local alpha = dt / (react + dt)
    cf.laggedSpeed = cf.laggedSpeed + (leadSpeed - cf.laggedSpeed) * alpha

    accel = idm.accel(v, v0, leadGap, cf.laggedSpeed, a, b, s0, T)

    -- Looking past the car in front. If the one beyond it is slowing or stopped, a driver who
    -- reads the road starts easing off before their own leader has even touched the brakes.
    -- The second car is two headways and a car length away at equilibrium.
    if alert and pcp.lead2Gap > 0 and dd.anticipation > 0.25 then
      local a2 = idm.accel(v, v0, pcp.lead2Gap, pcp.lead2Speed, a, b, s0 * 2 + 5, T * 2)
      if a2 < accel then accel = accel + (a2 - accel) * dd.anticipation end
    end
    cf.desiredGap = idm.desiredGap(v, s0, T)
      + v * (v - cf.laggedSpeed) / (2 * sqrt(a * b))
    if cf.desiredGap < s0 then cf.desiredGap = s0 end
  end

  local floorAccel = -b * 1.6
  if accel < floorAccel then accel = floorAccel end
  if accel > a then accel = a end
  cf.accel = accel

  local target = v + accel * PROJECT
  if target > v0 then target = v0 end

  -- Inverting the equilibrium gap (s = s0 + v*T) gives the speed that actually holds the
  -- gap. Without it, projecting acceleration alone approaches a stopped leader far too softly.
  if leadId ~= 0 then
    local vSafe = cf.laggedSpeed + (leadGap - s0) / T
    if target > vSafe then target = vSafe end

    -- The braking envelope: the speed from which this driver's own everyday braking still
    -- ends at the right distance. It is what makes a gentle driver start slowing a hundred
    -- metres from a queue and a brisk one leave it to the last forty, instead of everyone
    -- braking softly at first and then standing on the pedal.
    local vl = cf.laggedSpeed
    if vl < v then
      local room = leadGap - s0 - 1 - vl * T * 0.5
      if room < 0 then room = 0 end
      local vEnv = sqrt(vl * vl + 2 * dd.comfortDecel * 0.9 * room)
      if target > vEnv then target = vEnv end
    end
  end

  -- A red light or a stop sign seen from a distance. The engine does the stopping; this
  -- shapes the approach. Good anticipation lifts off early and rolls up to it, poor
  -- anticipation keeps the speed and brakes late. It never goes below a walking pace, so a
  -- stale signal reading cannot hold a car still.
  if alert and pcp.signalDist >= 0 and pcp.signalDist < dd.sightRange
    and (pcp.signalAction == 2 or pcp.signalAction == 3) then
    local coast = dd.comfortDecel * (0.5 + (1 - dd.anticipation) * 0.6)
    if coast < 0.8 then coast = 0.8 end
    local cap = sqrt(2 * coast * (pcp.signalDist > 3 and pcp.signalDist - 3 or 0))
    if cap < 2.5 then cap = 2.5 end
    if target > cap then target = cap end
  end

  if target < 0 then target = 0 end

  -- Hard floor independent of reaction lag, so late perception causes contact, not pileups.
  if leadGap >= 0 and leadGap < s0 * 0.6 then target = 0 end

  -- ai.lua reads a sudden drop in commanded speed as "brake as hard as you can", which
  -- locks the wheels and screeches. Ramping the command instead makes it press the pedal.
  local urgency, emergency = 1, false
  -- What stopping in the room available actually takes.
  local need = 0
  if leadGap >= 0 and leadSpeed < v then
    local room = leadGap - s0
    if room < 1 then room = 1 end
    need = (v * v - leadSpeed * leadSpeed) / (2 * room)
    local ttc = leadGap / (v - leadSpeed)
    if ttc < 3 then urgency = 1 + (3 - ttc) end
    if urgency > URGENCY_MAX then urgency = URGENCY_MAX end
    -- Time to collision is short at the end of every ordinary stop too, so on its own it
    -- says nothing; it is an emergency only when comfort braking cannot cover it.
    emergency = ttc < EMERGENCY_TTC and need > dd.comfortDecel * 1.5
  end
  -- Inside the standstill gap and still closing; the last metre of an ordinary stop is not one.
  if leadGap >= 0 and leadGap < s0 and v - leadSpeed > 1.5 then emergency = true end
  -- Moving off is not instant and not uniform. Each driver sits still for their own beat
  -- before going, which is what makes a queue at a green light ripple instead of jump.
  if v < 0.6 then
    if target > 1 then
      -- Looking at a phone, or half asleep: the light is green and they have not noticed.
      if d.state == 'distracted' or d.state == 'drowsy' then cf.launchWait = dt * 2 end
      if cf.launchWait > 0 then
        cf.launchWait = cf.launchWait - dt
        target = 0
      else
        cf.launchBoost = 1.6
      end
    end
  elseif v > 2.5 then
    cf.launchWait = dd.launchDelay
  end
  if cf.launchBoost > 0 then cf.launchBoost = cf.launchBoost - dt end

  -- Every behaviour's speed cap is applied BEFORE the rate limiter, not after. Applied
  -- afterwards they bypassed it completely and landed as a step change, which ai.lua reads
  -- as "brake as hard as you can" -- that was the unexplained hard braking in open road.
  -- Written out rather than looped over a table: this runs every tick for every vehicle.
  if sq.speedCap >= 0 and target > sq.speedCap then target = sq.speedCap end
  if d.wt.speedCap >= 0 and target > d.wt.speedCap then target = d.wt.speedCap end
  if d.itm.speedCap >= 0 and target > d.itm.speedCap then target = d.itm.speedCap end
  if d.dr.speedCap >= 0 and target > d.dr.speedCap then target = d.dr.speedCap end
  if d.ot.speedCap >= 0 and target > d.ot.speedCap then target = d.ot.speedCap end
  if d.pu.speedCap >= 0 and target > d.pu.speedCap then target = d.pu.speedCap end
  if d.hr.speedCap >= 0 and target > d.hr.speedCap then target = d.hr.speedCap end
  if d.ey.speedCap >= 0 and target > d.ey.speedCap then target = d.ey.speedCap end
  -- Evasion is the one cap that is allowed to be violent, so it also raises the ceiling.
  if d.ev.speedCap >= 0 and target > d.ev.speedCap then
    target = d.ev.speedCap
    if d.ev.level == 2 then emergency = true end
  end

  -- After a reset or a release the command has no history; anchoring it to the current
  -- speed keeps the very first command rate-limited too, instead of landing as a step.
  local prev = cf.cmdSpeed
  if prev < 0 then prev = v end
  do
    -- Everyday slowing stays inside the comfort band; only a genuine emergency is allowed
    -- to reach for the tyres. Either way the deceleration builds up rather than appearing.
    -- The comfort level and how abruptly braking starts are the driver's own style.
    local ceiling = emergency and GRIP_DECEL or dd.comfortDecel
    local jerkRate = emergency and JERK_EMERGENCY or dd.brakeJerk
    -- Seen late, or closing faster than comfort can deal with: brake as hard as it takes
    -- and no harder, rather than staying gentle until it becomes an emergency.
    if not emergency and need > ceiling then
      ceiling = need * 1.15
      if ceiling > GRIP_DECEL then ceiling = GRIP_DECEL end
      jerkRate = jerkRate * 2
    end
    local wantDecel = b * urgency
    if wantDecel > ceiling or need > dd.comfortDecel then wantDecel = ceiling end

    local jerk = jerkRate * dt
    if wantDecel > cf.lastDecel + jerk then wantDecel = cf.lastDecel + jerk end
    if target >= prev then wantDecel = 0 end
    cf.lastDecel = wantDecel

    local maxRise = a * dt
    if cf.launchBoost > 0 then maxRise = maxRise * dd.launchPunch end
    local maxDrop = wantDecel * dt
    if target < prev - maxDrop then target = prev - maxDrop end
    if target > prev + maxRise then target = prev + maxRise end
  end
  cf.cmdSpeed = target

  cf.targetSpeed = target
  push(ctx.id, cf, target)

  if leadId ~= 0 and leadGap < cf.desiredGap * 1.3 then
    return 'following'
  end
  return nil
end

-- Hands speed control back to ai.lua. Used while a crash action runs or when the driver
-- is stuck, where our model has nothing useful to say and would just pin the car at zero.
function M.release(d, id)
  local cf = d.cf
  if cf.released then return end
  cf.released = true
  cf.sentSpeed, cf.cmdSpeed = -1, -1
  base.send(id, 'ai.setSpeedMode("legal")')
end

function M.reset(d)
  local cf = d.cf
  cf.leaderId, cf.gap, cf.leaderSpeed = 0, -1, 0
  cf.desiredGap, cf.accel, cf.targetSpeed = 0, 0, 0
  cf.laggedSpeed, cf.sentSpeed, cf.cmdSpeed = 0, -1, -1
  cf.released = false
  cf.launchWait, cf.launchBoost, cf.lastDecel = d.d.launchDelay, 0, 0
end

return M
