Config = {
    ----------------------------------------------------------------
    -- GENERAL & FRAMEWORK SETTINGS
    ----------------------------------------------------------------
    Framework = "esx",              -- "esx" or "qb"
    ItemName = "drone",            
    RequireJob = false,             

    ----------------------------------------------------------------
    -- JOB CONFIGURATION
    -- `displayName`: Name shown on the drone UI.
    -- `logoUrl`: Image URL for the department logo on the UI.
    -- `canUseVision`: Can this job toggle Night and Thermal vision
    ----------------------------------------------------------------
    Jobs = {     
        ["police"] = {
            displayName = "Police Department",
            logoUrl = "images/LSPD.png",
            canUseVision = true
        },
        ["jsoc"] = {
            displayName = "Joint Special Operations Command",
            logoUrl = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d2/Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg/1280px-Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg.png",
            canUseVision = true
        },
        ["default"] = {  
            displayName = "Drone Camera",
            logoUrl = "images/default.png",
            canUseVision = true         
        }
    },

    ----------------------------------------------------------------
    -- DRONE MODEL & PERFORMANCE
    ----------------------------------------------------------------
    -- Core Properties
    DroneModel = `ch_prop_casino_drone_01a`, 
    DroneHealth = 25,                      

    -- Physics & Controls
    DroneSpeed = 5.0,                       
    SpeedBoostMultiplier = 2.5,             -- Speed multiplier when boosting.
    RotationSpeed = 120.0,                  
    MouseSensitivity = 1.5,                
    -- Camera
    CameraOffset = vector3(0.0, 0.0, 0.1),  
    MaxFOV = 90.0,                          
    MinFOV = 5.0,                          
    ZoomSpeed = 5.0,                       
    RotationZoomScaling = false,           

    ----------------------------------------------------------------
    -- CONTROLS
    -- A list of GTA5 control keys. Find more here: https://docs.fivem.net/docs/game-references/controls/
    ----------------------------------------------------------------
    Keys = {
        Forward = 32,       -- W
        Backward = 33,      -- S
        StrafeLeft = 34,    -- A
        StrafeRight = 35,   -- D
        Ascend = 22,        -- Space
        Descend = 21,       -- Left Shift
        RotateLeft = 44,    -- Q
        RotateRight = 38,   -- E
        Boost = 36,         -- Left Ctrl
        VisionToggle = 74,  -- H (Night/Thermal vision)
        Exit = 23,          -- F
    },

    ----------------------------------------------------------------
    -- Battery / Runtime Limiter
    ----------------------------------------------------------------
    RuntimeLimiter = {
        enabled = true,                     -- Enable/disable the battery feature.
        batteryDuration = 600,               -- Battery life in seconds.
        lowBatteryWarningThreshold = 0.30,  -- Show warning when battery is at 30% or less.
        overlayFlashDuration = 1500,        -- Not currently used, but for future features.
        lowBatteryColor = {r = 255, g = 165, b = 0, a = 255}, -- Orange for low battery bar.
        criticalBatteryColor = {r = 255, g = 0, b = 0, a = 255} -- Red for critical battery bar.
    },

    ----------------------------------------------------------------
    -- SIGNAL / DISTANCE LIMITER
    ----------------------------------------------------------------     
    DistanceLimiter = {
        enabled = true,                    
        maxDistance = 300.0,                -- Max distance in meters from the player before connection is lost.
        effectStartPercentage = 0.5,       
        NoiseEffect = {
            enabled = true,                 
            noiseStartPercentage = 0.8,     
            maxNoiseIntensity = 0.75,       
            degradationExponent = 7.5       -- Higher value = slower start, much faster ramp-up at the end (noise only).
        },
        NoiseSound = {
            enabled = true                  -- Enable/disable audio static/interference sound.
        }
    },

    ----------------------------------------------------------------
    -- PLAYER ANIMATION & PROP
    ----------------------------------------------------------------
    Animation = {
        dict = "anim@heists@ornate_bank@hack",
        name = "hack_loop",
    },

    -- Laptop prop that appears in front of the player.
    Prop = {
        enabled = true,
        model = `prop_laptop_01a`,
        bone = 0,
        groundOffset = vector3(0.5, 0.7, -1.0),
        rotation = vector3(0.0, 0.0, 0.0),
    },

    ----------------------------------------------------------------
    -- UI & VISUALS
    ----------------------------------------------------------------
    HUD = {
        disableComponents = true,    -- If true, hides certain vanilla HUD elements.
        hiddenComponents = { 1, 2, 3, 4, 6, 7, 8, 9, 13, 17, 20, 21, 22 },
        hideRadar = true,
        hideHealthArmor = true,
        hideWeaponWheel = true
    },

    MapMarker = {
        enabled = true,
        sprite = 741,              -- Blip icon ID. 613 is a drone icon.
        color = 1,                 -- Blip color ID. 3 is blue.
        scale = 0.6,
        trackRotation = false,     -- Set to true to make minimap rotate with drone heading, false to lock to north
    },

    ----------------------------------------------------------------
    -- EFFECTS
    ----------------------------------------------------------------
    Sound = {
        Set = "special_soundset",   -- The sound set in your audio files.
        Hover = "Error",            -- Sound name for hovering.
        Manouver = "Wow",           -- Sound name for moving/boosting.
        RenderDistance = 100.0,     -- Max distance other players can hear your drone.
        Update = 150,               -- How often to update the sound loop (ms).
    },

    DestructionEffect = {
        asset = "core",
        name = "ent_dst_elec_fire_sp",
        scale = 0.75,
        loopAmount = 7,
        loopDelay = 75
    },

    DestructionSound = {
        name = "ent_amb_elec_crackle",
        set = "",
    },
}