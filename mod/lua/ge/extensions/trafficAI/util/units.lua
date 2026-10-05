local M = {}

local find = string.find
local lower = string.lower

-- traffic/vehicle.lua only updates isAi inside setAiMode (vehicle.lua:206). Climb into a car
-- that was part of traffic and it still says isAi = true, so every "if v.isAi" guard in the
-- mod happily issued AI orders to the player's own car. Every guard goes through here now.
function M.isPlayer(id)
  if not id or id == 0 or not be then return false end
  return be:getPlayerVehicleID(0) == id
end

-- Is the AI really driving this traffic vehicle? The traffic entry carries its own id.
function M.ai(v)
  return v ~= nil and v.isAi == true and not M.isPlayer(v.id)
end

-- What kind of service vehicle this is, from its part config. Cached: the config only
-- changes when the car is replaced, and this is asked from hot per-driver code.
local KINDS = {
  {'ambulance', 'medic'}, {'firetruck', 'fire'}, {'firechief', 'fire'},
  {'armored_police', 'police'}, {'unmarked', 'police'}, {'detective', 'police'},
  {'police', 'police'}, {'sheriff', 'police'}, {'polizia', 'police'},
  {'gendarmerie', 'police'}, {'interceptor', 'police'}
}
local cache, cacheAt = {}, {}
local REFRESH = 10

local function now()
  return os.clock()
end

function M.serviceKind(id)
  if not id or id == 0 then return nil end
  local t = now()
  local at = cacheAt[id]
  if at and t - at < REFRESH then return cache[id] or nil end

  local kind = false
  if gameplay_police and gameplay_police.getPoliceVehicles then
    local ok, police = pcall(gameplay_police.getPoliceVehicles)
    if ok and police and police[id] then kind = 'police' end
  end
  if not kind then
    local obj = getObjectByID(id)
    local pc = obj and obj.partConfig
    if type(pc) == 'string' and pc ~= '' then
      pc = lower(pc)
      for i = 1, #KINDS do
        if find(pc, KINDS[i][1], 1, true) then kind = KINDS[i][2] break end
      end
    end
  end
  cache[id], cacheAt[id] = kind, t
  return kind or nil
end

-- Police, ambulance or fire. Civilians never pick a fight with one of these, and a horn or
-- a flash from one means "let me through", not an insult.
function M.isEmergency(id)
  return M.serviceKind(id) ~= nil
end

-- Recycling switched off for a vehicle shows up as state 'locked' (traffic/vehicle.lua:701).
-- It is still on the road and still driven, so it counts as alive.
function M.alive(v)
  return v ~= nil and (v.state == 'active' or v.state == 'locked')
end

-- Vehicle-side commands (lua/vehicle/extensions/auto/trafficAILights.lua). Each falls back to
-- stock behaviour if that extension is not there.
M.KERB_STOP = 'if trafficAIVeh then trafficAIVeh.kerbStop(0.8) else ai.setPullOver(true) end'
M.SIRENS_HIDE = 'if trafficAIVeh then trafficAIVeh.setIgnoreSirens(true) end'
M.SIRENS_SHOW = 'if trafficAIVeh then trafficAIVeh.setIgnoreSirens(false) end'

function M.forget(id)
  cache[id], cacheAt[id] = nil, nil
end

return M
