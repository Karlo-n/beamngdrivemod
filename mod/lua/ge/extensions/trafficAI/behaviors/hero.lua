local M = {}

local abs = math.abs
local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')

M.IDLE, M.WATCH, M.BLOCK, M.DONE = 0, 1, 2, 3

local SPOT_RANGE = 75
local BLOCK_WINDOW = 32 -- metres behind us where a runner is close enough to be worth blocking
-- Never more than this fraction of a lane. The idea is to make the gap awkward, not to
-- T-bone someone at speed: a full block is a crash, and a crash helps nobody.
local MAX_ENCROACH = 0.45

local toTarget = vec3()

-- Someone the police are actually after. gameplay_police keeps this on the traffic record,
-- so it covers the player too without any special case.
local function findRunner(ctx)
  local traffic = ctx.traffic
  if not traffic then return nil end

  local bestId, bestFwd, bestLat = nil, 0, 0
  for id, tveh in pairs(traffic) do
    if id ~= ctx.id and tveh.pursuit and tveh.pursuit.mode and tveh.pursuit.mode > 0
      and tveh.pos then
      toTarget:setSub2(tveh.pos, ctx.pos)
      if toTarget:squaredLength() < SPOT_RANGE * SPOT_RANGE then
        local fwd = toTarget:dot(ctx.dir)
        -- Only useful while they are still behind or level with us.
        if fwd < 6 and fwd > -BLOCK_WINDOW and (not bestId or fwd > bestFwd) then
          bestId, bestFwd = id, fwd
          bestLat = toTarget:dot(ctx.rightVec)
        end
      end
    end
  end
  return bestId, bestFwd, bestLat
end

function M.update(d, ctx, pcp, dt)
  local hr = d.hr
  hr.speedCap = -1

  if d.typeId ~= 'hero' or not ctx.valid then
    hr.phase, hr.targetId = M.IDLE, 0
    return nil
  end

  if hr.cooldown > 0 then
    hr.cooldown = hr.cooldown - dt
    if hr.cooldown < 0 then hr.cooldown = 0 end
    return nil
  end

  local id, fwd, lat = findRunner(ctx)
  if not id then
    if hr.phase ~= M.IDLE then
      if abs(hr.applied) > 0.05 then
        base.lateralHold(ctx, ctx.roadOffset - hr.applied, ctx.laneWidth)
      end
      hr.phase, hr.targetId, hr.applied = M.IDLE, 0, 0
    end
    return nil
  end

  hr.targetId, hr.gap, hr.lat = id, fwd, lat

  -- They are past us: unwind the lean and get back to normal driving.
  if fwd > 4 then
    if abs(hr.applied) > 0.05 then
      base.lateralHold(ctx, ctx.roadOffset - hr.applied, ctx.laneWidth)
    end
    hr.phase, hr.cooldown, hr.applied = M.DONE, 6 + random() * 6, 0
    return nil
  end

  -- Still far back: hold position and get ready rather than swerving early.
  if fwd < -BLOCK_WINDOW * 0.6 then
    hr.phase = M.WATCH
    return 'hero'
  end

  hr.phase = M.BLOCK

  -- Drift a fraction of a lane toward the line they are running on. Confidence decides how
  -- far this driver is willing to stick their car out.
  local reach = ctx.laneWidth * MAX_ENCROACH * (0.5 + d.p.confidence * 0.5)
  local want = lat > 0 and reach or -reach
  if abs(lat) < 0.8 then want = 0 end -- already in front of them, no need to lean over

  local delta = want - hr.applied
  if abs(delta) > 0.05 then
    hr.applied = want
    base.lateralHold(ctx, ctx.roadOffset + delta, ctx.laneWidth)
  end

  -- Being slightly slow is half the obstruction.
  hr.speedCap = ctx.limit * (0.55 + (1 - d.p.confidence) * 0.25)
  return 'hero'
end

function M.reset(d)
  local hr = d.hr
  hr.phase, hr.targetId, hr.cooldown = M.IDLE, 0, 0
  hr.speedCap, hr.applied, hr.gap, hr.lat = -1, 0, 0, 0
end

return M
