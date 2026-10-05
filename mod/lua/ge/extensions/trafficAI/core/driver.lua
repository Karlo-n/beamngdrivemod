local M = {}

local types = require('trafficAI/drivers/driverTypes')
local personalities = require('trafficAI/drivers/personalities')
local skills = require('trafficAI/drivers/skills')
local memory = require('trafficAI/core/memory')
local stateMachine = require('trafficAI/core/stateMachine')
local perception = require('trafficAI/environment/perception')
local conditions = require('trafficAI/environment/conditions')

local MEM_SIZE = 6

function M.new(id, typeId)
  local t = (typeId and types.get(typeId)) or types.random()
  local p = personalities.generate(t)
  local s = skills.generate(t)

  local d = {
    id = id,
    typeId = t.id,
    typeLabel = t.label,
    p = p,
    s = s,
    d = skills.derive(p, s),
    mem = memory.new(MEM_SIZE),
    state = 'normal',
    stateDef = stateMachine.states.normal,
    stateTimer = 0,
    maneuver = 'none',
    manDef = stateMachine.maneuvers.none,
    manHold = 0,

    -- Behaviour scratch, allocated once so the tick never builds a table.
    cf = {leaderId = 0, gap = -1, leaderSpeed = 0, laggedSpeed = 0,
          desiredGap = 0, accel = 0, targetSpeed = 0, sentSpeed = -1,
          cmdSpeed = -1, released = false, launchWait = 0, launchBoost = 0, lastDecel = 0},
    lc = {phase = 0, timer = 0, cooldown = 0, urge = 0, side = 0, targetOffset = 0,
          keepRight = 0, tightRear = false},
    rs = {state = 0, timer = 0, reason = ''},
    sh = {zone = nil, waitTime = 0, jumped = false, crossing = false},
    pm = perception.newMemory(),
    clock = 0,
    stuckTimer = 0,
    yieldTimer = 0,
    hornTimer = 0,
    crashState = 0,
    crash = {otherId = 0, speed = 0, dot = 0, at = 0, severity = 0,
             outcome = 'none', selfOnly = false, chaseWatch = 0},
    sq = {active = false, phase = 0, ignoreId = 0, offset = 0, target = 0,
          speedCap = -1, side = 0, timer = 0, cooldown = 0, clearance = 0,
          waitId = 0, waitTimer = 0},
    ev = {level = 0, active = false, speedCap = -1, ttc = -1,
          threatId = 0, warnedFor = 0, delay = 0, dodgeSide = 0},
    -- Opening a corridor for a siren: never a full stop, only a shift and a lift off.
    ey = {active = false, speedCap = -1, side = 0, dist = 0, behind = false, clearing = false,
          blocked = false, clearTimer = 0},
    -- Reaction to someone else's crash: 0 none, 1 stop, 2 stop then crawl, 3 just slow down.
    wt = {mode = 0, timer = 0, speedCap = -1},
    itm = {active = false, timer = 0, phase = 0, speedCap = -1, gapMult = 1,
           targetId = 0, flashTimer = 0},
    dr = {homeOffset = 0, response = 0, responseTimer = 0, pressTimer = 0,
          speedCap = -1, lastLateral = 99, wanderRate = 0, wanderPhase = 0,
          startled = 0, drift = 0, driftDir = 0, home = 0, yieldCap = -1,
          mergerSeen = 0, mergerCourteous = false, letIn = false},
    ot = {phase = 0, targetId = 0, timer = 0, cooldown = 0, urge = 0,
          speedCap = -1, speedBoost = 1, ignoreId = 0, reason = '', abortCap = -1,
          homeOffset = 0, targetOffset = 0, needClear = 0, usingOncoming = false,
          cautious = false, reject = '', signalled = false},
    pu = {mode = 0, targetId = 0, timer = 0, phase = 0, speedCap = -1,
          speedBoost = 1, decideTimer = 0},
    hr = {phase = 0, targetId = 0, cooldown = 0, speedCap = -1,
          applied = 0, gap = 0, lat = 0},
    -- Attitude that moves with the trip: stress from what other drivers do, time pressure
    -- from delays, and a grudge against whoever is in front if they earned one.
    at = {stress = 0, pressure = 0, grudge = 0, speedMult = 1, gapMult = 1, urge = 0,
          lastLead = 0, lastLeadGap = -1, hornTimer = 0, nearMiss = false},
    -- Lapses: a glance at the phone, nodding off, not knowing the way.
    ep = {timer = 8 + math.random() * 30, lostCooldown = 0, redRolled = false},
    drunk = false,
    mood = 'none',
    frustration = 0,
    goal = 'none',
    goalTimer = 0,
    goalTarget = 0,
    sentAgg = -1
  }

  -- The naco genuinely goes faster than everyone else and weaves. Everything else about
  -- them still comes out of their traits like any other driver.
  if t.id == 'speeder' then
    d.d.speedFactor = d.d.speedFactor * 1.25
    d.d.overtakeEagerness = math.min(1, d.d.overtakeEagerness + 0.4)
    d.d.overtakeWait = d.d.overtakeWait * 0.3
    d.d.overtaker = true
    d.d.laneChangeUrge = (d.d.laneChangeUrge or 1) * 1.8
    d.d.errandChance = 0
  end

  d.dr.wanderRate, d.dr.wanderPhase = d.d.wanderRate, d.d.wanderPhase

  -- A trip has a mood of its own. Two identical drivers behave differently when one of them
  -- is late, which is what stops a road full of "normal" drivers looking like clones.
  local r = math.random()
  if r < 0.12 then
    d.mood = 'hurried'
  elseif r < 0.28 then
    d.mood = 'relaxed'
  elseif conditions.night and r < 0.42 then
    d.mood = 'tired'
  end
  if d.mood == 'hurried' then d.at.pressure = 0.4 end
  -- Rare, and only after dark.
  d.drunk = conditions.night and math.random() < 0.012

  return d
end

-- The same person drives a bus differently from a hatchback: slower off the line, softer on
-- the brakes, further back, and far less keen to go round anyone. Re-applied from the
-- driver's own values on every refresh, because a recycled vehicle can come back as a
-- different model.
local FIT = {'maxAccel', 'maxDecel', 'comfortDecel', 'gapMin', 'gapTime', 'speedFactor',
             'laneChangeTime', 'overtakeEagerness', 'launchPunch'}

function M.fitVehicle(d, veh)
  local dd = d.d
  local b = d.base
  if not b then
    b = {}
    for i = 1, #FIT do b[FIT[i]] = dd[FIT[i]] end
    d.base = b
  end
  -- 0 for anything car-sized, 1 from about 12 m up (city bus, articulated lorry).
  local heavy = ((veh and veh.length or 4.6) - 6) / 6
  if heavy < 0 then heavy = 0 elseif heavy > 1 then heavy = 1 end
  d.heavy = heavy

  dd.maxAccel = b.maxAccel * (1 - heavy * 0.5)
  dd.maxDecel = b.maxDecel * (1 - heavy * 0.25)
  dd.comfortDecel = b.comfortDecel * (1 - heavy * 0.3)
  dd.gapMin = b.gapMin + heavy * 3
  dd.gapTime = b.gapTime * (1 + heavy * 0.35)
  dd.speedFactor = b.speedFactor * (1 - heavy * 0.1)
  dd.laneChangeTime = b.laneChangeTime * (1 + heavy * 0.6)
  dd.overtakeEagerness = b.overtakeEagerness * (1 - heavy * 0.6)
  dd.launchPunch = b.launchPunch * (1 - heavy * 0.5)
  dd.overtaker = dd.overtakeEagerness > 0.12
end

-- ai.lua uses aggression for far more than attitude: acc_target scales with it directly
-- (ai.lua:5109), so it sets how hard the car brakes and accelerates. Stock traffic runs at
-- 0.35; sending values near 1 was making every stop a near-emergency stop. This maps the
-- whole personality range into a band around the stock value instead.
function M.aggression(d)
  local raw = d.d.aggBase + d.stateDef.agg + d.frustration * 0.15
  local a = 0.24 + raw * 0.42
  return a < 0.24 and 0.24 or (a > 0.72 and 0.72 or a)
end

-- Moods, grudges and intimidation all multiply in here, and stacked together they took the
-- most aggressive drivers down to 0.2 s: glued to the bumper. Even tailgaters keep about half
-- a second; only the deliberate push of intimidation gets under it.
function M.headway(d)
  local t = d.d.gapTime * d.stateDef.gap * conditions.gapMult(d.p) * d.at.gapMult
  if t < 0.55 then t = 0.55 end
  return t * (d.itm.gapMult or 1)
end

-- The speed this driver actually wants right now: their own factor, the weather, and a very
-- slow drift so nobody holds an exactly constant speed for minutes on end.
function M.desiredSpeed(d, limit)
  local dd = d.d
  local drift = 1 + math.sin(d.clock * dd.speedDriftRate + dd.speedDriftPhase) * dd.speedDriftAmp
  -- Road class: the open-road bonus fades in between 50 and 90 km/h limits.
  local open = (limit - 14) / 11
  if open < 0 then open = 0 elseif open > 1 then open = 1 end
  local style = 1 + dd.speedOpenBonus * open + dd.areaSpeed
  return limit * dd.speedFactor * style * (d.stateDef.spd or 1) * d.at.speedMult
    * conditions.speedMult(d.p) * drift
end

function M.reaction(d)
  return d.d.reaction * d.stateDef.react
end

function M.setGoal(d, goal, targetId, duration)
  d.goal = goal
  d.goalTarget = targetId or 0
  d.goalTimer = duration or 0
end

function M.updateGoal(d, dt)
  if d.goalTimer <= 0 then return end
  d.goalTimer = d.goalTimer - dt
  if d.goalTimer <= 0 then
    d.goal, d.goalTarget = 'none', 0
  end
end

return M
