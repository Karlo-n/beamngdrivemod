local M = {}

local sin = math.sin
local abs = math.abs
local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')
local memory = require('trafficAI/core/memory')
local stateMachine = require('trafficAI/core/stateMachine')
local policeEvents = require('trafficAI/behaviors/policeEvents')


M.IGNORE, M.YIELD, M.ANNOYED, M.BRAKE_CHECK = 0, 1, 2, 3

-- Lateral drift is only for drivers who are actually impaired. Every command here is a
-- shove that the stock lane keeping then pulls back out, so sending it to everyone made
-- ordinary drivers look drunk. Sober, awake drivers are left entirely to the stock AI.
local function laneWander(d, ctx, dt)
  local dr = d.dr
  -- Standing at a light, a phone in hand drifts nothing.
  if ctx.laneWidth < 2 or ctx.speed < 3 then return end
  local lw, state = ctx.laneWidth, d.state

  local want
  if state == 'drunk' then
    -- The classic weave: wide, slow, and corrected late.
    want = sin(d.clock * (0.35 + dr.wanderRate * 0.4) + dr.wanderPhase) * lw * 0.17
  elseif state == 'distracted' then
    -- Eyes off the road: one slow drift to one side, fixed when they look up.
    if dr.driftDir == 0 then dr.driftDir, dr.home = random() < 0.5 and -1 or 1, ctx.laneCenter end
    dr.drift = dr.drift + dt * (0.05 + (1 - d.s.control) * 0.08)
    if dr.drift > lw * 0.16 then dr.drift = lw * 0.16 end
    want = dr.driftDir * dr.drift
  elseif state == 'asleep' then
    -- Hands go slack and the car keeps going wherever the road camber takes it.
    if dr.driftDir == 0 then dr.driftDir, dr.home = random() < 0.5 and -1 or 1, ctx.laneCenter end
    dr.drift = dr.drift + dt * (0.12 + random() * 0.08)
    want = dr.driftDir * dr.drift
  else
    dr.driftDir, dr.drift = 0, 0
    return
  end

  -- Re-asserted every tick as an absolute target, like every other steering behaviour.
  -- Measured from the lane they started in: once the car is over the line, the lane under
  -- it is a different one and its centre would push the drift a whole lane further.
  base.lateralHold(ctx, (state == 'drunk' and ctx.laneCenter or dr.home) + want, lw + 1)
end

-- A sleeping driver only comes round when something forces it: a horn, the noise of the
-- tyres on the lane edge, or the crash itself (the role escalates to 'scared' on impact).
local function sleepCheck(d, ctx, pcp)
  local dr = d.dr
  if d.state ~= 'asleep' then return end
  local woke = pcp.hornNearby
  if not woke and dr.driftDir ~= 0 then
    if dr.drift > ctx.laneWidth * 0.5 then woke = random() < 0.2 end
    -- Wheels off the tarmac: the edge is a kerb or a ditch, and that wakes anyone.
    -- clampOffset already keeps half a metre back from it, so a little past that.
    local target = dr.home + dr.driftDir * dr.drift
    if abs(base.clampOffset(ctx, target) - target) > 0.45 then woke = true end
  end
  if woke then
    stateMachine.set(d, 'scared')
    dr.startled = 1.5
  end
end

-- Being tailgated is one of the design's core interactions: the same pressure produces
-- yielding, irritation or a deliberate brake check depending entirely on who is driving.
local function rearPressure(d, ctx, pcp, dt)
  local dr = d.dr
  dr.speedCap = -1

  local gap, rearSpeed = pcp.rearGap, pcp.rearSpeed
  local pressed = gap >= 0 and gap < (2.5 + ctx.speed * 0.55) and rearSpeed > ctx.speed - 1

  if not pressed then
    dr.pressTimer = 0
    if dr.response ~= M.IGNORE and dr.responseTimer <= 0 then dr.response = M.IGNORE end
  else
    dr.pressTimer = dr.pressTimer + dt
  end

  if dr.responseTimer > 0 then
    dr.responseTimer = dr.responseTimer - dt
  elseif pressed and dr.pressTimer > 1.5 + d.p.tolerance * 5 then
    -- Decided once per episode, then held, so a driver does not flip-flop under pressure.
    local r = random()
    local yieldP = 0.25 + d.p.tolerance * 0.4 - d.p.aggression * 0.2
    local baitP = d.p.ragebait * 0.5 * (d.p.temper > 0.6 and 1 or 0.3)
    if r < yieldP then
      -- Fixed at the decision: a cap relative to the current speed would keep shrinking.
      dr.response, dr.yieldCap = M.YIELD, ctx.speed * 0.9
    elseif r < yieldP + baitP then
      dr.response = M.BRAKE_CHECK
    elseif r < yieldP + baitP + 0.3 then
      dr.response = M.ANNOYED
    else
      dr.response = M.IGNORE
    end
    dr.responseTimer = 4 + random() * 6
    dr.pressTimer = 0
  end

  -- Letting them by. Yielding used to be picked and then do nothing at all. On a road with
  -- one lane each way, a slow driver tucks toward the kerb and lifts off so the one behind
  -- can see past and go; with a lane to spare, they simply move over to it.
  if dr.response == M.YIELD and dr.responseTimer > 0 then
    if ctx.ourLanes == 1 then
      base.lateralHold(ctx, ctx.laneCenter + ctx.sideSign * 0.8, ctx.laneWidth)
      dr.speedCap = dr.yieldCap
    elseif ctx.laneIdx > 0 and d.lc.keepRight > 0.5 then
      d.lc.keepRight = 0.5
    end
  elseif dr.response == M.BRAKE_CHECK and dr.responseTimer > 3 then
    dr.speedCap = ctx.speed * 0.55 -- a jab of the brakes, not a stop
  elseif dr.response == M.ANNOYED and d.p.horn > 0.4 and dr.responseTimer > 5.5 then
    dr.speedCap = ctx.speed * 0.85
  end

  return dr.response
end

-- Someone indicating to come into our lane. Courtesy is a trait: some lift off and make
-- room, the tolerant ones almost always do, and the aggressive ones close the gap instead.
local function respondToMerger(d, ctx, pcp)
  local dr = d.dr
  dr.letIn = false
  if pcp.mergerId == 0 or pcp.mergerId == dr.mergerSeen then return end

  dr.mergerSeen = pcp.mergerId
  local chance = 0.25 + d.p.tolerance * 0.6 - d.p.aggression * 0.3
    + (d.mood == 'relaxed' and 0.15 or 0) - d.at.pressure * 0.3 - d.at.stress * 0.15
  if memory.grudge(d.mem, d.clock, pcp.mergerId) > 0.3 then chance = 0 end
  dr.mergerCourteous = random() < chance
end

local function applyMerger(d, ctx, pcp)
  local dr = d.dr
  if pcp.mergerId == 0 then
    dr.mergerSeen, dr.letIn = 0, false
    return
  end
  dr.letIn = dr.mergerCourteous
  if dr.mergerCourteous then
    -- Ease off so a gap opens ahead of them.
    local cap = ctx.speed * 0.85
    if dr.speedCap < 0 or cap < dr.speedCap then dr.speedCap = cap end
  end
end

function M.update(d, ctx, pcp, dt)
  local dr = d.dr
  dr.speedCap = -1
  if not ctx.valid then return nil end

  -- A horn going off right next to you makes people jump, and the jumpier the more so.
  if pcp.hornNearby and d.p.confidence < 0.55 and random() < 0.25 then
    dr.startled = 1.5
  end
  if dr.startled > 0 then dr.startled = dr.startled - dt end

  respondToMerger(d, ctx, pcp)
  applyMerger(d, ctx, pcp)

  sleepCheck(d, ctx, pcp)
  -- Asleep, they are not reacting to anyone behind them either.
  if d.state ~= 'asleep' then rearPressure(d, ctx, pcp, dt) end
  laneWander(d, ctx, dt)

  -- Everyone eases off past a parked patrol with its lights on. The position is published
  -- once by the event system, so no vehicle has to go looking for police itself.
  local calm = policeEvents.calmPos
  if calm and ctx.pos:squaredDistance(calm) < policeEvents.calmRadiusSq then
    local cap = ctx.limit * (0.6 + d.p.prudence * 0.15)
    if dr.speedCap < 0 or cap < dr.speedCap then dr.speedCap = cap end
  end
  return nil
end

function M.reset(d)
  local dr = d.dr
  dr.homeOffset, dr.lastLateral, dr.startled = 0, 99, 0
  dr.mergerSeen, dr.mergerCourteous, dr.letIn = 0, false, false
  dr.drift, dr.driftDir, dr.home = 0, 0, 0
  dr.response, dr.responseTimer, dr.pressTimer = M.IGNORE, 0, 0
  dr.speedCap = -1
end

return M
