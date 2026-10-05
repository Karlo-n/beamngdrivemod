local abs = math.abs
local min = math.min
local max = math.max
local random = math.random

local driver = require('trafficAI/core/driver')
local stateMachine = require('trafficAI/core/stateMachine')
local memory = require('trafficAI/core/memory')
local perception = require('trafficAI/environment/perception')
local base = require('trafficAI/behaviors/baseBehavior')
local carFollowing = require('trafficAI/behaviors/carFollowing')
local laneChange = require('trafficAI/behaviors/laneChange')
local squeeze = require('trafficAI/behaviors/squeeze')
local overtake = require('trafficAI/behaviors/overtake')
local evasion = require('trafficAI/behaviors/evasion')
local emergencyYield = require('trafficAI/behaviors/emergencyYield')
local intimidation = require('trafficAI/behaviors/intimidation')
local pursuit = require('trafficAI/behaviors/pursuit')
local driving = require('trafficAI/behaviors/driving')
local attitude = require('trafficAI/behaviors/attitude')
local hero = require('trafficAI/behaviors/hero')
local conditions = require('trafficAI/environment/conditions')
local emergency = require('trafficAI/environment/emergency')
local places = require('trafficAI/environment/places')
local parking = require('trafficAI/behaviors/parking')
local units = require('trafficAI/util/units')
local holds = require('trafficAI/util/holds')

local AGG_EPS = 0.03 -- queueLuaCommand crosses threads, so only resend when the value really moved
local LOD_FAR_SQ = 150 * 150 -- beyond this the full behaviour pipeline is not worth paying for

local C = {}

local function getDriver(id)
  return trafficAI_main and trafficAI_main.getDriver(id) or nil
end

function C:init()
  self.class = 'trafficAI'
  self.actions = {}
  for k, v in pairs(self.baseActions) do
    self.actions[k] = v
  end
  self.baseActions = nil

  -- baseRole's pullOver stops at brakingDistance + 20 m, which after a crash means driving
  -- off down the road. This one edges to the legal kerb and stops within a few metres.
  self.actions.crashPark = function(args)
    self.state = 'pullOver'
    self.flags.pullOver = 1
    local veh = self.veh
    if not units.ai(veh) then return end

    veh:setAiMode('traffic')
    local dist = self:clearOfJunction(args.dist or 8)
    local side = map.getRoadRules().rightHandDrive and -1 or 1
    veh.queuedFuncs.trafficAIpark = {timer = 0.25, vLua = string.format(
      'ai.laneChange(nil, %.1f, %.2f) ai.setStopPoint(nil, %.1f)', dist, side * (args.shift or 2.5), dist)}
    if args.hazards ~= false then self:setHazards() end
  end
end

-- ai.setPullOver is the engine's own kerbside stop (ai.lua:4402): it measures the road
-- half width, offsets by the car's own width and calls setStopPoint with avoidJunction.
-- Far better than driving a laneChange by hand, and it is only wired up from here.
function C:parkAtKerb(withSignal)
  local veh = self.veh
  if not units.ai(veh) then return end
  veh:setAiMode('traffic')
  local obj = getObjectByID(veh.id)
  if not obj then return end
  if withSignal then self:signalSide(map.getRoadRules().rightHandDrive and -1 or 1) end
  obj:queueLuaCommand(units.KERB_STOP)
end

function C:leaveKerb()
  local veh = self.veh
  local obj = getObjectByID(veh.id)
  if not obj then return end
  obj:queueLuaCommand('ai.setPullOver(false)')
  -- Indicating back out into the lane; the pulse stops itself once the turn completes.
  self:signalSide(map.getRoadRules().rightHandDrive and 1 or -1)
end

-- turnsignal is 1 for right, -1 for left. toggle_* flips, so an indicator already on that
-- side would be switched off by a blind call.
function C:signalSide(side)
  local o = map.objects and map.objects[self.veh.id]
  if o and o.states and o.states.turnsignal == side then return end
  local obj = getObjectByID(self.veh.id)
  if not obj then return end
  obj:queueLuaCommand(side > 0 and 'electrics.toggle_right_signal()'
    or 'electrics.toggle_left_signal()')
end

-- electrics.set_warn_signal restarts the indicator pulse every call, so this fires once and
-- schedules a single repeat for after ai.reset() has wiped the electrics.
function C:setHazards()
  local veh = self.veh
  local obj = getObjectByID(veh.id)
  if not obj then return end
  obj:queueLuaCommand('electrics.set_warn_signal(1)')
  veh.queuedFuncs.taiHazard = {timer = 0.7, vLua = 'electrics.set_warn_signal(1)'}
end

-- Stopping inside a junction blocks every approach to it, not just one lane. If one is
-- close ahead, the stop point is pushed past it instead.
function C:clearOfJunction(dist)
  local tr = self.veh.tracking
  if not tr or not tr.n2 or tr.n2 == '' then return dist end
  local nodes = map.getMap() and map.getMap().nodes
  local node = nodes and nodes[tr.n2]
  if not node or not node.links then return dist end

  local links = 0
  for _ in pairs(node.links) do links = links + 1 end
  if links <= 2 then return dist end -- plain road, not a junction

  local ahead = node.pos and (node.pos:distance(self.veh.pos)) or 1e9
  if ahead > dist + 12 then return dist end
  return ahead + 18
end

-- How far this vehicle can move toward the legal kerb before it runs out of road.
function C:kerbShift()
  local veh = self.veh
  local tr = veh.tracking
  if not tr or not tr.halfWidth or tr.halfWidth <= 0 then return 2.5 end
  -- rightHandDrive means right-hand *drive* cars, i.e. traffic on the left.
  local legalIsRight = not map.getRoadRules().rightHandDrive
  local room = tr.halfWidth * 2 * (legalIsRight and (1 - tr.roadXnorm) or tr.roadXnorm)
  local shift = room - (veh.width or 2.0) * 0.5 - 0.8
  return shift < 0.4 and 0.4 or (shift > 6 and 6 or shift)
end

-- Not every stopped car is a broken one. Drivers pull over to take a call, check the map
-- or drop something off, sit there a while, and then rejoin. It costs nothing and it is the
-- single cheapest thing that stops traffic looking like a conveyor belt.
function C:updateRoadsideStop(d, ctx, tickTime)
  local rs = d.rs
  rs.timer = rs.timer - tickTime

  if rs.state == 1 then
    if rs.timer > 0 then return true end
    rs.state, rs.timer = 0, d.isBus and (40 + random() * 60) or (90 + random() * 240)
    if rs.hazards then
      rs.hazards = false
      base.send(self.veh.id, 'electrics.set_warn_signal(0)')
    end
    self:leaveKerb()
    self:resetAction()
    stateMachine.set(d, 'normal')
    return false
  end

  if rs.timer > 0 then return false end
  rs.timer = d.isBus and (40 + random() * 60) or (45 + random() * 150)
  if d.crashState > 0 or not ctx.valid or ctx.speed < 5 then return false end
  if ctx.ourLanes > 1 and ctx.laneIdx < ctx.ourLanes - 1 then return false end

  -- Who stops, and why. A city bus works its stops; a delivery van in town stops wherever
  -- the drop is, shoulder or not; in a real downpour the careful ones wait it out.
  local urban = ctx.limit > 0 and ctx.limit <= 17
  local bus = d.isBus and urban
  local delivery = d.typeId == 'delivery' and urban
  local downpour = conditions.rain > 0.8
  local chance = bus and 0.6 or (delivery and 0.25 or d.d.errandChance)
  if downpour then chance = chance + d.p.prudence * 0.1 end
  if random() > chance then return false end

  -- Only where there is a shoulder to stop on. 0.8 m of room is exactly what an ordinary
  -- 3.5 m lane has, so that test let cars stop in the middle of a live lane. Buses and
  -- delivery vans are the exception everyone knows: they stop in the lane and you go round.
  local shoulder = self:kerbShift() >= 1.8
  if not shoulder and not (bus or delivery) then return false end

  -- Stopping right by a petrol station reads as filling up, and people linger longer there.
  local fuelling = not bus and places.nearStation(self.veh.pos)
  rs.state = 1
  if bus then
    rs.timer, rs.reason = 10 + random() * 18, 'parada de bus'
  elseif fuelling then
    rs.timer, rs.reason = 45 + random() * 70, 'gasolinera'
  elseif delivery and not shoulder then
    rs.timer, rs.reason = 20 + random() * 35, 'reparto en doble fila'
  elseif downpour then
    rs.timer, rs.reason = 30 + random() * 60, 'esperando que amaine'
  else
    rs.timer, rs.reason = 14 + random() * 55, delivery and 'reparto' or 'recado'
  end
  self.state = 'pullOver'
  self.flags.pullOver = 1
  self:parkAtKerb(true)
  -- Stopped where nobody expects a car to stop: hazards, so the cars behind know to go round.
  rs.hazards = (delivery and not shoulder) or downpour
  if rs.hazards then self:setHazards() end
  return true
end

function C:generatePersonality()
  local d = getDriver(self.veh.id)
  if not d then return end
  return {aggression = d.p.aggression, patience = d.p.patience, bravery = d.d.bravery}
end

function C:pushAiParameters()
  local d = self.d
  if not d or not units.ai(self.veh) then return end
  local dd = d.d
  getObjectByID(self.veh.id):queueLuaCommand(string.format(
    'ai.setParameters({lookAheadKv=%.2f,awarenessForceCoef=%.2f,turnForceCoef=%.2f,trafficWaitTime=%.2f})',
    dd.lookAhead, dd.awareness, dd.turnForce, dd.waitTime))
end

function C:syncAggression()
  local d = self.d
  local target = driver.aggression(d)
  if abs(target - d.sentAgg) < AGG_EPS then return end
  d.sentAgg = target
  self.driver.aggression = target
  getObjectByID(self.veh.id):queueLuaCommand(string.format('ai.setAggression(%.3f)', target))
end

-- Replacing the standard role also dropped its crash handling, which is why vehicles kept
-- driving after being hit. Damage decides whether it matters; personality decides the reaction.
function C:onCollision(otherId, data)
  local d = self.d
  if not d or not units.ai(self.veh) then return end
  d.crashState = max(d.crashState, 1)
  local c = d.crash
  c.otherId, c.speed, c.dot, c.at = otherId, data.speed or 0, data.dot or 0, d.clock
  c.selfOnly = false
  -- Touched by a police car, an ambulance or a fire engine: nobody sane takes that
  -- personally, still less chases it. It shakes them, and that is the end of it.
  if units.isEmergency(otherId) then
    stateMachine.escalate(d, 'scared')
    return
  end
  self:setTarget(otherId)
  memory.add(d.mem, d.clock, otherId, memory.COLLISION, 1 + d.p.temper)
  stateMachine.escalate(d, d.p.temper > 0.6 and 'angry' or 'scared')

  -- Someone rear-ended us and then drove off. Only then does anyone give chase, only if
  -- they are the type, and the point is to follow them, not to ram them.
  local theirFault = (data.dot or 0) < 0
  local hard = (data.speed or 0) > 4
  if theirFault and hard and d.crashState < 2 and d.p.temper > 0.65
    and d.d.bravery > 0.6 and random() < d.p.ragebait * 0.8 then
    c.chaseWatch = 4 -- wait and see whether they stop like a normal person
  end
end

-- A chase only starts if the other driver actually leaves the scene.
function C:updateChaseWatch(d, tickTime)
  local c = d.crash
  if (c.chaseWatch or 0) <= 0 then return end
  c.chaseWatch = c.chaseWatch - tickTime
  local other = c.otherId ~= 0 and map.objects and map.objects[c.otherId]
  local fleeing = other and other.vel and other.vel:length() > 7
  if c.chaseWatch > 0 then
    if not fleeing then return end
  elseif not fleeing then
    c.chaseWatch = 0
    return
  end
  c.chaseWatch = 0
  d.crashState = 6
  c.outcome = 'chase'
  if units.ai(self.veh) then self.veh:setAiMode('follow') end
  self.actionTimer = 1e9
  pursuit.start(d, pursuit.CHASE, c.otherId, 12 + random() * 18)
  stateMachine.set(d, 'angry')
end

function C:onCrashDamage(data)
  local d = self.d
  if not d or not units.ai(self.veh) then return end
  if d.crash.at == 0 then
    -- No other vehicle involved: debris from particle mods, kerbs and blown tyres all land
    -- here, so this is flagged self-only and judged against a much higher damage bar.
    d.crash.speed, d.crash.at, d.crash.selfOnly = self.veh.speed, d.clock, true
  end
  d.crashState = max(d.crashState, 1)
  stateMachine.escalate(d, 'scared')
end

local WITNESS_RANGE = 85
local toCrash = vec3()

function C:onOtherCollision(id1, id2, data)
  local d = self.d
  if not d or d.crashState > 0 then return end

  -- It has to be in front of us and close enough to matter. Without this, a shunt behind
  -- us or right across the valley made cars brake on an empty road for no visible reason.
  local other = map.objects and map.objects[id1]
  if not other or not other.pos or not self.veh.pos or not self.veh.dirVec then return end
  toCrash:setSub2(other.pos, self.veh.pos)
  local fwd = toCrash:dot(self.veh.dirVec)
  if fwd < 5 or toCrash:squaredLength() > WITNESS_RANGE * WITNESS_RANGE then return end
  if not self:checkTargetVisible(id1) then return end

  stateMachine.escalate(d, d.p.prudence > 0.5 and 'cautious' or 'amazed')
  memory.add(d.mem, d.clock, id1, memory.NEAR_MISS, 0.6)

  -- Nobody stops dead in a live lane for something they merely saw. They slow down and
  -- gawp. Actually stopping only happens when the wreck genuinely blocks the way, and
  -- car-following already handles that as an obstacle.
  local wt = d.wt
  if wt.mode ~= 0 then return end
  local slowChance = 0.2 + d.p.prudence * 0.45 - d.p.aggression * 0.25
  local r = random()
  if r < slowChance then
    wt.mode, wt.timer = 1, 3 + random() * 4      -- crawl past
  elseif r < slowChance + 0.35 then
    wt.mode, wt.timer = 2, 2 + random() * 3      -- slow hard, then ease off
  else
    wt.mode, wt.timer = 3, 5 + random() * 8      -- just lift off
  end
end

function C:updateWitness(d, ctx, tickTime)
  local wt = d.wt
  wt.speedCap = -1
  if wt.mode == 0 then return end

  wt.timer = wt.timer - tickTime
  -- A floor of walking pace, never zero. Pinning the command at 0 in an open lane is what
  -- made cars stop dead in the middle of the road for no reason a driver could see.
  if wt.mode == 1 then
    wt.speedCap = 2.5 + d.p.confidence * 2
    if wt.timer <= 0 then wt.mode = 0 end
  elseif wt.mode == 2 then
    wt.speedCap = 4 + d.p.confidence * 3
    if wt.timer <= 0 then wt.mode, wt.timer = 3, 6 + random() * 8 end
  else
    wt.speedCap = ctx.limit * (0.35 + d.p.confidence * 0.3)
    if wt.timer <= 0 then wt.mode = 0 end
  end
end

-- Severity blends accumulated damage with the speed at impact: a light kiss at 50 km/h
-- and a heavy shunt at 10 km/h are different events even if the damage number lands close.
function C:crashSeverity()
  local values = gameplay_traffic_trafficUtils.getBaseValues()
  local sev = (self.veh.damage / values.highDamage) * 0.65 + (self.d.crash.speed / 22) * 0.35
  return sev > 1 and 1 or sev
end

-- Real drivers do not all do the same thing after a shunt. Some edge the car onto the
-- shoulder, some leave it exactly where it stopped so the insurer can see the scene, and
-- some just drive off. Personality shifts the odds; severity caps what is even possible.
function C:pickCrashOutcome(sev)
  local d = self.d
  if sev >= 0.75 then return 'wrecked' end

  local driveOn = 0
  if sev < 0.22 then
    driveOn = d.d.bravery * (1 - sev * 3)
    if driveOn < 0 then driveOn = 0 end
  end

  local move = 0.5 + d.p.confidence * 0.25 + d.s.experience * 0.2 - d.p.prudence * 0.35 - sev * 0.45
  if move < 0.05 then move = 0.05 elseif move > 0.9 then move = 0.9 end

  -- dot > 0 means the other vehicle was ahead of us, so we drove into them: our fault.
  -- Only the driver who caused it runs. dot > 0 means they were ahead of us, so we drove
  -- into them; being hit from behind is never a reason to flee.
  local flee = 0
  if d.crash.dot > 0 and not d.crash.selfOnly and sev < 0.5 then
    flee = (1 - d.p.prudence) * 0.3 + d.p.aggression * 0.12
  end

  local r = random()
  if r < driveOn then return 'driveOn' end
  if r < driveOn + flee then return 'flee' end
  if r < driveOn + flee + move then return 'moveAside' end
  return 'stayPut'
end

-- Returns true while a crash action owns the vehicle, so the driving model stays out.
function C:handleCrash(tickTime)
  local d, veh = self.d, self.veh
  local c = d.crash

  if d.crashState == 1 then
    local values = gameplay_traffic_trafficUtils.getBaseValues()
    local floor = c.selfOnly and values.lowDamage * 4 or values.lowDamage
    if veh.damage < floor then
      d.crashState = 0 -- a scrape: rattled, but still driving
      c.outcome = 'scrape'
      return false
    end

    c.severity = self:crashSeverity()
    c.outcome = self:pickCrashOutcome(c.severity)
    if c.outcome == 'driveOn' then
      d.crashState = 0
      return false
    end

    if c.outcome == 'flee' then
      d.crashState = 5
      if units.ai(self.veh) then self.veh:setAiMode('flee') end
      self:setTarget(c.otherId)
      self.actionTimer = 1e9 -- pursuit decides when this ends, not a fixed timer
      pursuit.start(d, pursuit.FLEE, c.otherId, 18 + random() * 25)
      stateMachine.set(d, 'panic')
      return true
    end

    -- Everyone stops first. What happens next is decided when the shock passes.
    d.crashState = 2
    self:setAction('disabled')
    self.actionTimer = 2 + d.p.prudence * 6 + c.severity * 4
    return true
  end

  if d.crashState == 0 then return false end

  self.actionTimer = self.actionTimer - tickTime
  if self.actionTimer > 0 then return true end

  if d.crashState == 2 then
    if c.outcome == 'wrecked' then
      d.crashState = 4
      self.actionTimer = 1e9
    elseif c.outcome == 'moveAside' then -- luaCheck: ignore
      d.crashState = 3
      self:setAction('crashPark', {dist = 6 + random() * 6, shift = self:kerbShift()})
      self.actionTimer = 9
    else
      -- Left exactly where it stopped. A crashed car does not quietly rejoin the traffic
      -- ten seconds later; it sits there until the traffic system recycles it.
      d.crashState = 4
      self.actionTimer = 1e9
    end
    return true
  end

  if d.crashState == 3 then
    d.crashState = 4
    self:setAction('disabled')
    self.actionTimer = 1e9
    return true
  end

  if d.crashState == 5 or d.crashState == 6 then
    d.crashState, c.outcome = 0, 'none'
    if units.ai(self.veh) then self.veh:setAiMode('traffic') end
    self:resetAction()
    stateMachine.set(d, 'recovering')
    return false
  end

  d.crashState, c.outcome = 0, 'none'
  self:resetAction()
  stateMachine.set(d, 'recovering')
  return false
end

-- First piece of the intimidation layer: how often and how long a driver leans on the horn
-- is almost entirely personality, so two equally angry drivers sound completely different.
function C:maybeHonk(d, blocked, pcp, tickTime)
  d.hornTimer = d.hornTimer - tickTime

  -- The light is green and the car in front has not moved: the person on their phone. A
  -- short tap after a couple of seconds, from anyone who uses the horn at all.
  local green = pcp.signalDist >= 0 and pcp.signalDist < 45 and pcp.signalAction == perception.ACTION_NONE
  if green and self.veh.speed < 0.5 and pcp.leadId ~= 0 and pcp.leadSpeed < 0.5 and pcp.leadGap < 8 then
    d.greenWait = (d.greenWait or 0) + tickTime
    if d.greenWait > 2.5 + d.p.patience * 3 and d.hornTimer <= 0
      and (d.d.warnStyle == 1 or d.d.warnStyle == 3) then
      self.veh:honkHorn(0.12 + d.p.temper * 0.25)
      d.hornTimer, d.greenWait = 6, 0
      return
    end
  else
    d.greenWait = 0
  end

  if d.hornTimer > 0 or not blocked then return end

  -- Nobody sensible honks at a queue waiting for a red light.
  if pcp.signalDist >= 0 and pcp.signalDist < 45
    and (pcp.signalAction == perception.ACTION_STOP or pcp.signalAction == perception.ACTION_BRIEF_STOP) then
    d.hornTimer = 3
    return
  end

  -- Same repertoire the overlay shows. A driver listed as 'nada' never touches the horn.
  local style = d.d.warnStyle
  if style ~= 1 and style ~= 3 then
    d.hornTimer = 6
    return
  end

  local worked = d.state == 'angry' or d.state == 'frustrated' or d.frustration > 0.7
  if not worked then
    d.hornTimer = 2
    return
  end

  if random() < d.p.horn * 0.5 then
    self.veh:honkHorn(0.15 + d.p.horn * d.p.temper * 1.1)
    d.hornTimer = 4 + (1 - d.p.horn) * 14
    if self.targetId then
      memory.add(d.mem, d.clock, self.targetId, memory.HONKED, 0.5)
    end
  else
    d.hornTimer = 3
  end
end

-- Small things drivers do because of the conditions, not because of another driver.
function C:updateEnvironment(d, ctx, pcp, tickTime)
  local veh = self.veh
  d.envTimer = (d.envTimer or 0) - tickTime
  if d.envTimer <= 0 then
    d.envTimer = 4 + random() * 4
    -- Stock traffic only puts the lights on after dark. In rain or fog most people switch
    -- them on too; some never think to. Only lights this role switched on are switched off.
    local murky = conditions.rain > 0.3 or conditions.fog > 0.3
    if murky and d.d.weatherLights and not veh.headlights then
      veh.headlights, d.weatherLit = true, true
      base.send(veh.id, 'electrics.setLightsState(1)')
    elseif not murky and d.weatherLit and not conditions.night then
      veh.headlights, d.weatherLit = false, false
      base.send(veh.id, 'electrics.setLightsState(0)')
    end
  end

  -- Coming up fast on a queue that has stopped: a few seconds of hazards for whoever is
  -- behind. Common practice on fast roads, and only with someone actually behind to warn.
  d.queueWarn = (d.queueWarn or 0) - tickTime
  -- Off again before stopping: hazards on a standing car tell everyone behind it is broken
  -- down, and they would start going round a perfectly ordinary queue.
  if d.queueHazOn and (ctx.speed < 4 or d.queueWarn < 34) then
    d.queueHazOn = false
    veh.queuedFuncs.taiQueueHaz = nil
    base.send(veh.id, 'electrics.set_warn_signal(0)')
  end
  if d.queueWarn <= 0 and d.d.warnsQueue and ctx.speed > 19 and pcp.leadId ~= 0
    and pcp.leadSpeed < 4 and pcp.leadGap >= 0 and pcp.leadGap < 90 and pcp.rearId ~= 0 then
    d.queueWarn, d.queueHazOn = 40, true
    base.send(veh.id, 'electrics.set_warn_signal(1)')
  end
end

function C:onRefresh()
  self.targetId = nil
  self.actionTimer = 0
  self.d = getDriver(self.veh.id)
  if not self.d then return end

  local d = self.d
  driver.fitVehicle(d, self.veh)
  driver.rollTrip(d)
  local vobj = getObjectByID(self.veh.id)
  local pc = vobj and type(vobj.partConfig) == 'string' and string.lower(vobj.partConfig) or ''
  d.isBus = (d.heavy or 0) > 0.4 and string.find(pc, 'bus', 1, true) ~= nil
  d.sentAgg = -1
  d.frustration = 0
  attitude.reset(d)
  -- The mood the driver set out with, not just a neutral start.
  if d.mood == 'hurried' then
    stateMachine.set(d, 'hurried')
  elseif d.mood == 'tired' then
    stateMachine.set(d, 'tired')
  else
    stateMachine.set(d, 'normal')
  end
  stateMachine.setManeuver(d, 'none')
  driver.setGoal(d, 'none')
  carFollowing.reset(d)
  laneChange.reset(d)
  squeeze.reset(d)
  evasion.reset(d)
  emergencyYield.reset(d)
  intimidation.reset(d)
  driving.reset(d)
  overtake.reset(d)
  hero.reset(d)
  pursuit.reset(d)
  -- ai.setPullOver is not cleared by ai.reset(), so a respawn during a kerbside stop
  -- would leave the car trying to park for the rest of its life.
  local obj = getObjectByID(self.veh.id)
  if obj then obj:queueLuaCommand('ai.setPullOver(false)') end
  d.rs.state, d.rs.timer, d.rs.hazards = 0, 60 + random() * 180, false
  d.wt.mode, d.wt.timer, d.wt.speedCap = 0, 0, -1
  memory.clear(d.mem)
  d.clock, d.pm.count, d.pm.rayTimer = 0, 0, 0
  d.stuckTimer, d.yieldTimer, d.hornTimer, d.crashState = 0, 0, 0, 0
  d.crash.at, d.crash.speed, d.crash.severity, d.crash.outcome = 0, 0, 0, 'none'
  self:pushAiParameters()
end

function C:onTrafficTick(tickTime)
  local d = self.d
  if not d or not units.ai(self.veh) or not units.alive(self.veh) then return end

  -- The stock siren stop is switched off for cars this role drives; the corridor logic below
  -- replaces it. Re-sent now and then because a respawn resets the vehicle side.
  d.sirenTimer = (d.sirenTimer or 0) - tickTime
  if d.sirenTimer <= 0 then
    d.sirenTimer = 6
    base.send(self.veh.id, emergencyYield.alive and units.SIRENS_HIDE or units.SIRENS_SHOW)
  end

  -- An ambulance or fire engine on a shout is driven by the stock 'random' AI, which is
  -- far better at getting somewhere fast than anything the traffic model would do.
  if emergency.onCall(self.veh.id) then
    carFollowing.release(d, self.veh.id)
    stateMachine.setManeuver(d, 'emergencia')
    return
  end

  -- Pulled over by a patrol, or staged for a call (a casualty, a burning car): the engine's
  -- pull-over does the work and the driving model must not fight it.
  if holds.isHeld(self.veh.id) then
    carFollowing.release(d, self.veh.id)
    stateMachine.setManeuver(d, 'detenido')
    return
  end

  -- Heading for a parking bay on a routed path. The driving model would fight the route.
  if parking.active[self.veh.id] then
    carFollowing.release(d, self.veh.id)
    stateMachine.setManeuver(d, 'aparcando')
    return
  end

  d.clock = d.clock + tickTime
  stateMachine.update(d, tickTime)
  driver.updateGoal(d, tickTime)
  self:updateChaseWatch(d, tickTime)

  if (d.crashState == 5 or d.crashState == 6) and units.ai(self.veh) then
    local ctxP = base.beginTick(self.veh, d, gameplay_traffic.getTrafficData())
    local outcome = pursuit.update(d, ctxP, tickTime)
    if outcome == nil or outcome == 'over' or outcome == 'gaveUp' then
      -- Gave up or ran out of nerve: stop and go through the normal crash decision.
      d.crashState = 2
      d.crash.outcome = outcome == 'gaveUp' and 'stayPut' or 'moveAside'
      if units.ai(self.veh) then self.veh:setAiMode('traffic') end
      self:setAction('disabled')
      self.actionTimer = 3 + random() * 5
    else
      local pcpP = perception.sense(ctxP, d, tickTime, d.clock)
      carFollowing.update(d, ctxP, pcpP, tickTime)
      stateMachine.setManeuver(d, 'none')
      return
    end
  end

  if self:handleCrash(tickTime) then
    carFollowing.release(d, self.veh.id)
    return
  end

  local ctx = base.beginTick(self.veh, d, gameplay_traffic.getTrafficData())

  -- Far from the camera nobody can see the difference between full behaviour and simply
  -- following the car in front, so both the expensive half of the pipeline and the full
  -- perception scan are skipped there.
  local camDist = perception.camDistSq[self.veh.id]
  local far = camDist and camDist > LOD_FAR_SQ
  local pcp = far and perception.senseLight(ctx, d, tickTime, d.clock)
    or perception.sense(ctx, d, tickTime, d.clock)
  if far then
    d.ey.speedCap, d.sq.speedCap, d.ev.speedCap = -1, -1, -1
    d.itm.speedCap, d.dr.speedCap, d.ot.speedCap = -1, -1, -1
    d.pu.speedCap, d.hr.speedCap = -1, -1
    d.sq.ignoreId, d.ot.ignoreId, d.ot.speedBoost = 0, 0, 1
    self:updateWitness(d, ctx, tickTime)
    self:syncAggression()
    carFollowing.update(d, ctx, pcp, tickTime)
    stateMachine.setManeuver(d, 'following')
    return
  end

  if self:updateRoadsideStop(d, ctx, tickTime) then
    carFollowing.release(d, self.veh.id)
    stateMachine.setManeuver(d, 'none')
    return
  end

  local blocked = pcp.leadId ~= 0 and pcp.leadGap < d.cf.desiredGap * 1.4
    and pcp.leadSpeed < ctx.limit * 0.5

  -- Stress, time pressure, grudges and frustration, and the lapses of attention on top.
  attitude.update(d, ctx, pcp, tickTime)
  attitude.episodes(d, ctx, pcp, tickTime)

  if pcp.leadId ~= 0 and pcp.leadDecel > 4 and pcp.leadGap < d.cf.desiredGap then
    stateMachine.escalate(d, pcp.leadDecel > 7 and 'scared' or 'nervous')
    memory.add(d.mem, d.clock, pcp.leadId, memory.BRAKE_CHECK, pcp.leadDecel * 0.15)
  end

  self:syncAggression()
  self:maybeHonk(d, blocked, pcp, tickTime)
  self:updateEnvironment(d, ctx, pcp, tickTime)

  stateMachine.updateManeuver(d, tickTime)
  -- Evasion outranks everything, then squeezing past an obstacle. Both run before the
  -- stuck check: a car stopped behind a wreck is exactly the case that needs them.
  self:updateWitness(d, ctx, tickTime)
  local evading = evasion.update(d, ctx, pcp, tickTime)
  -- Opening a corridor outranks everything except a collision about to happen.
  local yielding = not evading and emergencyYield.update(d, ctx, pcp, tickTime) or nil
  local squeezing = not (evading or yielding) and squeeze.update(d, ctx, pcp, tickTime) or nil
  if (evading or squeezing or yielding) and d.lc.phase ~= 0 then
    if d.lc.phase == laneChange.SIGNAL or d.lc.phase == laneChange.EXEC then base.signal(ctx, 0) end
    laneChange.reset(d) -- they all steer; only one may own the wheel
  end

  -- Sitting still for a while means our speed cap is the thing holding the car in place.
  -- Hand control back so the stock avoidance and routing can get it out.
  -- A lane change already under way is the way out, so it does not count as stuck.
  if self.veh.speed < 0.5 and blocked and not squeezing and not evading and not yielding
    and d.lc.phase ~= laneChange.EXEC and d.lc.phase ~= laneChange.SIGNAL then
    d.stuckTimer = d.stuckTimer + tickTime
  else
    d.stuckTimer = 0
  end
  if d.stuckTimer > 6 then
    d.stuckTimer, d.yieldTimer = 0, 8
  end

  if d.yieldTimer > 0 and not squeezing and not evading and not yielding then
    d.yieldTimer = d.yieldTimer - tickTime
    carFollowing.release(d, self.veh.id)
    stateMachine.setManeuver(d, 'none')
    return
  end
  d.yieldTimer = 0

  local blocking = not yielding and hero.update(d, ctx, pcp, tickTime) or nil
  local passing = not (evading or squeezing or blocking or yielding)
    and overtake.update(d, ctx, pcp, tickTime) or nil

  -- Micro-driving only when nothing more urgent owns the wheel.
  if not (evading or squeezing or passing or blocking or yielding) and d.lc.phase == 0 then
    driving.update(d, ctx, pcp, tickTime)
  else
    d.dr.speedCap = -1
  end

  local bullying = not (squeezing or evading or passing or blocking or yielding)
    and intimidation.update(d, ctx, pcp, tickTime) or nil
  local following = carFollowing.update(d, ctx, pcp, tickTime)
  local changing = not (squeezing or evading or passing or yielding)
    and laneChange.update(d, ctx, pcp, tickTime) or nil
  stateMachine.setManeuver(d,
    yielding or evading or squeezing or blocking or passing or changing or bullying or following or 'none')
end

return function(...) return require('/lua/ge/extensions/gameplay/traffic/baseRole')(C, ...) end
