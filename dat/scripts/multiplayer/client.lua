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

-- make sure a name is unique by adding random numbers until it is
local function shorten( name )
    local newname = name:sub(1, math.min(name:len(), 16))
    if server.players[name] then
        newname = shorten( newname .. tostring(rnd.rnd(1,999)) )
    end

    return newname
end

-- registers a player, returns the players unique ID
local function registerPlayer( playernicksuggest, shiptype)
    if server.players[playernicksuggest] then
        -- prevent double registration
          return nil
    end
    -- create a unique registration ID
    local playerID = shorten( playernicksuggest )

    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "dummy", clear_allies = true, clear_enemies = true }
    )
    local random_spawn_point = vec2.new( rnd.rnd(-4000, 4000), rnd.rnd(-6000, 6000) )
    -- spawn the pilot server-side
    if playernicksuggest == player.name() then
        server.players[playerID] = player.pilot()
    else
        server.players[playerID] = pilot.add(
            shiptype,
            mplayerfaction,
            random_spawn_point,
            playerID
            --, { naked = true }
        )
    end

    return playerID
end

-- sends a message IFF we have a defined handler to receive it
local function sendMessage( peer, key, data )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
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
            print("REGISTERED <" .. player_id .. ">")
            sendMessage( peer, common.REGISTRATION_KEY, player_id )
            return
        end
     end
    peer:send("ERROR: Unsupported operation 1.")
end

-- player wants to sync
MESSAGE_HANDLERS[common.REQUEST_UPDATE] = function ( peer, data )
    -- peer just wants an updated world state
    if #data >= 1 then
        local player_id = data[1]:match( "%w+" )
        print("player_id: " .. player_id)
        if player_id and server.players[player_id] then
            -- update pilots
            local known_pilots = {}
            for ii, opid in ipairs( data ) do
                if ii > 1 then
                    print("known: " .. tostring(opid))
                    known_pilots[opid] = true
                end
            end

            for opid, opplt in pairs( server.players ) do
                -- need to synchronize creation of a new pilot
                if not known_pilots[opid] then
                    print("syncing " .. tostring(opid))
                    local message_data = fmt.f(
                        "{opid}\n{ship_type}\n{ship_name}",
                        {
                            opid = opid,
                            ship_type = opplt:ship():nameRaw(),
                            ship_name = opplt:name(),
                        }
                    )
                    sendMessage( peer, common.ADD_PILOT, message_data )
                end
                print("client should now know about " .. tostring(opid))
            end

            -- synchronize this players info
            server.synchronize_player( data[1] )

            -- send this player the requested world state
            sendMessage( peer, common.RECEIVE_UPDATE, server.world_state )
            return
        end
    end
    peer:send( "ERROR: Unsupported operation 2." )
    for k,v in pairs(data) do
        print(tostring(k) .. ": " .. tostring(v))
    end
end

local function handleMessage ( event )
    print("Got message: ", event.data, event.peer)
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n]+") do
        print("LINE: " .. line)
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    print("MESSAGE IS A: <" .. msg_type .. ">")

    return MESSAGE_HANDLERS[msg_type]( event.peer, msg_data)
end

-- start a new listenserver
server.start = function( port )
    if not port then port = 6789 end
    server.host = enet.host_create( fmt.f( "localhost:{port}", { port = port } ) )
    server.players = {}
    -- go to multiplayer system
    player.teleport("Crimson Gauntlet")
    -- register yourself
    registerPlayer( player.name(), player:pilot():ship():nameRaw() )
    -- update world state with yourself (weird)
    server.world_state = server.refresh()

    server.hook = hook.update("MULTIPLAYER_SERVER_UPDATE")
end

-- synchronize one player update after receiving
server.synchronize_player = function( player_info_str )
    print( player_info_str )
    local ppinfo = common.unmarshal( player_info_str )
    local ppid = ppinfo.id
    print("sync player " .. ppid .. " to health " .. tostring(ppinfo.armour) )
    if ppid then
        server.players[ppid]:setPos(vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)))
        server.players[ppid]:setDir(ppinfo.dir)
        server.players[ppid]:setVel(vec2.new(tonumber(ppinfo.velx), tonumber(ppinfo.vely)))
        server.players[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
    end
end

server.refresh = function()
    local world_state = ""

    for ppid, pplt in pairs(server.players) do
        if pplt:exists() then
            local armour, shield, stress = pplt:health()
            local velx, vely = pplt:vel():get()
            local posx, posy = pplt:pos():get()
            world_state = world_state .. fmt.f("{id} {posx} {posy} {dir} {velx} {vely} {armour} {shield} {stress}\n", {
                id = ppid,
                posx = posx,
                posy = posy,
                dir = pplt:dir(),
                velx = velx,
                vely = vely,
                armour = armour,
                shield = shield,
                stress = stress
            })
        else -- it died, respawn it
            print("Warning: Player is dead: " .. tostring(ppid) )
        end
    end

    server.world_state = world_state

    return world_state
end

-- do I need to explain this?
server.update = function ()
    -- synchronize the server peer
--    server.synchronize_player ( common.marshal_me( player.name() ) )
    -- refresh our world state before updating clients
    server.refresh()

    -- handle requests from clients
    local event = server.host:service()
    if event then
        if event.type == "receive" then
            handleMessage( event )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            -- reserve an ID? nah...
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- TODO: clean up
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
    end
end

MULTIPLAYER_SERVER_UPDATE = function() return server.update() end

return server
