local M = {}

local abs = math.abs
local sqrt = math.sqrt
local format = string.format

local base = require('trafficAI/behaviors/baseBehavior')
local shuttle = require('trafficAI/behaviors/shuttle')

M.IDLE, M.PASS, M.RETURN = 0, 1, 2

local MIN_GAP = 1.5   -- a stopped car sits ~2-3 m off the obstacle; anything higher
                      -- meant the manoeuvre could never start once it had already stopped
local MAX_GAP = 40
local SIGNAL_QUEUE_RANGE = 55 -- a stop light ahead means this is a queue, not a blockage
local PASS_TIMEOUT = 20 -- no manoeuvre round a stationary car should take longer
local DEFAULT_W, DEFAULT_L = 2.0, 4.6

-- Passing inside the carriageway. Perception only calls a car an obstacle once it is
-- actually stopped, so a lorry crawling at walking pace left everyone queued behind it for
-- ever: overtaking refuses (no room in the next lane) and squeezing never even looked.
local CRAWL_SPEED = 4.5
local CRAWL_MAX_OWN_SPEED = 12   -- filtering past only makes sense at low speed
local CRAWL_EXTRA_MARGIN = 0.35

local toObs = vec3()
local toEdge = vec3()

-- Lateral footprint of a rotated box on the road's cross axis. A car parked along the road
-- blocks its own width; one spun sideways across it blocks its whole length.
local function lateralHalfExtent(dirVec, rightVec, w, l)
  local fx = dirVec:dot(rightVec)
  if fx < 0 then fx = -fx end
  local sx = 1 - fx * fx
  sx = sx > 0 and sqrt(sx) or 0
  return 0.5 * (fx * l + sx * w)
end

-- Can the car fit through this corridor, and is taking it acceptable? Returns the lateral
-- target, or nil. Kept at module level so evaluating never allocates a closure.
local function evaluate(d, ctx, pcp, gap, targetLat, need, centerLat, ourSideIsRight, obsGap, lo, hi, obsPos)
  if gap < need then return nil end
  local crosses = ourSideIsRight and (targetLat < centerLat) or (targetLat > centerLat)
  if crosses then
    -- Physical safety first: never pull out in front of something coming the other way.
    local needClear = obsGap + 25 + ctx.speed * 2
    if pcp.oncomingGap >= 0 and pcp.oncomingGap < needClear then
      d.sh.crossing = false
      return nil
    end
    -- Then the turn. One direction at a time over the free lane.
    if obsPos and not shuttle.mayCross(d, ctx, obsPos) then
      d.sh.crossing = false
      return nil
    end
    d.sh.crossing = true
  end
  if lo > hi then return nil end
  if targetLat < lo then return lo elseif targetLat > hi then return hi end
  return targetLat
end

-- Closed loop on the remaining lateral error, same as laneChange: the plan is rebuilt
-- constantly, so the displacement has to be re-asserted every tick.
local function hold(ctx, sq)
  base.lateralHold(ctx, sq.targetOffset)
end

function M.update(d, ctx, pcp, dt)
  local sq = d.sq
  sq.speedCap, sq.ignoreId = -1, 0

  if sq.cooldown > 0 then
    sq.cooldown = sq.cooldown - dt
    if sq.cooldown < 0 then sq.cooldown = 0 end
  end

  -- A stopped car first; failing that, one crawling so slowly it may as well be parked.
  local obsId, obsGap = pcp.obstacleId, pcp.obstacleGap
  local crawling = false
  if obsId == 0 and pcp.leadId ~= 0 and pcp.leadGap >= 0
    and pcp.leadSpeed < CRAWL_SPEED and ctx.speed < CRAWL_MAX_OWN_SPEED then
    obsId, obsGap, crawling = pcp.leadId, pcp.leadGap, true
  end
  sq.crawling = crawling
  local stillThere = obsId ~= 0 and obsId == sq.target and obsGap >= 0 and obsGap <= MAX_GAP

  if sq.phase == M.PASS then
    sq.timer = sq.timer - dt
    -- A red light appearing ahead means we are now in a queue, whatever we were doing a
    -- moment ago. Without this the manoeuvre latched and blocked everything behind it.
    local queued = pcp.signalDist >= 0 and pcp.signalDist < SIGNAL_QUEUE_RANGE
      and (pcp.signalAction == 2 or pcp.signalAction == 3 or pcp.signalAction == 4)

    if stillThere and not queued and sq.timer > 0 then
      sq.ignoreId, sq.speedCap = obsId, sq.cap
      hold(ctx, sq)
      return 'squeeze'
    end
    sq.phase, sq.timer = M.RETURN, 2.0
  end

  if sq.phase == M.RETURN then
    sq.timer = sq.timer - dt
    -- Ease back rather than snapping, so the car drifts home instead of swerving.
    sq.targetOffset = sq.homeOffset + (sq.targetOffset - sq.homeOffset) * 0.6
    hold(ctx, sq)
    if sq.timer <= 0 or abs(sq.targetOffset - sq.homeOffset) < 0.15 then
      sq.phase, sq.active, sq.cooldown = M.IDLE, false, 2.5
      sq.clearance = 0
      shuttle.release(d)
    end
    return 'squeeze'
  end

  sq.active = false
  if sq.cooldown > 0 or not ctx.valid then return nil end
  if obsId == 0 or obsGap < MIN_GAP or obsGap > MAX_GAP then return nil end

  -- Everything stopped in front used to count as an obstacle, which meant every queue at a
  -- red light got treated as a blockage to be driven around. Three gates fix that.
  if pcp.signalDist >= 0 and pcp.signalDist < SIGNAL_QUEUE_RANGE
    and (pcp.signalAction == 2 or pcp.signalAction == 3 or pcp.signalAction == 4) then
    sq.waitTimer = 0
    return nil
  end

  if obsId ~= sq.waitId then
    sq.waitId, sq.waitTimer = obsId, 0
  else
    sq.waitTimer = sq.waitTimer + dt
  end

  local tr, objects = ctx.tracking, map.objects
  local o = objects and objects[obsId]
  if not o or not o.pos or not tr then return nil end

  local ot = ctx.traffic and ctx.traffic[obsId]

  -- A wreck sits across the road or is visibly damaged. Anything else has to have been
  -- sitting there long enough that it is clearly not just waiting its turn.
  local askew = o.dirVec and math.abs(o.dirVec:dot(ctx.dir)) < 0.82
  -- Hazard lights are the driver in front telling everyone they are not moving again.
  local damaged = (ot and ot.damage and ot.damage > 800) or pcp.obstacleHazard
  if crawling then
    -- Still moving, so nobody barges past on geometry alone: it takes a driver with some
    -- push and a while spent stuck behind them.
    if d.d.overtakeEagerness < 0.3 then return nil end
    if sq.waitTimer < 3 + d.p.patience * 7 then return nil end
  elseif not (askew or damaged) and sq.waitTimer < 6 + d.p.patience * 10 then
    return nil
  end
  local myHalfW = ((ctx.veh.width or DEFAULT_W) * 0.5)
  local obsHalf = lateralHalfExtent(o.dirVec or ctx.dir, ctx.rightVec,
    (ot and ot.width) or DEFAULT_W, (ot and ot.length) or DEFAULT_L)

  toObs:setSub2(o.pos, ctx.pos)
  local latRel = toObs:dot(ctx.rightVec)

  toEdge:setSub2(tr.roadRightPos, ctx.pos)
  local distRight = toEdge:dot(ctx.rightVec)
  toEdge:setSub2(tr.roadLeftPos, ctx.pos)
  local distLeft = toEdge:dot(ctx.rightVec)

  -- Creeping past at walking pace needs far less room than doing it at speed.
  local margin = 0.25 + d.p.prudence * 0.45
  if ctx.speed < 2 then margin = margin * 0.55 end
  -- Slipping past something that is still rolling needs more room than past a parked car.
  if crawling then margin = margin + CRAWL_EXTRA_MARGIN end
  local need = myHalfW * 2 + margin
  local gapRight = distRight - (latRel + obsHalf)
  local gapLeft = (latRel - obsHalf) - distLeft

  -- Centre line expressed in our own lateral frame; crossing it needs the oncoming check.
  local centerLat = -ctx.roadOffset
  local ourSideIsRight = ctx.sideSign > 0

  local lo, hi = distLeft + myHalfW + 0.1, distRight - myHalfW - 0.1
  local rightLat = evaluate(d, ctx, pcp, gapRight, (latRel + obsHalf + distRight) * 0.5,
    need, centerLat, ourSideIsRight, obsGap, lo, hi, o.pos)
  local leftLat = evaluate(d, ctx, pcp, gapLeft, (distLeft + latRel - obsHalf) * 0.5,
    need, centerLat, ourSideIsRight, obsGap, lo, hi, o.pos)

  local pick, clearance
  if ourSideIsRight then
    pick, clearance = rightLat or leftLat, rightLat and gapRight or gapLeft
  else
    pick, clearance = leftLat or rightLat, leftLat and gapLeft or gapRight
  end
  if not pick then
    -- Queued for our turn over the free lane: creep up to the obstacle and hold there.
    if d.sh.zone and d.sh.waitTime > 0 and d.sh.waitTime < 30 then
      sq.speedCap = obsGap > 10 and 4 or 1.5
      return 'squeeze'
    end
    return nil
  end

  sq.phase, sq.active, sq.target = M.PASS, true, obsId
  sq.timer = PASS_TIMEOUT
  -- Home is the lane centre, not wherever the car happened to be when it committed;
  -- otherwise a manoeuvre that started off-line left the car off-line afterwards.
  sq.homeOffset = ctx.laneCenter
  sq.targetOffset = ctx.roadOffset + pick
  -- Past a crawler you only need to be a little quicker than they are; taking it at speed
  -- is how a filtering move turns into a side-swipe.
  sq.cap = crawling and (pcp.leadSpeed + 2 + d.p.confidence * 2) or (3 + d.p.confidence * 5)
  sq.clearance = clearance
  sq.ignoreId, sq.speedCap = obsId, sq.cap
  hold(ctx, sq)
  return 'squeeze'
end

function M.reset(d)
  shuttle.release(d)
  local sq = d.sq
  sq.active, sq.phase, sq.target, sq.ignoreId = false, M.IDLE, 0, 0
  sq.targetOffset, sq.homeOffset, sq.offset = 0, 0, 0
  sq.speedCap, sq.timer, sq.cooldown, sq.clearance = -1, 0, 0, 0
  sq.waitId, sq.waitTimer, sq.crawling = 0, 0, false
end

return M
