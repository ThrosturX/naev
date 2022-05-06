local hypergate = require "spob.lua.lib.hypergate"

function load( p )
   return hypergate.load( p, {
         basecol = { 0.8, 0.8, 0.2 }, -- Sirius
         cost_mod = {
            [100] = 0,
            [90]  = 0.1,
            [75]  = 0.2,
            [60]  = 0.3,
            [45]  = 0.5,
            [30]  = 0.75,
            [10]  = 0.9,
         },
      } )
end

unload   = hypergate.unload
update   = hypergate.update
render   = hypergate.render
can_land = hypergate.can_land
land     = hypergate.land
