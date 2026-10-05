local M = {}

local POLL = 3.0 -- seconds; weather does not change fast enough to justify more
local MAX_DROPS = 8000 -- roughly the point where BeamNG rain reads as heavy

M.rain, M.fog, M.night, M.hour = 0, 0, false, 12
M.grip, M.visibility = 1, 1

local timer = 0

local function clamp01(v)
  return v < 0 and 0 or (v > 1 and 1 or v)
end

-- Polled once for the whole world, not per vehicle: every driver sees the same weather.
function M.update(dt)
  timer = timer - dt
  if timer > 0 then return end
  timer = POLL

  local env = core_environment
  if not env then return end

  local drops = env.getPrecipitation and env.getPrecipitation() or 0
  M.rain = clamp01((drops or 0) / MAX_DROPS)

  local fog = env.getFogDensity and env.getFogDensity() or 0
  M.fog = clamp01((fog or 0) * 1000 / 0.06)

  -- BeamNG's time runs from noon: 0 is midday, 0.25 evening, 0.5 midnight, 0.75 morning.
  -- The old test read it the other way round and called the whole working day night.
  local tod = env.getTimeOfDay and env.getTimeOfDay()
  if tod and tod.time then
    M.hour = (tod.time * 24 + 12) % 24
    M.night = M.hour >= 20.5 or M.hour < 6
  end

  M.grip = 1 - M.rain * 0.35
  M.visibility = 1 - M.fog * 0.6 - (M.night and 0.2 or 0)
  if M.visibility < 0.2 then M.visibility = 0.2 end
end

-- Commuting hours: more people late, and less patient about it.
function M.rushHour()
  local h = M.hour
  return (h >= 7 and h < 9.5) or (h >= 17 and h < 19.5)
end

-- Cautious drivers back off far more than reckless ones in the same downpour.
function M.speedMult(p)
  local caution = 0.10 + p.prudence * 0.20
  return 1 - M.rain * caution - M.fog * caution * 0.7 - (M.night and p.prudence * 0.06 or 0)
end

function M.gapMult(p)
  return 1 + M.rain * (0.25 + p.prudence * 0.5) + M.fog * 0.3
end

return M
