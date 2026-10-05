local M = {}

local random = math.random

local policeStop = require('trafficAI/behaviors/policeStop')
local perception = require('trafficAI/environment/perception')
local units = require('trafficAI/util/units')

local PROVOKE_RANGE = 35
local PROVOKE_RANGE_SQ = PROVOKE_RANGE * PROVOKE_RANGE
local DECAY = 0.35 -- score bled off per second
local STOP_AT = 5
local HORN_POINTS = 1.4
local FLASH_POINTS = 2.2

M.enabled = true

local scores = {}
local toPolice = vec3()
local hornSeen = {}

-- Is there a police car close enough that this could only be aimed at them?
local function policeNear(id)
  if not gameplay_police or not gameplay_police.getPoliceVehicles then return nil end
  local police = gameplay_police.getPoliceVehicles()
  local objects = map.objects
  if not police or not objects then return nil end

  local me = objects[id]
  if not me or not me.pos then return nil end

  for pid in pairs(police) do
    if pid ~= id then
      local o = objects[pid]
      if o and o.pos then
        toPolice:setSub2(o.pos, me.pos)
        if toPolice:squaredLength() < PROVOKE_RANGE_SQ then return pid end
      end
    end
  end
  return nil
end

local function add(id, points)
  -- A service vehicle using its horn or lights is working, not being rude at a patrol.
  if units.isEmergency(id) then return end
  local pid = policeNear(id)
  if not pid then return end

  local s = (scores[id] or 0) + points
  scores[id] = s
  if s < STOP_AT then return end

  -- Being rude at a patrol gets you pulled over and spoken to. Going straight to
  -- setPursuitMode treated a horn like an armed robbery, which is what it used to do.
  scores[id] = 0
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local tveh = traffic and traffic[id]
  if not tveh or not tveh.pursuit then return end
  if tveh.pursuit.mode and tveh.pursuit.mode > 0 then return end

  -- Severity grows with how much they kept at it, so persistence is what escalates.
  local severity = (s - STOP_AT) * 0.12
  policeStop.begin(id, 'conduccion molesta', severity > 0.45 and 0.45 or severity)
end

-- Reported from vehicle Lua, because the game engine is never told about headlight state.
function M.onHighBeamFlash(id)
  if not M.enabled then return end
  add(id, FLASH_POINTS)
end

-- The horn does reach the game engine, but only as a level: this turns it into events.
function M.update(dt)
  if not M.enabled then return end

  -- Reads the shared snapshot rather than sweeping map.objects for a third time per frame.
  local snap = perception.snapshot
  for i = 1, snap.n do
    local id = snap.id[i]
    local st = snap.states[i]
    local honking = st and st.horn and st.horn ~= 0
    if honking and not hornSeen[id] then
      hornSeen[id] = true
      add(id, HORN_POINTS)
    elseif not honking then
      hornSeen[id] = nil
    end
  end

  local bleed = DECAY * dt
  for id, s in pairs(scores) do
    s = s - bleed
    scores[id] = s > 0 and s or nil
  end
end

function M.getScore(id)
  return scores[id] or 0
end

function M.reset()
  table.clear(scores)
  table.clear(hornSeen)
end

return M
