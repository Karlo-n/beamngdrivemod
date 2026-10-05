local M = {}

local floor = math.floor
local format = string.format

-- The duty radio. Drawn with the engine's own ImGui from game-engine Lua, so it appears the
-- moment it is asked for. The HTML app route depended on the player's UI layout and, as the
-- log showed ("consola pedida"), the request went out and nothing was ever drawn.

M.visible = false

local im
local open

local ACCENT = {
  police = {0.26, 0.52, 0.88}, swat = {0.56, 0.44, 0.86}, undercover = {0.58, 0.63, 0.68},
  medic = {0.22, 0.74, 0.50}, fire = {0.88, 0.36, 0.24}
}
local ROLE_NAME = {
  police = 'Policia', swat = 'Unidad blindada', undercover = 'Unidad camuflada',
  medic = 'Servicio medico', fire = 'Bomberos'
}
local STATUS_NAME = {available = 'Disponible', disponible = 'Disponible'}

-- need: 't' needs a marked vehicle, 's' needs it stopped. wide spans both columns.
local ACTIONS = {
  police = {
    {'Marcar cercano', 'selectNearest'}, {'Matricula', 'runPlate', need = 't'},
    {'Dar el alto', 'signalStop', need = 't'}, {'Registrar', 'searchVehicle', need = 's'},
    {'Alcoholemia', 'breathTest', need = 's'}, {'Multar', 'issueTicket', need = 's'},
    {'Advertir', 'warnDriver', need = 's'}, {'Detener', 'arrest', need = 's'},
    {'Dejar ir', 'releaseStop', need = 't'}, {'Pedir apoyo', 'callBackup'},
    {'Balizar zona', 'secureScene', wide = true}
  },
  swat = {
    {'Marcar cercano', 'selectNearest'}, {'Matricula', 'runPlate', need = 't'},
    {'Dar el alto', 'signalStop', need = 't'}, {'Detener', 'arrest', need = 's'},
    {'Montar control', 'roadblock'}, {'Perimetro', 'perimeter'},
    {'Pedir apoyo', 'callBackup'}, {'Balizar zona', 'secureScene'}
  },
  undercover = {
    {'Marcar cercano', 'selectNearest'}, {'Matricula', 'runPlate', need = 't'},
    {'Seguir sin luces', 'tail', need = 't'}, {'Identificarse', 'blowCover'},
    {'Dar el alto', 'signalStop', need = 't'}, {'Registrar', 'searchVehicle', need = 's'},
    {'Alcoholemia', 'breathTest', need = 's'}, {'Detener', 'arrest', need = 's'}
  },
  medic = {
    {'Marcar cercano', 'selectNearest'}, {'Atender', 'treat', need = 't'},
    {'Trasladar', 'transport'}, {'Balizar zona', 'secureScene'},
    {'Pedir bomberos', 'requestFire'}, {'Pedir policia', 'callBackup'}
  },
  fire = {
    {'Marcar cercano', 'selectNearest'}, {'Sofocar', 'extinguish', need = 't'},
    {'Balizar zona', 'secureScene'}, {'Pedir sanitarios', 'requestMedic'},
    {'Pedir policia', 'callBackup'}
  }
}

local function col(r, g, b, a) return im.ImVec4(r, g, b, a or 1) end

local C = {}
local function palette()
  C.text = col(0.90, 0.92, 0.94)
  C.dim = col(0.52, 0.57, 0.63)
  C.faint = col(0.30, 0.34, 0.39)
  C.good = col(0.32, 0.78, 0.54)
  C.warn = col(0.93, 0.70, 0.28)
  C.bad = col(0.91, 0.42, 0.38)
end

-- ImGui's Text and TextColored are printf underneath; free text must not carry a bare %.
local function safe(s)
  return (tostring(s):gsub('%%', '%%%%'))
end

local function ctext(c, s) im.TextColored(c, safe(s)) end
local function label(s) ctext(C.dim, s) end

local function clock(sec)
  sec = sec > 0 and sec or 0
  return format('%02d:%02d', floor(sec / 60), floor(sec % 60))
end

local function availWidth()
  local w = im.GetContentRegionAvailWidth and im.GetContentRegionAvailWidth()
  if type(w) ~= 'number' and im.GetContentRegionAvail then
    local v = im.GetContentRegionAvail()
    w = v and v.x
  end
  if type(w) ~= 'number' or w < 120 then w = 340 end
  return w
end

local function lineHeight()
  local h = im.GetTextLineHeight and im.GetTextLineHeight()
  return type(h) == 'number' and h or 14
end

-- A small filled dot at the start of the line, then the text continues beside it.
local function dot(c, radius)
  local h = lineHeight()
  local p = im.GetCursorScreenPos and im.GetCursorScreenPos()
  local dl = im.GetWindowDrawList and im.GetWindowDrawList()
  if p and dl and type(p.x) == 'number' then
    im.ImDrawList_AddCircleFilled(dl, im.ImVec2(p.x + 5, p.y + h * 0.5 + 1), radius or 3.5,
      im.GetColorU322(c))
  end
  im.Dummy(im.ImVec2(12, h))
  im.SameLine()
end

-- Vertical accent bar beside the header block.
local function bar(c, height)
  local p = im.GetCursorScreenPos and im.GetCursorScreenPos()
  local dl = im.GetWindowDrawList and im.GetWindowDrawList()
  if p and dl and type(p.x) == 'number' then
    im.ImDrawList_AddRectFilled(dl, im.ImVec2(p.x, p.y), im.ImVec2(p.x + 3, p.y + height),
      im.GetColorU322(c), 1.5)
  end
end

-- Where the objective is relative to the car: distance plus a plain-words direction.
local function bearing(pos)
  local id = be:getPlayerVehicleID(0)
  local o = map.objects and map.objects[id]
  if not o or not o.pos or not o.dirVec or not pos then return '' end
  local dx, dy = pos.x - o.pos.x, pos.y - o.pos.y
  local dist = math.sqrt(dx * dx + dy * dy)
  local fx, fy = o.dirVec.x, o.dirVec.y
  local fl = math.sqrt(fx * fx + fy * fy)
  if fl < 1e-3 or dist < 1 then return format('%d m', floor(dist)) end
  fx, fy = fx / fl, fy / fl
  local fwd = (dx * fx + dy * fy) / dist
  local right = (dx * fy - dy * fx) / dist
  local where
  if fwd > 0.7 then where = 'delante'
  elseif fwd < -0.7 then where = 'detras'
  elseif right > 0 then where = 'a la derecha'
  else where = 'a la izquierda' end
  if dist >= 1000 then return format('%.1f km, %s', dist / 1000, where) end
  return format('%d m, %s', floor(dist), where)
end

local function header(duty, accent)
  local a = col(accent[1], accent[2], accent[3])
  local h = lineHeight()
  bar(a, h * 2 + 6)
  im.Indent(10)
  ctext(C.text, duty.callsign ~= '' and duty.callsign or 'En servicio')

  local raw = duty.status or 'available'
  local name = STATUS_NAME[raw] or (raw:sub(1, 1):upper() .. raw:sub(2))
  local busy = STATUS_NAME[raw] == nil
  local size = im.CalcTextSize and im.CalcTextSize(name)
  local ww = im.GetWindowWidth and im.GetWindowWidth()
  im.SameLine()
  if size and type(size.x) == 'number' and type(ww) == 'number' then
    im.SetCursorPosX(ww - size.x - 34)
  end
  dot(busy and C.warn or C.good, 4)
  ctext(busy and C.warn or C.good, name)

  label(ROLE_NAME[duty.role] or '')
  im.Unindent(10)
end

local function missionPanel(missions, accent)
  local a = col(accent[1], accent[2], accent[3])
  local m, offer = missions.current, missions.offer

  if offer then
    ctext(C.warn, 'Aviso entrante')
    im.SameLine()
    label('caduca en ' .. clock(offer.life))
    ctext(C.text, offer.title)
    im.PushTextWrapPos(0)
    label(offer.brief)
    im.PopTextWrapPos()
    label(format('Tiempo %s    Recompensa %d', clock(offer.time), offer.reward))
    local w = (availWidth() - 8) * 0.5
    im.PushStyleColor2(im.Col_Button, col(accent[1] * 0.6, accent[2] * 0.6, accent[3] * 0.6))
    if im.Button('Aceptar##offer', im.ImVec2(w, 0)) then pcall(missions.accept) end
    im.PopStyleColor()
    im.SameLine()
    if im.Button('Rechazar##offer', im.ImVec2(w, 0)) then pcall(missions.decline) end
    return
  end

  if not m then
    label('Sin avisos por ahora')
    local last = missions.last
    if last then
      ctext(last.ok and C.good or C.bad, format('%s: %s', last.title,
        last.ok and format('completada, %d puntos', last.points) or 'no completada'))
    end
    return
  end

  local def = missions.DEFS[m.id]
  ctext(C.text, def.title)
  im.SameLine()
  ctext(m.time < 30 and C.bad or C.dim, clock(m.time))
  for i, s in ipairs(m.steps) do
    if s.done then
      dot(C.good)
      label(s.text)
    elseif i == m.step then
      dot(a, 4)
      ctext(C.text, s.text)
    else
      dot(C.faint)
      ctext(C.faint, s.text)
    end
  end
  local where = missions.navPos()
  if where then label('Objetivo a ' .. bearing(where)) end
  if m.progress then
    im.PushStyleColor2(im.Col_PlotHistogram, a)
    im.ProgressBar(math.min(1, m.progress), im.ImVec2(-1, 6), '')
    im.PopStyleColor()
  end
  if im.Button('Abandonar mision##mission', im.ImVec2(-1, 0)) then pcall(missions.abandon) end
end

local function targetPanel(snap)
  local t = snap.target
  if not t then
    label('Ningun vehiculo marcado')
    return
  end
  ctext(C.text, t.name)
  if t.stopped then
    im.SameLine()
    ctext(C.good, 'detenido')
  end
  local over = t.limit > 0 and t.speed > t.limit
  ctext(over and C.bad or C.dim, format('%d km/h (limite %d)', t.speed, t.limit))
  im.SameLine()
  label(format('   danos %d', t.damage))
  if t.wanted then ctext(C.bad, 'En busca y captura') end
  if t.offenses and #t.offenses > 0 then
    im.PushTextWrapPos(0)
    ctext(C.warn, 'Infracciones: ' .. table.concat(t.offenses, ', '))
    im.PopTextWrapPos()
  end
  if t.searched then label('Registro: ' .. t.searched) end
end

local function actionGrid(duty, snap, accent)
  local list = ACTIONS[duty.role] or ACTIONS.police
  local full = availWidth()
  local half = (full - 8) * 0.5
  local hasTarget = snap.target ~= nil
  local stopped = hasTarget and snap.target.stopped
  local column = 0
  im.PushStyleColor2(im.Col_Button, col(0.14, 0.17, 0.20))
  im.PushStyleColor2(im.Col_ButtonHovered, col(accent[1] * 0.45, accent[2] * 0.45, accent[3] * 0.45))
  im.PushStyleColor2(im.Col_ButtonActive, col(accent[1] * 0.65, accent[2] * 0.65, accent[3] * 0.65))
  for i, act in ipairs(list) do
    local disabled = (act.need == 't' and not hasTarget) or (act.need == 's' and not stopped)
    if act.wide then
      if column == 1 then column = 0 end
    elseif column == 1 then
      im.SameLine()
    end
    im.BeginDisabled(disabled)
    local clicked = im.Button(act[1] .. '##act' .. i, im.ImVec2(act.wide and full or half, 0))
    im.EndDisabled()
    if clicked and duty[act[2]] then
      local ok, err = pcall(duty[act[2]])
      if not ok then log('E', 'trafficAI', 'radio: ' .. act[2] .. ': ' .. tostring(err)) end
    end
    column = act.wide and 0 or (1 - column)
  end
  im.PopStyleColor(3)
end

local function logPanel(duty)
  local n = math.min(#duty.log, 6)
  if n == 0 then
    label('Radio en silencio')
    return
  end
  im.PushTextWrapPos(0)
  for i = 1, n do
    ctext(i == 1 and C.text or C.dim, duty.log[i])
  end
  im.PopTextWrapPos()
end

function M.draw(duty, missions)
  if not M.visible or duty.role == 'none' then return end
  if not im then
    im = ui_imgui
    if not im then return end
    open = im.BoolPtr(true)
    palette()
  end
  open[0] = true

  local accent = ACCENT[duty.role] or ACCENT.police
  local snap = duty.snapshot()

  im.SetNextWindowPos(im.ImVec2(24, 150), im.Cond_FirstUseEver)
  im.SetNextWindowSize(im.ImVec2(360, 620), im.Cond_FirstUseEver)
  im.PushStyleVar1(im.StyleVar_WindowRounding, 6)
  im.PushStyleVar1(im.StyleVar_FrameRounding, 4)
  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(14, 12))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(8, 7))
  im.PushStyleColor2(im.Col_WindowBg, col(0.07, 0.08, 0.10, 0.95))
  im.PushStyleColor2(im.Col_TitleBg, col(0.07, 0.08, 0.10, 1))
  im.PushStyleColor2(im.Col_TitleBgActive, col(0.10, 0.12, 0.15, 1))
  im.PushStyleColor2(im.Col_Border, col(0.20, 0.23, 0.27, 1))
  im.PushStyleColor2(im.Col_Separator, col(0.17, 0.20, 0.24, 1))

  local failure
  if im.Begin('Radio de servicio##trafficAI', open, im.WindowFlags_NoCollapse) then
    local ok, err = pcall(function()
      header(duty, accent)
      im.Separator()
      missionPanel(missions, accent)
      im.Separator()
      targetPanel(snap)
      im.Separator()
      actionGrid(duty, snap, accent)
      im.Separator()
      logPanel(duty)
      im.Separator()
      label(format('Misiones %d completadas, %d fallidas    %d puntos', missions.stats.done,
        missions.stats.failed, missions.stats.score))
      label(format('Multas %d    Importe %d', snap.fineCount or 0, snap.fines or 0))
    end)
    if not ok then failure = err end
  end
  im.End()

  im.PopStyleColor(5)
  im.PopStyleVar(4)

  if not open[0] then M.visible = false end
  -- Raised only once the window and the style stack are closed again.
  if failure then error(failure, 0) end
end

function M.toggle()
  M.visible = not M.visible
end

return M
