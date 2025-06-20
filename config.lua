Config = {
    ----------------------------------------------------------------
    -- GENERAL & FRAMEWORK SETTINGS
    ----------------------------------------------------------------
    Framework = "esx",              -- "esx" or "qb"
    ItemName = "drone",             -- The item name required to use the drone.
    RequireJob = false,             -- If true, players need a job from the list below to use the drone.

    ----------------------------------------------------------------
    -- JOB CONFIGURATION
    -- `enabled`: If `RequireJob` is true, can this job use the drone?
    -- `displayName`: Name shown on the drone UI.
    -- `logoUrl`: Image URL for the department logo on the UI.
    -- `canUseVision`: Can this job toggle Night and Thermal vision?
    ----------------------------------------------------------------
    Jobs = {     
        ["police"] = {
            enabled = true,
            displayName = "Police Department",
            logoUrl = "images/LSPD.png",
            canUseVision = true
        },
        ["jsoc"] = {
            enabled = true,
            displayName = "Joint Special Operations Command",
            logoUrl = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d2/Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg/1280px-Seal_of_the_Joint_Special_Operations_Command_%28JSOC%29.svg.png",
            canUseVision = true
        },
        ["default"] = {
            enabled = true,             -- This should generally be true to provide a fallback.
            displayName = "Drone Camera",
            logoUrl = "images/default.png",
            canUseVision = true         -- Allow vision modes for non-job players if RequireJob is false.
        }
    },

    ----------------------------------------------------------------
    -- DRONE MODEL & PERFORMANCE
    ----------------------------------------------------------------
    -- Core Properties
    DroneModel = `ch_prop_casino_drone_01a`, -- Drone's 3D model.
    DroneHealth = 10,                       -- How much damage the drone can take before breaking.

    -- Physics & Controls
    DroneSpeed = 5.0,                       -- Base movement speed.
    SpeedBoostMultiplier = 2.0,             -- Speed multiplier when boosting.
    RotationSpeed = 120.0,                  -- How fast the drone turns.
    MouseSensitivity = 1.0,                 -- Mouse look sensitivity.

    -- Camera
    CameraOffset = vector3(0.0, 0.0, 0.1),  -- Camera position relative to the drone model.
    MaxFOV = 70.0,                          -- Default Field of View (widest).
    MinFOV = 10.0,                          -- Zoomed-in Field of View (narrowest).
    ZoomSpeed = 10.0,                       -- How fast the camera zooms in/out.
    RotationZoomScaling = false,            -- If true, slows down rotation speed when zoomed in.

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
    -- FEATURES
    ----------------------------------------------------------------
    -- Battery / Runtime Limiter
    RuntimeLimiter = {
        enabled = true,                     -- Enable/disable the battery feature.
        batteryDuration = 30,               -- Battery life in seconds.
        lowBatteryWarningThreshold = 0.30,  -- Show warning when battery is at 30% or less.
        overlayFlashDuration = 1500,        -- Not currently used, but for future features.
        lowBatteryColor = {r = 255, g = 165, b = 0, a = 255}, -- Orange for low battery bar.
        criticalBatteryColor = {r = 255, g = 0, b = 0, a = 255} -- Red for critical battery bar.
    },

    -- Signal / Distance Limiter
    DistanceLimiter = {
        enabled = true,                     -- Enable/disable the signal distance limit.
        maxDistance = 100.0,                -- Max distance in meters from the player before connection is lost.
        effectStartPercentage = 0.50,       -- Signal degradation effects start at 50% of maxDistance.
        degradationExponent = 5.0,          -- Higher value = slower start, much faster ramp-up at the end.
        maxNoiseIntensity = 0.1,            -- Max opacity for the static overlay (0.0 to 1.0).
        maxTimecycleStrength = 0.8,         -- Not currently used.
        maxFovDistortion = 5.0,             -- Max additional FOV due to signal distortion.

        NoiseEffect = {
            enabled = true                  -- Enable/disable visual static effect on screen.
        },
        NoiseSound = {
            enabled = true                  -- Enable/disable audio static/interference sound.
        }
    },

    ----------------------------------------------------------------
    -- PLAYER ANIMATION & PROP
    ----------------------------------------------------------------
    -- Animation played by the player character while flying the drone.
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
    -- General HUD hiding rules
    HUD = {
        disableComponents = true,    -- If true, hides certain vanilla HUD elements.
        hiddenComponents = { 1, 2, 3, 4, 6, 7, 8, 9, 13, 17, 20, 21, 22 },
        hideRadar = true,
        hideHealthArmor = true,
        hideWeaponWheel = true
    },

    -- Drone's blip on the map
    MapMarker = {
        enabled = true,
        sprite = 613,              -- Blip icon ID. 613 is a drone icon.
        color = 3,                 -- Blip color ID. 3 is blue.
        scale = 0.8,
    },

    ----------------------------------------------------------------
    -- EFFECTS
    ----------------------------------------------------------------
    -- Sound effects for the drone
    Sound = {
        Set = "special_soundset",   -- The sound set in your audio files.
        Hover = "Error",            -- Sound name for hovering.
        Manouver = "Wow",           -- Sound name for moving/boosting.
        RenderDistance = 100.0,     -- Max distance other players can hear your drone.
        Update = 150,               -- How often to update the sound loop (ms).
    },

    -- Visual and audio effects when the drone is destroyed.
    DestructionEffect = {
        asset = 'core',
        name = 'ent_dst_elec_fire_sp',
        scale = 1.75,
        loopAmount = 7,
        loopDelay = 75
    },
    DestructionSound = {
        name = 'ent_amb_elec_crackle',
        set = "",
    },
} 