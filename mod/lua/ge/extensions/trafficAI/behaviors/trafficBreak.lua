local M = {}
local units = require('trafficAI/util/units')

local random = math.random
local format = string.format

-- Real pursuit tactic. A unit gets onto the opposing carriageway ahead of the chase, lights
-- on, and slows the oncoming flow so nothing drives into the pursuit head-on. Police call it
-- a traffic break; it is the standard way of protecting the road ahead of a running suspect.
local TICK = 0.5
local AHEAD_MIN, AHEAD_MAX = 200, 340
local MIN_LEVEL = 2             -- stars before anyone is spared for it
local LIFE = 60
local COOLDOWN = 40
local ARRIVE_SQ = 45 * 45
local HOLD_SPEED = 7            -- m/s the blocker settles at, dragging oncoming traffic down

M.enabled = true
M.state = 'idle'
M.unitId = nil
M.pos = nil

local timer, life, cooldown = 0, 0, 0
local probe = vec3()

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

-- A point well ahead of the suspect, on the road, where the opposing flow can be held.
local function breakPoint(suspect)
  probe:setAddScaled(suspect.pos, suspect.dirVec,
    AHEAD_MIN + random() * (AHEAD_MAX - AHEAD_MIN))
  if not map.findClosestRoad then return nil end
  local n1 = map.findClosestRoad(probe)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return nil end
  return n1, nodes[n1].pos
end

local function freeUnit(data, police, suspect)
  local policeStop = require('trafficAI/behaviors/policeStop')
  local emergency = require('trafficAI/environment/emergency')
  local spikes = require('trafficAI/behaviors/spikes')
  local policeTactics = require('trafficAI/behaviors/policeTactics')
  local best, bestDist = nil, -1
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and v.pos
      and not policeStop.stops[pid] and not emergency.reserved[pid]
      and spikes.crewId ~= pid and not policeTactics.blockers[pid] then
      -- The furthest back is the one that can be spared; the close ones are on the suspect.
      local d = v.pos:distance(suspect.pos)
      if d > bestDist then best, bestDist = pid, d end
    end
  end
  -- Never take the only unit off the chase.
  local count = 0
  for _ in pairs(police) do count = count + 1 end
  if count < 2 then return nil end
  return best
end

local function release()
  if M.unitId then
    send(M.unitId, 'ai.setPullOver(false)')
    send(M.unitId, 'electrics.set_warn_signal(0)')
    send(M.unitId, 'electrics.set_lightbar_signal(0)')
    send(M.unitId, 'ai.setSpeedMode("legal")')
    local data = traffic()
    local v = data and data[M.unitId]
    if v then
      v.vars.aiMode = 'traffic'
      if units.ai(v) then v:setAiMode('traffic') end
    end
  end
  M.unitId, M.pos, M.state = nil, nil, 'idle'
  cooldown = COOLDOWN
end

local function start(data, police, suspect)
  local node, pos = breakPoint(suspect)
  if not node then return false end
  local pid = freeUnit(data, police, suspect)
  if not pid then return false end

  local v = data[pid]
  M.unitId, M.pos, M.state, life = pid, vec3(pos), 'moving', LIFE
  -- Traffic mode all the way: this unit must not itself become the hazard. The vars entry
  -- is parked so the stock role stops dragging it back into the chase.
  v.vars.aiMode = 'break'
  if units.ai(v) then v:setAiMode('traffic') end
  send(pid, 'ai.setAvoidCars("on")')
  send(pid, 'ai.driveInLane("on")')
  send(pid, 'ai.setSpeedMode("limit")')
  send(pid, format('ai.setSpeed(%.2f)', 22))
  send(pid, 'ai.setAggressionMode("off")')
  send(pid, 'ai.setAggression(0.5)')
  send(pid, 'electrics.set_lightbar_signal(2)')
  v:useSiren(1.5 + random())
  ui_message('trafficAI.wanted.trafficBreak', 5, 'trafficAI')
  return true
end

-- On station: sit in the opposing lane at walking pace with everything lit. Cars behind it
-- pile up behind rather than meeting the pursuit head-on.
local function onStation(pid)
  local data = traffic()
  local v = data and data[pid]
  if not v then return end
  send(pid, 'ai.setSpeedMode("limit")')
  send(pid, format('ai.setSpeed(%.2f)', HOLD_SPEED))
  send(pid, 'electrics.set_warn_signal(1)')
  send(pid, 'electrics.set_lightbar_signal(2)')
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK
  if cooldown > 0 then cooldown = cooldown - TICK end

  local data = traffic()
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not data or not police then return end

  local suspectId, suspect
  for id, v in pairs(data) do
    if v.pursuit and (v.pursuit.mode or 0) > 0 then suspectId, suspect = id, v break end
  end

  if M.state ~= 'idle' then
    life = life - TICK
    local v = data[M.unitId]
    if not suspectId or not v or v.state ~= 'active' or life <= 0 then
      release()
      return
    end
    if M.state == 'moving' and v.pos and M.pos and v.pos:squaredDistance(M.pos) < ARRIVE_SQ then
      M.state = 'holding'
      onStation(M.unitId)
    end
    return
  end

  if cooldown > 0 then return end

  -- Two reasons to hold the oncoming lane: a pursuit running down the road, or a wreck
  -- being worked on. Both are cases where oncoming traffic drives into the problem.
  if suspectId and suspect.pos and suspect.dirVec then
    local wanted = require('trafficAI/behaviors/wanted')
    if (wanted.stars or 0) >= MIN_LEVEL then
      if not start(data, police, suspect) then cooldown = 12 end
      return
    end
  end

  local emergency = require('trafficAI/environment/emergency')
  local inc = emergency.incident
  if inc and inc.pos and inc.vehId then
    local wreck = data[inc.vehId]
    if wreck and wreck.pos and wreck.dirVec then
      if not start(data, police, wreck) then cooldown = 15 end
    end
  end
end

function M.label(id)
  if M.unitId ~= id then return nil end
  return M.state == 'holding' and 'CORTA EL SENTIDO CONTRARIO' or 'va a cortar el contrario'
end

function M.reset()
  if M.unitId then release() end
  timer, life, cooldown = 0, 0, 0
  M.state, M.unitId, M.pos = 'idle', nil, nil
end

return M
