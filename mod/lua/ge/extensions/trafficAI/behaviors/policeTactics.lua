local M = {}
local units = require('trafficAI/util/units')

local abs = math.abs
local sqrt = math.sqrt
local format = string.format

local TICK = 0.25

-- Real policy, not guesswork: most agencies cap the PIT at 35 mph (15.6 m/s) and treat
-- anything faster as deadly force, so the high ceiling only unlocks at the top of the scale.
local PIT_SPEED_STD = 15.6
local PIT_SPEED_HIGH = 22
local PIT_RANGE = 9
local PIT_LAT = 3
local PIT_APPROACH = 26          -- from here in, the primary lines up on the quarter panel
local PIT_CIVILIAN_CLEAR = 45

local FLANK_RANGE = 55
local BOX_RANGE = 16
local SANDWICH_RANGE = 22
local NUDGE_MAX_CLOSING = 4
local ALONGSIDE = 6

-- Stock chase aims for a minimum 10 m/s relative *crash* speed (ai.lua:4157) with the speed
-- limiter switched off. Every unit gets an explicit ceiling instead, so they close on the
-- suspect rather than into them.
local STANDOFF = 14
local CATCHUP = 9
local TOUCH = 1.5

-- Rolling roadblock. When the suspect comes up behind a unit, stock chase mode plans a
-- U-turn (ai.lua:4180). Instead the unit stays in front, sits in their lane and drags the
-- speed down, which is what the boxing-in / rolling roadblock tactic actually is.
local BLOCK_TRIGGER = 6
local BLOCK_LIFE = 30
local BLOCK_FLOOR = 8
local BOX_FLOOR = 2
local BOX_RANGE_REAR = 18

M.enabled = true
M.roles = {}
M.tacticName = ''
M.suspectId = nil
M.blockers = {}

local timer = 0
local toTarget = vec3()
local right = vec3()
local order, fwdA, latA, distA, spdA = {}, {}, {}, {}, {}
local governed = {}
local refresh = 0

local function send(id, cmd)
  local obj = getObjectByID(id)
  if obj then obj:queueLuaCommand(cmd) end
end

-- Re-sending the same speed four times a second is pure queue traffic, so it only goes out
-- when the number actually moves. Every couple of seconds it goes out anyway: setAiMode ends
-- in ai.reset() (traffic/vehicle.lua:228), which quietly drops the limit we set.
local function govern(pid, target, floor)
  if target < (floor or 3) then target = floor or 3 end
  local prev = governed[pid]
  if prev and abs(prev - target) < 0.6 and refresh > 0 then return end
  governed[pid] = target
  send(pid, 'ai.setSpeedMode("limit")')
  send(pid, format('ai.setSpeed(%.2f)', target))
end

local function ungovern(pid)
  if governed[pid] == nil then return end
  governed[pid] = nil
  send(pid, 'ai.setSpeedMode("off")')
end

local function steer(pid, speed, amount)
  local dist = speed * 1.2
  if dist < 6 then dist = 6 end
  send(pid, format('ai.laneChange(nil, %.1f, %.2f)', dist, amount))
end

-- A lateral push is only safe when the two cars are already level and travelling at about
-- the same speed. Leaning on somebody you are closing on at 15 m/s is a collision.
local function nudge(id, speed, amount, fwd, closing)
  if fwd and (fwd > ALONGSIDE or fwd < -ALONGSIDE) then return false end
  if closing and closing > NUDGE_MAX_CLOSING then return false end
  steer(id, speed, amount)
  return true
end

local function relative(policePos, policeDir, targetPos)
  toTarget:setSub2(targetPos, policePos)
  local fwd = toTarget:dot(policeDir)
  right:set(policeDir)
  local x, y = right.x, right.y
  right.x, right.y, right.z = y, -x, 0
  local len = sqrt(right.x * right.x + right.y * right.y)
  if len > 0.001 then right.x, right.y = right.x / len, right.y / len end
  local lat = toTarget.x * right.x + toTarget.y * right.y
  return fwd, lat
end

-- A PIT that throws the suspect into somebody else is not a tactic, it is a crash. Nobody
-- attempts one unless the road ahead of the runner is clear of ordinary traffic.
local function laneClearAhead(suspect, traffic, police, dist)
  if not suspect.pos or not suspect.dirVec then return false end
  for id, v in pairs(traffic) do
    if id ~= suspect.id and not police[id] and v.pos and not v.isPerson then
      toTarget:setSub2(v.pos, suspect.pos)
      local fwd = toTarget:dot(suspect.dirVec)
      if fwd > 0 and fwd < dist then
        local lat = toTarget:squaredLength() - fwd * fwd
        if lat < 36 then return false end
      end
    end
  end
  return true
end

local function tacticsFor(level)
  if level <= 1 then return {'sigue', 'bloqueo'} end
  if level == 2 then return {'sigue', 'bloqueo', 'paralelo', 'sombra'} end
  if level == 3 then return {'sigue', 'bloqueo', 'paralelo', 'adelanta', 'sandwich', 'PIT'} end
  return {'sigue', 'bloqueo', 'paralelo', 'adelanta', 'sandwich', 'caja', 'PIT'}
end

local function allows(list, name)
  for i = 1, #list do if list[i] == name then return true end end
  return false
end

local function trafficData()
  return gameplay_traffic and gameplay_traffic.getTrafficData()
end

-- Traffic lights only exist for cars in traffic mode (the whole intersection block lives in
-- ai.lua's trafficPlan, ai.lua:5299). A unit in chase mode drives through them, but a rolling
-- blocker is in traffic mode, so it *would* stop dead at a red with the suspect right behind
-- it. Rather than blind the car to signals, no block is held near a signalled junction.
local JUNCTION_CLEAR = 45
local signalNodes, signalChecked = nil, false

local function nearJunction(pos)
  if not signalChecked then
    signalChecked = true
    if core_trafficSignals and core_trafficSignals.getMapNodeSignals then
      local ok, nodes = pcall(core_trafficSignals.getMapNodeSignals)
      signalNodes = ok and nodes or nil
    end
  end
  if not signalNodes or not next(signalNodes) or not map.findClosestRoad then return false end
  local n1, n2 = map.findClosestRoad(pos)
  if not n1 then return false end
  local m = map.getMap and map.getMap()
  local nodes = m and m.nodes
  if not nodes then return false end
  for _, n in ipairs({n1, n2}) do
    if n and signalNodes[n] and nodes[n] and nodes[n].pos
      and nodes[n].pos:squaredDistance(pos) < JUNCTION_CLEAR * JUNCTION_CLEAR then
      return true
    end
  end
  return false
end

local function startBlock(pid, v, level)
  M.blockers[pid] = {timer = BLOCK_LIFE, bite = 0.6 + level * 0.7}
  governed[pid] = nil
  -- The stock role only re-issues chaseTarget while vars.aiMode is 'traffic'
  -- (roles/police.lua:274). Parking it here is what stops the U-turn coming straight back.
  v.vars.aiMode = 'block'
  if units.ai(v) then v:setAiMode('traffic') end
  send(pid, 'ai.setAvoidCars("on")')
  send(pid, 'ai.driveInLane("on")')
  send(pid, 'ai.setAggressionMode("off")')
  send(pid, 'ai.setAggression(0.45)')
  send(pid, 'electrics.set_lightbar_signal(2)')
end

local function releaseBlock(pid, v, resume)
  M.blockers[pid] = nil
  governed[pid] = nil
  if not v then return end
  v.vars.aiMode = 'traffic'
  if resume then
    if v.role and v.role.setAction then
      pcall(function() v.role:setAction('chaseTarget') end)
    end
  else
    -- The chase is over: hand the car back to ordinary traffic instead of re-arming a
    -- chase with nothing to chase.
    if units.ai(v) then v:setAiMode('traffic') end
    send(pid, 'ai.setSpeedMode("legal")')
  end
end

function M.update(dt)
  if not M.enabled then return end
  timer = timer - dt
  if timer > 0 then return end
  timer = TICK
  refresh = refresh - 1
  if refresh < 0 then refresh = 8 end

  if not gameplay_police or not gameplay_police.getPoliceVehicles then return end
  local police = gameplay_police.getPoliceVehicles()
  local traffic = trafficData()
  local objects = map.objects
  if not police or not traffic or not objects then return end

  local suspectId, suspect
  for id, tveh in pairs(traffic) do
    if tveh.pursuit and tveh.pursuit.mode and tveh.pursuit.mode > 0 then
      suspectId, suspect = id, tveh
      break
    end
  end
  M.suspectId = suspectId

  if not suspectId or not suspect.pos or not next(police) then
    for pid in pairs(M.blockers) do releaseBlock(pid, traffic[pid]) end
    for pid in pairs(governed) do ungovern(pid) end
    if next(M.roles) then table.clear(M.roles) M.tacticName = '' end
    return
  end

  table.clear(M.roles)

  local wanted = require('trafficAI/behaviors/wanted')
  local level = wanted.stars or suspect.pursuit.mode or 1
  local allowed = tacticsFor(level)
  local suspectSpeed = suspect.vel and suspect.vel:length() or 0
  local suspectDir = suspect.dirVec
  -- Once the runner has actually stopped the pursuit is over and the arrest begins. Every
  -- unit holds station: the armoured car kept shoving a wreck that could not go anywhere.
  local stopped = suspectSpeed < 1.5

  -- Units sorted by distance, with their relative geometry worked out once.
  local n = 0
  for pid in pairs(police) do
    local o = objects[pid]
    if o and o.pos and o.dirVec and not units.isPlayer(pid) then
      n = n + 1
      order[n] = pid
      distA[pid] = o.pos:squaredDistance(suspect.pos)
    end
  end
  if n == 0 then return end
  for i = 2, n do
    local key = order[i]
    local kd = distA[key]
    local j = i - 1
    while j >= 1 and distA[order[j]] > kd do
      order[j + 1] = order[j]
      j = j - 1
    end
    order[j + 1] = key
  end

  local rearUnitClose = false
  for i = 1, n do
    local pid = order[i]
    local o = objects[pid]
    local fwd, lat = relative(o.pos, o.dirVec, suspect.pos)
    fwdA[pid], latA[pid] = fwd, lat
    spdA[pid] = o.vel and o.vel:length() or 0
    distA[pid] = sqrt(fwd * fwd + lat * lat)
    if not M.blockers[pid] and fwd > 0 and fwd < BOX_RANGE_REAR and abs(lat) < 6 then
      rearUnitClose = true
    end
  end

  -- Boxing in: the textbook end to a pursuit is the units around the suspect slowing to a
  -- stop together. Only once it is already slow and the chase has escalated that far.
  local maxBlockers = level >= 3 and 2 or 1
  local blockCount = 0
  for _ in pairs(M.blockers) do blockCount = blockCount + 1 end

  -- Boxing in only means anything with somebody already holding the front. One car sitting
  -- behind a slow suspect is not a box.
  local boxing = allows(allowed, 'caja') and rearUnitClose and blockCount > 0
    and suspectSpeed < 15

  local pitCeiling = level >= 4 and PIT_SPEED_HIGH or PIT_SPEED_STD
  local pitAllowed = allows(allowed, 'PIT') and not boxing and suspectSpeed < pitCeiling
    and laneClearAhead(suspect, traffic, police, PIT_CIVILIAN_CLEAR)
  local sandwichSide = 1
  M.tacticName = boxing and 'caja' or allowed[#allowed]

  local leaderDone = false

  for i = 1, n do
    local pid = order[i]
    local o = objects[pid]
    local v = traffic[pid]
    local fwd, lat, dist, speed = fwdA[pid], latA[pid], distA[pid], spdA[pid]
    local closing = speed - suspectSpeed
    local sameWay = suspectDir and o.dirVec:dot(suspectDir) > 0.5

    -- Another module already owns this car (a stop, a traffic break, a search, the spike
    -- crew). Two of us steering the same unit is how it ends up doing neither job.
    local mine = not v or not v.vars or v.vars.aiMode == 'traffic' or M.blockers[pid]
    if not mine then
      M.roles[pid] = 'en otra cosa'
      goto continue
    end

    -- setAiMode('chase') forces aggression to at least 0.8 with the rubber band off
    -- (traffic/vehicle.lua:219). That is the "driving like they want us dead" setting, so it
    -- gets dialled back and only climbs again as the pursuit escalates.
    if refresh == 0 and not M.blockers[pid] then
      local agg = 0.5 + level * 0.07
      if agg > 0.85 then agg = 0.85 end
      send(pid, format('ai.setAggression(%.2f)', agg))
    end

    if stopped then
      M.roles[pid] = dist < 12 and 'detencion' or 'llega a la detencion'
      govern(pid, dist < 12 and 0 or 6, 0)
      goto continue
    end

    local b = M.blockers[pid]
    if b then
      b.timer = b.timer - TICK
      -- They got past us, or we have held long enough: hand the unit back to the chase.
      if fwd > 8 or b.timer <= 0 or not sameWay or not v or v.state ~= 'active'
        or nearJunction(o.pos) then
        releaseBlock(pid, v, true)
        M.roles[pid] = 'vuelve a la caza'
        blockCount = blockCount - 1
      else
        -- Sit in their lane, so going round means committing to the other side of the road.
        local amount = lat
        if amount > 2.4 then amount = 2.4 elseif amount < -2.4 then amount = -2.4 end
        steer(pid, speed, amount)

        local floor = boxing and BOX_FLOOR or BLOCK_FLOOR
        local target = suspectSpeed - b.bite
        -- Right on our bumper: never brake harder than they can react to.
        if -fwd < 14 then target = suspectSpeed - 1 end
        if target < floor then target = floor end
        govern(pid, target)
        M.roles[pid] = boxing and 'caja (delante)' or 'bloqueo rodante'
      end

    elseif sameWay and fwd < -BLOCK_TRIGGER and fwd > -140 and abs(lat) < 12
      and blockCount < maxBlockers and suspectSpeed > 4 and suspectSpeed > speed - 3
      and allows(allowed, 'bloqueo') and v and not nearJunction(o.pos) then
      -- The suspect is behind this unit and gaining. Blocking beats turning round.
      startBlock(pid, v, level)
      blockCount = blockCount + 1
      M.roles[pid] = 'se pone a bloquear'

    elseif not leaderDone then
      leaderDone = true
      -- The primary. Speed is always governed, so the closing rate tails off as it arrives
      -- instead of the engine's flat-out run at the suspect's bumper.
      local margin
      if dist > 60 then margin = CATCHUP
      elseif dist > STANDOFF then margin = TOUCH + (dist - STANDOFF) * 0.16
      else margin = TOUCH end

      if boxing then
        -- Already contained. Shoving them now only throws them into the car in front.
        M.roles[pid] = 'caja (detras)'
        govern(pid, suspectSpeed - 0.5)
      elseif pitAllowed and dist < PIT_APPROACH then
        if fwd > 1 and fwd < PIT_RANGE and abs(lat) < PIT_LAT
          and nudge(pid, speed, lat >= 0 and 1.2 or -1.2, 0, closing) then
          M.roles[pid] = 'PIT'
          govern(pid, suspectSpeed + 1)
        else
          -- Line up on their quarter panel first. Without this phase the geometry a PIT
          -- needs never came up on its own and the manoeuvre simply never fired.
          M.roles[pid] = 'se coloca para el PIT'
          local amount = lat * 0.7
          if amount > 2 then amount = 2 elseif amount < -2 then amount = -2 end
          steer(pid, speed, amount)
          govern(pid, suspectSpeed + 3)
        end
      else
        M.roles[pid] = dist < BOX_RANGE and 'pegado' or 'persigue'
        govern(pid, suspectSpeed + margin)
      end

    elseif allows(allowed, 'sandwich') and dist < SANDWICH_RANGE and i <= 3 then
      local side = (i % 2 == 0) and -1.2 or 1.2
      M.roles[pid] = nudge(pid, speed, side, fwd, closing)
        and (side < 0 and 'sandwich izq' or 'sandwich der') or 'se pone al lado'
      govern(pid, suspectSpeed + 2.5)

    elseif allows(allowed, 'adelanta') and dist > FLANK_RANGE then
      -- Get in front rather than joining the queue behind.
      M.roles[pid] = 'se adelanta'
      govern(pid, suspectSpeed + CATCHUP)

    elseif allows(allowed, 'paralelo') and dist < FLANK_RANGE then
      M.roles[pid] = sandwichSide > 0 and 'paralelo der' or 'paralelo izq'
      nudge(pid, speed, sandwichSide * 1.2, fwd, closing)
      sandwichSide = -sandwichSide
      govern(pid, suspectSpeed + 2)

    elseif allows(allowed, 'sombra') then
      M.roles[pid] = 'vigila'
      govern(pid, suspectSpeed * 0.95 + 2)

    else
      M.roles[pid] = 'cierra'
      govern(pid, suspectSpeed + 3)
    end

    -- Nobody past the primary shares the primary's space: each gets its own slot further
    -- back, which is what stops the pile-up behind the lead car.
    if i > 1 and not M.blockers[pid] and dist < BOX_RANGE + i * 6 then
      local slot = suspectSpeed - 1.5 - i * 1.2
      if slot < 3 then slot = 3 end
      govern(pid, slot)
    end

    ::continue::
  end
end

function M.label(id)
  return M.blockers[id] and 'BLOQUEA EL PASO' or nil
end

function M.reset()
  local traffic = trafficData()
  for pid in pairs(M.blockers) do releaseBlock(pid, traffic and traffic[pid]) end
  for pid in pairs(governed) do ungovern(pid) end
  table.clear(M.roles)
  M.tacticName = ''
  M.suspectId = nil
  signalNodes, signalChecked = nil, false
end

return M
