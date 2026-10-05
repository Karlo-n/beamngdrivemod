local M = {}

local random = math.random
local floor = math.floor

-- Single-lane shuttle working. When the only lane in one direction is blocked, the two
-- directions have to take turns over the free lane. Traffic engineering calls this
-- priority-controlled shuttle working; drivers call it "you go, then me".
local CELL = 12                 -- metres; zones are keyed on a coarse grid
local GREEN = 7                 -- seconds one side keeps the right of way
local CLEAR_TIME = 2.5          -- grace after a side is done before the other starts
local ZONE_LIFE = 6             -- zone forgotten this long after nobody asks about it
local RANGE = 55                -- how far back a driver starts caring about the zone

M.zones = {}
M.count = 0
local clock = 0
local ASK_WINDOW = 1.5   -- a side counts as queued if anyone asked within this long
local PASS_LIFE = 15     -- nobody takes longer than this to get past one blockage

local function key(pos)
  return floor(pos.x / CELL) .. ':' .. floor(pos.y / CELL)
end

local function newZone(k, pos, refDir)
  local z = {
    k = k, pos = vec3(pos), refDir = vec3(refDir),
    holder = 0,                 -- which side currently has the right of way
    timer = 0, idle = ZONE_LIFE,
    lastAsk = {[1] = -99, [-1] = -99},
    passing = {},               -- ids currently crossing
    passCount = 0
  }
  M.zones[k] = z
  M.count = M.count + 1
  return z
end

-- Which of the two directions this driver is travelling in, decided against the heading of
-- whoever opened the zone. ctx.sideSign cannot be used: it comes from the road rules and is
-- the same value for every vehicle on the map, so both directions looked identical and the
-- queue could never alternate.
local function sideOf(z, ctx)
  return ctx.dir:dot(z.refDir) >= 0 and 1 or -1
end

-- Drivers ask at 4 Hz and this runs at 20 Hz, so the queue is tracked as "who asked
-- recently" rather than a counter that would be cleared before anyone could fill it.
local function queued(z, side)
  return clock - z.lastAsk[side] < ASK_WINDOW
end

function M.update(dt)
  clock = clock + dt
  if M.count == 0 then return end
  for k, z in pairs(M.zones) do
    z.idle = z.idle - dt
    if z.idle <= 0 then
      M.zones[k] = nil
      M.count = M.count - 1
    else
      z.timer = z.timer - dt
      -- A car that went off the far end, was recycled, or dropped out of the full update
      -- never says it is done, and one stale entry held the right of way for good.
      for id, t in pairs(z.passing) do
        if clock - t > PASS_LIFE or not (map.objects and map.objects[id]) then
          z.passing[id] = nil
          z.passCount = z.passCount - 1
        end
      end
      if z.passCount < 0 then z.passCount = 0 end
      -- Safety valve: whatever the state, nobody queues at a blockage for half a minute.
      z.stuck = (z.stuck or 0) + dt
      if z.stuck > 25 then
        z.holder, z.timer, z.stuck = 0, 0, 0
        table.clear(z.passing)
        z.passCount = 0
      end
      if z.timer <= 0 then
        local other = -z.holder
        if z.holder == 0 then
          if queued(z, 1) or queued(z, -1) then
            -- Whoever has been waiting longer goes first.
            z.holder = (z.lastAsk[1] <= z.lastAsk[-1]) and 1 or -1
            if not queued(z, z.holder) then z.holder = -z.holder end
            z.timer = GREEN
          end
        elseif z.passCount > 0 then
          z.timer = 1.5
          z.stuck = 0
        elseif queued(z, other) then
          z.holder, z.timer = other, GREEN + CLEAR_TIME
        else
          z.holder, z.timer = 0, 0
        end
      end
    end
  end
end

-- Returns true if this driver may cross now. Registers them either way, so the zone knows
-- how many are queued on each side.
function M.mayCross(d, ctx, obstaclePos)
  if not ctx.dir then return true end
  local k = key(obstaclePos)
  local z = M.zones[k]
  if not z then z = newZone(k, obstaclePos, ctx.dir) end
  z.idle = ZONE_LIFE

  local side = sideOf(z, ctx)
  local sh = d.sh

  if z.holder == side then
    z.lastAsk[side] = clock
    if not z.passing[ctx.id] then
      z.passing[ctx.id] = clock
      z.passCount = z.passCount + 1
    end
    sh.waitTime, sh.zone = 0, k
    return true
  end

  z.lastAsk[side] = clock
  sh.waitTime = sh.waitTime + 0.25
  sh.zone = k

  -- Nobody holds it and nobody is crossing: first to arrive simply goes.
  if z.holder == 0 and z.passCount == 0 then
    z.holder, z.timer = side, GREEN
    z.passing[ctx.id] = clock
    z.passCount = 1
    sh.waitTime = 0
    return true
  end

  -- Some people do not wait their turn. They still will not drive into someone coming the
  -- other way; impatience is not blindness.
  if not d.d.respectsTurn and sh.waitTime > d.d.turnPatience then
    sh.jumped = true
    return true
  end
  return false
end

function M.release(d)
  local sh = d.sh
  if sh.zone then
    local z = M.zones[sh.zone]
    if z and z.passing[d.id] then
      z.passing[d.id] = nil
      z.passCount = z.passCount - 1
      if z.passCount < 0 then z.passCount = 0 end
    end
  end
  sh.zone, sh.waitTime, sh.jumped = nil, 0, false
end

function M.reset()
  table.clear(M.zones)
  M.count, clock = 0, 0
end

return M
