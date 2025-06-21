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

-- NEW: State variables for battery and distance limiters
local batteryStartTime = 0
local currentBatteryPercentage = 1.0
local isLowBattery = false
local isCriticalBattery = false
local isNoiseTestActive = false
local playNoiseSound, stopNoiseSound -- Forward declaration

local currentDistanceToStart = 0.0
local calculatedSignalQuality = 100.0 -- Signal bars percentage (0-100)
local calculatedNoiseIntensity = 0.0 -- Noise overlay intensity (0.0-1.0)

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

local function resetBatteryState()
    if Config.RuntimeLimiter.enabled then
        batteryStartTime = GetGameTimer()
        currentBatteryPercentage = 1.0
        isLowBattery = false
        isCriticalBattery = false
        isNoiseTestActive = false
    end
end

CreateThread(function()
    if Config.Framework == "qb" then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    
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
    -- loadOverlay() -- This will be called by setPlayerData
    -- updatePlayerData() -- This will be called by setPlayerData

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

        if destructionReason then
            controllingDrone = false 
            if destructionReason == "battery_empty" then
                stopDroneSound()
                SendNUIMessage({ action = "showBatteryEmpty" })
                Wait(3000) -- Show the empty battery screen for 3 seconds
            elseif destructionReason == "out_of_range" then
                stopDroneSound()
                SendNUIMessage({ action = "showConnectionLost" })
                Wait(3000) -- Show the connection lost screen for 3 seconds
            end

            destroyDrone(droneEntity)

            droneEntity = nil 
            break 
        end

        if GetGameTimer() - soundTimer > Config.Sound.Update then
            local velocity = GetEntityVelocity(droneEntity)
            local isBoostPressed = IsControlPressed(0, Config.Keys.Boost)
            
            TriggerServerEvent("drone:updateSound", NetworkGetNetworkIdFromEntity(droneEntity), Config.Sound.Hover, currentDroneCoords, true, isBoostPressed)

            soundTimer = GetGameTimer()
        end
        
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
            destroyDrone(droneEntity)
            droneEntity = nil 
            controllingDrone = false
            break 
        end
    end 

    stopDroneSound()
    
    SendNUIMessage({ action = "updateHUD", showBattery = false, showSignal = false })
    hideOverlay()
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
end

local function spawnDroneAndControl()
    local ped = PlayerPedId()
    
    if IsPedInAnyVehicle(ped) then 
        return false
    end

    if controllingDrone then
        return false
    end

    resetBatteryState() -- Reset battery state before spawning a new drone

    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)        RequestModel(Config.DroneModel)
    while not HasModelLoaded(Config.DroneModel) do 
        Wait(50)
    end
    
    if not HasModelLoaded(Config.DroneModel) then
        return false
    end
      droneEntity = CreateObject(Config.DroneModel, pos.x, pos.y, pos.z + 1.0, true, true, true)    if not droneEntity or not DoesEntityExist(droneEntity) then
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

-- NUI Callbacks
RegisterNUICallback("hideOverlay", function(data, cb)
    SetNuiFocus(false, false)
    cb("ok")
end)

RegisterNUICallback("flashMessageComplete", function(data, cb)

    cb("ok")
end)

RegisterNetEvent("drone:playDestructionEffect")
AddEventHandler("drone:playDestructionEffect", function(netId, coords, ownerPlayerId)
    if currentSoundId ~= -1 then
        stopDroneSound()
    end
    
    if coords then
        RequestNamedPtfxAsset(Config.DestructionEffect.asset)
        while not HasNamedPtfxAssetLoaded(Config.DestructionEffect.asset) do
            Wait(1)
        end

        UseParticleFxAssetNextCall(Config.DestructionEffect.asset)
        StartParticleFxNonLoopedAtCoord(Config.DestructionEffect.name, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 1.0, false, false, false)
        PlaySoundFromCoord(-1, Config.DestructionSound.name, coords.x, coords.y, coords.z, Config.DestructionSound.set, false, 50.0, false)
        
    end
end)
