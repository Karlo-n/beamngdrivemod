local M = {}

local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')
local units = require('trafficAI/util/units')

M.PUSH, M.BACK = 1, 2

-- Riding up close then dropping back again, over and over. It is not an attempt to pass:
-- the point is to be felt by the driver in front.
function M.update(d, ctx, pcp, dt)
  local itm = d.itm
  itm.speedCap, itm.gapMult = -1, 1

  local hostile = d.state == 'angry' or d.state == 'aggressive' or d.frustration > 0.85
  local willing = d.p.ragebait > 0.15 or d.p.aggression > 0.7
  if not hostile or not willing or pcp.leadId == 0 or units.isEmergency(pcp.leadId) then
    itm.active, itm.phase, itm.timer = false, 0, 0
    return nil
  end

  local v0 = ctx.limit * d.d.speedFactor
  if pcp.leadSpeed > v0 * 0.9 or pcp.leadGap > d.cf.desiredGap * 2.5 then
    itm.active, itm.phase = false, 0
    return nil
  end

  itm.timer = itm.timer - dt
  if itm.timer <= 0 then
    if itm.phase == M.PUSH then
      itm.phase, itm.timer = M.BACK, 0.8 + random() * 1.6
    else
      itm.phase, itm.timer = M.PUSH, 1.2 + random() * 2.0
    end
  end
  itm.active, itm.targetId = true, pcp.leadId

  -- Flashing the car in front is the classic move, and this is where it happens often
  -- enough to be seen. Style is fixed per driver, so the same cars always do it.
  itm.flashTimer = itm.flashTimer - dt
  if itm.flashTimer <= 0 then
    itm.flashTimer = 5 + random() * 9
    local style = d.d.warnStyle
    if (style == 2 or style == 3) and random() < 0.55 then
      base.flashBeams(ctx.veh)
    end
  end

  if itm.phase == M.PUSH then
    -- Collapse the following distance well inside what this driver would normally keep.
    itm.gapMult = 0.30 + (1 - d.p.aggression) * 0.25
  else
    itm.gapMult = 1.6
    itm.speedCap = pcp.leadSpeed * 0.85
  end

  return 'intimidate'
end

function M.reset(d)
  local itm = d.itm
  itm.active, itm.phase, itm.timer = false, 0, 0
  itm.speedCap, itm.gapMult, itm.targetId = -1, 1, 0
  itm.flashTimer = 0
end

return M
