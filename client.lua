--Todo:
    -- HideHUD
    -- 2. Variant for JSOC
    



-- ========================================
-- CONFIGURATION SETTINGS
-- ========================================
local Config = {
    -- Framework Settings
    Framework = "esx",            -- Set to "esx" or "qb"
    
    -- Drone Physics & Controls
    DroneSpeed = 5.0,
    RotationSpeed = 120.0,
    MouseSensitivity = 1.0,
    RotationZoomScaling = false,
    ZoomSpeed = 10.0,
    MinFOV = 10.0,
    MaxFOV = 70.0,
    SpeedBoostMultiplier = 2.0,
    
    -- Drone Model & Health
    DroneModel = `ch_prop_casino_drone_01a`, -- Drone 3D model hash
    DroneHealth = 10,            -- Drone health points
    CameraOffset = vector3(0.0, 0.0, 0.1), -- Camera offset from drone (x, y, z)
    
    
    -- Map & Minimap Settings
    ShowMapMarker = true,         -- Show drone marker on map
    BlipSprite = 613,             -- Drone blip sprite ID (613 = drone icon)
    BlipColor = 3,                -- Drone blip color (3 = blue)
    BlipScale = 0.8,              -- Drone blip scale

    -- Job Configuration
    Jobs = {
        ["police"] = {
            enabled = true,
            displayName = "Police Department",
            logoUrl = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d2/Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg/1280px-Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg.png",
            canUseVision = true
        },
        ["jsoc"] = {
            enabled = true,
            displayName = "Joint Special Operations Command",
            logoUrl = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d2/Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg/1280px-Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg.png",
            canUseVision = true
        },
        ["default"] = {
            enabled = true,
            displayName = "Drone Camera",
            logoUrl = "https://i.imgur.com/TNiLwIZ.png",
            canUseVision = true
        }
    },


    -- HUD Configuration
    HUD = {
        disableComponents = true,    -- Enable/disable HUD component hiding
        hiddenComponents = {
            1,   -- WANTED_STARS
            2,   -- WEAPON_ICON
            3,   -- CASH
            4,   -- MP_CASH
            6,   -- VEHICLE_NAME
            7,   -- AREA_NAME
            8,   -- VEHICLE_CLASS
            9,   -- STREET_NAME
            13,  -- CASH_CHANGE
            17,  -- SAVE_GAME
            20,  -- STAMINA
            21,  -- BREATH
            22   -- THROW_GRENADE
        },
        hideRadar = true,           -- Hide minimap/radar
        hideHealthArmor = true,     -- Hide health and armor bars
        hideWeaponWheel = true      -- Hide weapon wheel
    },

    --Visuals
    Animation = {
        dict = "anim@heists@ornate_bank@hack",
        name = "hack_loop", 
    },
    
    -- Prop Configuration
    Prop = {
        enabled = true,           -- Enable/disable prop
        model = `prop_laptop_01a`, -- Laptop model hash
        bone = 0,                 -- World placement (not attached to bone)
        groundOffset = vector3(0.5, 0.7, -1.0), -- Offset from player position on ground
        rotation = vector3(0.0, 0.0, 0.0), -- Laptop rotation
    },
    
    -- Control Keys
    Keys = {
        Forward = 32,       -- W key
        Backward = 33,      -- S key
        Ascend = 22,        -- Space key
        Descend = 21,       -- Left Shift key
        StrafeLeft = 34,    -- A key
        StrafeRight = 35,   -- D key
        RotateLeft = 44,    -- Q key
        RotateRight = 38,   -- E key
        Boost = 36,         -- Left Ctrl key
        VisionToggle = 74,  -- H key (Night/Thermal vision)
        Exit = 23,          -- F key
    },

    Sound = {
        Set = "special_soundset",
        Hover = "Error",
        Manouver = "Wow",
        RenderDistance = 100.0,    -- Distance at which sounds can be heard
        Update = 150,              -- Sound update interval in milliseconds
    },

    DestructionEffect = {
        asset = 'core',
        name = 'ent_dst_elec_fire_sp',
        scale = 1.75,
        loopAmount = 7,
        loopDelay = 75
    },
    DestructionSound = {
        name = 'ent_amb_elec_crackle',
        set = "0"
    },

    -- NEW: Runtime Limiter (Battery)
    RuntimeLimiter = {
        enabled = true,                     -- Enable/disable battery feature
        batteryDuration = 30,              -- Battery duration in seconds (e.g., 300s = 5 minutes)
        lowBatteryWarningThreshold = 0.30,  -- Show warning when battery is at 20%
        overlayFlashDuration = 1500,        -- How long the "Battery Empty" overlay flashes (ms)
        lowBatteryColor = {r = 255, g = 165, b = 0, a = 255}, -- Orange for low battery
        criticalBatteryColor = {r = 255, g = 0, b = 0, a = 255} -- Red for critical
    },

    -- NEW: Distance Limiter
    DistanceLimiter = {
        enabled = true,                     -- Enable/disable distance limit feature
        maxDistance = 100.0,                -- Maximum distance from start point in meters
        effectStartPercentage = 0.50,       -- Worsening connection starts at 50% of maxDistance
        degradationExponent = 5.0,          -- Higher value = slower start, much faster ramp-up at the end.
        maxNoiseIntensity = 0.1,            -- Max opacity for the static overlay (0.0 to 1.0)
        maxTimecycleStrength = 0.8,
        maxFovDistortion = 5.0,             -- Max additional FOV due to distortion

        NoiseEffect = {
            enabled = true
        },

        NoiseSound = {
            enabled = true
        }
    },
}

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
local connectionQuality = 1.0 -- 1.0 = perfect, 0.0 = no connection
local activeTimecycleModifier = nil
local originalCamFOV = 70.0 -- To store camera FOV before distortion

local droneEntity, droneCamera = nil, nil
local controllingDrone = false
local currentFOV = Config.MaxFOV
local droneCoordsStart, visionMode = nil, 0
local droneBlip = nil
local heliCamScaleform = nil
local propObject = nil
local isAnimationPlaying = false
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
    if Config.ShowMapMarker and droneEntity and DoesEntityExist(droneEntity) then
        droneBlip = AddBlipForEntity(droneEntity)
        SetBlipSprite(droneBlip, Config.BlipSprite)
        SetBlipColour(droneBlip, Config.BlipColor)
        SetBlipScale(droneBlip, Config.BlipScale)
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
    local jobName = "unemployed" -- Default
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
            loadOverlay()
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
            loadOverlay()
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

-- Update player data and send to NUI
local function updatePlayerData()
    local pInfo = getPlayerInfo() -- Use the consistent function to get player details
    local jobConfig = Config.Jobs[pInfo.job] or Config.Jobs.default

    SendNUIMessage({
        action = "updatePlayerData",
        data = {
            name = pInfo.name,
            rank = pInfo.rank,
            job = (jobConfig and jobConfig.displayName) or pInfo.job
        }
    })
end

-- Function to toggle overlay visibility based on drone activity
local function toggleOverlayVisibility(isActive)
    if isActive then
        loadOverlay() -- This will determine and show the correct overlay (HTML or texture)
        updatePlayerData() -- Send initial player data when drone becomes active
    else
        hideOverlay() -- This tells NUI to hide all HTML overlays
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

    -- Update NUI with potentially new player info due to job change
    local currentPlayerData = getPlayerInfo() -- This will now reflect the new job
    local jobConfig = Config.Jobs[currentPlayerData.job] or Config.Jobs.default
    SendNUIMessage({
        action = "updatePlayerData",
        data = {
            name = currentPlayerData.name,
            rank = currentPlayerData.rank,
            job = (jobConfig and jobConfig.displayName) or currentPlayerData.job
        }
    })

    if controllingDrone then
        loadOverlay() -- Reload overlay if player is currently controlling a drone
    end
end)

RegisterNetEvent("drone:setPlayerData")
AddEventHandler("drone:setPlayerData", function(data)
    if data then
        playerData.name = data.name
        playerData.job = data.job
        playerData.grade = data.grade
        
        if controllingDrone then
            updatePlayerData() 
            loadOverlay()      
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
            showSignal = Config.DistanceLimiter.enabled
        }

        if hudData.showBattery then
            hudData.battery = math.floor(currentBatteryPercentage * 100)
        end

        if hudData.showSignal then
            hudData.signal = connectionQuality * 100
        end

        if Config.DistanceLimiter.enabled and Config.DistanceLimiter.NoiseEffect.enabled then
            hudData.showNoise = true
            hudData.noiseLevel = (1.0 - connectionQuality) * Config.DistanceLimiter.maxNoiseIntensity
        else
            hudData.showNoise = false
        end

        SendNUIMessage(hudData)
    end
end

local function controlDrone()
    local ped = PlayerPedId()
    controllingDrone = true
    droneCoordsStart = GetEntityCoords(ped) 
    soundTimer = GetGameTimer()

    saveOriginalHudState()
    loadOverlay() -- Activate the correct overlay (HTML or prepare for texture)
    updatePlayerData()

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
    originalCamFOV = currentFOV

    resetBatteryState()

    if Config.DistanceLimiter.enabled then
        currentDistanceToStart = 0.0
        connectionQuality = 1.0
        if activeTimecycleModifier then
            ClearTimecycleModifier()
            activeTimecycleModifier = nil
        end
        SetTimecycleModifierStrength(0)
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
                connectionQuality = 0.0
            elseif currentDistanceToStart > effectTriggerDistance then
                local linearProgress = (currentDistanceToStart - effectTriggerDistance) / (Config.DistanceLimiter.maxDistance - effectTriggerDistance)
                linearProgress = math.max(0, math.min(1, linearProgress))

                local exponent = Config.DistanceLimiter.degradationExponent
                local effectProgress = linearProgress ^ exponent
                
                connectionQuality = 1.0 - effectProgress

                if Config.DistanceLimiter.timecycleModifier and Config.DistanceLimiter.timecycleModifier ~= "" then
                    if not activeTimecycleModifier or activeTimecycleModifier ~= Config.DistanceLimiter.timecycleModifier then
                        SetTimecycleModifier(Config.DistanceLimiter.timecycleModifier)
                        activeTimecycleModifier = Config.DistanceLimiter.timecycleModifier
                    end
                    SetTimecycleModifierStrength(effectProgress * Config.DistanceLimiter.maxTimecycleStrength)
                end

                local fovDistortion = effectProgress * Config.DistanceLimiter.maxFovDistortion
                SetCamFov(droneCamera, originalCamFOV + fovDistortion)
            else
                connectionQuality = 1.0
                if activeTimecycleModifier then
                    ClearTimecycleModifier()
                    SetTimecycleModifierStrength(0)
                    activeTimecycleModifier = nil
                end
                SetCamFov(droneCamera, originalCamFOV)
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

        local lookX = -GetDisabledControlNormal(0, 1) * Config.MouseSensitivity
        local lookY = GetDisabledControlNormal(0, 2) * Config.MouseSensitivity
        local zoomFactor = (currentFOV - Config.MinFOV) / (Config.MaxFOV - Config.MinFOV)
        local adjustedRotSpeed = Config.RotationZoomScaling and Config.RotationSpeed * (zoomFactor ^ 1.1) or Config.RotationSpeed

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
    DisplayRadar(true)
    DisplayHud(true)
    for i = 0, 337 do EnableControlAction(0, i, true) end
    stopAnimation()

    if activeTimecycleModifier then
        ClearTimecycleModifier()
        SetTimecycleModifierStrength(0)
        activeTimecycleModifier = nil
    end
    isLowBattery = false
    isCriticalBattery = false
    connectionQuality = 1.0

    if soundTimer then soundTimer = 0 end
    controllingDrone = false
    currentFOV = Config.MaxFOV
    resetBatteryState() -- Final reset on exit
end

function destroyDrone(entity)
    if entity and DoesEntityExist(entity) then
        local destroyedCoords = GetEntityCoords(entity)
        
        -- Play sound once
        PlaySoundFromCoord(-1, Config.DestructionSound.name, destroyedCoords.x, destroyedCoords.y, destroyedCoords.z, Config.DestructionSound.set, false, 0, false)

        -- Loop particle effects in a new thread
        CreateThread(function()
            RequestNamedPtfxAsset(Config.DestructionEffect.asset)
            while not HasNamedPtfxAssetLoaded(Config.DestructionEffect.asset) do
                Wait(50)
            end
            UseParticleFxAssetNextCall(Config.DestructionEffect.asset)
            for i = 1, Config.DestructionEffect.loopAmount do
                StartParticleFxNonLoopedAtCoord(Config.DestructionEffect.name, destroyedCoords.x, destroyedCoords.y, destroyedCoords.z, 0.0, 0.0, 0.0, Config.DestructionEffect.scale, false, false, false)
                Wait(Config.DestructionEffect.loopDelay)
            end
        end)
        
        -- Instantly delete the drone entity
        DeleteEntity(entity)
    end
end

local function playNoiseSound()
    if not isNoiseSoundPlaying and Config.DistanceLimiter.NoiseSound.enabled then
        noiseSoundId = GetSoundId()
        -- ... existing code ...
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

-- Hypothetical NUI callback for flash messages (you'll need to implement the NUI side)
RegisterNUICallback("flashMessageComplete", function(data, cb)
    -- This could be used if NUI signals back after a flash, but often not needed
    cb("ok")
end)

function loadOverlay()
    local currentJob = getPlayerJob() 
    local logoConfig = Config.Jobs[currentJob] or Config.Jobs["default"]

    if logoConfig and logoConfig.enabled then
        local nuiData = {
            action = "showOverlay",
            overlayType = "bodycam"
        }
        if logoConfig.logoUrl then
            nuiData.logoUrl = logoConfig.logoUrl
        end
        SendNUIMessage(nuiData)
    else
        SendNUIMessage({ action = "hideOverlay" }) -- Hide if no valid config
    end
    -- Persistent HUD (battery/signal) is managed by NUI via "updateHUD" messages from DrawDroneOverlay
end

RegisterCommand("drone_test_noise", function()
    if controllingDrone then
        isNoiseTestActive = not isNoiseTestActive
        if isNoiseTestActive then
            TriggerEvent('chat:addMessage', {
                color = { 255, 0, 0 },
                args = { "[Drone]", "Noise test ACTIVATED." }
            })
        else
            TriggerEvent('chat:addMessage', {
                color = { 0, 255, 0 },
                args = { "[Drone]", "Noise test DEACTIVATED." }
            })
        end
    else
        TriggerEvent('chat:addMessage', {
            color = { 255, 165, 0 },
            args = { "[Drone]", "You must be controlling a drone to use this command." }
        })
    end
end, false)
