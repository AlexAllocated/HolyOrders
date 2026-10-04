-- HolyOrders — deterministic auto-planner
-- Same roster + same tags + same talents → the same plan, every time.
-- Coverage model: each paladin is assigned one blessing to cover across all
-- eligible classes; per-member preference deviations and tank protection are
-- expressed as player overrides (cast as 10-min singles).

local HO = HolyOrders
local Planner = {}
HO.Planner = Planner

local WISDOM, MIGHT, KINGS, SALVATION, LIGHT, SANCTUARY = 1, 2, 3, 4, 5, 6

-- raid blessing coverage priority by paladin count position (parties use
-- per-class preference lists instead)
local RAID_COVERAGE = { KINGS, SALVATION, MIGHT, WISDOM, LIGHT, SANCTUARY }

-- shipped class/spec preference defaults; user copies in HO.db.prefs win
local DEFAULT_PREFS = {
	WARRIOR = { default = { KINGS, MIGHT, SALVATION }, protection = { KINGS } },
	ROGUE = { default = { MIGHT, SALVATION, KINGS } },
	PRIEST = { default = { WISDOM, SALVATION, KINGS } },
	MAGE = { default = { WISDOM, SALVATION, KINGS } },
	WARLOCK = { default = { WISDOM, SALVATION, KINGS } },
	HUNTER = { default = { MIGHT, SALVATION, KINGS, WISDOM } },
	SHAMAN = { default = { WISDOM, SALVATION, KINGS }, enhancement = { MIGHT, SALVATION, KINGS }, elemental = { WISDOM, SALVATION, KINGS }, restoration = { WISDOM, SALVATION, KINGS } },
	DRUID = { default = { WISDOM, SALVATION, KINGS }, feral = { MIGHT, SALVATION, KINGS }, balance = { WISDOM, SALVATION, KINGS }, restoration = { WISDOM, SALVATION, KINGS } },
	PALADIN = { default = { KINGS, WISDOM }, holy = { WISDOM, KINGS }, protection = { KINGS }, retribution = { MIGHT, KINGS, SALVATION } },
}
Planner.DEFAULT_PREFS = DEFAULT_PREFS

function Planner.ValidSpecs(classToken)
	local prefs = DEFAULT_PREFS[classToken]
	local specs = {}
	if prefs then
		for key in pairs(prefs) do
			if key ~= "default" then
				table.insert(specs, key)
			end
		end
		table.sort(specs)
	end
	return specs
end

-- preference chain (SPEC-planner §6b) minus the manual-override level, which
-- the planner respects separately
-- my own spec from my own talent distribution — no inspect needed, so the
-- player's row is always spec-aware even before anyone tags them
local OWN_TAB_SPECS = { "holy", "protection", "retribution" }
local function OwnSpecTag()
	if select(2, UnitClass("player")) ~= "PALADIN" then
		return nil
	end
	local best, bestPoints, total = nil, 0, 0
	for tab, points in ipairs(HO.Talents.tabPoints) do
		total = total + points
		if points > bestPoints then
			best, bestPoints = tab, points
		end
	end
	if not best or total < 5 then
		return nil -- unspecced/ambiguous: fall through to the class default chain
	end
	return OWN_TAB_SPECS[best]
end

-- Own spec: a local tag wins, then talent inference, then the synced fallback.
-- Keep the same precedence as ResolvePreference.
function Planner.OwnSpec()
	local me = HO.FullName("player")
	return (me and HO.db.specCache[me]) or OwnSpecTag()
		or (me and HO.Comm and HO.Comm.specSync[me])
end

-- what a tank should get, best first: Kings, then Light, then the stat
-- blessings — every consumer filters by eligibility and what the caster
-- actually knows, so a paladin without the Kings talent falls through to
-- Light instead of holding an uncastable assignment
local TANK_CHAIN = { KINGS, LIGHT, MIGHT, WISDOM }

function Planner.ResolvePreference(name, classToken, isTank)
	if isTank then
		-- tank protection beats any liking or request; castability filtering
		-- happens downstream like for every other chain
		return { KINGS, LIGHT }
	end
	local prefs = HO.db.prefs[classToken] or DEFAULT_PREFS[classToken]
	local spec = name and HO.db.specCache[name]
	if not spec and name and name == HO.FullName("player") then
		spec = OwnSpecTag()
	end
	if not spec and name and HO.Comm then
		spec = HO.Comm.specSync[name]
	end
	local chain = (prefs and ((spec and prefs[spec]) or prefs.default)) or { KINGS }
	-- ordered chain, highest priority first, duplicates dropped keeping the earliest:
	--   1) the member's own ranked buff requests (their explicit wish)
	--   2) a remembered member liking (a paladin's earlier manual override)
	--   3) the spec/default class chain
	-- The downstream step-4 logic still filters each by eligibility and
	-- castability, so an ineligible or unavailable preference is skipped.
	local result, seen = {}, {}
	local function push(id)
		if id and not seen[id] then
			seen[id] = true
			result[#result + 1] = id
		end
	end
	local requests = HO.Comm and HO.Comm.requests and HO.Comm.requests[name]
	if type(requests) == "table" then
		for _, id in ipairs(requests) do
			push(id)
		end
	end
	push(HO.Plan and HO.Plan.MemberPref and HO.Plan.MemberPref(name))
	for _, id in ipairs(chain) do
		push(id)
	end
	return result
end

-- capabilities ----------------------------------------------------------------

local function Available(pallyName, blessingID)
	if pallyName == HO.FullName("player") then
		local blessing = HO.Data.blessings[blessingID]
		return (blessing and blessing.known) or false
	end
	-- peers broadcast their capabilities via HELLO
	local peer = HO.Comm and HO.Comm.peers[pallyName]
	if peer and peer.caps and peer.caps[blessingID] then
		return peer.caps[blessingID].known
	end
	-- no HolyOrders on that paladin: assume everything but talent-gated
	-- Sanctuary. Exception: a paladin tagged protection (manually, synced or
	-- inspect-inferred) is exactly the build that has Sanctuary — unlock it, so
	-- it stays assignable to addon-less protection paladins.
	if blessingID ~= SANCTUARY then
		return true
	end
	local spec = HO.db.specCache[pallyName] or (HO.Comm and HO.Comm.specSync[pallyName])
	return spec == "protection"
end
Planner.IsAvailable = Available

-- buff strength: improvement talents dominate (a maxed talent beats one
-- spell rank), then spell rank, then greater-version knowledge as tiebreak
local function Score(pallyName, blessingID)
	local talent, rank, greater = 0, 0, false
	if pallyName == HO.FullName("player") then
		talent = HO.Talents.ranks[blessingID] or 0
		local blessing = HO.Data.blessings[blessingID]
		rank = (blessing and blessing.rankNum) or 0
		greater = (blessing and blessing.greaterKnown) or false
	else
		local peer = HO.Comm and HO.Comm.peers[pallyName]
		local caps = peer and peer.caps and peer.caps[blessingID]
		if caps then
			talent = caps.talent or 0
			rank = caps.rank or 0
			greater = caps.greater or false
		end
	end
	return talent * 12 + rank * 10 + (greater and 1 or 0)
end

-- substitute for a Salvation class assignment while no-Salvation mode is on:
-- class preference first, then Light/Kings/Wisdom/Might, skipping blessings
-- the class already receives from another paladin
-- what replaces a Salvation assignment while no-Salvation mode runs. `target`
-- names the member when the assignment is about one person (a per-member
-- override, or a class with a single member present) — their own wishes then
-- decide, which is the whole point of a request.
function Planner.SalvSubstitute(pally, classToken, plan, target)
	local received = {}
	for otherPally, rows in pairs(plan.class) do
		if otherPally ~= pally then
			local a = rows[classToken]
			-- explicit-none markers carry no id
			if a and a.id then
				received[a.id] = true
			end
		end
	end
	-- candidate order decides what replaces Salvation. ResolvePreference
	-- supplies the member's ranked requests and their remembered per-character
	-- liking ahead of the class chain, so a wish is honoured here exactly like
	-- in normal planning — only Salvation itself is skipped. Kings is the
	-- universal filler and Light strictly LAST: it is the weakest still-useful
	-- blessing and must only appear once everything stronger is covered.
	local candidates = {}
	local function append(list)
		for _, id in ipairs(list or {}) do
			table.insert(candidates, id)
		end
	end
	append(Planner.ResolvePreference(target, classToken, false))
	local userPrefs = HO.db.prefs[classToken]
	append(userPrefs and userPrefs.default)
	local shipped = DEFAULT_PREFS[classToken]
	append(shipped and shipped.default)
	append({ KINGS, LIGHT })
	for _, id in ipairs(candidates) do
		if id ~= SALVATION and not received[id]
			and HO.Data.IsEligible(classToken, id, false) and Available(pally, id) then
			return id
		end
	end
	return nil
end

-- helpers ---------------------------------------------------------------------

local function IsTankEntry(plan, entry)
	return HO.Plan.IsTank(entry.name, entry.tankRole)
end

local function HasOverrideFor(plan, target)
	for _, targets in pairs(plan.player) do
		if targets[target] then
			return true
		end
	end
	return false
end

-- planner-generated overrides are tracked so a re-run can replace them while
-- manual overrides are never touched
local function ClearAutoOverrides(plan)
	if not plan.autoPlayer then
		return
	end
	for pally, targets in pairs(plan.autoPlayer) do
		for target in pairs(targets) do
			if plan.player[pally] then
				plan.player[pally][target] = nil
			end
		end
	end
	plan.autoPlayer = nil
end

local function AddAutoOverride(plan, pally, target, blessingID)
	HO.Plan.SetPlayerOverride(pally, target, blessingID)
	plan.autoPlayer = plan.autoPlayer or {}
	plan.autoPlayer[pally] = plan.autoPlayer[pally] or {}
	plan.autoPlayer[pally][target] = true
end

-- main -------------------------------------------------------------------------

local function RunCore(pallys)
	HO.Plan.CancelArrivals()
	local plan = HO.Plan.Active()
	local units = HO.Roster.units
	local isRaid = IsInRaid()
	local solo = (#pallys == 1)

	-- stale-paladin pruning: drop overrides owned by paladins no longer in the
	-- roster. An absent owner's leftover override otherwise blocks step 4 via
	-- HasOverrideFor while nobody is present to cast it. plan.class is wiped just
	-- below anyway; plan.rev (revision continuity for absent owners) and
	-- plan.tanks are deliberately left untouched.
	local inRoster = {}
	for _, pally in ipairs(pallys) do
		inRoster[pally] = true
	end
	for pally in pairs(plan.player) do
		if not inRoster[pally] then
			plan.player[pally] = nil
		end
	end
	if plan.autoPlayer then
		for pally in pairs(plan.autoPlayer) do
			if not inRoster[pally] then
				plan.autoPlayer[pally] = nil
			end
		end
	end

	ClearAutoOverrides(plan)
	wipe(plan.class)

	-- class composition (players only; pets are cast-engine targets)
	local classes = {} -- [classToken] = { members, tanks, list }
	for _, entry in ipairs(units) do
		if not entry.isPet and entry.class and entry.name then
			local info = classes[entry.class]
			if not info then
				info = { members = 0, tanks = 0, list = {} }
				classes[entry.class] = info
			end
			info.members = info.members + 1
			table.insert(info.list, entry)
			if IsTankEntry(plan, entry) then
				info.tanks = info.tanks + 1
			end
		end
	end

	-- 1) blessing coverage: one blessing per paladin, deterministic
	-- talent-aware self blessing for a lone paladin — never Salvation on
	-- yourself: the preference chain's own-spec fallback proposes Wisdom for
	-- holy, Might for retribution, Kings for protection
	local function AssignSelfBlessing(me)
		local myEntry = HO.Roster.byName[me]
		local isTank = (myEntry and IsTankEntry(plan, myEntry)) and true or false
		for _, id in ipairs(Planner.ResolvePreference(me, "PALADIN", isTank)) do
			if id ~= SALVATION and HO.Data.IsEligible("PALADIN", id, isTank) and Available(me, id) then
				HO.Plan.SetClassAssignment(me, "PALADIN", id, "auto")
				return
			end
		end
	end

	-- the Salvation-for-everyone solo mode needs a paladin who can cast it; a
	-- levelling paladin without Salvation plans like any other party instead
	local soloSalv = solo and IsInGroup() and Available(pallys[1], SALVATION)

	local assigned = {} -- [pallyName] = blessingID
	if solo and not IsInGroup() then
		-- truly alone: Salvation on yourself is pointless (threat reduction
		-- only matters with a tank)
		AssignSelfBlessing(pallys[1])
	elseif soloSalv then
		-- solo paladin in a group, raid AND party alike: Salvation on everyone.
		-- Tanks are protected by the step-2/3 rules (their classes fall to singles
		-- that skip them, and they receive Kings), pets get the pet blessing
		-- through their owner's class row, and explicit member requests still win
		-- via the step-4 request pass.
		assigned[pallys[1]] = SALVATION
	elseif isRaid and not solo then
		local used = {}
		for i = 1, math.min(#pallys, #RAID_COVERAGE) do
			local blessing = RAID_COVERAGE[i]
			local best, bestScore
			for _, pally in ipairs(pallys) do -- sorted; strict > keeps ties alphabetical
				if not used[pally] and Available(pally, blessing) then
					local score = Score(pally, blessing)
					if not bestScore or score > bestScore then
						best, bestScore = pally, score
					end
				end
			end
			if best then
				used[best] = true
				assigned[best] = blessing
			end
		end
	else
		-- multi-paladin party, or a lone paladin without Salvation (party or
		-- raid): singles economics — each class gets its top castable
		-- preferences, one per paladin (different blessings per class are
		-- fine; one-blessing-per-paladin is a per-target rule)
		for classToken in pairs(classes) do
			local prefs = HO.db.prefs[classToken] or DEFAULT_PREFS[classToken]
			local list = (prefs and prefs.default) or {}
			local usedPally = {}
			local slots = 0
			local info = classes[classToken]
			for _, blessingID in ipairs(list) do
				if slots >= #pallys then
					break
				end
				-- same tank rules as the raid branch: skip Salvation for
				-- all-tank classes, singles when a tank is present
				local mode = "auto"
				local skip = false
				if blessingID == SALVATION and info.tanks > 0 then
					if info.tanks >= info.members then
						skip = true
					else
						mode = "normal"
					end
				end
				if not skip and HO.Data.IsEligible(classToken, blessingID, false) then
					local best, bestScore
					for _, pally in ipairs(pallys) do
						if not usedPally[pally] and Available(pally, blessingID) then
							local score = Score(pally, blessingID)
							if not bestScore or score > bestScore then
								best, bestScore = pally, score
							end
						end
					end
					if best then
						usedPally[best] = true
						slots = slots + 1
						HO.Plan.SetClassAssignment(best, classToken, blessingID, mode)
					end
				end
			end
		end
	end

	-- 2) class assignments from the coverage
	for classToken, info in pairs(classes) do
		for pally, blessing in pairs(assigned) do
			if HO.Data.IsEligible(classToken, blessing, false) then
				local mode = "auto"
				if blessing == SALVATION and info.tanks > 0 then
					if info.tanks >= info.members then
						-- class consists only of tanks: first CASTABLE tank
						-- blessing (a paladin without the Kings talent gives
						-- Light instead of an uncastable Kings); none castable
						-- leaves the class unassigned
						blessing = nil
						for _, id in ipairs(TANK_CHAIN) do
							if HO.Data.IsEligible(classToken, id, true) and Available(pally, id) then
								blessing = id
								break
							end
						end
					else
						mode = "normal" -- singles; the cast engine skips tanks
					end
				end
				if blessing then
					HO.Plan.SetClassAssignment(pally, classToken, blessing, mode)
				end
			end
		end
	end

	-- solo in a group: the PALADIN class is just the solo pally themselves, so
	-- the blanket Salvation from step 2 is self-Salvation — replace it with
	-- the same talent-aware self blessing the ungrouped case uses
	if solo and IsInGroup() then
		AssignSelfBlessing(pallys[1])
	end

	-- which blessings actually reach each class (from ALL paladins' rows)
	local receivedByClass = {}
	for _, pally in ipairs(pallys) do
		local rows = plan.class[pally]
		if rows then
			for classToken, a in pairs(rows) do
				receivedByClass[classToken] = receivedByClass[classToken] or {}
				receivedByClass[classToken][a.id] = true
			end
		end
	end
	local function ClassReceives(classToken, blessingID)
		return receivedByClass[classToken] and receivedByClass[classToken][blessingID] or false
	end

	-- spread auto-overrides across paladins (round-robin) so no single row
	-- grows past the addon-message size cap; deterministic via sorted pally order
	local rrCursor = 0
	local function NextCaster(blessingID, classToken)
		-- first pass: prefer a caster who has NO class-row on the target's own
		-- class that could go greater — a greater re-cast on that class would
		-- wipe the single we are about to place ("normal" mode casts singles and
		-- is safe; auto/greater may cast the class-wide greater)
		for step = 1, #pallys do
			local idx = ((rrCursor + step - 1) % #pallys) + 1
			local pally = pallys[idx]
			if Available(pally, blessingID) then
				local rows = plan.class[pally]
				local a = classToken and rows and rows[classToken]
				if not (a and a.mode ~= "normal") then
					rrCursor = idx
					return pally
				end
			end
		end
		-- fallback: any available caster
		for step = 1, #pallys do
			local idx = ((rrCursor + step - 1) % #pallys) + 1
			if Available(pallys[idx], blessingID) then
				rrCursor = idx
				return pallys[idx]
			end
		end
	end

	-- iterate a name-sorted copy so the round-robin cursor advances in the same
	-- order on every client (party units are player/party1..4, whose order
	-- differs per client and would otherwise diverge the caster selection)
	local sortedUnits = {}
	for _, entry in ipairs(units) do
		sortedUnits[#sortedUnits + 1] = entry
	end
	table.sort(sortedUnits, function(a, b)
		return (a.name or "") < (b.name or "")
	end)

	-- 3) tanks: if no proper tank blessing reaches their class, give them one
	-- as a single — Kings preferred, Light when no caster knows Kings
	for _, entry in ipairs(sortedUnits) do
		if not entry.isPet and entry.name and IsTankEntry(plan, entry) then
			if not ClassReceives(entry.class, KINGS) and not ClassReceives(entry.class, LIGHT)
				and not HasOverrideFor(plan, entry.name) then
				for _, id in ipairs(TANK_CHAIN) do
					local caster = NextCaster(id, entry.class)
					if caster then
						AddAutoOverride(plan, caster, entry.name, id)
						break
					end
				end
			end
		end
	end

	-- 4) per-member preference singles for what the coverage doesn't provide
	for _, entry in ipairs(sortedUnits) do
		if not entry.isPet and entry.name and not IsTankEntry(plan, entry) then
			if soloSalv then
				-- solo mode defaults every non-tank to Salvation, so the default
				-- preference chains must NOT re-override it. Still honor an EXPLICIT
				-- buff request (not the default chain) as a single override, so a
				-- member who asked for something specific gets it instead of Salvation.
				local req = HO.Comm and HO.Comm.requests and HO.Comm.requests[entry.name]
				if type(req) == "table" and not HasOverrideFor(plan, entry.name) then
					for _, pref in ipairs(req) do
						if HO.Data.IsEligible(entry.class, pref, false) then
							local caster = NextCaster(pref, entry.class)
							if caster then
								AddAutoOverride(plan, caster, entry.name, pref)
								break
							end
						end
					end
				end
			elseif not HasOverrideFor(plan, entry.name) then
				-- give the member the best preference they can actually get: walk
				-- the chain in priority order. If the class already receives a
				-- castable higher pref they are satisfied (no override); otherwise
				-- place the first pref some paladin can cast. Only fall to the next
				-- candidate when the current one is neither received nor castable by
				-- anyone. Deterministic: candidates in preference order.
				local prefs = Planner.ResolvePreference(entry.name, entry.class, false)
				for _, pref in ipairs(prefs) do
					if HO.Data.IsEligible(entry.class, pref, false) then
						if ClassReceives(entry.class, pref) then
							break
						end
						local caster = NextCaster(pref, entry.class)
						if caster then
							AddAutoOverride(plan, caster, entry.name, pref)
							break
						end
					end
				end
			end
		end
	end

	-- drop overrides that merely duplicate the class assignment — they would
	-- force needless singles where a greater blessing covers the member
	for pally, targets in pairs(plan.player) do
		local rows = plan.class[pally]
		if rows then
			for target, id in pairs(targets) do
				local entry = HO.Roster.byName[target]
				local a = entry and not entry.isPet and rows[entry.class]
				if a and a.id == id and plan.autoPlayer and plan.autoPlayer[pally]
					and plan.autoPlayer[pally][target] then
					targets[target] = nil
					if plan.autoPlayer and plan.autoPlayer[pally] then
						plan.autoPlayer[pally][target] = nil
					end
				end
			end
		end
	end

	-- summary
	local overrideCount = 0
	if plan.autoPlayer then
		for _, targets in pairs(plan.autoPlayer) do
			for _ in pairs(targets) do
				overrideCount = overrideCount + 1
			end
		end
	end
	local parts = {}
	for _, pally in ipairs(pallys) do
		local blessing = assigned[pally]
		local label
		if blessing then
			label = HO.Data.blessings[blessing].name or HO.Data.blessings[blessing].key
		else
			local n = 0
			if plan.class[pally] then
				for _ in pairs(plan.class[pally]) do
					n = n + 1
				end
			end
			label = n > 0 and (n .. " class singles") or "nothing"
		end
		table.insert(parts, pally .. " > " .. label)
	end
	local summary = table.concat(parts, "; ")
	HO.Log("planner", string.format("run: raid=%s pallys=%d autoOverrides=%d | %s", tostring(isRaid), #pallys, overrideCount, summary))
	return summary
end

-- extending an existing plan to classes that JOIN later ------------------------
-- Pressing Auto is the only thing that ever wrote assignments, so a class
-- arriving afterwards stayed blank until someone pressed it again. This keeps
-- my own row in step: a class that is NEW to the roster inherits the coverage
-- I already give the others. It never touches an existing assignment, never
-- edits foreign rows (every paladin's client extends its own, so the result
-- is the same everywhere without extra messages), and an explicit "none"
-- marker counts as assigned — that stays the way to keep a class unbuffed.

local knownClasses = nil -- nil until the first roster scan primes it
local primeTimer = nil
-- joining a running group (or logging in inside one) must fill the gaps too,
-- not just later joiners — but not before the initial sync has landed, or we
-- would plan against rows that are still arriving
local PRIME_DELAY = 8

-- the blessing this paladin covers classes with: the most common id in their
-- row (lowest id wins a tie, so every client agrees). nil for an empty row.
local function CoverageBlessing(rows)
	local count = {}
	for _, a in pairs(rows or {}) do
		if a.id then
			count[a.id] = (count[a.id] or 0) + 1
		end
	end
	local best, bestCount
	for id, n in pairs(count) do
		if not bestCount or n > bestCount or (n == bestCount and id < best) then
			best, bestCount = id, n
		end
	end
	return best
end

local function PresentClassInfo()
	local classes = {}
	for _, entry in ipairs(HO.Roster.units) do
		if not entry.isPet and entry.class and entry.name then
			local info = classes[entry.class] or { members = 0, tanks = 0 }
			classes[entry.class] = info
			info.members = info.members + 1
			if HO.Plan.IsTank(entry.name, entry.tankRole) then
				info.tanks = info.tanks + 1
			end
		end
	end
	return classes
end

-- assign every present class that `previous` did not contain
local function FillNew(previous)
	local classes = PresentClassInfo()
	local me = HO.FullName("player")
	if not me then
		return
	end
	local plan = HO.Plan.Active()
	local noSalv = HO.Plan.NoSalvationActive() or HO.db.noSalvBy
	local added, seenClass = {}, {}
	-- EVERY paladin row we may edit, not just our own: a paladin without the
	-- addon (or on an older version) never extends their own row, so their
	-- duty for the joiner would stay blank. Each row's blessing is derived
	-- from that row's own coverage, so two clients doing this concurrently
	-- compute the same value and converge instead of fighting.
	for _, pally in ipairs(HO.Roster.Paladins()) do
		if not HO.Comm or HO.Comm.CanEdit(me, pally) then
			local rows = plan.class[pally]
			local coverage = CoverageBlessing(rows)
			if coverage then -- nothing planned for them yet: Auto is the user's move
				for classToken, info in pairs(classes) do
					if not previous[classToken] and rows[classToken] == nil then
						local allTanks = info.tanks >= info.members
						local id = coverage
						-- the same tank rules Auto applies: an all-tank class
						-- never gets Salvation, and the blessing must be
						-- castable for THAT paladin
						if id == SALVATION and allTanks then
							id = nil
							for _, tankID in ipairs(TANK_CHAIN) do
								if HO.Data.IsEligible(classToken, tankID, true) and Available(pally, tankID) then
									id = tankID
									break
								end
							end
						end
						if id and noSalv and id == SALVATION then
							id = Planner.SalvSubstitute(pally, classToken, plan)
						end
						if id and not (HO.Data.IsEligible(classToken, id, allTanks) and Available(pally, id)) then
							id = nil
						end
						if not id then
							-- coverage does not fit: fall back to the class chain,
							-- which contains Salvation for most classes — while
							-- the mode runs it must not sneak back in through a
							-- joiner
							for _, candidate in ipairs(Planner.ResolvePreference(nil, classToken, allTanks)) do
								if not (noSalv and candidate == SALVATION)
									and HO.Data.IsEligible(classToken, candidate, allTanks) and Available(pally, candidate) then
									id = candidate
									break
								end
							end
						end
						if id then
							HO.Plan.SetClassAssignment(pally, classToken, id, "auto")
							if not seenClass[classToken] then
								seenClass[classToken] = true
								added[#added + 1] = classToken
							end
						end
					end
				end
			end
		end
	end
	if #added > 0 then
		table.sort(added)
		HO.Log("planner", "extended coverage to " .. table.concat(added, ", "))
		HO.Announce("new class in the group — assigned " .. table.concat(added, ", "))
		if HO.Window and HO.Window.Refresh then
			HO.Window.Refresh()
		end
		if HO.Bar and HO.Bar.Refresh then
			HO.Bar.Refresh()
		end
	end
end

function Planner.ExtendCoverage()
	if not HO.db or not HO.Roster.units then
		return
	end
	local previous = knownClasses
	knownClasses = {}
	for classToken in pairs(PresentClassInfo()) do
		knownClasses[classToken] = true
	end
	if not previous then
		-- first scan of the session (login, reload, or the addon just loaded):
		-- every present class counts as new once the initial sync has settled,
		-- so joining a running group fills its gaps as well
		if not primeTimer then
			primeTimer = C_Timer.NewTimer(PRIME_DELAY, function()
				primeTimer = nil
				FillNew({})
			end)
		end
		return
	end
	if primeTimer then
		return -- still settling; the delayed pass covers everything present
	end
	FillNew(previous)
end

HO.Roster.OnChanged(Planner.ExtendCoverage)

function Planner.Run()
	-- a re-plan would assign Salvation again and desync the holder's snapshot:
	-- the encounter mode must be reverted before auto is allowed to run
	if HO.Plan.NoSalvationActive() or (HO.db and HO.db.noSalvBy) then
		return false, "no-Salvation mode is active — revert it first (No Salv button or /ho nosalv)"
	end
	local pallys = HO.Roster.Paladins()
	if #pallys == 0 then
		return false, "no paladins in the roster"
	end
	-- bulk edit: individual SETs are suppressed while the plan is computed;
	-- the suspension is error-safe (a stuck flag would silently kill ALL
	-- outgoing sync), and the finished plan broadcasts atomically
	if HO.Comm then
		HO.Comm.suspended = true
	end
	local ok, summary = pcall(RunCore, pallys)
	if HO.Comm then
		HO.Comm.suspended = false
	end
	if not ok then
		HO.Log("error", "planner: " .. tostring(summary))
		return false, "internal error (logged)"
	end
	if HO.Comm then
		if HO.Comm.SendPlanApply() then
			HO.Announce(HO.L["plan broadcast to the group"])
		elseif IsInGroup() then
			-- non-leads cannot broadcast the whole plan; their own row is
			-- still authoritative and syncs
			HO.Comm.BroadcastOwnRow()
			-- the local re-plan rewrote every paladin's row at unchanged revisions,
			-- so the foreign rows are now wrong locally; ask each owner to re-send
			-- their authoritative row (answered via random-delayed whisper)
			HO.Comm.RequestSync()
			HO.Print(HO.L["plan is local — only your own assignments sync (lead/assist can broadcast all)"])
		end
	end
	return true, summary
end

-- first-blessing onboarding ---------------------------------------------------
-- A levelling paladin with an empty plan never sees the cast bar, so the addon
-- stays invisible until someone opens the window. The moment the FIRST blessing
-- is learned (never again after that, and never at login) that blessing goes on
-- the paladin's own class row, plus the first known aura when none is set, so
-- the bar appears and can be tried right away.

local LEARN_SETTLE = 0.5 -- seconds for the spellbook to include the new spell

local function HasOwnDuties(plan, me)
	for _, assign in pairs(plan.class[me] or {}) do
		if assign.id then
			return true
		end
	end
	return next(plan.player[me] or {}) ~= nil
end

local function OnFirstBlessing(spellName)
	if select(2, UnitClass("player")) ~= "PALADIN" then
		return
	end
	HO.Data.Refresh()
	local known = HO.Data.KnownBlessings()
	if #known ~= 1 or HO.Data.blessings[known[1]].name ~= spellName then
		return -- not the first blessing, or not a blessing at all
	end
	local me = HO.FullName("player")
	local plan = HO.Plan.Active()
	if not me or HasOwnDuties(plan, me) then
		return
	end
	local blessingID = known[1]
	HO.Plan.SetClassAssignment(me, "PALADIN", blessingID, "auto")
	local auras = HO.Data.KnownAuras()
	if not HO.Plan.GetAura(me) and auras[1] then
		HO.Plan.SetAura(me, auras[1])
	end
	HO.Log("planner", "first blessing learned: assigned " .. tostring(spellName) .. " to self")
	HO.Print(string.format(HO.L["you learned %s — it is now assigned to yourself; click the cast bar to use it"], spellName))
	if HO.Bar and HO.Bar.Refresh then
		HO.Bar.Refresh()
	end
	if HO.Window and HO.Window.Refresh then
		HO.Window.Refresh()
	end
end

if HO.Compat.EventExists("LEARNED_SPELL_IN_SKILL_LINE") then
	HO.RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", function(spellID)
		local spellName = spellID and HO.Compat.SpellNameIcon(spellID)
		if spellName then
			C_Timer.After(LEARN_SETTLE, function()
				OnFirstBlessing(spellName)
			end)
		end
	end)
end
