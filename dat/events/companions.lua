--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Companion Handler4">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[

   Crewmate Handler Event

   This event runs constantly in the background and manages crewmates
   hired from the bar, including generating NPCs at the bar and managing
   crewmate conversation and behavior in space.

   TODO NOTES:
   
   - Missing tutorials and info about the following:
    * the crew wants stuff like food and water, so ideally you keep a few tons of food in your cargo
	* opening crates has hidden fees (restocking fruit)
	* salaries are paid when you land and eventually crew salaries
		synchronize if you don't land for many jumps
	* only the hired crew members that fit on the ship are "active" and usable
		-> this doesn't apply to officers and champions (aka crew that can do stuff)
	* a first officer can shuffle crew members (actually just moves
		rookies and low cadets near the back)
	* some types are incompatible (the characters will complain about it)
	* some types have limits (the characters will complain about it)
	* some types need bays to function (you can't have a guy launch a
		shark from a shark, but if you have 2 hyena bays already, sure...)
    * some crew refuse to work with others, but you can hire them in
		"the wrong order" to force them to work together
	* some crew have the same function as another but at a different price,
		and the salary is dependent on stats when hired, which are trainable,
		so it's actually a good idea to hire cheap crew and train it
	* a first officer acts like a normal manager at a bar, it's not until you're out
		in the lawlessness of space and jurisdiction of your own ship that you can
		finally do cool things. Same for the smuggler.
	* speaking of which -- the first officer can do some cool stuff
		that isn't explained anywhere like rename crew or throw out of airlock
		
	More TODO:
	- Promotion path from lieutenant to officer
	- ship_interior.facilities {} that can something like:
		- botanical	- produces 1 food every 30 periods or something
		- training	- converts crew satisfaction to xp?
		- some kind of research facilities, maybe gives upgrades to sensors or something
		- specialized facilities that consume a commodity to achieve some effect (e.g. ore + diamond = 100 hp armor)
			-> these ones would be meant for mining ships, or ships that can at least access materials easily
--]]
local der = require "common.derelict"
local fmt = require "format"
local portrait = require "portrait"
local pir = require "common.pirate"
local pilotname = require "pilotname"
local vntk = require "vntk"
local vn = require "vn"
local laudio       = require 'love.audio'
local luaspfx     = require "luaspfx"
local graphics = require 'love.graphics'

local lang = require "language.language"

local npcs  -- Non-persistent state
local infobtn -- "talk to commander" button on info screen
local logidstr = "log_shipcompanion"

-- this is a good place for easter eggs
local FAKE_CAPTAIN = {
	["name"] = player.name(),
	["article_subject"] = _("the captain"),
	["article_object"] = _("the captain"),
	["firstname"] = player.name(),
	["chatter"] = rnd.rnd(),
	-- need a minimal conversation table to be able to pass the fake captain around and create memories as if it was a real character
	["conversation"] = {
		["good_talker"] = { "{name} is doing a good job." },
		["bad_talker"] = { "{name} stands out from the bunch." },
		["topics_liked"] = { [tostring(player.pilot():ship())] = {_("She's a beauty, isn't she?") } },
		["topics_disliked"] = { _("salary"), _("credits") },
	},
	["satisfaction"] = 0,
	["xp"] = 0,
}
local mothership
mem.conversation_hook = nil
mem.ship_interior = {
	["dirt"] = 0,
	["dirt_accum"] = 0,
	["officers"] = {},
	["bay_strength"] = 0,
}

-- default crew limits
local START_CREW_LIMITS = {
	[_("Medical Officer")] = 0,
	[_("Engineer")] = 1,
	[_("Science")] = 1,
	[_("Rookie")] = 10,
	[_("Cadet")] = 6,
	[_("Ensign")] = 8,
	[_("Lieutenant")] = 1,
	[_("Pilot")] = -1, -- can't have any, needs to earn 2 to get the first one
}

mem.crew_limits = START_CREW_LIMITS

-- hooks for special ability crew (champions)
local entries = {
    ["demoman"] = function(speaker)
        return hook.board("player_boarding_c4", speaker)
    end,
    ["escort"] = function(speaker)
        return hook.land("escort_landing", "land", speaker)
    end,
	["smuggler"] = function(speaker)
		return hook.info("smuggle_cargo", "cargo", speaker)
	end,
	["engihull"] = function(speaker)
		return hook.timer(300, "engineer_armour", speaker)
	end,
	["engishld"] = function(speaker)
		return hook.timer(300, "engineer_shield", speaker)
	end,
	["engipowr"] = function(speaker)
		return hook.timer(300, "engineer_power", speaker)
	end,
	["command"] = function(speaker)
		return hook.timer(20, "commander_button", speaker)
	end,
}

-- prices of things we charge for that aren't commodities
local prices = {
    ["equipment"] = 15
}

-- TODO: I wonder what happens if a Pilot/Shuttle manager is promoted to officer here?
-- gets any officer, but prefers whichever has a pilot or a shuttle
local function getCommander()
	local candidate
	for _i, worker in ipairs(mem.companions) do
		if not candidate and string.find(worker.skill, _("Officer")) then
			candidate = worker -- could be this guy
		elseif string.find(worker.skill, _("First Officer")) then
			candidate = worker -- likely this guy
		end
		-- it's probably this guy
		if worker.pilot and string.find(worker.skill, _("Officer")) then
			return worker
		end
		
		-- almost definitely want this guy
		if candidate and candidate.shuttle then
			return candidate
		end
	end
	
	return candidate
end

-- transmits a message to the "internal ship comm" if it's open
local function _comm(speaker, message)
	if mothership == player.ship() then
		pilot.comm(speaker, message)
	else
		-- ugh, we need to find the commander that's piloting our ship
		for _i, worker in ipairs(mem.companions) do
			-- it's probably this guy
			if worker.pilot and worker.manager  and worker.pilot:exists() then
				print(fmt.f("intercepted comm from {name}: <{msg}>", {name = speaker, msg = message } ))
				local name = worker.pilot:name()
				worker.pilot:rename(speaker)
				worker.pilot:comm(message)
				worker.pilot:rename(name)
				return
			end
		end
	end
end

local function playMoney()
	local sfx = laudio.newSource( 'snd/sounds/jingles/money.ogg' )
	luaspfx.sfx( false, nil, sfx )
end

-- merges (overwrites) a template table t1 with data from t2
local function merge_tables(t1, t2)
    for k, v in pairs(t2) do
        t1[k] = v
    end

    return t1
end

-- appends t2 to the back of t1
local function append_table(t1, t2)
    for _i, v in ipairs(t2) do
        table.insert(t1, v)
    end

    return t1
end

-- creates a copy of t1 and t2 joined together
local function join_tables(t1, t2)
	local copy = {}
	for _i, v in ipairs(t1) do
        table.insert(copy, v)
    end
    for _i, v in ipairs(t2) do
        table.insert(copy, v)
    end

    return copy
end

-- pick a random item from the collection
local function pick_one(target)
    local r = rnd.rnd(1, #target)
    return target[r]
end

-- for every item in target, roll a 6-die and discard if less than factor (or 3)
local function pick_some(target, factor)
	factor = factor or 3
	local some = {}
	for _i, thing in ipairs(target) do
		if rnd.rnd(0, 6) >= factor then
			table.insert(some, thing)
		end
	end
	
	-- if we removed everything, we become savants instead
	if #some == 0 then
		return target
	end
	
	return some
end

-- pick a random key from a mapping
local function pick_key(mapping)
    local keys = {}
    for key, _value in pairs(mapping) do
        table.insert(keys, key)
    end

    local chosen_key = pick_one(keys)

    return chosen_key
end

-- picks out a list nested in a table that uses keys instead of numeric indexing
-- used on the conversation object
-- e.g. in topic -> "faith"
-- or    special -> "laugh"
local function pick_map(maptable)
    -- as per example above, "pick the topic"
    local chosen_key = pick_key(maptable)
    -- pick out the list that we can choose from
    local chosen_value = maptable[chosen_key]
    return chosen_value
end

-- picks one element out of a list that is nested inside a table
-- used on the conversation object
-- e.g. in topic -> "faith" -> picks one of phrases
-- or    special -> "laugh" -> picks one of laughters
local function pick_from_map(maptable)
    -- pick one out of the chosen list
    local choices = pick_map(maptable)
    return pick_one(choices)
end

-- pick a random letter out of a string
local function pick_str(str)
    local ii = rnd.rnd(1, str:len()) -- pick a random index from string length
    return string.sub(str, ii, ii) -- returns letter at ii
end

-- pick a random word out of a string
local function pick_word(str)
	local words = {}
	for word in str:gmatch("%w+") do
		table.insert(words, word)
	end
	return pick_one(words)
end

-- sanitize a phrase before it gets compared with a lot of words
local function sanitize_phrase(phrase)
	-- blacklist some very basic and common words for the random word picker
	local blacklist = {
		_("a"),
		_("is"),
		_("was"),
		_("I"),
		_("quite"),
		_("nice"),
		_("your"),
		_("that"),
		_("this"),
		_("my"),
		_("his"),
		_("her"),
		_("about"),
		_("to"),
		_("the"),
		_("their"),
	}
	local result
	for word in phrase:gmatch("%w+") do
		local keep = true
		for _i, banned in ipairs(blacklist) do
			if word == banned then
				keep = false
			end
		end
		if keep then
			if result then
				result = result .. " " .. word
			else
				result = word
			end
		end
	end

	return result
end

-- returns something that looks like the subject
-- or a random word from the phrase
local function extract_keyword(phrase)	
	-- let's just be lazy and find some articles without even checking the casing
	-- who knows how this gets lost in translation, but the idea is:
	-- find the subject of the phrase or an important key word
	local articles = {
		_("your"),
		_("that"),
		_("this"),
		_("my"),
		_("his"),
		_("her"),
		_("about"),
		_("to"),
		_("the"),
		_("their"),
	}

	for _, article in ipairs(articles) do
		local match = string.match(phrase, " " ..article .. " ([a-zA-Z]+)")
		if match then
			-- since we're being lazy and inefficient... we could check if it's an adjective and go one word further...
--			print("found match", match, phrase)
			return match
		end
	end
	
--	print("found no match in", phrase)

	return pick_word(sanitize_phrase(phrase))
end

-- parses a commodity from request
-- TODO: get better, search in nearby systems etc
local function parseCommodity( request )
-- right now we only understand standard commodities	
	for _i, standard in ipairs(commodity.getStandard()) do
		for word in request:gmatch("%w+") do
			-- is this a standard commodity?	
			if string.find(word:lower(), standard:name():lower()) then
				return standard
			end
		end
	end
	
	return nil -- nothing found
end

-- returns the outfit if it exists or nil
local function getShuttleOutfit(requested)
	if not requested then return nil end
	requested = requested:lower()
	local candidate
	for _, oo in ipairs(outfit.getAll()) do
		if string.find(oo:nameRaw():lower(), requested) then
			if
				-- fit the one with the shorter name, so if the player types
				-- "Ion Cannon", don't try to fit a "Heavy Ion Cannon"
				not candidate
				or (
					oo:nameRaw():len() < candidate:nameRaw():len()
				)
			then
				candidate = oo
			end
		end
	end
	
	-- make sure we can allow the player to fit this (must own one)
	if candidate and player.numOutfit(candidate:name(), true) < 1 then
		return nil
	else -- we take one from the player's stock? but we already charge for it...
		-- player.outfitRm(candidate:name(), 1) -- let's not
	end
	
	return candidate
end

-- remove the direct uplink to the commander on deck
local function clearCommanderInterface()
	if infobtn then
      player.infoButtonUnregister( infobtn )
      infobtn = nil
	end
	if mem.hail_hook then
		hook.rm(mem.hail_hook)
		mem.hail_hook = nil
	end
end

-- add a commander on deck, to the bridge and ready to communicate with the captain
local function addCommanderInterface()
	clearCommanderInterface()
	infobtn = player.infoButtonRegister( _("Discuss Command"), startCommandDiscussion, 2, "D" ) -- "Hotkey: Discuss"
	mem.hail_hook = hook.input( "hail_hook" )
end

-- checks what crewmates are actually on board and returns one of them or nil if none found
local function getCrewmateOnboard()
	local lind = math.min(#mem.companions, player.pilot():stats()["crew"])
	for ii, worker in ipairs(mem.companions) do
		if ii < lind then
			-- if this worker is "away", move to the back
			if worker.away then
				mem.companions[ii] = mem.companions[lind]
				mem.companions[lind] = worker
				lind = lind - 1
			end
		end
	end

	-- we found at least one present crewmate, pick one
	if lind > 0 then
		return mem.companions[rnd.rnd(1, lind)]
	end

	return nil
end

-- for adding a special kind of speech into an utterance
local function add_special(speaker, kind)
    local specials = speaker.conversation.special
    if not specials then
        return ""
    end
    local choice = pick_key(specials)
    if kind and specials[kind] then
        choice = kind
    end
    -- we have something like "laugh" and need to get the list inside
    local options = specials[choice]

    return pick_one(options)
end

local function getSpaceThing()
    -- just a bunch of things that you could find out in space
    return pick_one(lang.nouns.objects.space)
end

-- gets a random ship or possibly an alternative
local function getRandomShip()
    local ships = ship.getAll()

	-- minor sanitation
    local candidate = string.gsub(string.gsub(pick_one(ships):name(), "Drone \\(", ""), "\\)", "")

    -- don't allow thurion or proteron ships or outposts
    if string.find(candidate, "Thuri") or string.find(candidate, "Proter") or string.find(candidate, "Outpost") then
        -- give it some interesting choices along with some standard ones
        candidate = getSpaceThing()
    end

    return candidate
end

-- gets a random outfit
local function getRandomOutfit()
    local outfits = outfit.getAll()
    return pick_one(outfits):name()
end

-- generates a short, made-up capitalized Noun with limited imagination, usually 2-3 syllables or around 7 letters
local function getMadeUpName()
    -- bias some letters to introduce slight consistency for a little depth
    local start = "BCCDDDFGGHJKKLMMNNPPRRRSTTVWX"
    local middle = string.lower(start)
    local vowel = "aeiouy"

    local middle_part = pick_str(middle) .. pick_str(middle)
    if rnd.rnd(0, 1) == 1 then
        -- add an extra syllable
        middle_part = middle_part .. pick_str(vowel) .. pick_str(middle)
        -- maybe add an extra letter
        if rnd.rnd(0, 1) == 0 then
            middle_part = middle_part .. pick_str(middle)
        end
    end

    -- something like Gartok or Termengix or whatever
    return pick_str(start) .. pick_str(vowel) .. middle_part .. pick_str(vowel) .. pick_str(middle)
end

-- a picks a random "fruit", or a made up fruit name
local function getRandomFruit()
	-- must end with an s in plural in English, at least how it's being used now
	local fruits = join_tables(lang.nouns.food.fruit, {
		getMadeUpName():lower(), -- a made up food with a made up name
		-- a made up nut that the player might think is a testicle for comedic effect
		getMadeUpName() .. _(" nut"),
		-- some fairly unappealing foods to try to get the player to discard stuff sometimes for the side effects
		_("synthetic food"),
		_("insect block"),
		_("cricket crisp"),
	})
	
	return pick_one(fruits)
end

-- TODO: if we have facilities on this ship, list those
-- generates a shipboard activity, loosely based on the ship that's being flown
local function getShipboardActivity( activity_type )
	local activities = {}
	-- basic activities: "I'm going to go <do/for [some]> <activity>"
	activities.basic = {
		_("exercise"),
		_("maintenance"),
		_("sanitation"),
		_("inspection"),
		_("thing"),
		_("hydration"),
		_("research"),
		_("science"),
		_("inventory"),
		_("project"),
		_("assignment"),
		fmt.f(_("{fruit} restocking"), { fruit = getRandomFruit() } ),
		fmt.f(_("{fruit} tallying"), { fruit = getRandomFruit() } ),
	}
	-- anyone wanna play some <game>?
	activities.game = join_tables(lang.nouns.activities.games, {
		getMadeUpName(),
		_("squash")
	})
	if player.pilot():ship():size()  > 4 then
	-- these are "places to go" on the cruiser or larger where you go to do some cool activity
		activities.cruiser = lang.nouns.facilities.cruiser
	end
	if not activity_type then
		activity_type = pick_key(activities)
	elseif not activities[activity_type] then
		activity_type = "basic"
	end
	local choices = activities[activity_type]
	return pick_one(choices)
end

-- returns some kind of statement describing an insulting proper noun
-- i.e. something you would say about a ship or person that's in disorder
local function getInsultingProperNoun()
    -- things that you can put in the structured syntax and get away with
    -- "smelly smelly momma's boy sniffer" is a perfectly good insult, for instance
    -- as would be "dortetak jarryk Gorkok lebbeler!" because who knows where this person gets their insults from
    local adject2s = {
        _("smelly"),
        _("dirty"),
        _("rusty"),
        _("dated"),
        _("faded"),
        _("outdated"),
        _("expired"),
        _("deprecated"),
        _("overappreciated"),
        _("rotten"),
        _("slow,"), -- that comma is not a typo! it's for the emphasis on the slowness, like a person would do
        _("untrustworthy"),
        _("thieving"),
        _("tiny"),
        _("fat"),
        _("ugly"),
        _("insane"),
        _("senile"),
        _("angry"),
        _("dubious"),
        _("insufferable"),
        _("devious"),
        _("repugnant"),
        getMadeUpName():lower()
    }
    local adjectives = {
        _("old"),
        _("boring"),
        _("inglorious"),
        _("irrational"),
        _("stupid"),
        _("daft"),
        _("thick"),
        _("little"),
        _("demoralizing"),
        _("bloody"),
        _("blue"),
        _("boring"),
        _("ugly"),
        _("fat"),
        _("juice thirsty"),
        _("thirsty"),
        _("bloodthirsty"),
        _("insufferable"),
        getMadeUpName():lower()
    }
    local nouns = {
        _("momma's boy"),
        _("demon"),
        _("angel"),
        _("ass"),
        _("donkey"),
        _("butt"),
        _("fool"),
        _("mouth breather"),
        _("daddy's little angel"),
        _("terrorist"),
        _("violator"),
        _("jerk"),
        _("hat"),
        _("hat stand"),
        _("coat rack"),
        _("miner"),
        _("scientamologist"), -- an idiot saying "scientist" or someone being sarcastic to one
        _("cargo container"),
        _("hyena"),
        _("brick"),
        _("satan"),
        _("shit"),
        _("bucket"),
        _("square"),
        _("child"),
        _("dinosaur"),
        _("mule"),
        _("rhinoceros"),
        _("kangaroo"),
        _("bear"),
        _("sunken dream"),
        _("pirate"), -- insane boring pirate killer... sure, why not!
        _("prawn"),
        _("lobster"),
        _("dishwasher"),
        _("planet"),
        _("seed"),
        _("weed"),
        _("seaweed"),
        _("paper"),
        _("asteroid"),
        _("cinderblock"),
        _("clock"),
        _("hammock"),
        _("rock"),
        _("sock"),
        _("wrench"),
        _("document"),
        getMadeUpName()
    }
    -- these all get the '-er' suffix and don't have to be real, they are used by angry people who say strange things
    local verbs = {
        _("sniff"),
        _("smell"),
        _("lov"),
        _("eat"),
        _("lick"),
        _("huff"),
        _("idoliz"),
        _("smok"),
        _("slay"),
        _("crav"),
        _("sympathiz"),
        _("glorializ"),
        _("slay"),
        _("slay"),
        _("munch"),
        _("slap"),
        _("spit"),
        _("lurk"),
        _("fil"), -- lol, you FILER! LOL'd at IRL for real.
        _("kiss"),
        _("kill"),
        getMadeUpName():lower()
    }

    local params = {}
    params.noun = pick_one(nouns)
    params.adjective = pick_one(adjectives)
    params.adject2 = pick_one(adject2s)
    params.verb = pick_one(verbs)
    local r = rnd.uniform()
    if r < 0.33 then
        return fmt.f("{adjective} {noun}", params)
    elseif r < 0.5 then
        return fmt.f("{noun}", params)
    elseif r < 0.66 then
        return fmt.f("{adject2} {adjective} {noun}", params)
    elseif r < 0.88 then
        return fmt.f("{adjective} {noun} {verb}er", params)
    else
        return fmt.f("{adject2} {adjective} {noun} {verb}er", params)
    end
end

-- generate some random things, then picks one out of the hat or
-- (rarely) the name of the category it is from (could be funny)
local function getRandomThing()
    local things = {
        ["ship"] = getRandomShip(),
        -- TODO: generate these...
        ["item"] = pick_one(
            {
                "leather jacket",
                "vintage coat",
                "elegant design", -- okay, not really an item... but still
                "abstract holosculpture",
                "virtual death simulator",
                "synthetic snakeskin applicator",
                "high-quality lip stick",
                "white elephant",
                "red herring",
                "classic video game",
                "optical combustion device",
                "synthetic aquarium",
                "animal figurine",
                "paper plane",
                "telepathically controlled camera drone",
                "baseball bat",
                "baseball hat",
                "basketball",
                "wicker basket",
                "trojan",
                "sock puppet",
                "social network simulator",
                "vintage hand egg",
                "fictional literature",
                "device",
                "gadget",
                "hand-held",
                "portable",
                "Ultra 3000",
                "Neo 7000",
                "0K Elite Edition cup chiller",
                "wholesome book",
                "digital archive",
                "toy",
                "puppet",
                "sock"
            }
        ),
		["anything"] = pick_one(lang.getAll(lang.nouns)),
        ["outfit"] = getRandomOutfit(),
        ["thingymabob"] = pick_one(getMadeUpName()),
        ["spacething"] = getSpaceThing(),
		["fruit"] = getRandomFruit(),
        ["whatever"] = pick_one(getMadeUpName()),
    }
    for key, thing in pairs(things) do
        if rnd.rnd() < 0.22 then
            return thing
        end
        -- interesting alternatives to orthotox flow
        if rnd.rnd() > 0.967 then
            return key
        end
    end

    return "thing"
end

-- generates a generic bar action like "thinking about a drink" or "ready to get back to some food"
local function getBarSituation(character_sheet)
    local bar_actions = {
        {
            ["verb"] = pick_one(
                {
                    _("swirling"),
                    _("sipping"),
                    _("drinking"),
                    _("enjoying"),
                    _("nursing"),
                    _("nursing on")
                }
            ),
            ["descriptor"] = pick_one(
                {
                    _("a"),
                    _("a"),
                    _("some"),
                    _("some kind of")
                }
            ),
            ["adjective"] = pick_one(
                {
                    _("nice"),
                    _("strange"),
                    _("hot"),
                    _("cold"),
                    _("chilled"),
                    _("colourful"),
                    _("warm")
                }
            ),
            ["object"] = pick_one(
                {
                    _("drink"),
                    _("wine"),
                    _("tea"),
                    _("concoction"),
                    _("elixir"),
                    _("mixture of fluids"),
                    _("beverage")
                }
            )
        },
        {
            ["verb"] = pick_one(
                {
                    _("thinking"),
                    _("pondering"),
                    _("wondering"),
                    _("having feelings")
                }
            ),
            ["descriptor"] = pick_one(
                {
                    _("about some"),
                    _("about a"),
                    _("about that")
                }
            ),
            ["adjective"] = pick_one(
                {
                    _("nice"),
                    _("strange"),
                    _("shady"),
                    _("cold"),
                    _("eerie"),
                    _("colourful"),
                    _("distracting")
                }
            ),
            ["object"] = pick_one(
                {
                    _("drink"),
                    _("person"),
                    _("sculpture"),
                    _("plant"),
                    _("piece of machinery"),
                    _("bartender"),
                    _("smell")
                }
            )
        },
        {
            ["verb"] = pick_one(
                {
                    _("looking"),
                    _("peering"),
                    _("squinting"),
                    _("eyeing")
                }
            ),
            ["descriptor"] = pick_one(
                {
                    _("at"),
                    _("towards"),
                    _("in the direction of"),
                    _("vaguely towards")
                }
            ),
            ["adjective"] = pick_one(
                {
                    _("some"),
                    _("a"),
                    _("a mysterious"),
                    _("an unsuspicious"),
                    _("a suspicious looking"),
                    _("an anonymous"),
                    _("another")
                }
            ),
            ["object"] = pick_one(
                {
                    _("drink"),
                    _("patron"),
                    _("person"),
                    _("corner"),
                    _("stranger"),
                    _("crowd"),
                    _("group")
                }
            )
        },
        {
            -- an irregular one that adds anxiety to the crew
            ["verb"] = pick_one(
                {
                    _("anxious"),
                    _("desperate"),
                    _("poised"),
                    _("ready")
                }
            ),
            ["descriptor"] = _("to"),
            ["adjective"] = pick_one(
                {
                    _("get back to"),
                    _("return to"),
                    _("retreat to"),
                    _("abscond with")
                }
            ),
            ["object"] = pick_one(
                {
                    _("the ship"),
                    _("a drink"),
                    fmt.f(_("the {ship}"), {ship = player.pilot():name()}),
                    _("some food")
                }
            )
        }
    }
    if character_sheet and character_sheet.conversation and character_sheet.conversation.bar_actions then
        bar_actions = join_tables(bar_actions, character_sheet.conversation.bar_actions)
    end
	
    local chosen_action = pick_one(bar_actions)
    local doing = fmt.f(_("{verb} {descriptor} {adjective} {object}"), chosen_action)
    return doing
end

-- returns an evaluation score of this item determining how much satisfaction it will give us to consume
-- or a base score to evaluate receipt on
local function evaluate_item( character, item )
	-- we "probably" like this a bit
	local favor = 2 * rnd.rnd() + rnd.twosigma() * 0.4 + 0.12
	for _, liked in ipairs(character.preferences.liked) do
		if string.find(item, liked) then
			favor = favor + rnd.rnd()
		end
	end
	for _, disliked in ipairs(character.preferences.disliked) do
		if string.find(item, disliked) then
			favor = favor - rnd.rnd() * 3
		end
	end
	
	print(fmt.f("evaluate_item {name} scores {item} at {evaluation}.", { name = character.name, item = item, evaluation = favor }))
	return favor
end

-- returns an approximate evaluation score of this item
-- like evaluate_item but a bit careless and depends on the mood
local function evaluate_item_haste ( character, item ) 

	local favor = rnd.threesigma() * 0.3
	if character.satisfaction < 0 then
		-- we are negative
		-- assuming we don't like the item that much but expecting to like something
		favor = favor - rnd.rnd() * 0.2
		for _, liked in ipairs(pick_some(character.preferences.liked)) do
			if string.find(item, liked) then
				favor = favor + rnd.rnd()
			end
		end
	else
		-- we are positive
		-- assuming we like the item and hope that it doesn't disappoint
		favor = favor + rnd.rnd() + 1
		for _, disliked in ipairs(pick_some(character.preferences.disliked)) do
			if string.find(item, disliked) then
				favor = favor - rnd.rnd() * 2
			end
		end	
	end
	
	print(fmt.f("evaluate_item_haste {name} scores {item} at {evaluation}.", { name = character.name, item = item, evaluation = favor }))
	return favor
end

-- the character sheet pp is possibly affected by phrase, changing the article of thought
-- has some small potential for garbled thought, which is absolutely fine... if everything goes to plan
local function sentimentalize( pp, phrase )
	-- control for preventing execution
	-- this might be expensive, so let's not always execute the logic
	if math.abs(rnd.threesigma()) < 2.6 then
		-- "most of the time, we quit early"
		return
	end
	
	-- calculate how much we listen and how much we like/dislike
	local sentiment_cutoff = 10 * pp.chatter + math.abs(pp.satisfaction)
	local sentiment_score = 0
	local captured_attractor
	local captured_disguster
	local last
	local saved
	-- okay, the fun begins, lets see if this sentiment attracts our attention
	for word in phrase:gmatch("%w+") do
		if math.abs(sentiment_score) < sentiment_cutoff then
			for _i, found in ipairs(pp.preferences.liked) do
				sentiment_score = sentiment_score + 1
				-- we like something!! check if its a noun
				for _j, noun in ipairs(lang.getAll(lang.nouns)) do
					if string.match(noun, word) then
						captured_attractor = noun
						if last then saved = last end
					end
				end
			end
			for _i, found in ipairs(pp.preferences.disliked) do
				sentiment_score = sentiment_score / 2 - 1
				-- we hate something!! check if its a noun
				for _j, noun in ipairs(lang.getAll(lang.nouns)) do
					if string.match(noun, word) then
						captured_disguster = noun
						if last then saved = last end
					end
				end
			end
		end
		last = word
	end
	
	if sentiment_score > -1 and sentiment_score < 1 then
		-- we didn't really care about this, don't change our thoughts at all
		return
	end
	
	-- more likely to think about the thing we didn't like if there is one
	if sentiment_score < 1 then
		captured_attractor = captured_disguster or captured_attractor
	end
	
	-- common edge case, we said something like "noun was adjective", then it's the last word
	if not saved then saved = last end
	
	-- check if we saved an adjective to adorn our noun with
	if saved then
		for _i, adj in ipairs(lang.getAll(lang.adjectives)) do
			if string.find(adj, saved) then
				captured_attractor = saved .. " " .. captured_attractor
			end
		end
	end
	
	-- we have a calculated sentiment, let's not waste it since we are being sentimental
	pp.satisfaction = pp.satisfaction + sentiment_score / (math.abs(sentiment_score) + math.min(16, pp.xp))
	
	-- update our thoughts if we had one
	pp.article_of_thought = captured_attractor or pp.article_of_thought
end

-- makes sure our sentiments haven't just been cleared before inserting one
-- increases xp a little bit too because we tried to remember something
local function insert_sentiment(character, sentiment)
    if not character.conversation.sentiments then
        character.conversation.sentiments = {}
    end

	-- see if we can take a noun from this sentiment and be thinking about it
	sentimentalize(character, sentiment)
	
    table.insert(character.conversation.sentiments, sentiment)
	character.xp = math.min(100, character.xp + 0.006)
end

-- creates a memory of a certain kind, or a random memory
local function create_memory(character, memory_type, params)
    local topic = "random"
    local new_memory
    if memory_type == "gift" then
		-- we format about ourselves unless the item belongs to someone else (params)
		if not params then params = character end
		-- we were given an item that we appreciated receiving
		-- must have an item on hand!
		local choices = {
			_("I really liked that {item}."),
			_("Did I ever tell you about the {item} I got?"),
			_("I liked that {item}."),
			_("I want more {item}s."),
			_("I like {item}s."),
			_("That {item} was exactly what I needed."),
			_("I love a good {item}."),
			_("Can I have another {item}?"),
			_("Where can I get a {item}?"),
			_("Where can I get another {item}?"),
			_("How do we get {item}s?"),
			_("How do we get more {item}s?"),
			_("Where did we get those {item}s?"),
		}
		new_memory = pick_one(choices)
		
		-- memory READY, extra code here to strengthen it, plug into fatigue conversation
		
		-- since we are creating an (expectedly positive) memory,
		-- we should reminisce about this when we are fatigued
		-- but only if it's a food, otherwise we'll want a random fruit
		-- TODO: factor this logic out to extract a noun descriptor (e.g. letter <of recommendation>)
		local extracted_noun
		
		for _i, noun in ipairs(lang.getAll(lang.nouns.food)) do
			if (
				not extracted_noun 
				or noun:len() > extracted_noun:len()
			) and string.find(character.item, noun)
			then
				extracted_noun = noun
			end
		end
		
		if not extracted_noun then
			extracted_noun = getRandomFruit()
		end
		
		local desires = {
			_("I really want a {item}."),
			_("I'd love a {item} right about now."),
			_("I've got the urge to eat a {item}."),
			_("I want to eat some {item}s"),
			_("I would eat a {item} now if I could, seriously."),
			_("Man, would I love a {item}."),
			_("Where can I get {item}s?"),
			_("I need some {item}s."),
			_("Where did we get those {item}s?"),
			_("Can you hook me up with another one of those {item}s?"),
			_("I want more {item}s."),
			_("How do we get {item}s?"),
			_("How do we get more {item}s?"),
			_("No {item}s..."),
			_("Where are all the {item}s?"),
			_("Where are the {item}s?"),
			_("Where is my {item}?"),
		}		
		
		table.insert(character.conversation.fatigue, fmt.f(pick_one(desires), {item = extracted_noun} ))
		
	elseif memory_type == "payoff" then
        -- simple case, we got paid, this is a credits memory
        topic = "credits"
        local choices = {
            _("I made {credits} on one of my trips to {planet}."),
            _("I made {credits} on our voyage through {system}."),
            _("I'd like to go to {planet} again sometime.")
        }
        new_memory = pick_one(choices)
    elseif memory_type == "specific" then
        -- we are just learning how to say a new sentence, which should be in our params
        -- NOTE: This isn't even being used yet
        new_memory = params.specific or tostring(params)
    elseif memory_type == "underpaid" then
	    topic = pick_one({"credits", "business", _("the captain"), player.name()})
        local choices = {
            _("The captain didn't calculate my salary correctly."),
            fmt.f(_("{name} didn't calculate my salary correctly."), {name  = player.name() }),
           _("The captain paid me the wrong salary."),
            fmt.f(_("{name} didn't pay me my full salary."), {name  = player.name() }),
            _("My salary wasn't calculated correctly."),
			_("I didn't get my full salary."),
			_("The captain makes a lot of mistakes when it comes to calculations.")
        }
		new_memory = pick_one(choices)
	elseif memory_type == "friend" then
		-- real quick, make sure we're not memorizing about ourselves
		if character == params then
			print(fmt.f("{name} tried to create a self-memory, but we don't know what to do with those yet", character))
			return
		end
        -- learn about the friend by fetching info from params, which must be a character sheet
        -- hopefully these will become catalysts for further conversation
        local actions = {
            _("I witnessed {name} "),
            _("I was with {name} while {article_subject} was "),
            _("Was {name} really "),
            _("I saw {name} "),
			_("{name}? I saw {article_object} "),
            _("I noticed that {name} was ")
        }
        local when = {
            _(" earlier."),
            _(" the other day."),
            _(" at the bar."),
            _(" in the break room."),
            _(" some time ago."),
            _(" recently."),
            _(", but it feels like ages ago.")
        }
        local choices = {
            -- some random memories from the bar
            pick_one(actions) .. getBarSituation(params) .. pick_one(when),
            pick_one(actions) .. getBarSituation(params) .. pick_one(when) .. " " .. add_special(character),
            add_special(character) .. " " .. pick_one(actions) .. getBarSituation(params) .. pick_one(when),
            -- remembering that they like some topic (or dislike)
            pick_one(actions) ..
                "talking a lot about things like the err " .. pick_key(params.conversation.topics_liked) .. " or whatever.",
            pick_one(actions) .. "talking about the um " .. pick_key(params.conversation.topics_liked) .. " or whatever.",
            pick_one(actions) ..
                "expressing concern when the conversation was focused on " ..
                     pick_one(params.conversation.topics_disliked) .. ".",
            pick_one(actions) ..
                "expressing concern when the conversation was focused on " ..
                    pick_one(params.conversation.topics_disliked) .. pick_one(when),
            -- remembering that we had a special moment in this solar system
            fmt.f(_("{name} and I had a special moment in {system}."), {name = params.firstname, system = system.cur()}),
            fmt.f(_("I had a nice time with {name} in {system}."), {name = params.name, system = system.cur()})
        }
        local choice = pick_one(choices)
        -- if we're asking a question, let's fix the punctuation real quick
        if string.find(choice, "Was") then
            choice = string.gsub(choice, "%.", "?", 1)
        end

        topic = "friends"
        new_memory = choice
    elseif memory_type == "animosity" then
        -- generate a short insulting phrase
        local starts = {
            "{name}?",
            _("{name}? That"),
            _("That"),
            _("Oh that"),
            _("I should tell you that {name} is nothing but a")
        }
        -- make sure we have a name
        local name = params.name or getMadeUpName()
        local start = fmt.f(pick_one(starts), name)
        local insult = getInsultingProperNoun()
        local punctuation =
            pick_one(
            {
                ".",
                "!",
                "...",
                "!!",
                _("- *sigh*."),
                _(". Yeah. I said it.")
            }
        )
		
		if params.topic then
				topic = params.topic
				local topicsss = tostring(string.gsub(topic, "s+$", ""))
				punctuation = fmt.f(_(" always blabbers about {topic}s."), { topic = topicsss })
		else
			-- this is an aggressive thought, let's classify it as violence
			topic = "violence"
		end
		new_memory = fmt.f("{start} {insult}{punctuation}", {start = start, insult = insult, punctuation = punctuation})
		
    elseif memory_type == "violence" then
        -- this is a violence memory, let's classify it as such
        topic = "violence"
        -- we destroyed a ship, a few generic options, a few specific options,
        -- and a couple of "wow, we sure do a lot of <param>"
        local choices = {
            -- insanity
            _("Do you remember that {ship} we got in {system}? It had {credits} in it."),
            _("Man, that {ship}. I still keep thinking about it."),
            _("That {target} never stood a chance."),
            _("Do you remember that {target} we got in {system}? It had {credits} in it."),
            _("Do you remember the {ship}?"),
            _("Do you remember that {target}?"),
            _("Do you remember the {ship}}? The one with {credits} in it."),
            _("I still keep thinking about that {ship} we got in {system}.")
        }
        -- if we got lots of credits
        if params.cred_amt > 25e3 then
            -- wow, that's a lot, actually let's overwrite the default choices
            if params.cred_amt > 187e3 then
                choices = {
                    _("I'll never forget that {ship} in {system}."),
                    _("{credits} is a lot of credits."),
                    _("{system} is actually one of my favourite places to visit."),
					_("{system} is actually one of my favourite places to visit. If you want to know why, I'd tell you to ask a certain {target}, but I'm afraid that's impossible now. Bless the rich bastard."),
                    _(
                        "My favourite ship to board is the {ship}. Well, I can have many favourites, but that's a top contender for sure."
                    ),
                    _("That {target} never stood a chance."),
                    _("That {target} was in the wrong neighborhood, that's for sure."),
                    _("That I don't know what a {ship} like that was doing in {system} with {credits} on board."),
                    _("I still can't stop thinking about that {ship}!")
                }
                -- small chance of a memorable event
                if character.last_kill and character.last_kill == params.ship then
                    table.insert(
                        choices,
                        "{ship} are incredibly lucrative targets! We got a hundreds of thousand from just a few of them!"
                    )
                end
                -- more likely to mention it in a generic manner soon
                insert_sentiment(character, fmt.f(pick_one(choices), params))
                -- this was a lot of credits, this is now a memory about the credits
                topic = pick_one({"credits", "business"})
            end
            -- okay, so if it was a lot we'll still have some other choices, but let's add everything here that's "decent"
            table.insert(choices, _("I like getting big bounties."))
            table.insert(choices, _("Does anyone want to travel to {system} and pray for some credits?"))
            if params.cred_amt > 50e3 then
                table.insert(choices, _("We should hunt more {ship}s."))
                table.insert(choices, _("We should keep hunting {ship}s."))
                table.insert(choices, _("That {ship} we got once had {credits} in it."))
                table.insert(choices, _("Maybe we should go back to {system} to find more {ship}s."))
                table.insert(choices, _("I think we should take a little visit to {system}."))
                -- if we just killed something like this
                if character.last_kill and character.last_kill == params.ship then
                    table.insert(choices, _("We sure like to go after those {ship}s."))
                    table.insert(choices, _("I feel like we are always hunting {ship}s."))
                    table.insert(choices, _("I feel like the only ships we bother with anymore are {ship}s."))
                    table.insert(
                        choices,
                        fmt.f(
                            _("That {ship} was nothing but a {spacething} and its captain a {spacefool}."),
                            {ship = params.ship, spacething = getSpaceThing(), spacefool = getInsultingProperNoun()}
                        )
                    )
                end
                -- let's remember this kill more than usual
                character.last_kill = params.ship
                insert_sentiment(character, fmt.f(pick_one(choices), params))
            end
            -- hopefully we'll get a chance to talk about this, maybe multiple times
            insert_sentiment(character, fmt.f(pick_one(choices), params))
            -- the above is a wrapper that makes sure the table exists, it definitely exists now, don't use the wrapper
            table.insert(character.conversation.sentiments, fmt.f(pick_one(choices), params))
            table.insert(character.conversation.sentiments, fmt.f(pick_one(choices), params))
        end

        new_memory = pick_one(choices)
    elseif memory_type == "hysteria" then
        -- we're having a nervous breakdown and are about to have an unreal experience
        local choices = {
            _("Man, what a {ship}, that {target} was a complete waste of {credits}. Am I right?"),
            add_special(character) .. " " .. getMadeUpName() .. " " .. add_special(character, "laugh"),
            add_special(character) .. "... " .. add_special(character) .. "... " .. add_special(character),
            getMadeUpName() .. " " .. getMadeUpName() .. " " .. add_special(character),
            _("Why are we traveling to {system} again? I'd much rather go to {ship}."),
            _("Can't you see it out there? Tell me you can see it? You can see it can't you?"),
            _("Tell me you just saw that, I'm not the only one that just saw that, right?"),
            _("{target}na{target} {ship}ra{target} {system}{ship}{system}da..."),
            _("Why does this say our armour is at {armour} percent? These are percentages right?"),
            _("Why does this say our armour is at {armour} percent? Is that right?"),
            _("Why does this say our armour is at {armour} percent?"),
            -- scary thoughts
            _("This is all too real. I want to go home."),
            _("Sometimes I regret signing up for this."),
            _("I didn't sign up for this."),
            _("When did I sign up for this?"),
            _([[This isn't what I meant when I said "hang my hat"...]]),
            _(
                "Sometimes I can't get the thought out of my head... It's just this thin piece of hull between us and nothingness for distances so vast you can't even realistically imagine."
            ),
            -- aggressive ramblings and antisocial tendencies develop
            _("Don't you look at me like that! Don't do it!"),
            _("Hey, watch it!"),
            _("I saw that."),
            _("I know you're about to bring it up, I see that look in your eyes, quit it!"),
            _("Are you looking at me?"),
            _("Maybe all the violence has been getting to me."),
            _("Maybe all the violence is starting to get to me."),
            -- poignant moment such as remembering an old friend or having a epiphany
            fmt.f(_("I miss that rascal {name}. A true friendship never really ends."), {name = pilotname.human()}),
            fmt.f(_("I used to have a friend called {name}."), {name = pilotname.human()}),
            fmt.f(_("I miss my old friend {name}."), {name = getMadeUpName()}),
            _("You know, the best ship is friendship."),
            _(
                "I used to dream of sailing on a pirate ship as a child. Unfortunately, we don't live in that kind of fairy tale world. I did my time on a pirate ship in space, but I realized that what I really wanted was to feel the salty sea air blow across my face and fling my hair into the air."
            ),
            _("Maybe I shouldn't be so closed off about my affairs."),
            _("Maybe I shouldn't be so defensive about my affairs."),
            _("I can be a bit evasive when it comes to my affairs."),
            -- borrowed bits to conform with other memories
            _("That {ship} we got once had {credits} in it."),
            _("Maybe we should go back to {system} to find more {ship}s."),
            _("I think we should take a little visit to {system}."),
            _("I was just doing a routine {ship} inspection. I swear."),
            _("I still have scary thoughts about {system}."),
            _("Do you remember when we almost got stranded in {system}?"),
            _("We should probably avoid {system}.")
        }

        -- have some random thoughts
        insert_sentiment(character, fmt.f(pick_one(choices), params))
        table.insert(character.conversation.sentiments, fmt.f(pick_one(choices), params))
        table.insert(character.conversation.sentiments, fmt.f(pick_one(choices), params))
        -- pick the memory
        new_memory = pick_one(choices)
    else
        -- create a random memory about what we know about
        if not params then
            params = {}
        end
        -- we might need the system, let's make sure we have that
        params.system = params.system or system.cur()

        local pso = player.pilot():outfits()

        -- a bunch of random memories that will start to sound repetitive eventually and cause the crew member to seem senile
		-- TODO: Generate a completely unique memory
        local choices = {
            _("I had a thought in {system} but I forgot it."),
            _("I still think about {system} sometimes."),
            fmt.f(
                _("I think there's an issue with our {outfit}, I'm going to go and check it out."),
                {outfit = pick_one(pso)}
            ),
            fmt.f(_("I was just doing a routine {outfit} inspection. I swear."), {outfit = pick_one(pso)}),
            fmt.f(
                _("Before you go there, I don't want to hear about the {outfit} problems."),
                {outfit = pick_one(pso), system = "{system}"}
            ),            fmt.f(
            _("Before you go there, I don't want to hear about what happened in {system}."),
                {outfit = pick_one(pso), system = "{system}"}
            ),
            _("I see that look you're giving me! I was there too you know, let's just drop it!"),
            fmt.f(_("Oh {swear}, not this again, can we just drop it?"), {swear = getMadeUpName()}),
            _("I'm getting real tired of getting all these looks."),
            fmt.f(_("I'll never forget the flight of {shipname}."), {shipname = player.pilot():name()})
        }

        -- check if this system has places we can refuel
        local can_refuel = false
        for key, spob in ipairs(params.system:spobs()) do
            if spob:canLand() and spob:services()["refuel"] then
                can_refuel = true
            end
        end

        -- check if we are scarily low on fuel and there are no refueling places
        if player.pilot():stats().fuel <= 100 and not can_refuel then
            topic = "travel"
            table.insert(
                choices,
                fmt.f(
                    _("I'll never forget the feeling of looking at the gauge and seeing the value read out as {fuel}."),
                    {fuel = player.pilot():stats().fuel}
                )
            )
            table.insert(choices, _("I thought we were going to die in {system}."))
            table.insert(choices, _("I still have scary thoughts about {system}."))
            table.insert(choices, _("Do you remember when we almost got stranded in {system}?"))
            table.insert(choices, _("We should probably avoid {system}."))
            -- random chance for this stressful situation to classify this memory as fear
            if rnd.rnd() < 0.16 then
                topic = "fear"
            end
        end

        -- see if some irrational fear kicks in and we become slightly traumatized
        if player.pilot():health() < 96 then
            local stressors = {_("fear"), _("death"), _("weapon"), _("shield")}
            topic = pick_one(stressors)
            -- we might start disliking this topic as well now
            if not character.conversation.topics_disliked[topic] then
                -- if we like violence or if we have high xp, we resist disliking the stressor
                if character.conversation.topics_liked.violence and rnd.rnd() > character.xp * character.satisfaction then
                    table.insert(character.conversation.topics_disliked, topic)
                elseif rnd.rnd() * 2 > character.xp * character.satisfaction then
                    table.insert(character.conversation.topics_disliked, topic)
                end
            end
        end

        -- check if we are low on armour
        if player.pilot():health() < 35 then
            -- this is now a violent memory
            topic = "violence"
            table.insert(choices, _("I thought we were going to die in {system}."))
            table.insert(choices, _("I still have scary thoughts about {system}."))
            table.insert(choices, _("Do you remember when we almost got sucked into space that time in {system}?"))
            table.insert(choices, _("We should probably avoid {system}."))
            if player.pilot():health() < 10 then
                -- actually, let's remember this specific system because that's pretty scary
                topic = system.cur():name()
            end
        end

        new_memory = pick_one(choices)
    end

    -- whether we actually like this or not (check dislikes first), this is now a topic we bring up
    if not character.conversation.topics_liked[topic] then
        character.conversation.topics_liked[topic] = {}
    end

    -- if we have memories of this system, put it there instead so we keep talking about it but don't always say the same thing
    local csn = system.cur():name()
    if character.conversation.topics_liked[csn] then
        topic = csn
    end

    print("created memory for about", fmt.f(new_memory, params), character.name, topic)
    -- insert the memory
    table.insert(character.conversation.topics_liked[topic], fmt.f(new_memory, params))

    -- have a chance to talk about this memory (think about this memory soon)
    insert_sentiment(character, fmt.f(new_memory, params))

    -- we created a memory, that gives us some experience
    character.xp = math.min(100, character.xp + 0.03)
end

-- the crewmate consumes an item on hand (if any, unless non-consumable *unimplemented) and enjoys it
function crewmate_use_item(character)
	if not character.item then return end
	
	local favor = evaluate_item_haste(character, character.item)
	character.satisfaction = character.satisfaction + favor
	
	if favor > 1 then
		-- remember enjoying this item
		create_memory(character, "gift")
	end
	
	if favor > 2 then
		-- we really liked this item a lot, this item makes our satisfaction incluence our xp
		-- at the same time, we cap xp at 2 here because being this happy is a baseline mood
		character.xp = math.max(2, math.min(100, character.xp + character.satisfaction * 0.01))
	elseif favor < 0 then
		local yuck = {
			_("That was something."),
			_("That {item} was terrible."),
			_("I didn't like that {item}."),
			_("I'm glad to be rid of that {item}?"),
			_("Why did I even get this {item}?"),
			_("I didn't want that {item}."),
			_("I didn't really enjoy my {item}."),
			_("I didn't enjoy my {item}."),
			_("I didn't like my {item}."),
			_("I discarded that {item}."),
			_("I threw the {item} in the ") .. pick_one( { _("bin"), _("trash"), _("rubbish") } ) .. ".",
			pick_one(
			{
			_("I jetissoned the "), _("I launched the "), _("I jetissoned that "), _("I jetissoned that stinking "), _("I launched that bloody ") 
			}) .. _(" {item} out the airlock. ") .. add_special(character),
		}
		insert_sentiment(character, fmt.f(pick_one(yuck), character))
	end
	
	-- consume/discard the item
	character.item = nil
end

-- gives the character some item to (hopefully) use later
-- the character carefully inspects the item, judging how much it likes it
local function give_item( character, item )
	character.item = item
	local evaluation = evaluate_item(character, item) * 0.1
	character.satisfaction = character.satisfaction + evaluation
	if evaluation > 1 then
		-- we must have really liked this item
		create_memory(character, "gift")
	elseif evaluation < 0.04 then
		-- this item was a waste of our time
		local yuck = {
			_("What am I supposed to do with this?"),
			_("What am I supposed to do with this {item}?"),
			_("I didn't like that {item}."),
			_("What am I doing with this {item}?"),
			_("Why do I have a {item}?"),
			_("I don't want this {item}."),
			_("Do you want this {item}?"),
		}
		insert_sentiment(character, fmt.f(pick_one(yuck), character))
	end
end

local function has_interest(character, interest)
    for topic, _phrases in pairs(character.conversation.topics_liked) do
        if topic == interest then
            return true
        end
    end

    return false
end

-- makes speaker speak their message and anything special they might know
-- used to make a champion notify the player that they are doing their mission
function speak_notify(speaker)
    local message = pick_one(speaker.conversation.message)

    if speaker.conversation.special and rnd.rnd(0, 1) == 1 then
        message = message .. " " .. add_special(speaker)
    end

    _comm(fmt.f("{typetitle} {name}", speaker), message, "F")
end

-- records an interaction about one of reactor's disliked topics brought up by offender
-- might create a memory like "offender talks about topic too much"
local function dislike_topic(topic, reactor, offender)
    -- reactor doesn't like offender as much, decrease satisfaction and record a sentiment
    reactor.satisfaction = reactor.satisfaction - 0.03

    -- this is a low priority sentiment, use the table instead of the head
    insert_sentiment(reactor, fmt.f(pick_one(reactor.conversation.bad_talker), offender))

    -- try to create a memory about this event
    if rnd.rnd() < reactor.chatter then
        create_memory(reactor, "animosity", {name = offender.name, topic=topic})
    end
end

-- returns the keyword that evaluator didn't want to hear
local function dislikes_phrase(phrase, evaluator)
    for _i, disgust in pairs(evaluator.conversation.topics_disliked) do
        if string.find(phrase, disgust) then
            return disgust
        end
    end

    return false
end

-- returns the keyword that evaluator is interested in
local function doeslike_phrase(phrase, evaluator)
    for interest, _phrases in pairs(evaluator.conversation.topics_liked) do
        if string.find(phrase, interest) then
            return interest
        end
    end

    return false
end

-- returns a list of appropriate responses and the topic that sparked interest
local function appreciate_spoken(spoken, appreciator)
    -- first check if we dislike something
    local disgust = dislikes_phrase(spoken, appreciator)
    if disgust then
        return appreciator.conversation.phrases_disliked, disgust
    end

    -- check if we are do like something
    local interest = doeslike_phrase(spoken, appreciator)
    if interest then
        return appreciator.conversation.topics_liked[interest], interest
    end

    -- we don't care about this at all
    return appreciator.conversation.default_participation, nil
end

-- attempt to generate a list of valid responses based on what was said
local function generate_responses(spoken, crewmate)
    local responses, topic = appreciate_spoken(spoken, crewmate)

    -- this is a topic we like talking about or that we dislike
    if topic then
        return responses
    end

    -- try to figure out if there is something that looks like a question or doubt that we can agree/disagree with
    local doubters = {
        _("who"),
        _("what"),
        _("why"),
        _("when"),
        _("know"),
        _("sure")
    }

    for _, doubt in ipairs(doubters) do
        if string.find(spoken, doubt) then
            return crewmate.conversation.default_participation
        end
    end

    -- we still don't know what this is, generate some responses about our irritation
    local imaginary_topic =
        pick_one(
        {
            _("*inaudible*"),
            _("*expletive*"),
            getMadeUpName(),
			extract_keyword(spoken)
        }
    )

    -- are we being shouted at? If so, we can use that as a topic
    if spoken == spoken:upper() and spoken:len() > 0 then
        table.insert(responses, _("There's no need to shout.")) -- it's funny because there are dialog lines about being hard of hearing
        imaginary_topic = "shouting"
    end

    for _i, phrase in ipairs(crewmate.conversation.phrases_disliked) do
        table.insert(responses, fmt.f(phrase, {
			topic = imaginary_topic,
			name = "{name}",
			article_object = "{article_object}",
			article_subject = "{article_subject}",
			firstname = "{firstname}",
		}))
    end

    return responses
end

-- calculate the interaction between starter and partaker
-- note that starter can by anyone here, even the player
-- but the partaker is a proper character.conversation sheeted character
-- returns the partaker's response after hearing about their liked topic
local function interact_topic(topic, starter, partaker)
    local responses = partaker.conversation.topics_liked[topic]
    partaker.satisfaction = partaker.satisfaction + 0.02

    -- we like each other now, maybe remember that, but depends on the conversation partner whether we create a memory or not
    local who = rnd.rnd(0, 5)
    if who == 0 then
        if starter.conversation then -- this check is required to make sure that you don't try to create a memory for the player
            starter.conversation.sentiment = fmt.f(pick_one(starter.conversation.good_talker), partaker)
            if rnd.rnd() < partaker.chatter then
                create_memory(starter, "friend", partaker)
            end
			starter.satisfaction = starter.satisfaction + 0.05 -- we made a friendship bond stronger
        end
    elseif who == 1 then
        partaker.conversation.sentiment = fmt.f(pick_one(partaker.conversation.good_talker), starter)
        if rnd.rnd() < starter.chatter then
            -- make sure starter isn't the player because we don't know how we'll do those memories
            if starter.conversation then
                create_memory(partaker, "friend", starter)
            end
        end
    end -- otherwise, we forget about it

    return responses
end

-- listener "hears" what is spoken and forms an opinion about speaker
-- returns a response appropriate to the reaction and the object of reaction if any
local function analyze_spoken(spoken, speaker, listener)
	-- see if we can appreciate what was said to us
	local responses, topic = appreciate_spoken(spoken, listener)
	
	if topic then
		-- see if it was good or bad
		if dislikes_phrase(spoken, listener) then
			dislike_topic(topic, listener, speaker)
			responses = join_tables(join_tables(
					responses, listener.conversation.bad_talker),
					listener.conversation.smalltalk_negative
				)
			return fmt.f(pick_one(responses), speaker)
		else -- we like talking about this!
			-- calculate the interaction (the listener's response) to speaker mentioning topic
			return pick_one(interact_topic(topic, speaker, listener)), topic
		end
	end
	-- we don't have a topic, we don't understand
	-- lets do a simple analysis so that we seem like we know what we're saying or why we're saying it
	local analysis = {}
	-- check if it was a question
	analysis.index = string.find(spoken, "?")
	if analysis.index then -- it was probably a question
		-- what was it about?
		if string.find(spoken, "remember")
			or string.find(spoken, "are you")
			or string.find(spoken, "Does")
			or string.find(spoken, "Do ")
			or string.find(spoken, "play")
			or string.find(spoken, "right")
			then
			-- seeking affirmation
			analysis.question = "affirm"
		elseif string.find(spoken, "When") then
			-- asking about time
			analysis.question = "time"
		elseif string.find(spoken, "Why") then
			-- asking something specific
			analysis.question = "specific"
		elseif string.find(spoken, "Is")
			or string.find(spoken, "can ")
			or string.find(spoken, "I ")
			then -- asking something we're probably unsure about and makes us feel uncomfortable
			analysis.question = "affirm_negative"
		end
	end

	-- check if it has my name or article in it (right now, I don't think about other peolpe)
	if string.find(spoken, listener.name)
		or string.find(spoken, listener.firstname)
		or string.find(spoken, listener.article_subject)
		or string.find(spoken, listener.article_object)
		then
		analysis.subject = "me"
	end
	
	-- if it was a question and it was about me, respond appropriately
	if analysis.question and analysis.subject == "me" then 
		-- TODO: need a sentiment evaluator
		return pick_one(listener.conversation.default_participation), listener.name
	elseif analysis.question then
	-- if it wasn't about me, respond as directed
		if analysis.question == "affirm" then
			-- nice to feel included in conversation
			listener.satisfaction = listener.satisfaction + 0.01
			return pick_one(listener.conversation.default_participation), "smalltalk"
		elseif analysis.quesiton == "affirm_negative"
			or analysis.question == "time" then
			-- making me uncomfortable
			listener.satisfaction = listener.satisfaction - 0.01
			return pick_one(listener.conversation.unsatisfied), nil
		end
	end
	
	-- if we still have nothing, also do a deep search of our topics
	-- this will degrade performance as the memory table grows and
	-- hopefully give us the kick we need to start pruning it
	analysis.choices = {}
	local brief = sanitize_phrase(spoken)
	for my_topic, phrases in pairs(listener.conversation.topics_liked) do
--		print("checking liked topic with phrases", my_topic, phrases)
		if #analysis.choices == 0 then
			for _, phrase in ipairs(phrases) do
				local extracted = extract_keyword(phrase)
				-- let's see if we think they might be talking about this
				if string.find(brief, extracted) then
					table.insert(analysis.choices, my_topic)
				end
			end
			
			-- satisfaction decreases because I have to think about more topics
			-- otherwise I risk looking like an idiot blurting out the first thing I say
			listener.satisfaction = listener.satisfaction - 0.001 * (#analysis.choices - 3)
		end
	end
	
	if #analysis.choices >= 1 then
		-- I think I know what topic they're talking about, let's try to talk about it
		for _i, keyword in ipairs(analysis.choices) do
			if listener.conversation.topics_disliked[keyword] then
				-- we didn't want to talk about this
				listener.satisfaction = listener.satisfaction - 0.05
				return fmt.f(pick_one(listener.conversation.phrases_disliked), speaker), keyword
			end
		end
		local like = pick_one({
			_("I like talking"),
			_("I enjoy talking"),
			_("I enjoy partaking in conversations"),
			_("I like being included when we talk"),
			_("I feel included when we talk"),
			_("I like to talk"),
			_("Let's talk more"),
			_("Let's talk"),
			_("It's nice to talk"),
		})
		-- feel like we are having a good conversation
		topic = pick_one(analysis.choices)
		print(fmt.f("picked topic <{topic}> from <{source}>.", {topic = topic, source = spoken} ))
		listener.satisfaction = listener.satisfaction + 0.03
		insert_sentiment(listener, fmt.f([[{like} about {topic}.]], { like = like, topic = topic }))
		return pick_one(interact_topic(topic, speaker, listener)), topic
	else
		-- we have no idea what the hell you're saying, fallback to default
		print(fmt.f("{listener} didn't understand when {speaker} said <{spoken}>.", {listener=listener.name, speaker=speaker.name, spoken = spoken }))

        -- continue with smalltalk, or whatever this is and adjust the satisfaction slightly
        responses = {
            _("Whatever."),
            _("Yeah, okay."),
            fmt.f(_("Okay, {name}."), speaker),
            fmt.f(_("Aright, {name}."), speaker),
            _("Sure."),
            _("Oh, really?")
        } -- default responses
        responses = join_tables(responses, listener.conversation.default_participation)
		
        -- if both speakers are happy, increase their satisfaction a little bit from the interaction
        if speaker.satisfaction > 0 and listener.satisfaction > 0 then
            speaker.satisfaction = speaker.satisfaction + 0.01 -- it was a good chat
            listener.satisfaction = listener.satisfaction + 0.01 -- thanks for including me
            -- we had a good conversation, let's remember our partner maybe
            if rnd.rnd() > speaker.chatter / 2 then
                insert_sentiment(speaker, fmt.f(pick_one(speaker.conversation.good_talker), listener))
                if not listener.conversation.sentiment then
                    listener.conversation.sentiment = fmt.f(pick_one(listener.conversation.good_talker), speaker)
                end
            end
            -- if the listener isn't very chatty, they will remember this
            if rnd.rnd() > listener.chatter then
                listener.conversation.sentiment = fmt.f(pick_one(listener.conversation.good_talker), speaker)
            end
        elseif speaker.satisfaction < 0 and listener.satisfaction < 0 then
            -- penalize negative banter quite heavily
            speaker.satisfaction = speaker.satisfaction - 0.04 -- I didn't get my attention
            listener.satisfaction = listener.satisfaction - 0.02 -- why you gotta drag me into this
            if not listener.conversation.sentiment then
                if rnd.rnd(0, 7) == 0 then
                    listener.conversation.sentiment = fmt.f(pick_one(listener.conversation.bad_talker), speaker)
                end
            end
			insert_sentiment(speaker, fmt.f(pick_one(speaker.conversation.bad_talker), listener))
        else
            -- feel randomly about this interaction, slightly weighted towards negative
            speaker.satisfaction = speaker.satisfaction + math.floor(10 * rnd.threesigma()) / 1000 - 0.01
            listener.satisfaction = listener.satisfaction + math.floor(10 * rnd.threesigma()) / 1000 - 0.0075
        end
		-- retain having not understood this
		insert_sentiment(listener, fmt.f([[I didn't really get it when {speaker} said "{spoken}".]], {speaker=speaker.name, spoken = spoken }))
		return fmt.f(pick_one(responses), speaker)
	end
end

-- talker tries to start a conversation with other about topic
local function converse_topic(topic, talker, other)
    local my_topics = talker.conversation.topics_liked
    local choices = my_topics[topic]

	-- this should be a logically impossible branch but I leave it here 
	-- for the free feedback in case I made a mistake somewhere
	if not choices then
		local tname = talker
		local oname = other
		if tname then tname = talker.name end
		if oname then oname = other.name end
		print(fmt.f("converse_topic no choices {topic} {talker} {other}", {topic = topic, talker=tname, other=oname}))
		return
	end
	
	-- snip-in: we might want to do something with subject some analysis whatever
	local subject = talker -- for now, we talk about ourselves
    -- speak the chosen phrase
    _comm(fmt.f("{typetitle} {name}", talker), fmt.f(pick_one(choices), subject), "F")

    -- other party probably responds
    if other and other.chatter * (0.75 + rnd.rnd()) > rnd.rnd() and other ~= FAKE_CAPTAIN then
        local responses = other.conversation.default_participation
        local answered_in = rnd.rnd(4, 16)
        -- do we have to adjust our default responses?
        if other.conversation.topics_disliked[topic] then -- no thanks
            -- record the negative interaction about topic with talker
            dislike_topic(topic, other, talker)
            responses = other.conversation.phrases_disliked
        elseif other.conversation.topics_liked[topic] then -- we like this topic (we have memories and we don't dislike it)
            -- let them interact
            responses = interact_topic(topic, talker, other)

            -- the other party will have responded positively, let's end the conversation here with a default response
            hook.timer(
                answered_in + rnd.rnd(2, 5),
                "say_specific",
                {me = talker, message = pick_one(talker.conversation.default_participation)}
            )
        end
        hook.timer(answered_in, "say_specific", {me = other, message = fmt.f(pick_one(responses), join_tables(talker,{topic = topic}))})
    end

end

local function speak(talker, other)
    local colour = "F"
    local choices
    local last_sentiment = talker.conversation.sentiment
	
    -- figure out what to say
    -- do I have a sentiment that I need to get off my chest?
    if talker.conversation.sentiment then
        -- less important thoughts, we store them all and then throw them away after we picked one out of this hat
        choices = {last_sentiment}
        -- do we want to talk about something else later?
        if talker.conversation.sentiments and rnd.rnd() < talker.chatter then
            talker.conversation.sentiment = pick_one(talker.conversation.sentiments)
        else
            talker.conversation.sentiment = nil
        end
    elseif talker.conversation.sentiments then
        choices = talker.conversation.sentiments
        talker.conversation.sentiments = nil
    elseif talker.satisfaction > 5 then
        -- I'm quite satisfied
        choices = talker.conversation.satisfied
    elseif talker.satisfaction < -3 then
        -- I'm noticably unsatisfied
        choices = talker.conversation.unsatisfied
        colour = "r"
    elseif rnd.rnd() < 0.042 then -- let's try to be original, share a fun fact
        choices = talker.conversation.backstory.funfacts
    else
        -- do I want to talk about a favourite topic?
        -- if the crew is a silent type, be more likely to just make smalltalk
        if rnd.rnd() < talker.chatter then
            -- let's consider our liked topics
            local topic
            for ttt, _v in pairs(talker.conversation.topics_liked) do
                -- if we talk a lot, we will talk more randomly about topics by increasing the chance on low chatters
                if rnd.rnd() > talker.chatter then
                    -- if we like the topic, talk about it unless we randomly feel like we have to talk about it
                    -- otherwise we're always going to be negative, but we want negative memories not to be too repetitive
                    if not talker.conversation.topics_disliked[ttt] or rnd.twosigma() > 1 then
                        topic = ttt
                    end
                end
            end
            -- if we picked a topic
            if topic then
                -- rare edge case we talk to the captain instead of ourselves
                if not other then
                    other = FAKE_CAPTAIN
                end
                return converse_topic(topic, talker, other)
            end
        end
        -- I don't have anything interesting to say, try smalltalk
        if talker.satisfaction > 0 then
            choices = talker.conversation.smalltalk_positive
        else
            --            colour = "y"
            choices = talker.conversation.smalltalk_negative
        end
    end

	-- hopefully impossible safety branch
	if not choices or #choices == 0 then
	 choices = {"I have nothing to say."}
	end
	
	-- we didn't start discussing a topic, say what's on our mind
	print("about to select speech")
    local spoken = pick_one(choices)
	print("talker wants to speak", talker.name, spoken)
    -- say it
    _comm(fmt.f("{typetitle} {name}", talker), spoken, colour)
    local listener = getCrewmateOnboard()
    -- if there's another person in the conversation, let them interact
    -- a response is more likely than striking a conversation
    if other and other.chatter * 1.5 > rnd.rnd() and other ~= FAKE_CAPTAIN then

        -- see if we want to strike up a new conversation based on interests
        for interest, _phrases in pairs(other.conversation.topics_liked) do
            if string.find(spoken, interest) then
                print(
                    fmt.f(
                        "detected {topic} from our list of topics {list}",
                        {topic = interest, list = tostring(other.conversation.topics_liked)}
                    )
                )
                return converse_topic(interest, other, talker)
            end
        end

		-- not sure what to say yet, use the analyzer        
		local response = analyze_spoken(spoken, talker, other)
		local answered_in = rnd.rnd(4, 16)
        hook.timer(answered_in, "say_specific", {me = other, message = response})

		-- listener feels randomly about this interaction, slightly weighted towards
		-- the negative, mostly for being targeted out of the blue
		listener.satisfaction = listener.satisfaction + math.floor(10 * rnd.twosigma()) / 1000 - 0.005
        -- if talker currently has a new sentiment then we just set it because of conversation
        -- so let's express ourselves if it seems novel
        if talker.conversation.sentiment and talker.conversation.sentiment ~= last_sentiment and rnd.rnd(0, 1) == 0 then
            -- TODO here: give the other person a chance to retort?
            -- it's our turn to talk, or at least we think so
            -- TODO: let's try to start a conversation instead
            local our_response = rnd.rnd(6, 12)
            hook.timer(
                answered_in + our_response,
                "say_specific",
                {me = talker, message = talker.conversation.sentiment}
            )
        elseif rnd.rnd() > talker.chatter then
            -- forget about it this new sentiment, we don't need to talk about it that much
            talker.conversation.sentiment = nil
		elseif talker.chatter > rnd.rnd() then
			-- we actually start feeling pressured to answer, and we analyze what was said back at us
			hook.timer(
				answered_in + rnd.rnd(3, 6),
				"say_specific",
				{me = talker, message = analyze_spoken(response, other, talker)}
			)
        end
    elseif listener ~= talker then
        -- check if we can appreciate something that was spoken
        local appreciation, interest = appreciate_spoken(spoken, listener)

        -- listener thought about something, let's remember that instead of discarding the useful data
        insert_sentiment(listener, pick_one(appreciation))

        -- listener will mention his interest to the talker and try to start a conversation
        if interest then
            -- see if we have a sentiment
            return converse_topic(interest, listener, talker)
        elseif listener.conversation.sentiment then
			-- listener will mention his sentiment to another party
			local responder = talker
			if other then
				responder = other
			end
			
			if responder == nil then
				print("WARNING COMING! Reposnder is nil: talker, other, responder, listener:", talker, other, responder, listener)
			end
			
            hook.timer(
                rnd.rnd(6, 36), -- it might take us a while to speak up
                "speak_to",
                {
					me = listener,
					responder = responder,
					message = listener.conversation.sentiment
				}
            )
		end
    end
end

-- a hook wrapper that makes arg.me speak to arg.responder and 
-- makes arg.responder respond back (without expecting a reply)
function speak_to(arg)
	local response_delay = rnd.rnd(4, 8)
	local colour = arg.colour or "F"
	_comm(fmt.f("{typetitle} {name}", arg.me), arg.message, colour)
	if arg.responder then
	hook.timer(
		response_delay, "say_specific",
		{me = arg.responder, message = analyze_spoken(arg.message, arg.me, arg.responder) }
	)
	else
		print("WARNING: Speak_to with no responder! args:", arg)
		for k,v in pairs(arg) do
			print(fmt.f({k}, {v}), {k=k,v=v})
		end
	end
end

-- makes arg.me say arg.message to nobody (without expecting anything in return)
function say_specific(arg)
    local colour = arg.colour or "F"
    _comm(fmt.f("{typetitle} {name}", arg.me), arg.message, colour)
end

-- the crew starts a conversation
-- TODO: don't use crew members that aren't on board
function start_conversation()
    -- TODO: Talk attempts should be something like crew_mates / 3 or similar until you have a crew manager
    -- pick a random person and see if they want to talk
    local talker = getCrewmateOnboard()
    if not talker then
        return
    end
    local other = getCrewmateOnboard()

    print(fmt.f("picked {name} to talk", talker))
    if other == talker then
        -- special case: I will talk to myself
        if talker.satisfaction > -1 or talker.chatter < rnd.rnd() then
            -- don't talk to myself, I'm not crazy
            other = nil
        end
    end

    -- we are more likely to talk if we are not feeling neutral
    local fudge = math.abs(talker.satisfaction / 10)
    if rnd.rnd() < talker.chatter + fudge then
        -- I will speak
        speak(talker, other)
    else
        print(fmt.f("{name} didn't want to talk", talker))
        -- let other talk instead with a smaller chance
        if other and rnd.rnd() < (other.chatter / 2) then
            print(fmt.f("{name} got a chance to speak", other))
            speak(other) -- they just talk to themselves, not expecting an answer
        elseif other and rnd.rnd() < other.chatter then
            -- we actually wanted to talk, this makes us unhappy
            other.satisfaction = other.satisfaction - 0.02
            insert_sentiment(other, fmt.f(pick_one(other.conversation.bad_talker), talker))
        end
    end

    -- hook initiation of a new conversation
    hook.rm(mem.conversation_hook)
    mem.conversation_hook = hook.date(time.create(0, 1, rnd.rnd(0, 300)), "start_conversation")
end

-- randomly picks a planet belonging to a faction, or "my home planet" if it didn't pick one before it ran out
local function getSpobForFaction(faction)
    for _i, place in ipairs(spob.getAll()) do
        if place:faction() == faction and rnd.rnd() < 0.16 then
            return place
        end
    end

    return "my home planet"
end

-- generates a backstory for an incomplete companion
-- requires the typetitle, faction and skill fields to be set
-- could use a lot of love :)
local function generateBackstory(cdata)
    local backstory = {}
    local random_ship = getRandomShip()
    local random_lastname, random_firstname = pilotname.human()
    if cdata.typetitle == "Companion" then
        backstory.intent =
            pick_one(
            {
                _("I provide services for my customers on various worlds."),
                _("I provide my services for customers around the galaxy."),
                _("I do my business on prosperous worlds."),
                _("I conduct business with wealthy clientele."),
                _("I conduct business around major hubs."),
                _("I would like to live on your ship as I conduct my business around the galaxy."),
                _("My business benefits greatly from frequent travel and I'm looking for a ship."),
                _("I'm looking for a ship from which to conduct my business.")
            }
        )
        backstory.origin = getSpobForFaction(cdata.faction)
        backstory.funfacts = {
            _("My clients are the high paying kind."),
            _("My customers keep me happy."),
            _("I enjoy lavishing myself in luxury."),
            fmt.f(_("I own a {ship}, but I don't like to fly it."), {ship = random_ship}),
            fmt.f(_("Did you know that I'm from {origin}?"), backstory),
            fmt.f(_("I don't talk about my customers, but I can tell you about {lover}."), {lover = random_firstname}),
            fmt.f(
                _("{lover} was my first love, we met on {pworld}. Don't ask me what I was doing there."),
                {lover = random_firstname, pworld = getSpobForFaction(faction.get("Raven Clan"))}
            )
        }
    elseif cdata.skill == _("Demolition") then
        -- TODO: right now this is for explosives expert, but we need a generic engineer one
        backstory.intent =
            pick_one(
            {
                _("I love to blow things up."),
                _("You look like you could use a demolition man!"),
                _("I am an explosives expert."),
                _("I'll make sure enemies you board don't come back."),
                _("I like to make things go boom."),
                _("I will blow it into smithereens. Just point the finger and I'll set the charges."),
                _("We're going to have a lot of fun together, believe me.")
            }
        )
        backstory.origin = getSpobForFaction(cdata.faction)
        backstory.funfacts = {
            fmt.f(_("Did you know that I'm from {origin}?"), backstory),
            _("One day, I'd love to rig a Goddard to blow..."),
            fmt.f(_("One day I'll tell you about my first {ship} and what happened to it."), {ship = random_ship}),
            fmt.f(
                _("My last captain named his ship the {shipname}. What an idiot. It had to go, it had to blow."),
                {shipname = getMadeUpName()}
            ),
            fmt.f(
                _(
                    "One of my last captains almost renamed his ship to {shipname} in a drunken stupor... I made sure that couldn't happen."
                ),
                {shipname = getMadeUpName()}
            ),
            fmt.f(
                _("I used to have a cousin named {cousin}, but don't ask me what happened to him."),
                {cousin = random_firstname}
            ),
            fmt.f(_("You ever heard of the {shipname}? Yeah, that was me."), {shipname = random_lastname}),
            fmt.f(_("You ever heard of the {made_up} explosion? Yeah, I did that."), {made_up = getMadeUpName()})
        }
    else -- something super generic
        backstory.intent =
            pick_one(
            {
                _("I'm looking for a ship to lay low on for as long as you'll have me."),
                _("I'm looking for a ship to lay low on."),
                _("I'm just looking to hang back for a while."),
                _("I was just hoping to catch a ride."),
                _("I'm just hoping to catch a ride to anywhere and maybe get some work along the way."),
                _("I'll hang around for a bit if you don't mind my company."),
                _(
                    "I like to make conversation. Maybe I can join your crew and participate in all the fun and excitement that happens on your ship?"
                ),
                _("I will keep you company. I'm not sure if you need it, though."),
                _("I've been out of work for a while and am looking for a place to hang my hat."),
                _("I'm looking for a new family."),
                _(
                    "I'm looking for a ship for work. I'm not from around here and my last captain traded in his ship to pay off some debt."
                ),
                _("I'm a hard worker. I'll make sure your docking clamps are secure every time."),
                _("I'm a good worker. I'll make sure your cargo bay equipment is in order."),
                _(
                    "I inherited an interplanetary tea house franchise, but the relative ease of spacetravel completely destroyed the market. It only lasted me seven years. I wish it could have been eight."
                )
            }
        )
        backstory.origin =
            pick_one(
            {
                _("somewhere far away"),
                _("a bad place"),
                _("nowhere"),
                "Janus Station",
                spob.get(true), -- a completely random spob! Hah!
                _ "Kramer",
                _("Earth"),
                _("the future"),
                getMadeUpName(),
                _("outer space"),
                _("House Goddard"),
                _("Townstead"),
                ("Eden")
            }
        )

		-- everyone gets a unique fun fact backstory
        backstory.funfacts = {
            fmt.f(_("I used to work on a {ship}, that was really something."), {ship = getRandomShip()}),
            fmt.f(_("I used to run a side gig where I repaired {thing}s."), {thing = getRandomThing()}),
            fmt.f(_("If anyone asks where I'm from, just tell them I'm from {origin}."), backstory),
            fmt.f(
                _("If anyone asks you where I'm from, tell them I'm from {origin}, see if they believe you."),
                backstory
            ),
            fmt.f(_("Don't tell anyone that I'm from {origin}, not that they would believe you."), backstory),
            fmt.f(
                _(
                    "I used to work near Crylo and one day, {someone} caught a {fish} so big we were called down to transport it off-world on our Gaiwan."
                ),
                {
                    someone = pick_one(
                        {_("someone"), _("somebody"), _("a youngster"), _("some group"), _("some people")}
                    ),
                    fish = pick_one({_("fish"), _("whale"), _("creature"), _("shark")})
                }
            ),
            fmt.f(
                _("I used to work on a {ship} near {place}."),
                {ship = getRandomShip(), place = spob.get(faction.get("Empire"), faction.get("Za'lek"))}
            ),
            fmt.f(
                _("One of my previous ships had a regular tour of {place}."),
                {place = spob.get(faction.get("Soromid"))}
            ),
            fmt.f(_("My last ship, the {name}, was a {coffin}."), {name = getMadeUpName(), coffin = getSpaceThing()}),
            fmt.f(_("My last captain named his ship the {shipname}. What an idiot."), {shipname = getMadeUpName()}),
            fmt.f(
                _(
                    "My last captain named his ship the {shipname}. The thing was a {bettername}. The captain was a {trashname}."
                ),
                {shipname = getMadeUpName(), bettername = getSpaceThing(), trashname = getInsultingProperNoun()}
            ),
            fmt.f(
                _("One of my last captains almost renamed his ship to {shipname} in a drunken stupor."),
                {shipname = getMadeUpName()}
            ),
			pick_one({
            _("I'm not exactly the most useful person, but I'm hoping that nobody will notice."),
            _("I'm not really a hard worker, but I'm hoping that nobody will notice."),
            _("Actually, I am pretty lazy and I think that honesty is a damn good policy."),
			fmt.f(_("I'm a pretty hard worker, at least that's what my {relative} always said."), {relative = pick_one({
					_("mother"), _("father"), _("nephew"), _("neice"), _("cousin"), _("uncle"), _("aunt"), _("grandmother"), _("grandfather"), _("old boss"), _("last employer")
				})}),
			}),
        }
    end
    -- The crewmate also gets a rare and unique looking special fact
    local special_facts = {
        fmt.f(
            _(
                "Actually, I killed someone on my last crew. That's why I'm really here. I'll never forget {name} and that last look."
            ),
            {name = pilotname.generic()}
        ),
        fmt.f(
            _(
                "I had a secret love affair on my last post. That's why I'm really here. I'll never forget {name} and that kiss goodbye."
            ),
            {name = pilotname.human()}
        ),
        fmt.f(
            _(
                "I have a large scar on my back. I got it in an altercation between a mighty warlord on {place} due to a misunderstanding."
            ),
            {place = spob.get(faction.get("Dvaered"))}
        ),
        fmt.f(
            _(
                "I have a large scar on my leg. I got it in an altercation with a fiesty {person} on {place} after a slight misunderstanding."
            ),
            {
                person = pick_one({_("woman"), _("youngster"), _("acrobat"), _("man"), _("warrior")}),
                place = spob.get(faction.get("Dvaered"))
            }
        ),
        fmt.f(
            _("I have a hole in my leg. I got it after a minor misunderstanding with a {person} near {place}."),
            {
                person = pick_one(
                    {_("drone"), _("robotic guard"), _("manual firearm"), _("fictional character"), _("badass")}
                ),
                place = spob.get(faction.get("Za'lek"))
            }
        ),
        _("I lived on Kramer for over a year. I'll save you the jealousy and spare you the details."),
        _("I killed a man with my bare hands, but I'll spare you the details."),
        _(
            "I killed a man with my bare hands, it was intense. It was me or him. I was obviously outmatched, but I got lucky."
        ),
        _(
            "I was once a split second from getting blasted into bits by an armed guard near {place} when a masked stranger appeared out of nowhere and swapped out his plasma rifle with an umbrella! Yeah, I didn't believe it when it happened right in front of my eyes either."
        ),
        _(
            "Don't tell anyone I told you this, but I once managed to fool a bounty hunter by masking my Quicksilver as a Kestrel. To this day I can't belive he just trusted his sensors and didn't notice the stark differences between a Quicksilver and a Kestrel through the optical interface. Not to mention the difference in size!"
        ),
        _("One of my lovers near Zinter is a pyromaniac. I'd stay away from that area.")
    }
    table.insert(backstory.funfacts, pick_one(special_facts))

    return backstory
end

local function generateIntroduction(cdata)
    local greetings = {
        _("Hi."),
        _("Hi!"),
        _("Hello."),
        _("Hello!"),
        _("Hi there!"),
        _("Hello there."),
        _("Hi there."),
        _("Greetings."),
        _("Salutations."),
        _("Ni hao."),
        _("Huzzah!"),
        _("Hey!")
    }

    -- I say this if I'm a chatterbox right before asking if I can join the crew
    local preprompts = {
        _("I'd love to join a crew such as yours."),
        _("I'd love to serve on a ship such as yours."),
        _("So..."),
        _("Well anyway..."),
        _("Well, what do you think?")
    }

    local prompts = {
        _("Can I join your crew?"),
        _("What do you say, would you like me on board?"),
        _("Would you like to add me to your roster?"),
        _("Would you like to add me to your crew?"),
        _("Can I live on your ship?"),
        _("What do you say, can I come on board?")
    }

    local reassurances = {
        _("You can count on me!"),
        _("I'll show you, you'll see!"),
        _("You will regret not taking me on!"),
        _("I'll be a good companion."),
        _("I'll be a good crewmate."),
        _("I'll be a hard worker, you'll see."),
        _("Is it obvious that I like to talk? Oh well..."),
        _("I tend to talk a lot, I hope that's okay..."),
        _("My friends say that I'm a bit of a chatterbox...")
    }

    -- just generate a random backstory for now
    local backstory = cdata.conversation.backstory
    local params = {
        greeting = pick_one(greetings),
        prompt = pick_one(prompts),
        preprompt = pick_one(preprompts),
        intent = backstory.intent,
        reassurance = pick_one(reassurances),
        funfact = pick_one(backstory.funfacts),
        skill = cdata.skill,
        name = cdata.name
    }

    -- use chatter to determine how much backstory to give (and maybe.. 'mystery'? nah...)
    local approachtext
    if cdata.chatter < 0.2 then -- I am the strong, silent type
        approachtext = "Hello. {skill}. Need one?"
    elseif cdata.chatter < 0.36 then -- I am a quiet person
        approachtext = "{greeting} {intent} {prompt}"
    elseif cdata.chatter < 0.6 then -- I speak an average amount
        approachtext = "{greeting} I'm {name}. {intent}\n\n{funfact} {prompt}"
    else -- I talk a lot
        if rnd.rnd(0, 1) == 0 then
            approachtext = "{greeting} My name is {name}. {intent} {reassurance}\n\n{funfact} {preprompt} {prompt}"
        else
            approachtext =
                "{greeting} {intent} Oh, did I mention that my name is {name}? {reassurance}\n\n{funfact} {preprompt} {prompt}"
        end
    end

    return fmt.f(approachtext, params)
end

-- generates a rather verbose preference table describing items/foods liked or disliked
local function generatePreferences()
	local preferences = {}
	
	preferences.liked = append_table(
		pick_some(lang.nouns.food.general),			-- have preference for some food
		append_table(
			pick_some(lang.getAll(lang.nouns.objects)),	-- appreciate kinds of things more than others
			join_tables(
				join_tables(
					pick_some(lang.nouns.food.fruit),
					pick_some(lang.nouns.food.fruit, 6) -- like some fruit more than others
				), join_tables(
					pick_some(lang.nouns.gifts, 2),		-- like most gifts
					pick_some(lang.adjectives.positive.nice, 2)	-- like most nice things
				)
			)
		)
	)
	
	preferences.liked = append_table(preferences.liked,
		pick_some(lang.getAll(lang.adjectives))		-- some adjectives trigger happy memories
	)
	
	-- dislike some fruit, if we like and dislike something then it's
	-- rather random how we feel about it, realistic right?
	preferences.disliked = append_table(
		pick_some(lang.nouns.food.general),
		append_table(
			pick_some(lang.nouns.food.fruit, 5),	-- don't like all fruit
			pick_some(lang.nouns.objects.items, 4)	-- don't like some specific items
		)
	)
	preferences.disliked = append_table(preferences.disliked,
		append_table(
			pick_some(lang.getAll(lang.adjectives.negative), 4),	-- some negative adjectives are extra nasty to us
			pick_some(lang.getAll(lang.adjectives), 5)	-- some adjectives disgust us
		)
	)
	
	return preferences
end

local function generateTopics()
    local topics = {
        -- list of phrases that use the things I can like (or not)
        ["small talk"] = {
			_("I can't stop thinking about {article_of_thought}s."),
			_("I keep thinking about {article_of_thought}s."),
			_("I had a thought about a {article_of_thought}."),
			_("What do you think about {article_of_thought}s?"),
			_("Do you like {article_of_thought}s?"),
			_("I had a {article_of_thought}, once, what about you?"),
			_("I've got {article_of_thought}s on my mind."),
			_("So... how about them {article_of_thought}s?"),
			_("Are you using a new shampoo?"),
			_("What's that smell? Smells kind of nice."),
			_("So, what do you think about {article_of_thought}s?"),
			_("Who doesn't love a {article_of_thought}?"),
			
		},
		["the view"] = {
            _("Did you see the view at that last shipyard?"),
            _("Did you notice the spectacular view during that eclipse?"),
            _("What a wonderful view. The stars are amazing."),
			_("What a wonderful view. The stars are as amazing as {article_of_thought}s."),
            _("What a wonderful view. The galaxy is amazing."),
            _("What a fantastic view. Reminds me of {article_of_thought}."),
			_("What a fantastic view."),
            _("What a fascinating display."),
            _("A view like that is worth a lot of credits."),
            _("Wow, get a load of that view!"),
            _("Oh man, what was that? Did anyone else see that?"),
            _("Did anyone else see that?"),
            _("Did you see that?"),
			_("Did you see that? Was that a {article_of_thought}?"),
            _("This is why people travel, this is a true life of luxury."),
            _("I like looking out at the stars."),
            _("How could anyone not admire this view?")
        },
        ["luxury"] = {
            fmt.f(_("Do you want to see my {ship}? I keep it in storage."), {ship = getRandomShip()}),
            fmt.f(_("How do you like this {thing}?"), {thing = getRandomThing()}),
            fmt.f(_("I'm thinking about investing in {thing}s."), {thing = getRandomThing()}),
            fmt.f(_("I'm thinking about investing in {thing}s, what do you think?"), {thing = getRandomThing()}),
            _("What do you think about this color?"),
            _("Will you take me to Kramer some day?"),
            _("You should try the soap that I'm using, I don't know where you get your stuff."),
            _("You should try this lotion."),
            _("Here, try this cream."),
            _("Here, try this."),
            _("Here, try this, I know you'll like it."),
            _(
                [[Here, smell this. It's called "the faithful friend", but it cost a lot of credits, almost as much as this ship.]]
            ),
            _(
                [[Here, smell this. It's called "the pacifier of violence", but it cost a lot of credits, almost as much as this ship.]]
            ),
            fmt.f(
                _("You should try this new virtual viewport simulator, it lets you pretend you're on a {ship}."),
                {ship = getRandomShip()}
            ),
            _("Back when I got my first Admonisher at Minerva Station, it cost ten thousand tokens."),
            _("I'll never fly in a Llama again, I much prefer the Gawain."),
            _("I'll never fly in a shuttle again, I much prefer the Gawain."),
            _("The Gawain is probably my favourite ship. I mean, that interior is to die for, literally."),
            _("The Gawain is probably my favourite ship. I mean, that interior is to kill for, literally.")
        },
        ["friendships"] = {
            fmt.f(_("Check out this {ship} my friend thinking of buying."), {ship = getRandomShip()}),
            _("Do you want to grab a coffee?"),
			_("Do you want to grab a {article_of_thought}?"),
            _("I like how close we are."),
            _("I know we've had our differences, but you're alright."),
            _("Hey, buddy! Hows it's going? You good?"),
            fmt.f(_("Check out the custom paintjob on this {ship}!"), {ship = getRandomShip()}),
            fmt.f(_("My friend {name} would love this."), {name = pilotname.human()}),
            fmt.f(_("I'm sure {name} would appreciate this."), {name = pilotname.human()}),
			fmt.f(_("I'm sure {name} would appreciate this "), {name = pilotname.human()}) .. "{article_of_thought}.",
            fmt.f(_("I miss my friend {name}."), {name = pilotname.human()}),
            fmt.f(_("I used to have a friend called {name}."), {name = pilotname.human()}),
            fmt.f(_("I miss my friend {name}."), {name = getMadeUpName()}),
            fmt.f(_("I used to have a friend called {name}."), {name = getMadeUpName()}),
            fmt.f(_("I miss my old friend {name}."), {name = pilotname.human()}),
            fmt.f(_("I miss my other friend {name}."), {name = pilotname.human()}),
            fmt.f(_("I miss my friend's {name}."), {name = getRandomShip()}),
            fmt.f(_("I miss my friend's {name}. It wasn't special, but our friendship was."), {name = getRandomThing()}),
            fmt.f(_("I miss my friend {name}."), {name = getMadeUpName()}),
            fmt.f(_("I miss my friends from the {name} I used to work on."), {name = getRandomShip()})
        },
        ["ships"] = {
            fmt.f(_("Check out this {ship} my friend thinking of buying."), {ship = getRandomShip()}),
            fmt.f(_("Do you want to see my sister's {ship}? She keeps talking about it."), {ship = getRandomShip()}),
            fmt.f(
                _("This is my favourite ship. The {name} of {made_up} was alright but nothing like this."),
                {made_up = getMadeUpName(), name = pilotname.human()}
            ),
            fmt.f(
                _("This is such a nice ship. The {made_up} of {name} was decent but nothing like this."),
                {made_up = getMadeUpName(), name = pilotname.human()}
            ),
            fmt.f(_("I once constructed a {ship} in a single cycle."), {ship = getRandomShip()}),
            fmt.f(
                _("Have I told you about the prototype {ship} I designed during my training?"),
                {ship = getRandomShip()}
            ),
            fmt.f(_("I used to serve on a {ship}. I think I've told you about it, right?"), {ship = getRandomShip()}),
            fmt.f(
                _("I once saw a comet shaped like a {ship} near {place}. It was pretty cool."),
                {ship = getRandomShip(), place = spob.get(true)}
            ),
            fmt.f(
                _("I've heard from {name} the new {ship} is going to be even sleeker than the current model."),
                {name = pilotname.human(), ship = getRandomShip()}
            ),
            fmt.f(
                _(
                    "I've heard from my old friend {name} the next {ship}, code-name {made_up} is going to have a special compartment for {thing}s."
                ),
                {
                    ship = getRandomShip(),
                    name = pilotname.generic(),
                    made_up = getMadeUpName(),
                    thing = getRandomThing()
                }
            ),
            fmt.f(_("Have you seen the new {ship} features?"), {ship = getRandomShip()}),
            fmt.f(_("Have you seen these hidden {ship} features?"), {ship = getRandomShip()}),
            fmt.f(
                _("Did you read that article about the 7 {ship} features no captain knows about?"),
                {ship = getRandomShip()}
            )
        },
        ["business"] = {
            fmt.f(
                _("I was traveling near {place} for business in my early years. Have you been there?"),
                {place = spob.get(faction.get("Independent"))}
            ),
            fmt.f(
                _("I was traveling near {place} for business in my early years. Have you been there?"),
                {place = spob.get(faction.get("Empire"))}
            ),
            fmt.f(
                _("I had some business near {place} for some {art} back in the day. What a story."),
                {place = spob.get(faction.get("Empire")), art = "{article_of_thought}" }
            ),
            fmt.f(
                _("I was traveling near {place} on a ship in my early years. I hated it, but the view was nice."),
                {place = spob.get(faction.get("Dvaered"))}
            ),
            fmt.f(
                _("I had to travel near {place} for business in my early years. Have you been there?"),
                {place = spob.get(faction.get("Soromid"))}
            ),
            fmt.f(
                _("I've heard that {place} is known for being good at science."),
                {place = spob.get(faction.get("Za'lek"))}
            ),
            fmt.f(
                _("Of all my travels I must say, I've been too often to {place}."),
                {place = spob.get(faction.get("Soromid"))}
            ),
            fmt.f(
                _("I didn't really like working at {place}, but the pay was good."),
                {place = spob.get(faction.get("Soromid"))}
            ),

            fmt.f(
                _("{place} is my favourite pirate outpost. Don't ask me why, it just is."),
                {place = spob.get(faction.get("Raven Clan"))}
            )
        },
        ["faith"] = {
            _("Sometimes you just have to have a little bit of faith."),
            _("Sometimes you just have to let the spirits guide you."),
            _("Sometimes you need to trust the universe."),
			_("My motto is: if you want {article_of_thing}s, you should have ethical morals."),
            _("I believe that traveling among the stars makes us immortal."),
            _("We're all going to die one day. Let's enjoy the ride."),
            _("I believe that things get worse, then they get better."),
            fmt.f(_("We all have a lot to believe in, but I believe in my lucky {thing}."), {thing = getRandomThing()})
        },
        ["affairs"] = {
            fmt.f(
                _("I too have had my fair share of affairs. One day I might tell you the story of {name}."),
                {name = pilotname.human()}
            ),
            fmt.f(_("I had an affair with a dangerous vagabond named {name}."), {name = pilotname.human()}),
            fmt.f(_("I got into a scuffle with a criminal named {name}."), {name = pilotname.human()}),
            fmt.f(
                _("I got into a mighty struggle with {name} of {made_up} before I joined this ship."),
                {made_up = getMadeUpName(), name = pilotname.human()}
            ),
            _("Don't ask me about my affairs."),
            _("Don't ask me about my love affairs."),
            _("Don't ask me about my personal affairs."),
            _("Don't ask me about my previous life."),
            _("Don't ask me about my personal life."),
            _("Please don't talk to me when I'm off duty."),
            _("I don't want to talk right now."),
            _("Not right now."),
			_("Sorry, I'm thinking about the {article_of_thought}."),
            _("I know I can be secretive sometimes, but some things are best left unsaid."),
            _("Actually, can we save this for later?"),
            _("Let's save this for later? I wanted to enjoy the view."),
            _("I want to visit one of my previous lovers. I'm just not sure which."),
            _("Not in this company. Later."),
            _("I'm not sure that whatever we're discussing is appropriate but whatever."),
            fmt.f(
                _(
                    "... I'm not sure that's appropriate but whatever. I'm sure {captain} doesn't mind. Oh, hey {captain}!"
                ),
                {captain = player:name()}
            )
        },
        ["travel"] = {
            fmt.f(
                _("One of my favourite places to visit is {place}. Have you been there?"),
                {place = spob.get(faction.get("Independent"))}
            ),
            fmt.f(
                _("A fascinating place to visit is {place}. Have you been there?"),
                {place = spob.get(faction.get("Za'lek"))}
            ),
            fmt.f(
                _("I heard that {place} is developing a new {made_up}. Have you been there?"),
                {place = spob.get(faction.get("Za'lek")), made_up = getMadeUpName()}
            ),
            fmt.f(
                _("Of all my travels I must say, I've been too often to {place}. Have you been there?"),
                {place = spob.get(faction.get("Empire"))}
            ),
            fmt.f(
                _("I had an affair with a warrior from {place}. I wonder what fearsome {name} is up to these days."),
                {place = spob.get(faction.get("Dvaered")), name = pilotname.human()}
            ),
            fmt.f(
                _(
                    "All the violence and lawlessness on {place} led my cousin {name} towards a path of disastrous affairs."
                ),
                {place = spob.get(faction.get("Dvaered")), name = pilotname.human()}
            ),
            fmt.f(
                _("I went to {place} just to check it out. I haven't had the urge to go since."),
                {place = spob.get(faction.get("Soromid"))}
            ),
	        fmt.f(
                _("I got to travel to {place} in my childhood. Unforgettable."),
                {place = spob.get(faction.get("Sirius"))}
            ),
            fmt.f(
                _("I used to visit my {relative} {name} regularly on {place}."),
                {
                    place = spob.get(faction.get("Empire")),
                    name = pilotname.human(),
                    relative = pick_one({_("aunt"), _("grandmother"), _("uncle"), _("grandfather"), _("councellor")})
                }
            ),
        },
        ["violence"] = {
            fmt.f(_("I once destroyed a {ship} in a single volley."), {ship = getRandomShip()}),
            fmt.f(_("Have I told you about the {ship} I destroyed during my training?"), {ship = getRandomShip()}),
            _("I've killed a man with my bare hands."),
            _("I could kill you with a spoon."),
			fmt.f(_("I could kill you with a {item}."), { item = pick_one(lang.getAll(lang.nouns.objects)) } ),
			fmt.f(_("I could kill you with a {item}."), { item = pick_one(lang.nouns.gifts) } ),
			_("I could kill you with a {article_of_thought}."),
			_("I could kill you with this {article_of_thought}."),
			_("I could kill you with {article_of_thought}s."),
			_("I could kill you with {article_of_thought}s. Think about that."),
            fmt.f(
                _("I could slay you with a defective {thing} in a {thong} battle."),
                {thing = getMadeUpName(), thong = getMadeUpName()}
            ),
            _("You call that a knife?"),
            _("I will bathe in the blood of my enemies."),
            _("What are you looking at?"),
            _("Enjoying the view? Enjoy it while it lasts."),
            _("Give me some credits, or die."),
            _("I'll skin you if you meddle in my personal affairs."),
            _("This part of the ship is mine; you got it, friend?"),
            _(
                "I know we're not supposed to have blades like these in the spaceport but this baby never leaves my side, I take it everywhere."
            ),
            _("I like to strike fear in my enemies."),
            _("I will strike fear in my enemies."),
            _("To run is to lose, to win is to die."),
            _("Sometimes, excessive force is necessary."),
            _("You always have a right to defend yourself. Even if that means shooting someone in the face."),
            fmt.f(_("Check out my {made_up} rifle, pretty neat, huh?"), {made_up = getMadeUpName()}),
            fmt.f(
                _(
                    "Check out this {made_up}. I only paid {amount} for this killer. How many credits is that per ship destroyed?"
                ),
                {made_up = getMadeUpName(), amount = fmt.credits(rnd.rnd(35e3, 725e3))}
            ),
            _("I would never kill my friends, but I could break your leg on a whim."),
            fmt.f(
                _("All the violence and lawlessness on {place} excites me."),
                {place = spob.get(faction.get("Dvaered"))}
            ),
            fmt.f(
                _("I got into a scuffle on {place} some cycles back. That's where I got the small scar."),
                {place = spob.get(faction.get("Dvaered"))}
            ),
            fmt.f(
                _("We all make mistakes. I once killed a man on {place} only to find out I got the wrong guy."),
                {place = spob.get(faction.get("Empire"))}
            ),
            fmt.f(
                _(
                    "I once had our ship travel all the way to {place} only to find out that I forgot to reset the navigation equipment. Let's just say that I would owe them quite a few credits if they had any use for them."
                ),
                {place = spob.get(faction.get("Empire"))}
            )
        },
        ["credits"] = {
			_("That's worth a lot of {article_of_thought}s."),
            _("Give me some credits."),
            _("Lend me some credits."),
            _("Hand me that credit chip."),
            _("Is this yours? Do you mind?"),
            _("Is that yours? Can I take it?"),
            _("Can I have that?"),
            _("Are you gonna use that?"),
            _("*inaudible*"),
            _("Are we talking about money? That's what I like to call it."),
            _("Did somebody say credits? Yeah I'm listening."),
            _("How many credits is that?"),
            _("Who doesn't love dough?"),
            _("I heard what you said earlier about your business."),
            _("Who doesn't love credits?"),
            _("Who doesn't love moolah?"),
            _("That's a lot of coin."),
            _("I wouldn't want to owe that much."),
            _("I wouldn't want to own that much."),
            _("It sounds like a lot, but if you scratch my back, I'll scratch yours."),
            _("Stop bothering me, I'm trying to think."),
            _("Stop bothering me, I'm trying to think!"),
            _("Why are we changing the subject?"),
            _("I can't stop thinking about the weight of that last credit chip."),
            _("Can't you see I'm trying to count here?"),
            _("Sorry, I'm having a little trouble doing my finances right now.")
        },
        ["science"] = {
            fmt.f(_("Check out the landing gear on this {ship}!"), {ship = getRandomShip()}),
            fmt.f(_("Have you seen the new {ship} features?"), {ship = getRandomShip()}),
            fmt.f(_("Have you seen these hidden {ship} features?"), {ship = getRandomShip()}),
            fmt.f(
                _("Did you read that article about the 7 {ship} features no captain knows about?"),
                {ship = getRandomShip()}
            ),
            fmt.f(_("I heard about some unexplained phenomena at {place}."), {place = spob.get(true)}),
            fmt.f(_("I wonder what the big deal about {place} is, there's no mystery."), {place = spob.get(true)}),
            fmt.f(
                _("I once saw a comet shaped like a {ship} near {place}. It was pretty cool."),
                {ship = getRandomShip(), place = spob.get(true)}
            ),
            fmt.f(
                _("I've heard from {name} the new Admonisher is going to be even sleeker than the current model."),
                {name = pilotname.human()}
            ),
            fmt.f(
                _(
                    "I've heard from {name} the next {ship}, code-name {made_up} is going to have a secret unscannable cargo compartment."
                ),
                {ship = getRandomShip(), name = pilotname.generic(), made_up = getMadeUpName()}
            ),
            fmt.f(
                _("The new '{made_up}' {thing} is supposedly the bee's knees."),
                {made_up = getMadeUpName(), thing = getRandomThing()}
            ),
            fmt.f(
                _("I've heard that an updated {thing} is going to be even sleeker than the current model."),
                {thing = getRandomThing()}
            ),
            fmt.f(
                _("I've heard that the new {thing} is going to be even sleeker than the current model."),
                {thing = getMadeUpName()}
            ),
            fmt.f(_("I just read that the {thing} is getting revamped again."), {thing = getMadeUpName()}),
            fmt.f(_("I've tried that new {thing} and I have to say, I'm amazed."), {thing = getMadeUpName()}),
            fmt.f(
                _("Did you hear that the {thing} now only costs {amount}?"),
                {thing = getMadeUpName(), amount = fmt.credits(rnd.rnd(20e3, 50e3 - 1))}
            ),
            fmt.f(_("I've tried that new {thing} and I have to say, I'm amazed."), {thing = getMadeUpName()}),
            fmt.f(
                _("I don't think those paid science publications are any good. I put all my faith in {thing}."),
                {thing = getMadeUpName()}
            ),
            fmt.f(
                _(
                    "{thing} luxury friendship bracelets are practically being given away for just a single credit if you adopt an abandoned illegal pet iguana and fill out some required forms. The only downside is that we'd have to travel to {place} to go get it."
                ),
                {thing = getMadeUpName(), place = spob.get(faction.get("Empire"))}
            )
        }
    }

    local liked = {}
    local disliked = {}
    -- now go through all the topics, and pick whether we like, dislike, or don't care about each one
    for topic, phrases in pairs(topics) do
        local roll = rnd.rnd(0, 6)
        if roll > 3 then -- yay, we like this
			-- pick some of the phrases to learn about this topic
            liked[topic] = pick_some(phrases)
        elseif roll < 3 then -- ouch, we got a 2 or a 3
            table.insert(disliked, topic)
        end -- 3 is indifferent
    end
    return liked, disliked
end

local function crewManagerAssessment()
    local troublemaker
	local star
    local min_satisfaction = 0
    local max_satisfaction = 0
    local cumul_satisfaction = 0
    for _i, crew in ipairs(mem.companions) do
        cumul_satisfaction = crew.satisfaction + cumul_satisfaction
        if crew.satisfaction > max_satisfaction then
            max_satisfaction = crew.satisfaction
        elseif crew.satisfaction < min_satisfaction then
            min_satisfaction = crew.satisfaction
            troublemaker = crew
        end
		if not star and crew.satisfaction > 3 and not crew.manager then
			star = crew
		elseif star and crew.satisfaction > star.satisfaction and not crew.manager then
			star = crew
		end
		-- prioritize higher xp crew
		if star and crew.xp * crew.satisfaction > star.xp * star.satisfaction and not crew.manager then
			star = crew
		end
    end
	
    -- if we aren't satisfied to at least 1, let's worry
    if (cumul_satisfaction / #mem.companions) < 1 then
        return "unsatisfied", troublemaker
    end

    -- if someone is at -1, let's worry
    if min_satisfaction <= -1 then
        return "troublemaker", troublemaker
    end

	-- if someone is doing well, notify
	if star then
		return "promising", star
	end
	
    return "satisfied", troublemaker
end

-- returns whether or not an utterance despleases someone
local function displeases ( someone, utterance )
	for _i, hate in ipairs(someone.preferences.disliked) do
		if string.find(utterance, hate) then
			return true
		end
	end
	return false
end

-- generates an item that scores strongly with most of the crew
local function findSuitableDecoration ()
	local scores = {}
	
	-- score every picked noun for every crew member...
	for _i, word in ipairs(
		join_tables(
			pick_some(lang.getAll(lang.nouns)),
			pick_some(lang.getAll(lang.adjectives))
		)
	) do 
		for _j, who in ipairs(mem.companions) do
			score = scores[word] or 0
			if displeases( who, word ) then
				-- heavy penalty
				scores[word] = score - math.ceil(#mem.companions / 2)
			else
				scores[word] = score + 1
			end
		end
	end

	local picked_adjective, picked_noun
	
	-- now pick a noun and adjective
	table.sort(scores, function (a,b) return a[2] > b[2] end)
	local min_score_a = 1
	local min_score_n = 1
	-- what is this word now? maybe I could have stored it, but whatever, not performance critical here			
	for word, score in pairs(scores) do
		if score >= min_score_n then
			for _j, noun in ipairs(lang.getAll(lang.nouns)) do
				if
					word == noun
					and not picked_noun or rnd.rnd(1,7) == 0
				then
					picked_noun = noun
					min_score_n = score / 2
				end
			end
		end
		if score > min_score_a then
			for _j, adjective in ipairs(lang.getAll(lang.adjectives)) do
				if
					word == adjective
					and not picked_adjective or rnd.rnd(1,7) == 0
				then
					picked_adjective = adjective
					min_score_a = score / 2
				end
			end
		end
	end
	
	-- we are not guaranteed to find something everyone likes, so need a fallback
	if not picked_adjective then
		picked_adjective = _("vase of")
	end
	
	if not picked_noun then
		picked_noun = _("flowers")
	end
	
	return picked_adjective .. " " .. picked_noun
end

-- generates a suitable gift for personality
local function findSuitableGift( personality )
	local liked = {}
	
	for _i, pref in ipairs(personality.preferences.liked) do
		-- what is this preference?
		
		-- is it like a color? we want to prioritize this
		for _j, color in ipairs(lang.getAll(lang.adjectives.colors)) do
			if
				string.find(pref, color)
				and not displeases(personality, color)
				and (not liked.color or rnd.rnd(0, 1) == 0)
			then
				liked.color = color
			end
		end
		
		-- is it some other adjective? we want a couple
		for _j, adj in ipairs(
			join_tables(
				lang.getAll(lang.adjectives.positive),
				lang.getAll(lang.adjectives.negative)
			)
		) do
			if
				string.find(pref, adj)
				and not displeases(personality, adj)
				and rnd.rnd(0, 7) >= 5
			then
				if not liked.ad1 and rnd.rnd(0, 3) == 1 then
					liked.ad1 = adj
				elseif not liked.ad2 and rnd.rnd(0, 2) == 1 then
					liked.ad2 = adj
				end
			end
		end
		
		-- is it a noun? we want a good one here, preferably with lots of characters but not always
		local good = rnd.rnd(0, 1)
		local prefers = function (a, b) if good then return a:len() > b:len() else return rnd.rnd(-1, 1) end end
		for _j, noun in ipairs(lang.getAll(lang.nouns.objects)) do
			if
				string.find(pref, noun)
				and not displeases(personality, noun)
				and (not liked.noun or prefers(noun, liked.noun))
			then
				liked.noun = noun
			end
		end
	end
	
	if not liked.noun then
		return _("symbolic gesture") -- we don't know what to give them
	end
	
	-- postprocessing, don't duplicate colors
	if liked.color then
		if liked.ad2 and string.find(liked.ad2, liked.color) then
			liked.ad2 = nil
		end
		
		if liked.ad1 and string.find(liked.ad1, liked.color) then
			liked.ad1 = nil
		end
	end

	-- don't duplicate adjectives
	if liked.ad2 and (not liked.ad1 or string.find(liked.ad2, liked.ad1) or string.find(liked.ad1, liked.ad2) ) then
		liked.ad1 = liked.ad2
		liked.ad2 = nil
	end

	local order = ""
	if liked.ad2 and liked.color then
		order = "{ad2} {color} {ad1} {noun}"
	elseif liked.ad1 and liked.color then
		order = "{ad1} {color} {noun}"	
	elseif liked.color then
		order = "{color} {noun}"
	elseif liked.ad2 then
		order = "{ad2} {ad1} {noun}"
	elseif liked.ad1 then
		order = "{ad1} {noun}"
	else
		order = "{noun}"
	end
		
	return fmt.f(order, liked)
end

-- returns an assessment on the crew members and their psychology
-- returns the assesment string, the troublemaker and a 
-- suggestion for a suitable decoration
local function psychologicalAssessment()
	-- start with a basic personnel assessment, then season it with flavor
	local passessment, person = crewManagerAssessment()
		
	return passessment, person, findSuitableDecoration()
end

-- checks if you have a good minimum crew and whether the crew is doing well
-- returns "the assesment" and the subject of the assessment if it is a personnel assessment
local function commandAssessment()
	local passessment, person = crewManagerAssessment()
	local max_crew = player.pilot():stats()["crew"]
	local overstaffed = false
	local worst = { ["name"] = _("that guy"), ["firstname"] = _("a troublemaker"), xp = 0, ["article_subject"] = _("he") }
	-- assess general and janitorial strength
	local workers = {}
	workers.janitorial = 0
	workers.general = 0
	for ii, crewmate in ipairs(mem.companions) do
		if ii <= max_crew then
			if
				string.find(crewmate.skill, _("Sanitation"))
				or string.find(crewmate.skill, (_("Janitor")))
			then
				-- janitors can be doubly effective or extremely ineffective
				workers.janitorial = workers.janitorial + math.max(0.25, math.min(2, crewmate.xp * crewmate.satisfaction))
			elseif string.find(crewmate.skill, _("Rookie")) then
				if crewmate.xp < worst.xp then
					worst = crewmate
				end
				workers.general = workers.general + 0.12
				-- we don't have any skills, so we clean as well
				workers.janitorial = workers.janitorial + 0.1
			elseif string.find(crewmate.skill, _("Cadet")) then
				workers.general = workers.general + 0.25
			elseif string.find(crewmate.skill, _("Ensign")) then
				workers.general = workers.general + 1
			elseif string.find(crewmate.skill, _("Lieutenant")) then
				workers.general = workers.general + 0.5
				-- we are responsible, so we clean as well
				workers.janitorial = workers.janitorial + 0.2
			end
		elseif ii > max_crew then
			overstaffed = true
		end
	end
	local effective_janitors = workers.janitorial + (0.5 * workers.general)
	
	local janitors_needed =  math.ceil(math.min(#mem.companions * 0.168 + 0.75, max_crew * 0.16))
	
	if effective_janitors < janitors_needed then
		return _("Sanitation"), nil
	end
	
	if overstaffed then
		return _("Overstaffed"), worst
	end
	
	-- reuse calculation for general work strength
	if workers.general < math.floor(max_crew * 0.02) then
		return _("Short Staffed"), nil
	end
	
	return passessment, person
end

-- creates a manager component that's only useful for specials
local function createUselessManagerComponent()
	local manager = {}
	manager.type = ""
	manager.cost = 0 -- can't be activated if cost is 0
	
	return manager
end

-- create a generic manager component for crew management (goes into companion.manager)
local function createGenericCrewManagerComponent()
    local manager = {}

    manager.type = _("Personnel")
    local lines = {}
    manager.cost = 3e3 -- how much it costs to "activate" this manager

    lines.satisfied = {
        _("The crew seems happy."),
        _("The crew is content."),
        _("The crew doesn't look so bad at all."),
        _("The crew seems to be enjoying themselves."),
        _("The crew doesn't need any micromanagement at this point."),
        _("The crew doesn't seem to be having any issues."),
        _("The crew's looking good."),
        _("The crew seems to be doing good."),
        _("The crew is performing within parameters."),
        _("The crew is doing well.")
    }

    lines.unsatisfied = {
        _("The crew seems unhappy."),
        _("The crew isn't happy."),
        _("The crew doesn't look very happy."),
        _("The crew doesn't seem very happy."),
        _("The crew doesn't look happy."),
        _("The crew doesn't seem happy."),
        _("The crew's in a slump."),
        _("The crew could use a turnaround."),
        _("The crew is getting fatigued."),
        _("The crew needs a change of pace.")
    }

    lines.troublemaker = {
        _("We've got some problems with {name}."),
        _("You have a troublemaker in your crew."),
        _("{name} has been performing poorly."),
        _("{name} has been causing some issues."),
        _("{name} has been causing problems."),
        _("{name} has been causing trouble."),
        _("Honestly, we are having {typetitle} problems."),
        _("The {typetitle} situation could be better."),
		_("The {typetitle} situation has been better."),
		_("The {typetitle} problem is getting worse."),
		_("The {typetitle} situation is becoming noticeable."),
		_("The {typetitle} situation needs to be improved."),
        _("I've had some complaints about {name}."),
        _("I've had some complaints."),
        _("We've got some issues with {name}."),
        _("We've got some unresolved tension between {name} and the rest of the crew."),
		_("We've got some unresolved tension some {typetitle} and the rest of the crew."),
		_("We've got some {typetitle} complaining about the rest of the lot."),
        _("Let's not get into it. It's not looking good."),
        _("I don't want to point any fingers."),
        _("Don't say I didn't warn you. Can we leave it at that?")
    }
	
	-- the regular personnel manager isn't social, just wants to do payroll
	-- companion does the social stuff, but doesn't do payroll
	lines.specific = {
		_("Yes... {article_subject} probably scores around {satisfaction:.0f}."),
		_("Let's see... {article_subject} has an experience level around {xp:.0f} according to my notes."),
		_("That {skill} {typetitle} has an experience level of {xp:.0f} and a happiness score of {satisfaction:.0f}."),
		_("I would put {article_object} at around {satisfaction:.0f} on the happiness scale."),
		_("I'm not quite sure what you want me to tell you about {article_object}."),
		_("I don't really want to talk about {article_object}."),
		_("Do we have to discuss the staff? I'd rather just do payroll."),
		_("I think that {article_subject} is doing fine, stop bothering me."),
		_("I think that {article_subject} is doing fine, do we have to keep talking about {article_object}?"),
		_("Come on, {article_subject} is fine, do we have to keep talking about {article_object}?"),
		_("I think {article_subject} is alright, is something wrong with {article_object}?"),
		_("Why are you asking about {article_object}?"),
		_("I think that {article_subject} is probably doing alright, but you never know. I can only take a guess."),
		_("Do we have to keep talking about {article_object}? {firstname} is just one of the bunch."),
		
	}
	
	-- default manager can't recognize exceptional crew
	lines.promising = lines.satisfied

    manager.lines = lines

    return manager
end

local function createPsychologicalManagerComponent()
	local manager = createGenericCrewManagerComponent()
	
	manager.lines.specific = {
		_("Yes... {article_subject} displays a mood best described as the number {satisfaction:.0f}."),
		_("Let's see... {article_subject} has a preference for {article_of_thought}s according to my notes."),
		_("That {skill} {typetitle} has a happiness score of {satisfaction:.0f}."),
		_("I would put {article_object} at around {satisfaction:.0f} on the happiness scale."),
		_("I would suggest a {article_of_thought} to give {article_object}."),
		_("I know from my conversations with {article_object} that {article_subject} would appreciate a {article_of_thought}."),
		_("Perhaps you can decorate the ship with {article_of_thought}s, I assume you want to try to cheer {article_object} up?"),
		_("I think that {article_subject} would really appreciate a {article_of_thought}."),
		_("I can tell you that {article_subject} would love a {article_of_thought}, perhaps you can give {article_object} one?"),
		_("Someone like {article_object} would probably like a {article_of_thought}."),
		_("I think {article_subject} likes {article_of_thought}s"),
		_("Why don't you get {article_object} a {article_of_thought}?"),
	}
	
	return manager
end

-- create a generic crewmate with no special skills whatsoever
local function createGenericCrewmate(fac)
    fac = fac or faction.get("Independent")
    local portrait_arg = fac
    local pf = spob.cur():faction()
    local lastname, firstname = pilotname.human()
    if pir.factionIsPirate(pf) then
        fac = faction.get("Pirate")
        lastname = pilotname.pirate()
        portrait_arg = "Pirate"
    end
    local portrait_func = portrait.getMale

    local character = {}
    character.gender = "Male"
    character.article_object = "him"
    character.article_subject = "he"
    -- generic character has 50% chance of being male or female
    if rnd.rnd(0, 1) == 1 then
        character.gender = "Female"
        character.article_object = "her"
        character.article_subject = "she"
        portrait_func = portrait.getFemale
    -- TODO: female name
    end
	character.last_paid = time.get()
    character.name = lastname
    character.firstname = firstname

    character.typetitle = "Crew"
    character.skill = pick_one({_("Cargo Bay"), _("Sanitation"), _("Janitorial"), _("Maintenance"), _("Security"), _("Rookie"), _("Cadet"), _("Ensign"), _("Lieutenant")})
    character.satisfaction = rnd.rnd(-1, 5) -- there is a chance of hiring a troublemaker or negative nancy
    character.threshold = 1e3 -- how much they need to be happy after doing a paid job
    character.xp = math.floor(10 * (7 + 2 * rnd.threesigma())) / 10
    character.portrait = portrait_func(portrait_arg)
	character.vncharacter = portrait.getFullPath(character.portrait)
    character.faction = fac
    character.chatter = 0.5 + rnd.twosigma() * 0.2 -- how likely I am to talk at any given opportunity
    character.deposit = math.ceil(9e3 * character.satisfaction * character.xp + character.chatter * rnd.rnd() * 8e3) + 35e3
    character.salary = math.ceil(1 + character.xp * character.satisfaction) * 1000 * rnd.rnd() + math.ceil(character.chatter * 100)
    character.other_costs = "Water" -- if you don't have a cost factor, just cost water
	character.article_of_thought = _("Credit") -- if we don't think about anything, we think about credits
	
	local multipliers = {
		[_("Lieutenant")] = 32,
		[_("Ensign")]	= 16,
		[_("Cadet")] = 6,
		[_("Maintenance")] = 3,
		[_("Janitorial")] = 0.8,
	}
	for skill, multiplier in pairs(multipliers) do
	-- generic salary/deposit adjustment based on skill
		if string.find(character.skill, skill) then
			character.salary = character.salary * multiplier
			character.deposit = character.deposit * multiplier
		end
	end
	
	character.preferences = generatePreferences()
	
    local liked, disliked = generateTopics()
    character.conversation = {
        ["backstory"] = generateBackstory(character),
        -- what I say when I'm doing my job
        ["message"] = {
            _("I'm here."),
            _("I'm doing it."),
            _("I'm on it."),
			_("I'm working on it."),
			_("Stop pressuring me."),
			_("I've got it."),
			_("I'm on this."),
			_("I've got this."),
			_("I hope I got this right."),		
        },
        -- what I say when I'm satisfied
        ["satisfied"] = {
            _("I'm quite happy."),
            _("I am satisfied."),
            _("It's a good day."),
            _("I feel good."),
			_("Not the worst cycle, right?"),
			_("I've seen periods worse than this."),
        },
        -- what I say when not satisfied
        ["unsatisfied"] = {
            _("I am unhappy."),
            _("The situation is bleak."),
            _("The atmosphere is unfriendly."),
            _("I'm bored."),
            _("I get bored sometimes."),
            _("There's nothing to do around here."),
            _("It's too quiet here."),
			_("The past periods will haunt me."),
			_("The last cycle was harsh."),
			fmt.f(_("The {fruit} situation on the ship could be better."), {fruit = getRandomFruit() } ),
			fmt.f(_("I haven't seen a single {fruit} in cycles."), {fruit = getRandomFruit() } ),
			fmt.f(_("I last saw maybe one {fruit} some periods ago or longer, I don't even remember anymore."), {fruit = getRandomFruit() } ),
			fmt.f(_("I need my {fruit}s."), {fruit = getRandomFruit() } ),
			fmt.f(_("There's never enough {fruit}s when I need one."), {fruit = getRandomFruit() } ),
			fmt.f(_("I last saw maybe one {fruit}... I don't even remember anymore."), {fruit = getRandomFruit() } ),
        },
        -- things I say about {name} when I had a good conversation
        ["good_talker"] = {
            _("You're a good listener, {name}."),
            _("{name} seems nice."),
            _("Right on!"),
            _("I agree with whatever {firstname} says."),
			_("I agree with whatever {article_subject} says."),
            _("I agree with {article_object}, with {name}."),
            _("You know {name}, you're alright."),
            _("Anyone want to give me a hand with this?"),
            _("Say, could you give me a hand with this?"),
            _("Let's go grab a drink with {firstname}."),
            _("Isn't {name} nice?"),
			_("Isn't {article_subject} nice?"),
            _("Isn't that {name} great?"),
            _("Isn't this just wonderful?"),
            _("Everything seems great."),
            _("I'm feeling positive."),
            _("I'm glad I had that talk with {name}."),
            _("I'm glad we had this talk."),
			_("I had a good conversation with {article_object}."),
        },
        -- things I say about {name} when I had a bad conversation
        ["bad_talker"] = {
            _("Come on, {name}."),
            _("{name}, don't be such a downer."),
            _("Brighten up, {name}."),
            _("Get yourself together {name}."),
            _("To hell with it, {article_subject}'s insane."),
            _("Yeah, okay."),
            _("Interesting."),
            _("Whatever..."),
            _("Whatever, jeez."),
            _("Oh come on {name}, don't start with me."),
            _("Not this again, {name}."),
            _("I think {article_subject}'s being offensive."),
			_("I think {article_subject}'s having a bad day."),
			_("You'd think {article_subject}'d keep those thoughts to {article_object}self."),
			fmt.f(_("You should keep those thoughts to yourself, shouldn't {article_subject}, {captain}?"), {article_subject="{article_subject}", captain=player.name() } ),
			_("I don't know what {article_subject}'s on about."),
			_("What's gotten into {article_object}?"),
        },
        ["fatigue"] = {
			fmt.f(_("*sigh*... Time for my {skill} duty I guess."), character ),
            _("Are we going to get some time off anytime soon?"),
            _("It's really cold out here in space."),
            _("It's so lonely out here."),
            _("I could use a drink."),
            _("I could really use a drink."),
            _("I need a drink."),
            _("I could use a break."),
            _("I'm pretty tired."),
            _("I could use some rest."),
			_("Anyone want to play some cards?"),
			fmt.f(_("Anyone want to play some {game}?"), { game = getShipboardActivity("game") }),
			fmt.f(_("Anyone want to play {game}?"), { game = getShipboardActivity("game") }),
			fmt.f(_("Anyone want to play a game of {game}?"), { game = getShipboardActivity("game") }),
			fmt.f(_("I really want to play {game}."), { game = getShipboardActivity("game") }),
			fmt.f(_("Do I really have to do all that {basic}?"), { basic = getShipboardActivity("basic") }),
			fmt.f(_("Do I really have to do all that {basic}?"), { basic = getShipboardActivity("basic") }),
			fmt.f(_("Do I have to do the {basic}?"), { basic = getShipboardActivity("basic") }),
			fmt.f(_("Oh, I forgot that I have to do my {basic} for today."), { basic = getShipboardActivity("basic") }),
			fmt.f(_("I'm going for some {basic}."), { basic = getShipboardActivity("basic") }),
			fmt.f(_("I'm going to do that {basic} in a bit."), { basic = getShipboardActivity("basic") }),
			_("I hope someone can come cover for me soon, I'm getting a bit tired."),
			_("We've been in space for far too long, we need a break. A good one."),
			_("We need a break, and by break, I mean a big break with big rewards."),
			_("I thought it was all going to be action. But instead it's mostly fear, and a lot of nothing."),
			_("I can't wait for that drink with the crew when we land."),
			_("I wonder if the captain will mind if I take some time for myself at the next stop."),
			_("I haven't been feeling like myself lately."),
			_("Give me a break."),
			_("Give me a drink."),
			_("Get me a drink."),
			_("I need a sandwich or something."),
			_("Do we still have any fruit?"),
			_("Why does the water taste so stale?"),
			_("I can't believe we're out of bananas already, again!"),
			_("No bananas..."),
			_("Where are the bananas?"),
			fmt.f(_("Where are the {fruit}?"), {fruit = getRandomFruit() } ),
			fmt.f(_("No {fruit} today?"), {fruit = getRandomFruit() } ),
			fmt.f(_("I saw there were some {fruit}s in the break room earlier but I didn't take one."), {fruit = getRandomFruit() } ),
			fmt.f(_("I can't believe I didn't take the last {fruit}."), {fruit = getRandomFruit() } ),
			fmt.f(_("I haven't seen a single {fruit} in cycles."), {fruit = getRandomFruit() } ),
			fmt.f(_("I last saw maybe one {fruit} some periods ago or longer, I don't even remember anymore."), {fruit = getRandomFruit() } ),
        },
        -- special things I know how to say
        ["special"] = {
            ["laugh"] = {
                _("*laughs*"),
                _("Heh."),
                _("*chuckles*"),
                _("Haha."),
                _("Right? *laughs*"),
                _("*laughs*")
            },
            ["hysteria"] = {
                _("I can't take it, I have to get out of here!"),
                _("Why won't the airlock open? I need to get out of here!"),
                _("Oh man, oh boy, oh sister..."),
                _("Oh brother..."),
                _("Wait, what was that?"),
                _("What's going on?"),
                _("What is that?"),
                _("Hello? Is there anybody there?"),
                _("What's that ringing sound?"),
                _("Oh no, space blindness, it actually happened!"),
                _("Why can't I see anything?"),
                _("Is that a floating sponge?")
            },
            ["worry"] = {
                _("I don't know..."),
                _("Oh, wait a minute..."),
                _("Did I get that right?"),
                _("At least I thought so."),
                _("If everything goes to plan."),
                _("Maybe."),
                _("I think."),
                _("I think..."),
                _("I'm pretty sure."),
                _("I hope so.")
            }
        },
        ["smalltalk_positive"] = {
            fmt.f(_("Do you guys remember that {thing} the other day?"), {thing = getRandomThing()}),
            _("Hey. Everything good?"),
            fmt.f(_("My {made_up} is acting up. I'd better go check on it"), {made_up = getMadeUpName()}),
            _("I'll be in my quarters if you need me."),
            _("I'm going to go do inventory."),
            _("Let me know if you need anything."),
            _("I'm going to take stock in a bit."),
            _("Let me know if you need a hand with that thing later."),
            _("I'm going back to get on that maintenance task."),
            _("I'll go get on that maintenance task."),
            _("I'm about to go prime the locking equipment."),
            _("Do you need a hand with that?"),
            _("I could use a hand with this, do you mind?"),
            _("I could use a hand in the back, can you help me?"),
			_("You want a drink?"),
			_("You want this? I got two."),
			fmt.f(_("Would you like to play some {game}?"), { game = getShipboardActivity("game") }),
			fmt.f(_("I'll play some {game} if you want."), { game = getShipboardActivity("game") }),
			fmt.f(_("Would you like to have this {fruit}?"), { fruit = getRandomFruit() }),
			fmt.f(_("I'll give you my {fruit} if you want it."), { fruit = getRandomFruit() }),
			fmt.f(_("I just ate a really nice {fruit}."), { fruit = getRandomFruit() }),
			fmt.f(_("Do you want a piece of this {fruit}?"), { fruit = getRandomFruit() }),
			fmt.f(_("So, {fruit} anyone?"), { fruit = getShipboardActivity() }),
        },
        ["smalltalk_negative"] = {
            _("Sometimes I wonder what I'm even doing on this ship."),
            _("What am I even doing here?"),
            _("This life isn't as glamorous as it was made out to be."),
			_("The atmosphere here is killing me."),
			_("I feel like I am suffocating in here."),
			_("I don't know why I hang out with you."),
			_("You guys are the worst."),
			_("Your comany is unappreciated."),
			_("Please stop leaning in my direction."),
			_("Please stop looking in my direction."),
			_("I don't want you to look at me right now."),
			_("I don't want to look at you right now."),
			_("Please stop talking to me."),
			_("Please don't say anything."),
			_("Don't say anything."),
			_("Please don't talk to me."),
			_("Don't talk to me."),
			_("Stay away from me."),
			_("Say nothing."),
			fmt.f(_("Don't say a {thing} thing!"), { thing = getMadeUpName()}),
			fmt.f(_("What are you looking at, you {insult}?"), {insult = getInsultingProperNoun()}),
        },
        -- list of things I like to talk about and what I say about them
        ["topics_liked"] = liked,
        -- list of things I don't like talking about
        ["topics_disliked"] = disliked,
        -- things we say about things we are indifferent to
        ["default_participation"] = {
            _("Yeah, okay."),
            _("Interesting."),
            _("Great!"),
            _("That sounds good."),
            _("Yeah."),
            _("Nice."),
            _("Alright."),
            _("Cool."),
            _("Oh, that's news to me."),
            _("Oh, cool."),
            _("Oh, sweet."),
            _("I'm down."),
            _("Okay."),
            _("Sure."),
            _("Whatever."),
            _("I don't think so. I know so."),
            _("I think so.")
        },
        -- responses to conversations about topics I don't like
        ["phrases_disliked"] = {
            _("Do we have to talk about this?"),
            _("All you ever talk about is {topic}."),
            _("It's {topic} this, {topic} that, you just can't get enough {topic} can you?"),
            _("Whatever."),
            _("Yeah, okay."),
            _("Right."),
            _("Sure."),
            _("Yeah, because of all the {topic}, of course."),
            fmt.f(_("I'd rather talk about {made_up}s than {topic}."), {made_up = getRandomThing(), topic = "{topic}"}),
			fmt.f(_("Don't be such a {insult}."), {insult = getInsultingProperNoun()}),
        }
    }

	-- TODO HERE: Generate some usages of suitable gift candidates
    -- give the character some unique bar actions
    character.conversation.bar_actions = {
        {
            ["verb"] = pick_one(
                {
                    _("swirling"),
                    _("sipping"),
                    _("drinking"),
                    _("enjoying"),
                    _("nursing"),
                    _("nursing on"),
                    _("chugging")
                }
            ),
            ["descriptor"] = pick_one(
                {
                    _("a"),
                    _("another"),
                    _("some"),
                    _("some kind of")
                }
            ),
            ["adjective"] = pick_one(
                {
                    _("cheerful"),
                    _("bizarre"),
                    _("steaming"),
                    _("iced"),
                    _("chilled"),
                    _("extravagant"),
                    _("foaming")
                }
            ),
            ["object"] = pick_one(
                {
                    _("drink"),
                    _("wine"),
                    _("tea"),
                    _("concoction"),
                    _("elixir"),
                    _("mixture of fluids"),
                    _("beverage"),
                    _("beer"),
                    _("coffee"),
                    _("spirit")
                }
            )
        }
    }

    return character
end

-- create a generic manager that only knows how to do payroll and assess the crew
local function createGenericManager()
    local crewmate = createGenericCrewmate()
    crewmate.manager = createGenericCrewManagerComponent()
	crewmate.manager.skill = "payroll"
    crewmate.skill = crewmate.manager.type
    crewmate.salary = math.ceil(2e3 * crewmate.xp)
    return crewmate
end

-- create a ship psychologist
local function createPsychologistManager( fac )
	local crewmate = createGenericCrewmate()
	crewmate.manager = createPsychologicalManagerComponent()
	crewmate.manager.skill = nil -- no special skills, only assessment, other medical officers will have something  here
	crewmate.manager.type = _("Psychology")
	crewmate.typetitle = _("Psychologist")
	crewmate.skill = _("Medical Officer")
	crewmate.salary = math.ceil(4e3 * crewmate.xp) + 12500
	crewmate.deposit = math.ceil(750e3 + (1 - crewmate.chatter) * 300e3)
	crewmate.other_costs = "Medicine"
	
	-- TODO: has a hook to move negative satisfaction towards zero
	
	-- fix conversation lines
	crewmate.conversation.default_participation = {
		_("Of course."),
		_("Sure."),
		_("Yes."),
		_("Good talk."),
		_("Sounds good."),
		_("Yeah."),
		_("Nice."),
		_("Alright."),
		_("I'm a bit busy, but you can trust me."),
		_("I'll do what I can."),
		_("I always do my best."),
		_("I do my best."),
		_("I'll do my best for you."),
		_("I aim to please."),
		_("You can count on me."),
	}
	
		crewmate.conversation.message = {
		fmt.f( _("{typetitle} {name} on deck.") , crewmate),
		fmt.f( _("{typetitle} {name} on duty.") , crewmate),
		fmt.f( _("{typetitle} {name} reporting.") , crewmate),
		fmt.f( _("{typetitle} {name} reporting in.") , crewmate),
		fmt.f( _("{skill} {name} on deck.") , crewmate),
		fmt.f( _("{skill} {name} reporting for duty.") , crewmate),
	}
	
	-- stifled laughter in captain's company
	table.insert(crewmate.conversation.special.laugh, _("*snickers* Right, captain?"))
	table.insert(crewmate.conversation.special.laugh, _("*snickers*"))
	table.insert(crewmate.conversation.special.laugh, _("*stifled laughter*"))
	
	-- instead of hysteria, we express ourselves openly about work pressure
	crewmate.conversation.special.hysteria = {
		_("The ship could use a {article_of_thought}."),
		_("The workload is getting to me."),
		_("The crew can be hard to manage sometimes. They need a {article_of_thought}."),
		_("There's always a troublemaker in the bunch."),
		_("Wait, what was that?"),
		_("What's going on over here?"),
		_("What is that over there?"),
		_("There's too much going on."),
		_("My ears are ringing."),
		_("I need that drink."),
		_("I could really use a drink right about now."),
		fmt.f(_("Is that a floating {thing}?"), { thing = getSpaceThing() }),
		_("Where are all the {article_of_thought}s?"),
	}
	
	return crewmate
end

-- TODO: create an advisory officer (can do a command assessment + payroll but no command tasks or command conversation)
-- basically this is the "first officer" before you have a lieutenant

-- first officer -- TODO: make sure the player has a lieutenant
-- does payroll and command
-- has a shuttle so you can't have a smuggler
-- probably the player can use the shuttle, and it's probably a shark or something like that
-- the personality is extremely chummy, as the command skill makes it easily excusable
-- the first officer also tries to be more helpful than other crew, those are vagabonds, in disarray
-- the first officer improves upon lesser managers, unlocks new hires and allows you to do
-- crazy things like rename your crew members, throw them out of the airlock, and so on
local function createFirstOfficer()
    local crewmate = createGenericCrewmate()
    crewmate.manager = createGenericCrewManagerComponent()
	crewmate.manager.skill = "payroll"
	crewmate.manager.type = "Command"
	crewmate.manager.cost = 8e3 -- I'm a commander, I'm expensive
    crewmate.skill = _("First Officer")
	crewmate.typetitle = "Lt. Commander"
    crewmate.salary = math.ceil(6e3 * crewmate.xp)
	crewmate.deposit = math.ceil(2e6 + (1 - crewmate.chatter) * 3e6)
	crewmate.shuttle = { ship = ship.get("Gawain") } -- later get upgraded to shark or lancelot maybe
	crewmate.hook = {
		["func"] = "command",
		["hook"] = nil
	}

	-- this is a "yes man"  personality
	crewmate.conversation.default_participation = {
		_("Of course."),
		_("Sure."),
		_("Yes."),
		_("Good talk."),
		_("Sounds good."),
		_("Yeah."),
		_("Nice."),
		_("Alright."),
		_("I'm a bit busy, but I'll do what I can."),
		_("I'll do what I can."),
		_("I always do my best."),
		_("I'll do my best.")
	}
	
	crewmate.conversation.message = {
		fmt.f( _("{typetitle} {name} on deck.") , crewmate),
		fmt.f( _("{typetitle} {name} on duty.") , crewmate),
		fmt.f( _("{typetitle} {name} reporting.") , crewmate),
		fmt.f( _("{typetitle} {name} reporting in.") , crewmate),
		fmt.f( _("{skill} {name} on deck.") , crewmate),
		fmt.f( _("{skill} {name} reporting for duty.") , crewmate),
	}
	
	-- stifled laughter in captain's company
	table.insert(crewmate.conversation.special.laugh, _("Right, captain?"))
	
	-- instead of hysteria, we express ourselves openly about work pressure
	crewmate.conversation.special.hysteria = {
		_("The pressure might be getting to me."),
		_("The workload is getting to me."),
		_("The crew can be hard to manage sometimes."),
		_("There's always a troublemaker in the bunch."),
		_("Wait, what was that?"),
		_("What's going on over here?"),
		_("What is that over there?"),
		_("There's too much going on."),
		_("My ears are ringing."),
		_("I need that drink."),
		_("I could really use a drink right about now."),
		fmt.f(_("Is that a floating {thing}?"), { thing = getSpaceThing() }),
	}
	-- we try to be overly positive no matter what
	crewmate.conversation.special.worry = {
		_("I'm sure there's nothing to worry about."),
		_("Nothing that a drink won't fix."),
		_("Nothing that a little motivation won't fix."),
		_("Nothing that a paradise world won't fix."),
		_("Nothing that a vacation won't fix."),
		_("Nothing that a good payday won't fix."),
		_("I'm sure everything will be alright."),
		_("Everything is fine."),
		_("Everything seems fine to me."),
		_("Things are fine."),
		_("Everything is going to be fine."),
		_("Everything is going to be alright."),
		fmt.f(_("Right {name}?"), {name = player.name()} ),
	}
	
	crewmate.conversation.special.going = {
		_("The goose is loose."),
		_("Shuttle outbound."),
		_("Shuttle mission active. First Officer on board."),
		_("First Officer shuttle mission engaged."),
		_("Shuttle mission is live."),
		_("Shuttle outbound, see you soon captain."),
	}
	
	crewmate.conversation.special.coming = {
		_("Approach vector set and shuttle inbound."),
		_("Approach vector on course."),
		_("Shuttle inbound."),
		_("Shuttle incoming, stand by."),
		_("Shuttle inbound to dock, please stand by."),
		_("Shuttle on approach vector, stand by for docking."),
		_("First Officer reporting in."),
	}
	
	crewmate.conversation.special.arrived = {
		_("Shuttle is docked and secure."),
		_("Docking bays secure, I'm back."),
		_("Shuttle secure, and so am I."),
		_("Shuttle docked."),
		_("Shuttle safely in the docking bay."),
		_("Docking successful."),
	}
	
	local lines = crewmate.manager.lines
	
	lines.satisfied = join_tables(lines.satisfied, {
		_("I'm feeling positive."),
		_("Business is good."),
		_("Keep up the good work."),
		_("There's something about this place."),
		_("Everyone is having a pleasant time."),
		_("The crew having a lovely time."),
		_("Everyone seems to be enjoying this ship."),
		_("What can I say, we love the ship."),
		fmt.f(_("I'm taking a liking to this {ship}."), {ship = player.pilot():ship():name()}),
		_("I've got a good feeling, things are looking up."),
		_("How about that drink later?"),
		_("I will enjoy a strong but relaxing drink, will you join me?"),
		_("I'll have a nice drink tonight. You can join me if you'd like"),
		fmt.f(
			_("I have been brushing up on my {made_up}. Would you like to spar later on?"),
			{made_up = getMadeUpName()}
		),
		_("I've been talking with some of the crew, they like the available fruit."),
		fmt.f(_("Did I tell you about the creature from {place}?"), {place = spob.get(faction.get("Soromid"))}),
		_("I had to scold some of the crew earlier, I'll spare you the details, it's no big deal."),
		_("I feel like we are on a winning streak."),
		_("I feel like we are on a lucky streak."),
		_("I feel like we are on a lucky roll."),
		_("Things are going alright, aren't they?"),
		_("Things are good, huh?"),
		_("Overall, I'd say things are looking pretty good."),
		_("Sometimes there are bad times, but these aren't the worst of times."),
		_("Things have definitely been worse."),
		_("If we have an eligible shuttle and cargo that we can sell locally, we can send a pilot or I can take it myself. It's a real time saver."),
		_("I've been noticing a lot of positivity among the crew."),
		_("I think most of the crew is fairly happy."),
		_("With a captain like you, it's no wonder we're all so happy. There's nothing to worry about."),
		_("You shouldn't be having any problems with this crew. Everyone seems to be perfectly happy."),
		_("I think the crew could use a drink on a nice luxurious world, but for now there's nothing to worry about."),
		_("Don't worry about the crew, there's nothing wrong that a drink won't fix."),
		_("The crew seems fine. That's not what I'm worried about."),
		_("I wouldn't worry about the crew, at least not for a while."),
	})
	
	local jlabel = _("Sanitation")
	local slabel = _("Short Staffed")
	local olabel = _("Overstaffed")
	
	lines[jlabel] = {
		_("You need more janitors doing their job."),
		_("You need more sanitation workers."),
		_("You need more janitorial workers."),
		_("You might need to hire more janitorial staff"),
		_("You might need to motivate janitorial staff"),
		_("The ship is getting dirty, we need more dedication to sanitation."),
		_("We're unable to keep the ship clean as it stands."),
		_("We need more staff dedicated to cleaning."),
		_("We need more focus on the janitorial staff."),
		_("We need more dedication to the cleaning efforts."),
		_("We have to do something about this mess."),
		_("We have to do something about the uncleanliness."),
		_("We have to do something about all the grime."),
	}
	
	lines[slabel] = {
		_("We're a little short staffed."),
		_("We could use some more workers."),
		_("We could use some more crew on general duty."),
		_("We don't have enough crew for a ship of this size."),
		_("We have more tasks that need doing than we have crew members."),
		_("The workload is too high for a crew of this size."),
		_("A ship like this needs a much larger crew."),
		_("We don't have enough crew members on board."),
		_("We need to hire more crew members."),
	}
	
	lines[olabel] = {
		_("We're overstaffed."),
		_("We are paying a lot of workers."),
		_("We could use less crew on general duty."),
		_("We have enough crew for a ship of this size."),
		_("We have too many crew members for a ship of this size."),
		_("We have more crew that need doing than we have tasks."),
		_("A ship like this needs a smaller crew."),
		_("A ship like this needs a tighter crew."),
		_("We don't have enough space for all our crew members on board."),
		_("We should fire some crew members, like maybe {name}."),
		_("We should fire someone with {xp:.0f} experience or less."),
		_("We should fire some crew members, perhaps {firstname}."),
		_([[All you have to do is say  "fire {firstname}" and {article_subject} goes out the airlock.]]),
		_([[If you tell me to  "throw {firstname} out of the airlock" then that's where {article_subject} goes.]]),
	}
	
	lines.promising = {
	    _("{firstname} has {xp:.2f} experience points!"),
		_("Everything is looking great, how about that {firstname}?"),
        _("{name} has been showing signs of excellence."),
        _("{name} has been performing exceptionally."),
        _("{firstname} is doing well."),
        _("I've heard a lot of praise about {name}."),
        _("You should keep an eye on {firstname}."),
		_("On a scale of about ten, I'd put one of your {typetitle}'s happiness at around {satisfaction:.1f}."),
		_("On a scale to around ten, I'd put one of your {typetitle}'s experience level at around {xp:.1f}."),
		_("Smooth sailing, just the way I like it."),
		_("Smooth sailing, just how I like it."),
		_("Smooth sailing, exactly as I like it."),
		_("Nothing but clear skies."),
		_("Get a load of that view!"),
		_("Nothing but nebula and adventures ahead."),
		_("We're living the dream."),
		fmt.f(_("Have you heard the one about the {foo} and the {bar}?"), { foo = getMadeUpName(), bar = getMadeUpName() } ),
		fmt.f(_("Have I told you the one about the {foo} and the {bar} in the {thing}?"), { foo = getMadeUpName(), bar = getMadeUpName(), thing = getSpaceThing() } ),
		fmt.f(_("A {foo}, a {bar} and a {biz} walk into a {place} searching for some {fruit}... Oh wait, I've told you this one already haven't I?"), { foo = getMadeUpName(), bar = getMadeUpName(), biz = getMadeUpName(), place = getSpaceThing(), fruit = getRandomFruit() } ),
		_("I would really love a banana right about now."),
		fmt.f(_("I would really love a {banana} right about now."), { banana = getRandomFruit() }),
		fmt.f(_("Say, would you like this {banana}?"), { banana = getRandomFruit() }),
		fmt.f(_("Do you want this {banana}? I have another one for me."), { banana = getRandomFruit() }),
		_("Good times ahead."),
		_("How's the budget? The staff is great!"),
		_("If it were appropriate, I would kiss you."),
	}
	
	lines.troublemaker = join_tables(lines.troublemaker, {
        _("Perhaps we can commend {name} to try to motivate {article_object}."),
		_("Perhaps you'd like for me to commend {name} to try to motivate {article_object} a bit."),
		_("Perhaps you'd like for me to commend {name} to try to cheer {article_object} up a bit."),
		_("You might want to ask me to restock the bananas."),
		fmt.f(_("You might want to ask me to restock the {banana}s."), { banana = getRandomFruit() } ),
		_([[If you ask me to "restock fruit" with food in our cargo, I'll have it ready by the next time we talk.]]),
		fmt.f(_([[If you ask me to commend {name}, I'll get {article_object} something nice to make {article_object} feel better.]]), crewmate)
	})
	
	lines.specific = {
		_("Yes... {article_subject} probably scores around {satisfaction:.0f}."),
		_("Let's see... {article_subject} has an experience level around {xp:.0f} according to my notes."),
		_("That {skill} {typetitle} has an experience level of {xp:.0f} and a happiness score of {satisfaction:.0f}."),
		_("I would put {article_object} at around {satisfaction:.0f} on the happiness scale."),
		_("{firstname}? What do you want to know about {article_object}?"),
		_("I don't think you should worry about the {skill}s too much."),
		_("I don't think you should worry about that {typetitle} too much."),
		_("I think that {article_subject} is doing fine, don't even worry about it."),
		_("I think that {article_subject} is doing fine, don't worry about {article_object}."),
		_("Come on, {article_subject} is fine, don't worry about {article_object}."),
		_("I think {article_subject} is alright, is something wrong with {article_object}?"),
		_("Why are you asking about {article_object}? Should I keep an eye on the {skill}s?"),
		_("{firstname}? Should I be keeping a closer eye on the {skill}s?"),
		_("According to my notes, {article_subject}'s got around {xp:.1f} experience."),
		_("Based on my best judgement, {article_subject} seems to be feeling like a solid {satisfaction:.1f}."),
		_("That {skill} {typetitle} has an experience level of {xp:.1f}."),
		_("That {skill} {typetitle} has a happiness score of {satisfaction:.0f}."),
		_("That {skill} {typetitle} has a satisfaction score of {satisfaction:.0f}."),
		_("That {skill} {typetitle} ranks at {xp:.0f} experience and seems to be around {satisfaction:.0f} in mood."),
		_("{firstname} has a satisfaction score around {satisfaction:.1f}."),
		_("{name}'s experience level is around {xp:.1f}."),
		_("{name} has an experience level of {xp:.0f} and a happiness score of {satisfaction:.0f}."),
		_("I would rate {article_object} at around {satisfaction:.0f} these days."),
	}
	
	crewmate.manager.lines = lines
	
	-- fix up the manager lines a bit more
	table.insert(crewmate.manager.lines.unsatisfied, _("The crew seems fine. That's not what I'm worried about."))
	table.insert(crewmate.manager.lines.unsatisfied, _([[Try saying "banana" to me.]]))
	table.insert(crewmate.manager.lines.unsatisfied, _([[Try saying "list cadets" to me if you're having trouble remembering their names.]]))
	table.insert(crewmate.manager.lines.unsatisfied, _([[Tell me who or what you're worried about.]]))
	table.insert(crewmate.manager.lines.unsatisfied, fmt.f(_([[If you tell me to commend {name}, I'll use the reward to treat myself.]]), crewmate))
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("I wouldn't worry about the crew, but they are getting kind of tense.")
    )
    table.insert(crewmate.manager.lines.unsatisfied, _("There is a slight chance of some animosity between the crew."))
    table.insert(crewmate.manager.lines.unsatisfied, _("There is a slight chance of some hostility within the crew."))
	table.insert(crewmate.manager.lines.unsatisfied, _("I hope you know that you can ask me to commend specific crew members for a small fee."))
	table.insert(crewmate.manager.lines.unsatisfied, _("You might want to ask me to commend specific crew members, it only costs a small fee to be effective."))
	table.insert(crewmate.manager.lines.unsatisfied, _("You might want to ask me to restock some fruit, it only costs a small fee and a ton of food."))
	table.insert(crewmate.manager.lines.unsatisfied, _("You might want to ask me to dig out some fruit, it only costs a small fee and a ton of food."))
	table.insert(crewmate.manager.lines.unsatisfied, _("I won't show you everything I can do. You have to talk to me. Banana?"))
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("With a captain like you, it's no wonder we're usually all so happy. I'm sure things will get better.")
    )
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("With a captain like you, it's a wonder the situation is so dire. Maybe I can try to motivate them?")
    )
	
    return crewmate
end

-- creates a "Pilot" that can pilot the shuttle, or perhaps the ship sometimes too if the captain wants autopilot
local function createShuttlePilot()
	local crewmate = createGenericCrewmate()
	crewmate.manager = createUselessManagerComponent()
	crewmate.manager.type = _("Shuttle")
	crewmate.typetitle = _("Pilot")
	crewmate.skill = _("Pilot") -- NOTE: can get promoted to ensign etc
	crewmate.other_costs = pick_one({"Medicine", "Luxury Goods", "Gold", "Diamonds"}) -- maybe some metals for repairs?
	
	crewmate.conversation.message = {
		_("Shuttle en route."),
		_("Shuttle is out."),
		_("Shuttle outbound."),
		_("Shuttle mission is active."),
		_("The shuttle is out."),
		_("I've got it. Shuttle mission active."),
		_("I'm on this. In the shuttle."),
		_("I've got this. Shuttle outbound."),
	}
	
	crewmate.conversation.backstory.intent = pick_one({
		_("Look, I'm a pilot, it's as simple as that."),
		_("I'll fly your ship or any of your shuttles for you."),
		_("As long as you have a shuttle for me to use, I'll be ready for action."),
		_("They say I'm the best in the business. Do you need a pilot or what?"),
		_("I'm a pilot. You need a bay or a dock and a shuttle for me to use. You need a pilot to sell cargo without landing, it saves time, get it?"),
	})
	
	crewmate.conversation.special.going = {
		_("Shuttle en route."),
		_("Shuttle is out."),
		_("Shuttle outbound."),
		_("Shuttle mission is active."),
		_("The shuttle is out."),
		_("I've got it. Shuttle mission active."),
		_("I'm on this. In the shuttle."),
		_("I've got this. Shuttle outbound."),
	}
	
	crewmate.conversation.special.coming = {
		_("Approach vector set and shuttle inbound."),
		_("Approach vector on course."),
		_("Shuttle inbound."),
		_("Shuttle incoming, stand by."),
		_("Shuttle inbound to dock, please stand by."),
		_("Shuttle on approach vector, stand by for docking."),
	}
	
	crewmate.conversation.special.arrived = {
		_("Shuttle is docked and secure."),
		_("Docking bays secure."),
		_("Shuttle secure."),
		_("Shuttle docked."),
		_("Shuttle safely in the docking bay."),
		_("Docking successful."),
	}
	
	return crewmate
end

-- special escort companion doesn't do payroll but is a great satisfaction buffer for the crew
-- basically the kind of crewmate that stands out a bit and is more helpful while the player learns to manage crew
-- eventually the player should aim to replace the companion escort with a personnel manager with the payroll skill
local function createEscortCompanion()
    local crewmate = createGenericCrewmate()
    crewmate.manager = createGenericCrewManagerComponent()
    crewmate.typetitle = "Companion" -- generic type, doesn't do anything but might pay rent
    crewmate.skill = "Escort"
    crewmate.satisfaction = rnd.rnd(1, 3)
    crewmate.threshold = 100e3 -- how much they need to be happy after doing a paid job

    crewmate.manager.cost = math.floor(1e3 * crewmate.xp) -- the escort companion is cheaper than a generic manager, depends on starting xp
    -- should give us a fairly low salary, but we probably won't use this field often, or we'll have an exception or something
    crewmate.salary = math.floor(crewmate.xp * crewmate.satisfaction) * 10

    -- the escort companion is a bit more intimate with the captain and will
    -- talk about previous love affairs with characters of the opposite sex
    -- but for some translations, it might make sense to use something else like "my heart"
    -- used like "I wonder what she's up to these days"
    local opposite_article = _("she")
    -- 95% chance of female character to introduce large bias
    if rnd.rnd() < 0.95 then
        crewmate.gender = _("Female")
        crewmate.article_object = _("her")
        crewmate.article_subject = _("she")
        opposite_article = _("he")
        
		crewmate.vncharacter = pick_one({
			"neutral/female1.webp",
			"neutral/female2_nogog.webp",
			"neutral/female3.webp",
		})
		
		crewmate.portrait = string.gsub(string.gsub(crewmate.vncharacter, ".webp", "n.webp"), "_nogogn", "n_nogog")
		
		-- maybe give her a new name
		if rnd.rnd(0, 1) == 0 then
		crewmate.name = fmt.f("{made_up}{vowel}", {
			made_up = getMadeUpName(),
			vowel = pick_str("aeiouy")
		})
		end
    end

    -- customize the conversation table with new backstory
	crewmate.conversation.backstory = generateBackstory(crewmate)

	-- what I say when I'm doing my job
	crewmate.conversation.message = {"I would never kiss and tell."}
	-- what I say when I'm satisfied
	crewmate.conversation.satisfied = join_tables(crewmate.conversation.satisfied, {
		_("I'm feeling positive."),
		_("Business is good."),
		_("Keep up the good work."),
		_("There's something about this place."),
		_("I hope you're all having a pleasant time."),
		_("I hope you're having a lovely time."),
		_("I'm really enjoying this ship."),
		_("I love this ship."),
		fmt.f(_("I'm taking a liking to this {ship}."), {ship = player.pilot():ship():name()}),
		_("I've got a good feeling, things are looking up."),
		_("I will lavish myself in luxury tonight."),
		_("I will enjoy some luxuries tonight."),
		_("I will reap my rewards tonight."),
		fmt.f(
			_("I recently acquired a sample of {made_up}'s latest youth serum. Would anyone care to try some?"),
			{made_up = getMadeUpName()}
		),
		_("I'm expecting a call from a customer soon, I'll spare you the details."),
		fmt.f(_("Did I tell you about the bison from {place}?"), {place = spob.get(faction.get("Dvaered"))}),
		_("I have a scheduled call with a client soon, I'll spare you the details."),
		_("I feel like we are on a winning streak."),
		_("I feel like we are on a lucky streak."),
		_("I feel like we are on a lucky roll."),
		_("Things are going alright, aren't they?"),
		_("Things are good, huh?"),
		_("Were any of you at the party last night? Wait, when was the party again? My sleep cycle is off again."),
		_("Overall, I'd say things are looking pretty good."),
		_("Sometimes there are bad times, but these aren't the worst of times."),
		_("Things have definitely been worse.")
	})
	-- what I say when not satisfied
	crewmate.conversation.unsatisfied = join_tables(crewmate.conversation.unsatisfied, {
		_("I am quite unhappy."),
		_("I've been better."),
		_("I'm not feeling so well."),
		_("I worry about my financial situation."),
		_("I haven't had a good customer in far too long."),
		_("I haven't been able to visit my regular clients."),
		_("My customers are hungry, I don't know what to tell them."),
		_("Are we going anywhere nice soon?"),
		_("Please tell me we are headed towards civilization."),
		_("What in heavens are we even doing out here?"),
		_("My patience is wearing thin."),
		_("I would advise you to tread carefully."),
		_("Don't test me right now."),
		_("My patience is running out.")
	})
	
	-- maybe we don't want the generic things too here, idk
	-- things I say about {name} when I had a good conversation
	crewmate.conversation.good_talker = join_tables(crewmate.conversation.good_talker, {
		_("I like talking with {name}."),
		_("I like {name}."),
		_("We've had some good conversations."),
		_("I think {name} likes me."),
		_("{name} is nice."),
		_("{name} seems nice."),
		_("{name} is a dear isn't {article_subject}."),
		_("Isn't {article_subject} a dear."),
		_("{name} is lovely."),
		_("That was pleasant."),
		_("That was pleasant of {article_object}."),
		_("That was nice of {article_object}."),
		_("Don't forget to enjoy the view. Look at that bright one over there. I think it's a moon."),
		_("On a happiness scale to somewhere around ten, I'd put you at around {satisfaction}."),
		_("That was pretty smart for someone with {skill} expertise."),
		_("I wouldn't have expected that from some {typetitle} with {skill} expertise.")
	})
	-- things I say about {name} when I had a bad conversation
	crewmate.conversation.bad_talker = join_tables(crewmate.conversation.bad_talker, {
		_("{name} is too negative."),
		_("I dislike {name}."),
		_("I dislike {article_object}."),
		_("I'm not fond of {name}."),
		_("I'm not very fond of {article_object}."),
		_("I am not a fan of {name}."),
		_("I'm not friends with {name}."),
		_("I'm not friends with {article_object}."),
		_("I don't want to associate with {article_object}."),
		_("I don't enjoy my conversations with {article_object}."),
		_("I think {article_subject}'s being offensive."),
		_("Sometimes I wonder if you have any {skill} experience at all.")
	})
	
	crewmate.conversation.fatigue = join_tables(crewmate.conversation.fatigue, {
		_("I hope we're going somewhere nice."),
		_("I hope we'll land soon, preferably somewhere nice."),
		_("It can be a bit lonely out here sometimes."),
		_("Will someone join me for a spa?"),
		_("I'm going to take a bath later if someone wants to join."),
		_("I could use a break."),
		_("I'm a bit tired."),
		_("I could use some rest."),
		_(
			"You know I need my wealthy planets, don't let me be the black sheep of the bunch that's bringing everyone down."
		)
	})
	crewmate.conversation.bar_actions = join_tables(crewmate.conversation.bar_actions, {
		{
			["verb"] = pick_one(
				{
					_("seducing"),
					_("talking to"),
					_("gesturing at"),
					_("giggling at")
				}
			),
			["descriptor"] = pick_one(
				{
					_("some"),
					_("a"),
					_("a")
				}
			),
			["adjective"] = pick_one(
				{
					_("nice looking"),
					_("strange"),
					_("shady"),
					_("handsome"),
					_("dark"),
					_("mysterious"),
					_("preoccupied"),
					_("unknown")
				}
			),
			["object"] = pick_one(
				{
					_("stranger"),
					_("person"),
					_("man"),
					_("woman"),
					_("interloper"),
					_("dock worker"),
					_("crew member")
				}
			)
		}
	})
	-- special things I know how to say
	-- definitely overwrite whatever was in there before because we might pick
	-- random things from any topic here sometimes and we design the character
	-- "here" and not in the generic template
	crewmate.conversation.special = {
		["laugh"] = {
			_("*giggles*"),
			_("Hah!"),
			_("Haha!"),
			_("*laughs hysterically*"),
			_("*laughs briefly*")
		},
		["worry"] = {
			_("I hope I manage to secure a client on the next world."),
			_("Things just aren't as good as they used to be."),
			_("I'm growing increasingly concerned."),
			_("I feel as if I'm being reduced to nothing."),
			_("We are going to have to do something about that."),
			_("There are situations that need to be addressed."),
			_("From my viewpoint, things could be better."),
			_("I worry about the violence on this ship."),
			_("I'm a bit worried")
		}
	}
	crewmate.conversation.smalltalk_positive = join_tables(crewmate.conversation.smalltalk_positive, {
		_("What a lovely view."),
		_("I'll be in my quarters."),
		_("I wish I could tell you about my last customer."),
		_("I like being surrounded by all this science."),
		_("Of all my travels, this is my favourite journey so far.")
	})
	-- unique negative smalltalk to be distinguishable from regular crew
	crewmate.conversation.smalltalk_negative = {
		_("I really need a break... To bathe myself in luxury."),
		_("I've seen better days."),
		_("The viewscreen in my quarters is malfunctioning, could you help me repair it?"),
		_("I'm getting tired of all these backwater worlds."),
		_("I'll be in my quarters."),
		_("Business could be better."),
		_("I wish I could tell you about my last customer..."),
		_("What? I don't want to talk about it."),
		_("I'm not making enough credits to keep up with my luxurious lifestyle.")
	}
	
	-- overwrite whatever topics we liked or disliked in our template
	-- list of things I like to talk about and what I say about them
	-- we'll start with a small set of topics/interests and therefore
	-- "be better at learning" because there's less noise to choose from
	crewmate.conversation.topics_liked = {
		-- list of phrases that use the things I like (or not)
		["luxury"] = {
			_("Do you want to see my new hat?"),
			_("How do you like this vintage neck-scarf?"),
			_("What do you think about this color?")
		},
		-- normally, I call this "friend", but I don't want the companion to always
		-- be talking about their friends or cat, at least not that often
		["friendship"] = {
			fmt.f(_("Check out this {ship} my friend thinking of buying."), {ship = getRandomShip()}),
			_("Do you want to see some pictures of my neice?"),
			_("I like how close we are."),
			_("I know we've had our differences, but you're alright."),
			_("I fear that we are becoming a bit too intimate."),
			_("Have I told you about my cat?"),
			_("Did I tell you about my cat?"),
			_("Do you want to see my kitty?"),
			_("Do you want to see my cat?"),
			_("Don't you just love my kitty?")
		},
		["travel"] = {
			fmt.f(
				_("One of my favourite places to visit is {place}. Have you been there?"),
				{place = spob.get(faction.get("Independent"))}
			),
			fmt.f(
				_("I fell in love with a pirate from {place}. I wonder what {article}'s up to these days."),
				{place = spob.get(faction.get("Raven Clan")), name = pilotname.human(), article = opposite_article}
			),
			fmt.f(
				_("If you've never been to {place}, we should go."),
				{place = spob.get(faction.get("Independent"))}
			),
			fmt.f(
				_("An intriguing place to visit is {place}. Have you been there?"),
				{place = spob.get(faction.get("Za'lek"))}
			),
			fmt.f(
				_("I heard that {place} is developing a new {made_up}. What do you make of that?"),
				{place = spob.get(faction.get("Za'lek")), made_up = getMadeUpName()}
			),
			fmt.f(
				_("Of all my travels I must say, I've been too often to {place}. I don't mind the work."),
				{place = spob.get(faction.get("Empire"))}
			),
			fmt.f(
				_(
					"I had an affair with a servant from {place}. I wonder what meddlesome {name} is up to these days."
				),
				{place = spob.get(faction.get("Dvaered")), name = pilotname.human()}
			),
			fmt.f(
				_(
					"All the violence and lawlessness on {place} led my sister {name} towards a path of disastrous affairs."
				),
				{place = spob.get(faction.get("Dvaered")), name = pilotname.human()}
			),
			fmt.f(
				_("I went to {place} just to check it out. I haven't had the urge to go since."),
				{place = spob.get(faction.get("Soromid"))}
			),
			fmt.f(
				_("I went to {place} just to check it out. I don't recommend it."),
				{place = spob.get(faction.get("Soromid"))}
			)
		},
		["view"] = {
			_("Did you enjoy the view?"),
			_("Did you notice the spectacular view towards the star?"),
			_("What a wonderful view. The stars are amazing."),
			_("What an amazing view!"),
			_("What are you looking at?"),
			_("Are you enjoying the view?"),
			_("Keep your hands to yourself or I'll have to charge you some credits."),
			_("I like looking out at the stars."),
			_("How could anyone not admire this view?")
		}
	}
	-- list of things I don't like talking about
	-- put a bunch of things related to violent thoughts here
	crewmate.conversation.topics_disliked = {
		_("violence"),
		_("credits"),
		_("fear"),
		_("death"),
		_("kill"),
		_("poor"),
		_("trash"),
	}
	-- things we say about things we are indifferent to
	crewmate.conversation.default_participation = join_tables(crewmate.conversation.default_participation, {
		_("Of course."),
		_("Sure!"),
		_("That sounds good."),
		_("That sounds nice."),
		_("Sounds good."),
		_("Yeah."),
		_("Nice."),
		_("Alright."),
		_("I'm a bit busy, but I'll do what I can."),
		_("I'll do what I can."),
		_("I always do my best."),
		_("I'll do my best.")
	})
	-- responses to conversations about topics I don't like
	-- generally something dismissive but the companion is a bit diplomatic but can be dramatic
	crewmate.conversation.phrases_disliked = {
		_("Do we have to talk about this?"),
		_("All you ever talk about is about {topic}."),
		_("It's {topic} this, {topic} that, you just can't get enough {topic} can you?"),
		_("Whatever."),
		_("Yeah, okay."),
		_("I am not interested in that at all. Can we talk about something else?"),
		_("Sorry, not interested."),
		_("Right."),
		_("Sure."),
		_("Yeah, because of all the {topic}, of course."),
		_("Please give me some privacy."),
		_("I would like to be dismissed."),
		_("I have something else I have to do.")
	}
    
    crewmate.hook = {
        ["func"] = "escort",
        ["hook"] = nil
    }

    -- fix up the manager lines a bit to add some flavor
    table.insert(crewmate.manager.lines.satisfied, _("I've been noticing a lot of positivity among the crew."))
    table.insert(crewmate.manager.lines.satisfied, _("I think most of the crew is fairly happy."))
    table.insert(
        crewmate.manager.lines.satisfied,
        _("With a captain like you, it's no wonder we're all so happy. There's nothing to worry about.")
    )
    table.insert(
        crewmate.manager.lines.satisfied,
        _("You shouldn't be having any problems with this crew. Everyone seems to be perfectly happy.")
    )
    table.insert(
        crewmate.manager.lines.satisfied,
        _("I think the crew could use a break on a nice luxurious world, but for now there's nothing to worry about.")
    )
    table.insert(
        crewmate.manager.lines.satisfied,
        _("Don't worry about the crew, there's nothing wrong that a spa won't fix.")
    )
    table.insert(crewmate.manager.lines.satisfied, _("The crew seems fine. That's not what I'm worried about."))
    table.insert(crewmate.manager.lines.satisfied, _("I wouldn't worry about the crew, at least not for a while."))

    table.insert(crewmate.manager.lines.unsatisfied, _("The crew seems fine. That's not what I'm worried about."))
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("I wouldn't worry about the crew, but they are getting kind of tense.")
    )
    table.insert(crewmate.manager.lines.unsatisfied, _("There is a slight chance of some animosity between the crew."))
    table.insert(crewmate.manager.lines.unsatisfied, _("There is a slight chance of some hostility within the crew."))
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("With a captain like you, it's no wonder we're usually all so happy. I'm sure things will get better.")
    )
    table.insert(
        crewmate.manager.lines.unsatisfied,
        _("With a captain like you, it's a wonder the situation is so dire.")
    )

	crewmate.manager.lines.promising = {
	    _("Perhaps you should speak with {firstname}."),
        _("{name} has been showing signs of excellence."),
        _("{name} has been performing exceptionally."),
        _("{firstname} is being followed by good fortune."),
        _("I've heard a lot of praise about {name}."),
        _("You should keep an eye on {firstname}."),
		_("On a scale of about ten, I'd put one of your {typetitle}'s happiness at around {satisfaction:.0f}."),
		_("On a scale to around ten, I'd put one of your {typetitle}'s experience level at around {xp:.0f}."),
	}
    crewmate.manager.lines.troublemaker = {
        _("Perhaps you should speak with {name}."),
        _("You need to listen to your crew."),
        _("{name} did complain about some things."),
        _("{name} has been complaining about some issues."),
        _("{name} has been mentioning problems."),
        _("{name} is being followed by trouble."),
        _("{typetitle} problems. Yes. We should talk to them."),
        _("The {typetitle} situation could be better."),
        _("I've heard some backtalk about {name}."),
        _("I have heard rumors."),
        _("We should probably keep a better eye on {name}."),
        _("There is some unresolved tension between {name} and the rest of the crew."),
        _("Let's not get into it right now. Let me just say that it's not looking good."),
        _("I don't want to point any fingers."),
        _("Don't say I didn't warn you. Can we leave it at that?")
    }
	
	crewmate.manager.lines.specific = {
			_("{firstname} has a satisfaction score around {satisfaction:.0f}."),
			_("{name}'s experience level is around {xp:.1f}."),
			_("{name} has an experience level of {xp:.0f} and a happiness score of {satisfaction:.0f}."),
			_("I would rate {article_object} at around {satisfaction:.0f}."),
		}

    return crewmate
end

-- smuggler hangs out in cargo bay and tries to smuggle commodities to a nearby world that sells them
-- gets bonuses based on cargo bay workers
-- supposed to be a powerful early-game crew
local function createSmuggler()
	local crewmate = createGenericCrewmate()
	crewmate.manager = createUselessManagerComponent()
	crewmate.manager.type = _("Stock")
	crewmate.typetitle = _("Smuggler")
	crewmate.skill = _("Smuggler")
	crewmate.salary = 0
	crewmate.bonus = 0
	crewmate.other_costs = pick_one({"Medicine", "Food", "Luxury Goods"})
	crewmate.chatter = 0.2 + rnd.twosigma() * 0.1
	crewmate.deposit = math.ceil(1e6 + (1 - crewmate.chatter) * 2e6)
	crewmate.shuttle = {}
	crewmate.hook = {
        ["func"] = "smuggler",
        ["hook"] = nil
    }
	crewmate.conversation.backstory.intent = pick_one({
		_("Look, I'm a smuggler, it's as simple as that."),
		_("You point to a planet, you open the cargo bay, I tell you what I can take, capiche?"),
		_("As long as you have a fighter bay on your ship, I should be able to do my job."),
		_("I don't really like talking to strangers. Do you need a smuggler or what?"),
		_("I'm a smuggler. You need a bay or a dock. I'll be in the cargohold if you need me."),
	})
	crewmate.conversation.satisfied = {
		_("I'll be in the cargo bay if you need me."),
	}
	crewmate.conversation.unsatisfied = {
		_("I'll be in the cargo bay if you need me. *scoffs*"),
	}
	crewmate.conversation.good_talker = {
		_("Yeah, {article_subject}'s alright."),
		_("I actually don't mind {article_object} that much."),
		_("I'll be in the cargo bay if you need me."),
	}
	crewmate.conversation.bad_talker = {
		_("Yeah, {article_subject}'s not listening."),
		_("I wanna skin {article_object} so much."),
		_("Drop it."),
		_("Just drop it."),
		_("I'll be in the cargo bay if you need me."),
		fmt.f(_("Maybe some of you would like to play {game} in the cargo bay sometime. It gets lonely."), {game = getShipboardActivity("game") } )
	}
	crewmate.conversation.special.coming = {
		_("Hold on, I gotta realign the docking clamps."),
		_("I'm coming, give me a minute."),
		_("It might take a while to fully align once I'm close enough."),
		_("Hold your horses buster, I'm doing the best that I can here."),
	}
	crewmate.conversation.special.arrived = {
		_("Got it."),
		_("Check your logs."),
		_("Not bad."),
		_("I've seen worse."),
		_("I'm here."),
		_("We're in."),
		_("I'm back."),
	}
	crewmate.conversation.special.going = crewmate.conversation.message
	
	return crewmate
end

-- hull integrity engineer repairs armour when not under any stress at cost of energy and shields
-- generates a lot of heat but can also repair when near death
-- good for when you want to be able to take armour damage in a shield ship
-- and if you have a lot of armour hitpoints (each uninterrupted healing cycle increases healing bonus)
-- gets bonuses based on maintenance workers
local function createArmorEngineer(fac)
	local crewmate = createGenericCrewmate()
	crewmate.faction = fac
	crewmate.typetitle = "Engineer"
	crewmate.skill = "Hull Integrity"
	crewmate.salary = 3e3 * (crewmate.xp * crewmate.satisfaction)
	crewmate.other_costs = pick_one({"Diamond", "Ore", "Gold"})
	crewmate.chatter = 0.4 + rnd.twosigma() * 0.2
	crewmate.hook = {
		["func"] = "engihull",
		["hook"] = nil
	}
	crewmate.conversation.message = {
		_("Power levels normal."),
		_("Everything is within parameters."),
		_("Engineering reporting: Everything is OK."),
		_("We're doing fine down here."),
		_("Systems are online."),
		_("We are back to full power."),	
	}
	crewmate.conversation.backstory.intent = pick_one({
		_("Everyone needs an engineer, maybe two."),
		_("I'll make sure your power doesn't go to waste."),
		_("I'm specialized in hull integrity engineering."),
		_("You'll be glad to have an engineer like me on your ship, believe me."),
		fmt.f(_("I once fixed a {thing} on a three hour spacewalk."), {thing = getSpaceThing() } ),
		_("You might need me in a situation, think about that."),
		_("I'll get you out of a tough spot, or rather, I'll keep you in one piece for the trip back."),
		_("Danger is my middle name! Well, within reasonable parameters."),
	})
	crewmate.conversation.special.engine = {
		_("Easy does it..."),
		_("Easy girl..."),
		_("There, girl..."),
		_("There we go..."),
		_("You can do it, come on..."),
		_("I know we can do this..."),
		_("I got this."),
		_("You got this."),
		_("Trust the engine."),
		_("Everything will be alright."),
		fmt.f(_("Come on {made_up} engine don't fail me now."), { made_up = getMadeUpName() }),	
	}
	crewmate.conversation.special.worry = join_tables(crewmate.conversation.special.worry, {
		_("Probably."),
		_("If my calculations are correct..."),
		_("Did I double check those calculations?"),
		_("Wait a minute..."),
	})
	
	return crewmate
end

local function createPowerEngineer(fac)
	local crewmate = createArmorEngineer()
	crewmate.faction = fac
	crewmate.typetitle = "Engineer"
	crewmate.skill = "Core Stabilization"
	crewmate.salary = 3e3 * (crewmate.xp * crewmate.satisfaction)
	crewmate.other_costs = pick_one({"Diamond", "Ore", "Gold"})
	crewmate.chatter = 0.4 + rnd.twosigma() * 0.2
	crewmate.hook = {
		["func"] = "engipowr",
		["hook"] = nil
	}
	crewmate.conversation.message = {
		_("System levels normal."),
		_("Everything is within parameters."),
		_("Engineering reporting: Everything is OK."),
		_("We're doing fine down here."),
		_("Systems are online."),
	}
	crewmate.conversation.backstory.intent = pick_one({
		_("Everyone needs an engineer, maybe two."),
		_("I'll make sure your power doesn't go to waste."),
		_("I'm specialized in reactor engineering."),
		_("You'll be glad to have an engineer like me on your ship, believe me."),
		fmt.f(_("I once fixed a {thing} on a three hour spacewalk."), {thing = getSpaceThing() } ),
		_("You might need me in a situation, think about that."),
		_("I'll get you out of a tough spot, or rather, I'll keep you in one piece for the trip back."),
		_("Danger is my middle name! Well, within reasonable parameters."),
	})
	
	return crewmate
end

local function createShieldEngineer(fac)
	local crewmate = createPowerEngineer()
	crewmate.faction = fac
	crewmate.typetitle = "Engineer"
	crewmate.skill = "Shield Stabilization"
	crewmate.salary = 3e3 * (crewmate.xp * crewmate.satisfaction)
	crewmate.other_costs = pick_one({"Water", "Food", "Gold"})
	crewmate.chatter = 0.4 + rnd.twosigma() * 0.2
	crewmate.hook = {
		["func"] = "engishld",
		["hook"] = nil
	}
	
	crewmate.conversation.backstory.intent = pick_one({
		_("Everyone needs an engineer, maybe two."),
		_("I'll make sure your power doesn't go to waste."),
		_("I'm specialized in shield stabilization engineering."),
		_("You'll be glad to have an engineer like me on your ship, believe me."),
		fmt.f(_("I once fixed a {thing} on a three hour spacewalk."), {thing = getSpaceThing() } ),
		_("You might need me in a situation, think about that."),
		_("I'll get you out of a tough spot, or rather, I'll keep you in one piece for the trip back."),
		_("Danger is my middle name! Well, within reasonable parameters."),
	})
	
	return crewmate
end

-- It doesn't get much simpler than this for a custom character,
-- plants explosives after the player boards a hostile natural ship
-- usually it's enough to make sure it doesn't come back
-- uses engineer slot (can only have 2 engineers by default)
local function createExplosivesEngineer(fac)
    local character = createGenericCrewmate()
    fac = fac or faction.get("Za'lek")

    local portrait_func = portrait.getMale
    character.gender = "Male"
    character.article_object = "him"
    character.article_subject = "he"
    -- only 35% chance of female character to introduce small bias
    if rnd.rnd() < 0.35 then
        character.gender = "Female"
        portrait_func = portrait.getFemale
        character.article_object = "her"
        character.article_subject = "she"
    end
    character.name = pilotname.generic()
    character.typetitle = ("Engineer")
    character.skill = _("Demolition")
    character.satisfaction = rnd.rnd(1, 3)
    character.xp = math.floor(10 * (1 + rnd.sigma())) / 10
    character.portrait = portrait_func()
    character.faction = fac
    character.chatter = 0.3 + rnd.threesigma() * 0.1 -- how likely I am to talk at any given opportunity (could be NEVER!)
    character.deposit = math.ceil(100e3 * character.satisfaction * character.xp + character.chatter * rnd.rnd() * 10e3)
    character.salary = 0
    character.other_costs = "equipment"
	-- the explosives expert is a bit of a weirdo and gets his own custom conversation sheet
	-- actually that's a good way for me to find out if refactoring is breaking stuff
    character.conversation = {
        ["backstory"] = generateBackstory(character),
        -- what I say when I'm doing my job
        ["message"] = {
            _("The bomb has been planted."),
            _("The fuse has been lit."),
            _("The fuse is set."),
            _("Explosives in place."),
            _("I've set the charges."),
            _("Bombs in place."),
            _("Kaboom!"),
            _("Boom!"),
            _("Let's go!"),
            _("Bombs away..."),
            _("Can we stay and watch this one? It's gonna blow in a bit."),
            _("Special delivery."),
            _("Who needs stern chasers when you've got explosives?"),
            _("She's set to blow."),
            _("Fire in the hole!"),
            _("Fire in the hole."),
            _("Fire. Hole."),
            _("Tick tick tick..."),
            _("Tick tock..."),
			_("I've dropped a bomb."),
        },
        -- what I say when I'm satisfied
        ["satisfied"] = {
            _("I'm happy."),
            _("What can I say? It's a good day."),
            _("I feel alive."),
            _("I feel so alive."),
            _("I feel great."),
            _("I feel fantastic."),
            fmt.f(_("I feel like {million}!"), {million = fmt.credits(1e6 * rnd.rnd(1, 10))})
        },
        -- what I say when not satisfied
        ["unsatisfied"] = {
            _("I am unhappy."),
            _("Everything is bleak."),
            _("I want to use my explosives."),
            _("I'm bored."),
            _("I'm so bored."),
            _("I'm really bored."),
            _("There's nothing to do around here."),
            _("Nothing ever happens around here."),
            _("Nothing ever happens on this ship."),
            _("There's no action on this ship."),
            _("This ship is so boring."),
            _("It's too quiet here.")
        },
        -- things I say about or back to {name} when I had a good conversation
        ["good_talker"] = {
            _("I like talking with {name}."),
            _("{name} is nice."),
            _("Well, {article_subject}'s nice."),
            _("This was nice."),
            _("Bitchin'."),
            _("Cool."),
            _("Awesome."),
            _("Kaboom."),
            _("Kaplow."),
            _("Boom!"),
            _("Bombs away!"),
            _("Radical! Pun intended."),
            _("Well that's pretty sweet."),
            _("Isn't this nice."),
            _("Isn't this lovely."),
            _("That's great."),
            _("Yeah, yeah. I know. I'm with you."),
            _("Yeah, I'm with you."),
            _("Yeah, I know. I'm with you."),
            _("Don't look at me, I'm with {article_object} on this.")
        },
        -- things I say about {name} when I had a bad conversation
        ["bad_talker"] = {
            _("{name} is a downer."),
            _("I don't like {name}. How many times do I have to say it?"),
            _("I don't like you, {name}."),
            _("Screw {name}."),
            _("To hell with {name}."),
            _("Bah!"),
            _("Screw it."),
            _("To hell with it."),
            fmt.f(
                _("That little {made_up} can go float {article_object}self."),
                {made_up = getMadeUpName(), article_object = "{article_object}"}
            ),
            _("To hell with {article_object}!"),
            _("Can you see the look I'm giving {article_object}?"),
            _("{name} gets to do anything {article_subject} likes."),
            _("Everything is always about {name}, isn't it?"),
            _("Everything is about {article_object}, isn't it?")
        },
        ["fatigue"] = {
            _("Are we going to do something anytime soon?"),
            _("It's cold out there in space. Even with the explosions."),
            _("I want more explosions."),
            _("I could use a drink."),
            _("I need a drink."),
            _("I need a drink, damn it!"),
            _("I'm kind of beat."),
            _("I could use some shut-eye."),
            _("Where's my hat? Someone bring me my hat!"),
            _("Man I got too many bombs and not enough booms."),
            _("Where's all the action?"),
            _("I want to destroy a Goddard."),
            fmt.f(_("I want to destroy a {ship}"), {ship = getSpaceThing() } ),
            _("Where's the strong stuff?"),
            _("I need some of the good stuff."),
            _("Where's a heavy drink when you need one?"),
            _("Either my brain's going to explode or a nearby ship. That's for sure.")
        },
        ["bar_actions"] = {
            {
                ["verb"] = pick_one(
                    {
                        _("seducing"),
                        _("talking to"),
                        _("gesturing at"),
                        _("staring at")
                    }
                ),
                ["descriptor"] = pick_one(
                    {
                        _("some"),
                        _("a"),
                        _("a")
                    }
                ),
                ["adjective"] = pick_one(
                    {
                        _("tall"),
                        _("strange"),
                        _("shady"),
                        _("handsome"),
                        _("dark"),
                        _("mysterious"),
                        _("preoccupied")
                    }
                ),
                ["object"] = pick_one(
                    {
                        _("stranger"),
                        _("person"),
                        _("vagabond"),
                        _("piece of art"),
                        _("interloper"),
                        _("hologram"),
                        _("animal")
                    }
                )
            },
            {
                ["verb"] = pick_one(
                    {
                        _("motioning"),
                        _("signaling"),
                        _("gesturing"),
                        _("communicating")
                    }
                ),
                ["descriptor"] = pick_one(
                    {
                        _("with his"),
                        _("by waving his"),
                        _("by moving his")
                    }
                ),
                ["adjective"] = pick_one(
                    {
                        _("hand"),
                        _("hands"),
                        _("arms"),
                        _("legs"),
                        _("fingers"),
                        _("ears"),
                        _("eyes"),
                        _("eyebrows"),
                        _("tongue")
                    }
                ),
                ["object"] = pick_one(
                    {
                        _("in the air"),
                        _("towards a table"),
                        _("over his chest"),
                        _("around his face"),
                        _("inconsistently"),
                        _("like a maniac"),
                        _("without regard to his surroundings")
                    }
                )
            }
        },
        -- special things I know how to say
        ["special"] = {
            ["laugh"] = {
                _("*laughs maniacally*"),
                _("*laughs hysterically*"),
                _("*laughs frantically*"),
                _("Heh."),
                _("*chuckles*"),
                _("*cackles*"),
                _("Hehe."),
                _("Right? *laughs*"),
                _("*laughs*"),
                _("Am I right? Anyone?"),
                _("Right?"),
                _("Am I right or what?"),
                _("Yallahahahaha!"),
                _("*coughing laughter*"),
                _("*laughs while coughing*"),
                _("*asphyxiating laughter*"),
                _("Whoops, where did my lucky cigar go?")
            },
            ["random"] = {
                _("Tick tock!"),
                _("Shakalakalaka!"),
                _("Kaboom!"),
                _("BOOM!"),
                _("Aha!"),
                _("Tick tock..."),
                _("Tickety tock..."),
                _("It's time to say goodnight."),
                _("Close your eyes, it's gonna get bright.")
            },
            ["worry"] = {
                _("I hope I remembered to set the fuse..."),
                _("Oh, wait a minute..."),
                _("Did I get that right?"),
                _("At least I hope I'm right."),
                _("If everything goes to plan."),
                _("Maybe."),
                _("I think."),
                _("I think..."),
                _("I'm pretty sure."),
                _("Time will tell."),
                _("My lucky cigar never fails me."),
				_("Do you have it?")
            }
        },
        ["smalltalk_positive"] = {
            _("Do you guys remember the last ship we boarded?"),
            _("What was the name of that last ship? She went down beautifully."),
            _("I'll be in my quarters if you need me."),
            _("I'm going to go hang out with the cargo."),
            _("Let me know if you need anything.")
        },
        ["smalltalk_negative"] = {
            _("It's been a while since we paid anyone a special kind of visit, if you know what I mean."),
            _("Why don't we ever get dirty anymore?"),
            _("Do you guys remember the last ship we boarded?")
        },
        -- list of things I like to talk about and what I say about them
        ["topics_liked"] = {
            -- list of phrases that use the things I like (or not)
            ["violence"] = {
                fmt.f(_("Check out this {ship} I got to destroy."), {ship = getRandomShip()}),
                fmt.f(_("Have I told you about the {ship} I destroyed during my training?"), {ship = getRandomShip()})
            },
            ["friendship"] = {
                fmt.f(_("Check out this {ship} I'm thinking of buying."), {ship = getRandomShip()}),
                fmt.f(_("Check out the custom paintjob on this {ship}!"), {ship = getRandomShip()}),
                fmt.f(_("My old friend {name} would love this."), {name = pilotname.human()}),
                fmt.f(_("I'm sure {name} would appreciate this place."), {name = pilotname.human()})
            },
            ["science"] = {
                fmt.f(_("Check out the landing gear on this {ship}!"), {ship = getRandomShip()}),
                fmt.f(_("Have you seen the new {ship} features?"), {ship = getRandomShip()}),
                fmt.f(_("I heard about some unexplained phenomena at {place}."), {place = spob.get(true)}),
                fmt.f(
                    _("I wonder what the mystery about {place} is, maybe I missed something."),
                    {place = spob.get(true)}
                ),
                fmt.f(
                    _(
                        "I thought I saw a {ship} following me past {place}, my sensors were going crazy, but then I saw it with my own eyes. It was a comet!"
                    ),
                    {ship = getRandomShip(), place = spob.get(true)}
                )
            }
        },
        -- list of things I don't like talking about, words I don't like hearing
        ["topics_disliked"] = {
            _("luxury"),
            _("luxurious"),
            _("soap"),
            _("lotion")
        },
        -- things we say about things we are indifferent to
        ["default_participation"] = {
            _("Err.. Yeah!"),
            _("Sure!"),
            _("That sounds good."),
            _("Yeah."),
            _("Nice."),
            _("Boom, baby!")
        },
        -- responses to conversations about topics I don't like
        ["phrases_disliked"] = {
            _("Do we have to talk about this?"),
            _("All you ever talk about is {topic}."),
            _("It's {topic} this, {topic} that, you just can't get enough {topic} can you?"),
            _("Whatever."),
            _("Yeah, okay."),
            _("Right."),
            _("Sure."),
            _("Yeah, because of all the {topic}, of course.")
        }
    }
    character.hook = {
        ["func"] = "demoman",
        ["hook"] = nil
    }

    return character
end

-- creates a random engineer
local function createEngineer(fac)
	local choice = rnd.rnd(0, 3)
	
	if choice == 0 then
		return createArmorEngineer(fac)
	elseif choice == 1 then
		return createShieldEngineer(fac)
	elseif choice == 2 then
		return createPowerEngineer(fac)
	end
	
	return createExplosivesEngineer(fac)
end

--  decide what crew the player gets to encounter here
local function createCrewmateNPCs()
    local fac = spob.cur():faction()

    if spob.cur():tags().nonpc then
        return
    end

    if fac == nil then
        return
    end

	local patrons = {
		_("Patron"),
		_("Bar Patron"),
		_("Ship Worker"),
		_("Dock Worker"),
		_("Avid Talker"),
		_("Civilian"),
		fmt.f(_("{faction} Civilian"), {faction = fac}),
		_("Worker"),
		_("Drunkard"),
		_("Anxious Person"),
	}
	
	local presentable = {
		_("Attractive {gender}"),
		_("Presentable {gender}"),
		_("Eyecatching {gender}"),
		_("{gender} {typetitle}"),
		_("Obvious {skill}"),
	}
	
    
    -- the generic crewman disguised as a patron
	for _i=1, 5 do
		if rnd.rnd(1, 5) == 3 then
			local crewmate = createGenericCrewmate()
			local id =
				evt.npcAdd(
				"approachGenericCrewmate",
				pick_one(patrons),
				crewmate.portrait,
				fmt.f(
					_(
						[[This person seems to be looking for work, but there are no obvious details as to what they can do.]]
					),
					crewmate
				),
				9
			)

			npcs[id] = crewmate
		end
	end

	-- the first officer, quite rare
	if rnd.rnd(1, 21) == 21 then
	    local crewmate = createFirstOfficer()
        local id =
            evt.npcAdd(
            "approachGenericCrewmate",
                        fmt.f(pick_one(presentable), crewmate),
            crewmate.portrait,
			[[This person seems to be ]] .. getBarSituation(crewmate) ..
				fmt.f(
				_([[, perhaps you should go talk to {article_object}.]]),
				crewmate
            ),
            6
        )

        npcs[id] = crewmate
	end
	
	-- the ship psychologist
	if rnd.rnd(1, 13) == 13 then
		local crewmate = createPsychologistManager()
		local id = 
		    evt.npcAdd(
            "approachGenericCrewmate",
            fmt.f(pick_one(presentable), crewmate),
            crewmate.portrait,
			[[This person seems to be ]] .. getBarSituation(crewmate) ..
				fmt.f(
				_([[, perhaps you should go talk to {article_object}.]]),
				crewmate
            ),
            6
		)
		
        npcs[id] = crewmate
	end
	
    -- the generic manager disguised as a patron
    if rnd.rnd(1, 13) == 7 then
        local crewmate = createGenericManager()
        local id =
            evt.npcAdd(
            "approachGenericCrewmate",
            pick_one(patrons),
            crewmate.portrait,
            fmt.f(
                _(
                    [[This person seems to be looking for work, but there are no obvious clues as to what they can do.]]
                ),
                crewmate
            ),
            9
        )

        npcs[id] = crewmate
    end
	
	 -- the smuggler, more likely on pirate planets
    if rnd.rnd(1, 5) == 3 or (pir.factionIsPirate(fac) and rnd.rnd(0,6) <= 4) then
		-- TODO: only if this place sells commodities
        local crewmate = createSmuggler()
        local id =
            evt.npcAdd(
            "approachGenericCrewmate",
            pick_one(patrons),
            crewmate.portrait,
            fmt.f(
                _(
                    [[This person seems to be looking for work, but there are no obvious details as to what they can do.]]
                ),
                crewmate
            ),
            9
        )

        npcs[id] = crewmate
    elseif rnd.rnd(0, 2) == 0 then
		-- if no smuggler, the generic pilot has a chance
		local crewmate = createShuttlePilot()
        local id =
            evt.npcAdd(
            "approachGenericCrewmate",
            pick_one(patrons),
            crewmate.portrait,
            fmt.f(
                _(
                    [[This person seems to be looking for work, but there are no obvious details as to what they can do.]]
                ),
                crewmate
            ),
            9
        )
		npcs[id] = crewmate
	end
	
	-- the special crewmate, pick 1 or none
	local r = rnd.rnd(0, 3)
	-- the armor engineer
	if r == 2 or (fac == faction.get("Za'lek") and r == 3) then
		local character = createEngineer()

        local id =
            evt.npcAdd(
            "approachGenericCrewmate",
            character.typetitle,
            character.portrait,
            fmt.f(
                _(
                    [[This engineer seems to be looking for work.

		Name: {name}
		Post: {typetitle}
		Expertise: {skill}
]]
                ),
                character
            ),
            5
        )

        npcs[id] = character
	end
	
	-- the demolition man
    if r == 1 or (fac == faction.get("Za'lek") and r == 0) then
        local character = createExplosivesEngineer()

        local id =
            evt.npcAdd(
            "approachDemolitionMan",
            character.typetitle,
            character.portrait,
            fmt.f(
                _(
                    [[This engineer seems to be looking for work.

		Name: {name}
		Post: {typetitle}
		Expertise: {skill}
]]
                ),
                character
            ),
            5
        )

        npcs[id] = character
    end

    -- the companion escort, rare , less rare on criminal worlds
    if r == 2 or spob.cur():tags().criminal and r == 0 then
        local character = createEscortCompanion()
        character.faction = fac
        character.chatter = 0.5 + rnd.threesigma() * 0.1 -- how likely I am to talk at any given opportunity
        character.deposit = math.ceil(200e3 * character.xp + 35e3 * character.satisfaction)
        character.salary = 0 -- credits per cycle? sure.. credits per cycle.
        character.other_costs = "Luxury Goods" -- pay for 100 kg every time you land unless you have it on board

        local id =
            evt.npcAdd(
            "approachEscortCompanion",
            character.typetitle,
            character.portrait,
            fmt.f(
                _(
                    [[This person seems charming and charismatic. You get the feeling that you're about to be pursuaded into some business. Perhaps you should strike up a conversation?

		Name: {name}
		]]
                ),
                character
            ),
            5
        )

        npcs[id] = character
    end
end

local function getCrewSheet(crewmate)
	if not crewmate.last_paid then
		crewmate.last_paid = time.get()
	end
	crewmate.salary_fmt = fmt.credits(crewmate.salary)
	local sheet = _([[
{typetitle}
{name},		{firstname}

Assignment: 	{skill}
Experience: 	{xp:.0f}
Salary 32p:		{salary_fmt}
]])
	
	if crewmate.away then
		sheet = fmt.f(_([[		CURRENT STATUS:		 AWAY
Mission: {mission}
Ship:    {ship}
]]), crewmate.away) .. sheet
	end
	
	if crewmate.manager then
		if not string.find(crewmate.skill, _("Officer")) then
		sheet = fmt.f(_([[{type} Manager
			
	]]), crewmate.manager):upper() .. sheet
		end
		if crewmate.manager.skill then
			sheet = sheet .. fmt.f(_([[Other skills: {skill}
]]), crewmate.manager)
		end
	end
	if crewmate.shuttle then
		sheet = sheet .. fmt.f(_([[Shuttle:     {name}
]]), { name = crewmate.shuttle.ship })
	end

	sheet = sheet .. _([[Other costs:		{other_costs}
Last paycheck:		{last_paid}
]])

	
	return fmt.f(sheet, crewmate)
end

local function getOfferText(edata)
    local approachtext = generateIntroduction(edata)

    local _credits, scredits = player.credits(2)
    local deposit = edata.deposit
    if not deposit then
        deposit = 0
    end
    local credentials = _([[
Name: {name}
Expertise: {skill}
]])

    local finances = _([[
Money: {credits}
Deposit: {deposit}
Salary: {salary}
Other costs: {other_costs}]])
    return (approachtext ..
        "\n\n" ..
            fmt.f(credentials, edata) ..
                "\n\n" ..
                    fmt.f(
                        finances,
                        {
                            credits = scredits,
                            deposit = fmt.credits(deposit),
                            salary = fmt.credits(edata.salary),
                            other_costs = edata.other_costs
                        }
                    ))
end

function create()
    npcs = {}
    mem.companions = {}
    mem.costs = {}

    hook.land("land")
    hook.load("land")
    hook.enter("enter")
	hook.takeoff("takeoff")
end

-- calculate any bonuses that we might want to calculate
function takeoff()
	mem.last_system = system.cur()
	if (
		getCommander() and getCommander().pilot
		) or
		(mothership ~= player.ship() and mothership)
		then
		-- don't do anything now, a commander might be piloting the ship
		return
	end
	mothership = player.ship()
--[[
	mem.ship_interior = {
		["dirt"] = 0,
		["dirt_accum"] = 0,
		["officers"] = {},
		["bay_strength"] = 0,
	}
--]]
	-- END QUICKFIX SECTION

	-- start by checking if we want to alter our crew before assembling the roster
	-- shuffle crew if necessary
	if mem.ship_interior.officers[_("First Officer")] then
		local min_cadet_xp = 1
		local lindex = #mem.companions
		-- lazy sorting, just iterate through one pass and move "bad crew" further back
		for ii, crewman in ipairs(mem.companions) do
			if crewman.typetitle == _("Crew") and ii < math.floor(#mem.companions * 0.88) then
				local swap = false
				if crewman.skill == _("Rookie") then
					swap = true
				elseif crewman.skill == _("Cadet") then
					if crewman.xp < min_cadet_xp then
						swap = true
					else
						min_cadet_xp = math.floor(crewman.xp)
					end
				end
				if swap then	-- move near the back but not in an "away" slot
					local rindex = rnd.rnd(ii, math.min(1, lindex - 1))
					mem.companions[ii] = mem.companions[rindex]
					mem.companions[rindex] = crewman
				elseif crewman.away then -- move to the back into an "away" slot
					mem.companions[ii] = mem.companions[lindex]
					mem.companions[lindex] = crewman
					lindex = lindex - 1
				end
			end
		end
	end

	-- begin takeoff procedure (assemble roster)
	local officers = {}		-- crew that unlock abilities/crew
	local champions = {}	-- crew with special skills
	champions.engineers = {}
	local workers = {}		-- general supporting crew
	workers.general = 0
	workers.security = 0	-- something to do with defense when boarded?
	workers.cargo = 0
	workers.maintenance = 0
	workers.janitorial = 0
	local max_crew = player.pilot():stats()["crew"]
	-- count crew types and record champions
	-- note that we only count the first hired crews that can fit
	-- just in case the player was in a large ship with a large crew
	-- but swapped into something small with less crew space
	for ii, crewmate in ipairs(mem.companions) do
		if ii <= max_crew then
			if crewmate.skill == _("Cargo Bay") then
				workers.cargo = workers.cargo + 1
			elseif crewmate.skill == _("Maintenance") then
				workers.maintenance = workers.maintenance + 1
			elseif
				string.find(crewmate.skill, _("Sanitation"))
				or string.find(crewmate.skill, (_("Janitor")))
			then
				-- janitors can be doubly effective or extremely ineffective
				workers.janitorial = workers.janitorial + math.max(0.25, math.min(2, crewmate.xp * crewmate.satisfaction))
			elseif crewmate.skill == _("Security") then
				workers.security = workers.security + 1
			-- assign "generality" usefulness based on rank if unspecialized
			elseif string.find(crewmate.skill, _("Rookie")) then
				workers.general = workers.general + 0.12
				-- we don't have any skills, so we clean as well
				workers.janitorial = workers.janitorial + 0.1
			elseif string.find(crewmate.skill, _("Cadet")) then
				workers.general = workers.general + 0.25
			elseif string.find(crewmate.skill, _("Ensign")) then
				workers.general = workers.general + 1
			elseif string.find(crewmate.skill, _("Lieutenant")) then
				workers.general = workers.general + 0.5
			end
		end

		-- find officers (can own shuttles)
		if string.find(crewmate.skill, _("Officer"))
			or string.find(crewmate.typetitle, _("Chief"))
		then
			officers[crewmate.skill] = crewmate
		end
		-- record champions
		if crewmate.typetitle == _("Engineer") then
			if string.find(crewmate.skill, "Explosive") then
				champions.demoman = ii
			else
				
				table.insert(champions.engineers, crewmate)
			end
		elseif string.find(crewmate.typetitle, _("Scien")) then
			champions.scientist = ii
		elseif crewmate.typetitle == _("Pilot") then
			champions.pilot = crewmate -- not sure about this yet
		elseif crewmate.typetitle == _("Smuggler") then
			champions.smuggler = ii
		elseif crewmate.typetitle == _("Companion") then
			champions.escort = ii
		end
		crewmate.bonus = 0
	end
	
	-- assign bonuses
	-- smugglers benefit from cargo bay workers
	if champions.smuggler then
		mem.companions[champions.smuggler].bonus = workers.cargo
	end
	-- engineers benefit from maintenance workers
	for _i, engineer in ipairs(champions.engineers) do
		engineer.bonus = workers.maintenance
	end
	-- one scientist benefits from general workers
	if champions.scientist then
		mem.companions[champions.scientist].bonus = workers.general * 0.2
	end
	
	-- calculate bay strength in case we have a shuttle crew
	local po = player.pilot():outfits()
	mem.ship_interior.bay_strength = 0
	for _i, oo in ipairs(po) do
		if string.find(oo:nameRaw(), "Bay") then
			mem.ship_interior.bay_strength = mem.ship_interior.bay_strength + 2	
		elseif string.find(oo:nameRaw(), "Dock") then
			mem.ship_interior.bay_strength = mem.ship_interior.bay_strength + 1
		end
	end
	
	mem.ship_interior.officers = officers
	local limits = START_CREW_LIMITS
--	print("limit calculation")
	-- calculate limits based on officers
	for otype, officer in pairs(officers) do
		-- find limit in title, like "Chief of Science", or "Chief Engineer" or "Science Officer" I guess
		for limited, limit in pairs(limits) do
			if string.find(otype, limited) then
				limits[limited] = limits[limited] + 1
			end
		end
		
		
		if string.find(otype, _("First Officer")) then
			-- unlock first officer abilities
			-- earn 2 of every limited type
			for limited, limit in pairs(limits) do
				limits[limited] = limits[limited] + 2
			end
			-- custom maximums for first officer
			limits[_("Rookie")] = 8
			limits[_("Cadet")] = 16
			limits[_("Ensign")] = 16
			limits[_("Lieutenant")] = 6
			-- ship uses the first officer's shuttle
			mem.ship_interior.shuttle = officer.shuttle
		end
	end
	mem.crew_limits = limits
	
	-- calculate ship cleanliness deteriation
	-- we need about 16% of the crew to be cleaning up on average
	-- general duty workers contribute 10% as much as a janitor regardless of satisfaction
	-- but janitors' effectiveness heavily depends on satisfaction
	-- so if you hire a lot of general duty workers, you can offset unhappy janitors a bit
	local janitors_needed =  math.ceil(math.min(#mem.companions * 0.168 + 0.75, max_crew * 0.16))
	local effective_janitors = workers.janitorial + (0.5 * workers.general)
	if effective_janitors < janitors_needed then
		-- ship is going to get dirtier
		mem.ship_interior.dirt_accum = ((janitors_needed * 2) / (workers.janitorial + 1 + janitors_needed))
		mem.ship_interior.dirt = math.max(#mem.companions, mem.ship_interior.dirt)
	else -- try to clean the ship up a bit
		mem.ship_interior.dirt_accum = -0.1 * workers.janitorial
		mem.ship_interior.dirt = math.min(#mem.companions, mem.ship_interior.dirt)
	end
	print(fmt.f("There are {ej:.2f}/{need} effective janitors and ", { ej = effective_janitors, need = janitors_needed }) .. fmt.f("dirt is at {dirt:.1f} (accum at {dirt_accum:.2f})", mem.ship_interior ))
end

function land()
	if getCommander() and getCommander().pilot then
		-- don't do anything important now, a commander might be piloting the ship
		-- just check if we can populate the bar for the landed captain
		local pnt = spob.cur()
		local services = pnt:services()
		if services.inhabited and services.bar and not pnt:flags().nomissionspawn then
			npcs = {}
			createCrewmateNPCs()
		end
		return
	end

	clearCommanderInterface()
    npcs = {}
    local paid = {}
	local payroll
    for i, edata in ipairs(mem.companions) do
        -- natural satisfaction adjustment gravitates towards zero and adds
        -- a little bit of randomness based on how smooth the landing was or whatever
        local sss = math.max(-10, math.min(10, edata.satisfaction))
        edata.satisfaction = math.floor(10 * (sss - (sss / 64))) / 10 + 0.01 * rnd.threesigma()
		
        -- incurr any necessary commodity costs if we have the possibility to "restock"
        if edata.other_costs then
            -- see if this is a commodity we can buy here
            local available_comms = spob.cur():commoditiesSold()
            for _i, ccom in ipairs(available_comms) do
                local name = ccom:name()
				-- don't pay for things we have on board, as a bonus
                if name == edata.other_costs and not player.pilot():cargoHas(name) then
                    -- make the player pay the cost of 1/10th of a ton, which should be enough to last until we land again
                    local price = math.ceil(ccom:priceAt(spob.cur()) / 10)
                    player.pay(-price)
                    -- do some bookkkeeping in case we have a manager
                    local prev_paid = paid[name]
                    if prev_paid == nil then
                        prev_paid = 0
                    end
                    paid[name] = prev_paid + price
                end
            end
        end

		-- dock any missing non-officer shuttles
		if edata.shuttle and not string.find(edata.skill, _("Officer")) then
			edata.shuttle = "docked"
		end
		
        -- if we don't have a manager that called us, some crew doesn't go to the bar
        -- chance of being elsewhere depends on xp and crew size
        local elsewhere_chance =
            (#mem.companions - edata.satisfaction) / (edata.xp + #mem.companions + math.abs(edata.satisfaction))
        if edata.manager then
            elsewhere_chance = 0
			if edata.manager.skill == "payroll" then
				payroll = edata
			end
        end -- don't let managers go on holiday
        if mem.summon_crew or rnd.rnd() > elsewhere_chance or edata.manager then
            -- add the npc and figure out what he's doing
            local doing = getBarSituation(edata) .. "."
            local description =
                fmt.f(_("This is {typetitle} {firstname} {name}, designation {skill}. It seems that {article_subject} is "), edata) ..
                doing
            -- put ship crew at the bottom unless it's important management crew
            local priority = 10
            if edata.manager then
                priority = 6
            end
            local id = evt.npcAdd("approachCompanion", edata.name, edata.portrait, description, priority)
            npcs[id] = edata
        end
    end

    -- if we just summoned the crew, don't do it again next time
    mem.summon_crew = nil

    if #mem.companions <= 0 then
        evt.save(false)
    end

    -- Ignore on uninhabited and planets without bars
    local pnt = spob.cur()
    local services = pnt:services()
    local flags = pnt:flags()
    if not services.inhabited or not services.bar or flags.nomissionspawn then
        return
    end

	
	-- if we didn't pay salaries yet, do it now
	-- also: captain makes mistakes: paid = salary - salary * (rnd.twosigma() + rnd.rnd())
	-- and underpaid crew becomes unhappy and retain a memory (cap'n bad at maths) and get a sentiment (cap'n underpaid me)

	-- the captain pays salaries (incorrectly unless someone is working on payroll)
	for _i, crewmate in ipairs(mem.companions) do
		if crewmate.salary > 0 then
			-- estimate an incorrect salary but allow captain's interactions with crew to affect it
			local estimated = crewmate.salary + crewmate.salary * (rnd.twosigma() + rnd.rnd() + rnd.rnd()) + FAKE_CAPTAIN.xp * FAKE_CAPTAIN.satisfaction
			if payroll then -- fix the captain's mistakes and earn xp
				estimated = crewmate.salary
				payroll.xp = math.min(100, payroll.xp + 0.01)
			end

			if not crewmate.last_paid then
				crewmate.last_paid = time.get()
			else
				local dt = time.get() - crewmate.last_paid
				if dt > time.create(0, 15, 0) then
					if estimated < crewmate.salary then
						-- the crewmate is unhappy and loses experience
						-- (gets demotivated, hopefully we get it back with the paycheck)
						create_memory(crewmate, "underpaid")
						crewmate.satisfaction = crewmate.satisfaction - 0.01
						crewmate.xp = math.max(0, crewmate.xp - 0.5)
						insert_sentiment(crewmate, _("The captain miscalculated my salary."))
					else
						-- random salary happiness bonus
						crewmate.satisfaction = crewmate.satisfaction + rnd.rnd()
						-- did this paycheck come with a promotion?
						-- we can get promoted to lieutenant at most here
						if crewmate.xp >= 100 and crewmate.skill ~= _("Lieutenant") then
							local promotion = _("Cadet") -- default if we are a rookie
							if crewmate.skill == _("Cadet") then
								promotion = _("Ensign")
							elseif crewmate.skill == _("Ensign") then
								promotion = _("Lieutenant") -- finally!
							end
							crewmate.skill = promotion
							crewmate.xp = 1 -- reset xp so we don't get double promotion!
						end
					end
					local salary_resolution = time.create(0, 32, 0)
					local multiplier = dt:tonumber() / salary_resolution:tonumber()
					local calculated = estimated * multiplier
					local ttpaid = paid[crewmate.typetitle] or 0
					paid[crewmate.typetitle] = ttpaid + calculated -- bookkkeeping
					player.pay(-calculated)	-- player pays the crewmate
					crewmate.last_paid = time.get()
					--[[ we got paid, earn a random amount of experience
						and some experience based on our mood strength
						this makes negative nancies better at earning XP and
						positive patties much better at earning XP
						but the more salary you get, the less experience you gain from satisfaction
						and so in a way we treat [0-1] as depression to stable with 1 as stable and 
						anything else as a positive or negative mood ranging from mild to mania
						but this makes sure that TROUBLEMAKERS and PROMISING crew stand out a bit more
						and pushes "boring", stable crew to earn xp more slowly as you would expect IRL (not ambitious)
					--]]
					crewmate.xp = crewmate.xp + rnd.rnd() + math.abs(
						math.max(-3, crewmate.satisfaction * rnd.rnd())
					) / (math.max(1, calculated))
				end
			end
		end
	end
	
    -- pay for any other incurred costs
    for item, cost in pairs(mem.costs) do
        player.pay(-cost)
        paid[item] = cost
        mem.costs[item] = 0
    end

    -- if we have a manager, give him the data here
	-- could be used to figure out what crew is dead weight etc
	-- so the conversation/dialog uses the paid table as a base
    for _i, crewmate in ipairs(mem.companions) do
        if crewmate.manager then
            -- check if the manager has the finance skill
            if crewmate.manager.skill == "finance" then
                crewmate.manager.paid = paid
            end
        -- check for some other skills / data
        end
    end

	
    local total_paid = 0
    for _item, ppaid in pairs(paid) do
        total_paid = total_paid + ppaid
    end
    if total_paid > 0 then
        shiplog.append(
            logidstr,
            fmt.f(
                _("You paid {credits} in crew salaries and other costs."),
                {
                    credits = fmt.credits(total_paid)
                }
            )
        )
    end

    -- Create NPCs for pilots you can hire.
    createCrewmateNPCs()
end

function enter()
    -- if escorts are disabled, our companions are sleeping
    if var.peek("hired_escorts_disabled") then
        return
    end
	local cmdr = getCommander() 
	local lastsys = mem.last_system
	mem.last_system = system.cur()
	if cmdr and cmdr.pilot and mothership ~= player:ship() then
		-- oh man, what happened here? we probably jumped in a shuttle,
		-- leaving our main ship behind. so now the ship must either follow or stay
		-- I think we should just let it follow
				
		if lastsys == mem.lastsys then
			cmdr.ghost.pos = player.pilot():pos() + vec2.new( rnd.rnd(-1400, 1400), rnd.rnd(-960, 960))
		else
			cmdr.ghost.pos = lastsys
			-- this is where we WOULD update fuel, if we wanted to do that... I personally don't
		end
		cmdr.ghost.hook = hook.timer( rnd.rnd(1, 120 - cmdr.xp), "spawn_ghost_commander2", cmdr)
		return
	end
	
    if #mem.companions == 0 then
        return
    end

    -- start a conversation
    hook.rm(mem.conversation_hook)
    mem.conversation_hook = hook.timer(rnd.rnd(10, 30), "start_conversation")

    for _i, companion in ipairs(mem.companions) do
        -- reset any hooks
        if companion.hook then
            if companion.hook.hook then
                --				print(fmt.f("removing hook number {number} for {name}", {number = companion.hook.hook, name = companion.name}))
                hook.rm(companion.hook.hook)
            end
            companion.hook.hook = entries[companion.hook.func](companion)
        --			print(fmt.f("registered hook number {number} for {name}", {number = companion.hook.hook, name = companion.name}))
        end
    end

    -- set the fatigue hook
    hook.rm(mem.fatigue_hook)
    mem.fatigue_hook = hook.date(time.create(0, 1, 0), "period_fatigue", nil)
end

-- TODO: this should take a batch of crewmembers, to make it seem like they are on shifts
-- a period passes in space and the crew feels fatigued
-- dirt accumulates in the ship
-- and maybe some science project progress is updated
function period_fatigue()
	-- check if its safe to update the mothership and recalculate values
	if mem.ship_interior.shuttle and not mem.ship_interior.shuttle.out then
		-- recalculate dirt accumulation rate (use takeoff, recalculates everything)
		takeoff()
		mothership = player.ship()
	end
	-- calculate natural dirt accumulation
	mem.ship_interior.dirt = math.max(0, mem.ship_interior.dirt + mem.ship_interior.dirt_accum)
--	print("dirt is and grows by", mem.ship_interior.dirt, mem.ship_interior.dirt_accum)
    
	-- only one crewmate can get hysteria per period
	local hysteria = false
	-- calculate how each crew member is affected by the time that passed
    for _i, companion in ipairs(mem.companions) do
		-- calculate ship atmosphere interaction
		-- how occupied this worker was on this pass (busy or restless)
		local occupation = 0
		-- do I think that this area is dirty?
		if mem.ship_interior.decoration then
			occupation = 1
			-- there are nice decorations here, don't notice any dirt
			if not companion.item and rnd.rnd(0, 6) == 0 then
				-- I can take this item and put it on my person to use next period
				occupation = occupation + 1
				if evaluate_item_haste(companion, mem.ship_interior.decoration) > 0.25 then
					-- I want this item and I think I'll take one
					companion.item = mem.ship_interior.decoration
					companion.xp = companion.xp + 0.01 -- I showed initiative and took something I wanted
					occupation = occupation * 2
					if rnd.rnd(0, #mem.companions * 3) < mem.ship_interior.decoration:len() then
						-- I took the last item
						mem.ship_interior.decoration = nil
						occupation = occupation * 2
					end
				end
			end
		elseif mem.ship_interior.dirt > 4 * rnd.rnd() then
			companion.satisfaction = companion.satisfaction - 0.003 * mem.ship_interior.dirt
			occupation = occupation + 1
			if mem.ship_interior.dirt > 64 * rnd.rnd() + companion.chatter then
				-- TODO: generate "it's dirty here" speeches
				insert_sentiment(companion, _("This ship is filthy."))
				occupation = occupation + 3
			end
		end
		
		-- do I have an item that will make me happy?
		if companion.item then
			-- use this item soon
			hook.timer(rnd.rnd(3, 196), "crewmate_use_item", companion)
			occupation = occupation + 2
		-- are we out of food and water?
		elseif rnd.rnd(0, 3) == 0 and not (player.pilot():cargoHas("Food") or player.pilot():cargoHas("Water")) then
			insert_sentiment(companion, _("I'm getting hungry."))
			insert_sentiment(companion, _("I'm so thirsty."))
			companion.satisfaction = companion.satisfaction - 0.05
			occupation = occupation + companion.satisfaction
		end

		-- calculate fatigue and hysteria chances
		
        -- every experience point will give the crewmate 1% chance to resist fatigue
		-- every satisfaction point will contribute another 1% positively or negatively
        if rnd.rnd(0, 100 - occupation) > companion.xp + companion.satisfaction then
            companion.satisfaction = companion.satisfaction - 0.01
            -- if we are a big chatter we might express ourselves about this later
            if rnd.rnd() < companion.chatter then
                local last_sentiment = companion.conversation.sentiment
                companion.conversation.sentiment = pick_one(companion.conversation.fatigue)
                -- if it's the same sentiment, blurt it out soon
                if companion.conversation.sentiment == last_sentiment then
                    hook.timer(7 + rnd.rnd(3, 25), "say_specific", {me = companion, message = last_sentiment})
                    companion.conversation.sentiment = nil
                end
            end
        elseif rnd.threesigma() > 2.66 and not hysteria then
            -- we get a mild case of space hysteria that affects us more the more experienced we are
            companion.satisfaction = companion.satisfaction - companion.xp / (companion.xp + 6)
            print(fmt.f("{name} has hysteria.", companion))

            -- ramble at some victim (could be ourselves, especially on small crews)
            local victim = getCrewmateOnboard()

            -- start rambling about something
            local ramblings

            if rnd.rnd(0, 1) == 0 then
                -- we get lucky, we realize we're just tired, but we're still going to ramble
                ramblings = pick_one(companion.conversation.fatigue)
                -- create a random memory about this scary place
                create_memory(companion)
            else
                -- decide how to ramble
                if rnd.rnd(0, 1) == 0 then
                    -- we'll call the victim bad company for no reason
                    ramblings = fmt.f(pick_one(companion.conversation.bad_talker), victim)
                else -- oh we're really gonna ramble
                    if rnd.rnd(0, 1) == 0 then
                        -- we'll pick anything from our special choices and just say that
                        ramblings = add_special(companion)
                    else -- be a little more incoherent than usual
                        ramblings = add_special(companion) .. " " .. getMadeUpName() .. " " .. add_special(companion)
                    end
                    -- just in case we got no specials for some reason
                    if ramblings:len() == 0 or rnd.threesigma() > 2 then
                        ramblings = fmt.f(_("This voyage is driving me {made_up} crazy."), {made_up = getMadeUpName()})
                    end
                end
                -- experience melancholia too because we later learn how incoherent we were
                companion.satisfaction = companion.satisfaction - 1
                -- at this point, it's safe to say one of the crewmates is experiencing hysteria, don't add any more
                hysteria = true
                -- create a random memory but supplying some completely incorrect parameters
                local params = {
                    system = getMadeUpName(),
                    target = getMadeUpName(),
                    credits = fmt.credits(-rnd.rnd(3e3, 7e4)),
                    armour = rnd.rnd(44, 132),
                    ship = getRandomShip()
                }
                create_memory(companion, "hysteria", params)
            end

            -- set the sentiment so that we'll tell it to someone
            companion.conversation.sentiment = ramblings
            -- start talking to the victim (remember, could be ourselves, and we could start a conversation with ourselves)
            speak(companion, victim)
        elseif rnd.rnd(0, 17) >= 13 then -- control for creating random travel memories
			create_memory(companion)
		end
    end

	-- does the decorative item lose its charm?
	--if math.abs(rnd.threesigma()) > 2.7 then -- TODO depercate in steps by adding "bad" adjectives like "old", "worn"
	if mem.ship_interior.decoration then
		if not mem.ship_interior.decoration_locked and rnd.twosigma() > 1.75 then
			-- this item becomes dated or nasty
			local picked = pick_one(join_tables(lang.getAll(lang.adjectives.negative.dated), lang.getAll(lang.adjectives.negative.nasty)))
			mem.ship_interior.decoration_locked = pick_one(lang.getAll(lang.adjectives.negative.smelly))
			-- so we now get something "smelly old apple" or "pungent rotten banana"
			mem.ship_interior.decoration = mem.ship_interior.decoration_locked .. " " .. picked .. " " .. mem.ship_interior.decoration
		end
		-- this was the last one, notice how unlikely it is to take the last negatively adorned item
		if rnd.rnd(0, mem.ship_interior.decoration:len()) < 1 then
			mem.ship_interior.decoration = nil
			mem.ship_interior.decoration_locked = nil
		end
	end
	
    local next_fatigue = rnd.rnd(7500, 9950)
    -- set the next period fatigue timer
    hook.rm(mem.fatigue_hook)
    mem.fatigue_hook = hook.date(time.create(0, 0, next_fatigue), "period_fatigue", nil)
end

-- delete the crew member permanently
local function terminate_crew(crewmember, reason)
	-- the crew member had some stuff on board which leaves a mess
	mem.ship_interior.dirt = mem.ship_interior.dirt + crewmember.xp * player.pilot():ship():size() * 0.1
	
	for k, v in ipairs(mem.companions) do
		if crewmember.name == v.name then
			if crewmember.hook then
				hook.rm(crewmember.hook.hook)
			end
			mem.companions[k] = mem.companions[#mem.companions]
			mem.companions[#mem.companions] = nil
		end
	end
	
	shiplog.append(logidstr, reason)
	if npcs and player.isLanded() then
		for nn, cdata in pairs(npcs) do
			if crewmember == cdata then
				evt.npcRm(nn)
				npcs[nn] = nil
			end
		end
	end
end

-- method to wrap terminate_crew for hooking death
function terminate_crew_death( _dead, _killer, crewman, reason)
	return terminate_crew(crewman, reason)
end

-- generates a message that discusses some random interest of <crewmate>
local function discussRandomTopic(crewmate)
 local my_topics = crewmate.conversation.topics_liked
    local topic = nil
    local last_topic = nil
    for ttt, _choices in pairs(crewmate.conversation.topics_liked) do
        if not topic or rnd.rnd(0, 3) == 1 then
            topic = ttt
        end
        last_topic = ttt
    end
    local message
    if not topic then
        message = _("I got nothing to say to you.")
    else
        local choices = my_topics[topic]
        message = pick_one(choices)
    end

    if not message then
        message = _("I don't know what to say.")
    end

    -- to make it more interesting, sometimes pick another thing to say as well
    if rnd.rnd(0, 2) == 0 then
        local sep = "\n"
        -- our last topic, which is probably going to be the one that's last in the list in this file that got chosen, will be preferred and more likely
        if rnd.rnd(0, 2) == 1 then
            last_topic = topic -- use the same topic again
            sep = " " -- don't always seperate with newline, it's the same topic for sure ihere so lets avoid it
        end
        local choices = my_topics[last_topic]
        local other_message = pick_one(choices)
        -- don't say the exact same thing twice though
        if message ~= other_message then
            message = message .. sep .. other_message
        end
    end
	
	return message
end

-- starts a standard discussion with a crewmate (at the bar, unless the ship has a bridge UI where you can talk to your npcs)
-- this is definitely a place to be excessively wasteful and do computations we might not need if it increases the chance
-- of a more meaningful interaction. If we have to look every word typed by the player up in several tables, then that's what we'll do!
function startDiscussion(crewmate)
	if crewmate.away then
		vntk.msg(fmt.f(_([[{typetitle} {name}]]), crewmate), fmt.f(_([[{typetitle} {name} could not be summoned due to being on a ]]), crewmate) .. fmt.f(_([[{mission} in the {ship}.]]), crewmate.away))
		return
	end
	
    local name_label = fmt.f("{firstname} {name}", crewmate)
	vn.clear()
	vn.scene()
	local discusser = vn.newCharacter ( name_label, {image = portrait.getFullPath(crewmate.portrait) } )
	vn.transition()
	local message
	local count = 0
	vn.label("start")
	vn.func( function() 
		-- just pick a random thing to say from our interests
		message = discussRandomTopic(crewmate)
	end )
	discusser( function () return message end )
	
	vn.label("reply")
	local title_choice = pick_one({
		_("What do you say back?"),
		_("Your response?"),
		_("Keep talking?"),
		_("Anything to add?"),
		
	})
    vn.func( function()
		local spoken = tk.input(_("Conversation"), 0, 64, title_choice)
		if spoken then
			local appreciation, understood = appreciate_spoken(spoken, crewmate)

			if not understood then
				-- we didn't even understand this, lets increase the chance of an appropriate response
				local responses = {
					_("Whatever."),
					_("Yeah, okay."),
					fmt.f(_("Okay, {name}."), {name = player.name()}),
					fmt.f(_("Aright, {name}."), {name = player.name()}),
					_("Sure."),
					_("Oh, really?"),
					_("Sorry?"),
					_("What?"),
					_("Huh?"),
					_("I'm a little hard of hearing."),
					_("Oh, sure."),
					_("I didn't quite catch that."),
					_("I'm afraid I don't really know what you're saying."),
					_("I'm afraid that I don't quite understand you."),
					_("I don't know."),
					_("Yeah... It is what it is."),
					_("Carpe diem!"),
					_("Let's check in with the others."),
					_("*sips drink*"),
					add_special(crewmate, "laugh"),
					add_special(crewmate),
					_("Sorry, are you talking to me?"),
					_("Sorry, can you repeat that?"),
					fmt.f(_("I'm sorry {name}, I wasn't listening."), {name = player.name()}),
					fmt.f(_("I'm sorry {name}, can you rephrase that?"), {name = player.name()}),
					_("Sometimes you just gotta... Yeah, I don't know, sorry, I wasn't really listening."),
					_("Sorry, I'm a bit distracted."),
					_(
						"Look, can we talk about something I'm actually knowledgable about? I feel like you're trying to set me up to look like a fool."
					),
					_("Yeah, I don't know much about that."),
					_("I don't know much about that."),
					_("I don't know anything about that."),
					_("I don't know anything about it."),
					_("I don't know what you're talking about."),
					_("I don't know what you're saying."),
					_("I'm not very knowledgable about those things."),
					_("I'm not very knowledgable about these things."),
					_("I'm not interested in that."),
					_("I never think about that."),
					_("What's gotten into you?"),
					_("Let's just grab a drink, shall we?"),
					_("How about we just forget about all this?"),
					_("You're not thinking of firing me, are you?"),
					_("What's going on? I'm so confused."),
					_("Sometimes I just don't understand you."),
					_("You can be difficult to understand sometimes.")
				}
		
				responses = join_tables(responses, appreciation)
				if crewmate.conversation.sentiments then
					-- a chance of changing the subject
					responses = join_tables(responses, crewmate.conversation.sentiments)
				else
					-- try to be a bit smarter than usual and enlist help from a function
					responses = join_tables(responses, generate_responses(spoken, crewmate))
				end

				if not spoken or spoken:len() == 0 then
					message = fmt.f(pick_one(responses), FAKE_CAPTAIN)
					vn.jump("end")
					return
				end
				
				-- finally, use our fancy analyzer to see if the player "scores" and can continue the conversation
				local response, detected = analyze_spoken(spoken, FAKE_CAPTAIN, crewmate)
				-- I don't know how many stack frames we can handle, but 10 sounds like a long conversation in case the player is trapped
				-- which I guess is kind of likely if the just keeps saying the same stuff
				if detected and (count < 10) then
					message = fmt.f(response, FAKE_CAPTAIN)
					count = count + 1
				-- count of 10 is very high, lets try 6
				elseif detected and count == 6 then
					message = fmt.f(response, FAKE_CAPTAIN)
					vn.jump("end")
					return
				else
					table.insert(responses, response)
					message = fmt.f(pick_one(responses), FAKE_CAPTAIN)
					-- we're not sure how to answer, so we are dismissive here
					vn.jump("end")
					return
				end
			else -- understood and "appreciated"
				message = fmt.f(pick_one(appreciation), FAKE_CAPTAIN)
			end
		else -- not spoken
			vn.jump("end")
		end
	end )
	
	discusser( function () return message end )
	vn.jump("start")
	
	vn.label("end")
	discusser(pick_one(crewmate.conversation.default_participation))
	vn.done()
	vn.run()
end

-- this is the place to put custom management jobs, (one-off tasks)
local function doSpecialManagementFunc(edata)
	local special = edata.manager.special
	
	if special.price then -- we have to charge for it
		player.pay(-special.price)
		playMoney()
		-- we charged the player, we earn xp
		edata.xp = edata.xp + 0.01
	end
	
	-- if we have a goodie crate
	if special.crate then
		-- distribute some fruit or something, everyone is a bit happier
		for _i, crewmate in ipairs(mem.companions) do
			-- simulate consuming one item now
			local enjoyment = evaluate_item_haste(crewmate, special.crate.fruit)
			if enjoyment > 0.75 then
				insert_sentiment(crewmate, fmt.f(_("That was a nice {fruit}."), special.crate))
			end
			crewmate.satisfaction = crewmate.satisfaction + enjoyment
				
			if	-- the crew member might take another one for later
				special.crate.comm
				and (not crewmate.item or enjoyment > 0.56)
			then
					give_item(crewmate, special.crate.fruit)
			end
		end
		-- if this is a lucky crate with a commodity, there's more fruit to pass around
		if special.crate.comm then
			player.pilot():cargoAdd(special.crate.comm, 1)

		end
		-- no reusing crates
		edata.manager.special = nil
	end
	-- TODO: other stuff
	
	if edata.manager.type == _("Shuttle") then
		-- we are a shuttle manager, so we manage the shuttle "owned" by the ship
		local shuttle = mem.ship_interior.shuttle
		-- if we don't have a fitting, create one now
		local pppp = pilot.add(shuttle.ship, edata.faction)
		if edata.manager.outfits then
			-- perform a full refit
			pppp:outfitRm("all")
			-- add the favorite outfit
			if edata.manager.preferred_outfit then
				local fits = pppp:outfitAdd(edata.manager.preferred_outfit)
				print("adding favored:  " .. tostring(edata.manager.preferred_outfit))
				if not fits then print(" doesn't fit! " ) end
				-- don't keep adding these
				edata.manager.preferred_outfit = nil
			end
			-- add the old outfits
			for _j, o in ipairs(edata.manager.outfits) do
				local installed = pppp:outfitAdd(o)
				print("installing old outfit:  " .. tostring(o))
				if not installed then
					print("old outfit NOT installed:  " .. tostring(o))
				end
			end
		else
			edata.manager.outfits = {}
		end
		
		pppp:outfitRm("cores")
		
		-- try to fit these core modules
		if edata.manager.system then
			print("adding score " .. tostring(edata.manager.system))
			pppp:outfitAdd(edata.manager.system)
		end
		
		if edata.manager.engine then
		print("adding ecore " .. tostring(edata.manager.engine))
			pppp:outfitAdd(edata.manager.engine)
		end
		
		if edata.manager.hull then
			print("adding dcore " .. tostring(edata.manager.hull))
			pppp:outfitAdd(edata.manager.hull)
		end
		
		if pppp:spaceworthy() then		
			-- save the fitting, it's good
			edata.manager.outfits = {}
			print("final")
			for j, o in ipairs(pppp:outfits()) do
				edata.manager.outfits[#edata.manager.outfits + 1] = o:nameRaw()
				print(o)
			end
			print("saved a spaceworthy fitting")
		else
			edata.sentiment = _("I wonder if the captain will notice that I couldn't fit the shuttle to the requested specifications.")
			edata.satisfaction = edata.satisfaction - 0.08
			print("saved a garbage fitting:")
			for j, o in ipairs(pppp:outfits()) do
				print(o)
			end
			local _, reason = pppp:spaceworthy()
			print(reason)
		end
		pppp:rm()
		
		-- we did the thing
		edata.manager.special = nil
	end
	
	-- whatever we did, we probably made a small mess on the side
	mem.ship_interior.dirt = mem.ship_interior.dirt + 0.01
end

-- an officer (or maybe smuggler) converts a ton of food into a fruit crate
-- or if a requested argument was supplied, tries to construct that instead
local function convertFoodToFruit(officer, requested)

	local create_custom = false
	local commodity_required = nil
	--[[ "cost" -- what is this variable? read on:
	Additional multiplier to a price constant (the item's string length)
	determines the "weight" of each character in the word of this kind for the price
	so for instance, all fruit costs the same, but "special items, requires water"
	will cost 75 credits per character in the item name, so "synthetic snakeskin applicator"
	would cost $2250 + the standard rate (starts at 200, otherwise 100 per crew member
	but reduced with a good officer).
	Additionally, if the cost is greater than or equal to 5, we label the discard button as "decorating"
	but anything that gets decorated or discarded is picked up by crew members that fancy it
	whether it's decorations or in the trash :) but at least we don't decorate ship with fruit or clothes
	--]]
	local cost = 1
	if requested then
		-- actually well thought out gifts, very expensive because requires effort
		for _i, item in ipairs(lang.nouns.gifts) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				cost = 375
			end
		end
	
		-- special items, requires water
		for _i, item in ipairs(lang.nouns.objects.random) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				commodity_required = "Water"
				cost = 75
			end
		end
	
		-- free items (cost only the payment of using the crate)
		for _i, item in ipairs(join_tables(lang.nouns.objects.items, lang.nouns.objects.tools)) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				cost = 5
			end
		end
		
		-- TODO: use textiles commodity when one exists
		for _i, item in ipairs(lang.nouns.objects.clothes) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				cost = 3
			end
		end
		
		-- requires luxury goods
		for _i, item in ipairs(lang.nouns.objects.accessories) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				commodity_required = "Luxury Goods"
				cost = 6
			end
		end

		
		-- requires food
		for _i, item in ipairs(join_tables(lang.nouns.food.fruit, lang.nouns.food.general)) do
			if
				not create_custom
				and string.find(requested, item)
			then
				create_custom = item
				commodity_required = "Food"
				cost = 0
			end
		end

		if create_custom then
			-- first we check if our thing wants a noun descriptor
			-- (e.g. asked for "lion statue")
			-- because we can't create actors, but we can create actor items
			-- like animal book or warrior sword (or warrior's salad)
			
			local add = " "
			-- quick sanity check, if our thing is a food, we don't call it a lion banana, but a lion's banana
			-- this small detail makes the dialog seem much more realistic
			for _i, food in ipairs(lang.getAll(lang.nouns.food)) do
				if string.find(food, create_custom) then
					add = "'s "
				end
			end
			local all_actors = lang.getAll(lang.nouns.actors)
			local replacement
			for _i, actor in ipairs(all_actors) do
				if not string.find(create_custom, actor) and string.find(requested, actor) and (not replacement or actor:len() > replacement.want:len()) then
					replacement = { want = actor, find = create_custom, paste = actor .. add .. create_custom }
				end
			end
		
			-- now we check if we have to adorn the item with an adjective that isn't a part of the item name
			local all_adjectives = lang.getAll(lang.adjectives)
			table.sort(all_adjectives, function(a,b) return #a>#b end)
			for _i, adjective in ipairs(all_adjectives) do
				if not string.find(create_custom, adjective) and string.find(requested, adjective) then
					create_custom = adjective .. " " .. create_custom
					-- each adornment incurrs an additional cost
					cost = cost + 3
					if replacement and string.find(adjective, replacement.want) then
						-- we can't add this replacement, because of things like "ant" in "elegant"
						replacement = nil
					end
				end
			end
			
			-- now check if we want to do the replacement
			if replacement then
				create_custom = create_custom:gsub(replacement.find, replacement.paste)
				-- noun adornment incurrs an additional cost multiplier
				cost = cost * 2
			end
		end
	end
	
	-- if we are capable of crafting the custom item, craft it, otherwise move on
	-- creating a custom item will throw out the old one!
	if create_custom
		and (
			not commodity_required
			or player.pilot():cargoHas(commodity_required)
		)
	then
		if commodity_required then
			player.pilot():cargoRm(commodity_required, 1)
		end
		officer.manager.special = {}
		 -- TODO: Better conversation lines here, would do a lot for immersion
		officer.manager.special.feedback = pick_one(officer.conversation.default_participation)
		
		-- Note: throwing out / decorating is the same thing, but the player doesn't know that
		-- also, the officer will pocket the first crafted thing before discarding/decorating
		-- so there is some hidden officer's greed, but you can bypass that by decorating more
		local discard_label = { _("Get rid of them"), "discard_special" }
		local alternate_use = pick_one({
			_("discard them."),
			_("take one for myself and throw out the rest."),
			_("get rid of them."),
			_("discard them. I might keep one for myself."),
			_("throw them out."),
			_("throw them away."),
			_("give them to the senior staff."),
			_("give some to the janitors."),
			fmt.f(_("give them to one of the {skill}s. They'll know what to do."), getCrewmateOnboard()),
			fmt.f(_("delegate the issue to {skill} {name}, {article_subject} seems to know a lot about "), getCrewmateOnboard()) .. create_custom .. "s.",
			fmt.f(_("have {firstname} figure out what to do with them."), getCrewmateOnboard()),
			_([["Misplace" them in the cargo bay.]]),
		})
		if cost >= 5 then
			discard_label = {
				fmt.f(
					_("Decorate {ship} with {item}s"), { ship = player.pilot():name(), item = create_custom }
				) , "discard_special"
			}
			alternate_use = _("use them to decorate the ship.")
		end
		
		officer.manager.special.choices = {
			{ _("Distribute among crew"), "special_yes" },
				discard_label, 
			{ _("Nevermind"), "end" }
		}
		
		-- we're specifically acquiring this item, so we pay up-front
		local price = math.max(200, 100 * #mem.companions - 50 * officer.bonus) + create_custom:len() * cost
		player.pay(-price)
		-- we still have to pay for distribution
		officer.manager.special.price = officer.manager.cost * 0.25
		local crate = {}
		crate.fruit = create_custom
		crate.origin = system.cur()
		officer.manager.special.crate = crate
		officer.manager.special.label = fmt.f(_("Distribute {fruit}s"), crate )
		-- we already crafted the item when we display this message
		officer.manager.special.message = _("You ") .. pick_one({
			_("commanded"),
			_("asked"),
			_("requested of"),
			_("ordered"),
			_("reminded"),
			_("demanded of"),
			_("expected of"),
			
		}) .. fmt.f(_(" me to procure some {fruit}s earlier. I can distribute them now to the crew if you'd like, or "), crate) .. alternate_use
		return true
	end
	
	-- we have something already, don't waste it now
	if officer.manager.special then return false end
	
	
	-- at this point it's safe to say we weren't ordered to craft anything that we can currently craft
	-- if we didn't have any fruit, see if we can convert a ton of food
	if player.pilot():cargoHas("Food") then
		player.pilot():cargoRm("Food", 1)
		officer.manager.special = {}
		officer.manager.special.feedback = pick_one(officer.conversation.default_participation)
		officer.manager.special.choices = {
		{ _("Distribute among crew"), "special_yes" },
		{ _("Throw those out"), "discard_special" },
		{ _("Nevermind"), "end" }
		}
		officer.manager.special.price = math.max(200, 100 * #mem.companions - 50 * officer.bonus)
		local crate = {}
		crate.fruit = getRandomFruit()
		-- 10% chance of converting the food into water instead of consuming it all
		if rnd.rnd(0, 10) == 0 then
			crate.comm = "Water"
		end
		crate.origin = system.cur()
		officer.manager.special.crate = crate
		officer.manager.special.label = fmt.f(_("Distribute {fruit}s"), crate )
		-- we already created the food now, so it's in the pantry and not the cargo bay
		officer.manager.special.message = fmt.f(_("I can distribute the {fruit}s from the foodstores in storage. Should I?"), crate)
		return true
	end
	
	return false
end

local function findCrewOfType( typetitle )
	for _i, crew in ipairs(mem.companions) do
		if crew.typetitle == typetitle then
			return crew
		end
	end
	
	return nil
end

-- NOTE: Any officer that can do a command discussion is going to have a shuttle bay requirement
-- if you don't have any bay_strength on the ship, those features should be disabled
-- (e.g. buy <commodity> from nearby spob or "command the ship while I take the shark for a quick spin")
function startCommandDiscussion()
	-- if there's an open dialog, close it
	player.commClose()
	local officer = mem.ship_interior.officers[_("First Officer")] or pick_one(mem.ship_interior.officers)
	if not officer then
		print("ERROR: No officer available in startCommandDiscussion")
		return
	end
    -- woah, we are an officer! lets do our officer/manager thing
    local management = officer.manager

    -- if we can't afford our officer's services...
    if management.cost and player.credits() < management.cost then
        vntk.msg(
            fmt.f("{typetitle} {name}", officer),
            fmt.f(
                _(
                    "You don't have the {credits} you owe me for previous management and assessment services. Maybe you should work on one problem at a time."
                ),
                {credits = fmt.credits(management.cost)}
            )
        )
        return
    end
		
	local chat = { _("Chat"), "chat" }
	local summon = { _("Summon crew"), "summon" }
	local drinks = { _("Motivate crew"), "drinks" }
	local dismiss = { _("Dismiss"), "end" }
	
	local choices = {}
	if true then -- TODO: figure out if this character knows how to chat
		table.insert(choices, chat)
	end

	-- if we have something special to use
	if management.special then
		table.insert(choices, 
			{ management.special.label, "special" }
		)
	elseif mem.ship_interior.dirt_accum > 0 or mem.ship_interior.dirt > player.pilot():ship():size() then
		table.insert(choices,
			{ _("Clean ship"), "clean" }
		)
	end
		
	-- summon the crew to the bar on the next spob
	if not mem.summon_crew and management.cost > 0 then
		table.insert(choices, summon)
	end	
	
	-- motivate the crew
	if management.cost > 0 then
		table.insert(choices, drinks)
	end
	
	-- always put the dismiss option last
	table.insert(choices, dismiss)

	-- default message in case we end up here without an appropriate management skill
	local message = fmt.f(_("Greetings {captain}. What can I do for you?"), {captain = pick_one({
		_("captain"),
		_("Captain"),
		player.name(),
		_("captain ") .. player.name(),
		_("Captain ") .. player.name(),
	})})
	
	officer.vncharacter = portrait.getFullPath(officer.portrait)
	local textbox_font = vn.textbox_font
	-- open dialog part comes here
	vn.clear()
	vn.scene()
	local escort = vn.newCharacter ( officer.name, {image = portrait.getFullPath(officer.portrait) } )
	vn.transition()
	vn.label("start")
	
	-- give a command assessment
	vn.func( function() 
		local key, troublemaker = commandAssessment()
		if not troublemaker then
			troublemaker = {}
		end
		message = fmt.f(pick_one(management.lines[key]), troublemaker)
	end )
	-- maybe we are an unknown kind of manager, then nothing happens

	escort(function() return message end)
	vn.menu(function () return choices end) -- makes us jump to a label
	vn.done()
	-- talk with the officer about something they know about
	vn.label("chat")
	-- monster func, just fold this and move on
	local command
	vn.func( function()
	
		message = _("I'm not sure how to help you.")
		local chatting = false
		local wmore = false
		-- we want to keep chatting as much as possible
		local spoken = tk.input(_("Discussion"), 0, 64, _("Say:"))
		if spoken then
			spoken = spoken:lower()
			-- for now, let's just do a basic personnel analysis in here to refactor later (with management logic)
			-- find a name from the input
			for _i, worker in ipairs(mem.companions) do
				if string.find(spoken, worker.name:lower()) 
				or string.find(spoken, worker.firstname:lower())
				then
					chatting = true
					-- this worker is the subject
					if string.find(spoken, "rename") then
						-- the captain wants to rename this person
						local new_name = tk.input(worker.name, 3, 16, _("New Name:"))
						if new_name then
							worker.name = new_name
							message = fmt.f(_("Alright, {article_subject} will now be known as {name}."), worker)
							-- worker's xp and satisfaction is slightly affected by this
							worker.satisfaction = worker.satisfaction + rnd.sigma()
							worker.xp = worker.xp + rnd.sigma() * 0.01
							insert_sentiment(worker, fmt.f(_("{typetitle} {name} gave me a new name."), officer))
							insert_sentiment(worker, fmt.f(_("{name} didn't like my name."), FAKE_CAPTAIN))
							insert_sentiment(worker, fmt.f(_("{firstname} didn't like my name."), FAKE_CAPTAIN))
							insert_sentiment(worker, fmt.f(_("Well, {article_subject} didn't like my name."), FAKE_CAPTAIN))
						else -- the captain canceled the renaming process, stop talking now
							vn.jump("say_end")
						end
					elseif string.find(spoken, "renick") then
						-- the captain wants to give this person a new nickname
						-- like renaming, but generates a random new first name instead of setting a specific last name
						-- just so that you can't force a crewmates friends to call him an expletive, 
						-- even though you can totally name him that as a proper last name if you want
						local _last, new_name = pilotname.human()
						if new_name then
							worker.firstname = new_name
							message = fmt.f(_("Alright, {article_subject} will now be known as {firstname}."), worker)
							-- worker's xp and satisfaction is slightly affected by this
							worker.satisfaction = worker.satisfaction + rnd.sigma()
							worker.xp = worker.xp + rnd.sigma() * 0.01
							insert_sentiment(worker, fmt.f(_("{typetitle} {name} gave me a new nickname."), officer))
							insert_sentiment(worker, fmt.f(_("{name} didn't like the first name assigned to me at birth."), FAKE_CAPTAIN))
							insert_sentiment(worker, fmt.f(_("{firstname} didn't like my nickname."), FAKE_CAPTAIN))
							insert_sentiment(worker, fmt.f(_("Well, {article_subject} didn't really like my name."), FAKE_CAPTAIN))
						end
					elseif string.find(spoken, _("sheet"))
						or string.find(spoken, _("info"))
						or string.find(spoken, _("detail"))
					then
						-- be a perfect commander and access the personnel files
						message = getCrewSheet(worker)
						vn.jump("crewsheet")
					-- don't fire myself, I'm not that valiant
					elseif worker ~= officer and (
						string.find(spoken, _("fire"))
						or string.find(spoken, _("airlock"))
						)
					then
						-- the captain wants to throw this person out of the airlock
						terminate_crew(worker, fmt.f(_("You ordered {title} {officer} to throw {worker} out of the airlock in {system}."), { officer = officer.name, title = officer.typetitle, worker = worker.name, system = system.cur() }))
						-- recalculate crew roster using takeoff logic
						takeoff()
						der.sfx.unboard:play()
						-- everyone should get some xp or something for witnessing the sacrifice
						for _j, witness in ipairs(mem.companions) do
							local xp_bonus = rnd.rnd() + rnd.sigma() * 0.05
							witness.xp = math.min(99, witness.xp + xp_bonus)
							-- TODO: create sacrifice memory :)
						end
						vn.jump("end")
					elseif string.find(spoken, _("commend")) then
						-- the captain wants to boost this person's xp and satisfaction
						player.pay(-management.cost)
						playMoney()
						-- small motivational boost
						worker.satisfaction = worker.satisfaction + 0.2
						-- small pay bump
						worker.salary = math.ceil(worker.salary * 1.01)
						-- small xp gain chance
						worker.xp = math.min(99, worker.xp + 0.1 * (rnd.rnd() + rnd.sigma()))
						insert_sentiment(worker, fmt.f(_("{typetitle} {name} said I'm doing a good job!"), officer))
						insert_sentiment(worker, fmt.f(_("{skill} {name} said I'm doing a good job!"), officer))
						-- give the worker a symbolic gift of some kind
						local gift_options = append_table(
							-- construct a base table of appropriate gifts of types and descriptors
							{
								fmt.f("{nice} {item}", { nice = pick_one(lang.adjectives.positive.nice), item = pick_one(lang.nouns.objects.items) } ),
								fmt.f("{nice} {item}", { nice = pick_one(lang.adjectives.positive.nice), item = pick_one(lang.nouns.objects.clothes) } ),
								fmt.f("{item}", { item = pick_one(lang.nouns.objects.accessories) } ),
								fmt.f(_("{item} repair manual"), { item = pick_one(lang.nouns.objects.spaceship_parts) } ),
								fmt.f(_("{item} troubleshooting guide"), { item = pick_one(lang.nouns.objects.spaceship_parts) } ),
								fmt.f(_("{item} diagnostics & analysis system"), { item = pick_one(lang.nouns.objects.spaceship_parts) } ),
								fmt.f("{adjective} {item}", { adjective = pick_one(lang.adjectives.size.small), item = pick_one(lang.getAll(lang.nouns.objects)) } ),
								fmt.f(_("{adjective} {item} figurine"), {
									adjective = pick_one(join_tables(lang.adjectives.positive.magical, lang.adjectives.violent)),
									item = pick_one(lang.getAll(lang.nouns.actors.people))
								} ),
								fmt.f(_("{nice} {adjective} {item} figurine"), { nice = pick_one(lang.adjectives.positive.nice), adjective = pick_one(lang.getAll(lang.adjectives)), item = pick_one(lang.getAll(lang.nouns.actors.people)) } ),
								fmt.f("{nice} {item}", { nice = pick_one(lang.adjectives.colors), item = pick_one(lang.nouns.objects.items) } ),
								fmt.f("{nice} {item}", { nice = pick_one(lang.adjectives.colors), item = pick_one(lang.nouns.objects.clothes) } ),
							},
							-- add custom stylized choices of what we would consider nice gifts
							lang.nouns.gifts
						)
						give_item(worker, pick_one(gift_options))
						-- remember that we got this nice gift
						local sentiment = fmt.f(_("The captain gave me a {item}!"), worker)
						create_memory(worker, "specific", { topic = player.name(), specific = string.gsub(sentiment, "!", ".") } )
						insert_sentiment(worker, sentiment)
						-- tell the captain what we got the worker so that the player enjoys the worker mentioning it
						message = fmt.f(_("Good idea. I'll get {article_object} a {item} as well."), worker)
						-- we have a job to do, go do it, captain can bother us when we are done
						vn.jump("say_end")
					elseif string.find(spoken, _("summon")) then
						command = worker
						vn.jump("summon_single")
						return
					else
					-- let's talk about this person
						message = fmt.f(pick_one(management.lines.specific), worker)
					end

				end
			end
			if not chatting then
				-- TODO: check if the captain wants to hire new staff
				if string.find(spoken, _("rename to")) then
					-- the captain wants te rename me :'(
					officer.name = spoken:sub( 11, #spoken):gsub("^%l", string.upper)
				end
				-- special missions

				-- show me a list of crew that match spoken (typetitle or skill)
				if string.find(spoken, _("list")) then
					chatting = true
					command = spoken
					vn.jump("list")
					return
				elseif
					string.find(spoken, _("cargo"))
					or string.find(spoken, _("sell"))
					or string.find(spoken, _("trade"))
				then
					chatting = true
					vn.jump("mission_sell")
					return
				elseif
					string.find(spoken, _("buy"))
					or string.find(spoken, _("procure"))
					or string.find(spoken, _("purchase"))
				then
					-- only if we find something we can use here
					local comm = parseCommodity(spoken)
					if
						comm
					then
						command = comm:name():lower()
						chatting = true
						vn.jump("mission_buy")
						return
					end
				elseif
					string.find(spoken, _("let me fly"))
					or string.find(spoken, _("fly shuttle"))
					or string.find(spoken, _("joyride"))
				then
					chatting = true
					vn.jump("mission_shuttle")
				elseif string.find(spoken, _("summon pilot")) then
					command = findCrewOfType(_("Pilot"))
					if command then
						vn.jump("summon_single")
						return
					end
				end
				
				-- assume that if we want to buy a commodity, acquire/procure etc are already handled
				-- do we need to restock something?
				for _j, restock in ipairs(join_tables(lang.nouns.food.fruit, {
					_("get me"),
					_("give me"),
					_("find me"),
					_("craft"),
					_("create"),
					_("procure"),
					_("acquire"),
					_("restock"),
					_("fruit"),
					_("crate"),
					_("food"),
					_("hungry"),
				})) do
					if string.find(spoken, restock) then
						if convertFoodToFruit(officer, spoken) then
							insert_sentiment(officer, fmt.f(_("{name} seems to like bananas."), FAKE_CAPTAIN))
							insert_sentiment(officer, fmt.f(_("{name} seems to love mangoes."), FAKE_CAPTAIN))
							insert_sentiment(officer, fmt.f(_("{name} seems to really love strawberries."), FAKE_CAPTAIN))
							insert_sentiment(officer, _("So that's why there are never any strawberries..."))
							-- we're done with this conversation, we have a task!
							message = fmt.f(_("Good idea, I will procure some {fruit}s soon. Give me a moment."), officer.manager.special.crate)
							vn.jump("say_end")
							return
						else -- we couldn't create a fruit crate from the food
							message = _("I'm sorry, there's nothing I can do right now.")
							insert_sentiment(officer, fmt.f(_("{firstname} won't be happy that I couldn't restock the fruit."), FAKE_CAPTAIN))
							insert_sentiment(officer, _("We need more food in the cargo bay to keep the crew happy."))
						end
					end
				end
				
				-- last ditch, keep chatting?
				for _j, more in ipairs({
					_("more"),
					_("please"),
					_("what"),
					_("why"),
					_("how"),
					_("else"),
					_("anything"),
					_("doing"),
					_("satisf"),
					_("who"),
					_("help"), -- this is what you're really paying for with the officer
				}) do
					if string.find(spoken, more) then
--						print(fmt.f("found {more}", {more=more}))
						vn.jump("start")
						wmore = true
						chatting = true
						insert_sentiment(officer, fmt.f(_("{name} sure likes to chat."), FAKE_CAPTAIN))
					end
				end
			end
		end
		if wmore then vn.jump("start") end
		if not spoken or not chatting then
			vn.jump("end")
		end
	end )
	escort( function() return message end )
	vn.jump("chat")
	vn.done()
	
	if management and management.special then
		-- a custom function defined in the character sheet
		vn.label("special")
		escort(management.special.message)
		if management.special.choices then
			vn.menu(management.special.choices)
		end
		
		-- we assume the player says yes or that there are no choices
		-- if the choice was no, player jumps
		
		vn.label("special_yes")
		escort(management.special.feedback)
		vn.func( function() 
			doSpecialManagementFunc(officer)
		end )
		
		vn.done()
	end
	
	vn.label("discard_special")
	-- discards the special item, if there is one
	vn.func( function()
		-- when an officer discards something, some waste is left behind
		-- but the officer earns or loses some experience, favoring gains
		-- but since it's an officer, discarded items become decorations to be enjoyed

		officer.xp = officer.xp + 0.1 * (rnd.sigma() + rnd.rnd())

		local item
		if officer.manager.special and officer.manager.special.crate and officer.manager.special.crate.fruit then
			item = officer.manager.special.crate.fruit
		end
		-- I'm an officer, I'll take this item for myself if I like it
		if item and not officer.item and evaluate_item_haste(officer, item) > 0.6 then
			give_item(officer, item)
		else -- we had to discard something, make the dirt happen
			mem.ship_interior.dirt = mem.ship_interior.dirt + officer.xp * 0.06
			mem.ship_interior.decoration = item
		end
		
		-- clear the payload
		officer.manager.special = nil
	end )
	escort(_("Consider it done."))
	vn.done()
	
	vn.label("summon")
	-- let the player to summon the crew for credits
	escort(
		fmt.f(
			_(
				"Would you like to summon the crew to be available for discussion at the next bar? It will cost {credits} to persuade everyone."
			),
			{credits = fmt.credits(management.cost)}
		)
	)
	vn.menu({
		{ _("Yes"), "do_summon" },
		{ _("No"), "end" },
	})
	vn.label("do_summon")
	vn.func( function () 
		mem.summon_crew = true
		player.pay(-management.cost)
		playMoney()
		shiplog.append(
			logidstr,
			fmt.f(
				_("You paid {credits} in crew management fees."),
				{
					credits = fmt.credits(management.cost)
				}
			)
		)
		
		-- don't let the player summon twice
		for index, choice in ipairs(choices) do
			if choice == summon then
				table.remove(choices, index)
			end
		end
	end )

	vn.jump("end")
	
	-- let the player buy drinks for the crew that is present
	-- the payer has to pay for as many drinks as there are people at the bar
	-- because well, otherwise the player should be distributing fruit or something
	-- the smuggler can do that (gets a crate for smuggling and can convert food into fruit crate)
	vn.label("drinks")
	escort(
			_(
				"Would you like your officer to try to motivate the crew?"
			)
	)
	vn.menu({
		{ _("Yes"), "do_drinks" },
		{ _("No"), "end" },
	})
	vn.label("do_drinks")
	vn.func( function () 
		-- instead of paying for drinks, the commander pays with xp
		local siphoned_xp = math.max(0, officer.xp * 0.086)
		officer.xp = officer.xp - siphoned_xp
		-- everyone at the bar gets a decent chance to enjoy their drink and actually like it
		for _i, worker in ipairs(mem.companions) do

			-- buy everyone a drink, but not the person who bought the round
			if worker ~= officer then
				local enjoyment = rnd.sigma() + siphoned_xp - rnd.rnd()
				worker.satisfaction = math.min(10, worker.satisfaction + enjoyment * 0.1)
				if enjoyment >= 1.25 then
					worker.conversation.sentiment = _("I really enjoyed that motivational speech.")
				elseif enjoyment < 0 then
					insert_sentiment(worker, _("That motivational meeting was a waste of time."))
				elseif rnd.rnd() < worker.chatter then
					insert_sentiment(worker, _("It's nice to get some attention from the officers sometimes."))
				end
				print(fmt.f("{name} evaluated motivation at {enjoyment}", {name = worker.name, enjoyment=enjoyment}))
			elseif worker == officer then
				-- if I motivated the crew, I feel great
				officer.satisfaction = officer.satisfaction + 0.01 * siphoned_xp
			end

		end
		shiplog.append(
			logidstr,
			fmt.f(
				_("Your commander {name} tried to motivate your crew."),
				officer
			)
		)

	end )
	vn.sfxBingo()
	vn.jump("end")
	
	-- display a nice crew sheet
	vn.label("crewsheet")
	vn.func( function()
		vn.textbox_font = graphics.newFont( _("fonts/D2CodingBold.ttf"), 15 )
	end)

	escort( function () return message end )
	escort(_("Anything else?"))
	vn.func( function()
		vn.textbox_font = textbox_font
	end)
	vn.jump("chat")
	vn.done()

	-- summon a single crewmate for a conversation on the bridge
	vn.label("summon_single")
	vn.func( function()
		vn.textbox_font = textbox_font
	end)
	vn.func( function ()
		if command.away then
			message = fmt.f(_("It looks like {firstname} isn't on board. Didn't we send {article_object} on a "), command) .. fmt.f(_("{mission} in the {ship}?"), command.away)
		else
			if command.manager then
				hook.timer(rnd.rnd(12, 16), "startManagement", command)
			else
				hook.timer(rnd.rnd(2, 6), "startDiscussion", command)
			end
			message = fmt.f(_("You should expect {article_object} to arrive shortly."), command)
		end
	end )
	escort(function () return message end )
	vn.done()
	
	-- player wants to find some crew types
	-- or find information about the crew
	vn.label("list")
	local response
	vn.func( function ()
		vn.textbox_font = graphics.newFont( _("fonts/D2CodingBold.ttf"), 15 )
		response = ""
		for _i, worker in ipairs(mem.companions) do
			if 
				string.find(command, worker.typetitle:lower())
				or string.find(command, worker.skill:lower())
				or string.find(command, _("all"))
				or string.find(command, _("staff"))
			then
				response = response .. fmt.f("{xp: 3.0f} | {typetitle:13s} | {skill:15s} {name:16s},\t{firstname: 9s} \n", worker)
			else
			-- do a deeper search of this crew member, like if the player typed "list managers" or "list officer", we want all managers or crew with officer in the manager title
				local found = false
				for word in command:gmatch("%w+") do
					if not found and (
						string.find(worker.typetitle:lower(), word)
						or string.find(worker.skill:lower(), word)
						)
					then
						found = true
					elseif worker.manager and (
						string.find(worker.manager.type:lower(), word)
						or string.find(command, _("manager"))
						or (worker.manager.skill and string.find(worker.manager.skill:lower(), word))
						)
					then
						found = true
					end
				end
				if found then
					response = response .. fmt.f("{xp: 3.0f} | {typetitle:13s} | {skill:14s} {name:16s},\t{firstname: 9s} \n", worker)
				end
			end
		end
		if not string.find(response, "\n") then
			vn.textbox_font = textbox_font
			response = _("I know of no crew members matching that description.")
		end
	end )
	escort( function() return response end )
--	escort( _("Let me know if you need anything.") )
	vn.jump("chat")
	vn.done()
	
	-- the player wants to leave the commander in charge of the ship and
	-- take a joyride in the shuttle
	vn.label("mission_shuttle")
	
	vn.func( function ()
		-- check the bay strength first
		if officer.shuttle.ship:size() > math.floor(mem.ship_interior.bay_strength / 3) then
			response = fmt.f(_("The {name} isn't spaceworthy because it wouldn't fit in the docking bays. We need a bigger ship, more fighter bays or a smaller shuttle ship."), { name = officer.shuttle.ship:name() } )
			return
		end
		-- we need a chosen pilot because we need a shuttle manager to save the fitting when we get back
		local chosen_pilot = findCrewOfType(_("Pilot"))
		if chosen_pilot and not officer.shuttle.out then
			response = fmt.f(_([[Of course, I'll get {skill} {name} to prep the shuttle for you.
You can trust my capable hands with the ship.]]), chosen_pilot)
		elseif mothership ~= player.ship() then
			response = fmt.f(_("I can't find the {name}... Wait a minute, aren't you hailing me from it right now?"), { name = officer.shuttle.ship:name() } )
			return
		elseif officer.shuttle.out then
			response = fmt.f(_("I can't find the {name}. There's no shuttle."), { name = officer.shuttle.ship:name() } )
			return
		end
		-- good to go!
		-- we are using this shuttle
		mem.ship_interior.shuttle = officer.shuttle
		-- this is the mission payload
		local payload = {
			commander = officer,
			shuttle_manager = chosen_pilot
		}
		-- start the mission
		hook.timer(6 + 0.1 * (100 - officer.xp), "player_swaps_to_shuttle", payload)
	end )
	
	escort ( function () return response end )
		
	vn.done()
	
	-- player wants to sell some cargo remotely	
	vn.label("mission_sell")
	vn.func( function ()
		-- check the bay strength first
		if officer.shuttle.ship:size() > math.floor(mem.ship_interior.bay_strength / 3) then
			response = fmt.f(_("The {name} isn't spaceworthy because it wouldn't fit in the docking bays. We need a bigger ship, more fighter bays or a smaller shuttle ship."), { name = officer.shuttle.ship:name() } )
			return
		end
	
		local chosen_pilot = findCrewOfType(_("Pilot"))
		if chosen_pilot and not officer.shuttle.out then
			response = fmt.f(_("Of course, I'll get {skill} {name} on it."), chosen_pilot)
		elseif officer.shuttle.out then
			response = fmt.f(_("I can't find the {name}. There's no shuttle."), { name = officer.shuttle.ship:name() } )
			return
		else
			-- the shuttle is here, let the first officer fly it (risk it for the biscuit)
			response = _("I couldn't find a pilot for the shuttle, I'm going myself.")
			chosen_pilot = officer
			clearCommanderInterface()
		end
		-- we are using this shuttle
		mem.ship_interior.shuttle = officer.shuttle
		-- this is the mission payload
		local payload = {
			shuttle = officer.shuttle,
			crewsheet = chosen_pilot,
			mission = { mission = "Trade Mission", ship = officer.shuttle.ship, directive = "sell" },
		}
		-- start the mission
		hook.timer(3 + 0.1 * (100 - officer.xp), "away_mission", payload)
	end )
	escort( function () return response end )
	
	vn.done()
	
	-- player wants to purchase commodities remotely	
	vn.label("mission_buy")
	vn.func( function ()
		-- check the bay strength first
		if officer.shuttle.ship:size() > math.floor(mem.ship_interior.bay_strength / 3) then
			response = fmt.f(_("The {name} isn't spaceworthy because it wouldn't fit in the docking bays. We need a bigger ship, more fighter bays or a smaller shuttle ship."), { name = officer.shuttle.ship:name() } )
			return
		end
	
		local chosen_pilot = findCrewOfType(_("Pilot"))
		if chosen_pilot and not officer.shuttle.out then
			response = fmt.f(_("Of course, I'll get {skill} {name} on it."), chosen_pilot)
		elseif officer.shuttle.out then
			response = fmt.f(_("I can't find the {name}. There's no shuttle."), { name = officer.shuttle.ship:name() } )
			return
		else
			-- the shuttle is here, let the first officer fly it (risk it for the biscuit)
			response = _("I couldn't find a pilot for the shuttle, I'm going myself.")
			chosen_pilot = officer
			clearCommanderInterface()
		end
		-- we are using this shuttle
		mem.ship_interior.shuttle = officer.shuttle
		-- this is the mission payload
		local payload = {
			shuttle = officer.shuttle,
			crewsheet = chosen_pilot,
			mission = { mission = "Trade Mission", ship = officer.shuttle.ship, directive = "buy", target = command },
		}
		-- start the mission
		hook.timer(3 + 0.1 * (100 - officer.xp), "away_mission", payload)
	end )
	escort( function () return response end )
	
	vn.done()
	
	-- the ship is getting dirty and needs to be cleaned
	-- the player really wants to clean it
	vn.label("clean")
	vn.func( function ()
		player.pay(-management.cost)
		playMoney()
		-- figure out how well it gets cleaned
		-- summon all the non-senior staff for cleaning
		local sponge = 2 -- we get 2 from the officer
		for _i, worker in ipairs(mem.companions) do
			if
				string.find(worker.skill, _("Sanitation"))
				or string.find(worker.skill, (_("Janitor")))
			then
				-- all janitors get "motivated" regardless of satisfaction
				-- but the more experienced ones are much better
				sponge = sponge + worker.xp * 0.05 + rnd.rnd()
			elseif worker.skill == _("Cadet") then
				sponge = sponge + 0.5
			elseif worker.skill == _("Rookie") then
				sponge = sponge + 0.3 +  rnd.sigma()
			elseif worker.skill == _("Lieutenant") then
				sponge = sponge + 0.66
			end
		end

		-- cleaning isn't the same every time, and never perfect
		mem.ship_interior.dirt = math.max(
			mem.ship_interior.dirt - sponge,
			(sponge + mem.ship_interior.dirt) / (sponge * sponge)
		)
		
		print("cleaned ship to", mem.ship_interior.dirt)
		print("deteriation was", mem.ship_interior.dirt_accum)
		-- as a bonus, we re-calculate the dirt deteriation here
		takeoff()	
		print("deteriation is", mem.ship_interior.dirt_accum)
	end )
	
	vn.done()
	
	-- like end, but says the stored message
	vn.label("say_end")
	escort( function () return message end)
	vn.done()
	
	-- say goodbye
	vn.label("end")
	escort(pick_one(officer.conversation.default_participation))
	vn.done()
	vn.run()
end

-- TODO: fix this up so that you can open up a dialog and ask things
-- "How can I help you" -> choices -> default choices + open dialog
-- open dialog handler needs to somehow work generally
-- starts a managementarial discussion
function startManagement(edata)
	if edata.away then
		vntk.msg(fmt.f(_([[{typetitle} {name}]]), edata), fmt.f(_([[{typetitle} {name} could not be summoned due to being on a ]]), edata) .. fmt.f(_([[{mission} in the {ship}.]]), edata.away))
		return
	end
    -- woah, we are a manager! lets do our manager thing
    local management = edata.manager

    -- if we can't afford our manager's services...
    if management.cost and player.credits() < management.cost then
        vntk.msg(
            fmt.f("{typetitle} {name}", edata),
            fmt.f(
                _(
                    "You don't have the {credits} you owe me for previous management and assessment services. Maybe you should work on one problem at a time."
                ),
                {credits = fmt.credits(management.cost)}
            )
        )
        return
    end
	
	local chat = { _("Chat"), "chat" }
	local summon = { _("Summon crew"), "summon" }
	local drinks = { _("Buy a round of drinks"), "drinks" }
	local dismiss = { _("Dismiss"), "end" }
	local upgrade_shuttle = { _("Shuttle Management"), "shuttle_management_intro" }
	
	local choices = {}
	if true then -- TODO: figure out if this character knows how to chat
		table.insert(choices, chat)
	end
	if management.type == _("Shuttle") then
		table.insert(choices, upgrade_shuttle)
	end

	-- see if this is an officer that wants to buy a shuttle
	local shuttle_candidate = nil
	
	if	-- control for what officers can buy shuttles (pilots can't own their own shuttles)
		(player.isLanded() and spob.cur():services().shipyard)	-- must have a shipyard
		and string.find(edata.skill, _("Officer"))				-- must be an officer (i.e. titled officer, mid-tier+)
		and string.find(edta.typetitle, _("Commander"))			-- must be a commander (highest levels of officers)
	then
		local sships = spob.cur():shipsSold()
		shuttle_candidate = pick_one(sships)
		-- if we picked an appropriate ship based on bay_strength:
		-- display it, otherwise, nevermind! dream on officer...
		if  player.credits() < shuttle_candidate:price() * 3			-- budget issue, officer is responsible
			or (edata.shuttle and edata.shuttle.ship == shuttle_candidate
					and not edata.shuttle.out)							-- already flying this
			or shuttle_candidate:size() > 2								-- too big for a private shuttle
			or shuttle_candidate:size() > math.floor(mem.ship_interior.bay_strength / 3) 	-- doesn't fit in bays
		then
			shuttle_candidate = nil
		end
	end
	if shuttle_candidate then
		local shuttle_label = fmt.f(_("Buy {ship} ({price})"), { ship = shuttle_candidate:name(), price = fmt.credits(shuttle_candidate:price()) })
		local buy_shuttle = {  shuttle_label, "buy_shuttle" }
		table.insert(choices, buy_shuttle)
	end
	
	-- if this manager has a usable or distributable special item
	if management.special then
		table.insert(choices, 
			{ management.special.label, "special" }
		)
	end
	
	-- buy the crew some drinks
	if management.cost > 0 then
		table.insert(choices, drinks)
	end

	-- summon the crew to the bar next time
	if not mem.summon_crew and management.cost > 0 then
		table.insert(choices, summon)
	end	
	
	-- always put the dismiss option last
	table.insert(choices, dismiss)

	-- default message in case we end up here without an appropriate management skill
	local message = _("How can I help you?")
	local textbox_font = vn.textbox_font
	local decoration -- something to get from an assessment

	-- open dialog part comes here
	vn.clear()
	vn.scene()
	local escort = vn.newCharacter ( edata.name, {image = edata.vncharacter } )
	vn.transition()
	vn.label("start")
	
	-- figure out what kind of first message we want to give
	-- we are a personnel manager, let's give a personnel assessment
	vn.func( function()
		local key
		local troublemaker
		if string.find(management.type, _("Personnel")) then
			key, troublemaker = crewManagerAssessment()
			if not troublemaker then
				troublemaker = {}
			else -- I'm thinking about a "Cadet" or whatever
				edata.article_of_thought = troublemaker.skill
			end
			message = fmt.f(pick_one(management.lines[key]), troublemaker)
		elseif string.find(management.type, _("Psych")) then
			if not decoration then	-- this is a very expensive assessment
				key, troublemaker, decoration = psychologicalAssessment()
				edata.article_of_thought = decoration -- this is on our mind now
			end
			if not troublemaker then
				message = fmt.f(_("I think the crew would appreciate it if you distributed some {article_of_thought}."), edata)
			else
				message = fmt.f(pick_one(management.lines[key]), troublemaker)
			end
		end
	end )
	-- maybe we are an unknown kind of manager, then nothing happens
	
	
	escort(function() return message end)
	vn.menu(function () return choices end) -- makes us jump to a label
	vn.done()
	-- talk with the escort about something
	vn.label("chat")
--	local message
	-- TODO: call an approriate function?
	vn.func( function()
		message = _("I'm not sure how to help you.")
		local chatting = false
		local want_more = false
		-- we want to keep chatting as much as possible
		local spoken = tk.input(_("Discussion"), 0, 32, _("Say:"))
		vn.textbox_font = textbox_font
		if spoken then
			spoken = spoken:lower()
			-- for now, let's just do a basic personnel analysis in here to refactor later
			-- find a name from the input
			for _i, worker in ipairs(mem.companions) do
				if string.find(spoken, worker.name:lower()) 
				or string.find(spoken, worker.firstname:lower())
				then
					if string.find(spoken, _("sheet"))
						or string.find(spoken, _("info"))
						or string.find(spoken, _("detail"))
						or string.find(spoken, _("status"))
					then
						-- be a good manager and access the personnel files
						message = getCrewSheet(worker)
						vn.jump("crewsheet")
						return
					elseif string.find(management.type:lower(), _("psych")) then
						-- we can do psychological assessments about this person, let's do that
						worker.article_of_thought = findSuitableGift(worker)
						print(fmt.f("{name} wants a {article_of_thought}", worker))
						message = fmt.f(pick_one(management.lines.specific), worker )
						chatting = true
					else
						-- let's talk about this person
						message = fmt.f(pick_one(management.lines.specific), worker)
						chatting = true
					end
				end
			end
			if not chatting then
				for _j, more in ipairs({
					_("more"),
					_("please"),
					_("what"),
					_("else"),
					_("anything"),
					_("crew"),
					_("doing"),
					_("satisf"),
					_("who"),
				}) do
					if string.find(spoken, more) then
						print(fmt.f("found {more}", {more=more}))
						vn.jump("start")
						want_more = true
						chatting = true
					end
				end
			end
		end
		if want_more then vn.jump("start") end
		if not spoken or not chatting then
			vn.jump("end")
		end
	end )
	
	
	-- reset the font before replying
	vn.func( function()
		vn.textbox_font = textbox_font
	end )
	escort( function() return message end )
	vn.jump("chat")
	vn.done()
	
	-- BEGIN SECTION SHUTTLE MANAGER
	vn.label("shuttle_management_intro")
	escort( _([[So we're giving the old girl an overhaul?
Just tell me what you'd like me to change and I'll get everything ready for a refit job.
You'll be charged for the parts immediately, but you won't be charged for the work until we get to it.]]) )
	vn.label("shuttle_management")

	local shuttle_choices = {
		{ _("Change System"),  "sman_system" },
		{ _("Change Engines"), "sman_engine" },
		{ _("Change Hull"),    "sman_hull" },
		{ _("Add Outfit"),     "sman_extra" },
		{ _("Nevermind"),      "end" },
	}
	if player.isLanded() and spob.cur():services().shipyard then
		shuttle_choices = join_tables(
			{ { _("Replace Shuttle"), "sman_buy_shuttle"} },
			shuttle_choices
		)
	end
	vn.menu( shuttle_choices )
	vn.label("sman_buy_shuttle")
	if mem.ship_interior.shuttle then
		escort( fmt.f(_([[Tired of the old {ship} are we? That's fine, I can get us a replacement at the shipyard here. What would you like?]]), mem.ship_interior.shuttle) )
	else
		escort( _([[Wait a minute, do we even have a shuttle in there? Well, it's definitely time for a replacement.]]) )
	end
	local feedback
	vn.func( function()
		local desired_ship = tk.input(_("What shuttle should we buy?"), 4, 20, _("Ship name:")):lower()
		local shuttle_candidate
		
		-- now we search for a ship matching this description
		for _, sship in ipairs(spob.cur():shipsSold()) do
			if 
				string.find(sship:name():lower(), desired_ship)
				and	( -- get the better matching ship in case there are variants
					not shuttle_candidate
					or shuttle_candidate:name():len() > sship:name():len()
				)
			then
				-- this is what the player wants
				shuttle_candidate = sship
			end
		end

		
		-- find a reason to stop the player
		local reason
		if not shuttle_candidate then
			reason = _("I couldn't find anything matching that description in the shipyard... Why are you wasting my time?")
		elseif player.credits() < shuttle_candidate:price() then -- budget issue, can't afford
			reason = _("I'll be laughed at for not having the credits. I need you to be able to authorize a payment of at least ") .. fmt.credits(shuttle_candidate:price()) .. _(" in order to buy a ") .. shuttle_candidate:name() .. (" here.")
		elseif
			shuttle_candidate:size() > 2					  -- too big for a private shuttle
			or shuttle_candidate:size() > math.floor(mem.ship_interior.bay_strength / 3) -- doesn't fit in bays
		then
			reason = _("I'll be stuck with a ship without a hyperdrive, and I won't even be able to squeeze it into your fighter bays.")
		elseif (mem.ship_interior.shuttle and mem.ship_interior.shuttle.ship == shuttle_candidate
					and not mem.ship_interior.shuttle.out)-- already have this on board
		then
			feedback = fmt.f(_("Well... it looks to me like we already have a {ship}, what's wrong with the old one? I guess I'll restore it to the default configuration for now."), { ship = shuttle_candidate } )
			vn.jump("sman_clear_outfits")
			return
		end
		
		-- check if we prevented the player from buying it
		if  				
			reason 	
		then
			message = fmt.f(_("Well, I can tell you now that I'm not going to get that authorized, if I try to buy a {ship} now "), { ship = shuttle_candidate } ) .. reason
			shuttle_candidate = nil
			vn.jump("say_end")
			return
		end
		
		-- if we reach here, we definitely want to buy this ship
		local scost = shuttle_candidate:price()
		player.pay(-scost)
		mem.ship_interior.shuttle = { ship = shuttle_candidate }
		-- we probably have a commander that owns a shuttle, we need to throw out the old one
		-- if we don't have a commander, then this just becomes a ship shuttle
		local commander = getCommander()
		if commander then
			commander.shuttle = mem.ship_interior.shuttle
		end
		playMoney()
		shiplog.append(
			logidstr,
			fmt.f(
				_("Your shuttle manager {name} "),
				edata
			) .. fmt.f(_("bought a {shuttle} for the ship for {cost}."), {shuttle = shuttle_candidate, cost = fmt.credits(scost) } )
		)
		feedback = _("Excellent choice! I'll have the shipyard here modify one for shuttle usage right away. Don't forget to come back in a bit to reconfigure it if you want any other modifications.")
	end )
	
	-- deliberate fallthrough
	vn.label("sman_clear_outfits")
	escort( function () return feedback end)
	
	vn.func( function ()
		edata.manager.outfits = nil
	end )
	vn.jump("end")
	
	vn.label("sman_system")
	escort( _([[Alrighty then, let's see, what core system would you like? The Thalos 2202 is quite popular these days.]]) )
	
	vn.func( function ()
		local spoken = tk.input(_("New Core System"), 4, 64, _("System:"))
		local system = getShuttleOutfit(spoken)
		if system then
			edata.manager.system = system
			player.pay(-system:price()) -- NOTE we check if the player owned the system first, but didn't remove one
			playMoney()
			feedback = fmt.f(_("A {system} huh? I hope it fits!"), edata.manager)
		else
			feedback = _("That didn't quite make sense, we'll get it next time.")
		end
	end )
	escort( function () return feedback end )
	vn.jump("sman_extra")
	vn.done()
	
	vn.label("sman_engine")
	escort( _([[Alrighty then, what's next... What engines would you like? I'm a big fan of the Dart 150.]]) )
	vn.func( function ()
		local spoken = tk.input(_("New Core Engines"), 4, 64, _("Engines:"))
		local engine = getShuttleOutfit(spoken)
		if engine then
			edata.manager.engine = engine
			player.pay(-engine:price())
			playMoney()
			feedback = fmt.f(_("A {engine} huh? I hope that fits!"), edata.manager)
		else
			feedback = _("That didn't quite make sense, we'll get it later.")
		end
	end )
	escort( function () return feedback end )
	vn.jump("sman_extra")
	vn.done()
	
	vn.label("sman_hull")
	escort( _([[Well finally, last but not least -- what hull would you like? A small cargo hull of some kind perhaps?]]) )
	vn.func( function ()
		local spoken = tk.input(_("New Core Hull"), 3, 64, _("Hull:"))
		local hull = getShuttleOutfit(spoken)
		if hull then
			edata.manager.hull = hull
			player.pay(-hull:price())
			playMoney()
			feedback = fmt.f(_("A {hull} huh? I hope this fits!"), edata.manager)
		else
			feedback = _("That didn't quite make sense, we'll get it next time around.")
		end
	end )
	escort( function () return feedback end )
	vn.jump("sman_extra")
	vn.done()
	
	vn.label("sman_extra")
	escort( _("Do you want me to try to add some other outfit? Remember that this is a shuttle, weapons won't do me any good.") )
	vn.menu({
		{ _("Yes, add a specific outfit"),  "add_outfit" },
		{ _("Keep configuring core slots"), "shuttle_management" },
		{ _("No, let's finish up"),         "finish_inspection" },
		{ _("Nevermind, let's finish this later"), "end" },
	})
	vn.label("add_outfit")
	vn.func( function ()
		local spoken = tk.input(_("Extra outfit"), 0, 64, _("Extra outfit:"))
		-- TODO: check if spoken is a command
		if spoken:len() < 3 then
			-- no feedback
			feedback = _("Uhh... what?")
			return
		end
		local chosen = getShuttleOutfit(spoken)
		if chosen ~= nil then
			edata.manager.preferred_outfit = chosen
			player.pay(-chosen:price())
			playMoney()
			feedback = fmt.f(_("{preferred_outfit} eh? I hope that fits!"), edata.manager)
		else
			feedback = _("That didn't quite make sense, we'll get it next time around.")
		end
	end )
	escort( function () return feedback end )
	-- deliberate fallthrough
	
	vn.label("finish_inspection")
	local passed = false
	vn.func( function() 
		-- sanity check, captain doesn't know better
		if not (
			edata.manager.system and edata.manager.engine and edata.manager.hull
		) then
			feedback = _("Something isn't right with the selected outfits, something's missing but I can't put my finger on it... I swear though, we must be forgetting something!")
			return
		end
		vn.jump("inspection_good")
	end)
	escort( function () return feedback end )
	vn.jump("sman_extra") -- need to pass inspection from inside func or leave to avoid looping back
	
	vn.label("inspection_good")
	escort( _("Alright, check back with me in a bit and I should be able to make any requested adjustments.") )
	vn.func( function () 
		local special = {}
		special.message = _("Shuttle Maintenance")
		special.feedback = pick_one(edata.conversation.default_participation)
		special.price = math.ceil(math.max(20e3 + edata.salary, 23 * edata.salary) - edata.xp * edata.satisfaction)
		special.label = fmt.f(_("Shuttle Refit & Inspection"), {credits = fmt.credits(special.price) } )
		special.choices = {
		{ fmt.f(_("Perform Refit for {credits}"), {credits = fmt.credits(special.price) } ), "special_yes" },
		{ _("Nevermind"), "end" }
		}
		special.message = fmt.f(_("I can perform that {ship} inspection, refit and maintenance now. Should I?"), {ship = mem.ship_interior.shuttle.ship:name() })

		edata.manager.special = special
	end )
	vn.done()
	
	-- END SECTION SHUTTLE MANAGER
	
	-- if we have a special thing, enable the logic
	if management and management.special then
		-- a custom function defined in the character sheet
		vn.label("special")
		escort(management.special.message)
		if management.special.choices then
			vn.menu(management.special.choices)
		end
		
		-- we assume the player says yes or that there are no choices
		-- if the choice was no, player jumps
		
		vn.label("special_yes")
		escort(management.special.feedback)
		vn.func( function() 
			doSpecialManagementFunc(edata)
		end )
		
		vn.done()
	end
	
	vn.label("discard_special")
	-- throws out the special item, if there is one
	vn.func( function() 
		if edata.manager then
			mem.ship_interior.dirt = mem.ship_interior.dirt + 0.5 -- we aren't as clean as the officers
			-- earn a random amount of xp for using the item personally instead of discarding it
			edata.xp = edata.xp + rnd.sigma() + rnd.rnd()
			-- unhappy because we were told to discard something we brought on board
			edata.satisfaction = edata.satisfaction - 0.06
			-- anyone in the cargo bay enjoys the fruits of the discard
			-- and then the sanitation workers that go to the cargo bay (not janitorial)
			for ii, worker in ipairs(mem.companions) do
				if ii <= player.pilot():stats()["crew"] then
					if
						string.find(worker.skill, _("Cargo"))
						or string.find(worker.skill, _("Sani"))
					then
						worker.xp = worker.xp + 0.003
						worker.satisfaction =  worker.satisfaction + 0.1 * rnd.rnd()
						local sentiments = {
							_("I can't believe the captain wanted to throw these out. You want one?"),
							_("I can't believe the captain wanted to throw these out."),
							_("The captain wanted to throw these out. You want one?"),
							_("You want one of these?"),
							_("I grabbed these from the discard pile. You want one?"),
						}
						insert_sentiment(worker, pick_one(sentiments))
						
						-- if this crewmate actually likes this item, give one
						-- TODO: implement get_item from special wrapper
					end
				end
			end
			edata.manager.special = nil
		end
	end )
	vn.done()
	
	-- display a nice crew sheet
	vn.label("crewsheet")

	vn.func( function()
		vn.textbox_font = graphics.newFont( _("fonts/D2CodingBold.ttf"), 15 )
	end)

	escort( function () return message end )
	escort(_("Anything else?"))
	vn.func( function()
		vn.textbox_font = textbox_font
	end)
	vn.jump("chat")
	vn.done()
	
	vn.label("summon")
	-- let the player to summon the crew for credits
	escort(
		fmt.f(
			_(
				"Would you like to summon the crew to be available for discussion at the next bar? This will cost {credits}."
			),
			{credits = fmt.credits(management.cost)}
		)
	)
	vn.menu({
		{ _("Yes"), "do_summon" },
		{ _("No"), "end" },
	})
	vn.label("do_summon")
	vn.func( function () 
		mem.summon_crew = true
		player.pay(-management.cost)
		playMoney()
		shiplog.append(
			logidstr,
			fmt.f(
				_("You paid {credits} in crew management fees."),
				{
					credits = fmt.credits(management.cost)
				}
			)
		)
		
		-- don't let the player summon twice
		for index, choice in ipairs(choices) do
			if choice == summon then
				table.remove(choices, index)
			end
		end
	end )

	vn.jump("end")
	
	-- let the player buy drinks for the crew that is present
	-- the payer has to pay for as many drinks as there are people at the bar
	-- because well, otherwise the player should be distributing fruit or something
	-- the smuggler can do that (gets a crate for smuggling and can convert food into fruit crate)
	vn.label("drinks")
	local num_crew = #mem.companions
	if npcs and #npcs > 0 then
		num_crew = math.min(#npcs, num_crew)
	end
	local drinks_price = math.max(management.cost, management.cost * num_crew - (edata.satisfaction * management.cost * 0.1 * edata.xp))
	escort(
		fmt.f(
			_(
				"Would you like to buy everyone a round of drinks? This will cost {credits}."
			),
			{credits = fmt.credits(drinks_price)}
		)
	)
	vn.menu({
		{ _("Yes"), "do_drinks" },
		{ _("No"), "end" },
	})
	vn.label("do_drinks")
	vn.func( function () 
		player.pay(-drinks_price)
		-- everyone at the bar gets a decent chance to enjoy their drink and actually like it
		for _i, worker in ipairs(mem.companions) do
			-- make sure this npc is at the bar, find it in the loop
			for _j, cdata in pairs(npcs) do
				-- buy everyone a drink, but not the person who bought the round
				if cdata == worker and cdata ~= edata then
					-- enjoyment can be good or bad but pushed up by the managers xp
					local enjoyment = rnd.rnd() + rnd.threesigma() + edata.xp * 0.06
					worker.satisfaction = math.min(10, worker.satisfaction + enjoyment * 0.1)
					if enjoyment >= 1.25 then
						worker.conversation.sentiment = _("I really enjoyed that drink.")
					elseif enjoyment < 0 then
						insert_sentiment(worker, _("That drink I didn't ask for was nasty."))
					elseif rnd.rnd() < worker.chatter then
						insert_sentiment(worker, _("It was nice of the captain to buy us all drinks."))
					end
					print(fmt.f("{name} evaluated a free drink at {enjoyment}", {name = worker.name, enjoyment=enjoyment}))
				elseif cdata == edata then
					-- buy my own drink, of course I like it
					edata.satisfaction = edata.satisfaction + 0.02
				end
			end
		end
		shiplog.append(
			logidstr,
			fmt.f(
				_("You paid {credits} to treat your crew."),
				{
					credits = fmt.credits(management.cost)
				}
			)
		)

	end )
	vn.sfxBingo()
	vn.jump("end")
	
	-- buying a shuttle for an officer
	vn.label("buy_shuttle")
	vn.func( function()
		player.pay(-shuttle_candidate:price())
		edata.shuttle = { ship = shuttle_candidate }
		playMoney()
	end )
	escort(_("Nice, I'm sure it will come in handy."))
	vn.done()
	
	vn.label("say_end")
	escort( function () return message end )
	vn.done()
	-- say goodbye
	vn.label("end")
	escort(pick_one(edata.conversation.default_participation))
	vn.done()
	vn.run()
	
end

-- starts a conversation with the companion
local function startConversation(companion)
    local introduction
    -- what does the companion want to talk about
    -- if satisfaction is low, be negative and brief
    if companion.satisfaction < 0 then
        introduction = pick_one(companion.conversation.unsatisfied)
    else
        -- if satisfaction is high, be positive and verbose (extra greeting, etc)
        local greeting =
            pick_one(
            {
                _("Hello, Captain."),
                _("Oh. Hi there.") -- default neutral
            }
        )
        -- use chatter variable to determine verbosity TODO
        introduction = greeting .. "\n\n" .. pick_one(companion.conversation.satisfied)
    end

    if companion.conversation.sentiment then
        introduction = introduction .. " " .. companion.conversation.sentiment
    end

    return introduction
end

-- Asks the player whether or not they want to fire the pilot
local function crewmate_barConversation(edata, npc_id)
    local managing = ""
    if edata.manager then
        managing = edata.manager.type
    end
    if not edata.firstname then
        edata.firstname = "Mysterious"
    end -- generic dreadful nick, but better than "Gendrick"

    local praise_price = math.ceil(5 * edata.xp * edata.satisfaction)
    local scold_price = math.floor(20 * edata.xp + edata.satisfaction)

    local name_label = fmt.f("{firstname} {name}", edata)
    local n, _s =
        tk.choice(
        name_label,
        startConversation(edata),
        fmt.f(_(" Discuss {managing}"), {managing = managing}),
        fmt.f(_("Give Praise ({credits})"), {credits = fmt.credits(praise_price)}),
        fmt.f(_("Reprimand ({credits})"), {credits = fmt.credits(scold_price)}),
        fmt.f(_("Fire {typetitle}"), edata),
        _("Do nothing")
    )
    if n == 1 then -- Manager stuff
        -- if we are a manager, do the manager thing, otherwise, say a random thing
        if edata.manager then
            startManagement(edata)
        else
            -- start a one on discussion with this crewmate
            startDiscussion(edata)
        end
    elseif n == 2 then -- praise
        -- some responses specific to the praise
        local responses = {
            _("Thanks!"),
            _("Yeah, okay."),
            fmt.f(_("Okay, {name}."), {name = player.name()}),
            fmt.f(_("Aright, {name}. Thanks for the feedback."), {name = player.name()}),
            _("Thank you.")
        }
        -- default responses
        responses = join_tables(responses, edata.conversation.default_participation)
        -- add some interesting responses
        if edata.conversation.sentiment then
            table.insert(responses, edata.conversation.sentiment)
        end
        if edata.conversation.sentiments then
            responses = join_tables(responses, edata.conversation.sentiments)
        end
        -- reply to the captain
        vntk.msg(name_label, pick_one(responses))

        -- adjust the sentiment
        edata.conversation.sentiment =
            fmt.f(
            pick_one(edata.conversation.good_talker),
            {name = player.name(), article_subject = _("the captain"), article_object = _("the captain"), firstname = player.name() }
        )

        -- adjust the chatter trying to increase it
        edata.chatter = math.max(edata.chatter, math.min(0.66, edata.chatter + 0.1 + 0.1 * rnd.threesigma()))
    elseif n == 3 then -- criticize
        -- responses specific to the criticism
        local responses = {
            _("Okay captain."),
            _("Yeah, okay."),
            fmt.f(_("Okay, {name}. I'm sorry to hear that."), {name = player.name()}),
            fmt.f(_("Aright, {name}. Thanks for the feedback."), {name = player.name()}),
            _("Sorry."),
            _("I'll try and do better next time."),
            _("I'll try and learn from the others."),
            _("I'm sorry sir."),
            _("I'll take a step back."),
            _("Whatever you say sir."),
            _("Oh, man. Good to know, I guess.")
        }
        -- default responses
        responses = join_tables(responses, edata.conversation.default_participation)
        -- maybe let's just talk about violence
        if edata.conversation.topics_liked.violence then
            responses = join_tables(responses, edata.conversation.topics_liked.violence)
        end
        -- reply to the captain
        vntk.msg(name_label, pick_one(responses))

        -- adjust the sentiment
        edata.conversation.sentiment =
            fmt.f(
            pick_one(edata.conversation.bad_talker),
            FAKE_CAPTAIN
        )

        -- adjust the chatter trying to push it down
        edata.chatter = math.min(edata.chatter, math.max(0.16, edata.chatter - 0.1 - 0.1 * rnd.threesigma()))
    elseif n == 4 and vntk.yesno("", fmt.f(_("Are you sure you want to fire {name}? This cannot be undone."), edata)) then
        -- reply to the captain or storm off, depending on whether we know violence, have friends, or neither
        if edata.conversation.topics_liked.violence then
            -- talk about violence if possible
            vntk.msg(name_label, pick_one(edata.conversation.topics_liked.violence))
        elseif edata.conversation.topics_liked.friend then
            -- remisince about a friend one last time before the captain
            vntk.msg(name_label, pick_one(edata.conversation.topics_liked.friend))
        end
		
		local reason = fmt.f(_("You fired '{name}'."), edata)
		terminate_crew(edata, reason)

    end
end

-- Approaching hired pilot at the bar
function approachCompanion(npc_id)
    local edata = npcs[npc_id]
    if edata == nil then
        evt.npcRm(npc_id)
        return
    end

    crewmate_barConversation(edata, npc_id)
end

-- TODO: approach first officer function

-- Approaching a completely generic crewmate
function approachGenericCrewmate(npc_id)
    local pdata = npcs[npc_id]
    if pdata == nil then
        evt.npcRm(npc_id)
        return
    end

    if not vntk.yesno("", getOfferText(pdata)) then
        return -- Player rejected offer
    end

    if pdata.deposit and pdata.deposit > player.credits() then
        vntk.msg(_("Insufficient funds"), _("You don't have enough credits to pay for this person's deposit."))
        return
    end

    -- check if this ship has this kind of manager
    if pdata.manager then
        for _i, pers in ipairs(mem.companions) do
            if pers.manager and pers.manager.type == pdata.manager.type then
                -- TODO : generate a rejection
                vntk.msg(
                    _("No thanks"),
                    _("You look like you're pretty well staffed. I'll find another ship that needs me.")
                )
                return
            end
        end
    end
	
	if pdata.shuttle then
		for _i, pers in ipairs(mem.companions) do
            if pers.shuttle then
                -- TODO : generate a rejection
                vntk.msg(
                    _("No thanks"),
                    _("It looks like you already have someone else calling dibs on any spare space in your docking bays. I don't want to step on anyone's feet.")
                )
                return
            end
        end
		-- check if the ship has a shuttle that we can use
		-- otherwise, we would have brought our own with us
		if mem.ship_interior.shuttle then
			pdata.shuttle = mem.ship_interior.shuttle
		end
	end

	-- check if this crew member has a typetitle that is limited
	local count = 0
	for ttt, lll in pairs(mem.crew_limits) do
		
		if ttt == pdata.typetitle then
			for _i, crewmate in ipairs(mem.companions) do
				if crewmate.typetitle == pdata.typetitle then
					-- check if it's the same skill of same type (not allowed unless we are "Crew")
					if crewmate.skill == pdata.skill and crewmate.typetitle ~= _("Crew") then
						vntk.msg(
						    _("No thanks"),
							fmt.f(_("How many {skill} {typetitle}s do you think you need? If you think you need more than just the one, then I don't think I want to be anywhere near your ship."), pdata )
						)
						return
					end
					count = count + 1
					-- check if we reached the limit of types
					if lll <= 0 then -- we aren't allowed to have any of this type
					vntk.msg(
						    _("No thanks"),
							fmt.f(_("It doesn't really look like you have any use for a {typetitle}. I don't want to be dead weight, I'll find another ship."), pdata )
						)
						return
					end
					if count >= lll then
						pdata.limit = lll
						vntk.msg(
						    _("No thanks"),
							fmt.f(_("How many {typetitle}s do you think you need? If you think you need more than {limit}, then I don't think I want to be anywhere near your ship."), pdata )
						)
						return
					end
				end
			end
		end
	end


    local i = #mem.companions + 1
    if i * 1.2 >= player.pilot():stats()["crew"] and pdata.typetitle == "Crew" then
        local params = {
            ["start"] = pick_one({
                _("Oh hey,"),
                _("Well,"),
                _("Actually, upon closer inspection")
            }),
            ["reason"] = pick_one({
                _("it kind of looks like your ship has too much crew on it already."),
                _("I don't know if you have the facilities for another crew member."),
                _("I think it would be better if I joined a different ship.")
            }),
            ["excuse"] = pick_one({
                _("I can tell you're only trying to be polite, but there's obviously no room for me on your ship."),
                _("I'm sure I'll find something else."),
                _("It's not you or your ship, I just can't work with so many people.")
            }),
            ["bye"] = pick_one({
                _("Later."),
                _("I'll see you around."),
                _("Catch you later."),
                _("Sorry.")
            })
        }
        vntk.msg(_("No thanks"), fmt.f(_("{start} {reason} {excuse} {bye}"), params))
        return
    end
		
    if pdata.deposit then
        player.pay(-pdata.deposit, true)
		playMoney()
    end
	
	vntk.msg(fmt.f(_("{typetitle} hired"), pdata), _("You pay the worker, who heads towards your ship to begin a new life."))
    mem.companions[i] = pdata
    evt.npcRm(npc_id)
    npcs[npc_id] = nil
    local id =
        evt.npcAdd(
        "approachCompanion",
        pdata.name,
        pdata.portrait,
        fmt.f(_("{name} is a member of your crew."), pdata),
        9
    )
    npcs[id] = pdata
    evt.save(true)

    local edata = mem.companions[i]
    shiplog.create(logidstr, _("Ship Companions"), _("Ship Companions"))
    shiplog.append(logidstr, fmt.f(_("You hired '{name}' to join your crew."), edata))
	-- hiring a crew member usually means a little bit of a mess initially
	mem.ship_interior.dirt = mem.ship_interior.dirt + edata.xp * edata.satisfaction * 0.1
end

-- Approaching unhired companion escort at the bar
function approachEscortCompanion(npc_id)
    local pdata = npcs[npc_id]
    if pdata == nil then
        evt.npcRm(npc_id)
        return
    end

    if not vntk.yesno("", getOfferText(pdata)) then
        return -- Player rejected offer
    end

    if pdata.deposit and pdata.deposit > player.credits() then
        vntk.msg(_("Insufficient funds"), _("You don't have enough credits to pay for this person's deposit."))
        return
    end

    -- this can be generalized to an attribute like unique
    -- check if this ship has an escort
    for _i, pers in ipairs(mem.companions) do
        if pers.skill == "Escort" then
            -- TODO : generate a rejection
            vntk.msg(
                _("No thanks"),
                _(
                    "You already have an escort on your ship. I need my space. I need my privacy. I need my customers. I'll find another ship."
                )
            )
            return
        end
    end

    if pdata.deposit then
        player.pay(-pdata.deposit, true)
    end
	
    local i = #mem.companions + 1
    mem.companions[i] = pdata
    evt.npcRm(npc_id)
    npcs[npc_id] = nil
    local id =
        evt.npcAdd(
        "approachCompanion",
        pdata.name,
        pdata.portrait,
        fmt.f(_("{name} lives on your ship with the crew."), pdata),
        8
    )
    npcs[id] = pdata
    evt.save(true)

    local edata = mem.companions[i]
    shiplog.create(logidstr, _("Ship Companions"), _("Ship Companions"))
    shiplog.append(logidstr, fmt.f(_("You allowed '{name}' to live on your ship with your crew."), edata))
	-- the companion likes luxury and will do a little bit of initial cleaning
	mem.ship_interior.dirt = math.max(0, mem.ship_interior.dirt - edata.xp * edata.satisfaction - player.pilot():ship():size())
end

-- Approaching unhired demo man at the bar
function approachDemolitionMan(npc_id)
    local pdata = npcs[npc_id]
    if pdata == nil then
        evt.npcRm(npc_id)
        return
    end

    if not vntk.yesno("", getOfferText(pdata)) then
        return -- Player rejected offer
    end

    if pdata.deposit and pdata.deposit > player.credits() then
        vntk.msg(_("Insufficient funds"), _("You don't have enough credits to pay for this person's deposit."))
        return
    end

    for _i, pers in ipairs(mem.companions) do
        if pers.skill == _("Demolition") then
            -- TODO : generate a rejection
            vntk.msg(
                _("No thanks"),
                _(
                    "There's no room for two pyromaniacs on one ship. I'll save you the trouble and get out of your hair."
                )
            )
            evt.npcRm(npc_id)
            return
        end
    end

	-- check if this crew member has a typetitle that is limited
	local count = 0
	for _i, crewmate in ipairs(mem.companions) do
		if crewmate.typetitle == "Engineer" then
			count = count + 1
			if count >= 2 then
				pdata.limit = 2
				vntk.msg(
					_("No thanks"),
					fmt.f(_("How many {typetitle}s do you think you need? If you think you need more than {limit}, then I don't think I want to be anywhere near your ship."), pdata )
				)
				return
			end
		end
	end
	
    if pdata.deposit then
        player.pay(-pdata.deposit, true)
    end

    local i = #mem.companions + 1
    mem.companions[i] = pdata
    evt.npcRm(npc_id)
    npcs[npc_id] = nil
    local id = evt.npcAdd("approachCompanion", pdata.name, pdata.portrait, _("This is one of your crewmates."), 8)
    npcs[id] = pdata
    evt.save(true)

    local edata = mem.companions[i]
    shiplog.create(logidstr, _("Ship Companions"), _("Ship Companions"))
    shiplog.append(logidstr, fmt.f(_("You hired '{name}' to join your crew."), edata))
	-- hiring this guy in this condition (the special hiring function, not generic engineer one)
	-- means you hire him while he's really dirty, so he contaminates the ship
	mem.ship_interior.dirt = mem.ship_interior.dirt + edata.xp * edata.satisfaction + player.pilot():ship():size()
end

-- the player lands on a world with a companion escort on board
function escort_landing(speaker)
    -- used like "why are we on this pick(<descriptors>) anyway"
    local bad_tags = {
        ["garbage"] = {"dump", "literal garbage dump", "floating space turd", "scrapheap", "landfill"},
        ["mining"] = {"mining world", "low-brow planet", "terrible rock", "forsaken place", "labour camp"},
        ["poor"] = {"destitute world", "forsaken ground", "filthy rock", "scrapheap", "misery farm", "labour camp"}
    }
    -- used like "<tag> <descriptor> can actually be quite lucrative"
    local neutral_tags = {
        ["agriculture"] = "planets",
        ["criminal"] = "worlds",
        ["government"] = "facilities",
        ["industrial"] = "executives and their children",
        ["prison"] = "workers",
        ["research"] = "establishments"
    }
    -- TODO: these are special
    local good_tags = {
        ["medical"] = {
            "worlds",
            "facilities",
            "planets",
            "institutions",
            "complexes"
        },
        ["military"] = {
            "worlds",
            "facilities",
            "outposts",
            "organizations",
            "complexes"
        },
		-- I thought there would be some good rural words, but I keep seeing really bad ones
 --     ["rural"] = {"worlds", "planets", "moons", "paradises", "gardens"},
        ["shipbuilding"] = {"facilities", "locations"},
        ["urban"] = {"cities", "megaplexes", "megacities", "suburbs", "clubs"},
        ["trade"] = {"hubs", "kernels", "stops"},
        ["rich"] = {"places", "worlds", "planets", "people", "geriatrics", "octogenarians", "centenarians"}
    }

    -- we probably didn't get our argument, so let's pick out our escort from the crew
    if not speaker then
        for _i, pers in ipairs(mem.companions) do
            if pers.skill == "Escort" then
                speaker = pers
            end
        end
    end

    if not speaker then
        print("error no speaker")
        return
    end

    -- see if we get some jobs here
    local world_score = -0.1
    local tags = spob.cur():tags()
    local good_choices = {
        _("I always say that {tag} {place} are good for business."),
        _("We should come to {place} like these more often."),
        _("We should visit {place} like these often."),
        _("Those {tag} {place} are good for business."),
        _("I like traveling to {tag} {place}."),
        _("The {tag} {place} here were quite generous."),
        _("I had a good time here as usual."),
        _("I met one of my regulars. You'll never know the details."),
        _("Even a {made_up} would like this place.")
    }
    local neutral_choices = {
        _("I think that {tag} {place} aren't the worst for business."),
        _("The business is usually good when it comes to {tag} {place}."),
        _("We should stop at {place} like these every once in a while."),
        _("We should visit {place} like this one more often, but not too often."),
        _("Those {tag} {place} are alright for business."),
        _("I like traveling to {tag} {place}."),
        _("This was a nice break."),
        _("The {tag} {place} here were decent."),
        _("I had an unexpected good time."),
        _("I had a surprisingly good time."),
        _("I had a surprisingly relaxed stay."),
        _("I lucked into one of my regulars. You'll never guess which one."),
        fmt.f(_("I saw a {made_up} for what I think was the first time."), {made_up = getMadeUpName()}),
        fmt.f(_("Was that a {made_up}?"), {made_up = getMadeUpName()}),
        fmt.f(_("Was that a {made_up} back there?"), {made_up = getMadeUpName()}),
        fmt.f(
            _("I didn't want to ask in front of that {made_up}, but do you think it's real?"),
            {made_up = getMadeUpName()}
        )
		}
	local relevant_message
    -- check good tags
    for tag, thing_choices in pairs(good_tags) do
        if tags[tag] then
            local thing = pick_one(thing_choices)
            world_score = world_score + 3
            if rnd.rnd() > 0.33 then
                relevant_message = fmt.f(pick_one(good_choices), {tag = tag, place = thing, made_up = getMadeUpName()})
            end
        end
    end

    -- check neutral tags
    for tag, thing in pairs(neutral_tags) do
        if tags[tag] then
            world_score = world_score + 1
            if not relevant_message and rnd.rnd() > 0.67 then
                relevant_message =
                    fmt.f(pick_one(neutral_choices), {tag = tag, place = thing, made_up = getMadeUpName()})
            end
        end
    end

    -- check the dumps (make sure to check if the world is poor, because there are
	-- e.g. poor rural worlds like Waterhole's Moon)
    if world_score < 0 or tags.poor then
        for tag, choices in pairs(bad_tags) do
            if tags[tag] then
                world_score = -5
                relevant_message = fmt.f("What are we doing on this {place}?", {place = pick_one(choices)})
                -- create an unpleasant memory
                create_memory(
                    speaker,
                    "work",
                    {
                        system = system.cur(),
                        planet = spob.cur()
                    }
                )
            end
        end
    end

    local payoff = 0
    if world_score > 0 then
        for i = 0, world_score do
            local job_pay = world_score * 10e3 + world_score * 5e3 * rnd.threesigma()
            if rnd.rnd(0, 1) == 1 then -- we got the job
                payoff = payoff + job_pay
            elseif rnd.rnd() < (math.min(50, speaker.xp) * speaker.satisfaction / 1000) then
                -- we somehow got the job with a bonus
                payoff = payoff + job_pay + 100e3
            end
        end
        -- create a work memory
        create_memory(
            speaker,
            "work",
            {
                credits = fmt.credits(payoff),
                system = system.cur(),
                planet = spob.cur()
            }
        )
    end

    -- raise or lower satisfaction based on world score
    speaker.satisfaction = math.min(10, math.max(-10, speaker.satisfaction + world_score))

    if payoff > speaker.threshold then -- we are happy
        -- raise the satisfaction based on payoff
        speaker.satisfaction = math.min(10, speaker.satisfaction + math.floor(payoff / speaker.threshold))

        -- set our last message to happy regardless of true satisfaction
        -- if we are unhappy, maybe mention that this was a turnaround TODO
        speaker.conversation.sentiment = relevant_message
    elseif relevant_message then -- we are unhappy
        -- set our last message to dissatisfied regardless of true satisfaction
        speaker.conversation.sentiment = relevant_message
        if speaker.satisfaction < 0 then
            -- TODO: pick from choices
            speaker.conversation.sentiment = relevant_message .. " " .. pick_one(speaker.conversation.special["worry"])
        end
    end
end

-- should return the commodities that the player can sell
local function get_commodities_to_sell( cargo_limit , where )
	where = where or system.cur()
	local pp = player.pilot()
	local sellers = {}
	local total_cargo = 0
	for k,v in ipairs( pp:cargoList() ) do
		-- ignore mission cargo
		print(
		fmt.f("found cargo {q} x {name}", v),
		tostring(not v.m),
		tostring(commodity.canSell( v.name, where )),
		tostring(v.name ~= "Food")
		)
		if
			not v.m
			and commodity.canSell( v.name, where )
			and v.name ~= "Food" -- don't sell food, crew wants it
		then
			print(fmt.f("add cargo {q}x{name}", v))
			total_cargo = total_cargo + v.q
			sellers[v.name] = v.q
		end
	end
	
	if total_cargo > cargo_limit then
		-- Simulate cargo removal
		local cl = pp:cargoList()
		local space_needed = total_cargo - cargo_limit
		local removals = {}
		for k,v in ipairs( cl ) do
			if not v.m then
				v.p = commodity.get(v.name):priceAt(where)
			end
		end
		while space_needed > 0 do
			-- Find cheapest
			local cn, cq, ck
			local cp = math.huge
			for k,v in pairs( cl ) do
				if not v.m then
					if v.p < cp then
						ck = k
						cn = v.name
						cp = v.p
						cq = v.q
					end
				end
			end
			-- found cheapest
			cq = math.min( space_needed, cq )
			removals[cn] = cq
			cl[ck].q = cl[ck].q - cq
			if cl[ck].q <= 0 then
				cl[ck] = nil
			end
			space_needed = space_needed - cq
		end
		-- don't sell these
		for n, q in pairs(removals) do
			local stock = sellers[n] or 0
			stock = math.max(0, stock - q)
			print(fmt.f("Removing {q} x {n}, remaining is {amt}", {q=q, n=n, amt=stock} ))
			if stock > 0 then
				sellers[n] = stock
			else
				sellers[n] = nil
			end
		end
	end
		
	return sellers
end

-- makes the shuttler return to the mothership
local function mission_return_to_player( args )
	args.crewsheet.pilot:control(true)
	args.crewsheet.pilot:follow(player.pilot(), true)
	
	local start_check_time = 10 * args.crewsheet.pilot:ship():size()
	
	hook.timer(20, "shuttle_check_dock_distance", args)
end

-- destination must be a spob
local function mission_travel_to_spob( args, destination )
	-- makes the pilot fly to where it needs to go
	args.crewsheet.pilot:control(true)
	-- minor sanity check here
	if not destination then
		return mission_return_to_player( args )
	end
	local next_system = system.get( destination )
	if next_system == system.cur() then
		args.crewsheet.pilot:land(destination)
		return
	end
	print("UNIMPLEMENTED: Fake (simulated) away mission to another system")
end

-- player orders shuttlepilot to sell off some cargo in the current system
-- like smuggler, but needs a shuttle from an officer
local function sell_cargo_local( args )
	local shuttle = args.shuttle
	local crewman = args.crewsheet
	local active_pilot = args.crewsheet.pilot

	local will_sell = {}
	local profit = 0
	local space = crewman.pilot:cargoFree()

	-- find the nearest place that will buy some cargo
	local chosen_spob = nil
	for _i, sspob in ipairs (system.cur():spobs()) do
		if sspob:services().commodity then
			if not chosen_spob then
				chosen_spob = sspob
			elseif 
				vec2.dist2( player.pilot():pos(), chosen_spob:pos() )
				> ( vec2.dist2( player.pilot():pos(), sspob:pos() ) )
			then
				chosen_spob = sspob
			end
		end
	end

	local to_sell = get_commodities_to_sell(space, chosen_spob)
	
	-- remove the commodities from the players cargo hold
	-- and put them in the new ship
	for name, qty in pairs(to_sell) do
		local cc = commodity.get(name)
		local nn = player.fleetCargoRm(cc, qty)
		active_pilot:cargoAdd(cc, nn)
		profit = profit + qty * cc:priceAt(chosen_spob)
		print(fmt.f("gonna go sell {qty} x {name} for {price}, total at {total}", { qty=qty, name=name, price=cc:priceAt(chosen_spob), total=profit } ) )
	end

	hook.pilot(active_pilot, "land", "mission_away_landed", { profit = profit, crewsheet = crewman, shuttle = shuttle.ship, mission = args.mission })
	hook.pilot(active_pilot, "death", "terminate_crew_death", {crewman, _("Your pilot was lost in combat.") })
	active_pilot:setNoClear(true)
	mission_travel_to_spob(args, chosen_spob)
	message = pick_one(crewman.conversation.special.going)
	active_pilot:comm(message)
	if space == 0 then
		-- the pilot differs from the smuggler as it can be promoted all the way to lieutenant
		-- so a shuttle pilot can actually pull their own weight on a bayless ship
		crewman.xp = math.min(100, crewman.xp + 0.1)
	end
	der.sfx.unboard:play()
end

local function buy_cargo_local( args )
	local shuttle = args.shuttle
	local crewman = args.crewsheet
	local active_pilot = crewman.pilot

	-- our mission directive is to buy, but we need to know what to buy from where
	local want = args.mission.target
	local space = crewman.pilot:cargoFree()
	-- check if this system can sell us any of the want
	local chosen_spob = nil
	for _i, bspob in ipairs (system.cur():spobs()) do	
		local comms = bspob:commoditiesSold()
		for _j, cc in ipairs(comms) do
			-- this is sold here
			if string.find(cc:name():lower(), want:lower()) then
				if not chosen_spob then
					chosen_spob = bspob
				elseif
					vec2.dist2( player.pilot():pos(), chosen_spob:pos() )
					> ( vec2.dist2( player.pilot():pos(), bspob:pos() ) )
				then
					-- this one is closer
					chosen_spob = bspob
				end
			end
		end
	end

	hook.pilot(active_pilot, "land", "mission_away_landed", { profit=-crewman.deposit, crewsheet=crewman, shuttle = shuttle.ship , mission = args.mission })
	hook.pilot(active_pilot, "death", "terminate_crew_death", {crewman, _("Your pilot was lost in combat.") })
	active_pilot:setNoClear(true)
	mission_travel_to_spob(args, chosen_spob)
	message = pick_one(crewman.conversation.special.going)
	active_pilot:comm(message)
	if space == 0 then
		-- the pilot differs from the smuggler as it can be promoted all the way to lieutenant
		-- so a shuttle pilot could actually pull their own weight on a bayless ship
		crewman.xp = math.min(100, crewman.xp + 0.1)
	end
	der.sfx.unboard:play()
end

-- wrapper for launching an away mission
function away_mission( args )
	local shuttle = args.shuttle
	local crewman = args.crewsheet
	local mission = args.mission or { mission = "Trade Mission", ship = shuttle.ship:name(), directive = "sell" }

	if not shuttle.ship or shuttle.out then
		print("away_mission: no shuttle to use " .. tostring(shuttle) .. " : " .. tostring(shuttle.ship) .. " - " .. tostring(shuttle_out))
		return -- no shuttle to use, can happen because player ordered some mission twice or whatever
	end
	
	-- pre-flight safety check
	if player.isLanded() then
		return
	end
	
	-- we are using this shuttle
	mem.ship_interior.shuttle = shuttle
	
	-- create the ship
	crewman.pilot = pilot.add(shuttle.ship, crewman.faction, player.pilot():pos(), crewman.name, {ai="dummy"})
	player.pay(-crewman.deposit)
	crewman.pilot:credits(-crewman.pilot:credits() + crewman.deposit) -- holds deposit
	crewman.pilot:setHilight(true)
	if crewman.manager and crewman.manager.outfits then
		crewman.pilot:outfitRm("all")
		for _j, o in ipairs(crewman.manager.outfits) do
			crewman.pilot:outfitAdd(o, 1 , true)
		end
	end
	shuttle.out = true
	crewman.away = mission
	-- ready for the mission
	if mission.directive == "sell" then
		return sell_cargo_local( args )
	elseif mission.directive == "buy" and mission.target then
		return buy_cargo_local( args )
	end
	
	print("UNKNOWN MISSION", mission)
	print(mission.mission, mission.ship, mission.directive)
	
end

-- player opens the cargo bay, the smuggler is pressured to smuggle but will also restock fruit
function smuggle_cargo(speaker)
	if speaker.shuttle.ship or speaker.shuttle.out  then
		return -- we're not home
	end
	
	-- check if WE are docked
	if player.isLanded() then
		-- currently nothing for smuggler to do unless in space
		return
	end
	
	-- check if the smuggler has a bay to use

	local bay_strength = mem.ship_interior.bay_strength
	print("bay strength", bay_strength)
	
	if bay_strength == 0 then return end -- no bay to use, nothing for smuggler to do
	
	--[[
	-- if we have a bay, calculate our bonuses based on our cargo bay workers
	-- since we want to increase satisfaction and xp for active workers we do
	-- the recalculation instead of using takeoff's calculation (we are on a UI screen anyway)
	-- this CAN be abused by the player by repeatedly opening the cargo screen to
	-- increase the smuggler and cargo worker satisfaction and xp, but honestly I
	-- think that the player can be rewarded because they wouldn't know that they're
	-- getting all these free bonuses from this anyway unless they read the source
	-- in which case they know what they're doing anyway
	--]]
	for ii, worker in ipairs(mem.companions) do
		if ii <= player.pilot():stats()["crew"] then
			if worker.skill == "Cargo Bay" then
				bay_strength = bay_strength + worker.xp * 0.1
				worker.xp = worker.xp + 0.01
				speaker.satisfaction =  speaker.satisfaction + 0.01
			end
		end
	end
	
	-- decide the ship now because we'll need the cargo size
	local bay_ship = "Llama" -- default with no strength
	local space = 15
	if bay_strength > 8 then -- a carrier
		bay_ship = "Mule"
		space = 230
	elseif bay_strength > 6 then -- perhaps a cruiser or freighter
		bay_ship = "Rhino"
		space = 150
	elseif bay_strength > 4 then
		bay_ship = "Koala"
		space = 50
	elseif bay_strength == 2 then
		bay_ship = "Quicksilver"
		space = 30
	end
	
	speaker.shuttle.ship = bay_ship
	
	local will_sell = {}
	local profit = 0
	-- check if this system can buy any of our cargo
	local chosen_spob = nil
	for _i, spob in ipairs (system.cur():spobs()) do
		if not chosen_spob then
			local comms = spob:commoditiesSold()
			for _j, cc in ipairs(comms) do
				local owned = player.fleetCargoOwned(cc)
				-- quick check to not sell food
				if cc:name() == "Food" then owned = 0 end
				if owned > 0 and not chosen_spob then
					chosen_spob = spob
				end
				if owned > 0 and space > 0 then
					-- we can sell this commodity here!
					if owned > space then
						table.insert(will_sell, {cc, space})
						profit = profit + space * cc:priceAt(chosen_spob)
						space = 0
					elseif owned < space then
						table.insert(will_sell, {cc, owned})
						profit = profit + owned * cc:priceAt(chosen_spob)
						space = space - owned
					end
				end
			end
		end
	end
	
	-- TODO: populate choices and use a proper vn discussion and include the part about the fruit
--	print(profit, space, chosen_spob)
	local choices = {}
	
	-- only allow distribution of fruit if smuggler doesn't really want to smuggle
	if chosen_spob and space > 5 and profit < 4e3 or #will_sell == 0 then
		speaker.shuttle.out = true
		speaker.away = { mission = "Smuggling Mission", ship = bay_ship, directive = "sell" }
		-- if we don't have any fruit, see if we can convert a ton of food
		if not speaker.manager.special and player.pilot():cargoHas("Food") then
			player.pilot():cargoRm("Food", 1)
			crate.fruit = getRandomFruit()
			speaker.manager.special = {}
			speaker.manager.special.feedback = pick_one(speaker.conversation.default_participation)
			speaker.manager.special.choices = {
			{ _("Distribute among crew"), "special_yes" },
			{ fmt.f(_("Discard {fruit}"), crate ), "discard_special" },
			{ _("Nothing"), "end" }
			}
			speaker.manager.special.price = math.max(200, 100 * #mem.companions - 50 * speaker.bonus)
						local crate = {}
			-- 25% chance of converting the food into water instead of consuming it all
			if rnd.rnd(0,4) == 0 then
				crate.comm = "Water"
			end
			crate.origin = system.cur()
			speaker.manager.special.crate = crate
			speaker.manager.special.label = fmt.f(_("Restock {fruit}s"), crate )
			speaker.manager.special.message = fmt.f(_("I can restock the {fruit}s from what food we got here in the cargo bay. Should I?"), crate)
		end
		-- if we have any available fruit to restock, present the option
		if not speaker.manager.special then
			
			-- no special crates or anything and
			-- not enough commodities to fill the smuggler,
			-- not worth going, don't even bother the player
			return
		end
	end
	-- we have everything we need, talk to player
	
	local message = fmt.f(_("Welcome to the cargo bay {name}."), {name = player.name() })

	vn.clear()
	vn.scene()
	vn.transition()
	local character = vn.newCharacter ( fmt.f("{typetitle} {name}", speaker), {image = speaker.vncharacter } )
	
	if #will_sell > 0 and profit > 2e3 and (space < 5 or profit > 10e3) then
		choices = join_tables(
			{ { _("Yes"), "go_smuggle"} },
			choices)
		message = fmt.f(_("Hey captain! I can smuggle some of these commodities to a nearby planet and sell at least {b} tons of {a} if you'd like for {profit}. It would spare you the effort of doing it yourself."), {a=will_sell[1][1],b=will_sell[1][2], profit=fmt.credits(profit)} )
	elseif speaker.manager.special  then
		message = message .. " " .. speaker.manager.special.message
		choices = join_tables(choices, {
			{speaker.manager.special.label, "special_yes"}
		})
	end
	choices = join_tables(choices, {
		{_("Nevermind"), "cancel"}
	})
	
	character(message)
	vn.menu(choices)
	
	if speaker.manager.special then
		vn.label("special_yes")
		character(speaker.manager.special.feedback)
		vn.func( function() 
			doSpecialManagementFunc(speaker)
		end )
			
		vn.done()
	end
	vn.label("go_smuggle")
	vn.func( function () 
		-- player said yes
		-- create the smuggling ship
		local smuggler = pilot.add(bay_ship, "Trader", player.pilot():pos(), speaker.name, {ai="dummy"})
		smuggler:credits(-smuggler:credits()) -- remove any credits
		
		-- remove the commodities from the players cargo hold
		-- and put them in the new ship
		for _, pair in ipairs(will_sell) do
			local cc = pair[1]
			local qty = pair[2]
			local nn = player.fleetCargoRm(cc, qty)
			smuggler:cargoAdd(cc, nn)
		end
		
		smuggler:control(true)
		smuggler:land(chosen_spob)
		hook.pilot(smuggler, "land", "mission_away_landed", { profit = profit, crewsheet = speaker, shuttle = speaker.shuttle.ship, mission = speaker.away })
		hook.pilot(smuggler, "death", "terminate_crew_death", {speaker, _("Your smuggler was lost in combat.") })
		message = pick_one(speaker.conversation.special.going)
		smuggler:comm(message)
		if space == 0 then
			speaker.xp = math.min(10, speaker.xp + 0.1)
		end
		der.sfx.unboard:play()
	end )
	vn.done()
	vn.label("cancel")
	vn.func( function() speaker.shuttle.out = nil end)
	vn.label("end")
	vn.done()
	vn.run()
	
	
end

-- do what we need to do while landed during an away mission
function mission_away_landed( old_shuttler, planet, args )
	-- boilerplate
	old_shuttler:hookClear()
	args.planet = planet
	local return_time = math.max(16, (111 - args.crewsheet.xp) - args.crewsheet.satisfaction)
	hook.timer(return_time, "mission_away_return", args)
	
	-- we are good shuttle pilots and we'll record the commodity prices while we are here
	planet:recordCommodityPriceAtTime(time.get())

end
-- smuggler lands and must come back
function mission_away_return( args )
	-- great, now the shuttler needs to get back!
	local shuttler = pilot.add(args.shuttle, "Trader", args.planet, args.crewsheet.name, {ai="dummy"})
	shuttler:cargoRm("all")
	args.crewsheet.pilot = shuttler
	
	shuttler:setHilight(true)
	if args.crewsheet.manager and args.crewsheet.manager.outfits then
		shuttler:outfitRm("all")
		shuttler:outfitRm("cores")
		for _j, o in ipairs(args.crewsheet.manager.outfits) do
			local ret = shuttler:outfitAdd(o, 1 , true)
		end
	end
	
	-- before we actually "take off", we need to add any cargo that we were supposed to buy while landed
	-- do the assigned mission
	if args.mission.directive == "buy" then
		-- we can't leave without filling up our cargo!
		local free_space = shuttler:cargoFree()
		local commo = parseCommodity(args.mission.target)
		local unit_price = commo:priceAt(args.planet)
		local total_price = math.ceil(unit_price * free_space)
		print( fmt.f("Buying {q} units at {p} each for {t} total.", { q = free_space, p = unit_price, t = total_price } ) )
		-- completely fill the cargo!
		shuttler:cargoAdd( commo , free_space )
		args.profit = -total_price
	end

	shuttler:credits(-shuttler:credits() + args.crewsheet.deposit) -- holds deposit
	shuttler:credits(args.profit) -- add the profit (or cost)

	mission_return_to_player(args)
	
	local aimem = shuttler:memory()
	aimem.radius = 5
	local message = pick_one(args.crewsheet.conversation.special.coming)
	shuttler:comm(message)

	
	-- now as a special bonus, the shuttler has fruit to restock with from the trip
	-- and a random commodity that the crew might need
	local crate = {}
	crate.fruit = getRandomFruit()
	crate.comm = pick_one({"Water", "Medicine", "Food"})
	crate.origin = system.cur()
	
	args.crewsheet.manager.special = {}
	args.crewsheet.manager.special.label = fmt.f(_("Restock {fruit}s"), crate )
	args.crewsheet.manager.special.message = fmt.f(_("I picked up crate of {fruit}s and some {comm} back in {origin}. What do you want me to do with the all the {fruit}s?"), crate)
	args.crewsheet.manager.special.feedback = pick_one(args.crewsheet.conversation.default_participation)
	args.crewsheet.manager.special.choices = {
		{ _("Distribute among crew"), "special_yes" },
		{ _("Nothing"), "end" }
	}
	args.crewsheet.manager.special.crate = crate
	args.crewsheet.manager.special.price = 0
end

-- checks if it's alive and exists (otherwise player loses a pilot or smuggler)
-- checks if the smuggler or shuttle pilot can dock
-- if shuttle is too far, check again later
-- needs args { shuttler, crewsheet, profit }
function shuttle_check_dock_distance( args )
	local shuttler = args.crewsheet.pilot
	if not shuttler or not shuttler:exists() then
		-- player loses a shuttle pilot and the insurance deposit
		terminate_crew(
			args.crewsheet,
			fmt.f(
				_("{skill} {name} was lost -- never returned after losing communication during a cargo mission.", args.crewsheet)
				) ..
			fmt.f(" The insurance deposit of {deposit} was written off, as was the {shuttle}.", { deposit = fmt.credits(args.crewsheet.deposit), shuttle = args.shuttle.ship })
			)
		return
	end
	-- we're going to use square2, so we need to boost the base, we'll just double xp amount, docking range bonus is a nice bonus
	local shuttler_docking_distance = 2 * args.crewsheet.xp + args.crewsheet.satisfaction + 35 + args.crewsheet.bonus
	if vec2.dist2(player.pilot():pos(), shuttler:pos()) < shuttler_docking_distance * shuttler_docking_distance then
		shuttler:comm(pick_one(args.crewsheet.conversation.special.arrived))
		-- SUCCESS, we docked, pay the player the deposit back and any profit
		player.pay(args.profit + args.crewsheet.deposit)
		local pay = _("received")
		local from = _("from")
		if args.profit < 0 then
			pay = _("paid")
			from = _("to")
		end
		shiplog.append(
            logidstr,
            fmt.f(
                _("You {pay} {credits} {from} {skill} {name} after a successful mission."),
                {
					pay = pay,
					from = from,
                    credits = fmt.credits(math.abs(args.profit)),
					skill = args.crewsheet.skill,
					name = args.crewsheet.name,
                }
            )
        )
		-- transfer any new cargo over
		for _i, cargo in ipairs(shuttler:cargoList()) do
			player.pilot():cargoAdd( cargo.name, cargo.q )
		end
		
		shuttler:hookClear()
		shuttler:rm()
		-- if the officer went, he needs his button back now
		if string.find(args.crewsheet.skill, _("Officer")) then
			commander_button(args.crewsheet)
			-- I'm paranoid, ok? it was our shuttle and it was registered as the "ship shuttle"
			mem.ship_interior.shuttle.out = nil
			args.crewsheet.shuttle.out = nil
		-- if this was our shuttle, it's no longer out (shuttler transports)
		elseif args.crewsheet.shuttle then
			args.crewsheet.shuttle.out = nil
		else	-- it must have been an officer's shuttle, register it as docked
			mem.ship_interior.shuttle.out = nil
		end

		der.sfx.board:play()
		args.crewsheet.pilot = nil
		args.crewsheet.away = nil
		-- docking a shuttle after a voyage increases dirt
		mem.ship_interior.dirt = mem.ship_interior.dirt + mem.ship_interior.bay_strength * player.pilot():ship():size() * 0.1
		return
	end

	shuttler:comm(pick_one(args.crewsheet.conversation.special.coming))
	-- if we reached this point, we need to hook another timer
	hook.timer(10, "shuttle_check_dock_distance", args)
end

-- Engineer that converts power into shields  (simple logic)
-- if we are at low shield, the engineer tries to reroute some power to shields
-- an unsatisfied engineer will waste power and drain shields (but earn satisfaction and stabilize)
function engineer_shield(engineer)
	if engineer.hook and engineer.hook.hook then
		hook.rm(engineer.hook.hook)
	end
	engineer.hook.hook = nil
	local pp = player.pilot()
	local armour, shield, _stress = pp:health()
	if armour == nil then return end
	
	if shield < math.min(50, 20 + engineer.xp) then
		-- try to initiate a power surge to shields
		local surge = engineer.xp * engineer.satisfaction * pp:ship():size() * 3
		local power_needed = math.max(engineer.xp, surge * (12 - engineer.xp) - engineer.bonus)
		local current_power = pp:energy()
		-- learn to not be too greedy with the power
		if current_power > power_needed * math.max(1, engineer.xp) then
			pp:setEnergy(current_power - power_needed, true)
			pp:addHealth(0, surge)
			engineer.satisfaction = engineer.satisfaction + 0.01
			engineer.xp = math.max(10, engineer.xp + 0.01)
			-- doing our job makes our workstation and the rest of the ship dirtier
			mem.ship_interior.dirt = mem.ship_interior.dirt + engineer.xp * 0.06
			-- reaction to having done something
			if rnd.rnd() < engineer.chatter then
				-- act like a weird engineer
				local listener = getCrewmateOnboard()
			speak_to( {me=engineer, responder=listener, message=add_special(engineer) .. " " .. add_special(engineer) })
			elseif rnd.rnd() < engineer.chatter then
				-- act normally
				speak(engineer)
			end -- otherwise: just stay silent
		end
	end
	
	-- set the next hook to poll
	engineer.hook.hook = hook.timer(math.max(6, 8 * player.pilot():ship():size() - engineer.xp * engineer.satisfaction), "engineer_shield", engineer)
end

-- Engineer that converts armor into power (simple logic)
-- if we are at low power, the engineer tries to burn armor as fuel to generate power
-- an unsatisfied engineer will waste power and drain armor (but earn satisfaction and stabilize)
function engineer_power(engineer)
	if engineer.hook and engineer.hook.hook then
		hook.rm(engineer.hook.hook)
	end
	engineer.hook.hook = nil
	local pp = player.pilot()
	local armour, _shield, _stress = pp:health(true)
	if armour == nil then return end
	local current_power = pp:energy(true)
--	print(fmt.f("armour {armour} points energy {cp} ({energy} %)", { energy=pp:energy(), cp = current_power, armour=armour }))
	if pp:energy() < math.min(50, 20 + engineer.xp) then
		-- try to initiate a power surge
		local surge = engineer.xp * engineer.satisfaction * pp:ship():size()
		local armor_needed = math.max(engineer.xp, surge * (12 - engineer.xp) - engineer.bonus) / (10 - pp:ship():size())
--		print(fmt.f("armourneeded {armour_needed}/{armour} points surge {surge}", { energy=pp:energy(), cp = current_power, armour=armour, armour_needed=armor_needed, surge=surge }))
		-- learn to not be too greedy with the armor
		if armour > armor_needed * math.max(1, engineer.xp) then
			pp:setEnergy(current_power + surge * 4, true)
			pp:addHealth(-armor_needed)
			engineer.satisfaction = engineer.satisfaction + 0.01
			engineer.xp = math.max(10, engineer.xp + 0.01)
			-- doing our job makes our workstation and the rest of the ship dirtier
			mem.ship_interior.dirt = mem.ship_interior.dirt + engineer.xp * 0.06
			-- reaction to having done something
			if rnd.rnd() < engineer.chatter then
				-- act like a weird engineer
				local listener = getCrewmateOnboard()
			speak_to( {me=engineer, responder=listener, message=add_special(engineer) .. " " .. add_special(engineer) })
			elseif rnd.rnd() < engineer.chatter then
				-- act normally
				speak(engineer)
			end -- otherwise: just stay silent
		end
	end
	
	-- set the next hook to poll
	engineer.hook.hook = hook.timer(math.max(6, 8 * player.pilot():ship():size() - engineer.xp * engineer.satisfaction), "engineer_power", engineer)
end

-- engineer that converts shields and power into armour (active/cooldown logic)
-- the engineer is on duty in the engineering room
-- if the armour goes below 95%, the engineer wakes up and gets to work,
-- after some time (depends on skill and satisfaction) the engineer starts healing the ship
-- the healing gets stronger and stronger but heat accumulates
-- healing can only continue while shiled and energy are near full, and stress near zero
-- this makes the engineer useless for tanking, but great at repairing in between fights
function engineer_armour(engineer)
	if engineer.hook and engineer.hook.hook then
		hook.rm(engineer.hook.hook)
	end
	engineer.hook.hook = nil
	local pp = player.pilot()
	local armour, shield, stress = pp:health()
	if armour == nil then return end
	
--	print(fmt.f("{armour}, {shield}, {stress}", {armour=armour, shield=shield, stress=stress}))
	
	-- engineer hero sacrifice (but not if the player already died)
	if (armour <= 4 and pp:energy() > 36 and armour > 0) then
		local health_bonus = engineer.xp * engineer.xp * engineer.xp * engineer.satisfaction * engineer.satisfaction
		pp:addHealth(health_bonus, health_bonus / 8)
		engineer.bonus = health_bonus
		local message = fmt.f(_("Your engineer, {name}, was lost in space combat while maintaining hull integrity. As a final valiant act of heroism, {bonus:.0f} armor was repaired in a massive power surge."), engineer)
		vntk.msg(_("Heroic Sacrifice"), message)
		terminate_crew(engineer, message)
	elseif (armour <= 10 and pp:energy() > 20) then
		-- "active situation" polling rate
		engineer.hook.hook = hook.timer(16 - engineer.satisfaction, "engineer_armour", engineer)
	end
	
	-- standard engineer duties
	if (armour < math.min(100, 90 + engineer.xp)
		and shield >= 100 - engineer.xp - engineer.satisfaction
		and stress * stress < engineer.satisfaction * engineer.xp
		and pp:energy() > 96 - engineer.satisfaction
		) or	-- engineer spits out his coffee and roll up his sleeves
		(armour <= 16 + engineer.xp + engineer.satisfaction and pp:energy() >= 4)
	then

		-- begin healing after a slight delay
		if engineer.active then
			-- healing stage begun
			engineer.hook.hook = hook.timer(
				rnd.rnd(math.floor(11 - engineer.xp), math.ceil(22 - engineer.xp - engineer.satisfaction)),
				"engineer_armour", engineer)
			engineer.active = engineer.active + 1
			local healed = math.ceil(engineer.xp * engineer.active / (engineer.xp * engineer.xp + 1))
			pp:addHealth(healed, -healed * healed )
			local heated = engineer.active / (engineer.xp * engineer.xp + engineer.active + 1)
			pp:setTemp(pp:temp() + heated)
			local energy_used = heated * healed * engineer.xp
			pp:setEnergy(pp:energy(true) - energy_used, true)
--			print(fmt.f("healed {healed} armour points and heated by {heat} K at cost of {mw} energy", { healed = healed, heat = heated, mw=energy_used }))
		else
			engineer.active = 1 + engineer.bonus * 0.1
			local delay = math.max(2, 20 - engineer.xp - engineer.satisfaction)
			engineer.hook.hook = hook.timer(delay, "engineer_armour", engineer)
			
			local message = pick_one(engineer.conversation.message)
			_comm(fmt.f("{typetitle} {name}", engineer), message .. fmt.f(" I need about {delay} more seconds... ", { delay = math.max(2, math.ceil(delay + rnd.threesigma() * 10)) }) .. add_special(engineer) )
			engineer.satisfaction = math.min(10, engineer.satisfaction + 0.01)
		end
		return
	elseif engineer.active then
		-- experience gained while cooling down
		local gained_xp = (engineer.active * 0.01)
		engineer.xp = math.min(10, engineer.xp + gained_xp)
--		print(fmt.f("engineer cooldown and gained {xp} xp", {xp = gained_xp}))
		-- entering cooldown distributes residue dirt everywhere around the ship
		mem.ship_interior.dirt = mem.ship_interior.dirt + engineer.xp * 0.06
		if rnd.rnd() < engineer.chatter then
			-- act like a weird engineer
			local listener = getCrewmateOnboard()
			speak_to( {me=engineer, responder=listener, message=add_special(engineer) .. " " .. add_special(engineer) })
		elseif rnd.rnd() < engineer.chatter then
			-- act normally
			speak(engineer)
		end -- otherwise: just stay silent

		-- cooldown
		engineer.active = math.max(0, engineer.active / 2 - 3)
		engineer.hook.hook = hook.timer(20 * player.pilot():ship():size() + 10 * engineer.xp + engineer.satisfaction, "engineer_armour", engineer)
	elseif not player.isLanded() then
		-- polling rate to start the engineering logic 
		engineer.hook.hook = hook.timer(math.max(6, 20 * player.pilot():ship():size() - engineer.xp * engineer.satisfaction), "engineer_armour", engineer)
	end
	-- engineer cooldown finished to reset
	if engineer.active and engineer.active < 3 then
		engineer.active = nil
	end
end

-- the player boards a hostile ship with a demoman on board
function player_boarding_c4(target, speaker)
    if target and target:exists() and target:hostile() and target:memory().natural == true then
        hook.timer(2, "speak_notify", speaker)
        hook.timer(6, "detonate_c4", target)
        hook.timer(8, "detonate_c4", target)
        hook.timer(9, "detonate_c4", target)
        hook.timer(10, "detonate_c4", target)
        hook.timer(rnd.rnd(10, 11), "detonate_c4", target)
        hook.timer(11, "detonate_c4", target)
        hook.timer(12 + rnd.rnd(), "detonate_c4", target)
        hook.timer(12 + rnd.rnd(), "detonate_c4", target)
        hook.timer(12 + rnd.rnd(), "detonate_c4", target)
        -- we just planted a bomb, increase satisfaction
        speaker.satisfaction = math.min(10, speaker.satisfaction + 1)
        -- if we planted a bomb on something big, create a memory based on how likely we are to mention it
        if target:ship():size() >= 5 and rnd.rnd() < speaker.chatter then
            create_memory(
                speaker,
                "violence",
                {
                    target = target:name(),
                    ship = target:ship(),
                    credits = fmt.credits(target:credits()),
					cred_amt = target:credits(),
                    armour = target:health(true),
                    system = system.cur()
                }
            )
        end
		-- boarding the enemy ship and all that jazz made everything dirty
		mem.ship_interior.dirt = mem.ship_interior.dirt + speaker.xp * target:ship():size()  * 0.1
    else
        -- we boarded something for friendly reasons, if we like violence, we are pissed
        for _i, person in ipairs(mem.companions) do
            if has_interest(person, "violence") then
                person.satisfaction = math.max(-10, person.satisfaction - 1)
            end
        end
    end
end

-- a demoman's bomb explodes (single payload)
function detonate_c4(target)
    if target and target:exists() then
        local sound_choices = {
            "medexp1",
            "medexp0",
            "crash1",
            "grenade",
            "explosion0",
            "explosion1",
            "explosion2",
            "tesla"
        }
        local dir_vec = vec2.new(math.floor(rnd.threesigma() * 30), math.floor(rnd.twosigma() * 20))
        target:knockback(800, dir_vec, target:pos() - dir_vec)
        target:setDir(target:dir() + rnd.threesigma() * 0.07)
        local expl_pos = vec2.add(target:pos(), rnd.threesigma() * 2, rnd.twosigma() * 2)
        -- apply the damage (the player gets the credit)
        target:damage(rnd.rnd(277, 313), 0, 100, "impact", player.pilot())
        -- visual and audio effects?
        audio.soundPlay(pick_one(sound_choices), expl_pos)
        -- we used explosives, add to cost
        local current_cost = mem.costs["equipment"]
        if current_cost == nil then
            current_cost = 0
        end
        mem.costs["equipment"] = current_cost + prices["equipment"]
        -- an explosion just happened, if we like violence, we are thrilled
        for _i, person in ipairs(mem.companions) do
            if has_interest(person, "violence") then
                person.satisfaction = math.min(10, person.satisfaction + 0.01)
            end
        end
    end
end

-- function to restore the player into the "mothership" after
-- a joyride in the shuttle
function player_swaps_from_shuttle()
	local commander = getCommander()
	if commander.pilot then
		local shuttle_manager = findCrewOfType(_("Pilot"))
		-- make sure we are in the shuttle
		if player.pilot():ship():name() ~= mem.ship_interior.shuttle.ship:name() then
			vntk.msg( _("Docking Error"), _("The ship you are in doesn't appear to have the necessary adjustments to fit inside the docking bay. Whatever you've done with the shuttle, you'd better bring it back if you want to get back on your ship."))
			-- player doesn't get to return
			player.commClose()
			return false -- pun not intended
		end
		
		-- we are redocking, save the current outfit layout
		shuttle_manager.manager.outfits = {}
		for j, o in ipairs(player.pilot():outfits()) do
			shuttle_manager.manager.outfits[#shuttle_manager.manager.outfits + 1] = o:nameRaw()
		end
		-- the player goes back into the captain's seat
		-- bringing any cargo along
		player.swapShip(mothership, false, true)
		-- copy the vector
		player.pilot():setDir(commander.pilot:dir())
		player.pilot():setVel(commander.pilot:vel())
		
		-- put the cargo back
		local cl = commander.pilot:cargoList()
		-- goes back into the player
		for k,v in pairs( cl ) do
			commander.pilot:cargoRm( v.name, v.q )
			player.pilot():cargoAdd( v.name, v.q )
		end
		commander.pilot:rm()
		commander.pilot = nil
		mem.ship_interior.shuttle.out = nil
		player.allowSave(true)
		der.sfx.board:play()
		commander_button(commander)
		player.allowLand ( true )
	else
		-- error: no comander pilot found! shouldn't be possible since we are boarding it
		print("ERROR: No commander pilot found! Where is the mothership?")
	end
	
	-- remove the commander respawner
	if commander.ghost.hook then
		hook.rm(commander.ghost.hook)
		commander.ghost.hook = nil
	end
	commander.ghost = nil
end

-- crazy method that puts the player in the shuttle
-- and puts the commander at the helm of the player's ship
-- returns success
function player_swaps_to_shuttle ( args )
	if not naev.claimTest(system.cur()) then
		vntk.msg( _("Undocking error") , _([[You are unable to swap into the Officer's shuttle due to electromagnetic interference that would disrupt the sensors on the shuttle to the point where your safety cannot be fully guaranteed. Without the approval of both your shuttle manager and first officer, you will not be able to disembark in the shuttle at this time.]]) )
		return
	end
	local commander = args.commander or getCommander()
	local shuttle_manager = args.shuttle_manager or findCrewOfType(_("Pilot"))
	
	local template = pilot.add(mem.ship_interior.shuttle.ship, "Trader", player.pilot():pos())
	if shuttle_manager.manager and shuttle_manager.manager.outfits then
		print("the shuttle manager is " .. shuttle_manager.firstname)
		template:outfitRm("all")
		template:outfitRm("cores")
		for _j, o in ipairs(shuttle_manager.manager.outfits) do
			template:outfitAdd(o, 1 , true, false)
			print("template receives outfit: " .. tostring(o))
		end
	end
	
	local pp = player.pilot()
	mothership = player.ship()
	
	-- create a "ghost" for the commander in case the player lands
	-- we also use this to spawn the commander the first time
	commander.ghost = {}
	commander.ghost.ship = pp:ship()
	commander.ghost.pos = pp:pos()
	commander.ghost.dir = pp:dir()
	commander.ghost.vel = pp:vel()
	commander.ghost.outfits = pp:outfits()
	commander.ghost.cargo = pp:cargoList()
	
	local cl = pp:cargoList()

	for k, v in pairs( cl ) do
		if not v.m then
			-- goes into the commander's ship
			pp:cargoRm( v.name, v.q )
		end
	end

	-- before we create the new ship, we should save the old ship info for when we recreate it
	-- but we can't recreate it as it was, so instead we just hope the player doesn't try to jump in the same ship
	-- if he does, it errors straight away
	
	-- OK we create and swap to the shuttle here
	pp:hookClear() -- clear player hooks to prevent errors
	local acquired = fmt.f(_("The shuttle bay of your {mothership}."), { mothership = player:ship() } )
	
	local shuttle_name = fmt.f( _("{name}'s Shuttle"), args.commander )
	local newship = player.addShip(mem.ship_interior.shuttle.ship, shuttle_name, acquired, true)
	player.swapShip( newship , false, false)
	pp = player.pilot()
	pp:outfitRm( "all" )
	pp:outfitRm( "cores" )
	for _j, o in ipairs( template:outfits() ) do
		pp = player.pilot() -- not sure why I'm doing this, but swapship.swap#116 does this
		local ret = pp:outfitAdd(o, 1 , true)
		print("adding outfit " .. o:name() .. ":\t " .. tostring(ret))
	end
	mem.ship_interior.shuttle.out = true
	player.allowSave(false)
	der.sfx.unboard:play()
	template:rm()

	-- create the player's ship, piloted by the commander
	spawn_ghost_commander2(commander)
	commander.pilot:changeAI( "escort_guardian" )
	
	-- unregister the info button, need to hail the mothership now
	clearCommanderInterface()
--	player.allowLand ( false, _("The shuttle isn't equipped with landing gear.") )
--	player.pilot():setNoJump(true)
	
	-- risky
	player.pilot():hookClear() -- clear player hooks to prevent errors
	
	return true
end

-- if the player swapped out of his own ship in space, or if
-- the player despawned his own ship while landing, we need to respawn it
function spawn_ghost_commander2( commander )
	if	commander.ghost and
		(
			not commander.pilot
			or (
				not commander.pilot:exists()
				-- anything else?
			)
		)
		and
		mothership ~= player:ship()
	then
		if commander.ghost.hook then
			hook.rm(commander.ghost.hook)
			commander.ghost.hook = nil
		end
		print("spawning commander because mothership is %s != %s", mothership, player.ship())
		local fakefac = faction.dynAdd(commander.faction, commander.manager.skill, commander.manager.skill, { ai = "escort_guardian", clear_enemies = true})

		-- add the commander in the players ship
		commander.pilot = pilot.add(commander.ghost.ship, fakefac, commander.ghost.pos, fmt.f("{skill} {typetitle} {name}", commander), { naked = true })
		-- match speed and velocity
		commander.pilot:setDir(commander.ghost.dir)
		commander.pilot:setVel(commander.ghost.vel)
		-- commander has same outfits as player had
		for _j, o in ipairs(commander.ghost.outfits) do
			commander.pilot:outfitAdd(o)
		end
		-- put the cargo back
		for k, v in pairs(commander.ghost.cargo) do
			-- the player took the mision cargo
			if not v.m then
				commander.pilot:cargoAdd( v.name, v.q )
			end
		end
		commander.pilot:setVisplayer(true)
--		commander.pilot:setNoClear(true)
		commander.pilot:setNoLand(true)
		commander.pilot:setNoJump(true)
		commander.pilot:setActiveBoard(true)
		commander.pilot:setHilight(true)
		commander.pilot:setFriendly(true)
		commander.pilot:setInvincPlayer(true)

		-- reinstate the regular hooks
		hook.pilot(commander.pilot, "board", "player_swaps_from_shuttle", args)
		hook.pilot(commander.pilot, "hail", "startCommandDiscussion")
		if commander.ghost.hook then
			hook.rm(commander.ghost.hook)
			commander.ghost.hook = nil
		end
		commander.ghost.hook = hook.takeoff("spawn_ghost_commander2", commander)
	end
end

-- method to intercept the player trying to hail nothing,
-- if we have a first officer we register this hook and talk to the player
-- if the player is trying to hail nothing, we assume he wants to speak to a commander
function hail_hook( inputname, inputpress, args )
	if inputpress and inputname == "hail" and not player.pilot():target() and not player.pilot():nav() then
		hook.timer(rnd.rnd(2, 6), "startCommandDiscussion")
	end
end

-- TODO COMPANION BUTTON AND SHUTTLE
-- the first officer (or another commander) arrives on the bridge for duty
-- register an info button to speak to a commanding officer
function commander_button(officer)
	addCommanderInterface()
	mem.ship_interior.officers[_("First Officer")] = officer
	if rnd.rnd(0, officer.xp) < math.abs(officer.satisfaction) then
		hook.timer(2 + rnd.rnd(3, math.max(10, officer.xp * math.abs(officer.satisfaction))), "say_specific", {me = officer, message = pick_one(officer.conversation.message)})
	end
end