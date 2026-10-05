local M = {}

M.dependencies = {'gameplay_traffic'}

local driver = require('trafficAI/core/driver')
local overlay = require('trafficAI/debug/overlay')
local perception = require('trafficAI/environment/perception')
local policeWatch = require('trafficAI/environment/policeWatch')
local policeTactics = require('trafficAI/behaviors/policeTactics')
local policeStop = require('trafficAI/behaviors/policeStop')
local policeEvents = require('trafficAI/behaviors/policeEvents')
local emergency = require('trafficAI/environment/emergency')
local places = require('trafficAI/environment/places')
local emergencyYield = require('trafficAI/behaviors/emergencyYield')
local fines = require('trafficAI/behaviors/fines')
local spikes = require('trafficAI/behaviors/spikes')
local wanted = require('trafficAI/behaviors/wanted')
local convoy = require('trafficAI/behaviors/convoy')
local shuttle = require('trafficAI/behaviors/shuttle')
local manhunt = require('trafficAI/behaviors/manhunt')
local trafficBreak = require('trafficAI/behaviors/trafficBreak')
local parking = require('trafficAI/behaviors/parking')
local logger = require('trafficAI/util/log')
local conditions = require('trafficAI/environment/conditions')

-- Loaded here rather than lazily by the role, so the first traffic spawn does not pay
-- for compiling them mid-session.
local baseBehavior = require('trafficAI/behaviors/baseBehavior')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')
require('trafficAI/behaviors/carFollowing')
require('trafficAI/behaviors/laneChange')
require('trafficAI/behaviors/squeeze')
require('trafficAI/behaviors/overtake')
require('trafficAI/behaviors/evasion')
require('trafficAI/behaviors/intimidation')
require('trafficAI/behaviors/driving')
require('trafficAI/behaviors/pursuit')
require('trafficAI/behaviors/hero')
require('trafficAI/behaviors/emergencyYield')

local ROLE = 'trafficAI'
local drivers = {}

M.enabled = true

local function attach(id)
  local data = gameplay_traffic.getTrafficData()
  local tveh = data and data[id]
  if not tveh or tveh.isPerson then return end

  -- The player's own vehicle is in the traffic table too. Giving it this role let crash and
  -- pursuit code call setAiMode on it, which handed the player's car to the AI mid-drive.
  if id == be:getPlayerVehicleID(0) then return end

  -- Police keep the stock role. It already implements pursuit, roadblocks and spike strips;
  -- replacing it was what stopped them reacting to anything.
  if tveh.autoRole == 'police' or tveh.roleName == 'police' then return end

  drivers[id] = driver.new(id)
  tveh.autoRole = ROLE
  tveh:setRole(ROLE)
end

-- Switching vehicles moves the player into a car that may already be under our control.
function M.onVehicleSwitched(oldId, newId)
  if not newId then return end
  local d = drivers[newId]
  if not d then return end
  drivers[newId] = nil
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  local tveh = data and data[newId]
  if tveh then
    tveh.autoRole = 'standard'
    tveh:setRole('standard')
  end
end

local function detachAll(restoreRole)
  if restoreRole then
    local data = gameplay_traffic and gameplay_traffic.getTrafficData()
    if data then
      for id in pairs(drivers) do
        local tveh = data[id]
        if tveh then
          tveh.autoRole = 'standard'
          tveh:setRole('standard')
        end
      end
    end
  end
  table.clear(drivers)
  overlay.invalidate()
end

function M.getDriver(id)
  return drivers[id]
end

function M.getAll()
  return drivers
end

function M.setEnabled(value)
  M.enabled = value and true or false
  if not M.enabled then detachAll(true) end
end

function M.toggleOverlay()
  local on = overlay.toggle()
  ui_message('TrafficAI debug overlay: ' .. (on and 'ON' or 'OFF'), 3, 'trafficAI')
  return on
end

function M.setOverlayEnabled(value)
  overlay.setEnabled(value)
end

-- Reported by the per-vehicle lights extension, which is the only place headlight state
-- exists as far as the game engine is concerned.
function M.onHighBeamFlash(id)
  if units.isEmergency(id) then emergencyYield.requestPassage(id) end
  policeWatch.onHighBeamFlash(id)
end

-- The world sweep used to run three times per frame. Vehicle roles only tick at 4 Hz, so
-- refreshing the shared view at 20 Hz is still four times more often than anything reads it.
local WORLD_PERIOD = 1 / 20
local worldTimer, worldAccum = 0, 0

-- A module that throws inside onPreRender throws every single frame, and BeamNG formats a
-- full stack traceback each time. That alone cost more frames than everything this mod does
-- put together, so a module that fails repeatedly is switched off instead of left screaming.
local FAIL_LIMIT = 5
local fails = {}
local dead = {}

local cleanups = {}

local function guard(name, fn, arg)
  if dead[name] then return end
  local ok, err = pcall(fn, arg)
  if ok then return end
  fails[name] = (fails[name] or 0) + 1
  if fails[name] == 1 then
    logger.e(string.format('%s fallo: %s', name, tostring(err)))
  end
  if fails[name] >= FAIL_LIMIT then
    dead[name] = true
    logger.e(string.format('%s desactivado tras %d fallos', name, FAIL_LIMIT))
    -- Put back anything it changed on the vehicles before walking away from it.
    if cleanups[name] then pcall(cleanups[name]) end
    ui_message('TrafficAI: modulo "' .. name .. '" desactivado por errores.', 8, 'trafficAI')
  end
end

cleanups.manhunt = manhunt.reset
cleanups.trafficBreak = trafficBreak.reset
cleanups.spikes = spikes.reset
cleanups.wanted = wanted.reset
cleanups.convoy = convoy.reset
cleanups.emergency = emergency.reset
cleanups.policeStop = policeStop.reset
cleanups.policeTactics = policeTactics.reset
cleanups.parking = parking.reset
cleanups.emergencyYield = emergencyYield.clear
cleanups.perception = function() perception.snapshot.n = 0 end

-- Several modules park a vehicle in a custom vars.aiMode so the stock roles leave it alone.
-- If the extension is reloaded, a module is disabled after repeated errors, or a vehicle is
-- recycled mid-manoeuvre, that vehicle is left in a mode nobody owns and never drives
-- normally again. This sweep hands any such car back.
local OURS = {block = true, ['break'] = true, search = true, parking = true, spikes = true}

local function claimed(id)
  return policeTactics.blockers[id] or parking.active[id] or manhunt.units[id]
    or trafficBreak.unitId == id or spikes.crewId == id
end

local function recover(reason)
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  if not data then return 0 end
  local n = 0
  for id, v in pairs(data) do
    if v.vars and OURS[v.vars.aiMode] and not claimed(id) then
      v.vars.aiMode = 'traffic'
      if units.ai(v) then v:setAiMode('traffic') end
      local obj = getObjectByID(id)
      if obj then
        obj:queueLuaCommand('ai.setSpeedMode("legal")')
        obj:queueLuaCommand('electrics.set_warn_signal(0)')
      end
      n = n + 1
    end
  end
  if n > 0 then logger.i(string.format('recuperados %d vehiculos sueltos (%s)', n, reason)) end
  return n
end
M.recover = recover
local recoverTimer = 0

-- Anti-freeze watchdog. Whatever pins a car at zero -- one of our speed caps, a stop point
-- the engine re-armed, a pull-over that never cleared -- a traffic car sitting still on a
-- live road for this long is a bug, not a decision. Clearing the stop point is safe for red
-- lights: ai.lua recomputes the signal stop from scratch every frame (trafficActions), so a
-- car genuinely waiting at a red simply re-arms it on the next tick.
local FREEZE_LIMIT = 12
local stillFor = {}
M.thawed = 0

-- Seconds a car has been sitting still without a known reason, for the overlay.
function M.stillSeconds(id)
  return stillFor[id] or 0
end

local lastThawLog = -100

local function thaw(id, v)
  -- One line in the log per rescue (at most every few seconds), with what the driver was
  -- doing: next time "cars just sit there" comes up, the log says which behaviour held them.
  local d = drivers[id]
  local now = os.clock()
  if d and now - lastThawLog > 4 then
    lastThawLog = now
    logger.i(string.format('descongelado #%d: estado=%s maniobra=%s choque=%s recado=%s pasillo=%s hueco=%s',
      id, tostring(d.state), tostring(d.maneuver), tostring(d.crashState),
      tostring(d.rs and d.rs.state), tostring(d.ey and d.ey.active), tostring(d.sq and d.sq.phase)))
  end
  local obj = getObjectByID(id)
  if obj then
    obj:queueLuaCommand('ai.setStopPoint()')
    obj:queueLuaCommand('ai.setPullOver(false)')
    obj:queueLuaCommand('ai.setSpeedMode("legal")')
  end
  local d = drivers[id]
  -- yieldTimer is the role's own escape hatch: while it runs, every behaviour stands down
  -- and the stock AI gets the car moving again.
  if d then d.yieldTimer, d.stuckTimer = 6, 0 end
  if v.vars then v.vars.aiMode = 'traffic' end
  if units.ai(v) then v:setAiMode('traffic') end
  M.thawed = M.thawed + 1
end

local function antifreeze(dt)
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  if not data then return end
  for id, v in pairs(data) do
    -- Parked and stopped cars are meant to be still; so is anyone being arrested.
    local allowed = parking.active[id] or policeStop.stops[id] or policeStop.active(id)
      or holds.isClaimed(id)
      or (v.pursuit and (v.pursuit.mode or 0) > 0)
    if units.ai(v) and v.state == 'active' and (v.speed or 0) < 0.4 and not allowed then
      local t = (stillFor[id] or 0) + dt
      if t > FREEZE_LIMIT then
        stillFor[id] = 0
        thaw(id, v)
      else
        stillFor[id] = t
      end
    elseif stillFor[id] then
      stillFor[id] = nil
    end
  end
end

function M.onPreRender(dt)
  conditions.update(dt)

  -- The elapsed time is accumulated and handed over whole, so every timer downstream still
  -- counts in real seconds however often this actually fires.
  worldTimer = worldTimer - dt
  worldAccum = worldAccum + dt
  if worldTimer <= 0 then
    worldTimer = WORLD_PERIOD
    local wdt = worldAccum
    worldAccum = 0
    guard('perception', perception.refreshSnapshot)
    guard('emergencyYield', emergencyYield.refresh)
    guard('policeWatch', policeWatch.update, wdt)
    guard('policeTactics', policeTactics.update, wdt)
    guard('spikes', spikes.update, wdt)
    guard('wanted', wanted.update, wdt)
    guard('convoy', convoy.update, wdt)
    guard('shuttle', shuttle.update, wdt)
    guard('manhunt', manhunt.update, wdt)
    guard('trafficBreak', trafficBreak.update, wdt)
    guard('parking', parking.update, wdt)
    guard('antifreeze', antifreeze, wdt)
    recoverTimer = recoverTimer - wdt
    if recoverTimer <= 0 then
      recoverTimer = 15
      guard('recover', recover, 'barrido')
    end
    guard('policeStop', policeStop.update, wdt)
    guard('policeEvents', policeEvents.update, wdt)
    guard('emergency', emergency.update, wdt)
  end

  if overlay.enabled then guard('overlay', function() overlay.render(dt, drivers) end) end
end

function M.onAiRouteDone(vehId)
  parking.onAiRouteDone(vehId)
end

function M.moduleStatus()
  return dead, fails
end

function M.onTrafficVehicleAdded(id)
  emergency.onVehicleAdded(id)
  if M.enabled then attach(id) end
end

-- The traffic system asks every extension for extra special vehicles when it builds a group.
function M.onTrafficSpecialVehiclesProviders()
  if M.enabled then emergency.registerProviders() end
end

-- Traffic is up. If it brought police, build the spikestrip now rather than mid-pursuit:
-- spawning a vehicle costs a frame either way, and this is the moment where it does not show.
function M.onTrafficStarted()
  if not M.enabled then return end
  local police = gameplay_police and gameplay_police.getPoliceVehicles
    and gameplay_police.getPoliceVehicles()
  if police and next(police) then guard('spikesPreload', spikes.preload) end
  guard('recover', recover, 'arranque del trafico')
end

-- The road graph is only sampled once per level, not per call-out.
function M.onClientPostStartMission()
  -- A new level is a clean slate. A module that failed on the last map gets another go
  -- here instead of staying off for every level after it.
  table.clear(fails)
  table.clear(dead)
  emergencyYield.revive()
  emergency.buildNodeSample()
  places.build()
end

function M.onTrafficVehicleRemoved(id)
  drivers[id] = nil
  units.forget(id)
  holds.forget(id)
  perception.forgetSize(id)
  baseBehavior.forgetLateral(id)
  policeStop.onVehicleRemoved(id)
  emergency.onVehicleRemoved(id)
end

function M.onTrafficStopped()
  detachAll(false)
  policeWatch.reset()
  policeTactics.reset()
  policeStop.reset()
  policeEvents.reset()
  emergency.reset()
  fines.reset()
  spikes.reset()
  places.reset()
  wanted.reset()
  convoy.reset()
  shuttle.reset()
  manhunt.reset()
  trafficBreak.reset()
end

function M.onClientEndMission()
  detachAll(false)
  policeStop.reset()
  policeEvents.reset()
end

function M.onExtensionLoaded()
  local data = gameplay_traffic and gameplay_traffic.getTrafficData()
  if M.enabled and data then
    for id in pairs(data) do attach(id) end
  end
  logger.i('trafficAI loaded')
  return true
end

function M.onExtensionUnloaded()
  detachAll(true)
  policeStop.reset()
  policeEvents.reset()
end

return M
