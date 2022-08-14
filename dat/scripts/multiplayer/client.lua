-- luacheck: globals MULTIPLAYER_CLIENT_UPDATE MULTIPLAYER_CLIENT_INPUT enterMultiplayer reconnect  (Hook functions passed by name)

local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local mp_equip = require "equipopt.templates.multiplayer"
-- require "factions.equip.generic"

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

-- converts a world_state into information about "me" and a list of players I know about
--[[
--      my_player_id <my_stats>
--      other_player_id
--      ...
--]]

local function _marshal ( players_info )
    local cache = naev.cache()
    local message = common.marshal_me(client.playerinfo.nick, cache.accel, cache.primary, cache.secondary)
    for opid, _opplt in pairs(players_info) do
        message = message .. '\n' .. tostring(opid)
    end
    return message .. '\n'
end

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

--    print("CLIENT RECEIVES: " .. msg_type )
    if common.receivers[msg_type] then
        return common.receivers[msg_type]( client, msg_data )
    else
        player.pilot():broadcast( msg_type )
        return
    end
end

-- we are about to connect to a server, so we will disable client-side NPC
-- spawning for the sake of consistency
client.start = function( bindaddr, bindport, localport )
    if not localport then localport = rnd.rnd(1234,6788) end
    if not player.isLanded() then
        return "PLAYER_NOT_LANDED"
    end

    client.host = enet.host_create("*:" .. tostring(localport))
    if not client.host then
        return "NO_CLIENT_HOST"
    end
    client.conaddr = bindaddr
    client.conport = bindport
    client.server = client.host:connect( fmt.f("{addr}:{port}", { addr = bindaddr, port = bindport } ) )
    if not client.server then
        return "NO_CLIENT_SERVER"
    end
    -- WE ARE GOING IN
    player.allowSave ( false )  -- no saving or landing for now
    player.allowLand ( false, _("Multiplayer prevents landing.") )
    client.pilots = {}
    pilot.clear()
    pilot.toggleSpawn(false)
    -- give the player a new ship
    local ship_choices_large = {
        "Kestrel",
        "Hawking",
        "Goddard",
        "Dvaered Retribution",
        "Empire Rainmaker",
        "Pirate Rhino",
        "Dvaered Arsenal",
        "Za'lek Mammon"
    }
    local ship_choices_small = {
        "Shark",
        "Empire Shark",
        "Gawain",
        "Pirate Rhino",
        "Dvaered Ancestor",
        "Quicksilver",
        "Pirate Shark",
        "Zebra" -- lol
    }
    local ship_choices = ship_choices_small
    local player_ship = ship_choices[ rnd.rnd(1, #ship_choices) ]
    local mpshiplabel = "MULTIPLAYER SHIP"
    local mplayership = player.addShip(player_ship, mpshiplabel, "Multiplayer", true)
    player.swapShip( mpshiplabel, false, false )
    mp_equip( player.pilot() )

    -- send the player off
    player.takeoff()
    hook.timer(1, "enterMultiplayer")
    -- some consistency stuff
    naev.keyEnable( "speed", false )
    naev.keyEnable( "weapset1", false )
    naev.keyEnable( "weapset2", false )
    naev.keyEnable( "weapset3", false )
    naev.keyEnable( "weapset4", false )
    naev.keyEnable( "weapset5", false )
    naev.keyEnable( "weapset6", false )
    naev.keyEnable( "weapset7", false )
--  naev.keyEnable( "weapset8", false ) -- shield booster
--  naev.keyEnable( "weapset9", false ) -- afterburner, that's fine
    naev.keyEnable( "weapset0", false )
    player.cinematics(
        true,
        {
            abort = _("Entering multiplayer..."),
            no2x = true,
            gui = false
        }
    )
    -- configure the playerinfo for multiplayer
    client.playerinfo = {
        nick = player.name():gsub(' ', ''),
        ship = player_ship,
        outfits = common.marshal_outfits(player.pilot():outfits())
    }
end

local MY_SPAWN_POINT = player.pilot():pos()
client.spawn = function( ppid, shiptype, shipname , outfits, ai )
    --[[
    ai = ai or "remote_control"
    if ai ~= "remote_control" then
        client.npcs[ppid] = true
    end
    --]]
    ai = "remote_control"
    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = ai, clear_allies = true, clear_enemies = true } 
    )
    if not client.pilots[ppid] and ppid ~= client.playerinfo.nick then
        client.pilots[ppid] = pilot.add(
            shiptype,
            mplayerfaction,
            MY_SPAWN_POINT,
            shipname,
            { naked = true }
        )
        for _i, outf in ipairs(outfits) do
            client.pilots[ppid]:outfitAdd(outf, 1, true)
        end
        pmem = client.pilots[ppid]:memory()
        pmem.comm_no = _("NOTICE: Staying in chat will get you killed or disconnected. Caveat user!")
        print("created pilot for " .. tostring(ppid))
    elseif ppid == client.playerinfo.nick then
        client.pilots[ppid] = player.pilot()
    else
        print("WARNING: Trying to add already existing pilot: " .. tostring(ppid))
    end
end

local RESYNC_INTERVAL = 64 + rnd.rnd(36, 72)
local last_resync
client.synchronize = function( world_state )
    -- synchronize pilots
    local resync
    if not last_resync or last_resync >= RESYNC_INTERVAL then
        resync = true
--      print("resync " .. tostring(last_resync))
        last_resync = 0
    end
    last_resync = last_resync + 1
    for ppid, ppinfo in pairs(world_state.players) do
        if ppid ~= client.playerinfo.nick then
            if client.pilots[ppid] then
                local this_pilot = client.pilots[ppid]
                local target = ppinfo.target or "NO TARGET!!"
                if target and client.pilots[ target ] then
                    client.pilots[ppid]:setTarget( client.pilots[target] )
                else
                    client.pilots[ppid]:setTarget( player.pilot() )
                end
                local pdiff = vec2.add( this_pilot:pos() , -ppinfo.posx, -ppinfo.posy ):mod()
                if resync and pdiff > 6 then
                    client.pilots[ppid]:setPos(vec2.new(ppinfo.posx, ppinfo.posy))
                    client.pilots[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
                elseif pdiff > 8 then
                    last_resync = last_resync * pdiff
--                  client.pilots[ppid]:effectAdd("Wormhole Exit", 0.2)
                end
                if resync and ppinfo.accel and pdiff > 8 then
                    -- apply minor velocity prediction
                    local stats = this_pilot:stats()
                    local angle = vec2.newP(0, ppinfo.dir)
                    local acceleration = stats.thrust / stats.mass
                    local dv = vec2.mul(angle, acceleration)
                    local rtt = client.server:round_trip_time()
                    local pdv = vec2.new(
                        ppinfo.velx, ppinfo.vely
                    ) + dv * last_resync / 60
                    client.pilots[ppid]:setVel(pdv)
                elseif math.abs(ppinfo.velx * ppinfo.vely) < 1 then
                    -- ensure low-speed fidelity
                    client.pilots[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
                end
                client.pilots[ppid]:setDir(ppinfo.dir)
                client.pilots[ppid]:setHealth(
                    math.min(100, ppinfo.armour + 15),
                    math.max( rnd.rnd(0, 2), ppinfo.shield ),
                    ppinfo.stress
                )
                pilot.taskClear( client.pilots[ppid] )
                if ppinfo.weapset then
                    -- this is really laggy I think
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SWITCH_WEAPSET", ppinfo.weapset )
                end
                if ppinfo.primary == 1 then
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SHOOT", false )
                    if target and client.pilots[ target ] and client.pilots[target] == player.pilot() then
                        client.pilots[ppid]:setHostile()
                    end
                end
                if ppinfo.secondary == 1 then
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SHOOT", true )
                    if target and client.pilots[ target ] and client.pilots[target] == player.pilot() then
                        client.pilots[ppid]:setHostile()
                    end
                end
                if ppinfo.accel then
                    local anum = tonumber(ppinfo.accel)
                    if anum == 1 then
                        pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_ACCEL", 1 )
                    else -- if resync then
                        pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_ACCEL", 0 )
                    end
                end
            else
                print(fmt.f("WARNING: Updating unknown pilot <{id}>", ppinfo), ppid)
            end
        else    -- if we want to sync self from server, do it here
            local ppme = player.pilot()
            local pdiff = vec2.add( ppme:pos() , -ppinfo.posx, -ppinfo.posy ):mod()
            if pdiff > 128 or ( rsync and pdiff >= 48 ) then
                ppme:setPos( vec2.new(ppinfo.posx, ppinfo.posy) )
                ppme:effectAdd("Paralyzing Plasma", 1)
            end
            -- don't override direction
            -- ppme:setVel( vec2.new(ppinfo.velx, ppinfo.vely) )
            -- ppme:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        end
    end

end

local function tryRegister( nick )
    client.server:send(
        fmt.f(
            "{key}\n{nick}\n{ship}\n{outfits}\n",
            {
                key = common.REQUEST_KEY,
                nick = nick,
                ship = client.playerinfo.ship,
                outfits = client.playerinfo.outfits,
            }
        )
    )
end

client.update = function( timeout )
    timeout = timeout or 0
    player.cinematics(
        false,
        {
            abort = _("Autonav disabled in multiplayer."),
            no2x = true,
            gui = true
        }
    )
--    player.autonavReset()
    -- check what we think that we know about others
    for cpid, cpplt in pairs(client.pilots) do
        if not cpplt or not cpplt:exists() then
            client.pilots[cpid] = nil
        end
    end
    
    -- get any updates
    local func = function( tt ) return client.host:service( tt ) end
    local success, event = pcall( func, timeout )
    if not success then
        print('HOST ERROR:' .. event)
        return
    end
    while event do 
        if event.type == "receive" then
--            print("Got message: ", event.data, event.peer)
            -- update world state or whatever the server asks
            receiveMessage( event.data )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            player.pilot():setPos( vec2.new( 0, 0 ) )
            -- register with the server
            tryRegister( client.playerinfo.nick )
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- try to reconnect
            hook.rm(client.hook)
            hook.timer(6, "reconnect")
            return -- deal with the rest later
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = client.host:service()
    end
    
    -- tell the server what we know and ask for next resync
    client.server:send( common.REQUEST_UPDATE .. '\n' .. _marshal( client.pilots ) )
end

function reconnect()
    client.server = client.host:connect( fmt.f("{addr}:{port}", { addr = client.conaddr, port = client.conport } ) )
 
    tryRegister( client.playerinfo.nick )

    client.update( 4000 )
    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
end

function enterMultiplayer()
    player.teleport("Somal's Ship Cemetery")
    -- register with the server
    tryRegister( client.playerinfo.nick )

    client.update( 4000 )
    
    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
    client.inputhook = hook.input("MULTIPLAYER_CLIENT_INPUT")
end

local MP_INPUT_HANDLERS = {}

MP_INPUT_HANDLERS.accel = function ( press )
--  print("accel " .. tostring(press))
    if press then 
        naev.cache().accel = 1
    else
        naev.cache().accel = 0
    end
end

MP_INPUT_HANDLERS.primary = function ( press )
--  print("primary " .. tostring(press))
    if press then 
        naev.cache().primary = 1
    else
        naev.cache().primary = 0
    end
end

MP_INPUT_HANDLERS.secondary = function ( press )
--    print("secondary " .. tostring(press))
    if press then 
        naev.cache().secondary = 1
    else
        naev.cache().secondary = 0
    end
end

local hail_pressed
MP_INPUT_HANDLERS.hail = function ( press )
    player.commClose()
    if press then
        hail_pressed = true
    elseif hail_pressed then
        message = tk.input("COMMUNICATION", 0, 32, "Broadcast:")
        if message and message:len() > 0 then
            client.server:send( common.SEND_MESSAGE .. '\n' .. message )
        end
    end
    if not player.pilot():target() then
        last_resync = 300
    end
end

MULTIPLAYER_CLIENT_UPDATE = function() return client.update() end
function MULTIPLAYER_CLIENT_INPUT ( inputname, inputpress, args)
    if MP_INPUT_HANDLERS[inputname] then
        MP_INPUT_HANDLERS[inputname]( inputpress, args )
    end
end

return client
