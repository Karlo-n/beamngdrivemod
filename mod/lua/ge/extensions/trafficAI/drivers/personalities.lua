local M = {}

local sampleRange = require('trafficAI/util/mathUtils').sampleRange

M.traits = {'patience', 'aggression', 'prudence', 'confidence', 'tolerance', 'temper', 'horn', 'beams', 'ragebait'}

function M.generate(typeDef)
  local out, src = {}, typeDef.p
  for i = 1, #M.traits do
    local k = M.traits[i]
    local r = src[k]
    out[k] = sampleRange(r[1], r[2])
  end
  return out
end

return M
