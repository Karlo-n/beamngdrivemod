local M = {}

local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')
local perception = require('trafficAI/environment/perception')
local units = require('trafficAI/util/units')

M.NONE, M.CHASE, M.FLEE = 0, 1, 2
M.HUNT, M.RAM, M.CUT_OFF = 0, 1, 2

local RAM_RANGE = 18
local CUT_LEAD = 6 -- metres ahead of the target where cutting in front becomes possible

-- Chasing someone is not just following faster. What the angry driver does once alongside
-- depends on how far they are willing to take it.
local function chase(d, ctx, dt)
  local pu = d.pu
  local fwd, lat = perception.relativeTo(ctx, pu.targetId)
  if not fwd then
    pu.mode = M.NONE
    return nil
  end

  pu.speedBoost, pu.speedCap = 1.25, -1

  -- Ahead of them now: swing across and slow down hard. This is the move that actually
  -- ends a chase, and only the ones with a real mean streak pull it.
  if fwd < -CUT_LEAD and d.p.ragebait > 0.35 then
    pu.phase = M.CUT_OFF
    base.lateralHold(ctx, ctx.roadOffset + lat, ctx.laneWidth + 2)
    pu.speedCap, pu.speedBoost = ctx.speed * 0.45, 1
    return 'pursue'
  end

  -- Right behind them and willing: aim the car at where they actually are.
  if fwd > 0 and fwd < RAM_RANGE and d.p.ragebait > 0.5 and d.state == 'angry' then
    pu.phase = M.RAM
    base.lateralHold(ctx, ctx.roadOffset + lat, ctx.laneWidth + 2)
    return 'pursue'
  end

  pu.phase = M.HUNT
  return 'pursue'
end

-- Running from the scene. Nerve does not last: most people talk themselves into stopping.
local function flee(d, ctx, dt)
  local pu = d.pu
  pu.speedBoost, pu.speedCap = 1.2, -1

  pu.decideTimer = pu.decideTimer - dt
  if pu.decideTimer <= 0 then
    pu.decideTimer = 4 + random() * 5
    -- Prudence and a guilty conscience win over time; bravado keeps going.
    local giveUp = 0.15 + d.p.prudence * 0.5 - d.d.bravery * 0.3 + pu.timer * 0.01
    if random() < giveUp then
      pu.mode = M.NONE
      return 'gaveUp'
    end
  end
  return 'pursue'
end

function M.update(d, ctx, dt)
  local pu = d.pu
  pu.speedCap, pu.speedBoost = -1, 1
  if pu.mode == M.NONE then return nil end

  pu.timer = pu.timer - dt
  if pu.timer <= 0 then
    pu.mode = M.NONE
    return 'over'
  end

  if pu.mode == M.CHASE then return chase(d, ctx, dt) end
  return flee(d, ctx, dt)
end

function M.start(d, mode, targetId, duration)
  if mode == M.CHASE and units.isEmergency(targetId) then return end
  local pu = d.pu
  pu.mode, pu.targetId, pu.timer = mode, targetId or 0, duration or 20
  pu.phase, pu.decideTimer = M.HUNT, 5
end

function M.reset(d)
  local pu = d.pu
  pu.mode, pu.targetId, pu.timer, pu.phase = M.NONE, 0, 0, M.HUNT
  pu.speedCap, pu.speedBoost, pu.decideTimer = -1, 1, 0
end

return M
