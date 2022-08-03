--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Multiplayer Handler">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[

   Multiplayer Event

   This event runs constantly in the background and manages MULTIPLAYER!!!
--]]
local mplayerclient = require "multiplayer.client"
local mplayerserver = require "multiplayer.server"
-- luacheck: globals load (Hook functions passed by name)

function create ()
    hook.load("load")
end

local serverbtn
local clientbtn


local function startMultiplayerServer()
    -- NOTE: can put a custom port here as arg
    mplayerserver.start()

    -- you are a server now, stay like that!
    player.infoButtonUnregister( serverbtn )
    player.infoButtonUnregister( clientbtn )
end

local function connectMultiplayer()
    local target = nil
    --[[
    local hostname = tk.input("Connect", 3, 32, "HOSTNAME")
    local hostport = tk.input("Connect", 3, 32, "PORT")

    local target = hostname .. ":" .. hostport

    --]]
    -- for testing
    if not target then
        target = "localhost:6789"
    end

    if target then
        mplayerclient.start( target )
        -- sorry user, restart game to reconnect
        player.infoButtonUnregister( serverbtn )
        player.infoButtonUnregister( clientbtn )
    end
end

function load()
	serverbtn = player.infoButtonRegister( _("Start MP Server"), startMultiplayerServer, 3)
	clientbtn = player.infoButtonRegister( _("Connect Multiplayer"), connectMultiplayer, 3)
end
