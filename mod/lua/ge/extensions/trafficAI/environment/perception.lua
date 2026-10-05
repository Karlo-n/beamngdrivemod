local M = {}

local max = math.max
local min = math.min

local MAX_NEIGHBOURS = 12
local SCAN_RANGE = 70
local SCAN_RANGE_SQ = SCAN_RANGE * SCAN_RANGE
-- Oncoming traffic is checked much further out than anything else, because deciding to use
-- the other side of the road depends on distances an overtake actually covers.
local FAR_RANGE = 230
local FAR_RANGE_SQ = FAR_RANGE * FAR_RANGE
local CORRIDOR_HALF = 1.5
local CORRIDOR_HALF_SQ = CORRIDOR_HALF * CORRIDOR_HALF
local STOPPED_SPEED = 0.6
local RAY_PERIOD = 1.0 -- seconds between raycasts per driver
local ONCOMING_HALF_SQ = 6 * 6
local THREAT_HALF = 1.5 -- narrower than a lane: a car in the opposite lane is not a threat
local THREAT_HALF_SQ = THREAT_HALF * THREAT_HALF
local THREAT_TTC = 6
local SIGNAL_RANGE = 140
local SIGNAL_HALF_WIDTH_SQ = 10 * 10 -- generous: signals sit at the roadside, not on the lane
local HISTORY = 4
local SNAPSHOT_MAX = 64

-- core_trafficSignals.controllerDefinitions.signalActions
M.ACTION_NONE, M.ACTION_ALERT, M.ACTION_STOP = 0, 1, 2
M.ACTION_BRIEF_STOP, M.ACTION_YIELD, M.ACTION_SLOW = 3, 4, 5

M.ACTION_NAME = {[0] = 'none', 'alert', 'stop', 'briefStop', 'yield', 'slow'}

-- Single snapshot reused by every vehicle; behaviours consume it inside the same tick.
local P = {
  id = 0, valid = false,
  leadId = 0, leadGap = -1, leadSpeed = 0, leadRelSpeed = 0, leadDecel = 0, leadStopped = false,
  lead2Gap = -1, lead2Speed = 0, -- the car in front of the car in front
  tgtValid = false, tgtFrontGap = -1, tgtFrontSpeed = 0, tgtRearGap = -1, tgtRearSpeed = 0,
  obstacleId = 0, obstacleGap = -1, obstacleHazard = false, rayGap = -1,
  leadSignal = 0, leadHazard = false, hornNearby = false, mergerId = 0, mergerGap = 0,
  oncomingId = 0, oncomingGap = -1, oncomingSpeed = 0,
  threatId = 0, threatGap = -1, threatTtc = -1, threatLat = 0,
  rearId = 0, rearGap = -1, rearSpeed = 0,
  signalDist = -1, signalAction = 0, signalState = '',
  neighbourCount = 0, neighbours = {}
}

for i = 1, MAX_NEIGHBOURS do
  P.neighbours[i] = {id = 0, dist = 0, fwd = 0, lat = 0, latSigned = 0, rawFwd = 0,
                     halfLen = 0, halfW = 0, speed = 0, relSpeed = 0, sameLane = false}
end

M.data = P

-- Every driver used to walk map.objects (a hash) on its own tick. This flattens it once per
-- frame into parallel arrays that all of them scan instead. References are stored rather
-- than copies, so it stays live and allocates nothing after the first build.
local snap = {n = 0, id = {}, pos = {}, dir = {}, speed = {}, states = {},
              halfLen = {}, halfW = {}}
-- Vehicles far from the camera get a cheaper tick. Nobody can see them misbehave, and the
-- cost of the full pipeline is dominated by the ones on screen.
M.camPos = vec3()
M.camDistSq = {}
M.snapshot = snap

-- Sizes change only when a vehicle is added or removed, so they are cached rather than
-- looked up for every vehicle on every frame.
local sizeCache = {}

function M.forgetSize(id)
  sizeCache[id] = nil
end

local function halfSize(id)
  local c = sizeCache[id]
  if c then return c[1], c[2] end
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local v = traffic and traffic[id]
  local l, w = 4.6, 2.0
  if v and v.length and v.length > 0 then l, w = v.length, v.width or 2.0 end
  c = {l * 0.5, w * 0.5}
  sizeCache[id] = c
  return c[1], c[2]
end

function M.refreshSnapshot()
  local objects = map.objects
  local n = 0
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then M.camPos:set(p) end
  end
  local cam, camDist = M.camPos, M.camDistSq
  table.clear(camDist) -- rebuilt every sweep, so removed vehicles cannot linger
  if objects then
    for oid, o in pairs(objects) do
      if o.pos and n < SNAPSHOT_MAX then
        n = n + 1
        snap.id[n], snap.pos[n], snap.dir[n] = oid, o.pos, o.dirVec
        snap.speed[n] = o.vel and o.vel:length() or 0
        snap.states[n] = o.states
        snap.halfLen[n], snap.halfW[n] = halfSize(oid)
        camDist[oid] = o.pos:squaredDistance(cam)
      end
    end
  end
  snap.n = n
end

local toOther = vec3()
local lateralOffset = vec3()
local rayFrom = vec3()
local rayDir = vec3()

function M.newMemory()
  -- The shared snapshot is overwritten by the next vehicle, so the few values the overlay
  -- needs are mirrored here, per driver.
  local m = {idx = 0, count = 0, rayTimer = 0, spd = {}, gap = {}, t = {},
             rayGap = -1, leadRel = 0, leadDecel = 0, neighbours = 0, lastGap = -1,
             signalDist = -1, signalAction = 0,
             tgtFront = -1, tgtRear = -1, tgtSafe = -1,
             threatTtc = -1, threatId = 0}
  for i = 1, HISTORY do
    m.spd[i], m.gap[i], m.t[i] = 0, 0, 0
  end
  return m
end

local function pushHistory(pm, now, speed, gap)
  pm.idx = pm.idx % HISTORY + 1
  pm.spd[pm.idx], pm.gap[pm.idx], pm.t[pm.idx] = speed, gap, now
  if pm.count < HISTORY then pm.count = pm.count + 1 end
end

-- Oldest sample still in the ring, so a hard brake shows up as a large negative slope.
local function leaderDecel(pm, now, speedNow)
  if pm.count < 2 then return 0 end
  local oldest = pm.idx % HISTORY + 1
  if pm.count < HISTORY then oldest = 1 end
  local dt = now - pm.t[oldest]
  if dt < 0.1 then return 0 end
  return (pm.spd[oldest] - speedNow) / dt
end

-- Flat list of references into mapNodeSignals. Those entry tables are mutated in place
-- when a light changes (trafficSignals.lua:1591), so cached references stay live and only
-- need rebuilding when the signal set itself changes.
local signalList, signalCount, signalAge = {}, 0, 0

local function rebuildSignalList()
  signalCount = 0
  if not core_trafficSignals then return end
  local dict = core_trafficSignals.getMapNodeSignals()
  if not dict then return end
  for _, byNode in pairs(dict) do
    for _, list in pairs(byNode) do
      for i = 1, #list do
        if list[i].pos then
          signalCount = signalCount + 1
          signalList[signalCount] = list[i]
        end
      end
    end
  end
end

function M.invalidateSignals()
  signalAge, signalCount = 0, 0
end

-- The exact segment lookup only fires for the car sitting on the signal's own segment,
-- which is why everyone queued behind it saw nothing. This also scans ahead by distance.
local function readSignal(ctx, d, now)
  P.signalDist, P.signalAction, P.signalState = -1, 0, ''
  if not core_trafficSignals then return end

  -- Counted in sense() calls rather than seconds: driver clocks reset on respawn and
  -- would make a time-based check rebuild far more often than intended.
  signalAge = signalAge - 1
  if signalAge <= 0 then
    signalAge = 2000
    rebuildSignalList()
  end
  if signalCount == 0 then return end

  local pos, dir = ctx.pos, ctx.dir
  local best, bestFwd = nil, SIGNAL_RANGE
  for i = 1, signalCount do
    local s = signalList[i]
    toOther:setSub2(s.pos, pos)
    local fwd = toOther:dot(dir)
    if fwd > 0 and fwd < bestFwd then
      toOther:setAddScaled(toOther, dir, -fwd)
      toOther.z = 0
      if toOther:squaredLength() < SIGNAL_HALF_WIDTH_SQ then
        bestFwd, best = fwd, s
      end
    end
  end
  if not best then return end

  P.signalDist = bestFwd
  P.signalAction = best.action or 0
  P.signalState = best.state or ''
end

-- One pass over every vehicle in the world, not just traffic, so parked and player
-- vehicles register too. map.objects is the only table that carries all of them.
function M.sense(ctx, d, dt, now)
  local objects = map.objects
  P.id, P.valid = ctx.id, false
  P.leadId, P.leadGap, P.leadSpeed, P.leadRelSpeed = 0, -1, 0, 0
  P.leadDecel, P.leadStopped = 0, false
  P.lead2Gap, P.lead2Speed = -1, 0
  P.obstacleId, P.obstacleGap, P.obstacleHazard = 0, -1, false
  P.oncomingId, P.oncomingGap, P.oncomingSpeed = 0, -1, 0
  P.leadSignal, P.leadHazard, P.hornNearby = 0, false, false
  P.mergerId, P.mergerGap = 0, 0
  P.threatId, P.threatGap, P.threatTtc, P.threatLat = 0, -1, -1, 0
  P.rearId, P.rearGap, P.rearSpeed = 0, -1, 0
  P.tgtValid = false
  P.neighbourCount = 0
  if not objects then return P end

  local selfId, pos, dir, mySpeed = ctx.id, ctx.pos, ctx.dir, ctx.speed
  -- Every gap below is bumper to bumper. Using centre-to-centre made a 12 m lorry look
  -- 8 m further away than it was, which is why traffic tailgated and misjudged trucks.
  local myHalfLen = (ctx.veh.length or 4.6) * 0.5
  local myHalfW = (ctx.veh.width or 2.0) * 0.5
  -- Seventy metres is nothing at motorway speed: a stopped car seen that late cannot be
  -- braked for. The leader is looked for five to seven seconds ahead instead.
  local leadRange = mySpeed * (4.5 + d.s.perception * 2.5)
  -- Once seen it stays seen: the range shrinks as the car slows, and must not drop the very
  -- thing it is slowing for.
  local kept = d.pm.lastGap + 10
  if leadRange < kept then leadRange = kept end
  if leadRange < SCAN_RANGE then leadRange = SCAN_RANGE elseif leadRange > 220 then leadRange = 220 end
  local bestFwd, count = leadRange, 0
  local secondFwd = leadRange
  local obstacleFwd, oncomingFwd, rearFwd = SCAN_RANGE, FAR_RANGE, SCAN_RANGE
  local mergerBest = 1e9

  if snap.n == 0 then M.refreshSnapshot() end
  local sid, spos, sdir, sspd, sst = snap.id, snap.pos, snap.dir, snap.speed, snap.states
  local shl, shw = snap.halfLen, snap.halfW

  for i = 1, snap.n do
    local oid = sid[i]
    if oid ~= selfId then
      toOther:setSub2(spos[i], pos)
      local d2 = toOther:squaredLength()
      if d2 < FAR_RANGE_SQ then
        local rawFwd = toOther:dot(dir)
        -- Anything far away only matters as oncoming traffic, and only if it is ahead.
        if d2 < SCAN_RANGE_SQ or rawFwd > 0 then
        local lat = toOther:dot(ctx.rightVec)
        local latSq = d2 - rawFwd * rawFwd
        if latSq < 0 then latSq = 0 end
        local speed = sspd[i]
        local odir, states = sdir[i], sst[i]
        local oHalfLen, oHalfW = shl[i], shw[i]
        -- Bumper to bumper, keeping the sign: positive ahead, negative behind.
        local fwd = rawFwd
        if rawFwd > 0 then
          fwd = rawFwd - myHalfLen - oHalfLen
          if fwd < 0 then fwd = 0 end
        elseif rawFwd < 0 then
          fwd = rawFwd + myHalfLen + oHalfLen
          if fwd > 0 then fwd = 0 end
        end
        local near = rawFwd * rawFwd + latSq < SCAN_RANGE_SQ
        -- A wide lorry occupies our lane from further off centre than a hatchback does.
        local corridor = CORRIDOR_HALF + oHalfW + myHalfW - 1.95
        if corridor < CORRIDOR_HALF then corridor = CORRIDOR_HALF end
        local inLane = near and latSq < corridor * corridor
        -- That far out the road may have curved away, so only a car dead ahead and pointing
        -- the same way is trusted to be on it.
        local farLead = not near and rawFwd < leadRange and latSq < CORRIDOR_HALF_SQ
          and odir and odir:dot(dir) > 0.94

        -- Indicators, hazards and horns are published by every vehicle. Reading them is the
        -- difference between reacting to a manoeuvre and only reacting to its result.
        if states and near then
          if states.horn and states.horn ~= 0 and rawFwd * rawFwd + latSq < 900 then
            P.hornNearby = true
          end
          -- Someone in the next lane indicating toward us is asking to be let in.
          local sig = states.turnsignal
          if sig and sig ~= 0 and fwd > -6 and fwd < 45 and fwd < mergerBest then
            local wantsRight = sig > 0
            if (lat > 1.5 and not wantsRight) or (lat < -1.5 and wantsRight) then
              mergerBest = fwd
              P.mergerId, P.mergerGap = oid, fwd
            end
          end
        end

        if near and count < MAX_NEIGHBOURS then
          count = count + 1
          local n = P.neighbours[count]
          n.id, n.fwd, n.rawFwd, n.speed = oid, fwd, rawFwd, speed
          n.lat = latSq > 0 and math.sqrt(latSq) or 0
          n.latSigned = lat
          n.halfLen, n.halfW = oHalfLen, oHalfW
          n.dist = math.sqrt(rawFwd * rawFwd + latSq)
          n.relSpeed = speed - mySpeed
          n.sameLane = inLane
        end

        -- Whoever is closest behind in our own lane: the source of tailgating pressure.
        if inLane and fwd < -0.5 and -fwd < rearFwd and odir and odir:dot(dir) > 0.5 then
          rearFwd = -fwd
          P.rearId, P.rearGap, P.rearSpeed = oid, -fwd, speed
        end

        if (inLane or farLead) and fwd > 0.5 then
          if fwd < bestFwd then
            -- Whoever was nearest so far is now second in line.
            if P.leadId ~= 0 then
              secondFwd = bestFwd
              P.lead2Gap, P.lead2Speed = bestFwd, P.leadSpeed
            end
            bestFwd = fwd
            P.leadId, P.leadGap, P.leadSpeed = oid, fwd, speed
            P.leadSignal = (states and states.turnsignal) or 0
            P.leadHazard = (states and states.hazard_enabled and states.hazard_enabled ~= 0) or false
          elseif fwd < secondFwd then
            secondFwd = fwd
            P.lead2Gap, P.lead2Speed = fwd, speed
          end
          if speed < STOPPED_SPEED and fwd < obstacleFwd then
            obstacleFwd = fwd
            P.obstacleId, P.obstacleGap = oid, fwd
            P.obstacleHazard = (states and states.hazard_enabled and states.hazard_enabled ~= 0) or false
          end
        end

        -- Anything ahead facing us counts as oncoming, however far off our own corridor.
        local facingUs = odir and odir:dot(dir) < -0.5
        if fwd > 0 and fwd < oncomingFwd and latSq < ONCOMING_HALF_SQ and facingUs and speed > 1 then
          oncomingFwd = fwd
          P.oncomingId, P.oncomingGap, P.oncomingSpeed = oid, fwd, speed
        end

        -- A threat is narrower: something actually lined up with us and closing. Head-on
        -- closing speed is the sum, which is why these go critical so much faster.
        if near and fwd > 0.5 and latSq < THREAT_HALF_SQ and facingUs then
          local closing = mySpeed + speed
          if closing > 1.5 then
            local ttc = fwd / closing
            if ttc < THREAT_TTC and (P.threatTtc < 0 or ttc < P.threatTtc) then
              P.threatId, P.threatGap, P.threatTtc = oid, fwd, ttc
              P.threatLat = lat -- signed: which side to dodge away from
            end
          end
        end
        end
      end
    end
  end

  P.neighbourCount = count
  P.valid = true

  if P.leadId ~= 0 then
    P.leadRelSpeed = P.leadSpeed - mySpeed
    P.leadStopped = P.leadSpeed < STOPPED_SPEED
    local pm = d.pm
    P.leadDecel = leaderDecel(pm, now, P.leadSpeed)
    pushHistory(pm, now, P.leadSpeed, P.leadGap)
  else
    d.pm.count = 0
  end
  d.pm.lastGap = P.leadGap

  -- Static geometry ray, throttled to 1 Hz per driver. Advisory only: on curved roads it
  -- hits the terrain beside the road, so it must not drive braking on its own.
  local pm = d.pm
  pm.rayTimer = pm.rayTimer - dt
  if pm.rayTimer <= 0 then
    pm.rayTimer = RAY_PERIOD
    local tr = ctx.tracking
    if tr and tr.alignment and tr.alignment > 0.97 and mySpeed > 3 then
      rayFrom:set(pos)
      rayFrom.z = rayFrom.z + 0.8
      rayDir:set(dir)
      local range = min(50, mySpeed * 3)
      local hit = castRayStatic(rayFrom, rayDir, range)
      pm.rayGap = (hit and hit < range) and hit or -1
    else
      pm.rayGap = -1
    end
  end
  P.rayGap = pm.rayGap

  readSignal(ctx, d, now)

  pm.leadRel, pm.leadDecel, pm.neighbours = P.leadRelSpeed, P.leadDecel, count
  pm.signalDist, pm.signalAction = P.signalDist, P.signalAction
  pm.threatTtc, pm.threatId = P.threatTtc, P.threatId
  return P
end

-- Longitudinal and lateral offset of one specific vehicle, relative to us.
function M.relativeTo(ctx, id)
  local objects = map.objects
  local o = objects and objects[id]
  if not o or not o.pos then return nil end
  toOther:setSub2(o.pos, ctx.pos)
  local fwd = toOther:dot(ctx.dir)
  local lat = toOther:dot(ctx.rightVec)
  return fwd, lat, o.vel and o.vel:length() or 0
end

-- Cut-down version for vehicles far from the camera: only the car in front, which is all
-- the reduced pipeline reads. Skips signals, threats, mergers and the neighbour list.
function M.senseLight(ctx, d, dt, now)
  P.id, P.valid = ctx.id, false
  P.leadId, P.leadGap, P.leadSpeed, P.leadRelSpeed = 0, -1, 0, 0
  P.leadDecel, P.leadStopped = 0, false
  P.lead2Gap, P.lead2Speed = -1, 0
  P.obstacleId, P.obstacleGap, P.obstacleHazard = 0, -1, false
  P.oncomingId, P.oncomingGap, P.oncomingSpeed = 0, -1, 0
  P.leadSignal, P.leadHazard, P.hornNearby = 0, false, false
  P.mergerId, P.mergerGap = 0, 0
  P.threatId, P.threatGap, P.threatTtc, P.threatLat = 0, -1, -1, 0
  P.rearId, P.rearGap, P.rearSpeed = 0, -1, 0
  P.tgtValid, P.neighbourCount = false, 0

  local selfId, pos, dir, mySpeed = ctx.id, ctx.pos, ctx.dir, ctx.speed
  local myHalfLen = (ctx.veh.length or 4.6) * 0.5
  local myHalfW = (ctx.veh.width or 2.0) * 0.5
  local bestFwd = SCAN_RANGE
  local sid, spos, sspd = snap.id, snap.pos, snap.speed
  local shl, shw = snap.halfLen, snap.halfW

  for i = 1, snap.n do
    local oid = sid[i]
    if oid ~= selfId then
      toOther:setSub2(spos[i], pos)
      local d2 = toOther:squaredLength()
      if d2 < SCAN_RANGE_SQ then
        local rawFwd = toOther:dot(dir)
        if rawFwd > 0.5 then
          local latSq = d2 - rawFwd * rawFwd
          local corridor = CORRIDOR_HALF + shw[i] + myHalfW - 1.95
          if corridor < CORRIDOR_HALF then corridor = CORRIDOR_HALF end
          if latSq < corridor * corridor then
            local gap = rawFwd - myHalfLen - shl[i]
            if gap < 0 then gap = 0 end
            if gap < bestFwd then
              bestFwd = gap
              P.leadId, P.leadGap, P.leadSpeed = oid, gap, sspd[i]
            end
          end
        end
      end
    end
  end

  P.valid = true
  if P.leadId ~= 0 then
    P.leadRelSpeed = P.leadSpeed - mySpeed
    P.leadStopped = P.leadSpeed < STOPPED_SPEED
    local pm = d.pm
    P.leadDecel = leaderDecel(pm, now, P.leadSpeed)
    pushHistory(pm, now, P.leadSpeed, P.leadGap)
  else
    d.pm.count = 0
  end
  return P
end

-- Front and rear gaps in a lane offset laterally by laneDelta (roadOffset units).
function M.senseTargetLane(ctx, d, laneDelta)
  P.tgtValid = false
  P.tgtFrontGap, P.tgtRearGap = -1, -1
  P.tgtFrontSpeed, P.tgtRearSpeed = 0, 0

  local myHalfLen = (ctx.veh.length or 4.6) * 0.5
  local myHalfW = (ctx.veh.width or 2.0) * 0.5
  local front, rear = SCAN_RANGE, SCAN_RANGE

  for i = 1, P.neighbourCount do
    local n = P.neighbours[i]
    -- Distance from the neighbour to the centre line of the lane we are eyeing up.
    local off = n.latSigned - laneDelta
    if off < 0 then off = -off end
    local corridor = CORRIDOR_HALF + n.halfW + myHalfW - 1.95
    if corridor < CORRIDOR_HALF then corridor = CORRIDOR_HALF end
    if off < corridor then
      local rawFwd = n.rawFwd
      -- Bumper to bumper here too, so pulling out in front of a lorry needs the room
      -- a lorry actually takes up.
      local gap = (rawFwd >= 0 and rawFwd or -rawFwd) - myHalfLen - n.halfLen
      if gap < 0 then gap = 0 end
      if rawFwd >= 0 then
        if gap < front then
          front = gap
          P.tgtFrontGap, P.tgtFrontSpeed = gap, n.speed
        end
      elseif gap < rear then
        rear = gap
        P.tgtRearGap, P.tgtRearSpeed = gap, n.speed
      end
    end
  end

  P.tgtValid = true
  local pm = d.pm
  pm.tgtFront, pm.tgtRear = P.tgtFrontGap, P.tgtRearGap
end

return M
