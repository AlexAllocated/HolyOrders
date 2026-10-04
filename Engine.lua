-- HolyOrders — cast engine (what do I cast next, per class duty?)
-- Pure computation: scans buffs on my assigned targets and picks the next
-- target and spell per class. No secure frames here; the bar consumes tasks.

local HO = HolyOrders
local Engine = {}
HO.Engine = Engine

local EXPIRING_SOON = 300 -- seconds left that count as "needs a refresh"
local SALVATION = 4
local FRESH_AGE = 120 -- force mode: buffs older than this are re-cast
local FORCE_DURATION = 300 -- force mode safety timeout

Engine.tasks = {} -- [classToken] = task table, built in Update()
-- Per-member status and eligible single-target actions, consumed by the bar.
-- blessingID describes the assignment; castBlessingID applies the tank rule.
-- [classToken] = { {name, unit, isPet, owner, blessingID, hasBuff, inRange}, ... }
Engine.classMembers = {}
Engine.forceUntil = nil

-- force-rebuff sweep: pre-pull refresh of everything that is not fresh;
-- ends automatically when all assigned buffs are fresh, or after timeout
function Engine.StartForceRebuff()
	Engine.forceUntil = GetTime() + FORCE_DURATION
	HO.Log("engine", "force rebuff started")
end

function Engine.StopForceRebuff()
	Engine.forceUntil = nil
	HO.Log("engine", "force rebuff stopped")
end

function Engine.ForceActive()
	if Engine.forceUntil then
		if GetTime() < Engine.forceUntil then
			return true
		end
		Engine.forceUntil = nil
	end
	return false
end

-- a member's top-ranked buff request (highest priority), or nil. requests are an
-- ordered list; the cast bar / fly-out badge shows only the first
local function TopRequest(name)
	local r = HO.Comm and HO.Comm.requests[name]
	return (type(r) == "table") and r[1] or nil
end

-- which blessing target `entry` should get from me: override wins, then the
-- class assignment
-- is this pet buffed at all, per the owner-class settings?
local function PetIncluded(entry)
	local petOpts = HO.db.options.pets or {}
	local ownerEntry = entry.owner and HO.Roster.byName[entry.owner]
	local ownerClass = ownerEntry and ownerEntry.class
	if ownerClass == "HUNTER" then
		return petOpts.hunter ~= false
	end
	if ownerClass == "WARLOCK" then
		return petOpts.warlock == true
	end
	-- only hunter and warlock pets are permanent companions worth buffing;
	-- everything else (shadowfiend, water elemental, …) is temporary
	return false
end
Engine.PetIncluded = PetIncluded

-- is the requested blessing covered by ANY paladin's plan for this member?
-- A wish someone is already assigned to fulfil is handled — keeping it marked
-- outstanding on every other paladin's fly-out until the buff physically
-- lands (and again whenever it expires) is noise. Overrides count always;
-- a class row counts unless it is Salvation onto a tank, which the cast
-- engine deliberately never delivers.
local function PlanCoversRequest(plan, entry, reqID)
	for pally, targets in pairs(plan.player) do
		if targets[entry.name] == reqID and HO.Roster.byName[pally] then
			return true
		end
	end
	if entry.class and not (reqID == SALVATION and HO.Plan.IsTank(entry.name, entry.tankRole)) then
		for pally, rows in pairs(plan.class) do
			local a = rows[entry.class]
			if a and a.id == reqID and HO.Roster.byName[pally] then
				return true
			end
		end
	end
	return false
end

-- the deterministic pet-blessing split: every paladin covering the pet
-- OWNER's class takes one slot of a ranked list (the configured pet blessing,
-- then Kings, then Might — and Wisdom on pets that actually run on mana), so
-- several paladins stack blessings instead of all duplicating the same one.
-- Ties use sorted paladin names and the shared capability checks, so every
-- client computes the same split. Returns name-ordered { { pally, id or nil }, ... };
-- a nil id means that paladin has no pet duty (more coverers than blessings).
function Engine.PetSplit(entry)
	local plan = HO.Plan.Active()
	local ownerEntry = entry.owner and HO.Roster.byName[entry.owner]
	local ownerClass = ownerEntry and ownerEntry.class
	if not ownerClass then
		return {}
	end
	local covering = {}
	for pally, rows in pairs(plan.class) do
		local a = rows[ownerClass]
		-- a none-marked owner class (no id) is not a real assignment: its
		-- pets are nobody's duty; leavers' stale rows must not hold a slot
		if a and a.id and HO.Roster.byName[pally] then
			table.insert(covering, pally)
		end
	end
	table.sort(covering)
	local petOpts = HO.db.options.pets
	local list, seen = {}, {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	add((petOpts and petOpts.blessing) or 2)
	add(3) -- Kings
	add(2) -- Might
	if entry.unit and UnitPowerType(entry.unit) == 0 then
		add(1) -- Wisdom, only for pets that actually run on mana
	end
	-- Find a matching in blessing priority order. Moving an earlier duty to
	-- another capable caster can free the only Kings caster without dropping
	-- the configured first blessing. Sorted names make ties deterministic.
	local duties = {}
	local function place(id, visited)
		-- Prefer a free caster before rearranging an earlier duty.
		for pass = 1, 2 do
			for _, pally in ipairs(covering) do
				if (duties[pally] == nil) == (pass == 1) and not visited[pally]
					and HO.Planner.IsAvailable(pally, id) then
					visited[pally] = true
					if not duties[pally] or place(duties[pally], visited) then
						duties[pally] = id
						return true
					end
				end
			end
		end
		return false
	end
	for _, id in ipairs(list) do place(id, {}) end
	local split = {}
	for i, pally in ipairs(covering) do
		split[i] = { pally = pally, id = duties[pally] }
	end
	return split
end

local function TargetBlessing(plan, me, entry)
	local overrides = plan.player[me]
	local override = overrides and entry.name and overrides[entry.name]
	if override then
		-- an override identical to the class assignment is redundant: treat
		-- the member as a class-wide target so greater blessings stay possible
		local assigns = plan.class[me]
		local assign = assigns and entry.class and assigns[entry.class]
		if assign and not entry.isPet and assign.id == override
			and HO.Data.IsAllowed(override, HO.Plan.IsTank(entry.name, entry.tankRole)) then
			return assign.id, false
		end
		return override, true
	end
	if entry.isPet then
		-- pets are the duty of whoever covers the OWNER's class (a hunter's pet
		-- is the hunter-coverer's duty; the pet's own pseudo-class may have no
		-- player row at all); see Engine.PetSplit for the stacking rule
		if not PetIncluded(entry) then
			return nil, false
		end
		for _, duty in ipairs(Engine.PetSplit(entry)) do
			if duty.pally == me then
				return duty.id, false
			end
		end
		return nil, false
	end
	local assigns = plan.class[me]
	local assign = assigns and entry.class and assigns[entry.class]
	-- an explicit-none assignment (no id) yields no blessing, exactly like an
	-- unassigned class: its members are not my targets
	if assign and assign.id then
		return assign.id, false
	end
	return nil, false
end

local function HasBlessing(unit, blessingID)
	local blessing = HO.Data.blessings[blessingID]
	if not blessing then
		return false, nil
	end
	local found, duration, expirationTime = HO.Compat.FindBuff(unit, blessing.name, blessing.greaterName)
	if not found then
		return false, nil, nil
	end
	if expirationTime and expirationTime > 0 then
		return true, expirationTime - GetTime(), duration
	end
	return true, nil, nil
end

local function Castable(entry)
	return entry.online and not UnitIsDeadOrGhost(entry.unit) and UnitIsVisible(entry.unit)
end

local function InCastRange(blessing, unit)
	local result = HO.Compat.SpellInRange(blessing.name, unit)
	if result == nil then
		return true -- indeterminate: do not block the rotation
	end
	return result
end

local function UseGreater(assign, eligiblePlayers)
	local blessing = HO.Data.blessings[assign.id]
	if not blessing or not blessing.greaterKnown then
		return false
	end
	if HO.Data.SymbolCount() == 0 then
		return false -- no Symbol of Kings: fall back to singles automatically
	end
	if assign.mode == "greater" then
		return true
	end
	if assign.mode == "normal" then
		return false
	end
	-- auto: greater from N members; N=1 when the user prefers the 30-min
	-- duration over saving symbols
	return eligiblePlayers >= (HO.db.options.greaterMin or 2)
end

-- the engine's actual greater-vs-singles verdict per class for MY duty, so the
-- window tooltip can show what the bar will really cast (nil: not my duty)
local greaterVerdict = {}

function Engine.WouldUseGreater(classToken)
	return greaterVerdict[classToken]
end

function Engine.ClassMembers(classToken)
	return Engine.classMembers[classToken] or {}
end

-- Build secure actions from assignments, not from whichever task happens to
-- be next. A combat cycle uses singles when a greater would erase an override
-- or hit a member excluded by the tank rule.
function Engine.ClassActions(classToken)
	local me = HO.FullName("player")
	local rows = HO.Plan.Active().class[me]
	local assign = rows and rows[classToken]
	local blessing = assign and HO.Data.blessings[assign.id]
	local members = Engine.ClassMembers(classToken)
	local safeGreater = blessing and blessing.greaterKnown and blessing.greaterName
		and HO.Data.SymbolCount() > 0
	local anchor
	for _, member in ipairs(members) do
		if not member.isPet then
			if not assign or member.isOverride or member.castBlessingID ~= assign.id then
				safeGreater = false
			elseif member.unit and not anchor then
				anchor = member.unit
			end
		end
	end
	local actions = { cycle = {} }
	if anchor and blessing then
		actions.rightSpell = safeGreater and blessing.greaterName or blessing.name
		actions.rightUnit = anchor
		actions.rightIsGreater = safeGreater and true or false
	end
	local useGreater = safeGreater and Engine.WouldUseGreater(classToken)
	for _, member in ipairs(members) do
		local single = member.castBlessingID and HO.Data.blessings[member.castBlessingID]
		local target = member.isPet and member.unit or member.name
		if single and single.name and target then
			local spell = (useGreater and not member.isPet) and blessing.greaterName or single.name
			actions.cycle[#actions.cycle + 1] = { target = target, spell = spell }
			if not actions.rightSpell then
				actions.rightSpell, actions.rightUnit = single.name, member.unit
			end
		end
	end
	return actions
end

function Engine.Update()
	wipe(Engine.tasks)
	wipe(greaterVerdict)
	wipe(Engine.classMembers)
	local plan = HO.Plan.Active()
	local me = HO.FullName("player")
	if not me then
		return
	end

	-- pool my targets by class; also note which classes contain tanks
	local pools = {} -- [classToken] = { {entry, blessingID, isOverride}, ... }
	local classTanks = {} -- [classToken] = true when a tank is present
	for _, entry in ipairs(HO.Roster.units) do
		-- pets pass without an own class: an out-of-range pet reports none,
		-- and everything below uses the OWNER's class for pets anyway
		if entry.name and entry.unit and (entry.class or entry.isPet) then
			local isTank = HO.Plan.IsTank(entry.name, entry.tankRole)
			if isTank and not entry.isPet then
				classTanks[entry.class] = true
			end
			local blessingID, isOverride = TargetBlessing(plan, me, entry)
			-- pets group under their OWNER's class button; player eligibility
			-- rules do not apply to pets
			local poolClass = entry.class
			if entry.isPet then
				local ownerEntry = entry.owner and HO.Roster.byName[entry.owner]
				poolClass = (ownerEntry and ownerEntry.class) or entry.class
			end
			if poolClass then
				-- display row for the fly-out: every member is listed (even with no
				-- assigned blessing); castBlessingID separately records eligibility,
				-- and hasBuff/inRange are filled below for pooled members.
				-- display-only: the member's top-ranked buff request (nil for pets,
				-- which never send requests); never affects a cast
				local reqID = TopRequest(entry.name)
				local eligible = blessingID and blessingID > 0
					and (isOverride or entry.isPet or HO.Data.IsAllowed(blessingID, isTank))
				local member = {
					name = entry.name,
					unit = entry.unit,
					isPet = entry.isPet or nil,
					owner = entry.owner,
					blessingID = (blessingID and blessingID > 0) and blessingID or nil,
					castBlessingID = eligible and blessingID or nil,
					isOverride = isOverride,
					requestID = reqID,
					-- does the member already HAVE the requested blessing, from ANY
					-- paladin? (feeds the fly-out badge tint; per-paladin comparisons
					-- would mislead when someone else fulfils the wish)
					requestSatisfied = (reqID and (HasBlessing(entry.unit, reqID)
					or PlanCoversRequest(plan, entry, reqID))) or nil,
				}
				Engine.classMembers[poolClass] = Engine.classMembers[poolClass] or {}
				table.insert(Engine.classMembers[poolClass], member)
				if blessingID and blessingID > 0 then
					-- class rows may hold any blessing the user chose; only the
					-- hard tank rule (no Salvation) filters members out
					if eligible then
						pools[poolClass] = pools[poolClass] or {}
						-- keep the display row so the buff/range check below fills it in
						table.insert(pools[poolClass], { entry = entry, blessingID = blessingID, isOverride = isOverride, member = member })
					end
			end
			end
		end
	end

	for classToken, pool in pairs(pools) do
		local assign = plan.class[me] and plan.class[me][classToken]
		-- count only members that can actually be cast on (online, alive,
		-- visible) so the greater-vs-single decision matches reality
		local eligiblePlayers = 0
		for _, item in ipairs(pool) do
			if not item.isOverride and not item.entry.isPet and Castable(item.entry) then
				eligiblePlayers = eligiblePlayers + 1
			end
		end
		local greater = assign and UseGreater(assign, eligiblePlayers) or false
		-- hard guard: never resolve to greater Salvation over a class that
		-- contains a tank (the greater hits the whole class) — unless the
		-- mode was explicitly forced to greater by the user
		if greater and assign and assign.id == SALVATION and classTanks[classToken] and assign.mode ~= "greater" then
			greater = false
		end
		if assign then
			greaterVerdict[classToken] = greater
		end

		local force = Engine.ForceActive()
		-- class-wide targets before override/pet singles: a greater cast
		-- replaces this paladin's own singles on the whole class ("one
		-- blessing per paladin"), so it must always happen first
		local missingClass, missingSingles, expiring, minRemaining = {}, {}, {}, nil
		local outOfRange = 0
		for _, item in ipairs(pool) do
			local has, remaining, duration = HasBlessing(item.entry.unit, item.blessingID)
			item.remaining = remaining
			local blessing = HO.Data.blessings[item.blessingID]
			item.inRange = blessing and InCastRange(blessing, item.entry.unit)
			-- feed the fly-out's live green/red status + timer from the same check
			if item.member then
				item.member.hasBuff = has
				item.member.inRange = item.inRange
				item.member.remaining = remaining -- seconds left on the blessing, or nil
			end
			if not has then
				if Castable(item.entry) then
					if not item.inRange then
						outOfRange = outOfRange + 1
					end
					if item.isOverride or item.entry.isPet then
						table.insert(missingSingles, item)
					else
						table.insert(missingClass, item)
					end
				end
			elseif remaining then
				if not minRemaining or remaining < minRemaining then
					minRemaining = remaining
				end
				local stale = force and duration and duration > 0 and (duration - remaining) > FRESH_AGE
				if (remaining < EXPIRING_SOON or stale) and Castable(item.entry) then
					table.insert(expiring, item)
				end
			end
		end
		table.sort(expiring, function(a, b)
			-- when this class refreshes via a greater cast, that cast wipes this
			-- paladin's own singles across the whole class — so class-wide items
			-- must refresh before any override/pet single the greater would
			-- immediately erase; within each group keep the by-remaining order
			if greater then
				local aSingle = a.isOverride or a.entry.isPet
				local bSingle = b.isOverride or b.entry.isPet
				if aSingle ~= bSingle then
					return not aSingle
				end
			end
			return (a.remaining or 0) < (b.remaining or 0)
		end)

		-- unreachable members never block the rotation; for greater casts a
		-- nearby anchor covers out-of-range class members anyway
		local function FirstInRange(list)
			for _, item in ipairs(list) do
				if item.inRange then
					return item
				end
			end
		end

		local missingCount = #missingClass + #missingSingles
		-- in-range items across all three work lists; out-of-range members can
		-- never be cast on, so only reachable work may keep a sweep alive
		local reachable = 0
		for _, list in ipairs({ missingClass, missingSingles, expiring }) do
			for _, item in ipairs(list) do
				if item.inRange then
					reachable = reachable + 1
				end
			end
		end
		-- while a greater cast on this class is still pending, do NOT fall
		-- through to override singles on members of the class — the greater
		-- would immediately wipe them (M4)
		local nextItem
		if greater and #missingClass > 0 then
			nextItem = FirstInRange(missingClass) or FirstInRange(expiring)
		else
			nextItem = FirstInRange(missingClass) or FirstInRange(missingSingles) or FirstInRange(expiring)
		end
		if nextItem then
			local blessing = HO.Data.blessings[nextItem.blessingID]
			-- greater only for class-wide targets of the class blessing; pets
			-- and overrides always get singles
			local castGreater = greater and not nextItem.isOverride and not nextItem.entry.isPet
				and assign and nextItem.blessingID == assign.id
			Engine.tasks[classToken] = {
				classToken = classToken,
				blessingID = nextItem.blessingID,
				spellName = castGreater and blessing.greaterName or blessing.name,
				-- right-click alternative: always the 10-min single
				singleSpellName = blessing.name,
				unit = nextItem.entry.unit,
				unitName = nextItem.entry.name,
				missing = missingCount,
				expiring = #expiring,
				outOfRange = outOfRange,
				minRemaining = minRemaining,
				icon = blessing.icon,
				reachable = reachable,
				-- pool fed solely by overrides (no class-wide assignment)
				overrideOnly = (assign == nil) and true or nil,
			}
		else
			-- nothing castable right now (all covered, or the needy ones are
			-- out of range); passive display task keeps the counts honest
			local displayID = assign and assign.id or pool[1].blessingID
			local blessing = HO.Data.blessings[displayID]
			Engine.tasks[classToken] = {
				classToken = classToken,
				blessingID = displayID,
				spellName = nil,
				unit = nil,
				unitName = nil,
				missing = missingCount,
				expiring = #expiring,
				outOfRange = outOfRange,
				minRemaining = minRemaining,
				icon = blessing and blessing.icon,
				reachable = reachable,
				overrideOnly = (assign == nil) and true or nil,
			}
		end
	end

	-- placeholder tasks for classes I explicitly set to "none": keep a visible,
	-- re-assignable slot (with a "no blessing" icon) instead of dropping the
	-- button, but only where the class actually has a non-pet member present.
	-- Nothing is castable, so no spellName/unit/blessingID — consumers must guard
	-- on noneAssigned / nil blessingID. Skip a class that already produced a real
	-- task (e.g. a lingering member override) so we never clobber castable work.
	local myRows = plan.class[me]
	if myRows then
		local classHasMember = {}
		for _, entry in ipairs(HO.Roster.units) do
			if entry.name and entry.class and not entry.isPet then
				classHasMember[entry.class] = true
			end
		end
		for classToken, assign in pairs(myRows) do
			if assign and assign.none and classHasMember[classToken] and not Engine.tasks[classToken] then
				Engine.tasks[classToken] = {
					classToken = classToken,
					noneAssigned = true,
					missing = 0,
					expiring = 0,
					outOfRange = 0,
					icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
				}
			end
		end
	end

	-- force-rebuff sweep ends itself once every assigned buff is fresh
	if Engine.forceUntil and Engine.ForceActive() then
		local pending = false
		for _, task in pairs(Engine.tasks) do
			-- only reachable (in-range) work keeps the sweep alive; unreachable
			-- members would otherwise pin it until the timeout
			if (task.reachable or 0) > 0 then
				pending = true
				break
			end
		end
		if not pending then
			Engine.forceUntil = nil
			HO.Log("engine", "force rebuff complete")
			HO.Announce(HO.L["force rebuff complete — all assigned buffs are fresh"])
		end
	end
end
