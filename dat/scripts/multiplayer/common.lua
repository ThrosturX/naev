--  each line is <player_id> <pos> <dir> <vel> <armour> <shield> <stress>
local function unmarshal( player_info )
    local nice_player = {
        id = player_info.id,

        pos = player_info.stats[1],
        dir = player_info.stats[2],
        vel = player_info.stats[3],

        armour = player_info.stats[4],
        shield = player_info.stats[5],
        stress = player_info.stats[6],
    }

    return nice_player
end

local common
common.REQUEST_KEY      = "IDENTIFY"
common.REQUEST_UPDATE   = "SYNC_PILOTS"
common.RECEIVE_UPDATE   = "UPDATE"
common.ADD_PILOT        = "SPAWN"
common.REGISTRATION_KEY = "REGISTERED"
common.receivers = {}

--[[
--  Receive confirmation of server registration
--  REGISTERED <newname>
--]]
common.receivers[REGISTRATION_KEY] = function ( client, message )
    if message and #message == 1 then
        client.playerinfo.nick = message[1]
        print("YOU HAVE BEEN REGISTERED AS <" .. client.playerinfo.nick .. ">.")
    else
        print("FAILED TO REGISTER:")
        for k, v in pairs(message) do
            print("\t" .. tostring(k) .. ": " .. tostring(v))
        end
    end
end

--[[
--  Spawn a new pilot
--  lines are: player_id, ship_type, ship_name
--]]
common.receivers[common.ADD_PILOT] = function ( client, message )
    if #message >= 3 then
        return client.spawn( message[1], message[2], message[3] )
    else
        print("ERROR: Spawning pilot with too few parameters")
    end
end

--[[
--  Receive an update about the world state
--  each line is <player_id> <pos> <dir> <vel> <armour> <shield> <stress>
--]]
common.receivers[common.RECEIVE_UPDATE] = function ( client, message )
    local world_state = {}
    world_state.players = {}
    for _, player_line in ipairs(message) do
        local this_player = {}
        this_player.stats = {}
        -- get the player id
        this_player.id = player_line:match("%w")
        for playerstat in player_line:gmatch("%d") do
            table.insert(this_player.stats, playerstat)
        end
        table.insert(world_state.players, unmarshal(this_player))
    end

    return client.synchronize( world_state )
end

return common
