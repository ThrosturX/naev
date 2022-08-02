local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"

-- NOTE: This is a listen server
local server = {}
--[[
--      server.players = { player_id = pilot, ... }
--      server.world_state = { player_id = player_info, ... }
--
--      server.start()
--      server.synchronize_player( sender_info )
--      server.update()
--]]

local names = {}
-- make sure a name is unique by adding random numbers until it is
local function shorten( name )
    local newname = name:substr(1, math.min(name:len(), 16))
    if names[name] then
        newname = shorten( newname .. tostring(rnd.rnd(1,999)) )
    end

    return newname
end

-- registers a player, returns the players unique ID
local function registerPlayer( playernicksuggest, shiptype)
    if names[playernicksuggest] then
        -- prevent double registration
          return nil
    end
    -- create a unique registration ID
    local playerID = shorten( playernicksuggest )

    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "dummy", clear_allies = true, clear_enemies = true }
    )
    local random_spawn_point = vec3.new( rnd.rnd(-4000, 4000), rnd.rnd(-6000, 6000) )
    -- spawn the pilot server-side
    server.players[playerID] = pilot.add(
        shiptype,
        mplayerfaction,
        random_spawn_point,
        playerID,
        -- { naked = true }
    )

    return playerID
end

-- sends a message IFF we have a defined handler to receive it
local function sendMessage( peer, key, data )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end

    local message = fmt.f( "{key}\n{msgdata}", { key = key, data = data } )
    return peer:send( message )
end

local MESSAGE_HANDLERS = {}

-- player wants to join the server
MESSAGE_HANDLERS[common.REQUEST_KEY] = function ( peer, data )
    -- peer wants to register as <data>[1] in <data>[2]
    if data and #data == 2 then
        local player_id = registerPlayer(data[1], data[2])
        if player_id then
            -- ACK: REGISTERED <player_id>
            sendMessage( peer, common.REGISTRATION_KEY, player_id )
            return
        end
     end
    peer:send("ERROR: Unsupported operation.")
end

-- player wants to sync
MESSAGE_HANDLERS[common.REQUEST_UPDATE] = function ( peer, data )
    -- peer just wants an updated world state
    if #data >= 1 then
        local player_id = data[1]:match( "%w" )
        if player_id and names[player_id] then
            -- update pilots
            local known_pilots = {}
            for _ii, opid in ipairs( data ) do
                if ii > 1 then
                    known_pilots[opid] = true
                end
            end

            for opid, opplt in pairs( server.players ) do
                -- need to synchronize creation of a new pilot
                if not known_pilots[opid] then
                    local message_data = fmt.f( 
                        "{opid}\n{ship_type}\n{ship_name}",
                        {
                            opid = opid,
                            ship_type = opplt:ship():nameRaw(),
                            ship_name = ooplt:name(),
                        }
                    )
                    sendMessage( peer, common.ADD_PILOT, message_data )
                end
            end

            -- synchronize this players info
            server.synchronize_player( data[1] )

            -- send this player the requested world state
            sendMessage( peer, common.RECEIVE_UPDATE, server.world_state )
        end
    end
    peer:send( "ERROR: Unsupported operation." )
end

local function handleMessage ( event )
    print("Got message: ", event.data, event.peer)
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    return MESSAGE_HANDLERS[msg_type]( event.peer, msg_data)
end

-- start a new listenserver
server.start = function()
    server.host = enet.host_create("localhost:6789")
    server.players = {}
    -- TODO HERE: register yourself
    server.world_state = server.refresh()
end

-- synchronize one player update after receiving
server.synchronize_player = function( player_info_str )
    local ppinfo = common.unmarshal( player_info_str )
    local ppid = ppinfo.id
    if ppid then
        server.players[ppid]:setPos(ppinfo.pos)
        server.players[ppid]:setDir(ppinfo.dir)
        server.players[ppid]:setVel(ppinfo.vel)
        server.players[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
    end
end

server.refresh = function()
    local world_state = ""

    for ppid, pplt in pairs(server.players) do
        local armour, shield, stress = pplt:health()
        world_state = world_state .. fmt.f("{id} {pos} {dir} {vel} {armour} {shield} {stress}\n", {
            id = ppid,
            pos = pplt:pos(),
            dir = pplt:dir(),
            vel = pplt:vel(),
            armour = armour,
            shield = shield,
            stress = stress
        })
    end

    server.world_state = world_state
    
    return world_state
end

-- do I need to explain this?
server.update = function ()
    -- refresh our world state before updating clients
    server.refresh()

    -- handle requests from clients
    local event = server.host:service(100)
    while event do
        if event.type == "receive" then
            handleMessage( event )
        elseif event.type == "connect" then
            print(event.peer .. " connected.")
            -- reserve an ID? nah...
        elseif event.type == "disconnect" then
            print(event.peer .. " disconnected.")
            -- TODO: clean up
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = server.host:service()
    end
end

return server
