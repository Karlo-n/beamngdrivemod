local M = {}

local random = math.random

local policeStop = require('trafficAI/behaviors/policeStop')
local emergency = require('trafficAI/environment/emergency')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')

-- Scenes are staged with the patrols and traffic that already exist. Nothing is spawned,
-- so a scene only happens when the map happens to have the pieces for it.
local SCAN = 1.0            -- seconds between scheduler ticks
local TICK = 0.25           -- seconds between active-event ticks
local GAP_MIN, GAP_MAX = 45, 120 -- quiet time between scenes

M.enabled = true
M.current = nil
M.calmPos = nil             -- roadside patrol civilians should ease off for
M.calmRadiusSq = 0

local nextIn = 25
local scanTimer, tickTimer = 0, 0
local pool = {}

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function lightbar(id, level)
  send(id, 'electrics.set_lightbar_signal(' .. level .. ')')
end

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function patrols()
  if not gameplay_police or not gameplay_police.getPoliceVehicles then return nil end
  return gameplay_police.getPoliceVehicles()
end

-- A patrol with nothing better to do: not in a pursuit and not running a traffic stop.
local function freePatrols(data, police, out)
  local n = 0
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and v.pos and not policeStop.stops[pid]
      and not emergency.reserved[pid]
      and not (v.pursuit and v.pursuit.mode and v.pursuit.mode > 0) then
      n = n + 1
      out[n] = pid
    end
  end
  return n
end

local function randomCivilian(data, police, wantStopped)
  local playerId = be:getPlayerVehicleID(0)
  local n = 0
  for id, v in pairs(data) do
    if id ~= playerId and not police[id] and not v.isPerson and v.state == 'active' and v.pos
      and not policeStop.byTarget[id] and not holds.isClaimed(id)
      and not (v.pursuit and v.pursuit.mode and v.pursuit.mode > 0) then
      local speed = v.vel and v.vel:length() or 0
      if wantStopped == nil or (wantStopped and speed < 1) or (not wantStopped and speed > 3) then
        n = n + 1
        pool[n] = id
      end
    end
  end
  if n == 0 then return nil end
  return pool[random(n)]
end

local function parkPatrol(pid, data, withLights)
  local v = data[pid]
  if not v or not units.ai(v) then return end
  v:setAiMode('traffic')
  send(pid, units.KERB_STOP)
  lightbar(pid, withLights and 1 or 0)
end

local function unpark(pid, data)
  local v = data[pid]
  send(pid, 'ai.setPullOver(false)')
  send(pid, 'electrics.set_warn_signal(0)')
  lightbar(pid, 0)
  if v and units.ai(v) then v:setAiMode('traffic') end
end

-- Each scene: begin() stages it and returns a state table (or nil if the pieces are missing),
-- tick() runs while it lasts, and finish() puts everything back.
local scenes = {}

scenes.persecucion = {rare = true, w = 2, label = 'persecucion en curso',
  begin = function(data, police)
    local id = randomCivilian(data, police, false)
    if not id or not gameplay_police.setSuspect then return nil end
    gameplay_police.setSuspect(id)
    gameplay_police.setPursuitMode(1, id)
    return {life = 0} -- the stock pursuit system owns it from here
  end}

scenes.multaAparcado = {rare = true, w = 3, label = 'multando a un mal aparcado',
  begin = function(data, police, free, freeCount)
    local id = randomCivilian(data, police, true)
    if not id or freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    if not units.ai(v) then return nil end
    v:setAiMode('follow')
    send(pid, 'ai.setTargetObjectID(' .. id .. ')')
    lightbar(pid, 1)
    return {life = 45 + random() * 45, pid = pid, targetId = id}
  end,
  finish = function(s, data) unpark(s.pid, data) end}

scenes.radar = {rare = true, w = 3, label = 'control de velocidad',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    parkPatrol(pid, data, false)
    return {life = 60 + random() * 80, pid = pid, caught = false}
  end,
  tick = function(s, data)
    if s.caught then return end
    local pol = data[s.pid]
    if not pol or not pol.pos then return end
    for id, v in pairs(data) do
      if id ~= s.pid and v.pos and v.tracking and not v.isPerson then
        local speed = v.vel and v.vel:length() or 0
        -- Real radar tolerance: a few km/h over is let go, only a clear excess is stopped.
        if speed > (v.tracking.speedLimit or 16) * 1.25 + 3 and v.pos:squaredDistance(pol.pos) < 2500 then
          send(s.pid, 'ai.setPullOver(false)')
          if policeStop.begin(id, 'exceso de velocidad', 0.6) then
            s.caught = true
            s.life = 0
          end
          return
        end
      end
    end
  end,
  finish = function(s, data) if not s.caught then unpark(s.pid, data) end end}

scenes.paradaCivil = {rare = true, w = 3, label = 'parando a un civil',
  begin = function(data, police)
    local id = randomCivilian(data, police, false)
    if not id then return nil end
    if not policeStop.begin(id, 'control rutinario', 0.45) then return nil end
    return {life = 0}
  end}

scenes.avisoUrgente = {rare = true, w = 2, label = 'patrulla en aviso',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    v:useSiren(2 + random() * 2)
    lightbar(pid, 2) -- a genuine call: this one really does get lights and siren
    -- Lights and speed, but still driving properly: lane discipline and car avoidance stay on.
    send(pid, 'ai.setSpeedMode("off")')
    send(pid, 'ai.setAvoidCars("on")')
    send(pid, 'ai.driveInLane("on")')
    send(pid, 'ai.setAggressionMode("off")')
    send(pid, 'ai.setAggression(0.62)')
    return {life = 25 + random() * 25, pid = pid}
  end,
  finish = function(s, data)
    send(s.pid, 'ai.setSpeedMode("legal")')
    send(s.pid, 'ai.setAggression(0.35)')
    unpark(s.pid, data)
  end}

scenes.rutina = {w = 8, label = 'patrulla de rutina',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    local limit = (v.tracking and v.tracking.speedLimit) or 16
    send(pid, 'ai.setSpeedMode("limit")')
    send(pid, string.format('ai.setSpeed(%.2f)', limit * (0.65 + random() * 0.2)))
    return {life = 30 + random() * 40, pid = pid}
  end,
  finish = function(s) send(s.pid, 'ai.setSpeedMode("legal")') end}

scenes.descanso = {w = 7, label = 'patrulla aparcada',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    parkPatrol(pid, data, false)
    return {life = 40 + random() * 80, pid = pid}
  end,
  finish = function(s, data) unpark(s.pid, data) end}

scenes.charla = {w = 4, label = 'dos patrullas paradas',
  begin = function(data, police, free, freeCount)
    if freeCount < 2 then return nil end
    local a, b = free[1], free[2]
    if data[a].pos:squaredDistance(data[b].pos) > 40000 then return nil end
    parkPatrol(a, data, true)
    parkPatrol(b, data, true)
    return {life = 30 + random() * 40, pid = a, pid2 = b}
  end,
  finish = function(s, data) unpark(s.pid, data) unpark(s.pid2, data) end}

scenes.pasoRapido = {w = 6, label = 'patrulla cruzando con luces',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    -- Lights on, siren only as a short burst. A patrol does not drive around wailing.
    lightbar(pid, 1)
    data[pid]:useSiren(0.6 + random() * 0.8)
    return {life = 8 + random() * 7, pid = pid}
  end,
  finish = function(s) lightbar(s.pid, 0) end}

scenes.vigilancia = {w = 7, label = 'patrulla siguiendo a alguien',
  begin = function(data, police, free, freeCount)
    local id = randomCivilian(data, police, false)
    if not id or freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    if not units.ai(v) then return nil end
    v:setAiMode('follow')
    send(pid, 'ai.setTargetObjectID(' .. id .. ')')
    return {life = 20 + random() * 30, pid = pid}
  end,
  finish = function(s, data) unpark(s.pid, data) end}

scenes.escolta = {w = 4, label = 'escolta',
  begin = function(data, police, free, freeCount)
    local id = randomCivilian(data, police, false)
    if not id or freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    if not units.ai(v) then return nil end
    v:setAiMode('follow')
    send(pid, 'ai.setTargetObjectID(' .. id .. ')')
    lightbar(pid, 1)
    return {life = 30 + random() * 35, pid = pid}
  end,
  finish = function(s, data) unpark(s.pid, data) end}

scenes.corteCarril = {w = 4, label = 'carril cortado',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    local v = data[pid]
    if not units.ai(v) then return nil end
    v:setAiMode('stop')
    lightbar(pid, 1) -- stationary and blocking: lights are enough, no siren
    send(pid, 'electrics.set_warn_signal(1)')
    return {life = 20 + random() * 28, pid = pid}
  end,
  finish = function(s, data) unpark(s.pid, data) end}

scenes.chirrido = {w = 5, label = 'toque de sirena',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    data[pid]:useSiren(0.3 + random() * 0.5)
    return {life = 2}
  end}

scenes.reagrupar = {w = 5, label = 'patrulla cambiando de zona',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    -- Just a brisker patrol, not the free-for-all that 'random' mode produces.
    local limit = (data[pid].tracking and data[pid].tracking.speedLimit) or 16
    send(pid, 'ai.setSpeedMode("limit")')
    send(pid, string.format('ai.setSpeed(%.2f)', limit * 1.05))
    return {life = 20 + random() * 30, pid = pid}
  end,
  finish = function(s) send(s.pid, 'ai.setSpeedMode("legal")') end}

scenes.presencia = {w = 6, label = 'presencia policial',
  begin = function(data, police, free, freeCount)
    if freeCount == 0 then return nil end
    local pid = free[random(freeCount)]
    parkPatrol(pid, data, true)
    return {life = 45 + random() * 70, pid = pid, calm = true}
  end,
  tick = function(s, data)
    local pol = data[s.pid]
    -- Published so civilians ease off near a visible patrol without each of them searching.
    M.calmPos = pol and pol.pos or nil
    M.calmRadiusSq = 3600
  end,
  finish = function(s, data)
    M.calmPos, M.calmRadiusSq = nil, 0
    unpark(s.pid, data)
  end}

local order, totalWeight = {}, 0
for name, sc in pairs(scenes) do
  sc.name = name
  totalWeight = totalWeight + sc.w
  order[#order + 1] = sc
end

local function pick()
  local roll = random() * totalWeight
  for i = 1, #order do
    roll = roll - order[i].w
    if roll <= 0 then return order[i] end
  end
  return order[#order]
end

local function stop(data)
  local cur = M.current
  if not cur then return end
  M.current = nil
  if cur.scene.finish then
    local ok, err = pcall(cur.scene.finish, cur.state, data)
    if not ok then log('E', 'trafficAI', 'policeEvents finish: ' .. tostring(err)) end
  end
  nextIn = GAP_MIN + random() * (GAP_MAX - GAP_MIN)
end

function M.update(dt)
  if not M.enabled then return end

  local data = traffic()
  if not data then return end

  if M.current then
    tickTimer = tickTimer - dt
    if tickTimer <= 0 then
      tickTimer = TICK
      local cur = M.current
      cur.state.life = cur.state.life - TICK
      if cur.scene.tick then cur.scene.tick(cur.state, data) end
      if cur.state.life <= 0 then stop(data) end
    end
    return
  end

  scanTimer = scanTimer - dt
  if scanTimer > 0 then return end
  scanTimer = SCAN
  nextIn = nextIn - SCAN
  if nextIn > 0 then return end

  local police = patrols()
  if not police then nextIn = GAP_MIN return end

  local free = {}
  local freeCount = freePatrols(data, police, free)
  local sc = pick()
  local ok, state = pcall(sc.begin, data, police, free, freeCount)
  if not ok then
    log('E', 'trafficAI', 'policeEvents begin: ' .. tostring(state))
    state = nil
  end
  if not state then
    nextIn = 8 + random() * 12 -- the pieces were not there; try again shortly
    return
  end
  M.current = {scene = sc, state = state}
  tickTimer = 0
end

function M.label()
  return M.current and M.current.scene.label or nil
end

function M.reset()
  local data = traffic()
  if data then stop(data) end
  M.current, M.calmPos, M.calmRadiusSq = nil, nil, 0
  nextIn = 30
end

return M
