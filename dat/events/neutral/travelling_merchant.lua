--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Travelling Merchant">
 <location>enter</location>
 <chance>5</chance>
 <cond>require("common.pirate").systemPresence() &gt; 100 and system.cur():presence("Independent") &gt; 100 and player.credits() >= 1e6 and not system.cur():tags().restricted</cond>
</event>
--]]
--[[

   Travelling Merchant Event

Spawns a travelling merchant that can sell the player if interested.

--]]
local vn = require 'vn'
local love_shaders = require 'love_shaders'
local der = require "common.derelict"

local p, broadcastid, hailed_player, timerdelay -- Non-persistent state

local trader_name = _("Machiavellian Misi") -- Mireia Sibeko
local trader_image = "misi.png"
local trader_colour = {1, 0.3, 1}
local store_name = _("Machiavellian Misi's \"Fine\" Wares")
local broadcastmsg = {
   _("Machiavellian Misi's the name and selling fine shit is my game! Come get your outfits here!"),
   _("Get your fiiiiiiiine outfits here! Guaranteed 3 space lice or less or your money back!"),
   _("Recommended by the Emperor's pet iguana's third cousin! High quality outfits sold here!"),
   _("Best outfits in the universe! So freaking good that 50% of my clients lose their hair from joy!"),
   _("Sweeet sweet space outfits! Muaha hahaha ha ha ha erk…"),
   _("…and that's how I was able to get a third liver haha. Oops is this on? Er, nevermind that. Outfits for sale!"),
}

-- luacheck: globals board broadcast hail leave (Hook functions passed by name)
-- TODO boarding VN stuff should allow talking to Misi and such.

function create ()
   local scur = system.cur()

   -- Inclusive claim
   if not evt.claim( scur, nil, true ) then evt.finish() end

   -- Check to see if a nearby spob is inhabited
   local function nearby_spob( pos )
      for _k,pk in ipairs(scur:spobs()) do
         if pk:services().inhabited and pos:dist( pk:pos() ) < 1000 then
            return true
         end
      end
      return false
   end

   -- Find uninhabited planet
   local planets = {}
   for _k,pk in ipairs(scur:spobs()) do
      -- TODO add check to make sure no inhabited spob is nearby
      if not pk:services().inhabited and not nearby_spob( pk:pos() ) then
         table.insert( planets, pk )
      end
   end
   local spawn_pos
   if #planets==0 then
      -- Try to find something not near any inhabited planets
      local rad = scur:radius()
      local tries = 0
      while tries < 30 do
         local pos = vec2.newP( rnd.rnd(0,rad*0.5), rnd.angle() )
         if not nearby_spob( pos ) then
            spawn_pos = pos
            break
         end
         tries = tries + 1
      end
      -- Failed to find anything
      if not spawn_pos then
         evt.finish()
      end
   else
      local pnt = planets[rnd.rnd(1,#planets)]
      spawn_pos = pnt:pos() + vec2.newP( pnt:radius()+100*rnd.rnd(), rnd.angle() )
   end

   local fctmisi = faction.exists("fmisi")
   if not fctmisi then
      fctmisi = faction.dynAdd( "Independent", "fmisi", _("???"),
            {clear_enemies=true, clear_allies=true} )
   end

   -- Create pilot
   p = pilot.add( "Mule", fctmisi, spawn_pos, trader_name )
   p:setFriendly()
   p:setInvincible()
   p:setVisplayer()
   p:setHilight(true)
   p:setActiveBoard(true)
   p:control()
   p:brake()

   -- Set up hooks
   timerdelay = 5
   broadcastid = 1
   broadcastmsg = rnd.permutation( broadcastmsg )
   hook.timer( timerdelay, "broadcast" )
   hailed_player = false
   hook.pilot( p, "hail", "hail" )
   hook.pilot( p, "board", "board" )

   hook.jumpout("leave")
   hook.land("leave")
end

--event ends on player leaving the system or landing
function leave ()
    evt.finish()
end

function broadcast ()
   -- End the event if for any reason the trader stops existing
   if not p:exists() then
      evt.finish()
      return
   end

   -- Cycle through broadcasts
   if broadcastid > #broadcastmsg then broadcastid = 1 end
   p:broadcast( broadcastmsg[broadcastid], true )
   broadcastid = broadcastid+1
   timerdelay = timerdelay * 2
   hook.timer( timerdelay, "broadcast" )

   if not hailed_player and not var.peek('travelling_trader_hailed') then
      p:hailPlayer()
      hailed_player = true
   end
end

function hail ()
   if not var.peek('travelling_trader_hailed') then
      vn.clear()
      vn.scene()
      local mm = vn.newCharacter( trader_name,
         { image=trader_image, color=trader_colour, shader=love_shaders.hologram() } )
      vn.transition("electric")
      mm:say( _('"Howdy Human! Er, I mean, Greetings! If you want to take a look at my wonderful, exquisite, propitious, meretricious, effulgent, … wait, what was I talking about? Oh yes, please come see my wares on my ship. You are welcome to board anytime!"') )
      vn.done("electric")
      vn.run()

      var.push('travelling_trader_hailed', true)
      player.commClose()
   end
end

function board ()
   -- Boarding sound
   der.sfx.board:play()

   vn.clear()
   vn.scene()
   vn.transition()
   vn.na( _("You open the airlock and are immediately greeted by an intense humidity and heat, almost like a jungle. As you advance through the dimly lit ship you can see all types of mold and plants crowing in crevices in the wall. Wait, was that a small animal scurrying around? Eventually you reach the cargo hold that has been re-adapted as a sort of bazaar. It is a mess of different wares and most don't seem of much value, there might be some interesting find.") )
   vn.run()

   --[[
      Ideas
   * Vampiric weapon that removes shield regen, but regenerates shield by doing damage.
   * Hot-dog launcher (for sale after Reynir mission): does no damage, but has decent knockback and unique effect
   * Money launcher: does fairly good damage, but runs mainly on credits instead of energy
   * Mask of many faces: outfit that changes bonuses based on the dominant faction of the system you are in (needs event to handle changing outfit)
   * Weapon that does double damage to the user if misses
   * Weapon that damages the user each time it is shot (some percent only)
   * Space mines! AOE damage that affects everyone, but they don't move (useful for missions too!)
   --]]

   -- Always available outfits
   -- TODO add more
   local outfits = {
      'Air Freshener',
      'Valkyrie Beam',
      'Hades Torch',
   }

   -- TODO add randomly chosen outfits, maybe conditioned on the current system or something?

   -- Give mission rewards the player might not have for a reason
   local mission_rewards = {
      { "Drinking Aristocrat",      "Swamp Bombing" },
      { "The Last Detail",          "Sandwich Holder" },
      { "Prince",                   "Ugly Statue" },
      { "Destroy the FLF base!",    "Star of Valor" },
      { "Nebula Satellite",         "Satellite Mock-up" },
      { "The one with the Runaway", "Toy Drone" },
      { "Deliver Love",             "Love Letter" },
      --{ "Racing Skills 2",          "Racing Trophy" }, -- This is redoable so no need to give it again
      { "Operation Cold Metal",     "Left Boot" },
      { "Black Cat",                "Black Cat Doll" },
      { "Terraforming Antlejos 10", "Commemorative Stein" },
   }
   local event_rewards = {
   }
   -- Special case: this mission has multiple endings, and only one gives the reward.
   if var.peek( "flfbase_intro" ) == nil and var.peek( "invasion_time" ) == nil then
      table.insert( mission_rewards, { "Disrupt a Dvaered Patrol", "Pentagram of Valor" } )
   end
   for i,r in ipairs(mission_rewards) do
      local m = r[1]
      local o = r[2]
      if player.misnDone(m) and player.numOutfit(o)<1 then
         table.insert( outfits, o )
      end
   end
   for i,r in ipairs(event_rewards) do
      local e = r[1]
      local o = r[2]
      if player.evtDone(e) and player.numOutfit(o)<1 then
         table.insert( outfits, o )
      end
   end

   -- Start the merchant and unboard.
   tk.merchantOutfit( store_name, outfits )
   player.unboard()

   -- Boarding sound
   der.sfx.unboard:play()
end
