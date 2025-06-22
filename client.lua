--Todo:
    -- HideHUD
    -- 2. Variant for JSOC
    -- fix drone tilt glitch 
    -- itemicon 

-- ========================================
-- CONFIGURATION SETTINGS
-- ========================================

-- Ensure Config.MapMarker.trackRotation has a default value if not defined
if Config and Config.MapMarker and Config.MapMarker.trackRotation == nil then
    Config.MapMarker.trackRotation = false -- Default to lock north instead of tracking rotation
end

local ESX = nil
local QBCore = nil

local currentSoundId = -1
local lastSoundType = ""
local soundTimer = 0
local allDrones = {}
local playerJob = "unemployed"
local originalHudState = {}

-- Missing drone control variables
local droneEntity, droneCamera = nil, nil
local controllingDrone = false
local currentFOV = Config.MaxFOV
local droneCoordsStart, visionMode = nil, 0
local droneBlip = nil
local heliCamScaleform = nil
local propObject = nil
local isAnimationPlaying = false
local minimapLocked = false
local playerData = {
    name = "",
    job = "nil",
    grade = "nil"
}

-- NEW: State variables for battery and distance limiters
local batteryStartTime = 0
local currentBatteryPercentage = 1.0
local isLowBattery = false
local isCriticalBattery = false
local isNoiseTestActive = false
local playNoiseSound, stopNoiseSound -- Forward declaration

local currentDistanceToStart = 0.0
local keepOverlayVisible = false -- Track if overlay should stay visible after drone ends
local calculatedSignalQuality = 100.0 -- Signal bars percentage (0-100)
local calculatedNoiseIntensity = 0.0 -- Noise overlay intensity (0.0-1.0)

-- NEW: Jammer integration variables
local jammerSignalLoss = 0.0 -- Signal loss from jammers (0.0-1.0)
local jammerNoiseIntensity = 0.0 -- Noise intensity from jammers (0.0-1.0)
local inNogoZone = false -- Whether drone is in a no-go zone
local nearestJammerDistance = math.huge -- Distance to nearest affecting jammer
local lastJammerDebugTime = 0 -- For debug timing
local lastSignalDebugTime = 0 -- For signal calculation debug timing
local lastNUIDebugTime = 0 -- For NUI message debug timing
local inNoGoZoneLastFrame = false -- To track entering no-go zones

-- ================================================================
-- BATTERY STATE MANAGEMENT
-- ================================================================
local function resetBatteryState()
    if Config.RuntimeLimiter.enabled then
        batteryStartTime = GetGameTimer()
        currentBatteryPercentage = 1.0
        isLowBattery = false
        isCriticalBattery = false
        isNoiseTestActive = false
    end
end

-- ================================================================
-- JAMMER INTEGRATION FUNCTIONS
-- ================================================================

-- Fetch all jammers with verification and debug output
local function getAllJammersWithVerification()
    local jammers = nil
    local success, result = pcall(function()
        return exports['jammer']:GetAllJammers()
    end)
    
    if success then
        jammers = result
        if Config.Debug and Config.Debug.enabled then
            local count = 0
            for _ in pairs(jammers or {}) do count = count + 1 end
            print('[Drone] Successfully retrieved ' .. count .. ' jammers from jammer export')
        end
    else
        if Config.Debug and Config.Debug.enabled then
            print('[Drone] ERROR: Failed to get jammers from export: ' .. tostring(result))
        end
        jammers = {}
    end
    
    return jammers or {}
end

local function getAllJammers()
    return getAllJammersWithVerification()
end

-- Check if player owns a specific jammer
local function isPlayerJammerOwner(jammer)
    if not Config.JammerIntegration.excludeOwnerJammers then
        return false
    end
    
    -- Get player identifier (similar to jammer script logic)
    local playerIdentifier = nil
    if Config.Framework == "qb" and QBCore then
        local PlayerData = QBCore.Functions.GetPlayerData()
        playerIdentifier = PlayerData.citizenid
    elseif Config.Framework == "esx" and ESX then
        local PlayerData = ESX.GetPlayerData()
        playerIdentifier = PlayerData.identifier
    else
        playerIdentifier = tostring(GetPlayerServerId(PlayerId()))
    end
    
    return jammer.owner == playerIdentifier
end

-- Get player job function (moved here to be available before calculateJammerEffects)
local function getPlayerJob()
    local jobName = "" -- Default
    local sourceOfJob = "initial_default"

    if Config.Framework == "esx" then
        if ESX then
            local esxData = ESX.GetPlayerData()
            if esxData and esxData.job and esxData.job.name and esxData.job.name ~= "" and esxData.job.name ~= "unemployed" then
                jobName = esxData.job.name
                sourceOfJob = "esx_direct"
            end
        end
    elseif Config.Framework == "qb" then
        if QBCore then
            local qbData = QBCore.Functions.GetPlayerData()
            if qbData and qbData.job and qbData.job.name and qbData.job.name ~= "" and qbData.job.name ~= "unemployed" then
                jobName = qbData.job.name
                sourceOfJob = "qb_direct"
            end
        end
    end

    if (jobName == "unemployed" or jobName == "") and playerData and playerData.job and playerData.job ~= "nil" and playerData.job ~= "" and playerData.job ~= "unemployed" then
        jobName = playerData.job
        sourceOfJob = "playerData_fallback"
    end
    
    if jobName == "" or jobName == "nil" then
        jobName = "unemployed"
        if sourceOfJob ~= "playerData_fallback" then 
            sourceOfJob = "final_default_due_to_nil_empty"
        end
    end
    return jobName
end

-- Calculate jammer effects on drone signal and noise
local function calculateJammerEffects(droneCoords)
    if not Config.JammerIntegration.enabled or not droneCoords then
        return 0.0, 0.0, false -- No signal loss, no noise, not in no-go zone
    end
    
    local allJammers = getAllJammers()
    if not allJammers or next(allJammers) == nil then
        return 0.0, 0.0, false -- No jammers found
    end
    
    -- Get current player job for job detection
    local currentPlayerJob = getPlayerJob()
    
    local maxSignalLoss = 0.0
    local maxNoiseIntensity = 0.0
    local inAnyNogoZone = false
    local closestDistance = math.huge
    local jammersProcessed = 0
    local jammersInRange = 0 -- Initialize to 0 to prevent nil error
    local debugInfo = {}
    
    -- Check each jammer for effects
    for jammerIdOrIndex, jammer in pairs(allJammers) do
        if jammer.coords and jammer.range then
            jammersProcessed = jammersProcessed + 1
            
            -- Skip owner's jammers if configured
            if Config.JammerIntegration.excludeOwnerJammers and isPlayerJammerOwner(jammer) then
                table.insert(debugInfo, "Jammer " .. tostring(jammerIdOrIndex) .. " skipped (owner)")
                goto continue
            end
            
            -- NEW: Check if player's job is in the jammer's ignored jobs list
            if jammer.ignoredJobs and type(jammer.ignoredJobs) == "table" then
                local isJobIgnored = false
                for _, ignoredJob in ipairs(jammer.ignoredJobs) do
                    if string.lower(currentPlayerJob) == string.lower(ignoredJob) then
                        isJobIgnored = true
                        break
                    end
                end
                
                if isJobIgnored then
                    table.insert(debugInfo, "Jammer " .. tostring(jammerIdOrIndex) .. " (" .. (jammer.label or "Unknown") .. ") skipped - Job ignored: " .. currentPlayerJob)
                    goto continue
                end
            end
            
            local jammerCoords = vector3(jammer.coords.x, jammer.coords.y, jammer.coords.z)
            local distance = #(droneCoords - jammerCoords)
            local jammerRange = tonumber(jammer.range) or 50.0
            
            -- Track closest jammer distance
            if distance < closestDistance then
                closestDistance = distance
            end
            
            local jammerDebug = "Jammer " .. tostring(jammerIdOrIndex) .. " dist:" .. string.format("%.1f", distance) .. "m range:" .. jammerRange .. "m"
            
            -- Check if within jammer range
            if distance <= jammerRange then
                jammersInRange = jammersInRange + 1
                
                -- Check no-go zone first (highest priority)
                local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2 -- Default to 20% if not specified
                local nogoThreshold
                
                if noGoZoneValue >= 1.0 then
                    -- Absolute radius in meters
                    nogoThreshold = noGoZoneValue
                else
                    -- Percentage of jammer range
                    nogoThreshold = jammerRange * noGoZoneValue
                end
                
                if Config.JammerIntegration.NogoZone.enabled and distance <= nogoThreshold then
                    inAnyNogoZone = true
                    jammerDebug = jammerDebug .. " [NO-GO ZONE at " .. string.format("%.1f", nogoThreshold) .. "m (config: " .. tostring(noGoZoneValue) .. ")]"
                    table.insert(debugInfo, jammerDebug)
                    break -- No-go zone overrides everything
                end
                
                -- Calculate signal degradation within jammer range
                if Config.JammerIntegration.SignalEffect.enabled then
                    -- Calculate no-go zone boundary
                    local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2
                    local nogoThreshold = noGoZoneValue >= 1.0 and noGoZoneValue or (jammerRange * noGoZoneValue)
                    
                    -- Signal degradation: minimum 75% loss at jammer edge, maximum at no-go zone
                    if distance >= nogoThreshold then
                        -- Distance from no-go zone boundary outward to jammer range
                        local signalEffectDistance = jammerRange - nogoThreshold
                        local distanceFromNogoZone = distance - nogoThreshold
                        
                        -- Progress from 1.0 (at no-go zone) to 0.75 (at jammer edge for 1 bar)
                        local signalProgress = 1.0 - (distanceFromNogoZone / signalEffectDistance)
                        signalProgress = math.max(0, math.min(1, signalProgress))
                        
                        -- Apply degradation exponent
                        local degradationExponent = Config.JammerIntegration.SignalEffect.degradationExponent or 7.5
                        signalProgress = math.pow(signalProgress, degradationExponent)
                        
                        -- Scale between 75% (1 bar remaining at jammer edge) and 90% (max) signal loss
                        local minSignalLoss = 0.75 -- 1 bar remaining at jammer edge
                        local maxSignalLoss = Config.JammerIntegration.SignalEffect.maxSignalLoss or 0.9
                        local signalLoss = minSignalLoss + (signalProgress * (maxSignalLoss - minSignalLoss))
                        maxSignalLoss = math.max(maxSignalLoss, signalLoss)
                        
                        jammerDebug = jammerDebug .. " [SIGNAL LOSS:" .. string.format("%.2f", signalLoss) .. " (1 bar at edge, max at " .. string.format("%.1f", nogoThreshold) .. "m)]"
                    else
                        -- Inside no-go zone = maximum signal loss
                        local signalLoss = Config.JammerIntegration.SignalEffect.maxSignalLoss or 0.9
                        maxSignalLoss = math.max(maxSignalLoss, signalLoss)
                        jammerDebug = jammerDebug .. " [SIGNAL LOSS:" .. string.format("%.2f", signalLoss) .. " MAXIMUM (in no-go zone)]"
                    end
                end
                
                -- Calculate noise effects based on proximity to the no-go zone.
                -- Noise starts at jammer edge (0%) and reaches maximum at no-go zone boundary (100%)
                if Config.DistanceLimiter.NoiseEffect.enabled then
                    local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2
                    local nogoThreshold = noGoZoneValue >= 1.0 and noGoZoneValue or (jammerRange * noGoZoneValue)

                    -- Ensure nogoThreshold is not greater than the jammer range itself
                    nogoThreshold = math.min(nogoThreshold, jammerRange)

                    -- The noise effect zone is from jammer edge to no-go zone boundary
                    local noiseEffectZone = jammerRange - nogoThreshold
                    
                    if noiseEffectZone > 0 and distance >= nogoThreshold and distance <= jammerRange then
                        -- Calculate progress from jammer edge (0) to no-go zone boundary (1)
                        -- As drone moves closer to no-go zone, noise increases
                        local distanceFromNoGoZone = distance - nogoThreshold
                        local noiseProgress = 1.0 - (distanceFromNoGoZone / noiseEffectZone)
                        noiseProgress = math.max(0, math.min(1, noiseProgress))
                        
                        -- Apply degradation exponent from DistanceLimiter for a non-linear ramp-up
                        local degradationExponent = Config.DistanceLimiter.NoiseEffect.degradationExponent or 7.5
                        noiseProgress = math.pow(noiseProgress, degradationExponent)
                        
                        -- Use max noise intensity from DistanceLimiter
                        local maxIntensity = Config.DistanceLimiter.NoiseEffect.maxNoiseIntensity or 0.75
                        local noiseIntensity = noiseProgress * maxIntensity
                        maxNoiseIntensity = math.max(maxNoiseIntensity, noiseIntensity)
                        
                        jammerDebug = jammerDebug .. " [NOISE:" .. string.format("%.2f", noiseIntensity) .. " (Approaching no-go zone at " .. string.format("%.1f", nogoThreshold) .. "m)]"
                    elseif distance < nogoThreshold then
                        -- If inside the no-go zone, apply maximum noise
                        local maxIntensity = Config.DistanceLimiter.NoiseEffect.maxNoiseIntensity or 0.75
                        maxNoiseIntensity = math.max(maxNoiseIntensity, maxIntensity)
                        jammerDebug = jammerDebug .. " [NOISE:" .. string.format("%.2f", maxIntensity) .. " MAXIMUM (in no-go zone)]"
                    end
                end
            else
                jammerDebug = jammerDebug .. " [OUT OF RANGE]"
            end
            
            table.insert(debugInfo, jammerDebug)
            
            ::continue::
        end
    end
    
    -- Update global tracking variables
    nearestJammerDistance = closestDistance
    
    -- Debug output every 5 seconds when controlling drone
    local currentTime = GetGameTimer()
    if not lastJammerDebugTime then lastJammerDebugTime = 0 end
    if controllingDrone and (currentTime - lastJammerDebugTime) > 5000 then
        local playerId = PlayerId()
        print('[Drone Player' .. playerId .. '] === JAMMER EFFECTS DEBUG ===')
        print('[Drone Player' .. playerId .. ']   Current Player Job: ' .. tostring(currentPlayerJob))
        print('[Drone Player' .. playerId .. ']   Processed: ' .. jammersProcessed .. ' jammers, In Range: ' .. jammersInRange)
        print('[Drone Player' .. playerId .. ']   Final Signal Loss: ' .. string.format("%.3f", maxSignalLoss) .. ' (0.0-1.0)')
        print('[Drone Player' .. playerId .. ']   Final Noise: ' .. string.format("%.3f", maxNoiseIntensity) .. ' (0.0-1.0)')
        print('[Drone Player' .. playerId .. ']   No-Go Zone: ' .. tostring(inAnyNogoZone))
        print('[Drone Player' .. playerId .. ']   Closest Distance: ' .. (closestDistance == math.huge and "None" or string.format("%.1f", closestDistance) .. 'm'))
        
        -- Add range status debug message
        if jammersInRange > 0 then
            print('[Drone Player' .. playerId .. ']   >>> DRONE IS IN RANGE OF ' .. jammersInRange .. ' JAMMER(S) <<<')
        else
            print('[Drone Player' .. playerId .. ']   Drone is not in range of any jammers')
        end
        
        for _, info in ipairs(debugInfo) do
            print('[Drone Player' .. playerId .. ']   ' .. info)
        end
        print('[Drone Player' .. playerId .. '] === END DEBUG ===')
        lastJammerDebugTime = currentTime
    end
    
    return maxSignalLoss, maxNoiseIntensity, inAnyNogoZone
end

-- Check if player can spawn drone at their current location (respects job ignoring)
local function canPlayerSpawnDroneHere(playerCoords)
    if not Config.JammerIntegration.enabled then
        return true -- No jammer integration, always allow
    end
    
    local allJammers = getAllJammers()
    if not allJammers or next(allJammers) == nil then
        return true -- No jammers found, always allow
    end
    
    local currentPlayerJob = getPlayerJob()
    
    -- Check each jammer for no-go zone violations
    for jammerIdOrIndex, jammer in pairs(allJammers) do
        if jammer.coords and jammer.range then
            -- Skip owner's jammers if configured
            if Config.JammerIntegration.excludeOwnerJammers and isPlayerJammerOwner(jammer) then
                goto continue
            end
            
            -- Check if player's job is in the jammer's ignored jobs list
            if jammer.ignoredJobs and type(jammer.ignoredJobs) == "table" then
                local isJobIgnored = false
                for _, ignoredJob in ipairs(jammer.ignoredJobs) do
                    if string.lower(currentPlayerJob) == string.lower(ignoredJob) then
                        isJobIgnored = true
                        break
                    end
                end
                
                if isJobIgnored then
                    if Config.Debug and Config.Debug.enabled then
                        print('[Drone Spawn] Jammer ' .. tostring(jammerIdOrIndex) .. ' (' .. (jammer.label or "Unknown") .. ') ignored for job: ' .. currentPlayerJob)
                    end
                    goto continue -- Skip this jammer for this job
                end
            end
            
            local jammerCoords = vector3(jammer.coords.x, jammer.coords.y, jammer.coords.z)
            local distance = #(playerCoords - jammerCoords)
            local jammerRange = tonumber(jammer.range) or 50.0
            
            -- Check if within jammer range
            if distance <= jammerRange then
                -- Check no-go zone
                local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2 -- Default to 20% if not specified
                local nogoThreshold
                
                if noGoZoneValue >= 1.0 then
                    -- Absolute radius in meters
                    nogoThreshold = noGoZoneValue
                else
                    -- Percentage of jammer range
                    nogoThreshold = jammerRange * noGoZoneValue
                end
                
                if Config.JammerIntegration.NogoZone.enabled and distance <= nogoThreshold then
                    if Config.Debug and Config.Debug.enabled then
                        print('[Drone Spawn] Player in no-go zone of jammer ' .. tostring(jammerIdOrIndex) .. ' (' .. (jammer.label or "Unknown") .. ') - job: ' .. currentPlayerJob .. ' - distance: ' .. string.format("%.1f", distance) .. 'm, threshold: ' .. string.format("%.1f", nogoThreshold) .. 'm')
                    end
                    return false -- Player is in a no-go zone of a jammer that doesn't ignore their job
                end
            end
            
            ::continue::
        end
    end
    
    return true -- No blocking jammers found
end

-- Initialize framework and audio
CreateThread(function()
    -- Set up framework core object
    if Config.Framework == "qb" then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    
    -- Load custom audio bank
    while not RequestScriptAudioBank('audiodirectory/custom_sounds', false) do 
        Wait(0) 
    end
end)

local function createDroneBlip()
    if Config.MapMarker.enabled and droneEntity and DoesEntityExist(droneEntity) then
        droneBlip = AddBlipForEntity(droneEntity)
        SetBlipSprite(droneBlip, Config.MapMarker.sprite)
        SetBlipColour(droneBlip, Config.MapMarker.color)
        SetBlipScale(droneBlip, Config.MapMarker.scale)
        SetBlipAsShortRange(droneBlip, false)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString("Active Drone")
        EndTextCommandSetBlipName(droneBlip)
    end
end

local function removeDroneBlip()
    if droneBlip then
        RemoveBlip(droneBlip)
        droneBlip = nil
    end
end

local function setupDroneHealth()
    if droneEntity and DoesEntityExist(droneEntity) then
        SetEntityHealth(droneEntity, Config.DroneHealth)
        SetEntityMaxHealth(droneEntity, Config.DroneHealth)
        SetEntityCanBeDamaged(droneEntity, true)
        SetEntityProofs(droneEntity, false, false, false, false, false, false, false, false)
    end
end

local function initializeFramework()
    if Config.Framework == "esx" then
        ESX = exports["es_extended"]:getSharedObject()
        if not ESX then
            -- Try alternative method
            while ESX == nil do
                TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
                Wait(100)
            end
        end
    elseif Config.Framework == "qb" then
        QBCore = exports['qb-core']:GetCoreObject()
    end
end

local function getPlayerInfo()
    local playerName, playerRank, playerJob

    if playerData.name and playerData.name ~= "" then
        playerName = playerData.name
        playerRank = playerData.grade
        playerJob = playerData.job
    else
        if Config.Framework == "esx" and ESX then
            local data = ESX.GetPlayerData()
            if data then
                playerName = data.name or GetPlayerName(PlayerId())
                playerRank = data.job.grade_label or data.job.grade_name or "Officer"
                playerJob = data.job.name or "unemployed"
            end
        elseif Config.Framework == "qb" and QBCore then
            local data = QBCore.Functions.GetPlayerData()
            if data then
                playerName = (data.charinfo.firstname .. " " .. data.charinfo.lastname) or GetPlayerName(PlayerId())
                playerRank = data.job.grade.name or "Officer"
                playerJob = data.job.name or "unemployed"
            end
        else
            playerName = GetPlayerName(PlayerId())
            playerRank = "Officer"
            playerJob = "unemployed"
        end
    end

    if playerRank then
        playerRank = playerRank:gsub("^%l", string.upper)
    end

    return {
        name = playerName,
        rank = playerRank,
        job = playerJob
    }
end

-- ================================================================
-- NOTIFICATION FUNCTION
-- ================================================================
local function ShowNotification(message)
    if Config.Framework == "esx" and ESX then
        ESX.ShowNotification(message)
    elseif Config.Framework == "qb" and QBCore then
        QBCore.Functions.Notify(message, "primary", 5000)
    else
        AddTextEntry('DRONE_NOTIFICATION', message)
        BeginTextCommandDisplayHelp('DRONE_NOTIFICATION')
        EndTextCommandDisplayHelp(5000, true, false, -1)
    end
end

CreateThread(function()
    initializeFramework()
    
    while not RequestScriptAudioBank('audiodirectory/custom_sounds', false) do 
        Wait(0) 
    end
    
    if Config.Framework == "esx" then
        while not ESX.IsPlayerLoaded() do
            Wait(100)
        end
        playerJob = getPlayerJob() -- Ensure playerJob is set after loading
    elseif Config.Framework == "qb" then
        playerJob = getPlayerJob() -- Set playerJob for QB framework
    end
end)

if Config.Framework == "esx" then
    RegisterNetEvent('esx:setJob')
    AddEventHandler('esx:setJob', function(job)
        playerJob = job.name
        if controllingDrone then
            updatePlayerData() -- Now handles both data and overlay
        end
    end)
elseif Config.Framework == "qb" then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded')
    AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
        playerJob = getPlayerJob()
    end)
    
    RegisterNetEvent('QBCore:Client:OnJobUpdate')
    AddEventHandler('QBCore:Client:OnJobUpdate', function(JobInfo)
        playerJob = JobInfo.name
        if controllingDrone then
            updatePlayerData() -- Now handles both data and overlay
        end
    end)
end

-- HUD Management Functions
local function saveOriginalHudState()
    if not Config.HUD.disableComponents then return end
    
    originalHudState = {
        radar = IsRadarEnabled(),
        hudComponents = {}
    }
    
    -- Save state of HUD components we plan to hide
    for _, component in ipairs(Config.HUD.hiddenComponents) do
        originalHudState.hudComponents[component] = IsHudComponentActive(component)
    end
end

local function hideHudComponents()
    if not Config.HUD.disableComponents then return end
    
    -- Hide specified HUD components
    for _, component in ipairs(Config.HUD.hiddenComponents) do
        HideHudComponentThisFrame(component)
    end
    
    -- Hide radar/minimap
    if Config.HUD.hideRadar then
        DisplayRadar(false)
    end
    
    -- Hide health and armor
    if Config.HUD.hideHealthArmor then
        HideHudComponentThisFrame(3)  -- SP_STAT_HEALTH
        HideHudComponentThisFrame(4)  -- SP_STAT_ARMOUR
    end
    
    -- Hide weapon wheel
    if Config.HUD.hideWeaponWheel then
        HideHudComponentThisFrame(19) -- WEAPON_WHEEL
        HideHudComponentThisFrame(20) -- WEAPON_WHEEL_STATS
    end
end

local function restoreOriginalHudState()
    if not Config.HUD.disableComponents or not originalHudState then return end
    
    -- Restore radar
    if originalHudState.radar then
        DisplayRadar(true)
    end
    
    -- Note: Individual HUD components will restore automatically when we stop hiding them
end

local function stopDroneSound()
    if currentSoundId ~= -1 then
        StopSound(currentSoundId)
        ReleaseSoundId(currentSoundId)
        currentSoundId = -1
        lastSoundType = ""
    end
end

local function playDroneSound(soundName, coords, isOwnDrone)
    stopDroneSound()
    
    currentSoundId = GetSoundId()
    if isOwnDrone then
        PlaySoundFrontend(currentSoundId, soundName, Config.Sound.Set, true)
    else
        PlaySoundFromCoord(currentSoundId, soundName, coords.x, coords.y, coords.z, Config.Sound.Set, false, Config.Sound.RenderDistance, false)
    end
    lastSoundType = soundName
end

local function getDroneState(droneCoords, velocity, isBoostPressed)
    -- Simplified state: only hovering or maneuvering based on boost
    if isBoostPressed then 
        return "maneuvering"
    else
        return "hovering"
    end
end

local function isEntityUnderwater(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    
    local coords = GetEntityCoords(entity)
    local waterLevel = GetWaterHeight(coords.x, coords.y, coords.z)
    
    -- If there's water and the entity is below water level
    if waterLevel and coords.z < waterLevel then
        return true
    end
    return false
end

local function updateDroneSounds()
    local playerCoords = GetEntityCoords(PlayerPedId())
    
    for playerId, droneData in pairs(allDrones) do
        if droneData.active and droneData.entity and DoesEntityExist(droneData.entity) then
            local droneCoords = GetEntityCoords(droneData.entity)
            local distance = #(playerCoords - droneCoords)
            local isOwnDrone = (droneData.entity == droneEntity)
            

            if isOwnDrone or distance <= Config.Sound.RenderDistance then
                local velocity = GetEntityVelocity(droneData.entity)
                local isBoostPressed = false
                if isOwnDrone then
                    isBoostPressed = IsControlPressed(0, Config.Keys.Boost)
                end
                
                local state = getDroneState(droneCoords, velocity, isBoostPressed)
                
                if state == "hovering" then
                    TriggerServerEvent("drone:updateSound", droneData.netId, Config.Sound.Hover, droneCoords, isOwnDrone)
                elseif state == "maneuvering" then
                    TriggerServerEvent("drone:updateSound", droneData.netId, Config.Sound.Manouver, droneCoords, isOwnDrone)
                end
            end
        end
    end
end

-- NEW: Jammer noise sound management
local jammerNoiseActive = false
local jammerNoiseSoundId = -1

local function playJammerNoiseSound()
    if not Config.JammerIntegration.NoiseSound.enabled or jammerNoiseActive then
        return
    end
    
    jammerNoiseActive = true
    jammerNoiseSoundId = GetSoundId()
    PlaySoundFrontend(jammerNoiseSoundId, "Barrage_Finished", "CARMOD_3_RAM_ENGINE_CHANGE_MASTER", true)
end

local function stopJammerNoiseSound()
    if jammerNoiseActive and jammerNoiseSoundId ~= -1 then
        StopSound(jammerNoiseSoundId)
        ReleaseSoundId(jammerNoiseSoundId)
        jammerNoiseSoundId = -1
        jammerNoiseActive = false
    end
end

-- Update jammer noise based on current effects
local function updateJammerNoise()
    if not Config.JammerIntegration.enabled or not Config.DistanceLimiter.NoiseSound.enabled then
        return
    end
    
    if nearestJammerDistance == math.huge then
        stopJammerNoiseSound()
        return
    end
    
    -- Check if we should play jammer noise (reuse DistanceLimiter noise settings)
    local allJammers = getAllJammers()
    local shouldPlayNoise = false
    
    for id, jammer in pairs(allJammers) do
        if jammer.coords and jammer.jammerRange and not isPlayerJammerOwner(jammer) then
            local jammerCoords = vector3(jammer.coords.x, jammer.coords.y, jammer.coords.z)
            local distance = #(GetEntityCoords(droneEntity) - jammerCoords)
            
            -- Use the same percentage as the noise effect for consistency
            local soundStartPercentage = Config.DistanceLimiter.NoiseEffect.noiseStartPercentage
            local soundStartDistance = jammer.jammerRange * soundStartPercentage
            
            if distance <= soundStartDistance then
                shouldPlayNoise = true
                break
            end
        end
    end
    
    if shouldPlayNoise and not jammerNoiseActive then
        playJammerNoiseSound()
    elseif not shouldPlayNoise and jammerNoiseActive then
        stopJammerNoiseSound()
    end
end

RegisterNetEvent("drone:playSound")
AddEventHandler("drone:playSound", function(netId, soundName, coords, isOwnDrone)
    local playerCoords = GetEntityCoords(PlayerPedId())
    local distance = #(playerCoords - coords)
    if isOwnDrone or distance <= Config.Sound.RenderDistance then
        if isOwnDrone and not controllingDrone then
            stopDroneSound()
            return
        end
        playDroneSound(soundName, coords, isOwnDrone or false)
    end
end)

RegisterNetEvent("drone:stopSound")
AddEventHandler("drone:stopSound", function(netId)
    stopDroneSound()
end)

local function createProp()
    if not Config.Prop.enabled then return end
    
    local ped = PlayerPedId()
    local pedPos = GetEntityCoords(ped)
    local pedHeading = GetEntityHeading(ped)
    
    -- Request the prop model
    RequestModel(Config.Prop.model)
    local attempts = 0
    while not HasModelLoaded(Config.Prop.model) and attempts < 50 do
        Wait(50)
        attempts = attempts + 1
    end
    
    if HasModelLoaded(Config.Prop.model) then
        local forwardVector = GetEntityForwardVector(ped)
        local laptopPos = vector3(
            pedPos.x + (forwardVector.x * Config.Prop.groundOffset.y),
            pedPos.y + (forwardVector.y * Config.Prop.groundOffset.x),
            pedPos.z + Config.Prop.groundOffset.z
        )
        propObject = CreateObject(Config.Prop.model, laptopPos.x, laptopPos.y, laptopPos.z, true, true, true)
        SetEntityRotation(propObject, Config.Prop.rotation.x, Config.Prop.rotation.y, pedHeading + Config.Prop.rotation.z, 2, true)
        FreezeEntityPosition(propObject, true) 
        SetModelAsNoLongerNeeded(Config.Prop.model)
    end
end

local function deleteProp()
    if propObject and DoesEntityExist(propObject) then
        DeleteEntity(propObject)
        propObject = nil
    end
end

function PlayAnimation()
    TriggerServerEvent("drone:playAnimation")
end

RegisterNetEvent("drone:receiveAnimation")
AddEventHandler("drone:receiveAnimation", function()
    local dict = Config.Animation.dict
    local anim = Config.Animation.name
    local ped = PlayerPedId()
    RequestAnimDict(dict)
    local timeout = 0
    while not HasAnimDictLoaded(dict) and timeout < 5000 do
        Wait(10)
        timeout = timeout + 10
    end

    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 1, 0, false, false, false)
        isAnimationPlaying = true
    
        CreateThread(function()
            Wait(1)
            createProp()
        end)
    end
end)

local function stopAnimation()
    local ped = PlayerPedId()
    ClearPedTasks(ped)
    isAnimationPlaying = false
    deleteProp()
end

function LoadHeliCamScaleform()
    if not heliCamScaleform then
        heliCamScaleform = RequestScaleformMovie("HELI_CAM")
        while not HasScaleformMovieLoaded(heliCamScaleform) do
            Wait(0)
        end
    end
end

-- Function to hide the overlay
local function hideOverlay()
    SendNUIMessage({
        action = "hideOverlay" -- This tells NUI to hide all its managed overlays
    })
end

-- Update player data and send to NUI (now includes overlay loading)
local function updatePlayerData()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone] updatePlayerData called - setting up overlay')
        print('[Drone] controllingDrone:', controllingDrone)
    end
    
    local pInfo = getPlayerInfo() -- Use the consistent function to get player details
    local currentJob = getPlayerJob() 
    local jobConfig = Config.Jobs[currentJob] or Config.Jobs.default

    -- Determine rank and job display based on employment status and hideRank flag
    local displayRank = pInfo.rank
    local displayJob = pInfo.job
    
    -- Check if we should hide the rank based on the hideRank flag
    if jobConfig and jobConfig.hideRank then
        displayRank = ""
    end
    
    if currentJob == "unemployed" or currentJob == "" then
        displayJob = (jobConfig and jobConfig.displayName) or "Drone cam"
    else
        displayJob = (jobConfig and jobConfig.displayName) or pInfo.job
    end

    -- Send player data update
    SendNUIMessage({
        action = "updatePlayerData",
        data = {
            name = pInfo.name,
            rank = displayRank,
            job = displayJob
        }
    })

    -- Load overlay based on job configuration
    if jobConfig  then
        local nuiData = {
            action = "showOverlay",
            overlayType = "bodycam"
        }
        if jobConfig.logoUrl and jobConfig.logoUrl ~= "" then
            -- If the path is not already an absolute URL or nui:// reference, treat it as local
            if not string.find(jobConfig.logoUrl, "^https?://") and not string.find(jobConfig.logoUrl, "^nui://") then
                local resourceName = GetCurrentResourceName()
                -- Ensure there's no leading slash in the logoUrl
                local sanitizedPath = jobConfig.logoUrl:gsub("^/", "")
                nuiData.logoUrl = ("https://cfx-nui-%s/nui/%s"):format(resourceName, sanitizedPath)
            else
                nuiData.logoUrl = jobConfig.logoUrl
            end
        end
        
        if Config.Debug and Config.Debug.enabled then
            print('[Drone] Sending showOverlay to NUI:', json.encode(nuiData))
        end
        
        SendNUIMessage(nuiData)
    else
        SendNUIMessage({ action = "hideOverlay" }) -- Hide if no valid config
    end
end


-- Update the overlay dynamically when the player's job changes
RegisterNetEvent("drone:updateJob")
AddEventHandler("drone:updateJob", function(newJobData) -- Assuming newJobData could be a table like from esx:setJob
    local jobName
    if type(newJobData) == "table" and newJobData.name then
        jobName = newJobData.name
    elseif type(newJobData) == "string" then
        jobName = newJobData -- For QB or direct string updates
    else
        jobName = getPlayerJob() -- Fallback
    end

    playerJob = jobName -- Update the global playerJob variable

    if controllingDrone then
        updatePlayerData() -- Now handles both data update and overlay loading
    end
end)

RegisterNetEvent("drone:setPlayerData")
AddEventHandler("drone:setPlayerData", function(data)
    if data then
        playerData.name = data.name
        playerData.job = data.job
        playerData.grade = data.rank -- Match the key from the server event

        if playerData.grade == "Unemployed" then
            playerData.grade = ""
        end
        
        if controllingDrone then
            updatePlayerData() -- Now handles both data update and overlay loading
        end
    end
end)

-- Note: updatePlayerData function is defined above at line 755

function DrawDroneOverlay()
    if droneEntity and DoesEntityExist(droneEntity) then -- Removed heliCamScaleform check for now, assuming it's loaded if drone active
        if not heliCamScaleform or not HasScaleformMovieLoaded(heliCamScaleform) then
            LoadHeliCamScaleform() -- Ensure it's loaded
        end
        
        if heliCamScaleform and HasScaleformMovieLoaded(heliCamScaleform) then
            local coords = GetEntityCoords(droneEntity)
            local heading = GetEntityHeading(droneEntity)
            local zoomPercent = (Config.MaxFOV - currentFOV) / (Config.MaxFOV - Config.MinFOV)

            PushScaleformMovieFunction(heliCamScaleform, "SET_CAM_LOGO")
            PushScaleformMovieFunctionParameterInt(0) 
            PopScaleformMovieFunctionVoid()

            PushScaleformMovieFunction(heliCamScaleform, "SET_ALT_FOV_HEADING")
            PushScaleformMovieFunctionParameterFloat(coords.z)
            PushScaleformMovieFunctionParameterFloat(zoomPercent)
            PushScaleformMovieFunctionParameterFloat(heading)
            PopScaleformMovieFunctionVoid()

            DrawScaleformMovie(heliCamScaleform, 0.5, 0.5, 1.0, 1.0, 255, 255, 255, 255, 0)
        end

        local hudData = {
            action = "updateHUD",
            showBattery = Config.RuntimeLimiter.enabled,
            showSignal = Config.DistanceLimiter.enabled,
            signal = calculatedSignalQuality,
            showNoise = calculatedNoiseIntensity > 0.01,
            noiseLevel = calculatedNoiseIntensity
        }

        if hudData.showBattery then
            hudData.battery = math.floor(currentBatteryPercentage * 100)
        end

        -- Debug NUI data being sent
        if Config.Debug and Config.Debug.enabled and controllingDrone then
            local currentTime = GetGameTimer()
            if not lastNUIDebugTime then lastNUIDebugTime = 0 end
            if (currentTime - lastNUIDebugTime) > 3000 then -- Every 3 seconds
                print('[Drone NUI] Sending HUD Data:')
                print('  showBattery: ' .. tostring(hudData.showBattery))
                print('  showSignal: ' .. tostring(hudData.showSignal))
                print('  signal: ' .. string.format("%.2f", hudData.signal or 0))
                print('  showNoise: ' .. tostring(hudData.showNoise))
                print('  noiseLevel: ' .. string.format("%.3f", hudData.noiseLevel or 0))
                if hudData.battery then
                    print('  battery: ' .. hudData.battery .. '%')
                end
                lastNUIDebugTime = currentTime
            end
        end

        SendNUIMessage(hudData)
    end
end

local function controlDrone()
    local ped = PlayerPedId()
    controllingDrone = true
    droneCoordsStart = GetEntityCoords(ped) 
    soundTimer = GetGameTimer()

    TriggerServerEvent("drone:sendPlayerData") -- Request data from server

    saveOriginalHudState()
    -- Ensure overlay shows immediately, even if server event fails
    if Config.Debug and Config.Debug.enabled then
        print('[Drone] About to call updatePlayerData() to trigger bodycam overlay...')
    end
    updatePlayerData()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone] updatePlayerData() called successfully')
    end

    SetEntityVisible(ped, true, true)
    FreezeEntityPosition(ped, false)
    
    for i = 0, 337 do
        EnableControlAction(0, i, true)
    end
    
    createDroneBlip()
    setupDroneHealth()
    
    if droneEntity and DoesEntityExist(droneEntity) then
        SetEntityHasGravity(droneEntity, false)
    end

    LoadHeliCamScaleform() -- Ensure scaleform is loaded before camera creation

    droneCamera = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamActive(droneCamera, true)
    RenderScriptCams(true, false, 0, true, false)
    SetCamFov(droneCamera, currentFOV)

    resetBatteryState()

    if Config.DistanceLimiter.enabled then
        currentDistanceToStart = 0.0
    end

    local camRot = vector3(0.0, 0.0, GetEntityHeading(droneEntity))
    local animDict = Config.Animation.dict
    local animName = Config.Animation.name
    
    RequestAnimDict(animDict)
    while not HasAnimDictLoaded(animDict) do Wait(10) end

    while controllingDrone and DoesEntityExist(droneEntity) do
        Wait(0)

        for i = 0, 337 do
            EnableControlAction(0, i, true)
        end

        hideHudComponents()

        local currentDroneCoords = GetEntityCoords(droneEntity)
        local playerCoords = GetEntityCoords(ped) -- Not used, but kept for context
        local distFromPlayerToDroneStart = #(GetEntityCoords(ped) - droneCoordsStart) -- Renamed for clarity

        if isNoiseTestActive then
            currentDistanceToStart = Config.DistanceLimiter.maxDistance * 0.99
        else
            currentDistanceToStart = #(currentDroneCoords - droneCoordsStart)
        end

        if distFromPlayerToDroneStart > 1.0 then -- Freeze player if they move away from drone start
            FreezeEntityPosition(ped, true)
        end

        if isAnimationPlaying and not IsEntityPlayingAnim(ped, animDict, animName, 3) then
            TaskPlayAnim(ped, animDict, animName, 8.0, -8.0, -1, 1, 0, false, false, false)
        end

        if Config.Prop.enabled and propObject and DoesEntityExist(propObject) then
            FreezeEntityPosition(propObject, true)
        end

        DrawDroneOverlay() -- This now sends HUD data to NUI
        
        local destructionReason = nil
        if isEntityUnderwater(droneEntity) then
            destructionReason = "underwater"
        elseif GetEntityHealth(droneEntity) <= 0 or IsEntityDead(droneEntity) then
            destructionReason = "health"
        end

        if Config.RuntimeLimiter.enabled and not destructionReason then
            local elapsedTime = (GetGameTimer() - batteryStartTime) / 1000 
            currentBatteryPercentage = math.max(0, 1 - (elapsedTime / Config.RuntimeLimiter.batteryDuration))

            isLowBattery = currentBatteryPercentage <= Config.RuntimeLimiter.lowBatteryWarningThreshold
            isCriticalBattery = currentBatteryPercentage <= (Config.RuntimeLimiter.lowBatteryWarningThreshold / 2) 

            if currentBatteryPercentage <= 0 then
                destructionReason = "battery_empty"
            end
        end

        if Config.DistanceLimiter.enabled and not destructionReason then
            local effectTriggerDistance = Config.DistanceLimiter.maxDistance * Config.DistanceLimiter.effectStartPercentage

            if currentDistanceToStart > Config.DistanceLimiter.maxDistance then
                destructionReason = "out_of_range"
            else
                -- Calculate signal bars (independent, linear degradation)
                calculatedSignalQuality = 100.0 -- Default full signal (0-100%)
                local signalTriggerDistance = Config.DistanceLimiter.maxDistance * Config.DistanceLimiter.effectStartPercentage
                
                if currentDistanceToStart > signalTriggerDistance then
                    local signalProgress = (currentDistanceToStart - signalTriggerDistance) / (Config.DistanceLimiter.maxDistance - signalTriggerDistance)
                    signalProgress = math.max(0, math.min(1, signalProgress))
                    calculatedSignalQuality = math.max(0, 100 * (1 - signalProgress)) -- Linear 0-100%
                end

                -- Calculate noise overlay (independent, exponential degradation)
                calculatedNoiseIntensity = 0.0 -- Default no noise (0.0-1.0)
                if Config.DistanceLimiter.NoiseEffect.enabled then
                    local noiseStartPercentage = Config.DistanceLimiter.NoiseEffect.noiseStartPercentage or Config.DistanceLimiter.effectStartPercentage
                    local noiseTriggerDistance = Config.DistanceLimiter.maxDistance * noiseStartPercentage
                    
                    if currentDistanceToStart > noiseTriggerDistance then
                        local noiseProgress = (currentDistanceToStart - noiseTriggerDistance) / (Config.DistanceLimiter.maxDistance - noiseTriggerDistance)
                        noiseProgress = math.max(0, math.min(1, noiseProgress))
                        local degradationExponent = Config.DistanceLimiter.NoiseEffect.degradationExponent or 15.0
                        local exponentialProgress = noiseProgress ^ degradationExponent
                        calculatedNoiseIntensity = exponentialProgress * Config.DistanceLimiter.NoiseEffect.maxNoiseIntensity
                    end
                end
            end
        end

        -- Apply jammer effects (calculate before checking destruction)
        jammerSignalLoss, jammerNoiseIntensity, inNogoZone = calculateJammerEffects(currentDroneCoords)

        -- Handle entering a no-go zone
        if inNogoZone and not inNoGoZoneLastFrame then
            if Config.JammerIntegration.NogoZone.enabled and Config.JammerIntegration.NogoZone.notification then
                ShowNotification(Config.JammerIntegration.NogoZone.notification)
            end
        end
        inNoGoZoneLastFrame = inNogoZone -- Update for next frame

        -- Check for no-go zone violation first (highest priority)
        if inNogoZone then
            destructionReason = "out_of_range" -- Use connection lost overlay instead of no-go zone
        else
            -- Apply jammer effects to signal and noise
            if jammerSignalLoss > 0 then
                -- Convert signal loss (0.0-1.0) to percentage reduction
                local signalReduction = jammerSignalLoss * 100
                local originalSignalQuality = calculatedSignalQuality
                calculatedSignalQuality = math.max(0, calculatedSignalQuality - signalReduction)
                
                if shouldDebugSignal then
                    print('  Signal Reduction Applied: ' .. string.format("%.2f", signalReduction) .. '%')
                    print('  Signal Quality: ' .. string.format("%.2f", originalSignalQuality) .. '% -> ' .. string.format("%.2f", calculatedSignalQuality) .. '%')
                end
            end
            
            if jammerNoiseIntensity > 0 then
                -- Use the stronger noise source (jammer noise takes priority as it's the main interference)
                local originalNoiseIntensity = calculatedNoiseIntensity
                calculatedNoiseIntensity = math.max(calculatedNoiseIntensity, jammerNoiseIntensity)
                
                if shouldDebugSignal then
                    print('  Noise Intensity: ' .. string.format("%.3f", originalNoiseIntensity) .. ' -> ' .. string.format("%.3f", calculatedNoiseIntensity))
                    print('  Jammer Noise Priority: ' .. string.format("%.3f", jammerNoiseIntensity))
                end
            end
            
            if shouldDebugSignal then
                print('  Final Signal Quality: ' .. string.format("%.2f", calculatedSignalQuality) .. '%')
                print('  Final Noise Intensity: ' .. string.format("%.3f", calculatedNoiseIntensity))
                print('[Drone Signal] === END DEBUG ===')
            end
        end

        if destructionReason then
            keepOverlayVisible = true -- Keep overlay visible for destruction
            controllingDrone = false 
            
            -- Handle destruction and cleanup immediately
            stopDroneSound()
            destroyDrone(droneEntity)
            droneEntity = nil 
            
            -- Show overlay in a separate thread after cleanup is complete
            CreateThread(function()
                if destructionReason == "battery_empty" then
                    SendNUIMessage({ 
                        action = "showBatteryEmpty",
                        duration = Config.Overlays and Config.Overlays.batteryEmptyDuration or 5000
                    })
                    Wait(3000) -- Show the empty battery screen for 3 seconds
                elseif destructionReason == "out_of_range" then
                    SendNUIMessage({ 
                        action = "showConnectionLost",
                        duration = Config.Overlays and Config.Overlays.connectionLostDuration or 5000
                    })
                    Wait(3000) -- Show the connection lost screen for 3 seconds
                end
            end)
            
            break 
        end

        if GetGameTimer() - soundTimer > Config.Sound.Update then
            local velocity = GetEntityVelocity(droneEntity)
            local isBoostPressed = IsControlPressed(0, Config.Keys.Boost)
            
            TriggerServerEvent("drone:updateSound", NetworkGetNetworkIdFromEntity(droneEntity), Config.Sound.Hover, currentDroneCoords, true, isBoostPressed)

            soundTimer = GetGameTimer()
        end
        
        -- Update jammer noise effects
        updateJammerNoise()
        
        DisableControlAction(0, 24, true)  
        DisableControlAction(0, 25, true)  
        DisableControlAction(0, 37, true)  
        DisableControlAction(0, 142, true) 
        DisableControlAction(0, 106, true) 
        DisableControlAction(0, 30, true)  
        DisableControlAction(0, 31, true)  
        DisableControlAction(0, 26, true)  -- C key (look behind)  

        local lookX = -GetDisabledControlNormal(0, 1) * Config.MouseSensitivity
        local lookY = GetDisabledControlNormal(0, 2) * Config.MouseSensitivity
        local zoomFactor = (currentFOV - Config.MinFOV) / (Config.MaxFOV - Config.MinFOV)
        local adjustedRotSpeed = Config.RotationZoomScaling and Config.RotationSpeed * (zoomFactor ^ 1.05) or Config.RotationSpeed

        camRot = vector3(
            math.max(-80.0, math.min(80.0, camRot.x - lookY * adjustedRotSpeed * 0.016)),
            0.0, 
            camRot.z + lookX * adjustedRotSpeed * 0.016
        )

        if IsControlPressed(0, Config.Keys.RotateLeft) then
            camRot = vector3(camRot.x, 0.0, camRot.z + adjustedRotSpeed * 0.016) 
        end
        if IsControlPressed(0, Config.Keys.RotateRight) then
            camRot = vector3(camRot.x, 0.0, camRot.z - adjustedRotSpeed * 0.016) 
        end

        local moveF, moveV, moveS = 0.0, 0.0, 0.0
        if IsControlPressed(0, Config.Keys.Forward) then moveF = 1.0 end
        if IsControlPressed(0, Config.Keys.Backward) then moveF = -1.0 end
        if IsControlPressed(0, Config.Keys.Ascend) then moveV = 1.0 end
        if IsControlPressed(0, Config.Keys.Descend) then moveV = -1.0 end
        if IsControlPressed(0, Config.Keys.StrafeLeft) then moveS = 1.0 end
        if IsControlPressed(0, Config.Keys.StrafeRight) then moveS = -1.0 end

        local speedMultiplier = IsControlPressed(0, Config.Keys.Boost) and Config.SpeedBoostMultiplier or 1.0
        local heading = math.rad(camRot.z)
        local vx = (math.cos(heading) * moveF - math.sin(heading) * moveS) * Config.DroneSpeed * speedMultiplier
        local vy = (math.sin(heading) * moveF + math.cos(heading) * moveS) * Config.DroneSpeed * speedMultiplier
        SetEntityVelocity(droneEntity, vx, vy, moveV * Config.DroneSpeed * speedMultiplier)
        SetEntityHeading(droneEntity, (camRot.z + 90.0 + 360) % 360)
        
        -- Sync minimap to follow drone position with optional rotation tracking
        if not Config.HUD.hideRadar and Config.MapMarker.enabled and droneBlip then
            local droneCoords = GetEntityCoords(droneEntity)
            local droneHeading = GetEntityHeading(droneEntity)
            
            -- Continuously update position to follow the drone
            LockMinimapPosition(droneCoords.x, droneCoords.y)
            
            -- Check if we should track rotation or lock to north
            if Config.MapMarker.trackRotation then
                -- Rotate minimap to match drone heading
                SetGameplayCamRelativeHeading(droneHeading)
            else
                -- Lock minimap to face north (0 degrees)
                SetGameplayCamRelativeHeading(0.0)
            end
        end

        local offset = GetOffsetFromEntityInWorldCoords(droneEntity, Config.CameraOffset.x, Config.CameraOffset.y, Config.CameraOffset.z)
        SetCamCoord(droneCamera, offset.x, offset.y, offset.z)

        local pitch = math.rad(camRot.x)
        local yaw = math.rad(camRot.z)
        local dir = vector3(math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch))
        PointCamAtCoord(droneCamera, offset.x + dir.x * 10.0, offset.y + dir.y * 10.0, offset.z + dir.z * 10.0)
        SetCamRot(droneCamera, camRot.x, 0.0, camRot.z) 

        if IsControlJustPressed(0, 15) then currentFOV = math.max(Config.MinFOV, currentFOV - Config.ZoomSpeed) end
        if IsControlJustPressed(0, 14) then currentFOV = math.min(Config.MaxFOV, currentFOV + Config.ZoomSpeed) end
        SetCamFov(droneCamera, currentFOV)

        if IsControlJustPressed(0, Config.Keys.VisionToggle) then
            local playerJob = getPlayerJob()
            local jobConfig = Config.Jobs[playerJob] or Config.Jobs.default

            if jobConfig and jobConfig.canUseVision then
                if visionMode == 0 then
                    SetNightvision(true)
                    SetSeethrough(false)
                    visionMode = 1
                elseif visionMode == 1 then
                    SetNightvision(false)
                    SetSeethrough(true)
                    visionMode = 2
                else
                    SetNightvision(false)
                    SetSeethrough(false)
                    visionMode = 0
                end
            end
        end

        if IsControlJustPressed(0, Config.Keys.Exit) then
            TriggerServerEvent('drone:server:giveItemBack') -- Give the drone item back
            destroyDrone(droneEntity)
            droneEntity = nil 
            controllingDrone = false
            break 
        end
    end 

    stopDroneSound()
    stopJammerNoiseSound() -- Stop jammer noise when exiting drone control
    
    SendNUIMessage({ action = "updateHUD", showBattery = false, showSignal = false })
    if not keepOverlayVisible then
        hideOverlay() -- Only hide overlay if it shouldn't stay visible
    end
    keepOverlayVisible = false -- Reset for next time
    SetNuiFocus(false, false)

    RenderScriptCams(false, false, 0, true, false)
    if droneCamera then 
        SetCamFov(droneCamera, Config.MaxFOV) 
        DestroyCam(droneCamera); 
        droneCamera = nil 
    end
    removeDroneBlip()
    local currentPed = PlayerPedId()
    FreezeEntityPosition(currentPed, false)
    SetEntityVisible(currentPed, true, true)
    SetGameplayCamRelativeHeading(0.0)
    SetNightvision(false)
    SetSeethrough(false)
    visionMode = 0
    restoreOriginalHudState()
    UnlockMinimapPosition() -- Reset minimap to follow player
    SetGameplayCamRelativeHeading(0.0) -- Reset minimap rotation to default
    minimapLocked = false
    DisplayRadar(true)
    DisplayHud(true)
    for i = 0, 337 do EnableControlAction(0, i, true) end
    stopAnimation()

    isLowBattery = false
    isCriticalBattery = false

    if soundTimer then soundTimer = 0 end
    controllingDrone = false
    currentFOV = Config.MaxFOV
    resetBatteryState() -- Final reset on exit
end

function destroyDrone(entity)
    if entity and DoesEntityExist(entity) then
        local destroyedCoords = GetEntityCoords(entity)
        local netId = NetworkGetNetworkIdFromEntity(entity)
        TriggerServerEvent("drone:initiateDestruction", netId, destroyedCoords)

        DeleteEntity(entity)
    end
    
    -- Stop any jammer noise when drone is destroyed
    stopJammerNoiseSound()
end

local function spawnDroneAndControl()
    local ped = PlayerPedId()
    
    if IsPedInAnyVehicle(ped) then 
        return false
    end

    if controllingDrone then
        return false
    end

    -- Check if player can spawn drone at their current location (respects job exceptions)
    local playerCoords = GetEntityCoords(ped)
    local canSpawn = canPlayerSpawnDroneHere(playerCoords)
    
    if not canSpawn then
        if Config.Debug and Config.Debug.enabled then
            print('[Drone Player' .. PlayerId() .. '] Cannot spawn drone - player is in a no-go zone (job not ignored)')
        end
        
        -- Show notification to player
        if Config.JammerIntegration.NogoZone.notification then
            ShowNotification(Config.JammerIntegration.NogoZone.notification)
        else
            ShowNotification("Cannot deploy drone - signal interference too strong!")
        end
        
        return false
    end

    -- Show startup screen if enabled
    local droneStarted = false
    if Config.StartupScreen.enabled then
        local logoUrl = Config.StartupScreen.logoUrl
        if logoUrl and logoUrl ~= "" then
            -- Convert local logo URL if needed
            if not string.find(logoUrl, "^https?://") and not string.find(logoUrl, "^nui://") then
                local resourceName = GetCurrentResourceName()
                local sanitizedPath = logoUrl:gsub("^/", "")
                logoUrl = ("https://cfx-nui-%s/nui/%s"):format(resourceName, sanitizedPath)
            end
        end
        
        SendNUIMessage({
            action = "showStartupScreen",
            logoUrl = logoUrl,
            duration = Config.StartupScreen.duration or 3000,
            droneStartPercent = Config.StartupScreen.droneStartPercent or 80
        })
        
        -- Play startup sound if enabled
        if Config.StartupScreen.playSound and Config.StartupScreen.soundName then
            PlaySoundFrontend(-1, Config.StartupScreen.soundName, Config.StartupScreen.soundSet or "special_soundset", true)
        end
        
        -- Disable player controls during startup screen
        local startupDuration = Config.StartupScreen.duration or 3000
        local startTime = GetGameTimer()
        
        -- Create a thread to disable controls during startup
        CreateThread(function()
            while (GetGameTimer() - startTime) < startupDuration do
                Wait(0)
                -- Disable all player controls during startup
                DisableAllControlActions(0)
                DisableAllControlActions(1)
                DisableAllControlActions(2)
            end
        end)
        
        -- Calculate when to start drone (before full duration)
        local droneStartTime = (Config.StartupScreen.duration or 3000) * ((Config.StartupScreen.droneStartPercent or 80) / 100)
        
        -- Wait for drone start time, then spawn drone in background
        Wait(droneStartTime)
        
        -- Start requesting the drone model during startup screen
        RequestModel(Config.DroneModel)
        droneStarted = true
        
        -- Continue waiting for full startup duration
        local remainingTime = (Config.StartupScreen.duration or 3000) - droneStartTime
        if remainingTime > 0 then
            Wait(remainingTime)
        end
    end

    resetBatteryState() -- Reset battery state before spawning a new drone

    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    
    -- Request model if not already started during startup screen
    if not droneStarted then
        RequestModel(Config.DroneModel)
    end
    
    -- Wait for model to load
    while not HasModelLoaded(Config.DroneModel) do 
        Wait(50)
    end
    
    if not HasModelLoaded(Config.DroneModel) then
        return false
    end

    droneEntity = CreateObject(Config.DroneModel, pos.x, pos.y, pos.z + 1.0, true, true, true)
    
    if not droneEntity or not DoesEntityExist(droneEntity) then
        SetModelAsNoLongerNeeded(Config.DroneModel)
        return false
    end
    
    -- Ensure the drone stays loaded at long distances
    SetEntityDynamic(droneEntity, true)
    SetEntityInvincible(droneEntity, false)
    SetEntityLoadCollisionFlag(droneEntity, true)
    SetEntityAlwaysPrerender(droneEntity, true)
    
    SetEntityRotation(droneEntity, 0.0, 0.0, heading + 90.0, 2, true)
    SetModelAsNoLongerNeeded(Config.DroneModel)

    TriggerServerEvent("drone:spawn", NetworkGetNetworkIdFromEntity(droneEntity))
    
    PlayAnimation()

    CreateThread(function()
        Wait(250)
        controlDrone()
    end)
    
    return true
end


RegisterNetEvent("drone:useItem", function()
    -- The spawnDroneAndControl function already contains the correct logic 
    -- to check for no-go zones while respecting ignored jobs. 
    -- The previous check here was redundant and incorrect.
    spawnDroneAndControl()
end)

RegisterNetEvent("drone:syncAll", function(drones)
    allDrones = drones
    -- Update entity references for existing drones
    for playerId, droneData in pairs(allDrones) do
        if droneData.netId and droneData.active then
            droneData.entity = NetToEnt(droneData.netId)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then
        return
    end
    
    stopDroneSound()
    SendNUIMessage({ action = "updateHUD", showBattery = false, showSignal = false })
    hideOverlay()
    SetNuiFocus(false, false)
    
    if controllingDrone then 
        RenderScriptCams(false, false, 0, true, false)
        if droneCamera then DestroyCam(droneCamera); droneCamera = nil end
        removeDroneBlip()
        SetNightvision(false)
        SetSeethrough(false)
        
        if droneEntity and DoesEntityExist(droneEntity) then
            SetEntityHasGravity(droneEntity, true)
            DeleteEntity(droneEntity)
            droneEntity = nil
        end

        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        SetEntityVisible(ped, true, true)
        stopAnimation()
        deleteProp()
        restoreOriginalHudState() 
        UnlockMinimapPosition() -- Reset minimap to follow player
        SetGameplayCamRelativeHeading(0.0) -- Reset minimap rotation to default
        minimapLocked = false
        DisplayRadar(true)
        DisplayHud(true)
    end
    controllingDrone = false
end)

-- ================================================================
-- JAMMER DATA VERIFICATION AND DEBUGGING
-- ================================================================

-- Verify jammer data integrity
local function verifyJammerData(jammers)
    if not jammers then
        print('[Drone] ERROR: Received nil jammer data')
        return false, "Nil data"
    end
    
    if type(jammers) ~= 'table' then
        print('[Drone] ERROR: Received invalid jammer data type: ' .. type(jammers))
        return false, "Invalid type"
    end
    
    local validJammers = 0
    local invalidJammers = 0
    
    for id, jammer in pairs(jammers) do
        if type(jammer) == 'table' and jammer.coords and jammer.range then
            -- Enhanced validation
            local coordsValid = (type(jammer.coords) == "table" and 
                                jammer.coords.x and jammer.coords.y and jammer.coords.z and
                                type(jammer.coords.x) == "number" and 
                                type(jammer.coords.y) == "number" and 
                                type(jammer.coords.z) == "number")
            
            local rangeValid = (type(jammer.range) == "number" and jammer.range > 0)
            
            if coordsValid and rangeValid then
                validJammers = validJammers + 1
                print('[Drone] VALID Jammer ' .. tostring(id) .. 
                      ' - coords: (' .. jammer.coords.x .. ', ' .. jammer.coords.y .. ', ' .. jammer.coords.z .. ')' ..
                      ' - range: ' .. jammer.range .. 
                      ' - owner: ' .. tostring(jammer.owner) ..
                      ' - permanent: ' .. tostring(jammer.permanent))
            else
                invalidJammers = invalidJammers + 1
                print('[Drone] INVALID Jammer ' .. tostring(id) .. ' - coordsValid: ' .. tostring(coordsValid) .. ', rangeValid: ' .. tostring(rangeValid))
                if not coordsValid then
                    print('  coords type: ' .. type(jammer.coords) .. ', value: ' .. tostring(jammer.coords))
                end
                if not rangeValid then
                    print('  range type: ' .. type(jammer.range) .. ', value: ' .. tostring(jammer.range))
                end
            end
        else
            invalidJammers = invalidJammers + 1
            print('[Drone] WARNING: Invalid jammer data for ID ' .. tostring(id) .. 
                  ' - type: ' .. type(jammer) .. 
                  ' - has coords: ' .. tostring(jammer and jammer.coords ~= nil) .. 
                  ' - has range: ' .. tostring(jammer and jammer.range ~= nil))
        end
    end
    
    print('[Drone] Jammer data verification: ' .. validJammers .. ' valid, ' .. invalidJammers .. ' invalid jammers')
    return true, validJammers .. " valid jammers"
end

-- Enhanced jammer data retrieval with verification
local function getAllJammersWithVerification()
    if GetResourceState('jammer') ~= 'started' then
        print('[Drone] NOTICE: Jammer resource is not started')
        return {}
    end
    
    local success, jammers = pcall(function()
        return exports['jammer']:GetAllJammers()
    end)
    
    if not success then
        print('[Drone] ERROR: Failed to call jammer export: ' .. tostring(jammers))
        return {}
    end
    
    if not jammers then
        print('[Drone] NOTICE: Jammer export returned nil')
        return {}
    end
    
    local isValid, info = verifyJammerData(jammers)
    if isValid then
        print('[Drone] SUCCESS: Retrieved jammer data - ' .. info)
        
        -- Debug: Print first few jammers for verification
        local count = 0
        for id, jammer in pairs(jammers) do
            if count < 3 then -- Only show first 3 for brevity
                print('[Drone] DEBUG: Jammer ' .. tostring(id) .. 
                      ' at coords(' .. jammer.coords.x .. ', ' .. jammer.coords.y .. ', ' .. jammer.coords.z .. ')' ..
                      ' range=' .. tostring(jammer.range) ..
                      ' owner=' .. tostring(jammer.owner) ..
                      ' permanent=' .. tostring(jammer.permanent))
                count = count + 1
            end
        end
    else
        print('[Drone] ERROR: Invalid jammer data received - ' .. info)
        return {}
    end
    
    return jammers
end

-- Get all jammers from the jammer script

-- ================================================================
-- DEBUG COMMANDS FOR TESTING
-- ================================================================

RegisterCommand('dronetest', function()
    print('[Drone Test] ===== COMPREHENSIVE DRONE-JAMMER DEBUG =====')
    
    -- Test jammer resource state
    local jammerResourceState = GetResourceState('jammer')
    print('[Drone Test] Jammer resource state: ' .. jammerResourceState)
    
    local allJammers = getAllJammers()
    local jammerCount = 0
    for _ in pairs(allJammers) do jammerCount = jammerCount + 1 end
    
    print('[Drone Test] Found ' .. jammerCount .. ' jammers from getAllJammers()')
    
    if jammerCount > 0 then
        print('[Drone Test] Jammer data structure analysis:')
        local count = 0
        for id, jammer in pairs(allJammers) do
            if count < 3 then
                print('[Drone Test] Jammer ' .. tostring(id) .. ':')
                print('  coords type: ' .. type(jammer.coords))
                if type(jammer.coords) == "table" then
                    print('  coords: (' .. tostring(jammer.coords.x) .. ', ' .. tostring(jammer.coords.y) .. ', ' .. tostring(jammer.coords.z) .. ')')
                else
                    print('  coords: ' .. tostring(jammer.coords))
                end
                print('  range: ' .. tostring(jammer.range) .. ' (type: ' .. type(jammer.range) .. ')')
                print('  noGoZone: ' .. tostring(jammer.noGoZone) .. ' (type: ' .. type(jammer.noGoZone) .. ')')
                print('  owner: ' .. tostring(jammer.owner))
                print('  permanent: ' .. tostring(jammer.permanent))
                count = count + 1
            end
        end
    end
    
    -- Test jammer effects at player position
    local playerCoords = GetEntityCoords(PlayerPedId())
    print('[Drone Test] Testing signal calculations at player position:')
    print('  Player coords: (' .. string.format("%.1f", playerCoords.x) .. ', ' .. string.format("%.1f", playerCoords.y) .. ', ' .. string.format("%.1f", playerCoords.z) .. ')')
    
    -- Get configuration values for debugging
    print('[Drone Test] Configuration Values:')
    print('  JammerIntegration.enabled: ' .. tostring(Config.JammerIntegration.enabled))
    print('  JammerIntegration.excludeOwnerJammers: ' .. tostring(Config.JammerIntegration.excludeOwnerJammers))
    print('  SignalEffect.enabled: ' .. tostring(Config.JammerIntegration.SignalEffect.enabled))
    print('  SignalEffect.effectStartPercentage: 0.5 (HARDCODED - 50% of jammer range)')
    print('  SignalEffect.maxSignalLoss: ' .. tostring(Config.JammerIntegration.SignalEffect.maxSignalLoss))
    print('  SignalEffect.degradationExponent: ' .. tostring(Config.JammerIntegration.SignalEffect.degradationExponent))
    print('  NogoZone.enabled: ' .. tostring(Config.JammerIntegration.NogoZone.enabled))
    print('  NogoZone.threshold: PER-JAMMER (from jammer.noGoZone property)')
    print('  NoiseEffect.enabled: ' .. tostring(Config.DistanceLimiter.NoiseEffect.enabled))
    print('  NoiseEffect.effectStartPercentage: 0.5 (HARDCODED - 50% of jammer range)')
    print('  NoiseEffect.maxNoiseIntensity: ' .. tostring(Config.DistanceLimiter.NoiseEffect.maxNoiseIntensity))
    
    -- Test individual jammer calculations
    local allJammers = getAllJammers()
    if next(allJammers) then
        print('[Drone Test] Individual Jammer Analysis:')
        local count = 0
        for id, jammer in pairs(allJammers) do
            if count < 2 and jammer.coords and jammer.range then -- Test first 2 jammers
                local jammerCoords = vector3(jammer.coords.x, jammer.coords.y, jammer.coords.z)
                local distance = #(playerCoords - jammerCoords)
                local range = tonumber(jammer.range) or 50.0
                
                -- Calculate the specific thresholds using jammer's no-go zone property
                local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2 -- Default to 20% if not specified
                local nogoThreshold
                
                if noGoZoneValue >= 1.0 then
                    -- Absolute radius in meters
                    nogoThreshold = noGoZoneValue
                else
                    -- Percentage of jammer range
                   
                    nogoThreshold = range * noGoZoneValue
                end
                
                local effectTriggerDistance = range * 0.5  -- 50% for signal/noise effects
                
                print('  Jammer ' .. tostring(id) .. ':')
                print('    Distance: ' .. string.format("%.2f", distance) .. 'm')
                print('    Full Range: ' .. range .. 'm')
                print('    No-go Zone: ≤' .. string.format("%.1f", nogoThreshold) .. 'm (config: ' .. tostring(noGoZoneValue) .. ')')
                print('    Effects Zone: ≤' .. string.format("%.1f", effectTriggerDistance) .. 'm (50%)')

                
                if distance <= nogoThreshold then
                    print('    [NO-GO ZONE] Drone would disconnect!')
                elseif distance <= effectTriggerDistance then
                    print('    [EFFECTS ACTIVE] Calculating...')
                    local effectProgress = (effectTriggerDistance - distance) / (range - distance)
                    local signalLoss = effectProgress * 0.9  -- max signal loss
                    local noiseIntensity = effectProgress * 0.75  -- max noise
                    print('      Effect Progress: ' .. string.format("%.3f", effectProgress))
                    print('      Signal Loss: ' .. string.format("%.3f", signalLoss))
                    print('      Noise: ' .. string.format("%.3f", noiseIntensity))
                else
                    print('    [NO EFFECTS] Out of range')
                end
                count = count + 1
            end
        end
    end
    
    local signalLoss, noiseIntensity, inNogoZone = calculateJammerEffects(playerCoords)
    print('[Drone Test] Final calculated effects at player position:')
    print('  Signal Loss: ' .. string.format("%.4f", signalLoss) .. ' (0.0-1.0 scale)')
    print('  Noise Intensity: ' .. string.format("%.4f", noiseIntensity) .. ' (0.0-1.0 scale)')
    print('  In No-Go Zone: ' .. tostring(inNogoZone))
    
    -- Test signal quality conversion
    local baseSignalQuality = 100.0
    local signalReduction = signalLoss * 100
    local finalSignalQuality = math.max(0, baseSignalQuality - signalReduction)
    print('[Drone Test] Signal Quality Conversion:')
    print('  Base Signal Quality: ' .. baseSignalQuality .. '%')
    print('  Signal Reduction: ' .. string.format("%.2f", signalReduction) .. '%')
    print('  Final Signal Quality: ' .. string.format("%.2f", finalSignalQuality) .. '%')
    
    -- Test job detection system
    print('[Drone Test] Job Detection System Test:')
    local currentJob = getPlayerJob()
    print('  Current Player Job: ' .. tostring(currentJob))
    
    -- Test spawn capability at current location
    local canSpawn = canPlayerSpawnDroneHere(playerCoords)
    print('  Can Spawn Drone Here: ' .. tostring(canSpawn))
    
    for id, jammer in pairs(allJammers) do
        if jammer.coords and jammer.range then
            local jammerCoords = vector3(jammer.coords.x, jammer.coords.y, jammer.coords.z)
            local distance = #(playerCoords - jammerCoords)
            local inRange = distance <= (jammer.range or 50.0)
            
            if inRange then
                local jobIgnored = false
                if jammer.ignoredJobs and type(jammer.ignoredJobs) == "table" then
                    for _, ignoredJob in ipairs(jammer.ignoredJobs) do
                        if string.lower(currentJob) == string.lower(ignoredJob) then
                            jobIgnored = true
                            break
                        end
                    end
                end
                
                -- Check no-go zone
                local noGoZoneValue = tonumber(jammer.noGoZone) or 0.2
                local nogoThreshold = noGoZoneValue >= 1.0 and noGoZoneValue or ((jammer.range or 50.0) * noGoZoneValue)
                local inNoGoZone = distance <= nogoThreshold
                
                print('  Jammer ' .. tostring(id) .. ' (' .. (jammer.label or 'Unknown') .. '):')
                print('    Distance: ' .. string.format("%.1f", distance) .. 'm, Range: ' .. (jammer.range or 50.0) .. 'm')
                print('    No-Go Zone Threshold: ' .. string.format("%.1f", nogoThreshold) .. 'm, In No-Go Zone: ' .. tostring(inNoGoZone))
                print('    Ignored Jobs: ' .. (jammer.ignoredJobs and table.concat(jammer.ignoredJobs, ', ') or 'None'))
                print('    Job Ignored: ' .. tostring(jobIgnored))
                if jobIgnored then
                    print('    >>> JAMMER BYPASSED FOR THIS JOB <<<')
                elseif inNoGoZone then
                    print('    >>> BLOCKS DRONE SPAWN <<<')
                end
            end
        end
    end
    
    print('[Drone Test] ===== END DEBUG =====')
end)

RegisterCommand('dronesignal', function()
    if not controllingDrone then
        print('[Drone Signal] Not controlling a drone. Use this command while flying a drone.')
        return
    end
    
    print('[Drone Signal] === CURRENT SIGNAL STATUS ===')
    print('  Current Signal Quality: ' .. string.format("%.2f", calculatedSignalQuality) .. '%')
    print('  Current Noise Intensity: ' .. string.format("%.3f", calculatedNoiseIntensity))
    print('  Distance to Start: ' .. string.format("%.1f", currentDistanceToStart) .. 'm')
    print('  Max Distance: ' .. Config.DistanceLimiter.maxDistance .. 'm')
    print('  Jammer Signal Loss: ' .. string.format("%.3f", jammerSignalLoss))
    print('  Jammer Noise Intensity: ' .. string.format("%.3f", jammerNoiseIntensity))
    print('  In No-Go Zone: ' .. tostring(inNogoZone))
    print('  Battery Percentage: ' .. string.format("%.1f", currentBatteryPercentage * 100) .. '%')
    
    -- Show what values are being sent to NUI
    print('[Drone Signal] === VALUES SENT TO UI ===')
    local hudData = {
        action = "updateHUD",
        showBattery = Config.RuntimeLimiter.enabled,
        showSignal = Config.DistanceLimiter.enabled,
        signal = calculatedSignalQuality,
        showNoise = calculatedNoiseIntensity > 0.01,
        noiseLevel = calculatedNoiseIntensity
    }
    
    if hudData.showBattery then
        hudData.battery = math.floor(currentBatteryPercentage * 100)
    end
    
    print('  showBattery: ' .. tostring(hudData.showBattery))
    print('  showSignal: ' .. tostring(hudData.showSignal))
    print('  signal: ' .. string.format("%.2f", hudData.signal))
    print('  showNoise: ' .. tostring(hudData.showNoise))
    print('  noiseLevel: ' .. string.format("%.3f", hudData.noiseLevel))
    if hudData.battery then
        print('  battery: ' .. hudData.battery)
    end
    print('[Drone Signal] === END STATUS ===')
end)

-- Debug commands for testing overlays
RegisterCommand("testdronebodycam", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Testing bodycam overlay...')
        updatePlayerData() -- Trigger the bodycam overlay
    end
end, false)

RegisterCommand("testdroneconnlost", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Testing connection lost overlay...')
        SendNUIMessage({ 
            action = "showConnectionLost",
            duration = Config.Overlays and Config.Overlays.connectionLostDuration or 5000
        })
    end
end, false)

RegisterCommand("testdronebattery", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Testing battery empty overlay...')
        SendNUIMessage({ 
            action = "showBatteryEmpty",
            duration = Config.Overlays and Config.Overlays.batteryEmptyDuration or 5000
        })
    end
end, false)

RegisterCommand("testdronenoise", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Testing noise overlay at maximum intensity...')
        SendNUIMessage({ 
            action = "updateHUD", 
            showNoise = true, 
            noiseLevel = 1.0,
            showBattery = false,
            showSignal = false 
        })
    end
end, false)

RegisterCommand("testdronestartup", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Testing startup screen...')
        local logoUrl = Config.StartupScreen.logoUrl
        if logoUrl and logoUrl ~= "" then
            if not string.find(logoUrl, "^https?://") and not string.find(logoUrl, "^nui://") then
                local resourceName = GetCurrentResourceName()
                local sanitizedPath = logoUrl:gsub("^/", "")
                logoUrl = ("https://cfx-nui-%s/nui/%s"):format(resourceName, sanitizedPath)
            end
        end
        
        SendNUIMessage({
            action = "showStartupScreen",
            logoUrl = logoUrl,
            duration = Config.StartupScreen.duration or 3000,
            droneStartPercent = Config.StartupScreen.droneStartPercent or 80
        })
        
        if Config.StartupScreen.playSound and Config.StartupScreen.soundName then
            PlaySoundFrontend(-1, Config.StartupScreen.soundName, Config.StartupScreen.soundSet or "special_soundset", true)
        end
    end
end, false)

RegisterCommand("testdronehide", function()
    if Config.Debug and Config.Debug.enabled then
        print('[Drone Debug] Hiding all overlays...')
        hideOverlay()
    end
end, false)