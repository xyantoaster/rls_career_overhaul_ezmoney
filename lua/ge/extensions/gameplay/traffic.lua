-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_police', 'gameplay_traffic_trafficUtils', 'core_vehiclePoolingManager'}

local logTag = 'traffic'

local traffic, trafficAiVehsList, trafficIdsSorted, player, rolesCache = {}, {}, {}, {}, {}
local mapNodes, mapRules
local vehPool, vehPoolId
local trafficVehicle = require('gameplay/traffic/vehicle')

-- const vectors --
local vecUp = vec3(0, 0, 1)
local vecY = vec3(0, 1, 0)

-- common functions --
local min = math.min
local max = math.max
local random = math.random

-- traffic visibility settings --
local TRAFFIC_VISIBLE_DISTANCE = 250  -- Visible range in meters
local TRAFFIC_COLLISION_DISTANCE = 15  -- Collision range in meters
local lastVisibilityUpdate = 0

local TRAFFIC_SPEED_MULTIPLIER = 3.5  -- Increased multiplier for high speeds
local TRAFFIC_STATIONARY_RADIUS = 200 -- Radius to spawn traffic when player is stopped
local TRAFFIC_MIN_VEHICLES_IN_VIEW = 3 -- Minimum vehicles that should be visible

--------
local queuedVehicle = 0
local globalSpawnDist = 0 -- dynamic respawn distance ahead for all traffic vehicles
local globalSpawnDir = 0 -- dynamic respawn direction bias for all traffic vehicles
local state = 'off'
local worldLoaded = false

local spawnProcess = {}
local vars
local altVec = vec3()

local defaultData = {
  countries = {usa = 'United States', germany = 'Germany', italy = 'Italy', japan = 'Japan'}, -- temporary country list
  traffic = {model = 'pickup'},
  police = {model = 'fullsize', config = 'police'}
}

local debugColors = {
  black = ColorF(0, 0, 0, 1),
  white = ColorF(1, 1, 1, 1),
  green = ColorF(0.2, 1, 0.2, 1),
  red = ColorF(0.5, 0, 0, 1),
  blackAlt = ColorI(0, 0, 0, 255),
  greenAlt = ColorI(0, 64, 0, 255)
}

M.debugMode = false -- visual and logging debug mode
M.showMessages = true -- if enabled, UI messages can be automatically shown
M.queueTeleport = false -- sets a flag to make all traffic vehicles teleport when they are ready; TODO: deprecate this

local function getAmountFromSettings() -- gets saved or calculated amount of vehicles
  local amount = settings.getValue('trafficAmount') -- get amount from gameplay settings
  if amount == 0 then -- use CPU-based value
    amount = getMaxVehicleAmount(10)
  end
  return amount
end

local function getIdealSpawnAmount(amount, ignoreAdjust) -- gets the ideal amount of vehicles to spawn based on current world state
  if not amount or amount < 0 then
    amount = getAmountFromSettings()
  end

  local vehCount = 0
  if not ignoreAdjust then
    for _, veh in ipairs(getAllVehiclesByType()) do
      if veh.isParked ~= 'true' and veh:getActive() then
        vehCount = vehCount + 1
      end
    end
  end

  return amount - vehCount
end

local function getNumOfTraffic(activeOnly) -- returns current amount of AI traffic
  return (activeOnly and vehPool) and #vehPool.activeVehs or #trafficAiVehsList
end

local function getCountry() -- returns the country of the map
  return defaultData.countries[1] or 'default'
end

local function setMapData() -- updates all map related data
  mapNodes = map.getMap().nodes
  mapRules = map.getRoadRules()
end

local function getNextSpawnPoint(id, spawnData, placeData) -- sets the new spawn point of a vehicle
  if id and be:getObjectByID(id) then
    local playerId = be:getPlayerVehicleID(0)
    if not spawnData then
      local spawnValue = traffic[id] and traffic[id].respawn.finalSpawnValue or 1
      if spawnValue > 0 then
        local freeCamMode = commands.isFreeCamera() or not traffic[playerId]
        local startPos = freeCamMode and core_camera.getPosition() or traffic[playerId].pos
        local startDir = freeCamMode and core_camera.getForward() or traffic[playerId].driveVec
        local speedValue = freeCamMode and 40 or min(100, square(traffic[playerId].speed * 0.125))
        local addedDist = speedValue
        if freeCamMode then -- if free camera, the added distance is based on height from ground (can make vehicles respawn further away)
          addedDist = startPos.z - max(-1e6, be:getSurfaceHeightBelow(startPos))
          addedDist = clamp(square(addedDist) / 15, 0, 240)
        end
        if spawnValue == 1 then
          addedDist = addedDist + globalSpawnDist
        end

        local baseValue = clamp(100 / spawnValue, 40, 400) -- base value to use for distance
        local minDist = baseValue + addedDist -- spawn search initial distance
        local maxDist = clamp(minDist * 3, 200, 1200) -- spawn search final distance
        local targetDist = minDist + baseValue -- spawn search visible distance (static raycast)
        local spawnRandomValue = traffic[id] and traffic[id].respawn.spawnRandomization or 1 -- spawn search scatter randomness
        local lateralDist = spawnRandomValue * max(20, 100 - speedValue) * 0.25 -- side offset

        if lateralDist ~= 0 then
          -- adjacent roads may be used if enough lateralDist
          altVec:setCross(startDir, vecUp)
          altVec:setScaled(lerp(-lateralDist, lateralDist, random()))
          startPos:setAdd(altVec)
        end

        local params = {}
        params.pathRandomization = freeCamMode and 1 or clamp((100 - speedValue) / 80, 0, spawnRandomValue)

        if traffic[id] then
          -- roads with a drivability < 1 will have a much lower chance of being usable
          params.minDrivability = clamp(math.log10(10 * random() + 1) * 0.9, min(1, traffic[id].drivability), 1)
        end

        spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(startPos, startDir, minDist, maxDist, targetDist, params)
      end
    end
  end

  if spawnData then
    if spawnData.n1 and spawnData.n2 then
      local link = mapNodes[spawnData.n1].links[spawnData.n2] or mapNodes[spawnData.n2].links[spawnData.n1]
      if link then
        -- adjust global respawn distance based on road network density value based on this spawn point
        local branchNodes = map.getGraphpath():getBranchNodesAround(spawnData.n1, 200)
        local branchNodeCount = branchNodes and #branchNodes or 100
        local baseVal = link.speedLimit <= 25 and 500 or 200 -- highways: lower max spawn distance
        local baseCoef = link.speedLimit <= 25 and 25 or 50 -- highways: higher scattering
        local maxDist = baseVal / max(2, branchNodeCount) -- max global respawn distance is affected by the local road network density
        globalSpawnDist = globalSpawnDist + random() * baseCoef -- randomized increase
        if globalSpawnDist >= maxDist then globalSpawnDist = 0 end -- reset value if threshold reached

        globalSpawnDir = globalSpawnDir <= 0 and 0.6 or -0.6
        globalSpawnDir = globalSpawnDir + random() * 0.2 -- random stronger bias for respawning in the incoming direction
      end
    end

    if not placeData then
      -- this needs improvement
      local dirBias = traffic[id] and traffic[id].respawn.spawnDirBias or 0
      if dirBias == 0 then
        dirBias = globalSpawnDir

        if core_camera.getForward():dot(spawnData.pos - core_camera.getPosition()) < 0 then
          dirBias = min(1, dirBias + 0.8) -- vehicles respawning on the path behind should mostly drive towards you
        end
      end

      placeData = {dirRandomization = dirBias}
    end
    placeData.legalDirection = true

    local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, placeData)
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vecY:rotated(quatFromDir(dir, normal)), normal)

    if traffic[id] and spawnData.n1 and spawnData.n2 then
      -- speed boost after respawning
      if traffic[id].hasTrailer then -- has trailer
        traffic[id].respawnSpeed = -1 -- this seems to help with attaching trailer
      elseif (tableSize(map.getGraphpath().graph[spawnData.n2]) > 2 and pos:squaredDistance(mapNodes[spawnData.n2].pos) < 400) then -- is near intersection
        traffic[id].respawnSpeed = nil
      else
        traffic[id].respawnSpeed = max(8, dir:dot(vecUp) * 30) -- 12 km/h, or higher if uphill is steep enough
        local link = mapNodes[spawnData.n1].links[spawnData.n2] or mapNodes[spawnData.n2].links[spawnData.n1]
        if link then
          traffic[id].respawnSpeed = max(traffic[id].respawnSpeed, link.speedLimit * 0.65) -- bigger speed boost at higher speed limits
        end
      end
    end
    return pos, rot
  end
end

local function updateTrafficVisibility(dt, playerVeh, playerPos)
    lastVisibilityUpdate = lastVisibilityUpdate + dt
    if lastVisibilityUpdate < 0.1 then
        return
    end

    lastVisibilityUpdate = 0

    for _, veh in pairs(traffic) do
        local id = veh.id
        if career_career and career_modules_inventory.getInventoryIdFromVehicleId(id) then
            goto continue
        end
        local obj = scenetree.findObjectById(id)
        if obj then
            -- Check distance to other traffic vehicles
            local minDist = math.huge
            for _, otherVehEntry in pairs(traffic) do
                local otherId = otherVehEntry.id
                if otherId ~= id then  -- Exclude self
                    local otherObj = be:getObjectByID(otherId)
                    if otherObj then
                        local dist = veh.pos:distance(otherObj:getPosition())
                        if dist < minDist then
                            minDist = dist
                        end
                    end
                end
            end

            -- Manage visibility based on closest vehicle
            if minDist < TRAFFIC_COLLISION_DISTANCE then
                if veh._wasGhosted then
                    obj:queueLuaCommand("obj:setGhostEnabled(false)")
                    veh._wasGhosted = false
                end
            else
                if not veh._wasGhosted then
                    obj:queueLuaCommand("obj:setGhostEnabled(true)")
                    veh._wasGhosted = true
                end
            end
        end
        ::continue::
    end
end


local function respawnVehicle(id, pos, rot, strict)
  local obj = id and be:getObjectByID(id)
  if not obj or not pos or not rot then return end

  if not strict then
    spawn.safeTeleport(obj, pos, rot, true, nil, false) -- this is slower, but prevents vehicles from spawning inside static geometry
  else
    rot = rot * quat(0, 0, 1, 0)
    obj:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    obj:autoplace(false)
    obj:resetBrokenFlexMesh()
  end
  obj.renderDistance = TRAFFIC_VISIBLE_DISTANCE

  if traffic[id] then
    traffic[id].pos = vec3(pos)
    traffic[id]._teleport = nil
    traffic[id]._teleportDist = nil
    traffic[id]:onRespawn()
  end
end

local function forceTeleport(id, pos, dir, minDist, maxDist, targetDist) -- force teleports a traffic vehicle
  setMapData()

  local vehObj = be:getObjectByID(id)
  if vehObj and vehObj:getActive() then
    pos = pos or core_camera.getPosition()
    dir = dir or core_camera.getForward()
    minDist = minDist or 100
    maxDist = maxDist or 500
    targetDist = targetDist or min(minDist * 2, lerp(minDist, maxDist, 0.5))

    if traffic[id] then
      traffic[id].respawn.pos = vec3(0, 0, -1000)
    end

    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(nil, nil, minDist, maxDist, targetDist)
    local newPos, newRot = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, {legalDirection = true})
    newRot = quatFromDir(newRot, map.surfaceNormal(newPos))
    respawnVehicle(id, newPos, newRot)
  end
end

local function scatterTraffic(vehIds, minDist, maxDist) -- teleports a group of vehicles away from the current place
  vehIds = vehIds or trafficAiVehsList
  for _, id in ipairs(trafficAiVehsList) do
    forceTeleport(id, nil, nil, minDist, maxDist)
  end
end

local function createTrafficPool(idList) -- sets the main traffic vehicle pooling object
  if not core_vehiclePoolingManager then extensions.load('core_vehiclePoolingManager') end
  vehPool = core_vehiclePoolingManager.createPool()
  vehPool.name = 'traffic'
  vehPoolId = vehPool.id

  if idList then
    for _, id in ipairs(idList) do
      vehPool:insertVeh(id)
    end
  end
end

local function deleteTrafficPool() -- deletes the traffic pool and resets variables
  if vehPool then
    vehPool:deletePool(true)
    vehPool, vehPoolId = nil, nil
  end
  vars.activeAmount = math.huge
end

local function updateTrafficPool() -- updates the main traffic vehicle pooling object
  if not vehPool then return end
  vehPool:setMaxActiveAmount(vars.activeAmount, vars.idealActiveAmount)
  vehPool:setAllVehs(true)
end

local function getNextVehFromPool() -- returns the next usable inactive vehicle, or nil if none found
  if vehPool then
    local pool = vehPool
    if vehPool.prevPoolId and core_vehiclePoolingManager.getPoolById(vehPool.prevPoolId) then -- alternate vehicle pool for cycling
      pool = core_vehiclePoolingManager.getPoolById(vehPool.prevPoolId)
    end

    for _, id in ipairs(pool.inactiveVehs) do
      if traffic[id] then
        local activeProbability = traffic[id].enableRespawn and traffic[id].activeProbability or 0 -- later, use zones
        if activeProbability >= random() then -- vehicles are less likely to get activated if they have a lower probability value
          return id
        end
      end
    end
  end
end

local function processNextSpawn(id, ignorePool) -- processes the next vehicle respawn action
  local newPos, newRot
  local oldId, newId = id, id
  local tempId

  if not ignorePool and traffic[id].enableAutoPooling then
    tempId = getNextVehFromPool()
    if tempId then
      if #vehPool.activeVehs < vehPool.realActiveAmount then -- amount of active vehicles is less than the expected limit
        newId = tempId
      else
        oldId, newId = vehPool:crossCycle(vehPool.prevPoolId, oldId, tempId) -- cycles the pool; if a previous pool exists, use a vehicle from there
      end
    end
  end

  if vehPool.allVehs[newId] == 0 then -- if vehicle is still inactive, set it to active
    vehPool:setVeh(newId, true)
  end
  newPos, newRot = getNextSpawnPoint(newId)
  if newPos then
    respawnVehicle(newId, newPos, newRot)
  else
    if not tempId then
      traffic[newId]:onRefresh() -- refreshes the vehicle in place (only if it didn't get cycled)
    else
      forceTeleport(newId, nil, -core_camera.getForward()) -- force teleports the vehicle behind the player view (for now)
    end
  end
end

local function refreshVehicles() -- resets core traffic vehicle data
  for _, veh in pairs(traffic) do
    veh:onRefresh()
  end
end

local function resetTrafficVars() -- resets traffic variables to default
  vars = {
    spawnValue = 1, -- as the default value, globalSpawnDist will dynamically adjust the random respawn distance from player
    spawnDirBias = 0, -- as the default value, globalSpawnDir will dynamically adjust the random respawn direction
    baseAggression = 0.36, -- old default: 0.3
    activeAmount = math.huge,
    idealActiveAmount = nil,
    speedLimit = nil,
    aiMode = 'traffic',
    aiAware = 'auto',
    aiDebug = 'off',
    enableRandomEvents = false -- enables events such as police randomly chasing AI suspects
  }

  refreshVehicles()
end
resetTrafficVars()

local function setTrafficVars(data, reset) -- sets various traffic variables
  if reset then resetTrafficVars() end
  if type(data) ~= 'table' then return end

  for k, v in pairs(data) do
    if k == 'aiMode' or k == 'aiDebug' or k == 'aiAware' then
      data[k] = type(v) == 'string' and string.lower(v) or v
    end
  end

  vars = tableMerge(vars, data)

  for _, id in ipairs(trafficAiVehsList) do
    local veh = traffic[id]

    if data.aiMode then
      veh:setAiMode(vars.aiMode)
    end
    if data.aiAware then
      veh:setAiAware(vars.aiAware)
    end
    if data.speedLimit or data.baseAggression then
      refreshVehicles()
    end
    if data.spawnValue then
      veh.respawn.spawnValue = data.spawnValue
    end
  end

  if data.aiDebug then
    M.debugMode = data.aiDebug == 'traffic'
    gameplay_traffic_trafficUtils.debugMode = M.debugMode
    refreshVehicles()
  end
  if data.activeAmount and vehPool and state == 'on' then -- state needs to be on (not loading) for this to work
    updateTrafficPool()
  end
end

local function setDebugMode(value) -- sets the module debug mode
  value = value and 'traffic' or 'off'
  setTrafficVars({aiDebug = value})
end

local function setActiveAmount(amount, idealAmount) -- sets the maximum amount of active (visible) vehicles
  -- idealAmount is optional and means the total number of active vehicles in the whole scene
  amount = amount or math.huge
  setTrafficVars({activeAmount = amount, idealActiveAmount = idealAmount})
end

local function setPursuitMode(mode) -- sets pursuit mode; -1 = busted, 0 = off, 1 and higher = pursuit level
  extensions.gameplay_police.setPursuitMode(mode)
end

local function getRoleConstructor(roleName) -- gets the role constructor module
  if not rolesCache[roleName] then
    if not FS:fileExists('/lua/ge/extensions/gameplay/traffic/roles/'..roleName..'.lua') then
      log('W', logTag, 'Traffic role does not exist: '..roleName)
      roleName = 'standard'
    end
    rolesCache[roleName] = require('/lua/ge/extensions/gameplay/traffic/roles/'..roleName)
  end
  return rolesCache[roleName]
end

local function insertTraffic(id, ignoreAi, preventAiMode) -- inserts new vehicles into the traffic table
  -- ignoreAi prevents AI and respawn logic from getting applied to the given vehicle
  local obj = be:getObjectByID(id)

  if obj and not traffic[id] then
    traffic[id] = trafficVehicle({id = id})
    if not traffic[id] then -- traffic vehicle object creation failed
      return
    end

    if not ignoreAi then
      table.insert(trafficAiVehsList, id)
      gameplay_walk.addVehicleToBlacklist(id)

      obj:setDynDataFieldbyName('isTraffic', 0, 'true')
      obj.playerUsable = settings.getValue('trafficEnableSwitching') and true or false

      if not vehPool then
        createTrafficPool()
      end
      vehPool:insertVeh(id)

      if not preventAiMode then
        traffic[id]:setAiMode(vars.aiMode)
      end
    end

    trafficIdsSorted = tableKeysSorted(traffic)
    extensions.hook('onTrafficVehicleAdded', id)
  end
end

local function removeTraffic(id, stopAi) -- removes vehicles from the traffic table
  if traffic[id] then
    local obj = be:getObjectByID(id)
    local idx = arrayFindValueIndex(trafficAiVehsList, id)
    if idx then table.remove(trafficAiVehsList, idx) end

    if obj then
      traffic[id].role:resetAction()
      obj:setMeshAlpha(1, '')
      obj.playerUsable = true
      obj.uiState = 1

      if stopAi and traffic[id].isAi then
        obj:queueLuaCommand('ai.setMode("stop")')
      end
    end

    traffic[id] = nil
    trafficIdsSorted = tableKeysSorted(traffic)
    extensions.hook('onTrafficVehicleRemoved', id)
  end

  if vehPool and not trafficAiVehsList[1] then
    deleteTrafficPool()
  end
end

local function checkPlayer(id) -- checks if the player data needs to be inserted
  if state == 'on' then
    local obj = be:getObjectByID(id)

    if obj and obj:isPlayerControlled() then
      if traffic[id] then
        if traffic[id].alpha ~= 1 then -- if vehicle was invisible, show it
          obj:setMeshAlpha(1, '')
          traffic[id].alpha = 1
        end
      else
        insertTraffic(id, true)
      end
    end
  end
end

local function onVehicleSpawned(id)
  if traffic[id] then -- if vehicle is replaced, update its traffic role and properties
    traffic[id]:applyModelConfigData()
    traffic[id]:setRole(traffic[id].autoRole)
    traffic[id]:resetAll()
  end
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleSwitched(oldId, newId)
  checkPlayer(newId, oldId)
end

local function onVehicleResetted(id)
  checkPlayer(id)
  if traffic[id] then
    traffic[id]:onVehicleResetted()
  end
end

local function onVehicleDestroyed(id)
  removeTraffic(id)
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleActiveChanged(vehId, active)
  if vehPool then
    if not vehPool.allVehs[vehId] then
      vehPool._updateFlag = true
    end

    if traffic[vehId] and traffic[vehId].isAi then
      if not active then
        traffic[vehId]._teleport = true
        traffic[vehId].alpha = 0
        be:getObjectByID(vehId):setMeshAlpha(0, '')
      else
        if traffic[vehId]._teleport then -- immediately teleport vehicle if flag exists
          if gameplay_traffic_trafficUtils.checkSpawnPoint(traffic[vehId].pos) then -- if current position is safe, then no teleport needed
            traffic[vehId]:onRefresh()
          else
            forceTeleport(vehId, nil, nil, traffic[vehId]._teleportDist)
          end
        end
      end
    end
  end
end

local function deleteVehicles() -- deletes all traffic vehicles
  for _, veh in ipairs(getAllVehiclesByType()) do
    local id = veh:getId()
    if traffic[id] and (traffic[id].isAi or tonumber(veh.isTraffic) == 1) then
      removeTraffic(id)
      veh:delete()
    end
  end
end

local function activate(vehList) -- activates traffic mode, and adds specified vehicles to the traffic table
  -- backwards compatible stuff
  if type(vehList) ~= 'table' then
    vehList = {}
    for _, v in ipairs(getAllVehiclesByType()) do
      if not v.isParked then
        table.insert(vehList, v:getId())
      end
    end
  end

  if not vehList[1] then
    log('W', logTag, 'No vehicles found; unable to start traffic!')
    return
  end

  table.sort(vehList, function(a, b) return a < b end)

  for _, id in ipairs(vehList) do
    if type(id) == 'number' then
      map.request(id, -1) -- force mapmgr to read map
      insertTraffic(id, be:getObjectByID(id):isPlayerControlled())
    end
  end

  if not next(traffic) then
    log('W', logTag, 'Traffic activation failed!')
  end
end

local function deactivate(stopAi) -- deactivates traffic mode for all vehicles
  for _, id in ipairs(tableKeysSorted(traffic)) do
    removeTraffic(id, stopAi)
  end
end

local function getTrafficGroupFromFile(filters) -- returns an existing vehicle group file
  filters = filters or {}
  local group, fileName
  local dir = path.split(getMissionFilename()) or '/levels/'
  local files = FS:findFiles(dir, '*.vehGroup.json', 0, true, true)
  if not files[1] or filters.useCustom then
    files = FS:findFiles('/vehicleGroups/', '*.vehGroup.json', -1, true, true)
  end

  if filters.name then
    local filteredFiles = {}
    for _, v in ipairs(files) do
      local d, fn = path.splitWithoutExt(v)
      if string.find(fn, string.lower(filters.name)) then
        table.insert(filteredFiles, v)
      end
    end
    files = filteredFiles
  end

  if files[1] then
    fileName = files[math.random(#files)] -- if multiple files exist, select one randomly
    group = jsonReadFile(fileName)
    if group then
      group = group.data
    end
  end
  return group, fileName
end

local function createBaseGroupParams() -- returns base group generation parameters
  return {filters = {Type = {car = 1, truck = 0.75}, ["Derby Class"] = {["heavy truck"] = 0, other = 1}}, country = getCountry(), maxYear = 0, minPop = 50}
end

local function createTrafficGroup(amount, allMods, allConfigs, simpleVehs) -- creates a traffic group with the use of some player settings
  allConfigs = true
  simpleVehs = settings.getValue('trafficSimpleVehicles')
  allMods = settings.getValue('trafficAllowMods')

  local params = createBaseGroupParams()
  params.allMods = allMods
  params.modelPopPower = settings.getValue('trafficSmartSelections') and 1 or 0
  params.configPopPower = settings.getValue('trafficSmartSelections') and 1 or 0

  if simpleVehs then
    params.allConfigs = true
    params.filters.Type = {proptraffic = 1}
    params.minPop = 0
  else
    params.allConfigs = allConfigs
    params.filters['Config Type'] = {Police = 0, other = 1} -- no police cars

    if params.allMods and params.filters.Type then
      params.filters.Type.automation = 1
      params.minPop = 0
    end
  end

  return core_multiSpawn.createGroup(amount, params)
end

local function createPoliceGroup(amount, allMods) -- creates a group of police vehicles
  allMods = settings.getValue('trafficAllowMods')

  local params = createBaseGroupParams()

  params.allMods = allMods
  params.allConfigs = true
  params.minPop = 0
  params.modelPopPower = 1
  params.configPopPower = 1

  if params.allMods and params.filters.Type then
    params.filters.Type.automation = 1
  end
  if params.country ~= 'default' then
    params.filters.Country = {[params.country] = 100, other = 0.1} -- other is 0.1 (not 0) just in case no country matches
  end
  params.filters['Config Type'] = {police = 1}

  return core_multiSpawn.createGroup(amount, params)
end

local function spawnTraffic(amount, group, options) -- spawns a defined group of vehicles and sets them as traffic
  amount = amount or max(1, getAmountFromSettings() - #getAllVehiclesByType())
  group = group or core_multiSpawn.createGroup(amount)
  options = type(options) == 'table' and options or {}
  state = 'spawning'

  if not options.pos then
    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(nil, nil, 0, 200, 0)
    options.pos, options.dir = spawnData.pos, spawnData.dir
  end

  return core_multiSpawn.spawnGroup(group, amount, {name = 'autoTraffic', mode = options.mode or 'traffic', gap = options.gap or 20, pos = options.pos, dir = options.dir, ignoreJobSystem = not worldLoaded, ignoreAdjust = not worldLoaded})
end

local function setupTraffic(amount, policeRatio, options) -- prepares a group of vehicles for traffic
  amount = amount or -1
  policeRatio = policeRatio or 0
  options = type(options) == 'table' and options or {}

  if not options.ignoreDelete then
    deleteVehicles() -- clear current traffic
  end
  deleteTrafficPool()

  local trafficGroup, policeGroup
  local policeAmount = 0
  local activeAmount = options.activeAmount or amount

  if type(options.vehGroup) == 'table' then -- directly sets a vehicle group to be used for traffic; may overwrite other parameters
    trafficGroup = options.vehGroup
    log('I', logTag, 'Applying custom traffic group')
  end

  if amount == -1 then -- auto amount
    local amountFromSettings = getAmountFromSettings()
    amount = getIdealSpawnAmount(amountFromSettings) -- maxAmount automatically accounts for currently spawned non-traffic vehicles
    policeAmount = options.policeAmount or math.ceil(amount * policeRatio)
    activeAmount = amount

    if settings.getValue('trafficExtraVehicles') then
      local extraAmount = settings.getValue('trafficExtraAmount')
      if extraAmount == 0 then
        extraAmount = clamp(amountFromSettings, 2, 8)
      end

      amount = max(amountFromSettings, amount + extraAmount)
    end
  else
    if options.autoAdjustAmount then
      amount = getIdealSpawnAmount(amount) -- adjust for amount of existing active vehicles
    end
    policeAmount = options.policeAmount or math.ceil(amount * policeRatio)
  end

  if not trafficGroup then -- if predefined vehicle group does not exist, create it
    if policeAmount >= 1 then
      policeAmount = min(policeAmount, amount)
      local fileData, fileName
      local fileMode = options.autoLoadFromFile or settings.getValue('trafficSmartSelections')
      if fileMode then
        fileData, fileName = getTrafficGroupFromFile({name = 'police'})
        if fileData then
          fileData = core_multiSpawn.fitGroup(fileData, policeAmount)
          log('I', logTag, 'Loaded police group from file: '..tostring(fileName))
        end
      end
      policeGroup = fileData or createPoliceGroup(policeAmount)

      if not policeGroup[1] then
        for i = 1, policeAmount do
          table.insert(policeGroup, defaultData.police)
        end
      end
    end

    if amount >= 1 then
      if not trafficGroup then
        local fileData, fileName
        local fileMode = options.autoLoadFromFile and not (settings.getValue('trafficSimpleVehicles') or options.simpleVehs)
        if fileMode then
          fileData, fileName = getTrafficGroupFromFile({name = 'traffic'})
          if fileData then
            fileData = core_multiSpawn.fitGroup(fileData, amount)
            log('I', logTag, 'Loaded traffic group from file: '..tostring(fileName))
          end
        end

        trafficGroup = fileData or createTrafficGroup(amount, options.allMods, options.allConfigs, options.simpleVehs)
      end
      if not trafficGroup[1] then
        for i = 1, amount do
          table.insert(trafficGroup, defaultData.traffic)
        end
      end

      if policeGroup then
        for i = 1, policeAmount do
          if policeGroup[i] then
            table.insert(trafficGroup, 1, policeGroup[i]) -- insert at the start of the array (police vehicles have priority)
            table.remove(trafficGroup, #trafficGroup)
          end
        end
      end
    end
  end

  if amount > 0 and trafficGroup and trafficGroup[1] then
    spawnProcess.group = trafficGroup
    spawnProcess.amount = amount

    local multiSpawnOptions = {}
    multiSpawnOptions.pos = options.pos
    multiSpawnOptions.rot = options.rot
    if next(multiSpawnOptions) then spawnProcess.multiSpawnOptions = multiSpawnOptions end
    state = 'loading'

    createTrafficPool()
    setTrafficVars({aiMode = 'traffic', activeAmount = activeAmount})
    --idealActiveAmount = vehPool:getSceneActiveAmount() + activeAmount
  else
    if amount <= 0 then
      log('W', logTag, 'Traffic amount to spawn is zero!')
    else
      log('W', logTag, 'Traffic vehicle group is undefined!')
    end
    ui_message('ui.traffic.spawnLimit', 5, 'traffic', 'traffic')
    return false
  end

  return true
end

local function setupTrafficWaitForUi(usePolice) -- this is called from the radial menu and displays a loading screen
  spawnProcess.amount = -1
  spawnProcess.policeRatio = usePolice and 0.333 or 0
  spawnProcess.waitForUi = true
  setTrafficVars({aiMode = 'traffic', enableRandomEvents = true})
  guihooks.trigger('menuHide')
  guihooks.trigger('app:waiting', true) -- shows the loading icon
end

local function setupCustomTraffic(amount, params) -- spawns a group of vehicles for traffic, with custom parameters
  if type(params) ~= 'table' then params = {} end
  if not amount or amount < 0 then amount = getAmountFromSettings() end
  params.country = params.country or getCountry()

  spawnTraffic(amount, core_multiSpawn.createGroup(amount, params))
end

-- spawns and de-spawns traffic vehicles in freeroam
-- keepInMemory allows instantenous reactivation at the expense of ram consumption when traffic is disabled
local function toggle(keepInMemory)
  if core_gamestate.state.state == 'freeroam' then
    if state == 'off' then
      setupTraffic()
    elseif state == 'on' then
      if keepInMemory then
        if vars.activeAmount == 0 then
          vars.activeAmount = vars.prevActiveAmount or getAmountFromSettings()
          updateTrafficPool()
        else
          vars.prevActiveAmount = vars.activeAmount
          if vars.prevActiveAmount <= 0 then vars.prevActiveAmount = getAmountFromSettings() end
          vars.activeAmount = 0
          updateTrafficPool()
          for id, veh in pairs(traffic) do
            veh._teleport = true
            veh._teleportDist = 10
          end
        end
      else
        deleteVehicles()
      end
    end
  end
end

local function freezeState() -- stops the traffic and parking systems, and returns the state data
  return M.onSerialize(), gameplay_police.onSerialize(), gameplay_parking.onSerialize()
end

local function unfreezeState(trafficData, policeData, parkingData) -- reverts the traffic and parking systems
  if not trafficData and not parkingData then
    log('W', logTag, 'No data provided to revert state!')
    return
  end
  if trafficData then
    M.onDeserialized(trafficData)
    scatterTraffic()
  end
  if policeData then
    gameplay_police.onDeserialized(policeData)
  end
  if parkingData then
    gameplay_parking.onDeserialized(parkingData)
  end
end

local function doTraffic(dt, dtSim) -- various logic for traffic; also handles when to respawn traffic
  if not player.camPos then
    player.camPos, player.camDirVec = vec3(), vec3()
  end

  player.camPos:set(core_camera.getPositionXYZ())
  player.camDirVec:set(core_camera.getForwardXYZ())
  player.pos = map.objects[be:getPlayerVehicleID(0)] and map.objects[be:getPlayerVehicleID(0)].pos or player.camPos

  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  local vehCount = 0
  local aiVehsListSize = #trafficAiVehsList
  for i, id in ipairs(trafficIdsSorted) do -- ensures consistent order of vehicles
    vehCount = vehCount + 1
    local veh = traffic[id]
    if veh then
      veh.playerData = player
      veh:onUpdate(dt, dtSim)

      if veh.isAi and be:getObjectActive(id) then
        if veh.state == 'reset' then
          veh:onRefresh()

          if vars.enableRandomEvents and vars.aiMode == 'traffic' and veh.respawnCount > 0 then
            veh.role:tryRandomEvent()
          end
        end

        if i == queuedVehicle then -- checks one vehicle per frame, as an optimization
          if veh._teleport then
            forceTeleport(id, nil, nil, veh._teleportDist)
          else
            if veh.state == 'active' then
              veh:tryRespawn(aiVehsListSize)
            elseif veh.state == 'queued' then
              processNextSpawn(id)
            end
          end

          veh.otherCollisionFlag = nil
        end
      end
    end
  end

  queuedVehicle = queuedVehicle + 1
  if queuedVehicle > vehCount then
    queuedVehicle = 1
  end
end

local function doDebug() -- general debug visuals
  local linePoint = core_camera.getPosition() + core_camera.getForward()
  linePoint.z = linePoint.z - 1
  for id, veh in pairs(traffic) do
    if be:getObjectActive(id) then
      local lineColor = veh.camVisible and debugColors.green or debugColors.white
      local txtColor = debugColors.white
      local bgColor = veh.isPlayerControlled and debugColors.greenAlt or debugColors.blackAlt
      if veh.state == 'fadeIn' then lineColor = debugColors.red end

      if veh.debugLine then
        debugDrawer:drawLine(veh.pos, linePoint, lineColor)
      end

      if veh.debugText then
        debugDrawer:drawTextAdvanced(veh.pos, String('['..veh.id..']: '..math.floor(veh.distCam)..' m, '..math.floor((veh.speed or 0) * 3.6)..' km/h'), txtColor, true, false, bgColor)
        if veh.pursuit.mode ~= 0 then
          debugDrawer:drawTextAdvanced(veh.pos, String('[PURSUIT]: mode = '..veh.pursuit.mode..', score = '..math.ceil(veh.pursuit.score)..', offenses = '..veh.pursuit.uniqueOffensesCount), txtColor, true, false, bgColor)
        end
      end
    end
  end
end

local function onSettingsChanged()
  for id, veh in pairs(traffic) do
    if veh.isAi then
      be:getObjectByID(id).uiState = core_settings_settings.getValue('trafficMinimap') and 1 or 0
      be:getObjectByID(id).playerUsable = settings.getValue('trafficEnableSwitching') and true or false
    end
  end
end

local function trackAIAllVeh(mode) -- triggers when the player sets an AI mode for all vehicles
  vars.aiMode = string.lower(mode)
  refreshVehicles()
end

local function onVehicleMapmgrUpdate(id) -- when the latest spawned vehicle processes its mapmgr, complete the spawning process
  if vehPool and spawnProcess.vehList and spawnProcess.vehList[#spawnProcess.vehList] == id then
    if not worldLoaded then
      worldLoaded = true
    end

    if spawnProcess.waitForUi then
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
    end
    table.clear(spawnProcess)
    vehPool._updateFlag = true
  end
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == 'autoParking' then
    if not spawnProcess.trafficSetup then
      if spawnProcess.waitForUi then
        guihooks.trigger('app:waiting', false)
        guihooks.trigger('QuickAccessMenu')
      end
      table.clear(spawnProcess)
    end
  end

  if groupName == 'autoTraffic' then
    spawnProcess.vehList = vehList
    activate(spawnProcess.vehList)
    local _, dist = gameplay_traffic_trafficUtils.getNearestTrafficVehicle()
    if dist > 50 then
      ui_message('Traffic was moved to nearest valid road', 5, 'traffic', 'traffic')
    end
  end
end

local function onUpdate(dtReal, dtSim)
  if state == 'loading' then
    spawnTraffic(spawnProcess.amount, spawnProcess.group, spawnProcess.multiSpawnOptions)
  end

  -- these hooks activate the frame after the first or last traffic vehicle gets inserted or removed
  if state ~= 'on' and trafficAiVehsList[1] then
    extensions.hook('onTrafficStarted')
  end
  if state == 'on' and not trafficAiVehsList[1] then
    extensions.hook('onTrafficStopped')
  end

  if state == 'on' then
    if vehPool and vehPool._updateFlag and not spawnProcess.vehList then
      updateTrafficPool()
      vehPool._updateFlag = nil
    end

    if M.queueTeleport then
      scatterTraffic()
      M.queueTeleport = false
    end
    if be:getEnabled() and not freeroam_bigMapMode.bigMapActive() then
          -- Add visibility update
          updateTrafficVisibility(dtReal)
      doTraffic(dtReal, dtSim)
    end
  end
end

local function onPreRender(dt)
  if M.debugMode then
    doDebug()
  end
end

local function onTrafficStarted()
  setMapData()
  state = 'on'
  globalSpawnDist = 0
  globalSpawnDir = 0

  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  vehPool._updateFlag = true -- acts like a frame delay for the vehicle pooling system

  if gameplay_walk.isWalking() then -- check for player unicycle
    checkPlayer(be:getPlayerVehicleID(0))
  end
  for _, veh in ipairs(getAllVehiclesByType()) do -- check for player vehicles to insert into traffic
    checkPlayer(veh:getId())
  end
end

local function onTrafficStopped()
  deleteTrafficPool()
  table.clear(traffic)
  table.clear(trafficAiVehsList)
  table.clear(player)
  state = 'off'
end

local function onClientStartMission()
  if state == 'off' then
    worldLoaded = true
  end
end

local function onClientEndMission()
  onTrafficStopped()
  resetTrafficVars()
  worldLoaded = false
end

local function onUiWaitingState()
  if spawnProcess.waitForUi and not spawnProcess.trafficSetup and not spawnProcess.parkingSetup then
    if settings.getValue('trafficParkedVehicles') then
      spawnProcess.parkingSetup = gameplay_parking.setupVehicles()
    else
      spawnProcess.parkingSetup = false
    end
    spawnProcess.trafficSetup = setupTraffic(spawnProcess.amount, spawnProcess.policeRatio)

    if not spawnProcess.trafficSetup and not spawnProcess.parkingSetup then -- if there is nothing to spawn, reset the waiting UI
      table.clear(spawnProcess)
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
      state = 'off'
    end
  end
end

local function onSerialize()
  local trafficData = {}
  for _, veh in pairs(traffic) do
    table.insert(trafficData, veh:onSerialize())
  end
  local data = {state = state, traffic = deepcopy(trafficData), vars = deepcopy(vars)}
  onTrafficStopped()
  mapNodes, mapRules = nil, nil
  return data
end

local function onDeserialized(data)
  worldLoaded = true
  vars = data.vars
  if data.state == 'on' then
    for _, veh in pairs(data.traffic) do
      insertTraffic(veh.id, not veh.isAi)
      if traffic[veh.id] then
        traffic[veh.id]:onDeserialized(veh)
      end
    end
    updateTrafficPool()
  end
end

---- getter functions ----

local function getState() -- returns traffic system state
  return state
end

local function getTrafficPool()
  return core_vehiclePoolingManager and core_vehiclePoolingManager.getPoolById(vehPoolId) -- returns current vehicle pool object used for traffic
end

local function getTrafficAiVehIds() -- returns traffic list of ids
  return trafficAiVehsList
end

local function getTrafficData() -- returns the full traffic table
  return traffic
end

local function getTrafficVars()
  return vars
end

-- public interface
M.spawnTraffic = spawnTraffic
M.setupTraffic = setupTraffic
M.setupTrafficWaitForUi = setupTrafficWaitForUi
M.createTrafficGroup = createTrafficGroup
M.createPoliceGroup = createPoliceGroup
M.setupCustomTraffic = setupCustomTraffic
M.insertTraffic = insertTraffic
M.removeTraffic = removeTraffic
M.deleteVehicles = deleteVehicles
M.activate = activate
M.deactivate = deactivate
M.toggle = toggle
M.refreshVehicles = refreshVehicles

M.forceTeleport = forceTeleport
M.forceTeleportAll = scatterTraffic
M.scatterTraffic = scatterTraffic
M.getRoleConstructor = getRoleConstructor
M.setPursuitMode = setPursuitMode
M.setDebugMode = setDebugMode
M.getTrafficPool = getTrafficPool
M.getTrafficVars = getTrafficVars
M.setTrafficVars = setTrafficVars
M.setActiveAmount = setActiveAmount
M.getIdealSpawnAmount = getIdealSpawnAmount

M.getState = getState
M.freezeState = freezeState
M.unfreezeState = unfreezeState
M.getNumOfTraffic = getNumOfTraffic
M.getTrafficList = getTrafficAiVehIds
M.getTrafficAiVehIds = getTrafficAiVehIds
M.getTrafficData = getTrafficData
M.getTraffic = getTrafficData

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.trackAIAllVeh = trackAIAllVeh
M.onSettingsChanged = onSettingsChanged
M.onVehicleMapmgrUpdate = onVehicleMapmgrUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onUiWaitingState = onUiWaitingState
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
