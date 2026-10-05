local M = {}
local units = require('trafficAI/util/units')

local random = math.random
local floor = math.floor

-- The native pursuit already keeps a score (traffic/vehicle.lua:151). Stars are read off it
-- rather than invented, so offences the game scores are the offences that raise your level.
-- Half steps, so the level climbs visibly instead of jumping.
-- The native score climbs fast: a lump per offence plus a continuous trickle while running
-- (police.lua:647), and the speeding offence re-scores every tick. Read straight off it the
-- level went from one patrol to the whole country in seconds, so the bar is much higher now
-- and the climb is rate limited on top.
local THRESHOLDS = {120, 450, 1000, 2000, 3600, 6200, 9800, 14500, 20500, 28000}

-- Dispatch takes time. However fast the score runs away, the response only escalates one
-- half step at a time, and the higher the level the longer the next step takes.
local CLIMB_BASE = 11
local CLIMB_PER_STAR = 5
local DROP_DELAY = 14

-- All verified present in 0.39.4. There are no military vehicles in vanilla, so the top of
-- the ladder is unmarked cars and the fast pursuit models. The armoured ramplow is
-- deliberately absent: it is a snowplough with a spike on the front.
local SWAT = {model = 'md_series', config = 'md_60_armored_police'}
local UNMARKED = {
  {model = 'fullsize', config = 'unmarked'},
  {model = 'midsize', config = 'unmarked'},
  {model = 'bastion', config = 'police_unmarked_v8_awd_A'},
  {model = 'legran', config = 'detective'}
}
local FAST = {
  {model = 'scintilla', config = 'gts_polizia'},
  {model = 'vivace', config = 'ardente_gendarmerie'},
  {model = 'sunburst2', config = 'interceptor'}
}

M.enabled = true
M.stars = 0
M.score = 0
M.targetId = 0
M.swatId = nil
M.extraId = nil
M.fastId = nil
M.earned = 0
M.roadblocks = 0

local TICK = 0.5
local ROADBLOCK_GAP = 45
local timer, blockTimer, sent = 0, 0, -1
local climbTimer, dropTimer = 0, 0

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function levelFor(score)
  local n = 0
  for i = 1, #THRESHOLDS do
    if score >= THRESHOLDS[i] then n = i end
  end
  return n * 0.5
end

local function push()
  if M.stars == sent then return end
  local rising = M.stars > (sent < 0 and 0 or sent)
  sent = M.stars
  if guihooks then
    guihooks.trigger('TrafficAIWanted',
      {stars = M.stars, score = floor(M.score), rising = rising})
  end
end

-- Higher levels make the stock pursuit itself harder: it commits sooner and gives up later.
local function applyVars()
  if not gameplay_police or not gameplay_police.setPursuitVars then return end
  local s = M.stars
  gameplay_police.setPursuitVars({
    evadeTime = 40 + s * 22,
    evadeRadius = 70 + s * 45,
    arrestRadius = 20 + s * 4,
    roadblockFrequency = 0,
    strictness = 0.45 + s * 0.07
  })

  -- Below two stars the response is ordinary patrols driving briskly, not every unit at
  -- full aggression from the first second.
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  local police = gameplay_police.getPoliceVehicles and gameplay_police.getPoliceVehicles()
  if not data or not police then return end
  local agg = 0.4 + s * 0.06
  if agg > 0.7 then agg = 0.7 end
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and pid ~= M.swatId and pid ~= M.extraId then
      send(pid, string.format('ai.setAggression(%.2f)', agg))
    end
  end
end

local function despawnUnit(field)
  local id = M[field]
  if not id then return end
  local obj = getObjectByID(id)
  if obj then obj:delete() end
  M[field] = nil
end

local function despawnSwat()
  despawnUnit('swatId')
  despawnUnit('extraId')
  despawnUnit('fastId')
end

local function joinAsPolice(id, mode)
  if gameplay_traffic and gameplay_traffic.insertTraffic then
    pcall(gameplay_traffic.insertTraffic, id, false)
  end
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  local v = data and data[id]
  if v and v.setRole then
    v.autoRole = 'police'
    v:setRole('police')
  end
  send(id, 'electrics.set_lightbar_signal(2)')
  if gameplay_police.setPursuitMode and M.targetId ~= 0 then
    pcall(gameplay_police.setPursuitMode, mode, M.targetId, {id})
  end
end

-- An unmarked car that does not announce itself, brought in once things are serious.
local function spawnUnmarked(target)
  if M.extraId or not core_vehicles or not core_vehicles.spawnNewVehicle then return end
  if not target.pos or not target.dirVec then return end
  local pos = vec3(target.pos)
  pos:setAddScaled(pos, target.dirVec, -180)
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return end

  local pool = M.stars >= 4.5 and FAST or UNMARKED
  local pick = pool[random(#pool)]
  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(pick.model, {
      config = pick.config, pos = vec3(nodes[n1].pos), rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false
    })
  end)
  if not ok or not veh or not veh.getID then return end
  local id = veh:getID()
  if type(id) ~= 'number' then return end
  M.extraId = id
  joinAsPolice(id, 3)
  if pool == UNMARKED then send(id, 'electrics.set_lightbar_signal(0)') end
  ui_message('trafficAI.wanted.unmarked', 5, 'trafficAI')
end

-- Two stars is where the ordinary patrol stops being able to keep up, so a genuinely fast
-- car turns out. Always well behind, never in front: units appearing in your face is jarring.
local function spawnFast(target)
  if M.fastId or not core_vehicles or not core_vehicles.spawnNewVehicle then return end
  if not target.pos or not target.dirVec then return end
  local pos = vec3(target.pos)
  pos:setAddScaled(pos, target.dirVec, -260)
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return end

  local pick = FAST[random(#FAST)]
  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(pick.model, {
      config = pick.config, pos = vec3(nodes[n1].pos), rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false
    })
  end)
  if not ok or not veh or not veh.getID then return end
  local id = veh:getID()
  if type(id) ~= 'number' then return end
  M.fastId = id
  joinAsPolice(id, 2)
  ui_message('trafficAI.wanted.fast', 5, 'trafficAI')
end

local function spawnSwat(target)
  if M.swatId or not core_vehicles or not core_vehicles.spawnNewVehicle then return end
  if not target.pos or not target.dirVec then return end

  local pos = vec3(target.pos)
  pos:setAddScaled(pos, target.dirVec, -220)
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  local nodes = map.getMap and map.getMap()
  nodes = nodes and nodes.nodes
  if not n1 or not nodes or not nodes[n1] then return end

  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(SWAT.model, {
      config = SWAT.config, pos = vec3(nodes[n1].pos), rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false
    })
  end)
  if not ok or not veh or not veh.getID then return end
  local id = veh:getID()
  if type(id) ~= 'number' then return end
  M.swatId = id
  joinAsPolice(id, 3)
  ui_message('trafficAI.wanted.swat', 5, 'trafficAI')
end

-- Two free patrols across the road some way ahead of the runner.
-- Can the player see this point right now? One static ray from the camera; anything beyond
-- 700 m counts as out of sight.
local eye, toPoint = vec3(), vec3()

local function inSight(pos)
  if not core_camera or not castRayStatic then return true end
  eye:set(core_camera.getPosition())
  toPoint:setSub2(pos, eye)
  toPoint.z = toPoint.z + 1
  local len = toPoint:length()
  if len > 700 then return false end
  if len < 1 then return true end
  toPoint:setScaled(1 / len)
  return castRayStatic(eye, toPoint, len) >= len - 3
end
M.inSight = inSight

-- A roadblock is two units teleported across the road ahead. Done in plain view it is a
-- patrol car materialising in front of the bonnet, so both the units and the spot have to
-- be somewhere the player cannot see, and the spot has to be on the road they are actually
-- following rather than a straight line through the scenery.
local function tryRoadblock(target)
  if not gameplay_police or not gameplay_police.placeRoadblock then return false end
  if not target.pos or not target.dirVec then return false end
  local utils = gameplay_traffic_trafficUtils
  if not utils or not utils.findSpawnPointOnRoute then return false end

  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  local police = gameplay_police.getPoliceVehicles and gameplay_police.getPoliceVehicles()
  if not data or not police then return false end

  local ids = {}
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and v.pos and v.vars.aiMode == 'traffic'
      and pid ~= M.swatId and pid ~= M.extraId and pid ~= M.fastId then
      toPoint:setSub2(v.pos, target.pos)
      local dist = toPoint:length()
      local behind = toPoint:dot(target.dirVec) < 0
      if dist > 120 and (behind or not inSight(v.pos)) then ids[#ids + 1] = pid end
    end
    if #ids >= 2 then break end
  end
  if #ids < 2 then return false end

  local spot = utils.findSpawnPointOnRoute(target.pos, target.dirVec, 300, 650, 450,
    {pathRandomization = 0})
  if not spot or not spot.n1 or not spot.pos then return false end
  if inSight(spot.pos) and spot.pos:distance(target.pos) < 500 then return false end

  local nodes = map.getMap and map.getMap()
  nodes = nodes and nodes.nodes
  local r1 = nodes and nodes[spot.n1] and nodes[spot.n1].radius or 4.5
  local r2 = nodes and spot.n2 and nodes[spot.n2] and nodes[spot.n2].radius or r1
  local width = math.min(r1, r2) * 2 + 1

  local ok = pcall(gameplay_police.placeRoadblock, ids, vec3(spot.pos),
    quatFromDir(spot.dir, spot.normal or vec3(0, 0, 1)), {width = width, angle = 25, centerAngle = 0})
  if not ok then return false end

  -- Same bookkeeping the stock system does, so the units hold the line instead of driving
  -- straight off again, and leave it properly once the suspect is through.
  if target.pursuit and target.pursuit.roadblockPos then target.pursuit.roadblockPos:set(spot.pos) end
  for _, pid in ipairs(ids) do
    local v = data[pid]
    if v.modifyRespawnValues then v:modifyRespawnValues(500) end
    if v.role and v.role.setAction then pcall(function() v.role:setAction('roadblock') end) end
    send(pid, 'electrics.set_lightbar_signal(2)')
  end
  M.roadblocks = M.roadblocks + 1
  ui_message('trafficAI.wanted.roadblock', 5, 'trafficAI')
  return true
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK

  local playerId = be:getPlayerVehicleID(0)
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  local me = data and data[playerId]
  local p = me and me.pursuit

  if not p or (p.mode or 0) <= 0 then
    if M.stars ~= 0 then
      M.stars, M.score, M.targetId, M.roadblocks = 0, 0, 0, 0
      despawnSwat()
      applyVars()
      push()
    end
    return
  end

  M.targetId = playerId
  M.score = p.score or 0
  local earned = levelFor(M.score)
  M.earned = earned

  if climbTimer > 0 then climbTimer = climbTimer - TICK end
  if dropTimer > 0 then dropTimer = dropTimer - TICK end

  local newStars = M.stars
  if earned > M.stars then
    if climbTimer <= 0 then
      newStars = M.stars + 0.5
      climbTimer = CLIMB_BASE + newStars * CLIMB_PER_STAR
      dropTimer = DROP_DELAY
    end
  elseif earned < M.stars and dropTimer <= 0 then
    -- Stopped earning it: the response winds down instead of staying maxed out for ever.
    newStars = M.stars - 0.5
    dropTimer = DROP_DELAY
  end

  if newStars ~= M.stars then
    M.stars = newStars
    applyVars()
    push()
  end

  -- Tiers by what turns up, not just by how hard they drive: ordinary patrols to start,
  -- then genuinely fast cars, then the armoured unit.
  if M.stars >= 2 then spawnFast(me) end
  if M.stars >= 2.5 then
    blockTimer = blockTimer - TICK
    if blockTimer <= 0 then
      blockTimer = tryRoadblock(me) and ROADBLOCK_GAP or 8
    end
  end
  if M.stars >= 3 then spawnSwat(me) end
  if M.stars >= 3.5 then spawnUnmarked(me) end
end

function M.reset()
  despawnSwat()
  M.stars, M.score, M.targetId, M.roadblocks = 0, 0, 0, 0
  timer, blockTimer, sent = 0, 0, -1
  climbTimer, dropTimer = 0, 0
  push()
end

return M
