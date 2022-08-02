local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"

-- converts a world_state into information about "me" and a list of players I know about
--[[
--      my_player_id <my_stats>
--      other_player_id
--      ...
--]]
local function _marshal ( players_info )
    local armour, shield, stress = player.pilot():health()
    local message = fmt.f("{id} {pos} {dir} {vel} {armour} {shield} {stress}", 
        {
            id = client.playerinfo.nick,
            pos = player.pilot():pos(),
            dir = player.pilot():dir(),
            vel = player.pilot():vel(),
            armour = armour,
            shield = shield,
            stress = stress
        }
    )
    for opid, _opplt in pairs(players_info) do
        message = message .. '\n' .. tostring(opid)
    end
    return message
end

local client = {}
--[[
--      client.host
--      client.server
--      client.playerinfo { nick, ship?, outfits... }
--
--      client.pilots = { playerid = pilot, ... }
--
--      client.start()
--      client.synchronize( world_state )
--      client.update()
--]]

local function receiveMessage( message )
    local msg_type
    local msg_data = {}
    for line in message:gmatch("[^\n]+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    return common.receivers[msg_type]( client, msg_data )
end

-- we are about to connect to a server, so we will disable client-side NPC
-- spawning for the sake of consistency
client.start = function( target )
    client.host = enet.host_create()
    client.server = host:connect( target )
    client.playerinfo = { nick = player.name(), ship = player.pilot():ship():nameRaw() }
    client.pilots = {}
    pilot.clear()
    pilot.toggleSpawn(false)
    player.takeoff()
    hook.timer(1, "enterMultiplayer")
end

local MY_SPAWN_POINT = vec3.new( rnd.rnd(-2000, 2000), rnd.rnd(-2000, 2000) )
-- TODO: Support outfits
client.spawn = function( playerid, shiptype, shipname )
    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "dummy", clear_allies = true, clear_enemies = true } 
    )
    if not clients.pilots[ppid] then
        clients.pilots[ppid] = pilot.add(
            shiptype,
            mplayerfaction,
            MY_SPAWN_POINT,
            shipname,
            { naked = true }
        )
        print("created pilot for " .. tostring(playerid))
    else
        print("WARNING: Trying to add already existing pilot: " .. tostring(playerid))
    end
end

client.synchronize = function( world_state )
    -- synchronize pilots
    for ppid, ppinfo in pairs(world_state.players) do
        if clients.pilots[ppid] then
            client.pilots[ppid]:setPos(ppinfo.pos)
            client.pilots[ppid]:setDir(ppinfo.dir)
            client.pilots[ppid]:setVel(ppinfo.vel)
            client.pilots[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        else
            print(fmt.f("WARNING: Updating unknown pilot <{id}>", ppinfo))
        end
    end

end

client.update = function()
    -- tell the server what we know and ask for resync
    client.server:send( common.REQUEST_UPDATE, _marshal( client.pilots ) )
    --
    -- get updates
    local event = host:service(100)
    while event do
        if event.type == "receive" then
            print("Got message: ", event.data, event.peer)
            -- update world state or whatever the server asks
            receiveMessage( event.data )
        elseif event.type == "connect" then
            print(event.peer .. " connected.")
            -- register with the server
            event.peer:send( common.REQUEST_KEY .. '\n' .. client.playerinfo.nick )
        elseif event.type == "disconnect" then
            print(event.peer .. " disconnected.")
            -- TODO: cleanup
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = client.host:service()
    end
end

function enterMultiplayer()
    player.teleport("Crimson Gauntlet")
    -- register with the server
    client.server:send(
        fmt.f(
            "{key}\n{nick}\n{ship}",
            key = common.REQUEST_KEY,
            nick = client.playerinfo.nick,
            ship = client.playerinfo.ship
        )
    )
    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
end

MULTIPLAYER_CLIENT_UPDATE = function() return client.update() end

return client
