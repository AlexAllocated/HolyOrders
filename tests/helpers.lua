local H = { passed = 0 }
function H.noop() end
function H.load(file)
	assert(loadfile((os.getenv("HOLYORDERS_SOURCE") or ".") .. "/" .. file))()
end
function H.clock()
	local clock = { now = 0, timers = {} }
	GetTime = function()
		return clock.now
	end
	time = function()
		return 1800000000 + math.floor(clock.now)
	end
	local function timer(delay, callback, interval)
		local t = { at = clock.now + delay, callback = callback, interval = interval }
		function t:Cancel()
			self.cancelled = true
		end
		clock.timers[#clock.timers + 1] = t
		return t
	end
	C_Timer = {
		After = timer,
		NewTimer = timer,
		NewTicker = function(d, cb)
			return timer(d, cb, d)
		end,
	}
	function clock:advance(to)
		assert(to >= self.now)
		while true do
			local nextTimer
			for _, t in ipairs(self.timers) do
				if not t.cancelled and t.at <= to and (not nextTimer or t.at < nextTimer.at) then
					nextTimer = t
				end
			end
			if not nextTimer then
				break
			end
			self.now = nextTimer.at
			if nextTimer.interval then
				nextTimer.at = self.now + nextTimer.interval
			else
				nextTimer.cancelled = true
			end
			nextTimer.callback()
		end
		self.now = to
	end
	return clock
end
function H.checksum(rows, tanks)
	local text = ""
	for _, row in ipairs(rows) do
		text = text .. "PR:" .. row .. "\n"
	end
	for _, tank in ipairs(tanks) do
		text = text .. "PT:" .. tank .. "\n"
	end
	local hash = 5381
	for i = 1, #text do
		hash = (hash * 33 + text:byte(i)) % 4294967296
	end
	return hash
end
function H.fixture(withComm)
	local f = {
		clock = H.clock(),
		events = {},
		rosterCallbacks = {},
		buffs = {},
		sent = {},
		announcements = {},
		raid = true,
		symbols = 10,
	}
	local me = "Me-Realm"
	wipe = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
	end
	unpack = table.unpack or unpack
	strsplit = function(sep, value)
		local parts, start = {}, 1
		while true do
			local pos = value:find(sep, start, true)
			if not pos then
				parts[#parts + 1] = value:sub(start)
				break
			end
			parts[#parts + 1] = value:sub(start, pos - 1)
			start = pos + #sep
		end
		return unpack(parts)
	end
	IsInRaid = function()
		return f.raid
	end
	IsInGroup = function()
		return true
	end
	UnitIsGroupLeader = function()
		return false
	end
	UnitClass = function()
		return "Paladin", "PALADIN"
	end
	GetNormalizedRealmName = function()
		return "Realm"
	end
	UnitIsDeadOrGhost = function()
		return false
	end
	UnitIsVisible = function()
		return true
	end
	UnitPowerType = function(unit)
		return unit == "pet" and 2 or 0
	end
	InCombatLockdown = function()
		return f.combat or false
	end
	local HO = {
		VERSION = "0.40.0",
		L = setmetatable({}, {
			__index = function(_, k)
				return k
			end,
		}),
		db = {
			options = { greaterMin = 2, pets = { hunter = true, blessing = 2 }, bar = { grow = "right" } },
			prefs = {},
			specCache = {},
			plans = {},
			expected = {},
			log = {},
		},
		Roster = { units = {}, byName = {} },
		Talents = { ranks = {}, tabPoints = { 0, 0, 0 } },
		Window = { Refresh = H.noop },
		Bar = { Refresh = H.noop },
	}
	HolyOrders = HO
	f.HO = HO
	HO.FullName = function()
		return me
	end
	HO.Print = H.noop
	HO.Announce = function(message)
		f.announcements[#f.announcements + 1] = message
	end
	HO.Log = function(category, message)
		if category == "error" then
			error(message, 0)
		end
	end
	HO.RegisterEvent = function(event, callback)
		f.events[event] = f.events[event] or {}
		table.insert(f.events[event], callback)
	end
	HO.Roster.OnChanged = function(cb)
		f.rosterCallbacks[#f.rosterCallbacks + 1] = cb
	end
	HO.Roster.Paladins = function()
		local names = {}
		for name, e in pairs(HO.Roster.byName) do
			if e.class == "PALADIN" then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		return names
	end
	HO.Compat = {
		EventExists = function()
			return false
		end,
		TALENT_EVENTS = {},
		AddonCommsLocked = function()
			return false
		end,
		ItemCount = function()
			return f.symbols
		end,
		SpellInRange = function()
			return true
		end,
		FindBuff = function(unit, name, greater)
			local buff = f.buffs[unit]
			if buff and (buff.name == name or buff.name == greater) then
				return true, 1800, buff.expires
			end
		end,
	}
	function f:add(name, class, unit, rank)
		local e = { name = name, class = class, unit = unit, rank = rank or 0, online = true }
		HO.Roster.byName[name] = e
		HO.Roster.units[#HO.Roster.units + 1] = e
		return e
	end
	f:add(me, "PALADIN", "player", 1)
	H.load("Data.lua")
	for _, b in ipairs(HO.Data.blessings) do
		b.name = b.key
		b.greaterName = "Greater " .. b.key
		b.known = true
		b.greaterKnown = true
		b.rankNum = 1
	end
	H.load("Plan.lua")
	H.load("Planner.lua")
	H.load("Engine.lua")
	function f:event(name, ...)
		for _, cb in ipairs(self.events[name] or {}) do
			cb(...)
		end
	end
	local streams = {}
	function f:message(sender, msg)
		-- Hand-written stream cases get a PE checksum of the scripted rows.
		-- SendPlanApply round trips below use the sender's actual wire bytes.
		local kind, payload = msg:match("^(%u+):(.*)$")
		if kind == "PS" then
			streams[sender] = { rows = {}, tanks = {} }
		end
		local stream = streams[sender]
		if stream and kind == "PR" then
			stream.rows[#stream.rows + 1] = payload
		end
		if stream and kind == "PT" then
			for tank in payload:gmatch("[^|]+") do
				stream.tanks[#stream.tanks + 1] = tank
			end
		end
		if stream and kind == "PE" and payload:match("^%d+;%d+$") then
			msg = msg .. ";" .. H.checksum(stream.rows, stream.tanks)
		end
		self:event("CHAT_MSG_ADDON", "HolyOrders", "4:" .. msg, "RAID", sender)
	end
	if withComm then
		C_ChatInfo = {
			RegisterAddonMessagePrefix = H.noop,
			SendAddonMessage = function(prefix, msg, channel, target)
				f.sent[#f.sent + 1] = { prefix = prefix, message = msg, channel = channel, target = target }
			end,
		}
		H.load("Comm.lua")
		f:event("PLAYER_LOGIN")
	end
	return f
end
function H.test(name, cb)
	if arg[2] and arg[2] ~= name then
		return
	end
	cb()
	H.passed = H.passed + 1
	print("PASS " .. name)
end
return H
