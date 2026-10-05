local M = {}
local units = require('trafficAI/util/units')

local random = math.random
local format = string.format

-- BeamNG ships a real spikestrip vehicle whose controller can arm itself against one target
-- (vehicles/spikestrip/lua/controller/spikestripRemoteStick.lua). One strip is spawned lazily
-- and parked out of the world between uses.
local MODEL = 'spikestrip'
local CONFIG = 'flexr'
-- The crew has to be ahead of the runner already. A unit behind them cannot overtake and lay
-- a strip in time, which is why strips used to turn up with nobody near them.
local CREW_MIN, CREW_MAX = 140, 480
local CREW_SIDE = 60
local STAGE_TIME = 12    -- seconds the crew has to pull over before the attempt is dropped
local TOO_CLOSE = 60     -- runner this near an unready crew: too late to lay anything
local PASSED_BY = 12   -- metres past the strip before it is stowed
local SIDE_CLEAR = 7   -- lateral metres that count as having gone around it
local ARM_LEVEL = 2
local COOLDOWN = 70
local LIFETIME = 55
local PARK = vec3(0, 0, -600)

M.enabled = true
M.stripId = nil
M.state = 'idle'
M.targetId = 0
M.crewId = nil

local TICK = 0.5
local timer, cooldown, life = 0, 0, 0
local aheadPos = vec3()
local toStrip = vec3()

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function ensureStrip()
  if M.stripId and getObjectByID(M.stripId) then return true end
  if not core_vehicles or not core_vehicles.spawnNewVehicle then return false end

  -- spawnNewVehicle returns the vehicle OBJECT, not an id (core/vehicles.lua:1846).
  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(MODEL, {
      config = CONFIG, pos = vec3(PARK), rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false, cling = false, canSpawnAnotherVehicleCheck = false
    })
  end)
  if not ok or not veh or not veh.getID then
    log('W', 'trafficAI', 'spikestrip no disponible; modulo desactivado')
    M.enabled = false
    return false
  end
  local id = veh:getID()
  if type(id) ~= 'number' then M.enabled = false return false end
  M.stripId = id
  if gameplay_police and gameplay_police.insertProp then
    pcall(gameplay_police.insertProp, id)
  end
  local obj = getObjectByID(id)
  if obj then obj:setActive(0) end
  return true
end

-- A free AI unit already ahead of the runner, roughly on their line.
local function crewAhead(suspect)
  local data = traffic()
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not data or not police then return nil end

  local emergency = require('trafficAI/environment/emergency')
  local policeStop = require('trafficAI/behaviors/policeStop')
  local best, bestFwd = nil, 1e9
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and v.pos and v.vars.aiMode == 'traffic'
      and not emergency.reserved[pid] and not policeStop.stops[pid] then
      toStrip:setSub2(v.pos, suspect.pos)
      local fwd = toStrip:dot(suspect.dirVec)
      local latSq = toStrip:squaredLength() - fwd * fwd
      if fwd > CREW_MIN and fwd < CREW_MAX and latSq < CREW_SIDE * CREW_SIDE and fwd < bestFwd then
        best, bestFwd = pid, fwd
      end
    end
  end
  return best
end

-- The crew stops where it is. vars.aiMode is parked so the stock police role does not put
-- the unit straight back into the chase (roles/police.lua:274).
local function stageCrew(pid)
  local data = traffic()
  local v = data and data[pid]
  if not v then return false end
  v.vars.aiMode = 'spikes'
  if units.ai(v) then v:setAiMode('traffic') end
  send(pid, units.KERB_STOP)
  send(pid, 'electrics.set_warn_signal(1)')
  send(pid, 'electrics.set_lightbar_signal(2)')
  return true
end

-- Where the strip goes: on the road beside the crew, a few metres toward the runner so it is
-- not lying under the patrol car.
local function stripPlace(crewPos, suspect)
  if not map.findClosestRoad then return nil end
  local n1, n2 = map.findClosestRoad(crewPos)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not n2 or not nodes or not nodes[n1] or not nodes[n2] then return nil end
  local a, b = nodes[n1].pos, nodes[n2].pos
  local dir = vec3()
  dir:setSub2(b, a)
  dir.z = 0
  local len = dir:length()
  if len < 0.5 then return nil end
  dir:setScaled(1 / len)

  toStrip:setSub2(crewPos, a)
  local along = toStrip:dot(dir)
  if along < 0 then along = 0 elseif along > len then along = len end
  local pos = vec3()
  pos:setAddScaled(a, dir, along)

  -- Toward the runner, and facing them.
  toStrip:setSub2(suspect.pos, pos)
  if toStrip:dot(dir) < 0 then dir:setScaled(-1) end
  pos:setAddScaled(pos, dir, 9)
  pos.z = pos.z + 0.2
  return pos, dir
end

local function crewOnScene(pid)
  local data = traffic()
  local v = data and data[pid]
  if not v then return end
  send(pid, 'local c = controller.getControllerSafe("door_FL_coupler") ' ..
    'if c and c.toggleGroup then c.toggleGroup() end')
end

local function releaseCrew(pid)
  local data = traffic()
  local v = data and data[pid]
  send(pid, 'ai.setPullOver(false)')
  send(pid, 'electrics.set_warn_signal(0)')
  if v then v.vars.aiMode = 'traffic' end
end

-- Strip retracted, door shut, and that unit goes after whoever just went past.
local function crewChase(pid, suspectId)
  local data = traffic()
  local v = data and data[pid]
  if not v then return end
  send(pid, 'local c = controller.getControllerSafe("door_FL_coupler") ' ..
    'if c and c.toggleGroup then c.toggleGroup() end')
  releaseCrew(pid)
  if gameplay_police and gameplay_police.setPursuitMode and suspectId ~= 0 then
    local mode = 2
    local target = data[suspectId]
    if target and target.pursuit then mode = math.max(2, target.pursuit.mode or 2) end
    pcall(gameplay_police.setPursuitMode, mode, suspectId, {pid})
  end
end

local function stow()
  if M.crewId then
    if M.state == 'armed' then crewChase(M.crewId, M.targetId) else releaseCrew(M.crewId) end
    M.crewId = nil
  end
  if M.stripId then
    local obj = getObjectByID(M.stripId)
    if obj then
      send(M.stripId, 'local c = controller.getControllerSafe("spikestripRemoteStick") ' ..
        'if c and c.setManualExtension then c.setManualExtension(false) end')
      obj:setPosition(PARK)
      obj:setActive(0)
    else
      M.stripId = nil
    end
  end
  M.state, M.targetId = 'idle', 0
  cooldown = COOLDOWN
end

-- Step one: a unit ahead of the runner pulls over. Nothing is on the road yet.
local function stage(suspectId, suspect)
  if not ensureStrip() then return false end
  local crew = crewAhead(suspect)
  if not crew or not stageCrew(crew) then return false end
  M.state, M.targetId, M.crewId, life = 'staging', suspectId, crew, STAGE_TIME
  M.approached, M.scenePos = false, nil
  return true
end

-- Step two: the crew has stopped, so the strip goes down next to it.
local function lay(crewPos, suspect)
  local obj = M.stripId and getObjectByID(M.stripId)
  if not obj then M.stripId = nil return false end
  local pos, dir = stripPlace(crewPos, suspect)
  if not pos then return false end

  obj:setActive(1)
  local rot = quatFromDir(dir, vec3(0, 0, 1))
  vehicleSetPositionRotation(M.stripId, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  send(M.stripId, format(
    'local c = controller.getControllerSafe("spikestripRemoteStick") ' ..
    'or controller.getControllerSafe("spikestripRemoteScissor") ' ..
    'if c and c.setOperationMode then c.setOperationMode("auto") c.setManualTargetId(%d) end',
    M.targetId))

  M.state, life = 'armed', LIFETIME
  M.scenePos = vec3(pos)
  crewOnScene(M.crewId)
  if M.targetId == be:getPlayerVehicleID(0) then
    ui_message('trafficAI.spikes.ahead', 3, 'trafficAI')
  end
  return true
end

-- Built once when police traffic is set up, so laying it during a chase costs nothing.
function M.preload()
  if not M.enabled or M.stripId then return end
  ensureStrip()
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK
  if cooldown > 0 then cooldown = cooldown - TICK end

  local data = traffic()
  if not data then return end

  if M.state == 'staging' then
    life = life - TICK
    local target = data[M.targetId]
    local crew = data[M.crewId]
    local gone = not target or not target.pos or not target.pursuit or (target.pursuit.mode or 0) <= 0
    if gone or not crew or not crew.pos or crew.state ~= 'active' or life <= 0 then
      stow()
      return
    end
    local gap = crew.pos:distance(target.pos)
    if (crew.speed or 0) < 1.5 and gap > TOO_CLOSE then
      if not lay(crew.pos, target) then stow() end
    elseif gap <= TOO_CLOSE then
      -- They got here before the crew was ready. No strip; the unit rejoins the chase.
      stow()
    end
    return
  end

  if M.state == 'armed' then
    life = life - TICK
    local target = data[M.targetId]
    local gone = not target or not target.pursuit or (target.pursuit.mode or 0) <= 0

    -- Stowed as soon as it is behind them, whether they hit it or went round it. Both tests
    -- only count once they have actually reached it, so a bend in the road cannot look like
    -- a dodge from half a kilometre away.
    if target and target.pos and M.scenePos and target.dirVec then
      toStrip:setSub2(M.scenePos, target.pos)
      local d2 = toStrip:squaredLength()
      if d2 < 1600 then M.approached = true end
      if M.approached then
        local fwd = toStrip:dot(target.dirVec)
        if fwd < -PASSED_BY then stow() return end
        if fwd < PASSED_BY then
          local lat = d2 - fwd * fwd
          if lat > SIDE_CLEAR * SIDE_CLEAR then stow() return end
        end
      end
    end
    if gone or life <= 0 then stow() end
    return
  end

  if cooldown > 0 then return end

  for id, v in pairs(data) do
    if v.pursuit and (v.pursuit.mode or 0) >= ARM_LEVEL and v.pos and v.dirVec
      and (v.speed or 0) > 14 then
      if stage(id, v) then return end
      -- Nobody ahead right now. Look again soon: a unit ahead is a short window.
      cooldown = 5
      return
    end
  end
end

function M.reset()
  if M.crewId then releaseCrew(M.crewId) end
  if M.stripId then
    local obj = getObjectByID(M.stripId)
    if obj then obj:delete() end
  end
  M.stripId, M.state, M.targetId, M.crewId = nil, 'idle', 0, nil
  M.approached, M.scenePos = false, nil
  cooldown, life = 0, 0
end

return M
