local M = {}

local random = math.random

local DEF_P = {
  patience = {0.3, 0.7}, aggression = {0.3, 0.7}, prudence = {0.3, 0.7},
  confidence = {0.3, 0.7}, tolerance = {0.3, 0.7}, temper = {0.3, 0.7},
  horn = {0.1, 0.5}, beams = {0.05, 0.4}, ragebait = {0, 0.08}
}

local DEF_S = {
  experience = {0.3, 0.7}, reflexes = {0.3, 0.7}, control = {0.3, 0.7},
  perception = {0.3, 0.7}, decision = {0.3, 0.7}, area = {0.3, 0.7}
}

local defs = {
  {id = 'slow', label = 'Slow Driver', w = 8,
   p = {patience = {0.6, 0.95}, aggression = {0.02, 0.25}, prudence = {0.6, 0.9}, confidence = {0.1, 0.4}, temper = {0.05, 0.35}, horn = {0.02, 0.25}, beams = {0, 0.15}, ragebait = {0, 0.02}},
   s = {reflexes = {0.2, 0.5}, control = {0.3, 0.6}, perception = {0.3, 0.6}, decision = {0.3, 0.6}, area = {0.3, 0.8}}},

  {id = 'normal', label = 'Normal Driver', w = 12, p = {}, s = {}},

  {id = 'aggressive', label = 'Aggressive Driver', w = 9,
   p = {patience = {0.05, 0.35}, aggression = {0.65, 0.98}, prudence = {0.1, 0.4}, confidence = {0.6, 0.95}, tolerance = {0.05, 0.35}, temper = {0.6, 0.95}, horn = {0.3, 0.9}, beams = {0.2, 0.85}, ragebait = {0.05, 0.5}},
   s = {reflexes = {0.5, 0.9}, control = {0.5, 0.9}}},

  {id = 'defensive', label = 'Defensive Driver', w = 7,
   p = {patience = {0.55, 0.9}, aggression = {0.05, 0.3}, prudence = {0.7, 0.95}, tolerance = {0.6, 0.9}, temper = {0.1, 0.4}},
   s = {perception = {0.55, 0.9}, decision = {0.55, 0.85}}},

  {id = 'cautious', label = 'Cautious Driver', w = 6,
   p = {patience = {0.5, 0.85}, aggression = {0.02, 0.2}, prudence = {0.75, 0.98}, confidence = {0.15, 0.45}},
   s = {reflexes = {0.35, 0.7}, perception = {0.5, 0.85}}},

  {id = 'confident', label = 'Confident Driver', w = 6,
   p = {aggression = {0.45, 0.75}, prudence = {0.25, 0.55}, confidence = {0.7, 0.98}},
   s = {experience = {0.6, 0.95}, control = {0.6, 0.95}, decision = {0.5, 0.85}}},

  {id = 'impatient', label = 'Impatient Driver', w = 7,
   p = {patience = {0.02, 0.22}, aggression = {0.5, 0.8}, tolerance = {0.1, 0.4}, temper = {0.6, 0.95}, horn = {0.4, 0.9}, beams = {0.25, 0.7}, ragebait = {0.02, 0.25}},
   s = {}},

  {id = 'distracted', label = 'Distracted Driver', w = 5,
   p = {prudence = {0.15, 0.45}, confidence = {0.35, 0.7}},
   s = {reflexes = {0.15, 0.45}, perception = {0.05, 0.3}, decision = {0.2, 0.5}}},

  {id = 'inexperienced', label = 'Inexperienced Driver', w = 5,
   p = {confidence = {0.1, 0.4}, prudence = {0.5, 0.85}},
   s = {experience = {0.02, 0.25}, control = {0.15, 0.45}, decision = {0.15, 0.45}, area = {0.05, 0.35}}},

  {id = 'experienced', label = 'Experienced Driver', w = 6,
   p = {patience = {0.5, 0.8}, confidence = {0.6, 0.9}},
   s = {experience = {0.75, 0.98}, control = {0.65, 0.95}, perception = {0.65, 0.95}, decision = {0.65, 0.95}, area = {0.6, 0.95}}},

  {id = 'risky', label = 'Risky Driver', w = 4,
   p = {aggression = {0.55, 0.9}, prudence = {0.02, 0.2}, confidence = {0.65, 0.95}, ragebait = {0.1, 0.45}, beams = {0.2, 0.7}},
   s = {control = {0.45, 0.85}}},

  {id = 'courteous', label = 'Courteous Driver', w = 6,
   p = {patience = {0.65, 0.95}, aggression = {0.05, 0.3}, tolerance = {0.75, 0.98}, temper = {0.05, 0.3}, horn = {0.01, 0.15}, beams = {0, 0.1}, ragebait = {0, 0.01}},
   s = {decision = {0.5, 0.85}}},

  {id = 'dominant', label = 'Dominant Driver', w = 4,
   p = {aggression = {0.6, 0.9}, confidence = {0.75, 0.98}, tolerance = {0.1, 0.35}, temper = {0.5, 0.85}, beams = {0.35, 0.85}, ragebait = {0.08, 0.4}},
   s = {control = {0.6, 0.9}}},

  {id = 'passive', label = 'Passive Driver', w = 5,
   p = {patience = {0.6, 0.9}, aggression = {0.02, 0.2}, confidence = {0.1, 0.35}, tolerance = {0.6, 0.95}, horn = {0, 0.1}, beams = {0, 0.1}},
   s = {}},

  {id = 'routine', label = 'Routine Driver', w = 5,
   p = {patience = {0.45, 0.75}},
   s = {experience = {0.6, 0.9}, area = {0.8, 0.99}}},

  {id = 'erratic', label = 'Erratic Driver', w = 3,
   p = {patience = {0.05, 0.9}, aggression = {0.1, 0.95}, prudence = {0.05, 0.8}, confidence = {0.1, 0.95}, temper = {0.4, 0.95}, horn = {0.05, 0.8}, ragebait = {0.02, 0.35}},
   s = {control = {0.2, 0.8}, decision = {0.05, 0.5}, perception = {0.2, 0.7}}},

  {id = 'elderly', label = 'Elderly Driver', w = 5,
   p = {patience = {0.5, 0.9}, aggression = {0.02, 0.3}, prudence = {0.6, 0.95}, confidence = {0.2, 0.5}, horn = {0.05, 0.4}},
   s = {experience = {0.6, 0.95}, reflexes = {0.05, 0.35}, control = {0.3, 0.6}, perception = {0.2, 0.5}, area = {0.5, 0.9}}},

  {id = 'newDriver', label = 'New Driver', w = 4,
   p = {patience = {0.4, 0.8}, prudence = {0.55, 0.9}, confidence = {0.05, 0.3}},
   s = {experience = {0.02, 0.2}, control = {0.1, 0.4}, perception = {0.25, 0.55}, decision = {0.1, 0.4}, area = {0.02, 0.3}}},

  {id = 'professional', label = 'Professional Driver', w = 4,
   p = {patience = {0.55, 0.85}, aggression = {0.3, 0.6}, prudence = {0.5, 0.8}, confidence = {0.6, 0.9}, temper = {0.1, 0.4}, ragebait = {0, 0.01}},
   s = {experience = {0.8, 0.99}, reflexes = {0.65, 0.95}, control = {0.75, 0.98}, perception = {0.7, 0.95}, decision = {0.7, 0.95}, area = {0.65, 0.95}}},

  -- Rare on purpose. Sure of themselves, not reckless with ordinary traffic, but will put
  -- a corner of the car in the way of someone running from the police.
  {id = 'hero', label = 'Hero Driver', w = 2,
   p = {patience = {0.45, 0.8}, aggression = {0.4, 0.7}, prudence = {0.25, 0.55},
        confidence = {0.7, 0.98}, tolerance = {0.5, 0.85}, temper = {0.4, 0.75},
        horn = {0.3, 0.8}, beams = {0.3, 0.8}, ragebait = {0, 0.05}},
   s = {experience = {0.6, 0.95}, reflexes = {0.6, 0.95}, control = {0.6, 0.95},
        perception = {0.65, 0.98}, decision = {0.5, 0.85}, area = {0.5, 0.9}}},

  -- Fast for the sake of being fast, and dives into gaps to make a point. Rare on purpose:
  -- meant to be noticed when one turns up, not to be the character of the whole road.
  {id = 'speeder', label = 'Naco', w = 3,
   p = {patience = {0.02, 0.18}, aggression = {0.75, 0.99}, prudence = {0.02, 0.2},
        confidence = {0.8, 0.99}, tolerance = {0.02, 0.25}, temper = {0.55, 0.92},
        horn = {0.35, 0.9}, beams = {0.4, 0.95}, ragebait = {0.2, 0.6}},
   s = {experience = {0.45, 0.85}, reflexes = {0.55, 0.9}, control = {0.5, 0.9},
        perception = {0.4, 0.8}, decision = {0.15, 0.5}, area = {0.4, 0.85}}},

  {id = 'delivery', label = 'Delivery Driver', w = 5,
   p = {patience = {0.15, 0.45}, aggression = {0.5, 0.85}, prudence = {0.25, 0.55}, confidence = {0.55, 0.9}, horn = {0.25, 0.7}},
   s = {experience = {0.6, 0.9}, control = {0.5, 0.8}, area = {0.7, 0.98}}}
}

local byId, total = {}, 0

-- Ranges get expanded against the defaults at load time, so generation is a flat table read.
local function expand(base, over)
  local t = {}
  for k, v in pairs(base) do t[k] = over[k] or v end
  return t
end

for i = 1, #defs do
  local d = defs[i]
  d.p = expand(DEF_P, d.p)
  d.s = expand(DEF_S, d.s)
  total = total + d.w
  d.cw = total
  byId[d.id] = d
end

M.all = defs

function M.get(id)
  return byId[id]
end

function M.random()
  local r = random() * total
  for i = 1, #defs do
    if r <= defs[i].cw then return defs[i] end
  end
  return defs[1]
end

return M
