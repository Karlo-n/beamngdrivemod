local M = {}

-- Runs inside every vehicle. Three small jobs that can only be done from this side.

-- 1. Headlight flashes. mapmgr publishes horn, lightbar, hazards and indicators to the game
-- engine, but not the headlight state, so only the transition is reported.
local lastLights = -1
local reportTimer = 0

-- 2. Sirens. ai.lua's traffic mode stops a car dead at the extreme road edge whenever any lit
-- vehicle is within 100 m in any direction (ai.lua:4353-4412), and re-pins it there every
-- frame. That is the "everyone freezes for a siren" behaviour, and where the edge is a
-- guard rail it is also a scrape. For cars our own traffic role drives, the lightbar state
-- is removed from this vehicle's copy of the object list before ai.lua reads it, so the
-- stock stop never arms and the role's own "move over and keep going" is all that happens.
-- Only ai.lua reads other vehicles' lightbars on this side, so nothing else notices.
local ignoreSirens = false
local origGetObjects
local strippedAt = -1

local function getObjects()
  local objs = origGetObjects()
  if ignoreSirens then
    local t = obj:getSimTime()
    if t ~= strippedAt then
      strippedAt = t
      for _, v in pairs(objs) do
        local st = v.states
        if st and st.lightbar then st.lightbar = nil end
      end
    end
  end
  return objs
end

local function install()
  if origGetObjects or not mapmgr or not mapmgr.getObjects then return end
  origGetObjects = mapmgr.getObjects
  mapmgr.getObjects = getObjects
end

function M.setIgnoreSirens(on)
  install()
  ignoreSirens = on and origGetObjects ~= nil
end

-- 3. Kerbside stop with a margin. ai.setPullOver is the only stop the engine does not
-- overwrite (a plain stop point is reset every frame near a junction, ai.lua:4805), but it
-- parks the car flush against the road edge. The engine applies that sideways shift on its
-- next update; a few frames later it is trimmed back by `margin`.
local trim

function M.kerbStop(margin)
  ai.setPullOver(true)
  local vx, vy, vz = obj:getSmoothRefVelocityXYZ()
  local speedSq = (vx or 0) ^ 2 + (vy or 0) ^ 2 + (vz or 0) ^ 2
  -- Below 3 m/s the engine does not shift the car at all (ai.lua:4402), so there is nothing
  -- to trim.
  if speedSq >= 3.2 * 3.2 then
    trim = {frames = 3, margin = margin or 0.8}
  end
end

local function updateGFX(dt)
  if trim then
    trim.frames = trim.frames - 1
    if trim.frames <= 0 then
      local side = (mapmgr and mapmgr.rules and mapmgr.rules.rightHandDrive) and -1 or 1
      ai.laneChange(nil, 8, -trim.margin * side)
      trim = nil
    end
  end

  reportTimer = reportTimer - dt
  if reportTimer > 0 then return end
  reportTimer = 0.1

  local state = electrics.values.lights_state or 0
  if state == lastLights then return end

  local prev = lastLights
  lastLights = state

  -- Only a flash to high beam is worth telling anyone about.
  if state == 2 and prev >= 0 then
    obj:queueGameEngineLua(
      'if trafficAI_main then trafficAI_main.onHighBeamFlash(' .. objectId .. ') end')
  end
end

M.updateGFX = updateGFX

-- An explicit global, so the game-engine side does not depend on how this file gets named.
rawset(_G, 'trafficAIVeh', M)

return M
