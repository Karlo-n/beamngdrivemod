local M = {}

local abs = math.abs
local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')

M.NONE, M.WARN, M.EVADE = 0, 1, 2

local toEdge = vec3()

-- The repertoire is fixed per driver (d.d.warnStyle), so the quiet ones stay quiet and the
-- horn-happy ones always reach for the horn. Only the timing varies.
local function warn(d, ctx, threatId)
  local ev, style = d.ev, d.d.warnStyle
  if style == 0 or ev.warnedFor == threatId then return end
  ev.warnedFor = threatId

  local veh = ctx.veh
  if style == 1 or style == 3 then
    veh:honkHorn(0.2 + d.p.temper * 0.7)
  end
  if style == 2 or style == 3 then
    -- After dark the flash is the signal that actually carries; by day it is mostly a gesture.
    if veh:checkTimeOfDay() == false or random() < 0.5 then
      base.flashBeams(veh)
    end
  end
end

-- Away from whichever side the threat is on, not blindly toward the kerb.
local function escapeTarget(ctx, threatLat)
  local tr = ctx.tracking
  if not tr then return nil end
  local awayIsRight = threatLat < 0
  toEdge:setSub2(awayIsRight and tr.roadRightPos or tr.roadLeftPos, ctx.pos)
  local distEdge = toEdge:dot(ctx.rightVec)
  local myHalfW = (ctx.veh.width or 2.0) * 0.5
  local margin = myHalfW + 0.3
  return awayIsRight and (distEdge - margin) or (distEdge + margin)
end

function M.update(d, ctx, pcp, dt)
  local ev = d.ev
  ev.speedCap = -1

  local ttc = pcp.threatTtc
  if pcp.threatId == 0 or ttc < 0 or not ctx.valid then
    ev.level, ev.active, ev.delay = M.NONE, false, 0
    return nil
  end

  local warnAt = 3.0 + d.p.prudence * 1.5 + d.d.reaction
  local evadeAt = 1.5 + d.p.prudence * 0.9 + d.d.reaction

  if ttc > warnAt then
    ev.level, ev.active, ev.delay = M.NONE, false, 0
    return nil
  end

  -- Nobody reacts the instant a threat appears. This is the gap between seeing and acting.
  if ev.threatId ~= pcp.threatId then
    ev.threatId, ev.delay = pcp.threatId, d.d.warnDelay
  end
  if ev.delay > 0 then
    ev.delay = ev.delay - dt
    if ev.delay > 0 and ttc > evadeAt * 0.6 then return nil end
    ev.delay = 0
  end

  ev.active, ev.ttc = true, ttc
  warn(d, ctx, pcp.threatId)

  if ttc > evadeAt then
    ev.level = M.WARN
    ev.speedCap = ctx.speed * 0.75
    return 'evade'
  end

  ev.level = M.EVADE

  -- Braking is the feasible escape at low speed, steering at high speed, both at the last
  -- moment. Whether this driver is a swerver at all was decided when they were created.
  local steers = d.d.swerver and (ctx.speed > 5 or ttc < 1.0)
  if steers then
    local lat = escapeTarget(ctx, pcp.threatLat)
    if lat then
      base.lateralHold(ctx, ctx.roadOffset + lat, ctx.laneWidth + 2)
      ev.dodgeSide = pcp.threatLat < 0 and 1 or -1
    else
      steers = false
    end
  end

  ev.speedCap = (ctx.speed > 8 and not steers) and 0 or ctx.speed * 0.35
  if ev.speedCap < 0 then ev.speedCap = 0 end
  return 'evade'
end

function M.reset(d)
  local ev = d.ev
  ev.level, ev.active, ev.speedCap = M.NONE, false, -1
  ev.ttc, ev.threatId, ev.warnedFor, ev.delay, ev.dodgeSide = -1, 0, 0, 0, 0
end

return M
