local M = {}
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')

local random = math.random
local format = string.format

-- The game already knows where every parking bay on the level is: gameplay_parking loads them
-- from the level's sites file and each spot can test whether a given vehicle fits and whether
-- anyone is already in it. None of that needs reimplementing; what is missing is a driver who
-- decides to use one.
local TICK = 2
local MAX_PARKED = 2
local SEARCH_MIN, SEARCH_MAX = 45, 170
local DRIVE_TIMEOUT = 50
local SETTLE_TIMEOUT = 14
local STAY_MIN, STAY_MAX = 30, 90
local COOLDOWN = 18
local ARRIVE = 14
local CHANCE = 0.25
local LEAVE_TIMEOUT = 20
local LEAVE_GAP = 26        -- metres of clear road behind before pulling out

M.enabled = true
M.available = nil       -- nil = untested, false = this level has no parking data
M.active = {}
M.count = 0
M.reserved = {}   -- spots claimed by a police stop or an incident, by spot name

local timer, cooldown = 0, 0
local rel = vec3()

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function checkAvailable()
  if M.available ~= nil then return M.available end
  if not gameplay_parking or not gameplay_parking.getParkingSpots then
    M.available = false
    return false
  end
  local ok, spots = pcall(gameplay_parking.getParkingSpots)
  M.available = ok and spots ~= nil and next(spots) ~= nil
  return M.available
end

local function release(id, v)
  local e = M.active[id]
  if e then
    M.active[id] = nil
    M.count = M.count - 1
  end
  if not v then return end
  v.vars.aiMode = 'traffic'
  if units.ai(v) then v:setAiMode('traffic') end
  send(id, 'ai.setSpeedMode("legal")')
  send(id, 'electrics.set_warn_signal(0)')
  send(id, 'electrics.stop_turn_signal()')
  cooldown = COOLDOWN
end

-- Nobody reverses out into moving traffic without looking. Anything closing from behind
-- inside LEAVE_GAP holds the car in the bay.
local function rearClear(id, v, data)
  if not v.pos or not v.dirVec then return true end
  for oid, o in pairs(data) do
    if oid ~= id and o.pos and o.state == 'active' then
      rel:setSub2(o.pos, v.pos)
      local fwd = rel:dot(v.dirVec)
      if fwd < 0 and fwd > -LEAVE_GAP then
        local latSq = rel:squaredLength() - fwd * fwd
        if latSq < 30 and (o.speed or 0) > 2 then return false end
      end
    end
  end
  return true
end

-- Only ordinary traffic that nothing else has a claim on.
local function eligible(id, v)
  if not v or not units.ai(v) or v.state ~= 'active' or not v.pos then return false end
  if v.vars.aiMode ~= 'traffic' or holds.isClaimed(id) then return false end
  if v.role and (v.role.name == 'police' or v.role.name == 'suspect') then return false end
  if (v.pursuit and (v.pursuit.mode or 0) > 0) then return false end
  if (v.speed or 0) < 2 then return false end
  return true
end

local function freeSpotNear(pos, vehId)
  local ok, list = pcall(gameplay_parking.findParkingSpots, pos, SEARCH_MIN, SEARCH_MAX)
  if not ok or not list then return nil end
  for i = 1, #list do
    local ps = list[i].ps
    if ps and not ps.missing then
      local fits = not ps.vehicleFits or ps:vehicleFits(vehId)
      local taken = (ps.hasAnyVehicles and ps:hasAnyVehicles()) or M.reserved[ps.name]
      if fits and not taken then return ps end
    end
  end
  return nil
end

local function start(id, v)
  local ps = freeSpotNear(v.pos, id)
  if not ps or not ps.pos then return false end
  if not map.findClosestRoad then return false end
  local node = map.findClosestRoad(ps.pos)
  if not node then return false end

  -- wpTargetList routes over the real navgraph and does not teleport, unlike the `script`
  -- form of driveUsingPath (ai.lua:6005). driveInLane keeps the path on the legal side.
  send(id, format(
    'ai.driveUsingPath{wpTargetList = {"%s"}, driveInLane = "on", avoidCars = "on", ' ..
    'routeSpeed = %.1f, routeSpeedMode = "limit", aggression = 0.35}',
    node, 9 + random() * 4))

  v.vars.aiMode = 'parking'
  M.active[id] = {phase = 'yendo', ps = ps, timer = DRIVE_TIMEOUT, spot = ps.name}
  M.count = M.count + 1
  return true
end

local function settle(id, v, e)
  e.phase, e.timer = 'maniobra', SETTLE_TIMEOUT
  send(id, 'ai.setSpeedMode("limit")')
  send(id, 'ai.setSpeed(2.5)')
  send(id, 'electrics.set_warn_signal(1)')
end

local function parked(id, v, e, exact)
  e.phase, e.timer = 'aparcado', STAY_MIN + random() * (STAY_MAX - STAY_MIN)
  e.exact = exact
  if units.ai(v) then v:setAiMode('stop') end
  send(id, 'electrics.set_warn_signal(0)')
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK
  if cooldown > 0 then cooldown = cooldown - TICK end
  if not checkAvailable() then return end

  local data = traffic()
  if not data then return end

  for id, e in pairs(M.active) do
    local v = data[id]
    e.timer = e.timer - TICK

    if not v or v.state ~= 'active' or (v.pursuit and (v.pursuit.mode or 0) > 0) then
      release(id, v)

    elseif e.phase == 'yendo' then
      local near = v.pos and e.ps.pos and v.pos:squaredDistance(e.ps.pos) < ARRIVE * ARRIVE
      if near or e.arrived then
        settle(id, v, e)
      elseif e.timer <= 0 then
        release(id, v)
      end

    elseif e.phase == 'maniobra' then
      -- The spot itself decides whether the car is properly in it. Without reverse control
      -- the AI often only gets close, so stopping beside the bay still counts as done.
      local ok, valid = pcall(function()
        return e.ps.checkParking and e.ps:checkParking(id, 0.4, 5, 1) or false
      end)
      if ok and valid then
        parked(id, v, e, true)
      elseif (v.speed or 0) < 0.6 then
        parked(id, v, e, false)
      elseif e.timer <= 0 then
        release(id, v)
      end

    elseif e.phase == 'aparcado' then
      if e.timer <= 0 then
        -- Indicator on first, then wait for a hole. A bay is not somewhere you can just
        -- pull away from blind, and the AI has no reverse to get itself out of trouble.
        e.phase, e.timer = 'saliendo', LEAVE_TIMEOUT
        send(id, format('electrics.toggle_%s_signal()', random() < 0.5 and 'left' or 'right'))
      end

    elseif e.phase == 'saliendo' then
      if rearClear(id, v, data) or e.timer <= 0 then release(id, v) end

    elseif e.timer <= 0 then
      release(id, v)
    end
  end

  if cooldown > 0 or M.count >= MAX_PARKED then return end
  if random() > CHANCE then return end

  -- One candidate per cycle, picked at random rather than by sweeping the whole world.
  local ids, n = nil, 0
  for id, v in pairs(data) do
    if eligible(id, v) then
      n = n + 1
      if not ids then ids = {} end
      ids[n] = id
    end
  end
  if n == 0 then return end
  local pick = ids[random(n)]
  if not start(pick, data[pick]) then cooldown = 8 end
end

-- A free bay ahead of us, on our side, within a cone. This is the lay-by a traffic stop or
-- an incident should be moved into instead of blocking a live lane.
function M.spotAhead(pos, dirVec, minD, maxD, vehId)
  if not checkAvailable() or not pos or not dirVec then return nil end
  local ok, list = pcall(gameplay_parking.findParkingSpots, pos, minD or 30, maxD or 150)
  if not ok or not list then return nil end
  for i = 1, #list do
    local ps = list[i].ps
    if ps and ps.pos and not ps.missing and not M.reserved[ps.name] then
      rel:setSub2(ps.pos, pos)
      local fwd = rel:dot(dirVec)
      if fwd > 0 then
        local latSq = rel:squaredLength() - fwd * fwd
        -- Within about 12 m of our own line of travel, so it is genuinely beside this road.
        if latSq < 144 then
          local fits = not ps.vehicleFits or not vehId or ps:vehicleFits(vehId)
          local taken = ps.hasAnyVehicles and ps:hasAnyVehicles()
          if fits and not taken then return ps, fwd end
        end
      end
    end
  end
  return nil
end

-- Nearest free bay to a point, direction irrelevant: used to stage an incident off the road.
function M.spotNear(pos, maxD, vehId)
  if not checkAvailable() or not pos then return nil end
  local ok, list = pcall(gameplay_parking.findParkingSpots, pos, 0, maxD or 60)
  if not ok or not list then return nil end
  for i = 1, #list do
    local ps = list[i].ps
    if ps and ps.pos and not ps.missing and not M.reserved[ps.name] then
      local fits = not ps.vehicleFits or not vehId or ps:vehicleFits(vehId)
      local taken = ps.hasAnyVehicles and ps:hasAnyVehicles()
      if fits and not taken then return ps end
    end
  end
  return nil
end

function M.reserve(ps)
  if ps and ps.name then M.reserved[ps.name] = true end
end

function M.unreserve(ps)
  if ps and ps.name then M.reserved[ps.name] = nil end
end

-- ai.lua reports arrival through this hook (ge/main.lua:1163), which beats guessing from
-- distance alone when the bay sits off the navgraph.
function M.onAiRouteDone(vehId)
  local e = M.active[vehId]
  if e and e.phase == 'yendo' then e.arrived = true end
end

function M.label(id)
  local e = M.active[id]
  if not e then return nil end
  if e.phase == 'yendo' then return 'VA A APARCAR' end
  if e.phase == 'maniobra' then return 'APARCANDO' end
  if e.phase == 'saliendo' then return 'ESPERA HUECO PARA SALIR' end
  return e.exact and 'APARCADO' or 'PARADO JUNTO A LA PLAZA'
end

function M.reset()
  local data = traffic()
  for id in pairs(M.active) do release(id, data and data[id]) end
  M.active, M.count = {}, 0
  M.reserved = {}
  timer, cooldown = 0, 0
end

return M
