local M = {}

local sqrt = math.sqrt

local MIN_GAP = 0.5

-- Intelligent Driver Model acceleration. Pure maths: it knows nothing about personality or
-- about BeamNG, it takes numbers and returns one. Both the following behaviour and the lane
-- change model call this, so there is exactly one version of the formula in the project.
--   v        current speed
--   v0       desired free speed
--   gap      distance to the leader, or nil / negative for open road
--   vLead    leader speed
--   a, b     comfortable acceleration and deceleration
--   s0, T    minimum standstill gap and desired time headway
function M.accel(v, v0, gap, vLead, a, b, s0, T)
  if v0 < 1 then v0 = 1 end
  local ratio = v / v0
  ratio = ratio * ratio
  ratio = ratio * ratio -- (v/v0)^4

  if not gap or gap < 0 then
    return a * (1 - ratio)
  end

  local s = gap > MIN_GAP and gap or MIN_GAP
  local dv = v - (vLead or 0)
  local sStar = s0 + v * T + v * dv / (2 * sqrt(a * b))
  if sStar < s0 then sStar = s0 end

  local gapRatio = sStar / s
  return a * (1 - ratio - gapRatio * gapRatio)
end

-- The equilibrium gap the model settles at, which is also what the follower would need.
function M.desiredGap(v, s0, T)
  return s0 + v * T
end

return M
