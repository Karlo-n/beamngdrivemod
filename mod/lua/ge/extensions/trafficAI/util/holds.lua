local M = {}

-- One place that says "a scripted situation owns this car". Claimed cars are left alone by
-- every autonomous module (parking, patrol events, AI traffic stops). Held cars also have
-- their driver model stand down, so the engine's own pull-over can actually bring them to a
-- stop: without this, the player's lights made the civilian's corridor logic clear its stop
-- point every tick and it never finished pulling over.
local claims = {}

function M.claim(id, owner, held)
  if not id or id == 0 then return end
  claims[id] = {owner = owner or '?', held = held and true or false}
end

function M.setHeld(id, held)
  local c = claims[id]
  if c then c.held = held and true or false end
end

function M.release(id, owner)
  local c = claims[id]
  if c and (owner == nil or c.owner == owner) then claims[id] = nil end
end

function M.isClaimed(id)
  return claims[id] ~= nil
end

function M.isHeld(id)
  local c = claims[id]
  return c ~= nil and c.held
end

function M.owner(id)
  local c = claims[id]
  return c and c.owner or nil
end

function M.forget(id)
  claims[id] = nil
end

function M.reset()
  claims = {}
end

return M
