local M = {}

local floor = math.floor
local max = math.max

-- One context table reused for every vehicle, every tick. Ticks are sequential, never nested.
local ctx = {
  id = 0, veh = nil, traffic = nil, tracking = nil,
  pos = nil, dir = nil, speed = 0, limit = 0,
  valid = false, laneWidth = 0, ourLanes = 1, laneIdx = 0,
  legalSide = 1, sideSign = 1, roadOffset = 0, laneCenter = 0,
  leadId = 0, leadGap = -1, leadSpeed = 0
}
ctx.rightVec = vec3()

M.ctx = ctx

-- Road geometry comes from the vehicle's own roadTracking, which the traffic system
-- already refreshes on the same 0.25s tick, so this is a read, not a recomputation.
function M.beginTick(tveh, d, traffic)
  local tr = tveh.tracking
  ctx.id, ctx.veh, ctx.d, ctx.traffic, ctx.tracking = tveh.id, tveh, d, traffic, tr
  ctx.pos, ctx.dir = tveh.pos, tveh.dirVec
  ctx.speed = tveh.speed
  ctx.limit = tr and tr.speedLimit or 0
  ctx.valid = false
  if not tr or not tr.isNearRoad or tr.halfWidth <= 0 then return ctx end

  local lanes = tr.linkData and tr.linkData.lanes
  local laneCount
  if lanes and #lanes > 0 then
    laneCount = #lanes
  else
    -- No lane data on this link: infer it from the drivable width instead of assuming one.
    laneCount = floor(tr.halfWidth * 2 / 3.5 + 0.5)
    if laneCount < 1 then laneCount = 1 end
  end
  ctx.legalSide = tr.legalSide
  -- roadOffset grows to the right (roadTracking.lua:129) and legalSide is +1 when the legal
  -- side is the right one (roadTracking.lua:46), so the two share a sign convention.
  ctx.sideSign = tr.legalSide < 0 and -1 or 1

  local sideFrac = tr.isOneWay and 1 or (tr.legalSide < 0 and (1 - tr.centerLineXnorm) or tr.centerLineXnorm)
  if sideFrac <= 0.05 then sideFrac = 1 end

  local ourLanes = floor(sideFrac * laneCount + 0.5)
  if ourLanes < 1 then ourLanes = 1 end
  ctx.ourLanes = ourLanes
  ctx.laneWidth = (tr.halfWidth * 2) * sideFrac / ourLanes
  ctx.roadOffset = tr.roadOffset

  local fromCenter = tr.roadOffset * ctx.sideSign
  local idx = floor(fromCenter / max(0.5, ctx.laneWidth))
  ctx.laneIdx = idx < 0 and 0 or (idx > ourLanes - 1 and ourLanes - 1 or idx)

  -- Centre of the lane this vehicle is in, in roadOffset units. Micro-driving hangs off
  -- this instead of wherever the car happens to be sitting, which is what stopped drivers
  -- from slowly settling against a kerb and staying there.
  ctx.laneCenter = (ctx.laneIdx + 0.5) * ctx.laneWidth * ctx.sideSign

  ctx.rightVec:setSub2(tr.roadRightPos, tr.roadLeftPos)
  ctx.rightVec:normalize()
  ctx.valid = ctx.laneWidth > 1.5

  return ctx
end

function M.send(id, command)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(command) end
end

-- Three long pulses. Short blips were invisible, which is why nobody ever saw these.
function M.flashBeams(veh)
  local obj = getObjectByID(veh.id)
  if not obj then return end
  local rest = 'electrics.setLightsState(' .. (veh.headlights and 1 or 0) .. ')'
  obj:queueLuaCommand('electrics.setLightsState(2)')
  veh.queuedFuncs.taiBeam1 = {timer = 0.35, vLua = rest}
  veh.queuedFuncs.taiBeam2 = {timer = 0.60, vLua = 'electrics.setLightsState(2)'}
  veh.queuedFuncs.taiBeam3 = {timer = 0.95, vLua = rest}
  veh.queuedFuncs.taiBeam4 = {timer = 1.20, vLua = 'electrics.setLightsState(2)'}
  veh.queuedFuncs.taiBeam5 = {timer = 1.55, vLua = rest}
end

-- roadOffset grows toward the driver's right (roadTracking.lua:128), and electrics
-- publishes turnsignal as 1 right / -1 left, so the sign of a lateral move is the indicator
-- directly. toggle_* flips, so the published state decides whether a call is needed at all.
function M.signal(ctx, want)
  local o = map.objects and map.objects[ctx.id]
  local cur = (o and o.states and o.states.turnsignal) or 0
  if cur == want then return end
  local t = want ~= 0 and want or cur
  if t == 0 then return end
  M.send(ctx.id, t > 0 and 'electrics.toggle_right_signal()' or 'electrics.toggle_left_signal()')
end

-- Every steering behaviour re-asserts its target on every tick, and each assertion is a
-- formatted string pushed across a thread boundary. Repeating an unchanged command costs
-- real time and produces nothing, so near-identical requests are dropped.
local lastLateral = {}

function M.forgetLateral(id)
  lastLateral[id] = nil
end

-- ai.laneChange positive is to the right, like roadOffset: ai.lua's own kerbside stop
-- passes +disp on right-hand-traffic maps (ai.lua:4411).
-- No behaviour may aim a car off the tarmac or against whatever lines it. On open desert
-- roads a wheel over the edge is a car in the ditch; elsewhere the edge is a guard rail. The
-- edges in roadOffset units follow from roadTracking.lua:129.
-- Half a metre: enough to stay off a guard rail, and still leaves a 3.5 m lane some room to
-- move over in. Stopping at the kerb keeps a wider 0.8 m (units.KERB_STOP).
local EDGE_MARGIN = 0.5

function M.clampOffset(ctx, targetOffset)
  local tr = ctx.tracking
  if tr and tr.halfWidth and tr.halfWidth > 0 then
    local c = tr.centerLineXnorm or 0.5
    local half = ((ctx.veh and ctx.veh.width) or 2) * 0.5 + EDGE_MARGIN
    local lo = -2 * tr.halfWidth * c + half
    local hi = 2 * tr.halfWidth * (1 - c) - half
    if lo < hi then
      if targetOffset < lo then return lo elseif targetOffset > hi then return hi end
    end
  end
  return targetOffset
end

function M.lateralHold(ctx, targetOffset, limit)
  targetOffset = M.clampOffset(ctx, targetOffset)
  local err = targetOffset - ctx.roadOffset
  limit = limit or (ctx.laneWidth + 1)
  if err > limit then err = limit elseif err < -limit then err = -limit end
  local dist = ctx.speed * 1.2
  if dist < 6 then dist = 6 end

  local prev = lastLateral[ctx.id]
  if prev and prev[1] > err - 0.06 and prev[1] < err + 0.06
    and prev[2] > dist - 2.5 and prev[2] < dist + 2.5 then
    return err
  end
  if prev then prev[1], prev[2] = err, dist else lastLateral[ctx.id] = {err, dist} end

  M.send(ctx.id, string.format('ai.laneChange(nil, %.1f, %.2f)', dist, err))
  return err
end

return M
