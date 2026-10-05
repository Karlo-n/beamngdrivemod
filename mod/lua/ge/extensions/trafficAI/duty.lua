local M = {}

local random = math.random
local floor = math.floor
local format = string.format

local fines = require('trafficAI/behaviors/fines')
local policeStop = require('trafficAI/behaviors/policeStop')
local spikes = require('trafficAI/behaviors/spikes')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')
local missions = require('trafficAI/missions')
local radio = require('trafficAI/radio')

local NEAR = 45
local NEAR_SQ = NEAR * NEAR
local PUSH_PERIOD = 0.4

M.role = 'none'          -- none | police | medic | fire
M.callsign = ''
M.status = 'available'
M.targetId = 0
M.log = {}

local pushTimer = 0
local searched = {}      -- what was found in each vehicle, so a boot holds the same thing twice

local CONTRABAND = {
  'nada de interes', 'nada de interes', 'nada de interes',
  'herramienta sin justificar', 'bidon de gasolina', 'documentacion caducada',
  'matricula que no coincide', 'bolsa sospechosa', 'dinero en efectivo sin declarar'
}

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function note(text)
  table.insert(M.log, 1, text)
  for i = #M.log, 9, -1 do M.log[i] = nil end
end
missions.onNote = note

-- A car told to stop is held: its driver model stands down so the engine's own pull-over
-- can finish. Handing it back keeps it claimed if it is still somebody's mission target.
local function unhold(id)
  if not id or id == 0 then return end
  if missions.isTarget(id) then holds.claim(id, 'mission', false) else holds.release(id) end
end

-- Callsigns are stable per vehicle so the same car keeps its number for the session.
local PREFIX = {police = 'UNIDAD', medic = 'SVB', fire = 'BOMBA',
                swat = 'GEO', undercover = 'PAISANO'}

local function makeCallsign(id, role)
  return format('%s %d-%02d', PREFIX[role] or 'UNIDAD', 1 + (id % 9), 10 + (id % 80))
end

-- What the vehicle actually is. partConfig is the reliable source, but it comes back empty
-- for some spawns, so the model name and the traffic role are used as fallbacks.
local function configOf(id)
  local obj = getObjectByID(id)
  if not obj then return '' end
  local pc = obj.partConfig
  if pc == nil or pc == '' then
    local ok, v = pcall(function() return obj:getField('partConfig', 0) end)
    if ok then pc = v end
  end
  if pc == nil or pc == '' then pc = obj.JBeam end
  local data = traffic()
  local tv = data and data[id]
  if (pc == nil or pc == '') and tv then pc = tv.model or tv.modelName end
  return string.lower(pc or '')
end
M.configOf = configOf

local function classify(id)
  local pc = configOf(id)
  if pc == '' then return 'none' end
  if string.find(pc, 'ambulance', 1, true) then return 'medic' end
  if string.find(pc, 'firetruck', 1, true) or string.find(pc, 'firechief', 1, true) then
    return 'fire'
  end
  if string.find(pc, 'armored_police', 1, true) then return 'swat' end
  if string.find(pc, 'unmarked', 1, true) or string.find(pc, 'detective', 1, true) then
    return 'undercover'
  end
  local data = traffic()
  local v = data and data[id]
  if (v and (v.autoRole == 'police' or v.roleName == 'police'))
    or string.find(pc, 'police', 1, true) or string.find(pc, 'sheriff', 1, true)
    or string.find(pc, 'polizia', 1, true) or string.find(pc, 'gendarmerie', 1, true)
    or string.find(pc, 'interceptor', 1, true) then
    return 'police'
  end
  return 'none'
end

-- Nearest other vehicle in front of the player, which is what any of these actions act on.
local function nearest()
  local playerId = be:getPlayerVehicleID(0)
  local objects = map.objects
  local me = objects and objects[playerId]
  if not me or not me.pos then return nil end

  local best, bestD = nil, NEAR_SQ
  for id, o in pairs(objects) do
    if id ~= playerId and o.pos then
      local d = o.pos:squaredDistance(me.pos)
      if d < bestD then best, bestD = id, d end
    end
  end
  return best
end

local function vehName(id)
  local data = traffic()
  local v = data and data[id]
  return (v and v.modelName) or ('vehiculo #' .. tostring(id))
end

-- ---------------------------------------------------------------- state to the UI

local function snapshot()
  local data = traffic()
  local t = M.targetId ~= 0 and data and data[M.targetId] or nil
  local out = {
    role = M.role, callsign = M.callsign, status = M.status,
    stars = 0, fines = fines.total, fineCount = fines.count,
    log = M.log, target = nil
  }
  local wanted = require('trafficAI/behaviors/wanted')
  out.stars = wanted.stars or 0

  if t then
    local p = t.pursuit
    local offs = {}
    if p and p.offensesList then
      for _, k in ipairs(p.offensesList) do offs[#offs + 1] = k end
    end
    out.target = {
      id = M.targetId,
      name = vehName(M.targetId),
      speed = floor((t.speed or 0) * 3.6),
      limit = floor(((t.tracking and t.tracking.speedLimit) or 0) * 3.6),
      damage = floor(t.damage or 0),
      wanted = (p and (p.mode or 0) > 0) or false,
      offenses = offs,
      searched = searched[M.targetId] or nil,
      stopped = (t.speed or 0) < 1
    }
  end
  return out
end

M.snapshot = function() return snapshot() end

function M.push()
  if guihooks then guihooks.trigger('TrafficAIDuty', snapshot()) end
end

-- ---------------------------------------------------------------- actions

function M.selectNearest()
  local id = nearest()
  local m = missions.current
  if m and m.target then
    local me = map.objects and map.objects[be:getPlayerVehicleID(0)]
    local t = map.objects and map.objects[m.target]
    if me and t and me.pos and t.pos and me.pos:squaredDistance(t.pos) < NEAR_SQ * 2 then
      id = m.target
    end
  end
  if not id then note('Sin vehiculos cerca.') M.push() return end
  M.targetId = id
  note(format('Marcado: %s', vehName(id)))
  M.push()
end

function M.clearTarget()
  M.targetId = 0
  M.push()
end

-- Reads out what the game already knows about the vehicle rather than inventing a record.
function M.runPlate()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  local data = traffic()
  local t = data and data[M.targetId]
  if not t then note('Sin datos.') M.push() return end

  local p = t.pursuit
  local count = (p and p.uniqueOffensesCount) or 0
  local flagged = missions.plateInfo(M.targetId)
  if flagged then
    note(format('%s: %s', vehName(M.targetId), flagged))
  elseif count > 0 then
    note(format('%s: %d infraccion(es) registradas.', vehName(M.targetId), count))
  elseif p and (p.mode or 0) > 0 then
    note(format('%s: en busca y captura.', vehName(M.targetId)))
  else
    note(format('%s: sin antecedentes.', vehName(M.targetId)))
  end
  missions.onAction('plate', M.targetId)
  M.push()
end

function M.signalStop()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(2)')
  local data = traffic()
  local t = data and data[M.targetId]
  if t and units.ai(t) then
    holds.claim(M.targetId, 'stop', true)
    send(M.targetId, units.KERB_STOP)
  end
  M.status = 'parada de trafico'
  note(format('Dando el alto a %s.', vehName(M.targetId)))
  missions.onAction('stop', M.targetId)
  M.push()
end

function M.releaseStop()
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(0)')
  if M.targetId ~= 0 then
    send(M.targetId, 'ai.setPullOver(false)')
    unhold(M.targetId)
  end
  M.status = 'available'
  note('Puede continuar.')
  missions.onAction('release', M.targetId)
  M.push()
end

function M.warnDriver()
  if M.targetId == 0 then return end
  note(format('Advertencia verbal a %s. Puede continuar.', vehName(M.targetId)))
  missions.onAction('warning', M.targetId)
  send(M.targetId, 'ai.setPullOver(false)')
  unhold(M.targetId)
  M.status = 'available'
  M.push()
end

-- A boot search returns the same result every time for the same vehicle, so it reads as a
-- fact about that car rather than a dice roll.
function M.searchVehicle()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  local data = traffic()
  local t = data and data[M.targetId]
  if not t then return end
  if (t.speed or 0) > 1.5 then
    note('Tiene que estar detenido para registrarlo.')
    M.push()
    return
  end

  local found = searched[M.targetId]
  if not found then
    local seed = (M.targetId * 2654435761) % #CONTRABAND + 1
    found = CONTRABAND[seed]
    searched[M.targetId] = found
  end
  note(format('Registro de %s: %s.', vehName(M.targetId), found))
  M.status = 'registro'
  M.push()
end

function M.issueTicket()
  if M.targetId == 0 then return end
  local data = traffic()
  local t = data and data[M.targetId]
  if not t then return end
  local amount, warning = fines.issue(t, 'control', 0.9, false)
  if warning or amount == 0 then
    note('Advertencia verbal, sin multa.')
    missions.onAction('warning', M.targetId)
  else
    note(format('Multa emitida: %d.', amount))
    fines.clearRecord(t)
    missions.onAction('ticket', M.targetId)
  end
  send(M.targetId, 'ai.setPullOver(false)')
  unhold(M.targetId)
  M.status = 'available'
  M.push()
end

function M.arrest()
  if M.targetId == 0 then return end
  if gameplay_police and gameplay_police.arrestVehicle then
    pcall(gameplay_police.arrestVehicle, M.targetId, true)
  end
  note(format('%s detenido.', vehName(M.targetId)))
  missions.onAction('arrest', M.targetId)
  unhold(M.targetId)
  M.status = 'available'
  M.push()
end

function M.callBackup()
  local data = traffic()
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not data or not police then return end
  local me = data[be:getPlayerVehicleID(0)]
  if not me or not me.pos then return end

  local n1 = map.findClosestRoad and map.findClosestRoad(me.pos)
  local sent = 0
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' and n1 and sent < 2 then
      v:setAiMode('traffic')
      send(pid, format('ai.setTarget(%q)', n1))
      send(pid, 'ai.setAvoidCars("on")')
      send(pid, 'ai.driveInLane("on")')
      send(pid, 'electrics.set_lightbar_signal(2)')
      sent = sent + 1
    end
  end
  note(sent > 0 and format('%d unidad(es) en camino.', sent) or 'Sin unidades disponibles.')
  M.push()
end

function M.deploySpikes()
  if spikes.preload then spikes.preload() end
  note('Bandas de pinchos solicitadas.')
  M.push()
end

local BREATH = {'negativo', 'negativo', 'negativo', 'negativo',
                '0.28 mg/l, positivo', '0.41 mg/l, positivo', 'se niega a soplar'}

function M.breathTest()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  local data = traffic()
  local t = data and data[M.targetId]
  if not t then return end
  if (t.speed or 0) > 1.5 then
    note('Tiene que estar detenido.')
    M.push()
    return
  end
  local r = missions.breathResult(M.targetId) or BREATH[((M.targetId * 40503) % #BREATH) + 1]
  note(format('Prueba de alcoholemia: %s.', r))
  missions.onAction('breath', M.targetId)
  M.push()
end

-- Follows without lights and at a distance. The whole point of an unmarked car.
function M.tail()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(0)')
  M.status = 'seguimiento'
  note(format('Siguiendo a %s sin identificarse.', vehName(M.targetId)))
  M.push()
end

-- Lights on: the unmarked car stops being unmarked.
function M.blowCover()
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(2)')
  local data = traffic()
  local t = M.targetId ~= 0 and data and data[M.targetId]
  if t and gameplay_police and gameplay_police.setPursuitMode then
    pcall(gameplay_police.setPursuitMode, 1, M.targetId)
  end
  M.status = 'identificado'
  note('Identificacion policial. Objetivo requerido.')
  M.push()
end

-- SWAT: two units laid across the road well ahead of whoever is running.
function M.roadblock()
  local wanted = require('trafficAI/behaviors/wanted')
  local data = traffic()
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if not data or not police or not gameplay_police.placeRoadblock then
    note('Sin unidades para el corte.')
    M.push()
    return
  end

  local me = data[be:getPlayerVehicleID(0)]
  if not me or not me.pos or not me.dirVec then return end
  local ids = {}
  for pid in pairs(police) do
    local v = data[pid]
    if v and units.ai(v) and v.state == 'active' then ids[#ids + 1] = pid end
    if #ids >= 2 then break end
  end
  if #ids < 2 then
    note('Hacen falta dos unidades libres.')
    M.push()
    return
  end

  local pos = vec3(me.pos)
  pos:setAddScaled(pos, me.dirVec, 160)
  local n1 = map.findClosestRoad and map.findClosestRoad(pos)
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not n1 or not nodes or not nodes[n1] then return end
  local dir = vec3(me.dirVec)
  dir.z = 0
  dir:normalize()
  local ok = pcall(gameplay_police.placeRoadblock, ids, vec3(nodes[n1].pos),
    quatFromDir(dir, vec3(0, 0, 1)), {width = 9, angle = 25})
  note(ok and 'Control montado 160 m mas adelante.' or 'No se pudo montar el control.')
  M.push()
end

function M.perimeter()
  send(be:getPlayerVehicleID(0), 'electrics.set_warn_signal(1)')
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(2)')
  M.status = 'perimetro'
  note('Perimetro establecido.')
  M.push()
end

-- ---------------------------------------------------------------- medic / fire

function M.treat()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  local data = traffic()
  local t = data and data[M.targetId]
  if not t then return end
  local dmg = floor(t.damage or 0)
  if dmg < 500 then
    note(format('%s sin heridos aparentes.', vehName(M.targetId)))
  else
    note(format('Atendiendo a los ocupantes de %s (danos %d).', vehName(M.targetId), dmg))
    M.status = 'atendiendo'
  end
  missions.onAction('treat', M.targetId)
  M.push()
end

function M.extinguish()
  if M.targetId == 0 then M.selectNearest() end
  if M.targetId == 0 then return end
  send(M.targetId, 'fire.extinguishVehicleSlowly()')
  note(format('Sofocando el fuego en %s.', vehName(M.targetId)))
  M.status = 'extinguiendo'
  missions.onAction('extinguish', M.targetId)
  M.push()
end

function M.secureScene()
  send(be:getPlayerVehicleID(0), 'electrics.set_warn_signal(1)')
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(2)')
  M.status = 'asegurando'
  note('Escena asegurada, balizas puestas.')
  missions.onAction('secure', M.targetId)
  M.push()
end

-- Casualty away: the ambulance drives off and the job is done.
function M.transport()
  M.status = 'traslado'
  send(be:getPlayerVehicleID(0), 'electrics.set_lightbar_signal(2)')
  note(M.targetId ~= 0 and format('Trasladando desde %s al hospital.', vehName(M.targetId))
    or 'Trasladando al hospital.')
  missions.onAction('transport', M.targetId)
  M.targetId = 0
  M.push()
end

function M.requestUnit(kind)
  note(kind == 'fire' and 'Solicitados bomberos.'
    or (kind == 'medic' and 'Solicitada asistencia sanitaria.' or 'Solicitado apoyo policial.'))
  M.push()
end

function M.requestFire() M.requestUnit('fire') end
function M.requestMedic() M.requestUnit('medic') end

function M.setStatus(s)
  M.status = tostring(s or 'available')
  M.push()
end

-- ---------------------------------------------------------------- lifecycle

local shown = false

function M.showConsole()
  radio.toggle()
  shown = true
  log('I', 'trafficAI', 'radio ' .. (radio.visible and 'abierta' or 'cerrada') .. '; rol: ' .. tostring(M.role))
end

-- Run trafficAI_duty.diagnose() from the console when the panel does not turn up. It says
-- whether the app is registered at all and what the game thinks you are driving.
function M.diagnose()
  local id = be:getPlayerVehicleID(0)
  local apps = ui_apps and ui_apps.getUIAppsData and ui_apps.getUIAppsData()
  local registered = apps and apps.emergencyui ~= nil
  local names = {}
  if apps then
    for k in pairs(apps) do
      if string.find(string.lower(k), 'traffic', 1, true)
        or string.find(string.lower(k), 'emergency', 1, true) then
        names[#names + 1] = k
      end
    end
  end
  local msg = string.format(
    'TrafficAI duty: vehiculo=%s  config=%q  rol=%s  indicativo=%s\n' ..
    'app "emergencyui" registrada: %s\napps del mod encontradas: %s',
    tostring(id), configOf(id), tostring(M.role), tostring(M.callsign),
    tostring(registered), #names > 0 and table.concat(names, ', ') or 'NINGUNA')
  print(msg)
  log('I', 'trafficAI', msg)
  return msg
end

local function refreshRole()
  local id = be:getPlayerVehicleID(0)
  local role = classify(id)
  if role ~= M.role then
    M.role = role
    M.callsign = role ~= 'none' and makeCallsign(id, role) or ''
    M.status = 'available'
    M.targetId = 0
    table.clear(M.log)
    if role ~= 'none' then
      note('En servicio. Esperando avisos.')
      radio.visible = true
    end
    M.push()
  end
end

function M.onVehicleSwitched()
  refreshRole()
end

local function abandonedStop()
  local id = M.targetId
  if id == 0 or holds.owner(id) ~= 'stop' then return end
  local me = map.objects and map.objects[be:getPlayerVehicleID(0)]
  local t = map.objects and map.objects[id]
  if not t or not me or not me.pos or not t.pos or me.pos:squaredDistance(t.pos) > 22500 then
    send(id, 'ai.setPullOver(false)')
    unhold(id)
  end
end

-- Missions and the radio each get their own failure budget: a drawing bug must never take
-- the gameplay down with it, and either one fails once in the log, not once per frame.
local budget = {missions = 0, radio = 0}
local off = {}

local function run(name, fn, a, b)
  if off[name] then return end
  local ok, err = pcall(fn, a, b)
  if ok then return end
  budget[name] = budget[name] + 1
  if budget[name] == 1 then log('E', 'trafficAI', name .. ': ' .. tostring(err)) end
  if budget[name] >= 5 then
    off[name] = true
    if name == 'radio' then radio.visible = false end
    if ui_message then ui_message('TrafficAI: ' .. name .. ' desactivado por errores.', 8, 'trafficAI') end
  end
end

function M.onUpdate(dt)
  if M.role == 'none' and not missions.current and not missions.offer then return end
  run('missions', missions.update, dt, M.role)
  run('radio', radio.draw, M, missions)
end

function M.onPreRender(dt)
  pushTimer = pushTimer - dt
  if pushTimer > 0 then return end
  pushTimer = PUSH_PERIOD
  refreshRole()
  abandonedStop()
  if M.role ~= 'none' then M.push() end
end

function M.onExtensionLoaded()
  refreshRole()
  return true
end

function M.reset()
  missions.reset()
  radio.visible = false
  shown = false
  M.role, M.callsign, M.status, M.targetId = 'none', '', 'available', 0
  table.clear(M.log)
  table.clear(searched)
end

return M
