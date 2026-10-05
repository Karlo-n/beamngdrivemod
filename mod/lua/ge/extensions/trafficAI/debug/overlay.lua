local M = {}

local format = string.format
local sqrt = math.sqrt

local driver = require('trafficAI/core/driver')
local perception = require('trafficAI/environment/perception')
local policeTactics = require('trafficAI/behaviors/policeTactics')
local policeStop = require('trafficAI/behaviors/policeStop')
local policeEvents = require('trafficAI/behaviors/policeEvents')
local emergency = require('trafficAI/environment/emergency')
local manhunt = require('trafficAI/behaviors/manhunt')
local parking = require('trafficAI/behaviors/parking')
local trafficBreak = require('trafficAI/behaviors/trafficBreak')
local fines = require('trafficAI/behaviors/fines')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')

local REFRESH = 0.5
local MAX_DIST_SQ = 80 * 80
local MAX_SHOWN = 6
local MAX_DETAIL = 3

local LC_PHASE = {[0] = 'idle', 'want', 'check', 'exec', 'cool', 'intermitente'}
local SQ_PHASE = {[0] = '-', 'pasa', 'vuelve'}
local OT_PHASE = {[0] = '-', 'sale', 'ADELANTA', 'vuelve', 'ABORTA'}
local PU_PHASE = {[0] = 'persigue', 'EMBISTE', 'SE LE CRUZA'}
local WT_MODE = {[0] = '', ' [testigo: parado]', ' [testigo: para y avanza]', ' [testigo: lento]'}
local WARN_STYLE = {[0] = 'nada', 'claxon', 'rafagas', 'claxon+rafagas'}
local STOP_PHASE = {[0] = '-', 'observa', 'PARA', 'escolta', 'parados', 'ESCALA'}
local REAR_RESP = {[0] = '', ' | atras: ignora', ' | atras: CEDE', ' | atras: molesto',
                   ' | atras: FRENAZO'}

M.enabled = false

local palette, colText, colBg
local textPos = vec3()

local shown, shownCount = {}, 0
local cards, cardCount = {}, 0
local timer = 0

for i = 1, MAX_SHOWN do
  shown[i] = {id = 0, dist = 0}
  cards[i] = {id = 0, state = '', man = '', dist = 0, lines = {'', '', '', '', '', '', '', ''}, count = 0, col = nil}
end

local stateGroup = {
  normal = 1, recovering = 1, amazed = 1, cautious = 1, tired = 1,
  frustrated = 2, hurried = 2, distracted = 2, confused = 2, lost = 2, drowsy = 2, drunk = 2, asleep = 3,
  aggressive = 3, angry = 3,
  nervous = 4, scared = 4, panic = 4
}

-- ColorF/ColorI allocate userdata, so the palette is built once on first draw and reused.
local function ensurePalette()
  if palette then return end
  colText = ColorF(0.82, 0.82, 0.82, 1)
  colBg = ColorI(0, 0, 0, 190)
  palette = {
    ColorF(0.65, 0.95, 0.70, 1),
    ColorF(1.00, 0.85, 0.35, 1),
    ColorF(1.00, 0.42, 0.35, 1),
    ColorF(0.55, 0.85, 1.00, 1)
  }
end

local function considerVehicle(id, dist)
  if shownCount < MAX_SHOWN then
    shownCount = shownCount + 1
  elseif dist >= shown[shownCount].dist then
    return
  end
  local i = shownCount
  while i > 1 and shown[i - 1].dist > dist do
    shown[i].id, shown[i].dist = shown[i - 1].id, shown[i - 1].dist
    i = i - 1
  end
  shown[i].id, shown[i].dist = id, dist
end

-- Why a stopped car is stopped, in a word. Standing traffic with no reason is the bug; with
-- a reason it is behaviour, and from the driver's seat the two look the same.
local function stoppedReason(tveh, d)
  local id = tveh.id
  if holds.isHeld(id) then return 'retenido: alto o mision' end
  if parking.active[id] then return parking.label(id) or 'aparcando' end
  if d.rs and d.rs.state == 1 then return format('recado (%s) %.0fs', d.rs.reason or '?', d.rs.timer) end
  if d.crashState > 0 then return 'tras un choque' end
  if d.ey.active and d.ey.kind == 'crossing' then return 'cede el cruce a una emergencia' end
  local pm = d.pm
  if pm.signalDist >= 0 and pm.signalDist < 45 then return 'semaforo o stop' end
  if d.sh.zone then return 'espera su turno' end
  if d.cf.leaderId ~= 0 and d.cf.gap >= 0 and d.cf.gap < 9 then return 'en cola' end
  local t = trafficAI_main and trafficAI_main.stillSeconds and trafficAI_main.stillSeconds(id) or 0
  return format('SIN MOTIVO %.0fs', t)
end

local function buildCard(card, tveh, d, dist, detailed)
  local p, lines = d.p, card.lines
  card.id, card.state, card.man, card.dist = d.id, d.state, d.maneuver, dist
  card.col = palette[stateGroup[d.state] or 1]

  lines[1] = format('#%d  %s%s', d.id, d.typeLabel,
    d.mood ~= 'none' and format('  (%s)', d.mood) or '')
  local flag = ''
  if d.pu.mode ~= 0 then
    flag = d.pu.mode == 2 and '  [SE FUGA]'
      or format('  [%s #%d]', PU_PHASE[d.pu.phase] or '?', d.pu.targetId)
  elseif d.crashState > 0 then
    flag = format('  [CHOQUE %s sev %.2f]', d.crash.outcome, d.crash.severity)
  elseif d.yieldTimer > 0 then
    flag = '  [cede control]'
  elseif d.itm.active then
    flag = d.itm.phase == 1 and '  [presiona]' or '  [se descuelga]'
  end
  flag = flag .. (WT_MODE[d.wt.mode] or '')
  if d.ey.active and d.ey.kind == 'crossing' then
    flag = flag .. format('  [CEDE EN EL CRUCE %.0fm]', d.ey.dist)
  elseif d.ey.active then
    flag = flag .. format('  [PASILLO %s %.0fm%s]',
      d.ey.side > 0 and 'al arcen' or 'al centro', d.ey.dist,
      d.ey.blocked and ' BLOQUEADO' or '')
  end
  if d.hr.phase == 2 then flag = flag .. format('  [CIERRA PASO #%d]', d.hr.targetId)
  elseif d.hr.phase == 1 then flag = flag .. '  [vigila fuga]' end
  if d.dr.letIn then flag = flag .. '  [deja entrar]' end
  if (tveh.speed or 0) < 0.6 then
    flag = flag .. '  [PARADO: ' .. stoppedReason(tveh, d) .. ']'
  end
  if d.at.grudge > 0.3 then flag = flag .. '  [RENCOR al de delante]' end
  if d.drunk then flag = flag .. '  [EBRIO]' end
  lines[2] = format('%s %.1fs   frust %.0f%%  estres %.0f%%  prisa %.0f%%   agg %.2f%s',
    d.state, d.stateTimer > 0 and d.stateTimer or 0, d.frustration * 100, d.at.stress * 100,
    d.at.pressure * 100, driver.aggression(d), flag)

  if not detailed then
    card.count = 2
    return
  end

  lines[3] = format('pat %.2f  agg %.2f  pru %.2f  con %.2f  tol %.2f  tem %.2f',
    p.patience, p.aggression, p.prudence, p.confidence, p.tolerance, p.temper)
  lines[4] = format('anticipa %.0f%%  frenada %.1f m/s2  conoce la zona %.0f%%  aviso: %s  %s',
    d.d.anticipation * 100, d.d.comfortDecel, d.d.familiarity * 100,
    WARN_STYLE[d.d.warnStyle] or '?', d.d.swerver and 'esquiva' or 'solo frena')

  -- Gap and IDM values come straight off the blackboard the behaviours already filled.
  local cf, lc = d.cf, d.lc
  local limit = tveh.tracking and tveh.tracking.speedLimit or 0
  lines[5] = format('%.0f / %.0f km/h   tgt %.0f   %s',
    tveh.speed * 3.6, limit * 3.6, cf.targetSpeed * 3.6, d.maneuver)
  local sq = d.sq
  if d.sh.zone then
    flag = flag .. (d.sh.crossing and '  [PASA SU TURNO]'
      or format('  [espera turno %.0fs%s]', d.sh.waitTime, d.sh.jumped and ' SE CUELA' or ''))
    lines[2] = lines[2] .. ''
  end
  lines[6] = format('gap %s / %.1f m   a %+.2f   lc %s   sq %s%s',
    cf.gap >= 0 and format('%.1f', cf.gap) or '--', cf.desiredGap, cf.accel,
    LC_PHASE[lc.phase] or '?', SQ_PHASE[sq.phase] or '?',
    sq.active and format(' hueco %.1fm', sq.clearance) or '')
  local ot = d.ot
  lines[6] = lines[6] .. (ot.phase ~= 0 and format('   ot %s', OT_PHASE[ot.phase] or '?')
    or format('   ot %s%s%s', d.d.overtaker and format('%.0f%%', d.d.overtakeEagerness * 100) or 'NUNCA',
      ot.urge > 0 and format(' ganas %.1f/%.1f', ot.urge, d.d.overtakeWait) or '',
      (ot.reject ~= '' and ot.reject) and format(' [%s]', ot.reject) or ''))

  local pm = d.pm
  local ev = d.ev
  lines[7] = format('lider #%d  rel %+.1f m/s  decel %+.1f  vecinos %d%s%s',
    cf.leaderId, pm.leadRel, pm.leadDecel, pm.neighbours,
    REAR_RESP[d.dr.response] or '',
    ev.active and format('   AMENAZA #%d ttc %.1fs %s', ev.threatId, ev.ttc,
      ev.level == 2 and (d.d.swerver and 'ESQUIVA' or 'FRENA') or 'avisa') or '')
  lines[8] = format('carril dst F%s R%s %s   semaforo %s',
    pm.tgtFront >= 0 and format('%.0f', pm.tgtFront) or '-',
    pm.tgtRear >= 0 and format('%.0f', pm.tgtRear) or '-',
    pm.tgtSafe < 0 and '?' or (pm.tgtSafe == 1 and 'LIBRE' or 'ocupado'),
    pm.signalDist >= 0 and format('%.0fm %s', pm.signalDist, perception.ACTION_NAME[pm.signalAction] or '?') or '--')
  card.count = 8
end

local function refresh(traffic, drivers, camPos)
  shownCount = 0
  for id, tveh in pairs(traffic) do
    if drivers[id] and units.alive(tveh) and tveh.pos then
      local dist = tveh.pos:squaredDistance(camPos)
      if dist < MAX_DIST_SQ then considerVehicle(id, dist) end
    end
  end

  cardCount = 0
  for i = 1, shownCount do
    local id = shown[i].id
    local tveh, d = traffic[id], drivers[id]
    if tveh and d then
      cardCount = cardCount + 1
      buildCard(cards[cardCount], tveh, d, sqrt(shown[i].dist), i <= MAX_DETAIL)
    end
  end
end

function M.render(dt, drivers)
  if not M.enabled then return end
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  if not traffic then return end
  ensurePalette()

  local camPos = core_camera.getPosition()
  timer = timer - dt
  local rebuild = timer <= 0

  if not rebuild then
    for i = 1, cardCount do
      local d = drivers[cards[i].id]
      if d and (d.state ~= cards[i].state or d.maneuver ~= cards[i].man) then
        rebuild = true
        break
      end
    end
  end

  if rebuild then
    timer = REFRESH
    refresh(traffic, drivers, camPos)
  end

  -- Patrol cars are not ours, so they get their lines drawn straight from the police tables.
  for pid, role in pairs(policeTactics.roles) do
    local tveh = traffic[pid]
    if tveh and tveh.pos then
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 2.4
      local hunt = manhunt.label(pid) or trafficBreak.label(pid) or policeTactics.label(pid)
      debugDrawer:drawTextAdvanced(textPos,
        'POLICIA: ' .. role .. (hunt and ('  ' .. hunt) or ''), colText, true, false, colBg)
    end
  end

  -- Civilians on their way to a parking bay.
  for vid in pairs(parking.active) do
    local tveh = traffic[vid]
    if tveh and tveh.pos then
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 2.4
      debugDrawer:drawTextAdvanced(textPos, parking.label(vid) or '', colText, true, false, colBg)
    end
  end

  -- Ambulances and fire engines are not ours either, so they get their own line.
  for eid in pairs(emergency.units) do
    local tveh = traffic[eid]
    if tveh and tveh.pos then
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 2.6
      debugDrawer:drawTextAdvanced(textPos, string.upper(emergency.label(eid) or ''),
        colText, true, false, colBg)
      local inc = emergency.incident
      if inc and emergency.onCall(eid) then
        textPos.z = textPos.z - 0.35
        debugDrawer:drawTextAdvanced(textPos, 'aviso: ' .. inc.kind, colText, true, false, colBg)
      end
    end
  end

  local eventLabel = policeEvents.label()
  for pid, s in pairs(policeStop.stops) do
    local tveh = traffic[pid]
    if tveh and tveh.pos then
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 3.0
      debugDrawer:drawTextAdvanced(textPos, format('PARADA %s: %s  paciencia %.0f/%.0f s%s',
        STOP_PHASE[s.phase] or '?', s.reason, s.patience, s.maxPatience,
        s.ahead and '  [delante]' or ''), colText, true, false, colBg)
      textPos.z = textPos.z - 0.35
      local off = policeStop.officers[pid]
      if off then
        debugDrawer:drawTextAdvanced(textPos, format('agente: rigor %.2f  paciencia base %.0fs  %s%s',
          off.strictness, off.patience, off.bookish and 'multa facil' or 'suele avisar',
          off.chirpy and '  sirena corta' or ''), colText, true, false, colBg)
      end
      if s.ticketed then
        textPos.z = textPos.z - 0.35
        debugDrawer:drawTextAdvanced(textPos, s.warning and 'resultado: ADVERTENCIA'
          or format('resultado: MULTA %d  (sesion: %d en %d multas)', s.fine, fines.total, fines.count),
          colText, true, false, colBg)
      end
    end
  end

  if eventLabel then
    local cur = policeEvents.current
    local pid = cur and cur.state and cur.state.pid
    local tveh = pid and traffic[pid]
    if tveh and tveh.pos then
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 2.7
      debugDrawer:drawTextAdvanced(textPos, 'EVENTO: ' .. eventLabel, colText, true, false, colBg)
    end
  end

  -- Settles the lateral-sign question by counting, not by reading the source: cars driving
  -- normally are on their legal side, so sign(roadOffset) should equal legalSide.
  local agree, total, legal = 0, 0, 0
  for _, tveh in pairs(traffic) do
    local tr = tveh.tracking
    if units.ai(tveh) and tveh.state == 'active' and tr and tr.isOnRoad and not tr.isOneWay
      and (tveh.speed or 0) > 3 and tr.roadOffset and math.abs(tr.roadOffset) > 0.4 then
      total = total + 1
      legal = tr.legalSide or 0
      if (tr.roadOffset > 0) == (legal > 0) then agree = agree + 1 end
    end
  end
  if total > 0 then
    textPos:set(camPos)
    textPos.z = textPos.z - 1.2
    debugDrawer:drawTextAdvanced(textPos, format(
      'LADOS: legalSide=%d  coches con signo(roadOffset)==legalSide: %d/%d  -> positivo = %s',
      legal, agree, total, agree * 2 >= total and 'lado legal' or 'lado contrario'),
      colText, true, false, colBg)
  end

  for i = 1, cardCount do
    local card = cards[i]
    local tveh = traffic[card.id]
    if tveh and tveh.pos then
      -- Line spacing grows with distance to roughly cancel perspective shrink.
      local step = 0.30 + card.dist * 0.012
      textPos:set(tveh.pos)
      textPos.z = textPos.z + 1.9 + step * card.count
      for l = 1, card.count do
        debugDrawer:drawTextAdvanced(textPos, card.lines[l], l == 1 and card.col or colText, true, false, colBg)
        textPos.z = textPos.z - step
      end
    end
  end
end

function M.invalidate()
  cardCount, timer = 0, 0
end

function M.setEnabled(value)
  M.enabled = value and true or false
  if not M.enabled then
    cardCount, shownCount, timer = 0, 0, 0
  end
end

function M.toggle()
  M.setEnabled(not M.enabled)
  return M.enabled
end

return M
