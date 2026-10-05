local M = {}

local abs = math.abs
local max = math.max
local random = math.random
local format = string.format

local base = require('trafficAI/behaviors/baseBehavior')
local perception = require('trafficAI/environment/perception')

M.IDLE, M.WANT, M.CHECK, M.EXEC, M.COOL, M.SIGNAL = 0, 1, 2, 3, 4, 5

local ABORT_MARGIN = 0.35 -- fraction of a lane still to cover when the timer runs out

-- ai.laneChange displaces the current plan, and the plan is rebuilt continuously, so the
-- command is re-issued every tick as a closed loop on the remaining lateral error.
local function issue(ctx, lc)
  local err = base.clampOffset(ctx, lc.targetOffset) - ctx.roadOffset
  local w = ctx.laneWidth
  if err > w then err = w elseif err < -w then err = -w end
  local dist = ctx.speed * 1.5
  if dist < 8 then dist = 8 end
  base.send(ctx.id, format('ai.laneChange(nil, %.1f, %.2f)', dist, err))
  return err
end

local function targetLaneSafe(ctx, d, pcp)
  local dd = d.d
  local v = ctx.speed

  local frontNeed = dd.gapMin + v * dd.gapTime * 0.7
  if pcp.tgtFrontGap >= 0 and pcp.tgtFrontGap < frontNeed then return false end

  if pcp.tgtRearGap >= 0 then
    local closing = pcp.tgtRearSpeed - v
    local rearNeed = dd.gapMin + max(0, closing) * dd.rearPolitness * 2 + v * 0.25
    -- The driver there has seen the indicator and is dropping back to let us in.
    local rd = pcp.tgtRearId ~= 0 and trafficAI_main and trafficAI_main.getDriver(pcp.tgtRearId)
    if rd and rd.dr.letIn and rd.dr.mergerSeen == ctx.id then rearNeed = rearNeed * 0.5 end
    if pcp.tgtRearGap < rearNeed then return false end
  end

  return true
end

-- Indicator first, then a look, then the move. Moving the instant the indicator came on gave
-- nobody behind a chance to react, and it is not how anyone is taught to do it. The ones who
-- never indicate still take a glance.
local function begin(d, ctx, side)
  local lc = d.lc
  lc.phase, lc.side = M.SIGNAL, side
  lc.timer = d.d.indicates and (0.9 + random() * 1.0) or (0.2 + random() * 0.3)
  if d.d.indicates then base.signal(ctx, side) end
  return 'laneChange'
end

-- A brief flash of the hazards to the driver who made room. Plenty of people do it.
local function thank(d, ctx)
  local veh = ctx.veh
  if not veh or not veh.queuedFuncs or random() > 0.2 + d.p.tolerance * 0.5 then return end
  base.send(ctx.id, 'electrics.set_warn_signal(1)')
  veh.queuedFuncs.taiThanks = {timer = 1.3, vLua = 'electrics.set_warn_signal(0)'}
end

function M.update(d, ctx, pcp, dt)
  local lc, dd = d.lc, d.d

  if lc.cooldown > 0 then
    lc.cooldown = lc.cooldown - dt
    if lc.cooldown < 0 then lc.cooldown = 0 end
  end

  if lc.phase == M.SIGNAL then
    lc.timer = lc.timer - dt
    -- Still looking: the gap has to stay there for the whole time the indicator is on.
    perception.senseTargetLane(ctx, d, lc.side * ctx.laneWidth)
    if not ctx.valid or not targetLaneSafe(ctx, d, pcp) then
      lc.phase, lc.cooldown = M.IDLE, 1.5
      base.signal(ctx, 0)
      return nil
    end
    if lc.timer > 0 then return 'laneChange' end
    lc.phase, lc.timer = M.EXEC, dd.laneChangeTime
    lc.targetOffset = ctx.laneCenter + lc.side * ctx.laneWidth
    lc.tightRear = pcp.tgtRearGap >= 0 and pcp.tgtRearGap < 20
    issue(ctx, lc)
    return 'laneChange'
  end

  if lc.phase == M.EXEC then
    lc.timer = lc.timer - dt
    local err = issue(ctx, lc)
    if abs(err) < ctx.laneWidth * 0.2 then
      lc.phase, lc.cooldown, lc.urge = M.COOL, 3 + random() * 4, 0
      base.signal(ctx, 0)
      if lc.tightRear then thank(d, ctx) end
      return 'overtaking'
    end
    if lc.timer <= 0 then
      -- Ran out of time still short of the lane: give up and let the plan settle.
      lc.phase, lc.urge = M.COOL, 0
      lc.cooldown = abs(err) > ctx.laneWidth * ABORT_MARGIN and 6 or 3
      base.signal(ctx, 0)
      return 'laneChange'
    end
    return 'laneChange'
  end

  if not ctx.valid or lc.cooldown > 0 then
    lc.phase = M.IDLE
    return nil
  end

  local v0 = ctx.limit * dd.speedFactor
  local blocked = pcp.leadId ~= 0
    and pcp.leadGap < d.cf.desiredGap * 1.2
    and pcp.leadSpeed < v0 * 0.9

  if blocked then
    lc.urge = lc.urge + dt
    lc.phase = M.WANT
  else
    lc.urge = lc.urge - dt * 1.5
    if lc.urge <= 0 then
      lc.urge, lc.phase = 0, M.IDLE
      return nil
    end
  end

  -- Sitting in an inner lane with nothing in the way is lane hogging. Disciplined drivers
  -- move back out; the ones who do not are exactly the ones other drivers end up stuck behind.
  if not blocked and ctx.ourLanes > 1 and ctx.laneIdx > 0 and lc.keepRight > 0 then
    lc.keepRight = lc.keepRight - dt
    if lc.keepRight <= 0 then
      perception.senseTargetLane(ctx, d, ctx.sideSign * ctx.laneWidth)
      if targetLaneSafe(ctx, d, pcp) then
        lc.keepRight = dd.laneDiscipline
        return begin(d, ctx, ctx.sideSign)
      end
      lc.keepRight = 3
    end
  elseif blocked then
    lc.keepRight = dd.laneDiscipline
  end

  -- A stopped car in our lane is not something to sit behind, whoever is driving. The way
  -- round is whichever lane exists, inner first; the outer one is fine for this. A queue at
  -- a light is not that: nothing ahead of the stopped car, and no red in sight, is.
  local redAhead = pcp.signalDist >= 0 and pcp.signalDist < 60
    and (pcp.signalAction == 2 or pcp.signalAction == 3 or pcp.signalAction == 4)
  local headOfQueue = pcp.lead2Gap < 0 or pcp.lead2Gap > pcp.leadGap + 25
  local stopped = blocked and pcp.obstacleId ~= 0 and pcp.obstacleId == pcp.leadId
    and not redAhead and headOfQueue
  local wait = stopped and (dd.patienceDelay < 2.5 and dd.patienceDelay or 2.5) or dd.patienceDelay
  if lc.urge < wait or ctx.ourLanes < 2 or d.state == 'asleep' then return nil end

  local sides = 0
  if ctx.laneIdx > 0 then sides = -ctx.sideSign end
  for pass = 1, 2 do
    local side = pass == 1 and sides or (stopped and ctx.laneIdx < ctx.ourLanes - 1 and ctx.sideSign or 0)
    if side ~= 0 then
      lc.phase = M.CHECK
      perception.senseTargetLane(ctx, d, side * ctx.laneWidth)
      local safe = targetLaneSafe(ctx, d, pcp)
      d.pm.tgtSafe = safe and 1 or 0
      if safe then return begin(d, ctx, side) end
    end
  end
  return nil
end

function M.reset(d)
  local lc = d.lc
  lc.phase, lc.timer, lc.cooldown = M.IDLE, 0, 0
  lc.urge, lc.side, lc.targetOffset, lc.tightRear = 0, 0, 0, false
  lc.keepRight = d.d.laneDiscipline
end

return M
