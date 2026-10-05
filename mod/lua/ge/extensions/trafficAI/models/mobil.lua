local M = {}

local idm = require('trafficAI/models/idm')

-- MOBIL, as described in the paper the project notes cite. Two conditions:
--
--   safety     the driver who would end up behind us in the target lane must not be forced
--              to brake harder than bSafe
--   incentive  our own gain must beat a threshold, after subtracting the trouble we cause
--              others, weighted by a politeness factor
--
-- The politeness factor is the interesting part: it is literally the tolerance trait. At 0 the
-- driver only cares about their own gain and will cut anyone up; near 1 they will not move if
-- it inconveniences someone else. That single number produces both the courteous driver and
-- the one who dives into any hole.
--
-- p         politeness, 0..1
-- aThresh   minimum personal gain worth changing lane for (m/s2)
-- bSafe     the most we are willing to make the new follower brake (positive number)
--
-- Returns: accept (bool), gain (m/s2), reason (string when rejected)
function M.evaluate(s, p, aThresh, bSafe)
  local a, b, s0, T = s.a, s.b, s.s0, s.T

  -- Our acceleration, staying put versus moving over.
  local aSelfOld = idm.accel(s.v, s.v0, s.gap, s.vLead, a, b, s0, T)
  local aSelfNew = idm.accel(s.v, s.v0, s.tgtFrontGap, s.tgtFrontSpeed, a, b, s0, T)

  -- The car already in the target lane behind us: before, it followed whatever was ahead of
  -- it; afterwards it follows us.
  local aNewFollowerOld, aNewFollowerNew = 0, 0
  if s.tgtRearGap and s.tgtRearGap >= 0 then
    local vr = s.tgtRearSpeed or 0
    local aheadOfThem = (s.tgtFrontGap and s.tgtFrontGap >= 0)
      and (s.tgtRearGap + s.tgtFrontGap) or nil
    aNewFollowerOld = idm.accel(vr, s.v0, aheadOfThem, s.tgtFrontSpeed, a, b, s0, T)
    aNewFollowerNew = idm.accel(vr, s.v0, s.tgtRearGap, s.v, a, b, s0, T)

    -- Safety criterion. This is the one that must never be traded away.
    if aNewFollowerNew < -bSafe then
      return false, 0, 'cortaria al de atras'
    end
  end

  -- The car behind us in our current lane gets a clearer road once we leave it.
  local aOldFollowerOld, aOldFollowerNew = 0, 0
  if s.rearGap and s.rearGap >= 0 then
    local vr = s.rearSpeed or 0
    aOldFollowerOld = idm.accel(vr, s.v0, s.rearGap, s.v, a, b, s0, T)
    local theirNewGap = (s.gap and s.gap >= 0) and (s.rearGap + s.gap) or nil
    aOldFollowerNew = idm.accel(vr, s.v0, theirNewGap, s.vLead, a, b, s0, T)
  end

  local selfGain = aSelfNew - aSelfOld
  local othersLoss = (aNewFollowerOld - aNewFollowerNew) + (aOldFollowerOld - aOldFollowerNew)
  local score = selfGain - p * othersLoss

  if score <= aThresh then
    return false, score, 'no compensa'
  end
  return true, score, nil
end

return M
