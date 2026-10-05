local M = {}

local max = math.max
local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')
local perception = require('trafficAI/environment/perception')
local driver = require('trafficAI/core/driver')
local mobil = require('trafficAI/models/mobil')
local conditions = require('trafficAI/environment/conditions')

M.IDLE, M.PULLOUT, M.PASS, M.RETURN, M.ABORT = 0, 1, 2, 3, 4

-- Perception looks 230 m ahead for oncoming traffic; a pass needing more clear road than
-- this cannot honestly be verified, so it is simply not attempted.
local MAX_VERIFIABLE = 200
local PASS_TIMEOUT = 19
local BOOST = 1.18
local BOOST_CAUTIOUS = 1.05 -- taken on geometry alone, so taken gently

-- Backing out drops in behind the car we were passing, a little slower than them. Braking to
-- a fraction of our own speed was a stamp on the pedal in the middle of the road.
local function abort(d, ctx, reason)
  local ot = d.ot
  local _, _, theirSpeed = perception.relativeTo(ctx, ot.targetId)
  ot.phase, ot.timer, ot.reason = M.ABORT, 3.5, reason
  ot.ignoreId, ot.speedBoost = 0, 1
  ot.abortCap = theirSpeed and theirSpeed * 0.85 or ctx.speed * 0.8
end

-- Clear road still needed to finish from where we are now. Comparing the live oncoming gap
-- against the figure needed at the start aborted half the passes that were going fine: the
-- gap shrinks as the pass progresses, and so does what is left to do.
local function remainingNeed(ctx, fwd, theirSpeed, oncomingSpeed)
  local togo = fwd + (ctx.veh.length or 4.6) + 3
  if togo < 0 then return 0 end
  local closing = max(1.5, ctx.speed - (theirSpeed or 0))
  local t = togo / closing
  return (ctx.speed + oncomingSpeed) * t + 15
end

-- Distance of clear oncoming lane this pass actually needs: our travel while alongside,
-- plus whatever an oncoming car covers in the same time, plus a margin to tuck back in.
local function clearanceNeeded(d, ctx, pcp)
  local v0 = driver.desiredSpeed(d, ctx.limit) * BOOST
  local closing = max(1.5, v0 - pcp.leadSpeed)
  -- Both cars' real lengths: getting past a bus takes a lot more road than past a hatchback.
  local tPass = (pcp.leadGap + (ctx.veh.length or 4.6) + (pcp.leadLen or 4.6) + 5) / closing
  local oncomingSpeed = pcp.oncomingGap >= 0 and pcp.oncomingSpeed or ctx.limit
  return v0 * tPass + oncomingSpeed * tPass + 10 + d.p.prudence * 14, tPass
end

function M.update(d, ctx, pcp, dt)
  local ot, dd = d.ot, d.d
  ot.speedCap, ot.ignoreId, ot.speedBoost = -1, 0, 1

  if ot.cooldown > 0 then
    ot.cooldown = ot.cooldown - dt
    if ot.cooldown < 0 then ot.cooldown = 0 end
  end

  if ot.phase == M.ABORT then
    ot.timer = ot.timer - dt
    ot.speedCap = ot.abortCap
    base.lateralHold(ctx, ot.homeOffset, ctx.laneWidth + 1)
    if ot.timer <= 0 then
      ot.phase, ot.cooldown, ot.cautious = M.IDLE, 8 + random() * 10, false
      base.signal(ctx, 0)
    end
    return 'overtaking'
  end

  if ot.phase == M.PULLOUT or ot.phase == M.PASS then
    ot.timer = ot.timer - dt
    local fwd, _, theirSpeed = perception.relativeTo(ctx, ot.targetId)
    if ot.timer <= 0 or not fwd then
      abort(d, ctx, 'timeout')
      return 'overtaking'
    end

    -- Someone appeared in the lane we borrowed. Already more than half past: finish and tuck
    -- in, which is what anyone does. Otherwise drop back behind them.
    if ot.usingOncoming and pcp.oncomingGap >= 0
      and pcp.oncomingGap < remainingNeed(ctx, fwd, theirSpeed, pcp.oncomingSpeed) then
      if fwd < 0 then
        ot.phase, ot.timer, ot.signalled = M.RETURN, 3, false
      else
        abort(d, ctx, 'oncoming')
      end
      return 'overtaking'
    end

    base.lateralHold(ctx, ot.targetOffset, ctx.laneWidth + 1)

    -- Until the car is actually out of the lane, the one in front is still in front. Ignoring
    -- it from the first tick drove the car at its bumper, and the stock AI then braked: that
    -- was the lunge, brake, lunge cycle behind slow cars.
    local span = ot.targetOffset - ot.homeOffset
    local progress = span ~= 0 and (ctx.roadOffset - ot.homeOffset) / span or 1
    if progress > 0.55 then
      ot.phase = M.PASS
    elseif ot.phase == M.PULLOUT and ot.timer < PASS_TIMEOUT - d.d.laneChangeTime * 2.5 then
      abort(d, ctx, 'no sale')
      return 'overtaking'
    end
    if ot.phase == M.PASS then
      ot.ignoreId, ot.speedBoost = ot.targetId, ot.cautious and BOOST_CAUTIOUS or BOOST
    end

    -- Clear of them by more than a car length: time to tuck back in.
    if fwd < -(ctx.veh.length or 4.6) - 3 then
      ot.phase, ot.timer, ot.signalled = M.RETURN, 4, false
    end
    return 'overtaking'
  end

  if ot.phase == M.RETURN then
    ot.timer = ot.timer - dt
    if d.d.indicates and not ot.signalled then
      ot.signalled = true
      base.signal(ctx, ot.homeOffset > ot.targetOffset and 1 or -1)
    end
    ot.ignoreId, ot.speedBoost = ot.targetId, BOOST
    local err = base.lateralHold(ctx, ot.homeOffset, ctx.laneWidth + 1)
    if ot.timer <= 0 or (err and err < 0.25 and err > -0.25) then
      ot.phase, ot.cooldown = M.IDLE, 5 + random() * 8
      ot.ignoreId, ot.speedBoost, ot.cautious = 0, 1, false
      base.signal(ctx, 0)
    end
    return 'overtaking'
  end

  -- Idle from here on: decide whether to start one.
  if not dd.overtaker then ot.reject = 'nunca adelanta' ot.urge = 0 return nil end
  if d.state == 'asleep' then return nil end
  if ot.cooldown > 0 then ot.reject = 'en espera' return nil end
  if not ctx.valid then ot.reject = 'sin datos de via' ot.urge = 0 return nil end

  local v0 = driver.desiredSpeed(d, ctx.limit)
  -- Being held up is a matter of distance and speed, not of a multiple of a gap that itself
  -- shrinks when following slowly. That coupling was quietly suppressing most attempts.
  local held = pcp.leadId ~= 0 and pcp.leadGap >= 0 and pcp.leadGap < 70
    and pcp.leadSpeed < v0 * 0.93 and ctx.speed > 1.2

  if not held then
    ot.reject = pcp.leadId == 0 and 'via libre' or 'el de delante no estorba'
    ot.urge = max(0, ot.urge - dt * 2)
    return nil
  end

  ot.urge = ot.urge + dt
  if ot.urge < dd.overtakeWait * (1 - d.at.urge) then
    ot.reject = 'aun aguanta'
    return nil
  end

  local side, need = M.chooseSide(d, ctx, pcp)
  if not side then return nil end

  ot.phase, ot.timer = M.PULLOUT, PASS_TIMEOUT
  ot.targetId, ot.needClear, ot.urge = pcp.leadId, need, 0
  ot.reject = ''
  ot.usingOncoming = (ctx.ourLanes == 1)
  ot.homeOffset = ctx.laneCenter
  ot.targetOffset = ctx.laneCenter + side * ctx.laneWidth
  ot.signalled = false
  if dd.indicates then base.signal(ctx, side) end
  base.lateralHold(ctx, ot.targetOffset, ctx.laneWidth + 1)
  return 'overtaking'
end

-- Which side to go round, in roadOffset units. On a multi-lane road the inner lane is the
-- proper one; taking the outer lane instead is undertaking, and only the pushy do it. On a
-- single-lane road the only option is the oncoming side, and that needs real clearance.
-- Everything MOBIL needs, filled from perception. Reused, never rebuilt.
local scene = {}

local function fillScene(d, ctx, pcp)
  local dd = d.d
  scene.v, scene.v0 = ctx.speed, driver.desiredSpeed(d, ctx.limit)
  scene.a, scene.b = dd.maxAccel, dd.maxDecel
  scene.s0, scene.T = dd.gapMin, driver.headway(d)
  scene.gap, scene.vLead = pcp.leadGap, pcp.leadSpeed
  scene.tgtFrontGap, scene.tgtFrontSpeed = pcp.tgtFrontGap, pcp.tgtFrontSpeed
  scene.tgtRearGap, scene.tgtRearSpeed = pcp.tgtRearGap, pcp.tgtRearSpeed
  scene.rearGap, scene.rearSpeed = pcp.rearGap, pcp.rearSpeed
  return scene
end

-- Politeness is the tolerance trait, and the acceptance threshold falls as eagerness rises.
local function mobilSays(d, ctx, pcp)
  local dd = d.d
  local politeness = d.p.tolerance
  local threshold = 0.35 - dd.overtakeEagerness * 0.28
  local bSafe = 2.0 + d.p.prudence * 2.0
  return mobil.evaluate(fillScene(d, ctx, pcp), politeness, threshold, bSafe)
end

-- MOBIL answers "is this move worth it", which is not the same question as "does this
-- physically fit". When the target lane is plainly empty for a long way in both directions
-- a real driver goes anyway and just takes it gently, so that case gets a second look.
function M.lanePlainlyClear(ctx, pcp)
  local front, rear = pcp.tgtFrontGap or -1, pcp.tgtRearGap or -1
  -- Sized by closing speed, not by our own: a gap is only clear relative to whoever is
  -- coming into it. Roughly 2.5 s of closing plus a standing margin.
  if front >= 0 then
    local closing = ctx.speed * 1.15 - (pcp.tgtFrontSpeed or 0)
    if closing < 0 then closing = 0 end
    if front < 18 + closing * 2.5 then return false end
  end
  if rear >= 0 then
    local closing = (pcp.tgtRearSpeed or 0) - ctx.speed
    if closing < 0 then closing = 0 end
    if rear < 12 + closing * 2.5 then return false end
  end
  -- The lane has to exist: enough road left of the target offset for the car plus a margin.
  local tr = ctx.tracking
  if tr and tr.halfWidth and tr.halfWidth > 0 then
    local room = tr.halfWidth - math.abs(ctx.laneCenter) - (ctx.veh.width or 2) * 0.5
    if room < 0.4 then return false end
  end
  return true
end

function M.chooseSide(d, ctx, pcp)
  local ot = d.ot
  local inner = -ctx.sideSign
  local outer = ctx.sideSign

  if ctx.ourLanes > 1 then
    if ctx.laneIdx > 0 then
      perception.senseTargetLane(ctx, d, inner * ctx.laneWidth)
      if M.lanePlainlyClear(ctx, pcp) then
        local ok = mobilSays(d, ctx, pcp)
        ot.cautious = not ok
        return inner, 0
      end
      local ok, gain, why = mobilSays(d, ctx, pcp)
      if ok then return inner, 0 end
      ot.reject = 'interior: ' .. (why or '?')
    end
    -- Undertaking. Frowned on, so it needs a keener driver, but it is the only option left
    -- for someone stuck in the inside lane behind a slow car.
    if ctx.laneIdx < ctx.ourLanes - 1 and d.d.overtakeEagerness > 0.35 then
      perception.senseTargetLane(ctx, d, outer * ctx.laneWidth)
      if M.lanePlainlyClear(ctx, pcp) then
        ot.cautious = true
        return outer, 0
      end
      local ok, gain, why = mobilSays(d, ctx, pcp)
      if ok then return outer, 0 end
      ot.reject = 'exterior: ' .. (why or '?')
    elseif ctx.laneIdx == 0 then
      -- Innermost lane already, so the only way past is the outside. Reserved for a lane
      -- that is demonstrably empty, since it is still undertaking.
      perception.senseTargetLane(ctx, d, outer * ctx.laneWidth)
      if ctx.ourLanes > 1 and M.lanePlainlyClear(ctx, pcp) then
        ot.cautious = true
        return outer, 0
      end
      ot.reject = 'ya va por dentro'
    end
    return nil
  end

  if ctx.tracking and ctx.tracking.isOneWay then
    ot.reject = 'via de sentido unico'
    return nil
  end

  -- Fog and darkness shorten how much empty road anyone can honestly vouch for.
  local need = clearanceNeeded(d, ctx, pcp)
  if need > MAX_VERIFIABLE * conditions.visibility then
    ot.reject = string.format('hace falta %.0fm de via', need)
    return nil
  end
  if pcp.oncomingGap >= 0 and pcp.oncomingGap < need then
    ot.reject = string.format('viene uno a %.0fm, hace falta %.0fm', pcp.oncomingGap, need)
    return nil
  end
  return inner, need
end

function M.reset(d)
  local ot = d.ot
  ot.phase, ot.targetId, ot.timer, ot.cooldown, ot.urge = M.IDLE, 0, 0, 0, 0
  ot.speedCap, ot.speedBoost, ot.ignoreId, ot.abortCap = -1, 1, 0, -1
  ot.homeOffset, ot.targetOffset, ot.needClear = 0, 0, 0
  ot.usingOncoming, ot.cautious, ot.signalled = false, false, false
  ot.reason, ot.reject = '', ''
end

return M
