local M = {}

local random = math.random

local function clamp(v, lo, hi)
  return v < lo and lo or (v > hi and hi or v)
end

-- Mean of 3 uniforms: bell curve on 0..1 with sd ~0.167, so most drivers land mid-range.
local function gauss01()
  return (random() + random() + random()) * 0.3333333333
end

local function sampleRange(lo, hi)
  return lo + (hi - lo) * gauss01()
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

M.clamp = clamp
M.gauss01 = gauss01
M.sampleRange = sampleRange
M.lerp = lerp

return M
