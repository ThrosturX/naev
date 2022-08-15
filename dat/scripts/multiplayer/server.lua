--
-- luacheck: globals MULTIPLAYER_SERVER_UPDATE (Hook functions passed by name)
local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local pilotname = require "pilotname"
local mp_equip = require "equipopt.templates.multiplayer"

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

local function random_spawn_point()
    return vec2.new( rnd.rnd(-400, 400), rnd.rnd(-800, 800) )
end

local ships = {
    "Gawain",
    "Zebra",
    "Mule",
    "Shark",
    "Koala",
    "Rhino",
--  "Cargo Shuttle",
    "Quicksilver",
    "Pirate Kestrel",
    "Goddard",
    "Dvaered Goddard",
    "Empire Hawking",
    "Za'lek Mephisto",
    "Soromid Reaver",
    "Soromid Nyx",
    "Sirius Dogma",
    "Dvaered Retribution",
    "Pirate Starbridge",
    "Starbridge",
    "Vigilance",
    "Pacifier",
    "Empire Admonisher"
}

local MAX_NPCS = 8
-- spawn an NPC
local function createNpc( shiptype )
    local count = 0
    for _a, _b in pairs(server.npcs) do
        count = count + 1
        if count >= MAX_NPCS then
            print("INFO: Canceling NPC creation, limit reached.")
            return
        end
    end
    shiptype = shiptype or ships[rnd.rnd(1, #ships)]
    local newnpc = {}
    newnpc.nick = pilotname.human():gsub(" ", "t"):gsub("'", "ek")
    server.npcs[newnpc.nick] = true
    local newfac = faction.dynAdd("Independent", "NPC" .. tostring(rnd.rnd(0,499)), "NPC", { ai="mercenary", clear_allies = true, clear_enemies = true } )
    server.players[newnpc.nick] = pilot.add(
        shiptype,
        newfac,
        random_spawn_point(),
        newnpc.nick,
        { naked = true }
--      { ai = "trader" }
--        { ai = "mercenary" }
    )
    mp_equip( server.players[newnpc.nick] )
    server.playerinfo[newnpc.nick] = {}
    pmem = server.players[newnpc.nick]:memory()
    pmem.norun = true
end

-- registers a player, returns the players unique ID
local function registerPlayer( playernicksuggest, shiptype, outfits )
    if server.players[playernicksuggest] then
        -- prevent double registration
          return nil
    end
    -- create a unique registration ID
    local playerID = shorten( playernicksuggest )

    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "remote_control", clear_allies = true, clear_enemies = true }
    )
    -- spawn the pilot server-side
    if playernicksuggest == server.hostnick then
        server.players[playerID] = player.pilot()
    else
        print("ADDING PLAYER " .. playerID )
        server.players[playerID] = pilot.add(
            shiptype,
            mplayerfaction,
            random_spawn_point(),
            playerID,
            { naked = true }
        )
        for _i, outf in ipairs(outfits) do
            server.players[playerID]:outfitAdd(outf, 1, true)
        end
        server.playerinfo[playerID] = {}
    end
    createNpc( shiptype )

    return playerID
end

-- sends a message IFF we have a defined handler to receive it
local function sendMessage( peer, key, data, reliability )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end
    reliability = reliability or "unsequenced"

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    return peer:send( message, 0, reliability )
end

local MESSAGE_HANDLERS = {}

local REGISTERED = {}
-- player wants to join the server
MESSAGE_HANDLERS[common.REQUEST_KEY] = function ( peer, data )
    -- peer wants to register as <data>[1] in <data>[2]
    if data and #data >= 2 then
        local player_id = registerPlayer(data[1], data[2], common.unmarshal_outfits(data) )
        if player_id then
            -- ACK: REGISTERED <player_id>
            print("REGISTERED <" .. player_id .. "> in a " .. tostring(data[2]))
            sendMessage( peer, common.REGISTRATION_KEY, player_id, "reliable" )
            REGISTERED[peer:index()] = player_id
            return
        end
     end
    peer:send("ERROR: This nickname is reserved, please reconnect with another name or wait until the nickname is no longer in use..")
end

-- player wants to sync
MESSAGE_HANDLERS[common.REQUEST_UPDATE] = function ( peer, data )
    -- peer just wants an updated world state
    local player_id
    if #data >= 1 then
        player_id = data[1]:match( "%w+" )
--      print("player'id: " .. player_id)
        if player_id and server.players[player_id] then
            -- update pilots
            local known_pilots = {}
            for ii, opid in ipairs( data ) do
                if ii > 1 then
--                  print("known: " .. tostring(opid))
                    known_pilots[opid] = true
                end
            end

            for opid, opplt in pairs( server.players ) do
                -- need to synchronize creation of a new pilot
                if not known_pilots[opid] then
--                  print("syncing " .. tostring(opid))
                    if opplt:exists() then
                       local message_data = fmt.f(
                           "{opid}\n{ship_type}\n{outfits}\n",
                           {
                               opid = opid,
                               ship_type = opplt:ship():nameRaw(),
                               outfits = common.marshal_outfits( opplt:outfitsList() ),
                           }
                       )
                       if server.npcs[opid] then
                           sendMessage( peer, common.ADD_NPC, message_data )
                       else
                           sendMessage( peer, common.ADD_PILOT, message_data, "reliable" )
                       end
                    else
                       -- player is dead
                    end
                end
            end

            -- synchronize this players info
            server.synchronize_player( data[1] )

            -- send this player the requested world state
            sendMessage( peer, common.RECEIVE_UPDATE, server.world_state, "unreliable" )
            return
        end
    end
    local emsg
    if not player_id then
        emsg =  "ERROR: Unsupported operation 2: Please use a valid nickname." 
    elseif not server.players[player_id] then
        emsg =  "ERROR: Unsupported operation 3: Please register before attempting to synchronize." 
        peer:disconnect()
        return
    end
    peer:send( emsg  )
    print( emsg )
    for k,v in pairs( data ) do
        print(tostring(k) .. ": " .. tostring(v))
    end
end

MESSAGE_HANDLERS[common.SEND_MESSAGE] = function ( peer, data )
    -- peer wants to broadcast <data>[1] as a message
    if data and #data >= 1 then
        local plid = REGISTERED[peer:index()]
        local message = common.SEND_MESSAGE .. '\n' .. data[1] .. '\n' .. server.players[plid]:name()
        return server.host:broadcast( message, 0, "unreliable" )
    end
end

local handled_frame = {}

local function handleMessage ( event )
--    print("Got message: ", event.data, event.peer)
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n]+") do
--        print("LINE: " .. line)
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

--    print("MESSAGE IS A: <" .. msg_type .. ">")

    if handled_frame[event.peer:index()] == msg_type then
        print( "Already handled a " .. msg_type .. " from peer " .. tostring(event.peer:index()) )
    end
    handled_frame[event.peer] = msg_type

    return MESSAGE_HANDLERS[msg_type]( event.peer, msg_data)
end

-- start a new listenserver
server.start = function( port )
    if player.isLanded() then
        return "ERROR_SERVER_LANDED"
    end
    if not port then port = 6789 end
    server.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )
    if server.host then
        server.players     = {}
        server.npcs        = {}
        server.playerinfo  = {}
        -- go to multiplayer system
        player.teleport("Somal's Ship Cemetery")
        -- register yourself
        server.hostnick = player.name():gsub(' ', '')
        registerPlayer( server.hostnick, player:pilot():ship():nameRaw() , player:pilot():outfitsList() )
        -- update world state with yourself (weird)
        server.world_state = server.refresh()

        server.hook = hook.update("MULTIPLAYER_SERVER_UPDATE")
        -- borrow client hook to update cache variables
        server.inputhook = hook.input("MULTIPLAYER_CLIENT_INPUT")
        player.pilot():setNoDeath( true )    -- keep the server running
        player.pilot():setInvincible( true ) -- keep the server running
        player.pilot():setInvisible( true )  -- keep the npcs from chasing the server
    end
end

-- synchronize one player update after receiving
server.synchronize_player = function( player_info_str )
--  print( player_info_str )
    local ppinfo = common.unmarshal( player_info_str )
    local ppid = ppinfo.id
--    print("sync player " .. ppid .. " to health " .. tostring(ppinfo.armour) )
    if ppid and server.players[ppid] and server.players[ppid]:exists() then
        -- sync direction always
        server.players[ppid]:setDir(ppinfo.dir)
        -- validation
        local dist2 = vec2.dist2(
            vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)),
            server.players[ppid]:pos()
        )
        local stats = server.players[ppid]:stats()
        local fudge = 4
        local speed2 = math.min(stats.speed_max * stats.speed_max, math.abs(ppinfo.posx + fudge * ppinfo.posy + fudge))
        if dist2 >= speed2 then
            print("WARNING: Refusing to synchronize player " .. ppid)
            server.players[ppid]:setHealth(ppinfo.armour - 1, ppinfo.shield, ppinfo.stress + 1)
            common.sync_player( ppid, ppinfo, server.players )
        end
        -- server side sync
        server.players[ppid]:setPos(vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)))
        server.players[ppid]:setVel(vec2.new(tonumber(ppinfo.velx), tonumber(ppinfo.vely)))
        server.players[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        server.playerinfo[ppid] = ppinfo
        
        common.sync_player( ppid, ppinfo, server.players )
    end


end

server.refresh = function()
    handled_frame = {}
    local world_state = ""

    for nid, _bool in pairs(server.npcs) do
        local pplt = server.players[nid]
        if pplt:exists() then
            local accel = 1
            local primary = 0
            local secondary = 0
            local target = pplt:target()
            if target then
              server.playerinfo[nid].target = target:name()
              server.playerinfo[nid].accel = rnd.rnd()
              server.playerinfo[nid].primary = rnd.rnd(0, 1)
              server.playerinfo[nid].secondary = rnd.rnd(0, 1)
            end
        else    -- spawn a new one :)
            server.npcs[nid] = nil
            createNpc()
        end
    end


    server.players[server.hostnick] = player.pilot()
    for ppid, pplt in pairs(server.players) do
        if pplt:exists() then
            local accel = 0
            local primary = 0
            local secondary = 0
            local target = server.hostnick
            if server.playerinfo[ppid] then
               if server.playerinfo[ppid].accel then
                  accel = server.playerinfo[ppid].accel
               end
               if server.playerinfo[ppid].primary then
                  primary = server.playerinfo[ppid].primary
               end
               if server.playerinfo[ppid].secondary then
                  secondary = server.playerinfo[ppid].secondary
               end
               if server.playerinfo[ppid].target then
                   target = server.playerinfo[ppid].target
                end
            end
            local armour, shield, stress = pplt:health()
            local velx, vely = pplt:vel():get()
            local posx, posy = pplt:pos():get()
            world_state = world_state .. fmt.f("{id} {posx} {posy} {dir} {velx} {vely} {armour} {shield} {stress} {accel} {primary} {secondary} {target}\n", {
                id = ppid,
                posx = posx,
                posy = posy,
                dir = pplt:dir(),
                velx = velx,
                vely = vely,
                armour = armour,
                shield = shield,
                stress = stress,
                accel = accel,
                primary = primary,
                secondary = secondary,
                target = target,
            })
        else -- it died
            print("INFO: Player is dead: " .. tostring(ppid) )
            server.players[ppid]    = nil
            server.npcs[ppid]       = nil
            server.playerinfo[ppid] = nil
        end
    end

    server.world_state = world_state

--  print("_________________")
--  print("WORLD STATE START")
--  print("~~~~~~~~~~~~~~~~~")
--  print(world_state)
--  print("_________________")
--  print("WORLD STATE  END ")
    return world_state
end

-- do I need to explain this?
server.update = function ()
    player.cinematics(
        false,
        {
            abort = _("Autonav disabled in multiplayer."),
            no2x = true,
            gui = false
        }
    )
--    player.autonavReset()
--    synchronize the server peer
--    server.synchronize_player ( common.marshal_me( player.name() ) )
    -- refresh our world state before updating clients
    server.refresh()

    -- handle requests from clients
    local event = server.host:service()
    while event do
        if event.type == "receive" then
            handleMessage( event )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            -- reserve an ID? nah...
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- clean up
            local dc_player = REGISTERED[event.peer:index()]
            if dc_player then
                if server.players[dc_player] and server.players[dc_player]:exists() then
                    server.players[dc_player]:rm()
                end
                server.players[dc_player] = nil
                REGISTERED[event.peer:index()] = nil
            end
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = server.host:service()
    end
end

MULTIPLAYER_SERVER_UPDATE = function() return server.update() end

return server
