-- HolyOrders — blessing plan model and per-roster persistence
-- The active plan is what gets edited and cast from; it persists across
-- reloads. Stored plans are keyed by the sorted paladin roster: an exact
-- roster match re-applies automatically, a similar roster is suggested.

local HO = HolyOrders
local Plan = {}
HO.Plan = Plan
local function L(key)
	return (HO.L or {})[key] or key
end

Plan.MAX_STORED = 20 -- unnamed plans beyond this are pruned (oldest first)
Plan.SUGGEST_THRESHOLD = 0.5 -- min paladin-set overlap for a suggestion

local VALID_MODES = { auto = true, greater = true, normal = true }
local pendingArrivals = {}

function Plan.CancelArrivals(paladin)
	if paladin then pendingArrivals[paladin] = nil
	else wipe(pendingArrivals) end
end

local function NewPlan()
	return {
		version = 1,
		class = {}, -- [paladinName][classToken] = { id, mode }
		player = {}, -- [paladinName][targetName] = blessingID
		aura = {}, -- [paladinName] = auraID (which aura that paladin runs)
		tanks = {}, -- [characterName] = true (roster-scoped, per spec)
		meta = { created = time() },
	}
end

local function Copy(value)
	if type(value) ~= "table" then
		return value
	end
	local t = {}
	for k, v in pairs(value) do
		t[k] = Copy(v)
	end
	return t
end

-- signatures -----------------------------------------------------------------

function Plan.Signature(paladins)
	return table.concat(paladins, ";")
end

function Plan.CurrentSignature()
	return Plan.Signature(HO.Roster.Paladins())
end

local function SetFromSignature(sig)
	local set = {}
	for name in string.gmatch(sig, "[^;]+") do
		set[name] = true
	end
	return set
end

local function Jaccard(setA, setB)
	local inter, union = 0, 0
	for k in pairs(setA) do
		union = union + 1
		if setB[k] then
			inter = inter + 1
		end
	end
	for k in pairs(setB) do
		if not setA[k] then
			union = union + 1
		end
	end
	if union == 0 then
		return 0
	end
	return inter / union
end

-- active plan ----------------------------------------------------------------

function Plan.Active()
	if not HO.db.activePlan then
		HO.db.activePlan = NewPlan()
	end
	-- normalize: plans written by other addon versions must never nil-error
	local plan = HO.db.activePlan
	plan.class = plan.class or {}
	plan.player = plan.player or {}
	plan.aura = plan.aura or {}
	plan.tanks = plan.tanks or {}
	plan.meta = plan.meta or { created = time() }
	return plan
end

local function MarkDirty(plan)
	plan.meta = plan.meta or {}
	plan.meta.dirty = true
end

function Plan.SetClassAssignment(paladin, classToken, blessingID, mode, arrival)
	if not arrival or pendingArrivals[paladin] ~= arrival then Plan.CancelArrivals(paladin) end
	local plan = Plan.Active()
	plan.class[paladin] = plan.class[paladin] or {}
	if blessingID == 0 then
		plan.class[paladin][classToken] = nil
	else
		if mode == nil then
			-- a plain blessing switch keeps the cell's cast mode: a deliberately
			-- chosen "always greater/normal" must survive picking another blessing
			local existing = plan.class[paladin][classToken]
			mode = existing and existing.mode
		end
		if not VALID_MODES[mode or "auto"] then
			mode = "auto"
		end
		plan.class[paladin][classToken] = { id = blessingID, mode = mode or "auto" }
	end
	MarkDirty(plan)
	if HO.Comm then
		HO.Comm.OnClassEdited(paladin, classToken)
	end
	if HO.Interop then
		HO.Interop.OnLocalPlanChanged(paladin)
	end
end

-- explicit "none" for a class: a placeholder marker (no id) that keeps a visible,
-- re-assignable slot instead of removing the duty. Local-only — it serializes as
-- absence (unassigned) on the wire, so peers treat the class as cleared.
function Plan.SetClassNone(paladin, classToken)
	Plan.CancelArrivals(paladin)
	local plan = Plan.Active()
	plan.class[paladin] = plan.class[paladin] or {}
	plan.class[paladin][classToken] = { none = true }
	MarkDirty(plan)
	if HO.Comm then
		HO.Comm.OnClassEdited(paladin, classToken)
	end
	if HO.Interop then
		HO.Interop.OnLocalPlanChanged(paladin)
	end
end

-- which aura a paladin runs (0/nil clears). Mirrors SetClassAssignment: writes
-- the plan, marks it dirty and notifies Comm (nil-safe) for a live broadcast.
function Plan.SetAura(paladin, auraID)
	local plan = Plan.Active()
	if not auraID or auraID == 0 then
		plan.aura[paladin] = nil
	else
		plan.aura[paladin] = auraID
	end
	MarkDirty(plan)
	if HO.Comm then
		HO.Comm.OnAuraEdited(paladin)
	end
end

function Plan.GetAura(paladin)
	if not paladin then
		return nil
	end
	local plan = Plan.Active()
	return plan.aura and plan.aura[paladin] or nil
end

function Plan.SetPlayerOverride(paladin, targetName, blessingID)
	Plan.CancelArrivals(paladin)
	local plan = Plan.Active()
	-- The planner explicitly marks its own writes after calling this setter.
	-- A later deliberate edit must no longer be cleared by Auto.
	if plan.autoPlayer and plan.autoPlayer[paladin] then
		plan.autoPlayer[paladin][targetName] = nil
	end
	plan.player[paladin] = plan.player[paladin] or {}
	if blessingID == 0 then
		plan.player[paladin][targetName] = nil
	else
		plan.player[paladin][targetName] = blessingID
	end
	MarkDirty(plan)
	if HO.Comm then
		HO.Comm.OnOverrideEdited(paladin, targetName)
	end
	if HO.Interop then
		HO.Interop.OnLocalPlanChanged(paladin)
	end
end

-- persistent per-member blessing liking, remembered by character name and
-- independent of any paladin pairing. This is NOT plan state (never marks the
-- plan dirty); it feeds the auto-planner's preference chain and syncs on its own.
function Plan.SetMemberPref(name, blessingID)
	if not name or not HO.db then
		return
	end
	HO.db.memberPrefs = HO.db.memberPrefs or {}
	local newID = (blessingID and blessingID ~= 0) and blessingID or nil
	if HO.db.memberPrefs[name] == newID then
		return -- unchanged: nothing to store or announce
	end
	HO.db.memberPrefs[name] = newID
	if HO.Comm and HO.Comm.OnMemberPrefChanged then
		HO.Comm.OnMemberPrefChanged(name, newID)
	end
end

function Plan.MemberPref(name)
	if not name or not HO.db or not HO.db.memberPrefs then
		return nil
	end
	return HO.db.memberPrefs[name]
end

function Plan.ToggleTank(name)
	-- gate here too so no future caller can bypass the tank-flag permission
	-- (nil-safe when Comm is not loaded)
	if HO.Comm and HO.Comm.CanFlagTank and not HO.Comm.CanFlagTank(name) then
		return nil
	end
	local plan = Plan.Active()
	-- flip the EFFECTIVE state and store it explicitly: toggling off someone
	-- who is tank-by-role-icon or tank-by-spec records `false`, which
	-- overrides those derived sources (otherwise such a tank could never be
	-- unmarked at all)
	local entry = HO.Roster.byName and HO.Roster.byName[name]
	local flagged = not Plan.IsTank(name, entry and entry.tankRole)
	plan.tanks[name] = flagged
	MarkDirty(plan)
	if HO.Comm then
		HO.Comm.OnTankToggled(name, flagged)
	end
	return flagged
end

-- is this character a tank for planning purposes? Explicit mark (either
-- direction) wins; otherwise raid MAINTANK role, party tank role, local
-- protection spec tag, or the synced spec overlay (so every client computes
-- the same tank set even when their inspect results diverge).
function Plan.IsTank(name, tankRole)
	local manual = name and Plan.Active().tanks[name]
	if manual ~= nil then
		return manual -- explicit mark: true = tank, false = never a tank
	end
	if tankRole then
		return true -- raid MAINTANK role
	end
	if name and HO.db.specCache[name] == "protection" then
		return true -- local spec tag (manual or inspect-inferred)
	end
	if name and HO.Comm and HO.Comm.specSync[name] == "protection" then
		return true -- synced overlay from another client
	end
	return false
end

-- temporary no-Salvation mode -------------------------------------------------
-- For encounters with random aggro: swaps every Salvation assignment for a
-- substitute and remembers the previous plan; disabling restores it exactly.

local SALVATION = 4

function Plan.NoSalvationActive()
	return HO.db.salvSnapshot ~= nil
end

function Plan.SetNoSalvation(enable)
	Plan.CancelArrivals()
	if enable then
		-- never overwrite an existing snapshot (F2): two leads racing must not
		-- snapshot each other's already-swapped plan
		if HO.db.salvSnapshot then
			return false, "already active"
		end
		local plan = Plan.Active()
		-- nothing to swap → do nothing, so a race cannot snapshot an already
		-- Salvation-free plan and then be unable to restore Salvation (F1)
		local hasSalv = false
		for _, rows in pairs(plan.class) do
			for _, a in pairs(rows) do
				if a.id == SALVATION then
					hasSalv = true
					break
				end
			end
			if hasSalv then
				break
			end
		end
		if not hasSalv then
			for _, targets in pairs(plan.player) do
				for _, id in pairs(targets) do
					if id == SALVATION then
						hasSalv = true
						break
					end
				end
				if hasSalv then
					break
				end
			end
		end
		if not hasSalv then
			return false, "no Salvation assignments to swap"
		end
		HO.db.salvSnapshot = Copy(plan)
		-- the only member of a class: their requests and remembered liking can
		-- decide that class's substitute, since nobody else receives it
		local function LoneMember(classToken)
			local found
			for _, entry in ipairs(HO.Roster.units) do
				if not entry.isPet and entry.class == classToken and entry.name then
					if found then
						return nil -- more than one member: no personal wish applies
					end
					found = entry.name
				end
			end
			return found
		end
		local changed = 0
		for pally, rows in pairs(plan.class) do
			for classToken, a in pairs(rows) do
				if a.id == SALVATION then
					local sub = HO.Planner.SalvSubstitute(pally, classToken, plan, LoneMember(classToken))
					if sub then
						a.id = sub
					else
						rows[classToken] = nil
					end
					changed = changed + 1
				end
			end
		end
		for pally, targets in pairs(plan.player) do
			for target, id in pairs(targets) do
				if id == SALVATION then
					-- a per-member Salvation was dropped outright, leaving that
					-- member unbuffed for the encounter; substitute by their own
					-- wishes instead (nil only when nothing at all fits)
					local entry = HO.Roster.byName[target]
					targets[target] = HO.Planner.SalvSubstitute(pally, entry and entry.class, plan, target)
					changed = changed + 1
				end
			end
		end
		HO.Log("plan", "no-salvation enabled, " .. changed .. " swapped")
		return true, changed
	end
	if not HO.db.salvSnapshot then
		return false, "not active"
	end
	local restored = HO.db.salvSnapshot
	-- keep revisions monotonic so the restore propagates over the swap
	restored.rev = Copy(Plan.Active().rev or {})
	HO.db.activePlan = restored
	HO.db.salvSnapshot = nil
	HO.Log("plan", "no-salvation reverted")
	return true
end

-- storage --------------------------------------------------------------------

local function CountStored()
	local n = 0
	for _ in pairs(HO.db.plans) do
		n = n + 1
	end
	return n
end

local function Prune()
	while CountStored() > Plan.MAX_STORED do
		local oldestSig, oldestTime
		for sig, plan in pairs(HO.db.plans) do
			if not plan.meta.name then -- named plans are never pruned
				local used = plan.meta.lastUsed or plan.meta.created or 0
				if not oldestTime or used < oldestTime then
					oldestSig, oldestTime = sig, used
				end
			end
		end
		if not oldestSig then
			return -- everything is named; accept exceeding the cap
		end
		HO.db.plans[oldestSig] = nil
	end
end

function Plan.Save(label)
	local sig = Plan.CurrentSignature()
	if sig == "" then
		return nil
	end
	local stored = Copy(Plan.Active())
	stored.rev = nil -- stored plans never carry revision state
	stored.meta.lastUsed = time()
	stored.meta.dirty = nil
	if label and label ~= "" then
		stored.meta.name = label
	end
	HO.db.plans[sig] = stored
	HO.db.activeSignature = sig
	Plan.Active().meta.dirty = nil -- saved: no unsaved edits anymore
	Prune()
	HO.Log("plan", "saved plan for " .. sig .. (label and label ~= "" and (" as '" .. label .. "'") or ""))
	return sig
end

-- pre-planning: expected paladins --------------------------------------------
-- Paladins announced for later ("two more palas after the break") can be
-- assigned before they join: their rows are ordinary plan rows (editable by
-- the usual permission rules — an absent paladin has no consent flag — saved
-- with the plan, and pushed to legacy clients once they arrive). The expected
-- list only adds window columns and drives the arrival handling below.

local ARRIVAL_REASSERT_DELAY = 6 -- seconds; an arriving client has announced its own row by then

-- expected paladins who are still absent, sorted (window columns)
function Plan.Expected()
	local list = {}
	for name in pairs((HO.db and HO.db.expected) or {}) do
		if not HO.Roster.byName[name] then
			list[#list + 1] = name
		end
	end
	table.sort(list)
	return list
end

-- add/remove an expected paladin; returns true when added
function Plan.ToggleExpected(name)
	HO.db.expected = HO.db.expected or {}
	if HO.db.expected[name] then
		HO.db.expected[name] = nil
		return false
	end
	HO.db.expected[name] = true
	return true
end

-- swap two paladins' complete duties (class rows and per-member overrides;
-- auras are personal and stay). Routed through the normal Set* calls so
-- revisions bump, peers sync and permissions gate exactly like manual edits.
function Plan.SwapPaladins(a, b)
	if not a or not b or a == b then
		return false, "pick two different paladins"
	end
	local editor = HO.FullName("player")
	if HO.Comm and editor then
		if not HO.Comm.CanEdit(editor, a) then
			return false, "no permission to edit " .. a
		end
		if not HO.Comm.CanEdit(editor, b) then
			return false, "no permission to edit " .. b
		end
	end
	local plan = Plan.Active()
	local function copyRow(name)
		local out = {}
		for classToken, x in pairs(plan.class[name] or {}) do
			if x.id then
				out[classToken] = { id = x.id, mode = x.mode }
			end
		end
		return out
	end
	local rowA, rowB = copyRow(a), copyRow(b)
	local union = {}
	for classToken in pairs(rowA) do union[classToken] = true end
	for classToken in pairs(rowB) do union[classToken] = true end
	for classToken in pairs(union) do
		local xa, xb = rowA[classToken], rowB[classToken]
		Plan.SetClassAssignment(a, classToken, xb and xb.id or 0, xb and xb.mode)
		Plan.SetClassAssignment(b, classToken, xa and xa.id or 0, xa and xa.mode)
	end
	local ovA, ovB = {}, {}
	for target, id in pairs(plan.player[a] or {}) do ovA[target] = id end
	for target, id in pairs(plan.player[b] or {}) do ovB[target] = id end
	local ovUnion = {}
	for target in pairs(ovA) do ovUnion[target] = true end
	for target in pairs(ovB) do ovUnion[target] = true end
	for target in pairs(ovUnion) do
		Plan.SetPlayerOverride(a, target, ovB[target] or 0)
		Plan.SetPlayerOverride(b, target, ovA[target] or 0)
	end
	HO.Log("plan", "swapped duties: " .. a .. " <> " .. b)
	return true
end

-- an expected paladin joined: drop them from the list. If they run this addon
-- their own row broadcast overwrites the pre-plan (the owner is authoritative
-- by protocol) — and what an arriving client broadcasts is nearly always the
-- stale remainder of an older group, not intent. So the pre-planned row is
-- captured and re-applied shortly after arrival as a normal permission-gated
-- edit, replacing their announced row wholesale; edits made after joining win
-- normally like anywhere else.
local function HandleArrivals()
	local expected = HO.db and HO.db.expected
	if not expected or not next(expected) then
		return
	end
	local present = {} -- case-insensitive lookup: typos in /ho expect must still match
	for rname in pairs(HO.Roster.byName) do
		present[rname:lower()] = rname
	end
	for name in pairs(expected) do
		local real = present[name:lower()]
		if real then
			expected[name] = nil
			local plan = Plan.Active()
			-- the row was pre-planned under the typed key; move it to the real
			-- name if the capitalization differed
			if real ~= name then
				plan.class[real] = plan.class[real] or plan.class[name]
				plan.class[name] = nil
				plan.player[real] = plan.player[real] or plan.player[name]
				plan.player[name] = nil
			end
			local captured
			for classToken, a in pairs(plan.class[real] or {}) do
				if a.id then
					captured = captured or {}
					captured[classToken] = { id = a.id, mode = a.mode }
				end
			end
			if captured then
				local arrival = {}
				pendingArrivals[real] = arrival
				local function Current()
					return pendingArrivals[real] == arrival and Plan.Active() == plan
						and HO.Roster.byName[real] ~= nil
				end
				HO.Announce(real .. " arrived — holding their pre-planned assignments")
				-- replace the row wholesale with the pre-planned lane: what the
				-- arriving client announced is in practice stale leftovers from
				-- an older group. Returns false without permission.
				local function ApplyCaptured()
					if not Current() then return false end
					local editor = HO.FullName("player")
					if HO.Comm and editor and not HO.Comm.CanEdit(editor, real) then
						return false -- no permission; their own row stands
					end
					for classToken, a in pairs(captured) do
						Plan.SetClassAssignment(real, classToken, a.id, a.mode, arrival)
					end
					-- clear classes outside the pre-plan so the lane is exactly
					-- what was planned, not a merge with their leftovers
					local clear = {}
					for classToken, a in pairs(Plan.Active().class[real] or {}) do
						if a.id and not captured[classToken] then
							clear[#clear + 1] = classToken
						end
					end
					for _, classToken in ipairs(clear) do
						Plan.SetClassAssignment(real, classToken, 0, nil, arrival)
					end
					return true
				end
				-- does the row match the pre-planned lane exactly?
				local function Matches()
					local row = Plan.Active().class[real] or {}
					for classToken, a in pairs(captured) do
						local cur = row[classToken]
						if not cur or cur.id ~= a.id or cur.mode ~= a.mode then
							return false
						end
					end
					for classToken, cur in pairs(row) do
						if cur.id and not captured[classToken] then
							return false
						end
					end
					return true
				end
				C_Timer.After(ARRIVAL_REASSERT_DELAY, function()
					if not ApplyCaptured() then
						if pendingArrivals[real] == arrival then pendingArrivals[real] = nil end
						return
					end
					HO.Announce("pre-planned assignments applied for " .. real)
					-- verification pass: the join window is thick with row
					-- broadcasts, and an in-flight stale copy serialized before
					-- our edits can land after them and overwrite the lane
					-- (owner rows apply unconditionally). One bounded retry.
					C_Timer.After(ARRIVAL_REASSERT_DELAY, function()
						if Current() and not Matches() and ApplyCaptured() then
							HO.Announce("pre-planned assignments re-applied for " .. real .. " (a crossing update had overwritten them)")
						end
						if pendingArrivals[real] == arrival then pendingArrivals[real] = nil end
					end)
					-- their capabilities are known by now (from their client's
					-- greeting): warn loudly when the pre-plan does not fit —
					-- e.g. Kings/Sanctuary pre-planned onto a build without the
					-- talent. The lane swap (click two window headers) fixes it.
					local peer = HO.Comm and HO.Comm.peers[real]
					if peer and peer.caps then
						for _, a in pairs(captured) do
							local cap = peer.caps[a.id]
							if cap and not cap.known then
								local blessing = HO.Data.blessings[a.id]
								HO.Print(real .. " cannot cast " .. ((blessing and blessing.name) or ("blessing " .. a.id))
									.. " — click two paladin names in the window to swap lanes")
							end
						end
					end
				end)
			end
		end
	end
end

-- auto-apply / suggestion ----------------------------------------------------

Plan.suggestion = nil -- signature of the suggested stored plan, if any
local lastHandledSig

local function OnRosterChanged()
	if not HO.db then
		return
	end
	for name in pairs(pendingArrivals) do
		if not HO.Roster.byName[name] then Plan.CancelArrivals(name) end
	end
	HandleArrivals()
	local sig = Plan.CurrentSignature()
	if sig == "" or sig == lastHandledSig then
		if Plan.suggestion ~= sig then
			Plan.suggestion = nil -- a suggestion from a different roster is stale
		end
		return
	end
	lastHandledSig = sig
	if sig == HO.db.activeSignature then
		if Plan.suggestion ~= sig then
			Plan.suggestion = nil -- stale suggestion from a different roster
		end
		return -- same roster as the active plan; nothing to do
	end
	local stored = HO.db.plans[sig]
	if stored then
		local active = Plan.Active()
		local dirty = active.meta and active.meta.dirty
		-- no-Salvation mode must survive a roster change: auto-applying a stored
		-- plan would resurrect the swapped-out Salvation mid-encounter
		local noSalv = Plan.NoSalvationActive() or HO.db.noSalvBy
		if dirty or noSalv then
			-- offer instead of applying; do NOT stamp activeSignature (nothing
			-- was applied)
			Plan.suggestion = sig
			HO.Log("plan", "stored plan for " .. sig .. " offered (auto-apply suppressed)")
			if dirty then
				HO.Announce(L("stored plan for this roster available — '/ho plan apply' loads it (your unsaved edits are kept until then)")
					.. (noSalv and " (no-Salvation mode active)" or ""))
			else
				HO.Announce("stored plan for this roster available — '/ho plan apply' loads it (no-Salvation mode active)")
			end
			return
		end
		-- adopt the stored plan; carry the CURRENT rev table forward so peers
		-- accept the restored rows (stored plans hold no rev of their own)
		local prevRev = Copy(Plan.Active().rev or {})
		HO.db.activePlan = Copy(stored)
		HO.db.activePlan.rev = prevRev
		HO.db.activePlan.meta.dirty = nil
		HO.db.activeSignature = sig
		stored.meta.lastUsed = time()
		Plan.suggestion = nil
		HO.Log("plan", "auto-applied stored plan for " .. sig)
		HO.Announce(L("stored plan applied for this paladin roster") .. (stored.meta.name and (" ('" .. stored.meta.name .. "')") or ""))
		-- the automatic broadcast fires on every privileged client at once;
		-- gate it to the actual group leader. Other privileged clients apply
		-- locally and only re-sync their own row.
		if HO.Comm then
			if UnitIsGroupLeader("player") then
				if HO.Comm.SendPlanApply() then
					-- PLANAPPLY carries no auras; the lead teaches them here
					HO.Comm.BroadcastAuras()
					HO.Announce(L("plan broadcast to the group"))
				end
			else
				HO.Comm.BroadcastOwnRow()
			end
		end
		return
	end
	-- no exact match: keep the current active plan, look for a similar one
	HO.db.activeSignature = sig
	local mySet = SetFromSignature(sig)
	local bestSig, bestScore
	for storedSig in pairs(HO.db.plans) do
		local score = Jaccard(mySet, SetFromSignature(storedSig))
		if score >= Plan.SUGGEST_THRESHOLD and (not bestScore or score > bestScore) then
			bestSig, bestScore = storedSig, score
		end
	end
	Plan.suggestion = bestSig
	if bestSig then
		local named = HO.db.plans[bestSig].meta.name
		HO.Announce(string.format(
			"similar stored plan found (%d%% paladin overlap)%s — '/ho plan apply' to use it",
			math.floor(bestScore * 100 + 0.5),
			named and (" '" .. named .. "'") or ""
		))
	end
end

function Plan.ApplySuggestion()
	local sig = Plan.suggestion
	local stored = sig and HO.db.plans[sig]
	if not stored then
		return false
	end
	-- carry the current rev table forward so peers accept the loaded rows
	-- (stored plans hold no rev of their own)
	local prevRev = Copy(Plan.Active().rev or {})
	HO.db.activePlan = Copy(stored)
	HO.db.activePlan.rev = prevRev
	HO.db.activePlan.meta.dirty = nil
	HO.db.activeSignature = Plan.CurrentSignature()
	stored.meta.lastUsed = time()
	Plan.suggestion = nil
	if HO.Comm and HO.Comm.SendPlanApply() then
		HO.Comm.BroadcastAuras() -- PLANAPPLY carries no auras; teach them here
		HO.Print(L("plan broadcast to the group"))
	end
	return true
end

HO.Roster.OnChanged(OnRosterChanged)
