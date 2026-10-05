local M = {}
local units = require('trafficAI/util/units')

local random = math.random
local format = string.format

-- The engine already works out whether a unit can actually see the suspect
-- (police.lua:639 keeps pursuit.sightValue and pursuit.policeVisible), but it only uses it
-- to size the arrest and evade radii. The units themselves are handed the live position via
-- ai.setTargetObjectID, so they always know exactly where you are. This gives them a last
-- known position instead, and makes them search from it.
local TICK = 0.5
local LOST_AFTER = 2.5          -- seconds without sight before a unit stops being told where you are
local SEARCH_TIME = 45          -- how long a unit keeps looking before giving up
local ARRIVE_SQ = 30 * 30
local HOP = 90                  -- metres between search waypoints

M.enabled = true
M.state = 'idle'                -- idle | contact | searching
M.lkp = nil                     -- last known position
M.lkpDir = nil
M.lkpAge = 0
M.units = {}

local timer = 0
local noSight = 0
local probe = vec3()

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

-- Each officer guesses differently. A sharp one follows the direction you were heading;
-- a poor one fans out more or less at random.
local function officer(id)
  local u = M.units[id]
  if u then return u end
  u = {instinct = 0.25 + random() * 0.7, spread = random() * 2 - 1,
       phase = 'chase', timer = 0, dest = nil}
  M.units[id] = u
  return u
end

-- A road node roughly `HOP` metres from the last known position, biased along the suspect's
-- last heading by however good this officer's instinct is.
local function searchPoint(u)
  if not M.lkp then return nil end
  probe:set(M.lkp)
  if M.lkpDir then
    probe:setAddScaled(probe, M.lkpDir, HOP * u.instinct)
  end
  local a = random() * 6.283
  probe.x = probe.x + math.cos(a) * HOP * (1 - u.instinct) * (0.4 + random() * 0.8)
  probe.y = probe.y + math.sin(a) * HOP * (1 - u.instinct) * (0.4 + random() * 0.8)

  local n1 = map.findClosestRoad and map.findClosestRoad(probe)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return nil end
  return n1, nodes[n1].pos
end

-- Search mode has to stop the stock police role re-issuing chaseTarget every tick. That
-- re-assertion is gated on veh.vars.aiMode == 'traffic' (roles/police.lua:274), so parking
-- the variable is enough and it is put straight back afterwards.
local function toSearch(id, u, veh)
  u.phase, u.timer, u.dest = 'search', SEARCH_TIME, nil
  -- Traffic mode is the only mode that keeps a car on its own side of the road and out of
  -- everyone else's way. 'manual' plans over the raw graph and was sending searching units
  -- back down the carriageway the player was on, head-on into the public.
  -- vars.aiMode is only the default the role reads; the mode the car actually drives in is
  -- set separately. Parking the variable stops roles/police.lua:274 re-issuing chaseTarget
  -- every tick, while the car itself still drives in traffic mode and keeps to its lane.
  veh.vars.aiMode = 'search'
  if units.ai(veh) then veh:setAiMode('traffic') end
  send(id, 'ai.setAvoidCars("on")')
  send(id, 'ai.driveInLane("on")')
  send(id, 'ai.setSpeedMode("limit")')
  send(id, format('ai.setSpeed(%.2f)', 13 + u.instinct * 7))
  send(id, 'ai.setAggressionMode("off")')
  send(id, 'ai.setAggression(0.42)')
  send(id, 'electrics.set_lightbar_signal(1)')
  return true
end

local function toChase(id, u, veh)
  u.phase, u.timer, u.dest = 'chase', 0, nil
  veh.vars.aiMode = 'traffic'
  if units.ai(veh) then veh:setAiMode('traffic') end
  if veh.role and veh.role.setAction then
    pcall(function() veh.role:setAction('chaseTarget') end)
  end
end

local function standDown(id, u, veh)
  u.phase, u.timer, u.dest = 'idle', 0, nil
  veh.vars.aiMode = 'traffic'
  if units.ai(veh) then veh:setAiMode('traffic') end
  send(id, 'electrics.set_lightbar_signal(0)')
  send(id, 'ai.setSpeedMode("legal")')
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  local step = TICK
  timer = TICK

  local data = traffic()
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not data or not police then return end

  -- Who is being chased.
  local suspectId, suspect
  for id, v in pairs(data) do
    if v.pursuit and (v.pursuit.mode or 0) > 0 then suspectId, suspect = id, v break end
  end

  if not suspectId then
    if M.state ~= 'idle' then
      for id, u in pairs(M.units) do
        local veh = data[id]
        if veh and u.phase ~= 'idle' then standDown(id, u, veh) end
      end
      table.clear(M.units)
      M.state, M.lkp, M.lkpDir, noSight = 'idle', nil, nil, 0
    end
    return
  end

  local p = suspect.pursuit
  local visible = p.policeVisible

  if visible then
    noSight = 0
    M.state = 'contact'
    M.lkp = M.lkp or vec3()
    M.lkp:set(suspect.pos)
    M.lkpDir = M.lkpDir or vec3()
    if suspect.dirVec then M.lkpDir:set(suspect.dirVec) end
    M.lkpAge = 0
  else
    noSight = noSight + step
    M.lkpAge = M.lkpAge + step
    if noSight >= LOST_AFTER then M.state = 'searching' end
  end

  for pid in pairs(police) do
    local veh = data[pid]
    if veh and units.ai(veh) and veh.state == 'active' then
      local u = officer(pid)

      if M.state == 'searching' then
        if u.phase ~= 'search' then
          toSearch(pid, u, veh)
        else
          u.timer = u.timer - step
          if u.timer <= 0 then standDown(pid, u, veh) end
        end

      elseif u.phase ~= 'chase' then
        -- Sight regained: straight back onto them.
        toChase(pid, u, veh)
      end
    end
  end
end

function M.label(id)
  local u = M.units[id]
  if not u then return nil end
  if u.phase == 'search' then
    return format('BUSCA (olfato %.0f%%)', u.instinct * 100)
  end
  return nil
end

function M.reset()
  local data = traffic()
  if data then
    for id, u in pairs(M.units) do
      local veh = data[id]
      if veh and u.phase ~= 'idle' then standDown(id, u, veh) end
    end
  end
  table.clear(M.units)
  M.state, M.lkp, M.lkpDir, M.lkpAge = 'idle', nil, nil, 0
  timer, noSight = 0, 0
end

return M
