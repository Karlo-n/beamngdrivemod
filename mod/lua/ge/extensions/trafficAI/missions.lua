local M = {}

local random = math.random
local floor = math.floor
local format = string.format

local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')
local stateMachine = require('trafficAI/core/stateMachine')

-- Dispatch calls for whoever is driving a service vehicle. Each call is a short chain of
-- objectives checked against what is really happening on the road: the speeder is a real
-- civilian driving fast because its driver model was told to, the casualty is a real car
-- pulled over at the kerb, the fire is a real fire. Nothing is faked on screen.

local TICK = 0.25
local OFFER_FIRST = 8
local OFFER_GAP_MIN, OFFER_GAP_MAX = 20, 45
local OFFER_LIFE = 25
local NAV_REFRESH = 3
local NAV_NEAR = 35

M.offer = nil
M.current = nil
M.last = nil
M.stats = {done = 0, failed = 0, score = 0}
M.onNote = nil

local role = 'none'
local timer, offerTimer, navTimer, navOn = 0, OFFER_FIRST, 0, false
-- Real seconds since the last tick. Resetting a countdown to TICK drops the overshoot, and
-- with float steps every tick came out a frame long: mission clocks ran 20% slow.
local elapsed = TICK

local function traffic()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

local function note(text)
  if M.onNote then M.onNote(text) end
end

local function driverOf(id)
  return trafficAI_main and trafficAI_main.getDriver and trafficAI_main.getDriver(id) or nil
end

local function player()
  local id = be:getPlayerVehicleID(0)
  local data = traffic()
  local o = map.objects and map.objects[id]
  return id, o, data and data[id]
end

-- A civilian the AI is really driving, not already busy with something else.
local function pickCivilian(minD, maxD)
  local data = traffic()
  local pid, me = player()
  if not data or not me or not me.pos then return nil end
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles() or {}
  local pool, n = {}, 0
  for id, v in pairs(data) do
    if id ~= pid and units.ai(v) and v.state == 'active' and v.pos and not police[id]
      and not v.isPerson and v.vars and v.vars.aiMode == 'traffic' and (v.speed or 0) > 3
      and not holds.isClaimed(id) and not units.isEmergency(id)
      and not (v.pursuit and (v.pursuit.mode or 0) > 0) and driverOf(id) then
      local d = v.pos:distance(me.pos)
      if d >= minD and d <= maxD then
        n = n + 1
        pool[n] = id
      end
    end
  end
  if n == 0 then return nil end
  return pool[random(n)]
end

-- A road point at roughly the wanted distance. Small maps may not have one in the exact
-- band, so the band widens rather than the call silently skipping a step.
local function pointFrom(pos, minD, maxD)
  local emergency = require('trafficAI/environment/emergency')
  if not emergency.pointBetween or not pos then return nil end
  return emergency.pointBetween(pos, minD, maxD)
    or emergency.pointBetween(pos, minD * 0.5, maxD * 1.6)
    or emergency.pointBetween(pos, 150, 4000)
end

local function protect(id, on)
  local data = traffic()
  local v = id and data and data[id]
  if v then v.enableRespawn = not on end
end

local function vehName(id)
  local data = traffic()
  local v = data and data[id]
  return (v and v.modelName) or 'vehiculo'
end

-- ---------------------------------------------------------------- objective helpers

local function step(m)
  return m.steps[m.step]
end

local function advance(m, text)
  local s = m.steps[m.step]
  if s then s.done = true end
  m.step = m.step + 1
  m.progress = nil
  if text then note(text) end
  if m.step > #m.steps then return 'done' end
  return nil
end

-- Holding a position for a while (treating, extinguishing, keeping a scene closed).
local function hold(m, ctx, ok, seconds)
  if ok then
    m.progress = (m.progress or 0) + elapsed / seconds
  elseif m.progress then
    m.progress = m.progress - elapsed / (seconds * 2)
    if m.progress < 0 then m.progress = 0 end
  end
  return m.progress and m.progress >= 1
end

local function targetPos(m)
  local data = traffic()
  local v = m.target and data and data[m.target]
  return v and v.pos or nil, v
end

local function targetGone(m)
  if not m.target then return false end
  local data = traffic()
  local v = data and data[m.target]
  return not units.alive(v)
end

-- ---------------------------------------------------------------- shared pieces

-- The civilian keeps driving on its own driver model; only its mood and pace change.
local function makeDriver(m, state, speedFactor, dur)
  local d = driverOf(m.target)
  if not d then return false end
  m.saved = {speedFactor = d.d.speedFactor}
  if speedFactor then d.d.speedFactor = speedFactor end
  if state then stateMachine.set(d, state, dur or 900) end
  holds.claim(m.target, 'mission', false)
  protect(m.target, true)
  return true
end

local function restoreDriver(m)
  if not m.target then return end
  local d = driverOf(m.target)
  if d and m.saved then
    d.d.speedFactor = m.saved.speedFactor
    stateMachine.set(d, 'normal')
  end
  holds.release(m.target, 'mission')
  holds.release(m.target, 'stop')
  protect(m.target, false)
end

-- A casualty or a burning car: pulled over at the kerb, hazards on, and held so the traffic
-- model leaves it there instead of driving off.
local function stageAtKerb(m)
  holds.claim(m.target, 'mission', true)
  protect(m.target, true)
  send(m.target, units.KERB_STOP)
  send(m.target, 'electrics.set_warn_signal(1)')
end

local function unstage(m)
  if not m.target then return end
  send(m.target, 'electrics.set_warn_signal(0)')
  send(m.target, 'ai.setPullOver(false)')
  holds.release(m.target, 'mission')
  protect(m.target, false)
end

-- Runs away once the patrol lights it up, then loses its nerve and pulls over.
local function checkFlee(m, ctx)
  if not m.flee or m.fled or not ctx.lights then return end
  if ctx.dist > 50 then return end
  m.fled, m.fleeTimer = true, 25 + random() * 30
  local d = driverOf(m.target)
  if d then
    d.d.speedFactor = 1.9
    stateMachine.set(d, 'aggressive', 900)
  end
  holds.setHeld(m.target, false)
  send(m.target, 'ai.setPullOver(false)')
  note(format('%s no para y huye.', vehName(m.target)))
end

local function checkGiveUp(m)
  if not m.fled or m.gaveUp then return end
  m.fleeTimer = m.fleeTimer - elapsed
  if m.fleeTimer > 0 then return end
  m.gaveUp = true
  local d = driverOf(m.target)
  if d then
    d.d.speedFactor = 0.7
    stateMachine.set(d, 'scared', 900)
  end
  holds.claim(m.target, 'mission', true)
  send(m.target, units.KERB_STOP)
  send(m.target, 'electrics.set_warn_signal(1)')
  note(format('%s se rinde y se orilla.', vehName(m.target)))
end

local function isStopped(ctx)
  return ctx.tSpeed and ctx.tSpeed < 1 and ctx.dist < 35
end

-- ---------------------------------------------------------------- the calls

local DEFS = {}

DEFS.speeder = {
  band = {40, 320},
  roles = {police = true, undercover = true, swat = true}, weight = 4, time = 240, reward = 400,
  title = 'Exceso de velocidad',
  brief = 'Un vehiculo circula muy por encima del limite. Localizalo, dale el alto y sancionalo.',
  setup = function(m)
    m.target = pickCivilian(40, 320)
    if not m.target then return false end
    if not makeDriver(m, 'hurried', 1.55 + random() * 0.35) then return false end
    m.flee = random() < 0.2
    m.steps = {{text = 'Localiza al vehiculo'}, {text = 'Dale el alto'},
               {text = 'Multa o advierte al conductor'}}
    return true
  end,
  tick = function(m, ctx)
    if m.step == 1 and ctx.dist < 60 then return advance(m, 'Vehiculo localizado.') end
    if m.step == 2 then
      checkFlee(m, ctx)
      checkGiveUp(m)
      if isStopped(ctx) then return advance(m, 'Vehiculo detenido.') end
    end
  end,
  action = function(m, name)
    if m.step == 3 and (name == 'ticket' or name == 'warning' or name == 'arrest') then
      return advance(m)
    end
  end,
  cleanup = restoreDriver
}

DEFS.drunk = {
  band = {40, 320},
  roles = {police = true, undercover = true}, weight = 3, time = 260, reward = 550,
  title = 'Conductor erratico',
  brief = 'Avisan de un coche haciendo eses. Paralo y hazle la prueba de alcoholemia.',
  setup = function(m)
    m.target = pickCivilian(40, 320)
    if not m.target then return false end
    local d = driverOf(m.target)
    if not makeDriver(m, 'drunk', d and d.d.speedFactor * 0.85) then return false end
    m.forcedBreath = format('%.2f mg/l, positivo', 0.45 + random() * 0.5)
    m.steps = {{text = 'Localiza al vehiculo'}, {text = 'Dale el alto'},
               {text = 'Prueba de alcoholemia'}, {text = 'Detenlo o multalo'}}
    return true
  end,
  tick = function(m, ctx)
    if m.step == 1 and ctx.dist < 60 then return advance(m, 'Vehiculo localizado.') end
    if m.step == 2 and isStopped(ctx) then return advance(m, 'Vehiculo detenido.') end
  end,
  action = function(m, name)
    if m.step == 3 and name == 'breath' then return advance(m) end
    if m.step == 4 and (name == 'arrest' or name == 'ticket') then return advance(m) end
  end,
  cleanup = restoreDriver
}

DEFS.stolen = {
  band = {50, 350},
  roles = {police = true, undercover = true, swat = true}, weight = 3, time = 300, reward = 700,
  title = 'Vehiculo robado',
  brief = 'Un vehiculo con denuncia de robo circula por la zona. Comprueba la matricula y detenlo.',
  setup = function(m)
    m.target = pickCivilian(50, 350)
    if not m.target then return false end
    if not makeDriver(m, nil, nil) then return false end
    m.stolen = true
    m.flee = random() < 0.45
    m.steps = {{text = 'Localiza al vehiculo'}, {text = 'Comprueba la matricula'},
               {text = 'Detenlo'}, {text = 'Practica la detencion'}}
    return true
  end,
  tick = function(m, ctx)
    if m.step == 1 and ctx.dist < 60 then return advance(m, 'Vehiculo localizado.') end
    if m.step == 3 then
      checkFlee(m, ctx)
      checkGiveUp(m)
      if isStopped(ctx) then return advance(m, 'Vehiculo detenido.') end
    end
  end,
  action = function(m, name)
    if m.step == 2 and name == 'plate' then
      if m.flee then m.lightsTrigger = true end
      return advance(m)
    end
    if m.step == 4 and name == 'arrest' then return advance(m) end
  end,
  cleanup = restoreDriver
}

DEFS.patrol = {
  roles = {police = true, swat = true, undercover = true}, weight = 2, time = 360, reward = 250,
  title = 'Patrulla de zona',
  brief = 'Recorre los puntos de control indicados y comunica sin novedad.',
  setup = function(m)
    local _, me = player()
    if not me or not me.pos then return false end
    m.points, m.steps = {}, {}
    local from = me.pos
    for i = 1, 3 do
      local p = pointFrom(from, 250, 800)
      if not p then return false end
      m.points[i] = p
      m.steps[i] = {text = format('Pasa por el punto %d', i)}
      from = p
    end
    return true
  end,
  dest = function(m) return m.points[m.step] end,
  tick = function(m, ctx)
    local p = m.points[m.step]
    if p and ctx.me:distance(p) < 20 then
      return advance(m, format('Punto %d sin novedad.', m.step))
    end
  end
}

DEFS.accident = {
  roles = {police = true, swat = true}, weight = 2, time = 300, reward = 350,
  title = 'Accidente: cortar la via',
  brief = 'Accidente con heridos. Acude, balizala zona y mantenla cerrada hasta que llegue la grua.',
  setup = function(m)
    local _, me = player()
    m.point = me and me.pos and pointFrom(me.pos, 300, 900)
    if not m.point then return false end
    m.steps = {{text = 'Llega al lugar'}, {text = 'Baliza la zona'},
               {text = 'Manten la zona cerrada'}}
    return true
  end,
  dest = function(m) return m.point end,
  tick = function(m, ctx)
    local near = ctx.me:distance(m.point)
    if m.step == 1 and near < 30 then return advance(m, 'En el lugar.') end
    if m.step == 3 and hold(m, ctx, near < 45 and ctx.lights, 20) then
      return advance(m, 'Zona despejada.')
    end
  end,
  action = function(m, name)
    if m.step == 2 and name == 'secure' then return advance(m) end
  end
}

local function casualtySetup(m, urgent)
  m.target = pickCivilian(70, 380)
  if not m.target then return false end
  stageAtKerb(m)
  m.urgent = urgent
  m.steps = {{text = 'Llega hasta el herido'}, {text = 'Atiende al herido'},
             {text = 'Traslado al hospital'}}
  return true
end

local function casualtyTick(m, ctx)
  if m.step == 1 and ctx.dist < 25 then return advance(m, 'En el lugar, paciente a la vista.') end
  if m.step == 2 and m.treating then
    if hold(m, ctx, ctx.dist < 18 and ctx.mySpeed < 1, m.urgent and 20 or 12) then
      m.treating = false
      return advance(m, 'Paciente estabilizado. Listo para el traslado.')
    end
  end
  if m.step == 3 and m.hospital and ctx.me:distance(m.hospital) < 22 then
    return advance(m, 'Paciente entregado en el hospital.')
  end
end

local function casualtyAction(m, name)
  if m.step == 2 and name == 'treat' then
    m.treating = true
    note('Atendiendo... mantente parado junto al paciente.')
  elseif m.step == 3 and name == 'transport' and not m.hospital then
    local pos = targetPos(m)
    m.hospital = pos and pointFrom(pos, 600, 1400)
    if not m.hospital then
      return advance(m, 'Paciente trasladado.')
    end
    unstage(m)
    m.target = nil
    note('Traslado en curso. Sigue las indicaciones.')
  end
end

DEFS.injured = {
  band = {70, 380},
  roles = {medic = true}, weight = 4, time = 300, reward = 500,
  title = 'Herido en accidente',
  brief = 'Conductor herido tras una salida de via. Acude, estabilizalo y trasladalo.',
  setup = function(m) return casualtySetup(m, false) end,
  dest = function(m) return m.hospital end,
  tick = casualtyTick, action = casualtyAction, cleanup = unstage
}

DEFS.cardiac = {
  band = {70, 380},
  roles = {medic = true}, weight = 2, time = 180, reward = 800,
  title = 'Parada cardiorrespiratoria',
  brief = 'Urgente. Persona inconsciente dentro de un vehiculo. Cada segundo cuenta.',
  setup = function(m) return casualtySetup(m, true) end,
  dest = function(m) return m.hospital end,
  tick = casualtyTick, action = casualtyAction, cleanup = unstage
}

DEFS.carfire = {
  band = {70, 380},
  roles = {fire = true}, weight = 4, time = 240, reward = 600,
  title = 'Vehiculo en llamas',
  brief = 'Un turismo ha empezado a arder en el arcen. Acude y sofoca el fuego antes de que se extienda.',
  setup = function(m)
    m.target = pickCivilian(70, 380)
    if not m.target then return false end
    stageAtKerb(m)
    m.igniteIn = 3
    m.steps = {{text = 'Llega al incendio'}, {text = 'Sofoca el fuego'}, {text = 'Asegura la zona'}}
    return true
  end,
  tick = function(m, ctx)
    if m.igniteIn then
      m.igniteIn = m.igniteIn - elapsed
      if m.igniteIn <= 0 and ctx.tSpeed and ctx.tSpeed < 1 then
        m.igniteIn = nil
        send(m.target, 'fire.igniteRandomNodeMinimal()')
      end
    end
    if m.step == 1 and ctx.dist < 30 then return advance(m, 'En el lugar. Fuego visible.') end
    if m.step == 2 and m.spraying then
      -- A fire hose reaches roughly 20-30 m.
      if hold(m, ctx, ctx.dist < 25 and ctx.mySpeed < 1, 10) then
        m.spraying = false
        send(m.target, 'fire.extinguishVehicle()')
        return advance(m, 'Fuego extinguido.')
      end
    end
  end,
  action = function(m, name)
    if m.step == 2 and name == 'extinguish' then
      m.spraying = true
      note('Aplicando agua... mantente cerca y parado.')
    elseif m.step == 3 and name == 'secure' then
      return advance(m)
    end
  end,
  timeout = function(m)
    -- Left too long it spreads: that is the failure.
    if m.target then send(m.target, 'fire.igniteRandomNode()') end
  end,
  cleanup = function(m)
    if m.target then send(m.target, 'fire.extinguishVehicleSlowly()') end
    unstage(m)
  end
}

DEFS.spill = {
  roles = {fire = true}, weight = 2, time = 300, reward = 350,
  title = 'Derrame en la calzada',
  brief = 'Derrame de combustible tras un choque. Acude, balizala zona y mantenla cortada.',
  setup = function(m)
    local _, me = player()
    m.point = me and me.pos and pointFrom(me.pos, 300, 900)
    if not m.point then return false end
    m.steps = {{text = 'Llega al lugar'}, {text = 'Baliza la zona'},
               {text = 'Manten la zona cerrada'}}
    return true
  end,
  dest = function(m) return m.point end,
  tick = function(m, ctx)
    local near = ctx.me:distance(m.point)
    if m.step == 1 and near < 30 then return advance(m, 'En el lugar.') end
    if m.step == 3 and hold(m, ctx, near < 45 and ctx.lights, 25) then
      return advance(m, 'Calzada limpia.')
    end
  end,
  action = function(m, name)
    if m.step == 2 and name == 'secure' then return advance(m) end
  end
}

M.DEFS = DEFS

-- ---------------------------------------------------------------- lifecycle

local function roleKey(r)
  if r == 'medic' or r == 'fire' or r == 'swat' or r == 'undercover' then return r end
  return 'police'
end

local function chooseDef()
  local key = roleKey(role)
  local total, list = 0, {}
  local carNear = {}
  for id, def in pairs(DEFS) do
    if def.roles[key] then
      -- A call built around a civilian is only offered while there is one to build it on.
      local ok = true
      if def.band then
        local b = def.band[1] .. ':' .. def.band[2]
        if carNear[b] == nil then carNear[b] = pickCivilian(def.band[1], def.band[2]) ~= nil end
        ok = carNear[b]
      end
      if ok then
        total = total + def.weight
        list[#list + 1] = id
      end
    end
  end
  if total == 0 then return nil end
  table.sort(list)
  local r = random() * total
  for _, id in ipairs(list) do
    r = r - DEFS[id].weight
    if r <= 0 then return id end
  end
  return list[#list]
end

local function clearNav()
  if navOn and core_groundMarkers and core_groundMarkers.resetAll then
    pcall(core_groundMarkers.resetAll)
  end
  navOn = false
end

local function scheduleNext()
  offerTimer = OFFER_GAP_MIN + random() * (OFFER_GAP_MAX - OFFER_GAP_MIN)
end

local function finish(ok, reason)
  local m = M.current
  if not m then return end
  local def = DEFS[m.id]
  if not ok and def.timeout and reason == 'tiempo' then pcall(def.timeout, m) end
  if def.cleanup then pcall(def.cleanup, m) end
  clearNav()

  local points = 0
  if ok then
    local _, _, me = player()
    local dmg = me and me.damage or 0
    local damageTaken = math.max(0, dmg - (m.startDamage or dmg))
    points = def.reward + floor(math.max(0, m.time) * 2) - floor(damageTaken * 0.05)
    if m.usedLights then points = points + 50 end
    if points < 50 then points = 50 end
    M.stats.done = M.stats.done + 1
  else
    points = reason == 'abandonada' and -100 or 0
    M.stats.failed = M.stats.failed + 1
  end
  M.stats.score = M.stats.score + points
  M.last = {ok = ok, title = def.title, points = points, reason = reason}
  note(ok and format('Mision completada: %s, %d puntos.', def.title, points)
    or format('Mision no completada: %s (%s).', def.title, reason or '?'))
  if ui_message then
    ui_message(ok and format('Mision completada: %s  +%d', def.title, points)
      or format('Mision no completada: %s', def.title), 5, 'trafficAI')
  end
  M.current = nil
  scheduleNext()
end

function M.accept()
  local o = M.offer
  if not o or M.current then return end
  M.offer = nil
  local def = DEFS[o.id]
  local m = {id = o.id, step = 1, time = def.time, steps = {}}
  local ok, res = pcall(def.setup, m)
  if not ok or not res then
    note('El aviso ya no esta disponible. Central busca otro.')
    if m.target then
      holds.release(m.target)
      protect(m.target, false)
    end
    offerTimer = 6
    return
  end
  local _, _, me = player()
  m.startDamage = me and me.damage or 0
  M.current = m
  navTimer = 0
  note(format('Aviso aceptado: %s.', def.title))
end

function M.decline()
  if not M.offer then return end
  M.offer = nil
  note('Aviso rechazado.')
  offerTimer = 15
end

function M.abandon()
  if M.current then finish(false, 'abandonada') end
end

-- Called by the duty console whenever the player does something to a vehicle.
function M.onAction(name, targetId)
  local m = M.current
  if not m then return end
  local def = DEFS[m.id]
  if not def.action then return end
  if m.target and targetId and targetId ~= m.target and name ~= 'secure' then return end
  local res = def.action(m, name)
  if res == 'done' then finish(true) end
end

function M.plateInfo(id)
  local m = M.current
  if m and m.target == id and m.stolen then return 'consta denuncia de robo. Proceder a la detencion.' end
  return nil
end

function M.breathResult(id)
  local m = M.current
  if m and m.target == id and m.forcedBreath then return m.forcedBreath end
  return nil
end

function M.isTarget(id)
  return M.current ~= nil and M.current.target == id
end

-- Where the navigation should point right now.
function M.navPos()
  local m = M.current
  if not m then return nil end
  local def = DEFS[m.id]
  if def.dest then
    local p = def.dest(m)
    if p then return p end
  end
  return (targetPos(m))
end

local function refreshNav(me)
  local pos = M.navPos()
  if not pos then clearNav() return end
  if me.pos:distance(pos) < NAV_NEAR then clearNav() return end
  if not core_groundMarkers and extensions and extensions.load then
    pcall(extensions.load, 'core_groundMarkers')
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    local ok = pcall(core_groundMarkers.setPath, vec3(pos), {step = 3, clearPathOnReachingTarget = false})
    navOn = ok
  end
end

function M.update(dt, dutyRole)
  if dutyRole ~= role then
    role = dutyRole or 'none'
    if role == 'none' then
      if M.current then finish(false, 'fuera de servicio') end
      M.offer = nil
      offerTimer = OFFER_FIRST
      return
    end
    offerTimer = OFFER_FIRST
  end
  if role == 'none' then return end

  timer = timer + dt
  if timer < TICK then return end
  elapsed = timer
  timer = 0

  local pid, me, meT = player()
  if not me or not me.pos then return end

  -- Waiting for a call, or one waiting for an answer.
  if not M.current then
    if M.offer then
      M.offer.life = M.offer.life - elapsed
      if M.offer.life <= 0 then
        M.offer = nil
        note('Aviso reasignado a otra unidad.')
        scheduleNext()
      end
      return
    end
    offerTimer = offerTimer - elapsed
    if offerTimer <= 0 then
      local id = chooseDef()
      if id then
        M.offer = {id = id, title = DEFS[id].title, brief = DEFS[id].brief, life = OFFER_LIFE,
                   time = DEFS[id].time, reward = DEFS[id].reward}
        note(format('Central: %s.', DEFS[id].title))
      else
        scheduleNext()
      end
    end
    return
  end

  local m = M.current
  local def = DEFS[m.id]

  if targetGone(m) then
    if def.cleanup then pcall(def.cleanup, m) end
    m.target = nil
    clearNav()
    M.current = nil
    note('Aviso cancelado: el vehiculo ya no esta en la zona.')
    scheduleNext()
    return
  end

  m.time = m.time - elapsed
  if m.time <= 0 then
    finish(false, 'tiempo')
    return
  end

  local st = me.states
  local lights = st and st.lightbar and st.lightbar > 0 or false
  if lights then m.usedLights = true end
  local tpos, tv = targetPos(m)
  local ctx = {
    me = me.pos, mySpeed = (meT and meT.speed) or (me.vel and me.vel:length()) or 0,
    lights = lights, dist = tpos and me.pos:distance(tpos) or 1e9,
    tSpeed = tv and tv.speed or nil
  }
  local ok, res = pcall(def.tick, m, ctx)
  if ok and res == 'done' then finish(true) return end

  navTimer = navTimer - elapsed
  if navTimer <= 0 then
    navTimer = NAV_REFRESH
    refreshNav(me)
  end
end

function M.reset()
  if M.current then
    local def = DEFS[M.current.id]
    if def.cleanup then pcall(def.cleanup, M.current) end
  end
  clearNav()
  M.current, M.offer, M.last = nil, nil, nil
  role = 'none'
  timer, offerTimer, navTimer = 0, OFFER_FIRST, 0
end

return M
