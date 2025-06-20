local Config = {
    Framework = "esx",            
    ItemName = "drone",           
    RequireJob = false,           
    AllowedJobs = {"police", "ems", "mechanic"},
    CleanupInterval = 300000,
}

local ESX = nil
local QBCore = nil

-- Initialize framework
CreateThread(function()
    if Config.Framework == "esx" then
        while ESX == nil do
            TriggerEvent("esx:getSharedObject", function(obj) ESX = obj end)
            Wait(100)
        end
    elseif Config.Framework == "qb" then
        QBCore = exports['qb-core']:GetCoreObject()
    end
end)

local drones = {}
local droneSounds = {} 

local function playerHasItem(src, itemName)
    if Config.Framework == "esx" then
        local xPlayer = ESX.GetPlayerFromId(src)
        if xPlayer then
            local item = xPlayer.getInventoryItem(itemName)
            return item and item.count > 0
        end
    elseif Config.Framework == "qb" then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            local item = Player.Functions.GetItemByName(itemName)
            return item and item.amount > 0
        end
    end
    return false
end

local function sendErrorMessage(src, msg)
    if Config.Framework == "esx" then
        TriggerClientEvent('esx:showNotification', src, msg)
    elseif Config.Framework == "qb" then
        TriggerClientEvent('QBCore:Notify', src, msg, "error")
    end
end

local function hasRequiredJob(src)
    if not Config.RequireJob then return true end
    
    local job = nil
    if Config.Framework == "esx" then
        local xPlayer = ESX.GetPlayerFromId(src)
        if xPlayer then
            job = xPlayer.job.name
        end
    elseif Config.Framework == "qb" then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            job = Player.PlayerData.job.name
        end
    end
    
    if not job then return false end
    
    for _, allowedJob in pairs(Config.AllowedJobs) do
        if job == allowedJob then return true end
    end
    
    return false
end

RegisterNetEvent("drone:playAnimation")
AddEventHandler("drone:playAnimation", function()
    local src = source
    TriggerClientEvent("drone:receiveAnimation", src)
end)

RegisterNetEvent("drone:spawn")
AddEventHandler("drone:spawn", function(netId)
    local src = source

    drones[src] = {
        netId = netId,
        playerId = src,
        timestamp = os.time(),
        active = true
    }
    
    -- Initialize sound state for this drone
    droneSounds[netId] = {
        currentSound = "",
        lastUpdate = 0
    }
    
    TriggerClientEvent("drone:syncAll", -1, drones)
end)

RegisterNetEvent("drone:updateSound")
AddEventHandler("drone:updateSound", function(netId, soundName, coords, isOwnDrone_sent_by_client) -- isOwnDrone_sent_by_client is true if the sender is the owner
    local src = source -- This is the player who triggered the update (the drone owner)
    
    -- Validate inputs
    if not netId or not soundName or not coords then
        -- print(string.format("[DRONE_SCRIPT] drone:updateSound missing parameters from src %s", src))
        return
    end
    
    -- Check if this drone belongs to this player (src)
    local droneOwner = nil
    local droneData = nil
    for playerId_iterator, drone_data_iterator in pairs(drones) do
        if drone_data_iterator.netId == netId and drone_data_iterator.active then
            droneOwner = playerId_iterator
            droneData = drone_data_iterator
            break
        end
    end
    
    -- If we can't find the drone by netId, or if the sender (src) is not the recorded owner, reject.
    if not droneOwner or droneOwner ~= src then
        -- print(string.format("[DRONE_SCRIPT] drone:updateSound permission denied or drone not found. src %s, netId %s, found owner %s", src, netId, droneOwner or 'nil'))
        return
    end
    
    -- Initialize sound state for this netId if it doesn't exist
    if not droneSounds[netId] then
        droneSounds[netId] = {
            currentSound = "",
            lastUpdate = 0
        }
    end
    
    -- Only update if sound changed or enough time passed (prevent spam)
    local currentTime = GetGameTimer()
    if droneSounds[netId].currentSound ~= soundName or (currentTime - droneSounds[netId].lastUpdate) > 200 then
        droneSounds[netId].currentSound = soundName
        droneSounds[netId].lastUpdate = currentTime
        
        -- Broadcast sound to all players.
        -- For each player, determine if they are the owner (src) of this drone sound event.
        for _, playerId_str in ipairs(GetPlayers()) do
            local targetPlayerId = tonumber(playerId_str)
            local isRecipientTheOwner = (targetPlayerId == src) -- src is the drone owner who initiated this sound update
            TriggerClientEvent("drone:playSound", targetPlayerId, netId, soundName, coords, isRecipientTheOwner)
        end
    end
end)

RegisterNetEvent("drone:stopSound")
AddEventHandler("drone:stopSound", function(netId)
    local src = source -- The player who is controlling the drone and telling it to stop its sound
    
    if not netId then return end
    
    local droneOwner = nil
    for playerId, droneData_iterator in pairs(drones) do -- Renamed droneData to avoid conflict
        if droneData_iterator.netId == netId and droneData_iterator.active then
            droneOwner = playerId
            break
        end
    end

    -- Only the owner of the drone should be able to explicitly stop its continuous sound via this path
    -- Or if the server is globally stopping it (src might be nil or a special value if called server-side)
    if droneOwner and droneOwner ~= src then
        -- print(string.format("Player %s tried to stop sound for drone %s owned by %s", src, netId, droneOwner))
        return
    end
    
    if droneSounds[netId] then
        droneSounds[netId].currentSound = ""
        -- droneSounds[netId].lastUpdate = GetGameTimer() -- Not strictly needed here
    end
    
    -- Broadcast stop sound to all players for the specific netId
    TriggerClientEvent("drone:stopSound", -1, netId)
end)

-- New event handler for when a client initiates drone destruction
RegisterNetEvent("drone:initiateDestruction")
AddEventHandler("drone:initiateDestruction", function(destroyedNetId, effectCoords)
    local src = source -- This is the player who was controlling the drone

    -- Spark effect broadcast to other clients is removed.

    if drones[src] then
        local serverKnownNetId = drones[src].netId

        if droneSounds[serverKnownNetId] then
            TriggerClientEvent("drone:stopSound", -1, serverKnownNetId) -- Stop for all clients
            droneSounds[serverKnownNetId] = nil
        end

        drones[src].active = false
        
        CreateThread(function()
            Wait(1000) -- Delay before removing from sync, client handles visual delay of falling
            if drones[src] and not drones[src].active then
                drones[src] = nil
                TriggerClientEvent("drone:syncAll", -1, drones)
            end
        end)
    else
        -- print(string.format("[DRONE_SCRIPT] Warning: drone:initiateDestruction called for src %s, but no active drone found.", src))
    end
end)

AddEventHandler("playerDropped", function()
    local src = source
    if drones[src] then
        local netId = drones[src].netId
        if droneSounds[netId] then
            TriggerClientEvent("drone:stopSound", -1, netId)
            droneSounds[netId] = nil
        end
        drones[src].active = false
        drones[src] = nil
        TriggerClientEvent("drone:syncAll", -1, drones)
    end
end)

CreateThread(function()
    while (Config.Framework == "esx" and ESX == nil) or (Config.Framework == "qb" and QBCore == nil) do
        Wait(100)
    end
      if Config.Framework == "esx" and ESX then
        ESX.RegisterUsableItem(Config.ItemName, function(source)
            local src = source
            if not hasRequiredJob(src) then
                sendErrorMessage(src, "You are not authorized to use the drone.")
                return
            end
            
            local xPlayer = ESX.GetPlayerFromId(src)
            if xPlayer then
                -- Send player data to client first
                local playerData = {
                    name = xPlayer.getName and xPlayer.getName() or GetPlayerName(src),
                    job = xPlayer.job.name,
                    grade = xPlayer.job.grade_label or xPlayer.job.grade_name
                }
                TriggerClientEvent("drone:setPlayerData", src, playerData)
                Wait(100)
                TriggerClientEvent("drone:useItem", src)
                xPlayer.removeInventoryItem(Config.ItemName, 1)
            end
        end)
          elseif Config.Framework == "qb" and QBCore then
        QBCore.Functions.CreateUseableItem(Config.ItemName, function(source, item)
            local src = source
           
            if not hasRequiredJob(src) then
                sendErrorMessage(src, "You are not authorized to use the drone.")
                return
            end
            
            local Player = QBCore.Functions.GetPlayer(src)
            if Player then
                -- Send player data to client first
                local playerData = {
                    name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname,
                    job = Player.PlayerData.job.name,
                    grade = Player.PlayerData.job.grade.name
                }
                TriggerClientEvent("drone:setPlayerData", src, playerData)
                TriggerClientEvent("drone:useItem", src)
                Player.Functions.RemoveItem(Config.ItemName, 1)
                TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[Config.ItemName], "remove", 1)
            end
        end)
    end
end)

RegisterNetEvent("drone:sendPlayerData")
AddEventHandler("drone:sendPlayerData", function()
    local src = source
    local playerName, playerRank, playerJob

    if Config.Framework == "esx" then
        local xPlayer = ESX.GetPlayerFromId(src)
        if xPlayer then
            playerName = xPlayer.getName()
            playerRank = xPlayer.getGroup() or "Unknown"
            playerJob = xPlayer.job.name
        end
    elseif Config.Framework == "qb" then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            playerName = Player.PlayerData.name
            playerRank = Player.PlayerData.rank or "Unknown"
            playerJob = Player.PlayerData.job.name
        end
    end

    TriggerClientEvent("drone:updatePlayerData", src, {
        name = playerName,
        rank = playerRank,
        job = playerJob
    })
end)



