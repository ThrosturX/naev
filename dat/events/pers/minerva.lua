local equipopt = require "equipopt"
local pir = require "common.pirate"

return function ()
   local pers = {}
   local scur = system.cur()
   local spres = scur:presences()

   if pir.systemPresence( scur ) > 300 then
      table.insert( pers, {
         spawn = function ()
            local p = pilot.add( "Pirate Kestrel", "Wild Ones", nil, _("Pink Demon"), {naked=true, ai="pers_pirate"} )
            equipopt.pirate( p, {
               type_range = {
                  ["Launcher"] = { max = 0 },
                  ["Turret Launcher"] = { max = 0 },
               }
            } )
            p:intrinsicSet( "fwd_damage", 15 )
            p:intrinsicSet( "tur_damage", 15 )
            p:intrinsicSet( "fwd_dam_as_dis", 30 )
            p:intrinsicSet( "tur_dam_as_dis", 30 )
            local m = p:memory()
            m.taunt = _("Ho ho ho and a bottle of rum!")
            m.comm_greet = _([["What are you doing here?"]])
            return p
         end,
      } )
   end

   if not player.misnDone("Kex's Freedom 3") and (spres["Dvaered"] or 0) > 100 then
      table.insert( pers, {
         spawn = function ()
            local p = pilot.add("Dvaered Goddard", "Dvaered", nil, _("Major Malik"), {naked=true, ai="pers_patrol"})
            equipopt.dvaered( p, {
               type_range = {
                  ["Beam Turret"] = { max = 0 },
                  ["Beam Cannon"] = { max = 0 },
               }
            } )
            local m = p:memory()
            m.ad = {
               _("Back in my day we walked uphill, both ways, in the snow to fight for honour!"),
               _("Kids don't know how good they have it these days!"),
               _("Nobody likes a good honour fight to the death anymore!"),
            }
            m.taunt = _("Get out of my way punk!")
            m.comm_greet = _([["Can't you see I'm busy complaining, whippersnap!"]])
            local pos = p:pos()
            local vel = p:vel()
            for i=1,4 do
               local e = pilot.add("Dvaered Vendetta", "Dvaered", pos )
               e:setVel( vel )
               e:setLeader( p )
            end
            return p
         end,
      } )
   end

   return pers
end
