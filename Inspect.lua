-- HolyOrders — inspect-based spec inference
-- Fills EMPTY spec tags only (manual tags always win). Queued, throttled,
-- range-checked, out of combat only; best effort by design.

local HO = HolyOrders
local Inspect = {}
HO.Inspect = Inspect

-- talent tab -> spec tag (only classes with spec-dependent preferences)
local TAB_SPECS = {
	SHAMAN = { "elemental", "enhancement", "restoration" },
	DRUID = { "balance", "feral", "restoration" },
	PALADIN = { "holy", "protection", "retribution" },
	WARRIOR = { nil, nil, "protection" },
}
local RETRY_AFTER = 600 -- seconds before re-trying a member
local TIMEOUT = 5
local MIN_POINTS = 5 -- below this the spec is too ambiguous to infer

local queue, queued, attempts = {}, {}, {}
local current

-- a MANUAL spec tag (set via /ho spec or the assignment window) is authoritative
-- and never re-inspected or overwritten; only empty and inferred tags refresh, so
-- a respec (or an earlier bad read) self-corrects on the next inspection
local function IsManual(name)
	return HO.db.specManual and HO.db.specManual[name]
end

local function Enqueue()
	for _, entry in ipairs(HO.Roster.units) do
		local name = entry.name
		if name and not entry.isPet and TAB_SPECS[entry.class]
			and not IsManual(name) and not queued[name]
			and name ~= HO.FullName("player")
			and (not attempts[name] or (GetTime() - attempts[name]) > RETRY_AFTER) then
			queued[name] = true
			table.insert(queue, name)
		end
	end
end

local function Pump()
	if current or InCombatLockdown() then
		return
	end
	if InspectFrame and InspectFrame:IsShown() then
		return -- never fight the player's own inspect session
	end
	for _ = 1, #queue do
		local name = table.remove(queue, 1)
		queued[name] = nil
		local entry = HO.Roster.byName[name]
		if entry and not IsManual(name) then
			local unit = entry.unit
			if unit and UnitIsConnected(unit) and CheckInteractDistance(unit, 1) and CanInspect(unit) then
				attempts[name] = GetTime()
				current = { name = name, unit = unit, class = entry.class }
				current.timeoutTimer = C_Timer.NewTimer(TIMEOUT, function()
					pcall(ClearInspectPlayer)
					current = nil
				end)
				NotifyInspect(unit)
				return
			end
			-- out of range right now: stay queued for a later tick
			queued[name] = true
			table.insert(queue, name)
		end
	end
end

HO.RegisterEvent("INSPECT_READY", function(guid)
	if not current or UnitGUID(current.unit) ~= guid then
		return
	end
	local best, bestPoints, perTab = nil, 0, {}
	for tab = 1, GetNumTalentTabs(true) do
		local points = 0
		for index = 1, GetNumTalents(tab, true) do
			local _, _, _, _, rank = GetTalentInfo(tab, index, true)
			points = points + (rank or 0)
		end
		perTab[tab] = points
		if points > bestPoints then
			best, bestPoints = tab, points
		end
	end
	local spec = best and TAB_SPECS[current.class] and TAB_SPECS[current.class][best]
	-- partial-data guard: inspect talents stream in, and a half-loaded tree (say
	-- 0/0/7 on a level-60) would otherwise pass MIN_POINTS and tag the wrong spec.
	-- Expect roughly level-appropriate total points (80% slack for unspent ones);
	-- less than that means the data isn't fully here yet — skip, retry later.
	local total = 0
	for _, points in ipairs(perTab) do
		total = total + points
	end
	local level = UnitLevel(current.unit)
	local expected = (level and level >= 10) and math.floor((level - 9) * 0.8) or MIN_POINTS
	if total < expected then
		HO.Log("inspect", current.name .. " talents incomplete (" .. total .. "/" .. expected .. " expected) — retry later")
		-- quick retry (~30s) instead of the full cooldown; the data usually
		-- finishes streaming shortly
		attempts[current.name] = GetTime() - RETRY_AFTER + 30
		ClearInspectPlayer()
		if current.timeoutTimer then
			current.timeoutTimer:Cancel()
		end
		current = nil
		return
	end
	if bestPoints >= MIN_POINTS and not IsManual(current.name) then
		-- specs without a preference mapping (e.g. arms/fury) cache as "other".
		-- Overwrite an existing inferred tag so a respec / earlier bad read updates.
		local newSpec = spec or "other"
		local changed = HO.db.specCache[current.name] ~= newSpec
		HO.db.specCache[current.name] = newSpec
		HO.Log("inspect", current.name .. " inferred as " .. newSpec
			.. " (tabs " .. table.concat(perTab, "/") .. ")")
		-- share the inference so every client computes the same tank set (only on a
		-- change, to avoid needless churn on the periodic re-inspect)
		if changed and HO.Comm then
			HO.Comm.SendSpecTag(current.name, newSpec)
		end
	end
	ClearInspectPlayer()
	if current.timeoutTimer then
		current.timeoutTimer:Cancel()
	end
	current = nil
end)

HO.RegisterEvent("PLAYER_LOGIN", function()
	-- spec inference reads classic talent tabs; the trait client has none, so
	-- there manual/synced spec tags are the only source
	if not HO.Compat.HAS_TALENT_TABS then
		return
	end
	HO.Roster.OnChanged(Enqueue)
	C_Timer.NewTicker(3, Pump)
end)
