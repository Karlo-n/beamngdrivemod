local M = {}

local random = math.random
local abs = math.abs

local fines = require('trafficAI/behaviors/fines')
local emergency = require('trafficAI/environment/emergency')
local parking = require('trafficAI/behaviors/parking')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')

M.NONE, M.WARN, M.SIGNAL, M.ESCORT, M.PARKED, M.ESCALATED = 0, 1, 2, 3, 4, 5

local TICK = 0.25
local MAX_STOPS = 2
local FIND_RANGE = 90
local LOSE_RANGE = 200
local STOPPED_SPEED = 0.8
local PARK_HOLD = 3
local SIREN_BURST = 5      -- seconds of full lights-and-siren before dropping to lights only
local TUCK_GAP = 4         -- metres the officer wants to sit behind you once you are stopped
local WALK_TIME = 6        -- getting out, walking up, and getting back in again

M.stops = {}     -- keyed by officer id
M.byTarget = {}
M.officers = {}

local stops, byTarget, officers = M.stops, M.byTarget, M.officers
local timer = 0
local toTarget = vec3()
local dead = {}

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

-- Every officer works to the same rulebook and is still a different person: patience is how
-- long they keep asking nicely, strictness is how little it takes for them to ask at all.
local function officer(id)
  local o = officers[id]
  if o then return o end
  o = {
    patience = 16 + random() * 26,
    strictness = 0.25 + random() * 0.65,
    chirpy = random() < 0.5,        -- uses short siren bursts instead of just lights
    escortGap = 9 + random() * 7,
    lecture = 8 + random() * 14,    -- seconds parked before they let you go
    mercy = random() * 0.35,        -- chance per tick of dropping it once you complied
    bookish = random() < 0.55       -- writes the ticket rather than giving a talking-to
  }
  officers[id] = o
  return o
end

local function setLightbar(id, level)
  send(id, 'electrics.set_lightbar_signal(' .. level .. ')')
end

-- Doors latch through the coupler system (see fullsize_doors_F.jbeam: the door_* triggers
-- are couplers with open/close forces), so this is how an officer gets out and back in.
local function toggleDoor(id, right)
  send(id, string.format(
    'local c = controller.getControllerSafe("door_%s_coupler") if c and c.toggleGroup then c.toggleGroup() end',
    right and 'FR' or 'FL'))
end

-- The officer tucks in behind rather than stopping wherever the follow AI happened to be.
-- laneChange lines them up with your side of the road; setStopPoint puts the nose a car
-- length back instead of a bus length.
local function tuckIn(id, gap, lateral)
  send(id, string.format('ai.laneChange(nil, %.1f, %.2f)', gap + 6, lateral))
  send(id, string.format('ai.setStopPoint(nil, %.1f)', gap))
end

-- toggle_* really are toggles, so the published state decides whether the call is needed.
-- turnsignal is 1 for right and -1 for left (electrics.lua:409), the same sign the road
-- rules use for the legal kerb side.
local function setBlinker(id, want)
  local o = map.objects and map.objects[id]
  local cur = (o and o.states and o.states.turnsignal) or 0
  if cur == want then return end
  local target = want ~= 0 and want or cur
  send(id, target > 0 and 'electrics.toggle_right_signal()' or 'electrics.toggle_left_signal()')
end

local function isPlayer(id)
  return id == be:getPlayerVehicleID(0)
end

local function tr(key, fallback)
  if _tr then
    local ok, v = pcall(_tr, key, fallback)
    if ok and v and v ~= key then return v end
  end
  return fallback
end
M.tr = tr

local function say(s, key, duration)
  if isPlayer(s.targetId) then ui_message(key, duration or 5, 'trafficAI') end
end

local function release(s, reason)
  local id = s.officerId
  parking.unreserve(s.layby)
  s.layby = nil
  send(id, 'ai.setStopPoint()')
  setLightbar(id, 0)
  setBlinker(id, 0)
  send(id, 'electrics.set_warn_signal(0)')
  send(id, 'ai.setSpeedMode("legal")')
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local veh = traffic and traffic[id]
  if veh and units.ai(veh) then veh:setAiMode('traffic') end
  byTarget[s.targetId] = nil
  stops[id] = nil
  s.phase, s.reason = M.NONE, reason or ''
end

function M.active(targetId)
  return byTarget[targetId] ~= nil
end

-- Someone did something worth a word rather than a manhunt. severity 0..1 decides whether
-- the officer starts with a look or goes straight to lights and siren.
function M.begin(targetId, reason, severity)
  if byTarget[targetId] or holds.isClaimed(targetId) then return false end
  if not gameplay_police or not gameplay_police.getPoliceVehicles then return false end

  local police = gameplay_police.getPoliceVehicles()
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local objects = map.objects
  local target = traffic and traffic[targetId]
  if not police or not target or not target.pos or not objects then return false end
  if target.pursuit and target.pursuit.mode and target.pursuit.mode > 0 then return false end

  local n = 0
  for _ in pairs(stops) do n = n + 1 end
  if n >= MAX_STOPS then return false end

  -- Nearest free unit that can actually see them.
  local bestId, bestDist = 0, FIND_RANGE
  for pid in pairs(police) do
    if not stops[pid] and not emergency.reserved[pid] and units.ai(traffic[pid]) then
      local o = objects[pid]
      if o and o.pos then
        local dist = o.pos:distance(target.pos)
        if dist < bestDist then bestId, bestDist = pid, dist end
      end
    end
  end
  if bestId == 0 then return false end

  severity = severity or 0.2
  local off = officer(bestId)
  -- A lenient officer lets small things go entirely; nobody ignores a serious one.
  if random() > off.strictness + severity * 0.5 then return false end

  local s = {
    phase = severity > 0.5 and M.SIGNAL or M.WARN,
    officerId = bestId, targetId = targetId, reason = reason or 'control',
    patience = off.patience, maxPatience = off.patience,
    warnTimer = 3 + random() * 4, parkTimer = 0, lectureTimer = 0,
    side = 0, sentSpeed = -1, ahead = false, hazards = false,
    ticketed = false, fine = 0, warning = false,
    sirenTimer = 0, walkTimer = 0, outOfCar = false, tucked = false
  }
  stops[bestId] = s
  byTarget[targetId] = s

  local pveh = traffic[bestId]
  if pveh and units.ai(pveh) then
    pveh:setAiMode('follow')
    send(bestId, 'ai.setTargetObjectID(' .. targetId .. ')')
    send(bestId, 'ai.setAggressionMode("rubberBand")')
  end
  -- Lights straight away; the siren is a short burst to get your attention, not a
  -- permanent noise. Real patrols do not drive around wailing.
  setLightbar(bestId, 1)
  s.sirenTimer = s.phase == M.SIGNAL and SIREN_BURST or 0
  if s.phase == M.SIGNAL then setLightbar(bestId, 2) end
  if off.chirpy and pveh then pveh:useSiren(0.4 + random() * 0.4) end

  if s.phase == M.SIGNAL then
    say(s, 'trafficAI.stop.pullOver', 6)
  else
    say(s, 'trafficAI.stop.noticed', 4)
  end
  return true
end

-- Which side of the road they are pointing you at, and whether there is any room there.
local function kerbSide(target)
  local tr = target.tracking
  if not tr then return 1, false end
  -- Same formula ai.lua's own pull-over uses, so the indicator points where the engine
  -- would actually park the car.
  local side = map.getRoadRules().rightHandDrive and -1 or 1
  local width = (target.width or 2) * 0.5
  -- halfWidth is the road half width at this point; no shoulder means stopping in the lane.
  local room = (tr.halfWidth or 0) - abs(tr.roadOffset or 0) - width > 1.1
  return side, room
end

local function tick(s, step, traffic, objects)
  local off = officer(s.officerId)
  local target = traffic[s.targetId]
  local pol = objects[s.officerId]
  local tObj = objects[s.targetId]
  if not target or not target.pos or not pol or not pol.pos or not tObj then
    release(s, 'perdido')
    return
  end

  if target.pursuit and target.pursuit.mode and target.pursuit.mode > 0 then
    release(s, 'persecucion')
    return
  end

  local dist = pol.pos:distance(target.pos)
  if dist > LOSE_RANGE then
    say(s, 'trafficAI.stop.lostYou', 4)
    release(s, 'fuera de alcance')
    return
  end

  local limit = (target.tracking and target.tracking.speedLimit) or 16
  local tSpeed = target.vel and target.vel:length() or 0
  local pSpeed = pol.vel and pol.vel:length() or 0
  local st = tObj.states
  local indicating = st and ((st.turnsignal and st.turnsignal ~= 0)
    or (st.hazard_enabled and st.hazard_enabled ~= 0))
  local complying = indicating or tSpeed < limit * 0.4 or tSpeed < 3

  -- Are they in front of us or behind? The officer sits behind by default and only ends up
  -- ahead when the target has already slowed right down.
  toTarget:setSub2(target.pos, pol.pos)
  s.ahead = pol.dirVec and toTarget:dot(pol.dirVec) < 0

  local side, room = kerbSide(target)
  s.side = side

  if s.phase == M.WARN then
    -- Still just looking. Lights on, no siren, no drama.
    s.warnTimer = s.warnTimer - step
    if complying then
      s.phase = M.ESCORT
    elseif s.warnTimer <= 0 then
      s.phase = M.SIGNAL
      setLightbar(s.officerId, 2)
      local sideWord = tr(side > 0 and 'trafficAI.stop.sideRight' or 'trafficAI.stop.sideLeft',
        side > 0 and 'derecha' or 'izquierda')
      say(s, (tr('trafficAI.stop.pullOverSide', 'Orillate a la {side}.')
        :gsub('{side}', sideWord)), 6)
    end

  elseif s.phase == M.SIGNAL then
    s.patience = s.patience - step
    setBlinker(s.officerId, side)
    -- Full lights and siren only long enough to be noticed, then lights alone.
    if s.sirenTimer > 0 then
      s.sirenTimer = s.sirenTimer - step
      if s.sirenTimer <= 0 then setLightbar(s.officerId, 1) end
    end
    if complying then
      s.phase = M.ESCORT
      setLightbar(s.officerId, 1)
      say(s, 'trafficAI.stop.goodStop', 4)
    end

  elseif s.phase == M.ESCORT then
    -- Complying: the officer eases off, matches your pace and keeps pointing at the kerb.
    setBlinker(s.officerId, side)
    if complying then
      s.patience = s.patience + step * 0.5
      if s.patience > s.maxPatience then s.patience = s.maxPatience end
      if random() < off.mercy * step then
        say(s, 'trafficAI.stop.letGo', 4)
        release(s, 'aviso verbal')
        return
      end
    else
      -- Back to ignoring them: one more burst, then lights again.
      s.patience = s.patience - step * 1.5
      s.phase = M.SIGNAL
      setLightbar(s.officerId, 2)
      s.sirenTimer = SIREN_BURST
    end

    -- Stopping in a live lane is what a real officer avoids. If there is a lay-by or a
    -- parking area ahead on this road, the stop gets moved into it.
    if not s.laybyChecked then
      s.laybyChecked = true
      local traffic2 = gameplay_traffic and gameplay_traffic.getTrafficData()
      local tv = traffic2 and traffic2[s.targetId]
      if tv and tv.pos and tv.dirVec then
        local ps, fwd = parking.spotAhead(tv.pos, tv.dirVec, 35, 160, s.targetId)
        if ps then
          s.layby = ps
          parking.reserve(ps)
          say(s, 'trafficAI.stop.layby', 6)
          -- An AI driver can be sent there; the player just gets told.
          if not isPlayer(s.targetId) and map.findClosestRoad then
            local node = map.findClosestRoad(ps.pos)
            if node then
              send(s.targetId, string.format(
                'ai.driveUsingPath{wpTargetList = {"%s"}, driveInLane = "on", ' ..
                'avoidCars = "on", routeSpeed = 11, routeSpeedMode = "limit", ' ..
                'aggression = 0.3}', node))
            end
          end
        end
      end
    end

    -- Match their pace, but close the gap if they have hung back. Sitting 30 m away is
    -- what made it look like the patrol had lost interest.
    local want = tSpeed + 1.5
    if dist > off.escortGap + 6 then want = tSpeed + 5 end
    if want < 3 then want = 3 end
    if s.sentSpeed < 0 or abs(want - s.sentSpeed) > 1.5 then
      s.sentSpeed = want
      send(s.officerId, 'ai.setSpeedMode("limit")')
      send(s.officerId, string.format('ai.setSpeed(%.2f)', want))
    end

    -- Once you have almost stopped, the officer commits to a spot right behind you and
    -- lines up with whatever side of the road you actually ended up on.
    if tSpeed < 2.5 and not s.tucked then
      s.tucked = true
      local tr = target.tracking
      local lateral = 0
      if tr and pol.pos and target.pos then
        toTarget:setSub2(target.pos, pol.pos)
        -- ai.laneChange and roadOffset share a sign, so this is simply where they are
        -- minus where we are.
        lateral = (tr.roadOffset or 0) - ((pol.tracking and pol.tracking.roadOffset) or 0)
        if lateral > 4 then lateral = 4 elseif lateral < -4 then lateral = -4 end
      end
      tuckIn(s.officerId, TUCK_GAP, lateral)
    elseif tSpeed > 4 and s.tucked then
      s.tucked = false
      send(s.officerId, 'ai.setStopPoint()')
    end
  end

  -- Both stopped: the stop is happening here, wherever "here" turns out to be.
  if s.phase ~= M.ESCALATED and tSpeed < STOPPED_SPEED and pSpeed < STOPPED_SPEED then
    s.parkTimer = s.parkTimer + step
    if s.parkTimer > PARK_HOLD and s.phase ~= M.PARKED then
      s.phase = M.PARKED
      s.lectureTimer = off.lecture
      setLightbar(s.officerId, 1)
      setBlinker(s.officerId, 0)
      -- Out of the car and up to your window.
      s.walkTimer, s.outOfCar = WALK_TIME, true
      toggleDoor(s.officerId, false)
      say(s, 'trafficAI.stop.officerOut', 4)
      -- No shoulder to use, so hazards: this is where we are stopping, mind us.
      if not room and not s.hazards then
        s.hazards = true
        send(s.officerId, 'electrics.set_warn_signal(1)')
        say(s, 'trafficAI.stop.noShoulder', 5)
      end
    end
  else
    s.parkTimer = 0
    if s.phase == M.PARKED then s.phase = M.ESCORT end
  end

  if s.phase == M.PARKED then
    s.lectureTimer = s.lectureTimer - step
    if s.walkTimer > 0 then
      s.walkTimer = s.walkTimer - step
      if s.walkTimer <= 0 then toggleDoor(s.officerId, false) end -- door shut behind them
    end
    -- Halfway through the stop they have finished with your papers and decide.
    if not s.ticketed and s.lectureTimer < off.lecture * 0.45 then
      s.ticketed = true
      local strict = off.bookish and off.strictness or off.strictness * 0.4
      local amount, warning = fines.issue(target, s.reason, strict, isPlayer(s.targetId))
      s.fine, s.warning = amount, warning
      if isPlayer(s.targetId) and fines.last then
        ui_message(fines.last.text, 8, 'trafficAI')
      end
      if not warning then fines.clearRecord(target) end
    end
    -- Back to the patrol car, in, door shut, and only then do they leave.
    if s.lectureTimer <= 1.5 and s.outOfCar then
      s.outOfCar = false
      toggleDoor(s.officerId, false)
      send(s.officerId, 'electrics.set_warn_signal(0)')
    end
    if s.lectureTimer <= 0 then
      if s.fine and s.fine > 0 then
        say(s, (tr('trafficAI.stop.fineTotal', 'Total de multas: {total}.')
          :gsub('{total}', tostring(fines.total))), 5)
      else
        say(s, 'trafficAI.stop.allClear', 5)
      end
      release(s, 'resuelto')
    end
    return
  end

  if s.patience <= 0 then
    s.phase = M.ESCALATED
    if gameplay_police.setPursuitMode then gameplay_police.setPursuitMode(1, s.targetId) end
    say(s, 'trafficAI.stop.outOfPatience', 5)
    release(s, 'escalado')
  end
end

function M.update(dt)
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK
  if next(stops) == nil then return end

  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local objects = map.objects
  if not traffic or not objects then return end

  -- Collected first because tick() may remove entries from the table being walked.
  local n = 0
  for _, s in pairs(stops) do n = n + 1 dead[n] = s end
  for i = 1, n do tick(dead[i], TICK, traffic, objects) dead[i] = nil end
end

function M.onVehicleRemoved(id)
  local s = stops[id] or byTarget[id]
  if s then release(s, 'retirado') end
  officers[id] = nil
end

function M.reset()
  for _, s in pairs(stops) do
    byTarget[s.targetId] = nil
  end
  table.clear(stops)
  table.clear(byTarget)
  table.clear(officers)
end

return M
