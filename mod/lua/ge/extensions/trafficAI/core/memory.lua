local M = {}

M.CUT_OFF, M.NEAR_MISS, M.COLLISION, M.HONKED, M.BLOCKED, M.BRAKE_CHECK = 1, 2, 3, 4, 5, 6

local TTL = {12, 25, 60, 15, 20, 30} -- how long each event kind stays relevant, in seconds

-- Fixed ring buffer allocated once per driver, so recording an event never allocates.
function M.new(size)
  local m = {size = size, head = 0, count = 0, e = {}}
  for i = 1, size do
    m.e[i] = {id = 0, kind = 1, t = 0, w = 0}
  end
  return m
end

function M.add(m, now, id, kind, weight)
  m.head = m.head % m.size + 1
  local e = m.e[m.head]
  e.id, e.kind, e.t, e.w = id, kind, now, weight or 1
  if m.count < m.size then m.count = m.count + 1 end
end

function M.grudge(m, now, id)
  local total = 0
  for i = 1, m.count do
    local e = m.e[i]
    if e.id == id and e.w > 0 then
      local f = 1 - (now - e.t) / TTL[e.kind]
      if f > 0 then total = total + e.w * f end
    end
  end
  return total
end

function M.strongest(m, now)
  local bestId, bestW = 0, 0
  for i = 1, m.count do
    local e = m.e[i]
    if e.w > 0 and e.id ~= 0 then
      local f = 1 - (now - e.t) / TTL[e.kind]
      if f > 0 then
        local w = e.w * f
        if w > bestW then bestW, bestId = w, e.id end
      end
    end
  end
  return bestId, bestW
end

function M.clear(m)
  for i = 1, m.size do
    local e = m.e[i]
    e.id, e.w = 0, 0
  end
  m.head, m.count = 0, 0
end

return M
