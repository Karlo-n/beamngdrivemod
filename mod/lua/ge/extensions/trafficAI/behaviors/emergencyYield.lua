local M = {}

local abs = math.abs
local sqrt = math.sqrt

local base = require('trafficAI/behaviors/baseBehavior')
local perception = require('trafficAI/environment/perception')
local policeTactics = require('trafficAI/behaviors/policeTactics')
local units = require('trafficAI/util/units')

-- Vanilla ai.lua forces every traffic car to stop dead at the kerb whenever a lit vehicle is
-- within 100 m (ai.lua:4360). That is not what real traffic does, and it is what causes the
-- pile-ups. This opens a corridor instead: the inner lane hugs the centre line, everyone else
-- hugs the kerb, and the cars keep rolling. The engine's own stop never arms for these cars:
-- the vehicle side hides other vehicles' lightbars from ai.lua (see trafficAILights.lua).

-- Seeing it early is what stops the last-second swerve, but reacting to something 120 m away
-- by braking is just as wrong: outside REACT they only drift over, they do not slow.
M.SCAN = 130
local SCAN_SQ = M.SCAN * M.SCAN
local REACT = 95
local MIN_ROLL = 5        -- m/s; below this nobody is "keeping moving" any more
local CLOSE = 18          -- m; right on top of us, the nervous ones may actually stop
local RUNNER_SPEED = 18   -- m/s a fleeing car has to be doing before it counts as a hazard
-- A patrol stopped at the roadside with its lights on is a scene, not a siren to let past.
-- Real law says move over a lane and slow right down; the stock AI instead stops dead
-- (ai.lua forces a stop for any lit vehicle within 100 m), which is what causes the pile-ups.
local SCENE_RANGE = 70
local SCENE_SLOW = 45
local SCENE_STOPPED = 2
-- Crossing traffic. An emergency vehicle about to come through a junction on the other road:
-- whoever has not entered yet holds back, whoever is already in it clears it.
local CROSS_LOOK = 70      -- metres ahead of us the paths may meet
local CROSS_THEIRS = 130   -- metres ahead of them
local CROSS_TIME = 7       -- seconds until they reach the meeting point
local CROSS_STANDOFF = 7   -- metres short of the meeting point where we wait
local CROSS_DECEL = 2.6

M.lit = {}                -- shared per-frame list of lit emergency vehicles
M.count = 0
M.alive = true            -- false once switched off: cars then fall back to the stock siren stop

local rel = vec3()

-- One pass per frame for the whole map instead of one per driver per tick.
local function addHazard(snap, i, kind)
  local dir = snap.dir[i]
  if not dir then return end
  local n = M.count + 1
  M.count = n
  local e = M.lit[n]
  if not e then e = {pos = vec3(), dir = vec3()} M.lit[n] = e end
  e.id = snap.id[i]
  e.pos:set(snap.pos[i])
  e.dir:set(dir)
  e.speed = snap.speed[i]
  e.kind = kind
end

-- A horn or a flash of the headlights from a service vehicle means "let me through". It is
-- honoured for a few seconds so a short tap still opens the gap.
local passage = {}
local PASSAGE_TIME = 3

function M.requestPassage(id, secs)
  passage[id] = os.clock() + (secs or PASSAGE_TIME)
end

function M.refresh()
  M.count = 0
  local t = os.clock()
  -- The car being chased is a hazard too. Traffic that only watches for lightbars pulls
  -- straight out in front of it, which is most of what looks stupid during a pursuit.
  local runnerId = policeTactics.suspectId
  -- Same shared snapshot the rest of the mod uses; there is no second world sweep here.
  local snap = perception.snapshot
  for i = 1, snap.n do
    local st = snap.states[i]
    -- Most cars have no lightbar at all, so the state is nil, not 0. Comparing nil with >=
    -- threw, and five throws switched this module off for the rest of the session.
    local bar = st and st.lightbar or 0
    local speed = snap.speed[i] or 0
    local id = snap.id[i]
    if st and st.horn and st.horn ~= 0 and units.isEmergency(id) then
      passage[id] = t + PASSAGE_TIME
    end
    local asking = passage[id] ~= nil and passage[id] > t
    -- lightbar 2 is lights + siren; 1 is lights only, which only counts when they are
    -- actually going somewhere. Same test the engine itself uses.
    if bar >= 1 and speed < SCENE_STOPPED then
      addHazard(snap, i, 'scene')
    elseif bar == 2 or (bar == 1 and speed >= 10) or (asking and speed >= 3) then
      addHazard(snap, i, 'siren')
    elseif runnerId and snap.id[i] == runnerId and speed >= RUNNER_SPEED then
      addHazard(snap, i, 'runner')
    end
  end
end

-- If this module is ever switched off, the hazard list must go with it. A frozen list kept
-- every driver swerving away from sirens that had left long ago.
function M.clear()
  M.count = 0
  M.alive = false
  passage = {}
end

function M.revive()
  M.alive = true
end

-- The one that matters to us: closest lit vehicle coming up from behind on our side, or
-- bearing down from ahead. Returns the vehicle plus how it is approaching.
local function relevant(ctx)
  local best, bestDist, bestBehind, bestLat, bestCross = nil, 1e9, false, 0, nil
  for i = 1, M.count do
    local e = M.lit[i]
    if e.id ~= ctx.id then
      rel:setSub2(e.pos, ctx.pos)
      if rel:squaredLength() < SCAN_SQ then
        local fwd = rel:dot(ctx.dir)
        local lat = rel:dot(ctx.rightVec)
        local heading = e.dir:dot(ctx.dir)
        local sameDir = heading > 0.35
        local dist = abs(fwd)
        local matters = false
        local behind = false
        local cross = nil
        if e.kind == 'scene' then
          -- Static, so what matters is that it is ahead of us and close to our line.
          matters = fwd > 2 and fwd < SCENE_RANGE and abs(lat) < 12
        elseif sameDir and fwd < 4 then
          -- Coming through from behind, and actually gaining on us.
          matters = e.speed > ctx.speed - 1
          behind = true
        elseif heading < -0.35 then
          -- Head on. Only worth reacting to while it is still coming at us.
          matters = fwd > 0 and abs(lat) < 14
        elseif not sameDir and e.kind == 'siren' and e.speed > 4 and abs(rel.z) < 6 then
          -- Roughly at right angles: where do the two paths meet, and who gets there first?
          local det = ctx.dir.x * e.dir.y - ctx.dir.y * e.dir.x
          if det > 0.5 or det < -0.5 then
            local ours = (rel.x * e.dir.y - rel.y * e.dir.x) / det
            local theirs = (rel.x * ctx.dir.y - rel.y * ctx.dir.x) / det
            if ours > 0 and ours < CROSS_LOOK and theirs > -5 and theirs < CROSS_THEIRS then
              local tTheirs = theirs / e.speed
              local tOurs = ours / (ctx.speed > 1 and ctx.speed or 1)
              -- Through and gone well before they arrive: carry on.
              if tTheirs < CROSS_TIME and tOurs + 1.5 > tTheirs then
                matters, cross, dist = true, ours, ours
              end
            end
          end
        end
        if matters and dist < bestDist then
          best, bestDist, bestBehind, bestLat, bestCross = e, dist, behind, lat, cross
        end
      end
    end
  end
  return best, bestDist, bestBehind, bestLat, bestCross
end

-- Where the corridor goes, in roadOffset units. The rule everyone is taught: innermost lane
-- squeezes toward the centre line, every other lane squeezes toward the kerb, and the gap
-- opens between them. One lane means as far over as the road allows.
-- `lat` is where the emergency vehicle actually is, sideways, relative to us: positive means
-- it is on our right. Moving toward it is what caused cars to cut across in front of an
-- ambulance, so that always loses to the textbook rule.
local function corridorOffset(ctx, lat)
  local half = (ctx.veh.width or 2) * 0.5 + 0.2
  local w = ctx.laneWidth

  local toKerb
  if abs(lat) > 1.6 then
    -- We can see which side it is coming up: get out of that side, whatever the lane rule says.
    -- roadOffset grows to the right, so a positive lat means we go to negative offset.
    toKerb = (lat > 0) ~= (ctx.sideSign > 0)
  else
    -- Straight behind us: the textbook corridor. Innermost lane hugs the centre line,
    -- everyone else hugs the kerb, and the gap opens between them.
    toKerb = ctx.ourLanes == 1 or ctx.laneIdx > 0
  end

  local fromCenter
  if ctx.ourLanes == 1 then
    fromCenter = w - half            -- nothing to share with: as far over as the road goes
    toKerb = true
  elseif toKerb then
    fromCenter = (ctx.laneIdx + 1) * w - half  -- outer edge of our own lane, not the kerb
  else
    fromCenter = ctx.laneIdx * w + half        -- hug the centre line
  end

  local maxOut = ctx.ourLanes * w - half
  if fromCenter > maxOut then fromCenter = maxOut end
  if fromCenter < half then fromCenter = half end
  return fromCenter * ctx.sideSign, toKerb
end

function M.update(d, ctx, pcp, dt)
  local ey = d.ey
  ey.speedCap, ey.active, ey.side, ey.blocked, ey.kind = -1, false, 0, false, nil
  if M.count == 0 or not ctx.valid then
    if ey.clearing then ey.clearing = false end
    return nil
  end

  local e, dist, behind, lat, cross = relevant(ctx)
  if not e then
    ey.clearing, ey.crossHold = false, false
    return nil
  end

  ey.active, ey.dist, ey.behind = true, dist, behind
  ey.kind = e.kind

  -- Crossing: no swerving, just do not enter. Brake to a point short of where the paths
  -- meet; if we are already that close, we are in the junction and the right thing is to
  -- get out of it.
  if cross then
    ey.kind = 'crossing'
    if cross > CROSS_STANDOFF then
      local cap = sqrt(2 * CROSS_DECEL * (cross - CROSS_STANDOFF))
      ey.speedCap = cap < 0.6 and 0 or cap
      ey.crossHold = true
    elseif ey.crossHold then
      -- Braked up to the line for it: stay there. Without this the car reached the line,
      -- counted as "already in the junction", and pulled out in front of the ambulance.
      ey.speedCap = 0
    end
    return 'cedeEmergencia'
  end
  ey.crossHold = false

  local target, toKerb = corridorOffset(ctx, lat)
  ey.side = toKerb and 1 or -1

  -- Somebody is right alongside on the side we were going to move to. Hold the line and
  -- just slow instead: shuffling into an occupied space is how the pile-ups started.
  local blockedSide = false
  local move = target - ctx.roadOffset
  if move > 0.05 or move < -0.05 then
    perception.senseTargetLane(ctx, d, (move > 0 and 1 or -1) * ctx.laneWidth * 0.6)
    local f, r = pcp.tgtFrontGap or -1, pcp.tgtRearGap or -1
    if (f >= 0 and f < 5) or (r >= 0 and r < 4) then blockedSide = true end
  end

  if not blockedSide then
    -- A small limit so the car eases across instead of snapping over.
    base.lateralHold(ctx, target, 1.1)
  end
  ey.blocked = blockedSide

  -- Always still moving. How much they lift off is personality: the prudent slow right
  -- down, the oblivious barely change. Only a driver who brakes for sirens, with the
  -- vehicle right on top of them, goes near a stop.
  -- Passing a stopped scene: move over and come down to a crawl-past, which is what the
  -- move-over rule actually asks for. It is not the corridor case, so it has its own speeds.
  if e.kind == 'scene' then
    ey.speedCap = ctx.limit * (dist < SCENE_SLOW and 0.5 or 0.75)
    if ey.speedCap < MIN_ROLL then ey.speedCap = MIN_ROLL end
    return 'cedeEmergencia'
  end

  -- Still far off, or it is a car running from the police: move over, but braking in front
  -- of either of them is the wrong answer. Only ease off once it is genuinely close.
  if dist > REACT or e.kind == 'runner' then
    ey.speedCap = -1
    return 'cedeEmergencia'
  end

  -- Coming the other way: it has its own half of the road, so tucking in is nearly all that
  -- is needed. A touch off the speed and carry on.
  if not behind then
    ey.speedCap = ctx.limit * (0.9 - d.p.prudence * 0.1)
    return 'cedeEmergencia'
  end

  -- Same direction: ease off enough to be passed cleanly, never a crawl. Drivers who used to
  -- drop to 40% of the limit were the ones that read as "stopping to listen".
  local f = 0.86 - d.p.prudence * 0.2 + d.p.confidence * 0.08
  if f < 0.62 then f = 0.62 elseif f > 0.94 then f = 0.94 end
  local cap = ctx.limit * f
  if d.d.sirenBraker and dist < CLOSE then
    cap = cap * 0.65
  end
  if cap < MIN_ROLL then cap = MIN_ROLL end
  ey.speedCap = cap
  return 'cedeEmergencia'
end

function M.reset(d)
  local ey = d.ey
  ey.active, ey.speedCap, ey.side, ey.dist, ey.behind = false, -1, 0, 0, false
  ey.kind = nil
  ey.blocked, ey.crossHold = false, false
  ey.clearing, ey.clearTimer = false, 0
end

return M
