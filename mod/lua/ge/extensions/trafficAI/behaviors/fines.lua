local M = {}

local floor = math.floor

-- The game already tracks real offences on every vehicle (traffic/vehicle.lua:475), so a
-- ticket is priced off what actually happened rather than invented out of nothing.
local TARIFF = {
  speeding =    {base = 90,  label = 'exceso de velocidad'},
  racing =      {base = 350, label = 'carreras en via publica'},
  reckless =    {base = 280, label = 'conduccion temeraria'},
  wrongWay =    {base = 220, label = 'circular en sentido contrario'},
  intersection ={base = 180, label = 'saltarse un semaforo'},
  hitPolice =   {base = 500, label = 'colision con un vehiculo policial'},
  hitTraffic =  {base = 300, label = 'colision y fuga'}
}

-- Things our own mod noticed that the game does not score by itself.
local EXTRA = {
  ['conduccion molesta'] = {base = 60,  label = 'uso indebido del claxon y las luces'},
  ['exceso de velocidad'] = {base = 90, label = 'exceso de velocidad'},
  ['control rutinario'] = {base = 0,    label = 'control rutinario'}
}

M.total = 0        -- session tally for the player
M.count = 0
M.last = nil       -- {amount, lines = {...}, warning = bool}

local lines = {}

local function moneyAvailable()
  return career_career and career_career.isActive and career_career.isActive()
    and career_modules_playerAttributes ~= nil
end

-- Builds the itemised ticket for one vehicle. Returns the amount and fills `lines`.
function M.assess(tveh, reason)
  local n, amount = 0, 0
  for i = 1, #lines do lines[i] = nil end

  local pursuit = tveh and tveh.pursuit
  local offenses = pursuit and pursuit.offenses
  if offenses then
    for key, data in pairs(offenses) do
      local t = TARIFF[key]
      if t then
        local sum = t.base
        -- Speeding scales with how far over the limit they actually were.
        if key == 'speeding' or key == 'racing' then
          local over = (data.value or 0) - (data.threshold or 0)
          if over > 0 then sum = sum + floor(over * 3.6 * 4) end
        end
        n = n + 1
        lines[n] = string.format('%s: %d', t.label, sum)
        amount = amount + sum
      end
    end
  end

  -- The speed at the moment of the stop, when nothing formal was ever logged.
  if n == 0 then
    local e = EXTRA[reason or '']
    if e and e.base > 0 then
      n = 1
      lines[1] = string.format('%s: %d', e.label, e.base)
      amount = e.base
    end
  end

  return amount, n
end

-- strictness comes from the officer: a lenient one writes a warning for a small ticket.
function M.issue(tveh, reason, strictness, isPlayer)
  local amount, n = M.assess(tveh, reason)
  if n == 0 then
    M.last = {amount = 0, warning = true, text = 'Solo una advertencia verbal.'}
    return 0, true
  end

  -- Small stuff, lenient officer, no formal offences: let off with a warning.
  local warning = amount <= 120 and math.random() > strictness

  local text
  if warning then
    text = 'Advertencia por ' .. (lines[1] or 'la infraccion') .. '. Sin multa.'
    amount = 0
  else
    local body = table.concat(lines, '  |  ', 1, n)
    text = string.format('MULTA %d  (%s)', amount, body)
    if isPlayer then
      M.total = M.total + amount
      M.count = M.count + 1
      if moneyAvailable() then
        -- Career mode has real money; free roam just keeps the running total.
        pcall(function()
          career_modules_playerAttributes.addAttributes({money = -amount},
            {label = 'Multa de trafico', tags = {'gameplay', 'fine'}})
        end)
      end
    end
  end

  M.last = {amount = amount, warning = warning, text = text}
  return amount, warning
end

-- Clears the offence record so the same ticket is not written twice at the next stop.
function M.clearRecord(tveh)
  local p = tveh and tveh.pursuit
  if not p or not p.offenses then return end
  table.clear(p.offenses)
  if p.offensesList then table.clear(p.offensesList) end
  p.uniqueOffensesCount, p.offensesCount, p.addScore = 0, 0, 0
end

function M.reset()
  M.total, M.count, M.last = 0, 0, nil
end

return M
