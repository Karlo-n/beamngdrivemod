local M = {}

local sin = math.sin
local abs = math.abs
local random = math.random

local base = require('trafficAI/behaviors/baseBehavior')
local memory = require('trafficAI/core/memory')
local policeEvents = require('trafficAI/behaviors/policeEvents')


M.IGNORE, M.YIELD, M.ANNOYED, M.BRAKE_CHECK = 0, 1, 2, 3

-- Nobody holds a perfectly straight line. Poor control and impaired states wander more,
-- and the wander is slow, so it reads as a person rather than a wobble.
local function laneWander(d, ctx, dt)
  local dr = d.dr
  if ctx.laneWidth < 2 then return end

  local amp = dr.wanderAmp
  if d.state == 'distracted' or d.state == 'drowsy' then amp = amp * 2.2
  elseif d.state == 'drunk' then amp = amp * 4
  elseif d.state == 'nervous' or d.state == 'scared' then amp = amp * 1.6 end

  -- Occasional bigger drift, then back. A glance away, a pothole, a passenger talking.
  dr.excursionTimer = dr.excursionTimer - dt
  if dr.excursionTimer <= 0 then
    dr.excursionTimer = 12 + random() * 25
    dr.excursion = (random() - 0.5) * ctx.laneWidth * 0.09
  end
  dr.excursion = dr.excursion * 0.985

  local limit = ctx.laneWidth * 0.055
  if amp > limit then amp = limit end

  local want = sin(d.clock * dr.wanderRate + dr.wanderPhase) * amp + dr.excursion + dr.laneBias
  local span = ctx.laneWidth * 0.12
  if want > span then want = span elseif want < -span then want = -span end

  -- Only the change is sent, never an absolute position. The stock AI keeps doing the lane
  -- centring and this rides on top of it, so a wrong idea of where the centre is can no
  -- longer drag anyone onto the kerb.
  local delta = want - dr.lastWant

  -- The standing bias would otherwise be corrected away within a second and every car would
  -- sit dead centre. A small nudge every couple of seconds holds a slight personal offset
  -- against the AI's centring, which settles a few centimetres off and stays there.
  dr.biasTimer = dr.biasTimer - dt
  if dr.biasTimer <= 0 then
    dr.biasTimer = 2.5
    local trim = dr.laneBias * 0.3
    if trim > 0.06 then trim = 0.06 elseif trim < -0.06 then trim = -0.06 end
    delta = delta + trim
  end

  if abs(delta) < 0.04 then return end
  dr.lastWant = want
  base.lateralHold(ctx, ctx.roadOffset + delta, 0.8)
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
      dr.response = M.YIELD
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

  if dr.response == M.BRAKE_CHECK and dr.responseTimer > 3 then
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

  rearPressure(d, ctx, pcp, dt)
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
  dr.homeOffset, dr.lastLateral, dr.lastWant = 0, 99, 0
  dr.biasTimer, dr.startled = 0, 0
  dr.mergerSeen, dr.mergerCourteous, dr.letIn = 0, false, false
  dr.excursion, dr.excursionTimer = 0, 0
  dr.response, dr.responseTimer, dr.pressTimer = M.IGNORE, 0, 0
  dr.speedCap = -1
end

return M
