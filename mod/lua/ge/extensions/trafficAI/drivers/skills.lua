local M = {}

local mathUtils = require('trafficAI/util/mathUtils')
local sampleRange, clamp = mathUtils.sampleRange, mathUtils.clamp
local random = math.random

M.names = {'experience', 'reflexes', 'control', 'perception', 'decision', 'area'}

function M.generate(typeDef)
  local out, src = {}, typeDef.s
  for i = 1, #M.names do
    local k = M.names[i]
    local r = src[k]
    out[k] = sampleRange(r[1], r[2])
  end
  return out
end

-- Resolved once per driver so the per-tick path never recomputes any of this.
function M.derive(p, s)
  local out = {
    reaction = 0.12 + (1 - s.reflexes) ^ 1.5 * 0.6,
    gapTime = clamp(0.6 + p.patience * 1.4 - p.aggression * 0.5, 0.35, 2.2),
    sightRange = 40 + s.perception * 90,
    bravery = clamp(p.confidence * 0.6 + (1 - p.prudence) * 0.4, 0, 1),
    aggBase = clamp(0.25 + p.aggression * 0.55 + p.confidence * 0.15 - p.prudence * 0.2, 0.15, 1),
    lookAhead = 0.35 + s.perception * 0.45 + s.experience * 0.2,
    awareness = 0.1 + s.perception * 0.35,
    turnForce = 1.2 + s.control * 1.6,
    -- ai.lua reuses trafficWaitTime as trafficStates.block.timerLimit (= waitTime*2), and
    -- past that limit it replans in reverse -- a U-turn. Floor it so impatience never does that.
    waitTime = clamp(2.0 + p.patience * 4, 2.0, 6.0),
    errorRate = (1 - s.control) * 0.6 + (1 - s.experience) * 0.4,

    -- Reading the road. Experience, perception and decision were generated for every driver
    -- and then used for nothing; this is what they were for. A high value looks past the car
    -- in front, reads a red light from a distance and lifts off early. A low one drives on
    -- the bumper ahead and brakes late.
    anticipation = clamp(s.experience * 0.45 + s.perception * 0.30 + s.decision * 0.25, 0, 1),
    -- Braking style: how hard an everyday stop is, and how abruptly it starts. Field data
    -- puts comfortable braking at 1-1.5 m/s2 for gentle drivers and near 3 for brisk ones.
    comfortDecel = clamp(1.25 + p.aggression * 1.2 + p.confidence * 0.4 - p.prudence * 0.5, 1.1, 2.9),
    brakeJerk = clamp(1.4 + p.aggression * 1.8 + (1 - s.control) * 0.6, 1.3, 3.6),
    -- Speed style. Confident, experienced drivers open up on fast roads; someone who does
    -- not know the area holds back everywhere, a local does not.
    speedOpenBonus = clamp(0.02 + p.confidence * 0.08 + s.experience * 0.04 - p.prudence * 0.05, 0, 0.12),
    areaSpeed = clamp((s.area - 0.5) * 0.14, -0.07, 0.04),
    familiarity = s.area,
    -- How prone they are to taking their eyes off the road.
    distractible = clamp((1 - s.perception) * 0.6 + (1 - p.prudence) * 0.3 + random() * 0.2, 0, 1),

    -- IDM and lane-change parameters, resolved here so the behaviours only read numbers.
    speedFactor = clamp(0.80 + p.aggression * 0.30 - p.prudence * 0.12, 0.72, 1.20),
    maxAccel = clamp(1.0 + p.aggression * 1.8 + s.control * 0.6, 0.8, 3.2),
    maxDecel = clamp(1.8 + p.aggression * 1.6 + s.control * 0.8, 1.5, 4.5),
    gapMin = 2.0 + p.prudence * 3.5,
    laneChangeTime = clamp(1.6 + (1 - s.control) * 1.8, 1.4, 3.6),
    patienceDelay = clamp(1.0 + p.patience * 6 - p.aggression * 1.2, 0.5, 8),
    rearPolitness = 0.4 + p.tolerance * 1.2,
    overtaker = false, -- filled in below, once eagerness is known

    -- Rolled once per driver so the repertoire is a trait, not a coin flip every time:
    -- 0 nothing, 1 horn, 2 flash, 3 both. Some people simply never do either.
    warnStyle = (random() < p.horn * 1.1 and 1 or 0) + (random() < p.beams * 1.1 and 2 or 0),
    warnDelay = 0.2 + (1 - s.reflexes) * 1.6 + random() * 0.7,
    -- Not everyone swerves; plenty of drivers just stand on the brakes and hope.
    swerver = (p.confidence * 0.5 + s.control * 0.5 - p.prudence * 0.4 + random() * 0.4) > 0.45,

    -- Time between the road clearing and this driver actually moving off. It is why a
    -- queue at a green light ripples forward instead of starting as one block.
    launchDelay = 0.25 + (1 - s.reflexes) * 1.3 + random() * 0.5,
    launchPunch = 1 + p.aggression * 1.4 + p.confidence * 0.4,

    -- Slow drift within the lane, and a slow drift in chosen cruising speed.
    -- Real drivers sit near the middle of their lane. The variation is centimetres, not
    -- half a lane: a standing personal bias plus a slow, small drift on top of it.
    laneBias = (random() - 0.5) * (0.16 + (1 - s.control) * 0.16),
    wanderAmp = 0.03 + (1 - s.control) * 0.08 + (1 - s.perception) * 0.04,
    wanderRate = 0.25 + random() * 0.5,
    wanderPhase = random() * 6.28,
    speedDriftAmp = 0.02 + (1 - s.control) * 0.05,
    speedDriftRate = 0.06 + random() * 0.10,
    speedDriftPhase = random() * 6.28,

    -- Seconds of clear road before moving back out of an inner lane, and how often this
    -- driver decides to stop at the roadside for a couple of minutes.
    laneDiscipline = 3 + (1 - p.aggression) * 10 + p.prudence * 6,
    errandChance = 0.02 + random() * 0.06,
    -- Some people stamp on the brakes the moment they hear a siren; most just move over.
    sirenBraker = random() < 0.3 + p.prudence * 0.4,
    -- Whether they bother with the indicator at all. Plenty of people simply do not.
    indicates = random() < 0.35 + s.experience * 0.35 + p.prudence * 0.25,
    -- Whether they wait their turn at a blocked single lane, and how long before impatience
    -- wins. Plenty of people simply push in.
    respectsTurn = random() < 0.45 + p.patience * 0.4 + p.tolerance * 0.2,
    turnPatience = clamp(3 + p.patience * 9, 2, 12),

    -- Willingness to overtake, as a degree rather than a switch. Field studies put roughly
    -- a fifth of drivers at an infinite critical gap (they never pass at all); the rest
    -- differ in how long they will sit there first, not in whether they ever go.
    overtakeEagerness = clamp(p.confidence * 0.35 + p.aggression * 0.4 - p.prudence * 0.5
                              + s.experience * 0.15 + random() * 0.3, 0, 1)
  }

  -- Below this they simply never pass. Above it, eagerness scales how long they wait.
  out.overtaker = out.overtakeEagerness > 0.12
  out.overtakeWait = clamp(out.patienceDelay * (1.3 - out.overtakeEagerness * 1.0), 0.8, 8)
  return out
end

return M
