local M = {}

local random = math.random

-- agg is an offset on final aggression; gap and react are multipliers on headway and reaction time;
-- spd is what the state does to the speed the driver chooses.
-- pri gates escalation: a state only overrides one of equal or lower priority.
local S = {
  normal     = {pri = 0, spd = 1.00, agg = 0,     gap = 1.00, react = 1.00, next = nil,          dur = {0, 0}},
  recovering = {pri = 1, spd = 0.97, agg = -0.05, gap = 1.10, react = 1.05, next = 'normal',     dur = {5, 15}},
  amazed     = {pri = 1, spd = 0.92, agg = 0,     gap = 1.05, react = 1.25, next = 'normal',     dur = {2, 6}},
  cautious   ={pri = 2, spd = 0.92, agg = -0.15, gap = 1.25, react = 0.95, next = 'recovering', dur = {8, 25}},
  tired      = {pri = 2, spd = 0.95, agg = -0.05, gap = 1.10, react = 1.30, next = 'normal',     dur = {30, 90}},
  distracted = {pri = 2, spd = 0.93, agg = 0,     gap = 1.10, react = 1.60, next = 'normal',     dur = {5, 14}},
  confused   = {pri = 2, spd = 0.85, agg = -0.10, gap = 1.20, react = 1.30, next = 'cautious',   dur = {4, 10}},
  lost       = {pri = 2, spd = 0.80, agg = -0.20, gap = 1.20, react = 1.15, next = 'confused',   dur = {10, 30}},
  frustrated = {pri = 3, spd = 1.03, agg = 0.10,  gap = 0.85, react = 0.95, next = 'normal',     dur = {6, 18}},
  hurried    = {pri = 3, spd = 1.06, agg = 0.25,  gap = 0.75, react = 0.95, next = 'normal',     dur = {20, 60}},
  drowsy     = {pri = 3, spd = 0.92, agg = -0.10, gap = 1.15, react = 1.80, next = 'tired',      dur = {15, 40}},
  drunk      = {pri = 3, spd = 0.96, agg = 0.10,  gap = 0.90, react = 1.70, next = 'drunk',      dur = {60, 180}},
  nervous    = {pri = 4, spd = 0.90, agg = -0.15, gap = 1.35, react = 1.10, next = 'cautious',   dur = {6, 20}},
  aggressive = {pri = 5, spd = 1.08, agg = 0.20,  gap = 0.70, react = 0.90, next = 'recovering', dur = {8, 20}},
  angry      = {pri = 6, spd = 1.08, agg = 0.30,  gap = 0.60, react = 0.85, next = 'frustrated', dur = {10, 30}},
  scared     = {pri = 7, spd = 0.80, agg = -0.25, gap = 1.60, react = 0.85, next = 'nervous',    dur = {3, 8}},
  panic      = {pri = 8, spd = 0.70, agg = -0.35, gap = 1.80, react = 0.75, next = 'scared',     dur = {2, 5}}
}

M.states = S

function M.set(d, name, dur)
  local s = S[name]
  if not s then return false end
  d.state = name
  d.stateDef = s
  d.stateTimer = dur or (s.dur[1] + random() * (s.dur[2] - s.dur[1]))
  return true
end

-- Temper decides how easily a driver is pushed into a stronger state.
function M.escalate(d, name, dur)
  local s = S[name]
  if not s then return false end
  if s.pri < d.stateDef.pri and d.stateTimer > 0 then return false end
  return M.set(d, name, dur)
end

function M.update(d, dt)
  if d.stateTimer <= 0 then return end
  d.stateTimer = d.stateTimer - dt
  if d.stateTimer <= 0 then
    M.set(d, d.stateDef.next or 'normal')
  end
end

-- Maneuvers are a second, independent axis: what the driver is doing right now, as opposed
-- to how the driver feels. An angry driver can be following; a calm one can be overtaking.
local MAN = {
  none       = {pri = 0, minDur = 0},
  following  = {pri = 1, minDur = 0.5},
  intimidate = {pri = 2, minDur = 1.5},
  laneChange = {pri = 2, minDur = 1.0},
  overtaking = {pri = 3, minDur = 2.0},
  squeeze    = {pri = 4, minDur = 1.5},
  evade      = {pri = 5, minDur = 1.0},
  cedeEmergencia = {pri = 6, minDur = 1.0},
  emergencia = {pri = 7, minDur = 1.0},
  hero       = {pri = 4, minDur = 1.5},
  aparcando  = {pri = 7, minDur = 0},
  detenido   = {pri = 8, minDur = 0}
}

M.maneuvers = MAN

function M.setManeuver(d, name)
  local m = MAN[name]
  if not m then return false end
  if m.pri <= d.manDef.pri and d.manHold > 0 then return false end
  d.maneuver, d.manDef, d.manHold = name, m, m.minDur
  return true
end

function M.updateManeuver(d, dt)
  if d.manHold > 0 then
    d.manHold = d.manHold - dt
    if d.manHold < 0 then d.manHold = 0 end
  end
end

return M
