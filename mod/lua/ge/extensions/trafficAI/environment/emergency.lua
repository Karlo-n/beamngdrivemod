local M = {}
local units = require('trafficAI/util/units')

local random = math.random
local format = string.format

-- Ambulances and fire engines exist as real configs in 0.39.4, and traffic.lua exposes a
-- registration point for extra special vehicles (traffic.lua:60), so they are spawned by the
-- game's own group builder rather than dropped in by hand.
-- Deliberately the light bodies only. A 6x6 fire engine or an md_series box van costs
-- several ordinary cars' worth of physics, and one of those parked in view was enough to
-- move the frame rate on its own.
local AMBULANCES = {
  {model = 'van', config = 'ambulance'},
  {model = 'van', config = 'ambulance_eu'},
  {model = 'pickup', config = 'd45_ambulance_A'}
}
local FIRE = {
  {model = 'roamer', config = 'firechief'},
  {model = 'legran', config = 'firechief'}
}

M.AMBULANCE, M.FIRE = 1, 2
M.IDLE, M.ENROUTE, M.ONSCENE = 0, 1, 2

M.enabled = true
M.units = {}        -- id -> unit state
M.reserved = {}     -- patrol ids this module is using, so the police modules leave them be
M.incident = nil    -- the single scene being worked right now
M.callCount = 0

local TICK = 0.5
local GAP_MIN, GAP_MAX = 120, 300
local ARRIVE_SQ = 24 * 24
local ENROUTE_LIMIT = 150   -- seconds before a unit gives up trying to get there
local CRASH_DAMAGE = 3000

local timer = 0
local nextCall = 90
local scanPos = vec3()

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function pickGroup(list, count)
  local group = {}
  for i = 1, count do
    local e = list[random(#list)]
    group[i] = {model = e.model, config = e.config}
  end
  return group
end

-- No longer spawned. Every extra body is physics the frame budget has to pay for, and the
-- gain was not worth it. The behaviour below still runs for an ambulance or fire engine the
-- player brings themselves, and police still turn out to crashes.
M.spawnUnits = false

function M.registerProviders()
  if not M.spawnUnits then return end
  if not gameplay_traffic or not gameplay_traffic.registerSpecialVehicleProvider then return end

  gameplay_traffic.registerSpecialVehicleProvider({
    name = 'trafficAI_ambulance', priority = 6, minTotalAmount = 8,
    getDesiredCount = function(_, options)
      if not options or not options.police then return 0 end
      return random() < 0.5 and 1 or 0
    end,
    buildGroup = function(count) return pickGroup(AMBULANCES, count) end
  })
end

-- Model and config are the only reliable markers; the traffic system files both of these
-- under the generic "Service" config type, so it cannot tell them apart for us.
function M.classify(id)
  local obj = getObjectByID(id)
  if not obj then return nil end
  local pc = string.lower(obj.partConfig or '')
  if pc == '' then return nil end
  if string.find(pc, 'ambulance', 1, true) then return M.AMBULANCE end
  if string.find(pc, 'firetruck', 1, true) or string.find(pc, 'firechief', 1, true) then
    return M.FIRE
  end
  return nil
end

function M.onVehicleAdded(id)
  local kind = M.classify(id)
  if not kind then return end
  M.units[id] = {kind = kind, phase = M.IDLE, timer = 0,
                 label = kind == M.AMBULANCE and 'ambulancia' or 'bomberos'}
end

function M.onVehicleRemoved(id)
  local u = M.units[id]
  if u and u.phase ~= M.IDLE and M.incident then
    M.incident.attending[id] = nil
  end
  M.units[id] = nil
end

function M.onCall(id)
  local u = M.units[id]
  return u ~= nil and u.phase ~= M.IDLE
end

function M.isUnit(id)
  return M.units[id] ~= nil
end

-- ---------------------------------------------------------------- dispatch

-- Driving to a place means having a place to drive to. 'manual' mode plus a real map node
-- is the only stock mode that actually navigates somewhere and stops on arrival; 'random'
-- just wanders, which is why units never turned up anywhere.
local function dispatch(id, u, pos, urgent)
  local data = traffic()
  local veh = data and data[id]
  if not veh or not units.ai(veh) then return false end

  -- If the level has a lay-by or parking area beside the incident, work from there instead
  -- of leaving an ambulance stopped in a live lane.
  local parking = require('trafficAI/behaviors/parking')
  local target = pos
  local ps = parking.spotNear(pos, 70, id)
  if ps then
    parking.reserve(ps)
    u.spot, target = ps, ps.pos
  end

  local n1 = map.findClosestRoad and map.findClosestRoad(target)
  if not n1 then
    if ps then parking.unreserve(ps) u.spot = nil end
    return false
  end

  u.phase, u.timer, u.dest = M.ENROUTE, ENROUTE_LIMIT, target
  veh:setAiMode('manual')
  send(id, format('ai.setTarget(%q)', n1))
  -- Lights and speed, but still looking where it is going: aggression stays sane and car
  -- avoidance stays ON, which 'random' mode turns off.
  send(id, 'ai.setAvoidCars("on")')
  send(id, 'ai.driveInLane("on")')
  send(id, 'ai.setSpeedMode("off")')
  send(id, 'ai.setAggressionMode("off")')
  send(id, format('ai.setAggression(%.2f)', urgent and 0.68 or 0.55))
  send(id, 'electrics.set_lightbar_signal(2)')
  veh:useSiren(2 + random() * 3)
  M.callCount = M.callCount + 1
  return true
end

-- Police turn out to accidents as well. They are not ours to drive, so this borrows one
-- and hands it straight back.
local function dispatchPatrol(pos)
  if not gameplay_police or not gameplay_police.getPoliceVehicles then return end
  local policeStop = require('trafficAI/behaviors/policeStop')
  local data = traffic()
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  if not data or not n1 then return end

  for pid in pairs(gameplay_police.getPoliceVehicles()) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and not M.reserved[pid] and not policeStop.stops[pid]
      and not (v.pursuit and v.pursuit.mode and v.pursuit.mode > 0) then
      M.reserved[pid] = {timer = ENROUTE_LIMIT, dest = vec3(pos), onScene = false}
      v:setAiMode('manual')
      send(pid, format('ai.setTarget(%q)', n1))
      send(pid, 'ai.setAvoidCars("on")')
      send(pid, 'ai.driveInLane("on")')
      send(pid, 'ai.setSpeedMode("off")')
      send(pid, 'ai.setAggressionMode("off")')
      send(pid, 'ai.setAggression(0.62)')
      send(pid, 'electrics.set_lightbar_signal(2)')
      v:useSiren(2 + random() * 2)
      return pid
    end
  end
  return nil
end

local function releasePatrol(pid)
  M.reserved[pid] = nil
  send(pid, 'electrics.set_lightbar_signal(0)')
  send(pid, 'electrics.set_warn_signal(0)')
  send(pid, 'ai.setPullOver(false)')
  send(pid, 'ai.setSpeedMode("legal")')
  local data = traffic()
  local v = data and data[pid]
  if v and units.ai(v) then v:setAiMode('traffic') end
end

local function standDown(id, u)
  if u.spot then
    require('trafficAI/behaviors/parking').unreserve(u.spot)
    u.spot = nil
  end
  u.phase, u.timer, u.dest = M.IDLE, 0, nil
  send(id, 'electrics.set_lightbar_signal(0)')
  send(id, 'electrics.set_warn_signal(0)')
  send(id, 'ai.setPullOver(false)')
  send(id, 'ai.setSpeedMode("legal")')
  local data = traffic()
  local veh = data and data[id]
  if veh and units.ai(veh) then veh:setAiMode('traffic') end
  if M.incident then M.incident.attending[id] = nil end
end

local function onScene(id, u)
  u.phase, u.timer = M.ONSCENE, 28 + random() * 30
  send(id, units.KERB_STOP)
  send(id, 'electrics.set_warn_signal(1)')
  send(id, 'electrics.set_lightbar_signal(1)')
  local data = traffic()
  local veh = data and data[id]
  if veh and units.ai(veh) then veh:setAiMode('traffic') end

  local inc = M.incident
  if not inc then return end
  if u.kind == M.FIRE and inc.kind == 'incendio' and inc.vehId then
    -- Actually putting it out, not miming it: fire.lua exposes this to vehicle Lua.
    send(inc.vehId, 'fire.extinguishVehicleSlowly()')
    inc.extinguished = true
  end
  u.work = u.kind == M.AMBULANCE and 'atendiendo a un herido' or 'sofocando el fuego'
end

-- ---------------------------------------------------------------- incidents

local function freeUnit(kind)
  for id, u in pairs(M.units) do
    if u.phase == M.IDLE and (kind == nil or u.kind == kind) then return id, u end
  end
  return nil
end

-- A real wreck beats an invented call-out. Only something badly damaged and stationary.
local function findWreck(data)
  local playerId = be:getPlayerVehicleID(0)
  local me = data[playerId]
  if me and me.pos and (me.damage or 0) > CRASH_DAMAGE and (me.speed or 0) < 1.5
    and not (me.pursuit and (me.pursuit.mode or 0) > 0) then
    return playerId
  end
  local best, bestDamage = nil, CRASH_DAMAGE
  for id, v in pairs(data) do
    if v.state == 'active' and v.pos and not M.units[id] and id ~= playerId
      and (v.speed or 0) < 1.5 and (v.damage or 0) > bestDamage then
      best, bestDamage = id, v.damage
    end
  end
  return best
end

-- Somewhere plausible to send a unit when nothing has actually happened: a road node a few
-- hundred metres away, so the drive is real even if the call is routine.
-- Built once per level. West Coast has thousands of nodes and walking them all every time
-- a call-out was considered produced a visible stall.
local nodeSample = {}
local nodeSampleCount = 0

function M.buildNodeSample()
  nodeSampleCount = 0
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not nodes then return end
  local n = 0
  for _, node in pairs(nodes) do
    n = n + 1
    if n % 11 == 0 and node.pos then
      nodeSampleCount = nodeSampleCount + 1
      nodeSample[nodeSampleCount] = node.pos
      if nodeSampleCount >= 400 then break end
    end
  end
end

-- A road point between minD and maxD from `fromPos`, for mission destinations.
function M.pointBetween(fromPos, minD, maxD)
  if nodeSampleCount == 0 then M.buildNodeSample() end
  if nodeSampleCount == 0 or not fromPos then return nil end
  local lo, hi = minD * minD, maxD * maxD
  for _ = 1, 24 do
    local p = nodeSample[random(nodeSampleCount)]
    local dist = p:squaredDistance(fromPos)
    if dist > lo and dist < hi then return vec3(p) end
  end
  return nil
end

local function somewhereElse(fromPos)
  if nodeSampleCount == 0 then M.buildNodeSample() end
  if nodeSampleCount == 0 then return nil end
  -- A handful of random probes rather than a full scan.
  for _ = 1, 12 do
    local p = nodeSample[random(nodeSampleCount)]
    local dist = p:squaredDistance(fromPos)
    if dist > 40000 and dist < 640000 then return p end
  end
  return nil
end

local function startIncident(data)
  local wreckId = findWreck(data)
  local kind, pos, vehId

  if wreckId then
    vehId = wreckId
    pos = data[wreckId].pos
    -- A heavy wreck sometimes goes up, but only ever when there is an engine free to put
    -- it out. Setting a car alight that nobody can attend is just vandalism.
    local canBurn = freeUnit(M.FIRE) ~= nil
    kind = (canBurn and data[wreckId].damage > 9000 and random() < 0.45) and 'incendio' or 'accidente'
  else
    local focus = data[be:getPlayerVehicleID(0)]
    local from = focus and focus.pos
    if not from then return false end
    pos = somewhereElse(from)
    if not pos then return false end
    kind = random() < 0.6 and 'aviso medico' or 'alarma de incendio'
  end

  local wantKind = (kind == 'incendio' or kind == 'alarma de incendio') and M.FIRE or M.AMBULANCE
  local id, u = freeUnit(wantKind)
  if not id then
    id, u = freeUnit(nil)
    if kind == 'alarma de incendio' then kind = 'aviso medico' end
  end

  -- A crash gets the police even with no medical unit in the world at all, which is the
  -- normal case now that ambulances are not spawned.
  if not id then
    if not wreckId then return false end
    M.incident = {kind = kind, pos = vec3(pos), vehId = vehId, attending = {},
                  timer = 200, extinguished = false}
    if not dispatchPatrol(M.incident.pos) then
      M.incident = nil
      return false
    end
    return true
  end

  M.incident = {kind = kind, pos = vec3(pos), vehId = vehId, attending = {},
                timer = 240, extinguished = false}

  if kind == 'incendio' and vehId then
    send(vehId, 'fire.igniteVehicle()')
  end

  if not dispatch(id, u, M.incident.pos, wreckId ~= nil) then
    M.incident = nil
    return false
  end
  M.incident.attending[id] = true
  -- A wreck on the road gets a patrol as well; a routine call-out does not.
  if wreckId then dispatchPatrol(M.incident.pos) end
  return true
end

-- ---------------------------------------------------------------- update

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK

  local data = traffic()
  if not data then return end

  local anyBusy = false
  for id, u in pairs(M.units) do
    if u.phase ~= M.IDLE then
      anyBusy = true
      u.timer = u.timer - TICK
      local veh = data[id]
      if not veh or veh.state ~= 'active' then
        standDown(id, u)
      elseif u.phase == M.ENROUTE then
        if u.dest and veh.pos and veh.pos:squaredDistance(u.dest) < ARRIVE_SQ then
          onScene(id, u)
        elseif u.timer <= 0 then
          standDown(id, u) -- could not get there; nobody circles forever
        end
      elseif u.timer <= 0 then
        standDown(id, u)
      end
    end
  end

  for pid, r in pairs(M.reserved) do
    r.timer = r.timer - TICK
    local v = data[pid]
    if not v or v.state ~= 'active' then
      M.reserved[pid] = nil
    elseif not r.onScene and v.pos and v.pos:squaredDistance(r.dest) < ARRIVE_SQ then
      r.onScene, r.timer = true, 30 + random() * 35
      send(pid, units.KERB_STOP)
      send(pid, 'electrics.set_warn_signal(1)')
      send(pid, 'electrics.set_lightbar_signal(1)')
      local pv = data[pid]
      if pv and units.ai(pv) then pv:setAiMode('traffic') end
    elseif r.timer <= 0 then
      releasePatrol(pid)
    end
  end

  if M.incident then
    M.incident.timer = M.incident.timer - TICK
    local patrolBusy = next(M.reserved) ~= nil
    if M.incident.timer <= 0 or not (anyBusy or patrolBusy) then
      for pid in pairs(M.reserved) do releasePatrol(pid) end
      M.incident = nil
      nextCall = GAP_MIN + random() * (GAP_MAX - GAP_MIN)
    end
    return
  end

  nextCall = nextCall - TICK
  if nextCall > 0 then return end
  if not startIncident(data) then nextCall = 25 end
end

function M.label(id)
  local u = M.units[id]
  if not u then return nil end
  if u.phase == M.IDLE then return u.label end
  if u.phase == M.ENROUTE then
    return format('%s EN CAMINO (%s)', u.label,
      M.incident and M.incident.kind or 'aviso')
  end
  return format('%s: %s', u.label, u.work or 'en el lugar')
end

function M.reset()
  for id, u in pairs(M.units) do
    if u.phase ~= M.IDLE then standDown(id, u) end
  end
  for pid in pairs(M.reserved) do releasePatrol(pid) end
  table.clear(M.units)
  table.clear(M.reserved)
  nodeSampleCount = 0
  M.incident, M.callCount, nextCall = nil, 0, 90
end

return M
