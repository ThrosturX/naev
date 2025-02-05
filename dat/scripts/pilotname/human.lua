local fmt = require "format"

-- For translation, just transliterate if necessary.
local articles = {
   _("Das"),
   _("Der"),
   _("Kono"),
   _("La"),
   _("Le"),
   _("The"),
   _("Ye"),
}
local descriptors = {
   _("Aerobic"),
   _("Aku No"),
   _("Amai"),
   _("Ancient"),
   _("Astro"),
   _("Baggy"),
   _("Bakana"),
   _("Bald"),
   _("Beautiful"),
   _("Benevolent"),
   _("Bedrohliche"),
   _("Big"),
   _("Big Bad"),
   _("Bloody"),
   _("Bright"),
   _("Brooding"),
   _("BT"),
   _("Bureina"),
   _("Caped"),
   _("Citrus"),
   _("Clustered"),
   _("Cocky"),
   _("Creamy"),
   _("Crisis"),
   _("Crusty"),
   _("Dark"),
   _("Deadly"),
   _("Deathly"),
   _("Defiant"),
   _("Delicious"),
   _("Despicable"),
   _("Destructive"),
   _("Diligent"),
   _("Drunk"),
   _("Egotistical"),
   _("Electromagnetic"),
   _("Erroneous"),
   _("Escaped"),
   _("Eternal"),
   _("Evil"),
   _("Fallen"),
   _("Fearless"),
   _("Fearsome"),
   _("Filthy"),
   _("Flightless"),
   _("Flying"),
   _("Foreboding"),
   _("Fuketeru"),
   _("Full-Motion"),
   _("Furchtlose"),
   _("General"),
   _("Gigantic"),
   _("Glittery"),
   _("Glorious"),
   _("Great"),
   _("Groß"),
   _("Grumpy"),
   _("Hairy"),
   _("Hammy"),
   _("Handsome"),
   _("Happy"),
   _("Hashitteru"),
   _("Hellen"),
   _("Hen'na"),
   _("Hidoi"),
   _("Hilarious"),
   _("Hitori No"),
   _("Horrible"),
   _("IDS"),
   _("Imperial"),
   _("Impressive"),
   _("Insatiable"),
   _("Ionic"),
   p_("name", "Iron"),
   _("Justice"),
   _("Kakkowarui"),
   _("Koronderu"),
   _("Kowai"),
   _("Lesser"),
   _("Lightspeed"),
   _("Lone"),
   _("Loud"),
   _("Lovely"),
   _("Lustful"),
   _("Mächtige"),
   _("Malodorous"),
   _("Messy"),
   _("Mighty"),
   _("Mijikai"),
   _("Morbid"),
   _("Mukashi No"),
   _("Murderous"),
   _("Nai"),
   _("Naïve"),
   _("Neutron-Accelerated"),
   _("New"),
   _("Night's"),
   _("Nimble"),
   _("Ninkyōna"),
   _("No Good"),
   _("Numb"),
   _("Oishī"),
   _("Ōkina"),
   _("Old"),
   _("Oshirisu No"),
   _("Oyoideru"),
   _("Pale"),
   _("Perilous"),
   _("human's"),
   _("Pocket"),
   _("Princeless"),
   _("Psychic"),
   _("Raging"),
   _("Reclusive"),
   _("Relentless"),
   _("Rostige"),
   _("Rough"),
   _("Ruthless"),
   _("Saccharin"),
   _("Salty"),
   _("Samui"),
   _("Satanic"),
   _("Secluded"),
   _("Seltsame"),
   _("Serial"),
   _("Sharing"),
   _("Silly"),
   _("Single"),
   _("Sleepy"),
   _("Slimy"),
   _("Smelly"),
   _("Solar"),
   _("Space"),
   _("Stained"),
   _("Static"),
   _("Steel"),
   _("Strange"),
   _("Strawhat"),
   _("Sukina"),
   _("Super"),
   _("Sweaty"),
   _("Sweet"),
   _("Tall"),
   _("Takai"),
   _("Terrible"),
   _("Tired"),
   _("Toothless"),
   _("Tropical"),
   _("Tsukareteru"),
   _("Typical"),
   _("Ultimate"),
   _("Umai"),
   _("Uncombed"),
   _("Undead"),
   _("Unersättliche"),
   _("Unhealthy"),
   _("Unreal"),
   _("Unsightly"),
   _("Urusai"),
   _("Utsukushī"),
   _("Vengeful"),
   _("Very Bad"),
   p_("name", "Violent"),
   _("Warui"),
   _("Weeping"),
   _("Wild"),
   _("Winged"),
   _("Wretched"),
   _("Yaseteru"),
   _("Yasui"),
   _("Yasashī"),
   _("Yummy"),
}


local actors = {
   _("1024"),
   _("Aku"),
   _("Akuma"),
   _("Alphabet Soup"),
   _("Amigo"),
   _("Angel"),
   _("Angle Grinder"),

   _("Ari"),
   _("Arrow"),
   p_("name", "Ass"),
   _("Atama"),
   _("Aunt"),
   _("Auster"),
   _("Avenger"),
   _("Axis"),
   _("Baka"),
   _("Bakemono"),
   _("Band Saw"),
   _("Bat"),
   _("Beard"),
   _("Belt Sander"),
   _("Bench Grinder"),
   _("Bengoshi"),
   _("Black Hole"),
   _("Blarg"),
   _("Blitzschneider"),
   _("Blizzard"),
   _("Blood"),
   _("Blunder"),
   _("Boot"),
   _("Bobber"),
   _("Bolt Cutter"),
   _("Bōshi"),
   _("Brain"),
   _("Breeze"),
   _("Bride"),
   _("Brigand"),
   _("Bulk"),
   _("Burglar"),
   _("Cane"),
   _("Chainsaw"),
   _("Cheese"),
   _("Cheese Grater"),
   _("Chi"),
   _("Chicken"),
   _("Circle"),
   _("Claw"),
   _("Claw Hammer"),
   _("Club"),
   _("Coconut"),
   _("Coot"),
   _("Corsair"),
   _("Cougar"),
   _("Crisis"),
   _("Crow"),
   _("Crowbar"),
   _("Crusader"),
   _("Curse"),
   _("Cyborg"),
   _("Darkness"),
   p_("name", "Death"),
   _("Deity"),
   _("Demon"),
   _("Destruction"),
   _("Devil"),
   _("Dictator"),
   _("Disaster"),
   _("Discord"),
   _("Donkey"),
   _("Doom"),
   _("Drache"),
   _("Dragon"),
   _("Dread"),
   _("Drifter"),
   _("Drill Press"),
   _("Duckling"),
   _("Eagle"),
   _("Eggplant"),
   _("Ego"),
   _("Electricity"),
   _("Emperor"),
   _("Energy-Volt"),
   _("Engine"),
   _("Fang"),
   _("Flare"),
   _("Flash"),
   _("Fox"),
   _("Friend"),
   _("Fugitive"),
   _("Gaki"),
   _("Geschützturmdrehbank"),
   _("Giant"),
   _("Gift"),
   _("Gohan"),
   _("Goose"),
   _("Gorilla"),
   _("Gun"),
   _("Hae"),
   _("Hamburger"),
   _("Hammer"),
   _("Headache"),
   _("Hex"),
   _("Hikari"),
   _("Horobi"),
   _("Horror"),
   p_("name", "Hunter"),
   _("Husband"),
   _("Ichigo"),
   _("Id"),
   _("Impact Wrench"),
   _("Inazuma"),
   _("Ionizer"),
   _("Ishi"),
   _("Itoyōji"),
   _("Jalapeño"),
   _("Jigsaw"),
   _("Jishin"),
   _("Jinx"),
   _("Ka"),
   _("Kailan"),
   _("Kaji"),
   _("Kamakiri"),
   _("Kame"),
   _("Kami"),
   _("Kamikaze"),
   _("Kappa"),
   _("Karaoke"),
   _("Katana"),
   _("Kaze"),
   _("Keel"),
   _("Ketchup"),
   _("Killer"),
   _("Kirin"),
   _("Kitchen Knife"),
   _("Kitsune"),
   _("Kitten"),
   _("Knave"),
   _("Knife"),
   _("Knight"),
   _("Kōmori"),
   _("Kumo"),

   _("Madōshi"),
   _("Magician"),
   _("Mahō"),
   _("Maize"),
   _("Mangaka"),
   _("Mangekyō"),
   _("Mango"),
   _("Mech"),
   _("Melon"),
   _("Mind"),
   _("Model"),
   _("Monster"),
   _("Mosquito"),
   _("Moustache"),
   _("Mugi"),
   _("Nanika"),
   _("Neckbeard"),
   _("Necromancer"),
   _("Neko"),
   _("Nezumi"),
   _("Night"),
   _("Niku"),
   _("Ninja"),
   _("Niwatori"),
   _("Nova"),
   _("Ogre"),
   _("Oni"),
   _("Onion"),
   _("Osiris"),
   _("Outlaw"),
   _("Oyster"),
   _("Panther"),
   _("Paste"),
   _("Pea"),
   _("Peapod"),
   _("Peril"),
   _("Pickaxe"),
   _("Pipe Wrench"),
   _("Pitchfork"),
   _("Politician"),
   _("Potato"),
   _("Potter"),
   _("Pride"),
   _("Princess"),
   _("Pulse"),
   _("Puppy"),
   _("Python"),
   _("Raigeki"),
   _("Ramen"),
   _("Rat"),
   _("Ratte"),
   _("Ravager"),
   _("Raven"),
   _("Reaver"),
   _("Recluse"),
   _("Rice"),
   _("Ring"),
   _("River"),
   _("Roba"),
   _("Rōjin"),
   _("Rubber Mallet"),
   _("Ryū"),
   _("Sakura"),
   _("Salad"),
   _("Samurai"),
   _("Sasori"),
   _("Scythe"),
   _("Sea"),
   _("Seaweed"),
   _("Seijika"),
   _("Sentinel"),
   _("Serpent"),
   _("Shepherd"),
   _("Shinigami"),
   _("Shinobi"),
   _("Shock"),
   _("Shovel"),
   _("Shujin"),
   _("Siren"),
   _("Slayer"),
   _("Space Dog"),
   _("Spade"),
   _("Spaghetti"),
   _("Spaghetti Monster"),
   _("Spider"),
   _("Squeegee"),
   _("Staple Gun"),
   _("Stern"),
   _("Stir-fry"),
   _("Storm"),
   _("Supernova"),
   _("Surströmming"),
   _("Table Saw"),
   _("Tallman"),
   _("Tanoshimi"),
   _("Tatsumaki"),
   _("Tegami"),
   _("Teineigo"),
   _("Tenkūryū"),
   _("Terror"),
   _("Thunder"),
   _("Tomodachi"),
   _("Tooth"),
   _("Tora"),
   _("Tori"),
   _("Treasure Hunter"),
   _("Tree"),
   _("Tsuchi"),
   _("Tumbler"),
   _("Turret Lathe"),
   _("Twilight"),
   _("Tyrant"),
   _("Umi"),
   _("Urchin"),
   _("Velocity"),
   _("Vengeance"),
   _("Void"),
   _("Vomit"),
   _("Wache"),
   _("Watcher"),
   _("Wedge"),
   _("Widget"),
   _("Widow"),
   _("Wight"),
   _("Willow"),
   _("Wind"),
   _("Wizard"),
   _("Wolf"),
   _("Yakuza"),
   _("Yama"),
   _("Yami"),
   _("Yarou"),
   _("Yasai"),
   _("Yatsu"),
   _("Youma"),
   _("Zombie"),
}

local prefixes = {
	_("B'"),
	_("Be"),
	_("Ben"),
	_("Bir"),
	_("Bo"),
	_("Bon"),
	_("Bond"),
	_("D'"),
	_("De"),
	_("Do"),
	_("Dom"),
	_("Don"),
	_("Gan"),
	_("Gon"),
	_("Je"),
	_("Jen"),
	_("Jo"),
	_("Jon"),
	_("Se"),
	_("Sed"),
	_("Wan"),
	_("Wu"),
	_("z"),
	_("zi"),
	_("Ze"),
	_("Zed"),
	
}

local anchors = {
	_("A"),
	_("Anchor"),
	_("And"),
	_("Anvil"),
	_("Al"),
	_("Ash"),
	_("Bad"),
	_("Bak"),
	_("Bal"),
	_("Bald"),
	_("Bat"),
	_("Bate"),
	_("Brick"),
	_("Bronz"),
	_("Cak"),
	_("Cake"),
	_("Cell"),
	_("Celi"),
	_("Chees"),
	_("Cloud"),
	_("Cod"),
	_("Cold"),
	_("D"),
	_("Daph"),
	_("De"),
	_("Dee"),
	_("Dea"),
	_("Deal"),
	_("Duck"),
	_("Ein"),
	_("Eind"),
	_("Eine"),
	_("Eins"),
	_("Eld"),
	_("End"),
	_("Err"),
	_("Far"),
	_("Fear"),
	_("Fer"),
	_("Filth"),
	_("Fir"),
	_("Firm"),
	_("For"),
	_("Ford"),
	_("Fork"),
	_("Form"),
	_("Fort"),
	_("Fortress"),
	_("Gand"),
	_("Gerr"),
	_("Gild"),
	_("Gill"),
	_("Gist"),
	_("Git"),
	_("Gitter"),
	_("God"),
	_("Godder"),
	_("Gold"),
	_("Gott"),
	_("Gum"),
	_("Gumb"),
	_("Gund"),
	_("Gun"),
	_("Gunn"),
	_("Gyn"),
	_("Hack"),
	_("Han"),
	_("Hans"),
	_("Hat"),
	_("Hatt"),
	_("Hen"),
	_("Hend"),
	_("Hender"),
	_("Hens"),
	_("Hond"),
	_("Hoss"),
	_("Host"),
	_("Hot"),
	_("Hotten"),
	_("Hous"),
	_("Iald"),
	_("Il"),
	_("Ili"),
	_("Ill"),
	_("Illi"),
	_("In"),
	_("Ini"),
	_("Ind"),
	_("Ing"),
	_("Inn"),
	_("Int"),
	_("Iss"),
	_("Ist"),
	_("Jaram"),
	_("Jasp"),
	_("Jest"),
	_("Jerem"),
	_("John"),
	_("Kal"),
	_("Kald"),
	_("Kals"),
	_("Kalts"),
	_("Kand"),
	_("Kandest"),
	_("Kar"),
	_("Karl"),
	_("Kass"),
	_("Kat"),
	_("Katt"),
	_("Katty"),
	_("Kern"),
	_("Kerr"),
	_("Ketil"),
	_("Ketl"),
	_("Kett"),
	_("Kettel"),
	_("Kit"),
	_("Kits"),
	_("Kitt"),
	_("Kitz"),
	_("Kittz"),
	_("Kor"),
	_("Kord"),
	_("Kort"),
	_("Kott"),
	
	_("Lance"),	
	_("Lanz"),
    _("Lantern"),
    _("Law"),
    _("Lawyer"),
    _("League"),
	_("Lith"),
	_("Lord"),
	_("Loth"),
	_("Lund"),
	_("Lun"),
	_("Lunn"),
	
	
   
   _("Lust"),
	
	_("Mass"),
	_("Metal"),
	_("Meteor"),
	_("Mil"),
	_("Mild"),
	_("Mill"),
	
	_("Nickel"),
	_("Nil"),
	
	_("Old"),
	_("Olden"),
	_("Oldest"),
	_("Or"),
	_("Ord"),
	_("Orl"),
	_("Orph"),
	_("Ost"),
	
	_("Pad"),
	_("Pam"),
	_("Pan"),
	_("Panda"),
	_("Past"),
	_("Pat"),
	_("Patt"),
	_("Pax"),
	_("Pen"),
	_("Pet"),
	_("Peter"),
	_("Petter"),
	_("Pest"),
	_("Pomme"),
	_("Pond"),
	_("Pog"),
	_("Pond"),
	_("Pondif"),
	
	_("Qaas"),
	_("Qald"),
	_("Quick"),
	
	_("Rand"),
	_("Round"),
	_("Rover"),
	_("Rock"),
	
	_("Silver"),
	_("Somal"),
	_("Ston"),
	_("Straw"),
	
	_("Ton"),
	_("Thon"),
	_("Thor"),
	_("Thord"),
	_("Thun"),
	_("Thund"),
	_("Thunder"),
	
	_("Uli"),
	_("Ull"),
	_("Ullys"),
	_("Under"),
	_("Ungv"),
	
	_("Van"),
	_("Vander"),
	_("Vanst"),
	_("Ven"),
	_("Veni"),
	_("Victor"),
	_("Wan"),
	_("Wand"),
	_("Wen"),
	_("Win"),
	_("Window"),
	_("Winston"),
	_("Wu"),
	
	_("Xer"),
	_("Xi"),
	_("Xu"),
	_("Yak"),
	_("Yard"),
	_("Yell"),
	_("York"),
	_("Zak"),
	_("Zanzi"),
	_("Zell"),
	_("Zend"),
	_("Zi"),
	_("Zor"),
	
	   _("Akai"),
   _("Amarillo"),
   _("Aoi"),
   _("Azul"),
   _("Blau"),
   _("Bleu"),
   _("Blue"),
   _("Chairo No"),
   _("Crimson"),
   _("Cyan"),
   _("Gelb"),
   _("Gin'iro No"),
   _("Golden"),
   _("Gray"),
   _("Green"),
   _("Grün"),
   _("Haiiro No"),
   _("Kiiroi"),
   _("Kin'iro No"),
   _("Kuroi"),
   _("Mauve"),
   _("Midori No"),
   _("Murasaki No"),
   _("Pink"),
   _("Purple"),
   _("Red"),
   _("Roho"),
   _("Schwarz"),
   _("Shiroi"),
   _("Silver"),
   _("Violet"),
   _("Yellow"),
}

local suffixes = {
	_("'"),
	_("'k"),
	_("'s"),
	_("'t"),
	_("a"),
	_("ad"),
	_("alf"),
	_("am"),
	_("an"),
	_("bad"),
	_("be"),
	_("belt"),
	_("bon"),
	_("bone"),
	_("bolg"),
	_("dab"),
	_("dad"),
	_("daph"),
	_("ee"),
	_("en"),
	_("elia"),
	_("eliad"),
	_("elian"),
	_("elle"),
	_("emme"),
	_("enne"),
	_("er"),
	_("ess"),
	_("esson"),
	_("est"),
	_("eston"),
	_("estone"),
	_("ex"),
	_("ext"),
	_("exter"),
	_("exxy"),
	_("fed"),
	_("femme"),
	_("fen"),
	_("fenne"),
	_("fet"),
	_("fett"),
	_("git"),
	_("gitt"),
	_("gitte"),
	_("god"),
	_("got"),
	_("gott"),
	_("gotte"),
	_("ham"),
	_("iad"),
	_("ier"),
	_("ilya"),
	_("iya"),
	_("illa"),
	_("ison"),
	_("isen"),
	_("ist"),
	
	_("karl"),
	
	_("le"),
	
	_("o"),
	_("oid"),
	_("on"),
	_("otten"),
	
	_("phne"),
	
	_("man"),
	_("mann"),

	
	_("rap"),
	_("red"),
	_("ress"),
	_("roid"),
	_("sen"),
	_("ster"),
	_("ston"),
	_("stone"),
	_("son"),
	_("sus"),
	_("suz"),
	_("ter"),
	_("tt"),
	_("tty"),
	_("ton"),
	_("uzi"),
	_("zer"),
	_("zi"),
	_("zor"),
}

   local ugly_duplicates = {
		{ found="aaa", replace="a" },
		{ found="eee", replace="ee" },
		{ found="iii", replace="i" },
		{ found="ooo", replace="oo" },
		{ found="ooi", replace="oi" },
		{ found="sss", replace="ss" },
		{ found="uuu", replace="u" },
		{ found="yyy", replace="y" },
		
   }

--[[
-- @brief Generates somewhat human sounding names
--]]
local function human ()
   
   local params = {article=article, descriptor=descriptor, colour=colour, actor=actor}

   local prefix = prefixes[ rnd.rnd(1, #prefixes) ]
   local anchor = anchors[ rnd.rnd(1, #anchors) ]
   local first_name_part = anchors[ rnd.rnd(1, #anchors) ]
   local suffix = suffixes[ rnd.rnd(1, #suffixes) ]
   local suffix2 = suffixes[ rnd.rnd(1, #suffixes) ]
   
   local vowels = { "a", "e", "i", "o", "u", "y" }
   
   local vowel = vowels[rnd.rnd(1, #vowels)]
   local vowel2= vowels[rnd.rnd(1, #vowels)]
   
   local first_name_alt = fmt.f("{prefix}{suffix}", {prefix=prefixes[ rnd.rnd(1, #prefixes) ], suffix=suffixes[ rnd.rnd(1, #suffixes) ]})
   
   if rnd.rnd(0, 1) == 0 then
	first_name_part = first_name_alt
   end
   
   local params = {
		first_name_part = first_name_part,
		first_name_alt = first_name_alt,
		prefix=prefix,
		anchor=anchor,
		suffix=suffix,
		suffix2=suffix2,
		vowel=vowel,
		vowel2=vowel2,
   }
   
   local result = "Unnamed"
   local firstname = "Unknown"
   
   local r = rnd.rnd()
   if r < 0.166 then
      firstname = fmt.f(_("just"), params)
      result = fmt.f(_("{prefix}{anchor}{suffix}"), params)
   elseif r < 0.333 then
	firstname = fmt.f(_("{first_name_part}{vowel}"), params)
      result = fmt.f(_("{anchor}{suffix}"), params)
   elseif r < 0.50 then
		firstname = fmt.f(_(""), params)
      result = fmt.f(_("{first_name_part}{vowel2} {anchor}{vowel}"), params)
   elseif r < 0.666 then
	firstname = fmt.f(_("{first_name_part}"), params)
      result = fmt.f(_("{anchor}{suffix}{vowel}"), params)
   elseif r < 0.833 then
		firstname = fmt.f(_("{first_name_alt}"), params)
      result = fmt.f(_("{anchor}{vowel} {prefix}{suffix}"), params)
   else
	firstname = fmt.f(_("{prefix}{first_name_part}"), params)
      result = fmt.f(_("{anchor}{suffix}{suffix2}"), params)
   end
   

   
   -- remove ugly duplicate letters
   for found, replacement in pairs(ugly_duplicates) do
	result = string.gsub( result, found, replacement )
	firstname = string.gsub( firstname, found, replacement )
	end
   
   return result, firstname
end

return human
