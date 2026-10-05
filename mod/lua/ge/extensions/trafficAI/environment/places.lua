local M = {}

-- Petrol stations are real, queryable level data (freeroam/facilities.lua:117), so a driver
-- pulling in for fuel stops somewhere that actually is a petrol station rather than at a
-- random kerb. Positions are cached once per level; not every map has any.
local NEAR = 70
local NEAR_SQ = NEAR * NEAR

M.stations = {}
M.count = 0
local built = false

function M.build()
  M.count, built = 0, true
  if not freeroam_facilities or not freeroam_facilities.getFacilitiesByType then return end
  local level = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  local ok, list = pcall(freeroam_facilities.getFacilitiesByType, 'gasStation', level)
  if not ok or type(list) ~= 'table' then return end

  for _, f in pairs(list) do
    local pos
    if freeroam_facilities.getAverageDoorPositionForFacility then
      local okPos, p = pcall(freeroam_facilities.getAverageDoorPositionForFacility, f)
      if okPos and p then pos = p end
    end
    if pos then
      M.count = M.count + 1
      M.stations[M.count] = vec3(pos)
    end
  end
end

-- Is there a petrol station close enough that stopping here reads as stopping for fuel?
function M.nearStation(pos)
  if not built then M.build() end
  if M.count == 0 or not pos then return false end
  for i = 1, M.count do
    if M.stations[i]:squaredDistance(pos) < NEAR_SQ then return true end
  end
  return false
end

function M.reset()
  M.count, built = 0, false
end

return M
