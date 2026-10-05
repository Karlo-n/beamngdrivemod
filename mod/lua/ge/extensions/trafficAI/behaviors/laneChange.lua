local M = {}

local abs = math.abs
local max = math.max
local random = math.random
local format = string.format

local base = require('trafficAI/behaviors/baseBehavior')
local perception = require('trafficAI/environment/perception')

M.IDLE, M.WANT, M.CHECK, M.EXEC, M.COOL = 0, 1, 2, 3, 4

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
    if pcp.tgtRearGap < rearNeed then return false end
  end

  return true
end

function M.update(d, ctx, pcp, dt)
  local lc, dd = d.lc, d.d

  if lc.cooldown > 0 then
    lc.cooldown = lc.cooldown - dt
    if lc.cooldown < 0 then lc.cooldown = 0 end
  end

  if lc.phase == M.EXEC then
    lc.timer = lc.timer - dt
    local err = issue(ctx, lc)
    if abs(err) < ctx.laneWidth * 0.2 then
      lc.phase, lc.cooldown, lc.urge = M.COOL, 3 + random() * 4, 0
      base.signal(ctx, 0)
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
        lc.phase, lc.timer = M.EXEC, dd.laneChangeTime
        lc.side = ctx.sideSign
        lc.targetOffset = ctx.roadOffset + ctx.sideSign * ctx.laneWidth
        lc.keepRight = dd.laneDiscipline
        if dd.indicates then base.signal(ctx, lc.side) end
        issue(ctx, lc)
        return 'laneChange'
      end
      lc.keepRight = 3
    end
  elseif blocked then
    lc.keepRight = dd.laneDiscipline
  end

  if lc.urge < dd.patienceDelay then return nil end
  if ctx.ourLanes < 2 or ctx.laneIdx <= 0 then return nil end

  lc.phase = M.CHECK
  perception.senseTargetLane(ctx, d, -ctx.sideSign * ctx.laneWidth)

  local safe = targetLaneSafe(ctx, d, pcp)
  d.pm.tgtSafe = safe and 1 or 0
  if not safe then return nil end

  lc.phase = M.EXEC
  lc.timer = dd.laneChangeTime
  lc.side = -ctx.sideSign
  lc.targetOffset = ctx.roadOffset - ctx.sideSign * ctx.laneWidth
  if dd.indicates then base.signal(ctx, lc.side) end
  issue(ctx, lc)
  return 'laneChange'
end

function M.reset(d)
  local lc = d.lc
  lc.phase, lc.timer, lc.cooldown = M.IDLE, 0, 0
  lc.urge, lc.side, lc.targetOffset = 0, 0, 0
  lc.keepRight = d.d.laneDiscipline
end

return M
