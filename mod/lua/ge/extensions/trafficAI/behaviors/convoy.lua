local M = {}
local units = require('trafficAI/util/units')

local random = math.random

-- md_series ships a real cash-in-transit body and lansdale a security car, so the convoy is
-- made of vehicles that already exist rather than a reskin.
local TRUCK = {model = 'md_series', config = 'md_70_armored_bank'}
local ESCORT = {model = 'lansdale', config = '22_security_late_A'}

M.enabled = true
M.active = false
M.truckId = nil
M.escortId = nil
M.phase = 'none'

local TICK = 1.0
local CHANCE = 0.012        -- per roll, and a roll only happens every few minutes
local ROLL_GAP = 240
local LIFE = 300
local ROB_CHANCE = 0.25

local timer, nextRoll, life = 0, 180, 0
local grace = 8

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function spawnAt(entry, pos)
  if not core_vehicles or not core_vehicles.spawnNewVehicle then return nil end
  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(entry.model, {
      config = entry.config, pos = vec3(pos), rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false
    })
  end)
  if not ok or not veh or not veh.getID then return nil end
  local id = veh:getID()
  if type(id) ~= 'number' then return nil end
  if gameplay_traffic and gameplay_traffic.insertTraffic then
    pcall(gameplay_traffic.insertTraffic, id, false)
  end
  return id
end

local function despawn(id)
  if not id then return end
  local obj = getObjectByID(id)
  if obj then obj:delete() end
end

local function finish()
  despawn(M.truckId)
  despawn(M.escortId)
  M.truckId, M.escortId = nil, nil
  M.active, M.phase = false, 'none'
  nextRoll = ROLL_GAP + random() * ROLL_GAP
end

local function start(data)
  local playerId = be:getPlayerVehicleID(0)
  local me = data[playerId]
  if not me or not me.pos or not me.dirVec then return false end

  local pos = vec3(me.pos)
  pos:setAddScaled(pos, me.dirVec, 320 + random() * 200)
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return false end
  local spot = nodes[n1].pos

  local truck = spawnAt(TRUCK, spot)
  if not truck then return false end
  local behind = vec3(spot)
  behind:setAddScaled(behind, me.dirVec, -14)
  local escort = spawnAt(ESCORT, behind)

  M.truckId, M.escortId = truck, escort
  M.active, M.phase, life, grace = true, 'transit', LIFE, 8

  local t = data[truck]
  if t and t.setRole then
    t.autoRole = 'standard'
    t:setRole('standard')
    if units.ai(t) and t.setAiMode then t:setAiMode('traffic') end
  end
  if escort then
    local e = data[escort]
    if e and units.ai(e) and e.setAiMode then
      e:setAiMode('follow')
      send(escort, 'ai.setTargetObjectID(' .. truck .. ')')
      send(escort, 'ai.setAvoidCars("on")')
    end
  end
  ui_message('trafficAI.convoy.seen', 6, 'trafficAI')
  return true
end

-- Occasionally the convoy is the target rather than scenery: the truck runs and the police
-- system takes it from there.
local function maybeRob(data)
  if M.phase ~= 'transit' or random() > ROB_CHANCE then return end
  M.phase = 'robbed'
  local t = data[M.truckId]
  if t and units.ai(t) then t:setAiMode('flee') end
  if gameplay_police then
    if gameplay_police.setSuspect then pcall(gameplay_police.setSuspect, M.truckId) end
    if gameplay_police.setPursuitMode then
      pcall(gameplay_police.setPursuitMode, 2, M.truckId)
    end
  end
  send(M.truckId, 'electrics.set_warn_signal(1)')
  ui_message('trafficAI.convoy.robbed', 7, 'trafficAI')
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK

  local data = traffic()
  if not data then return end

  if M.active then
    life = life - TICK
    local t = data[M.truckId]
    if not t or t.state ~= 'active' then
      grace = grace - TICK
      if grace <= 0 then finish() end
      return
    end
    grace = 8
    if life < LIFE * 0.6 then maybeRob(data) end
    if life <= 0 then
      if M.phase ~= 'robbed' then finish() end
      if life < -120 then finish() end
    end
    return
  end

  nextRoll = nextRoll - TICK
  if nextRoll > 0 then return end
  nextRoll = 60

  -- Only with police in the world; a cash convoy with nobody to react to it is pointless.
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not police or not next(police) then return end
  if random() > CHANCE then return end
  if not start(data) then nextRoll = 90 end
end

function M.reset()
  finish()
  timer, nextRoll, life = 0, 180, 0
end

return M
