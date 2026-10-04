-- HolyOrders — client API compatibility
-- One codebase runs on two clients: the classic client (legacy globals such as
-- GetSpellInfo / UnitBuff / GetTalentInfo) and the modern-engine vanilla client
-- (namespaced C_* API, trait-based talents, secret combat values, addon-comm
-- lockdown). Every call site goes through here; the legacy global always wins
-- when it exists, so the classic client keeps its exact behavior.

local HO = HolyOrders
local Compat = {}
HO.Compat = Compat

local MAX_BUFFS = 40

-- true where talents are classic tab trees (GetTalentInfo); false where they
-- live on the trait system and tab-based inspection cannot work
Compat.HAS_TALENT_TABS = GetNumTalentTabs ~= nil

-- spells ------------------------------------------------------------------------

-- localized name and icon of a spell ID (nil when the client lacks the spell)
function Compat.SpellNameIcon(spellID)
	if GetSpellInfo then
		local name, _, icon = GetSpellInfo(spellID)
		return name, icon
	end
	local info = C_Spell.GetSpellInfo(spellID)
	if info then
		return info.name, info.iconID
	end
	return nil, nil
end

-- calls fn(slot, name, rankText) for every player spellbook entry, in book order
function Compat.ForEachSpellBookItem(fn)
	if GetNumSpellTabs then
		for tab = 1, GetNumSpellTabs() do
			local _, _, offset, numSlots = GetSpellTabInfo(tab)
			for slot = offset + 1, offset + numSlots do
				local name, rank = GetSpellBookItemName(slot, BOOKTYPE_SPELL)
				if name then
					fn(slot, name, rank)
				end
			end
		end
		return
	end
	local bank = Enum.SpellBookSpellBank.Player
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if info then
			local offset = info.itemIndexOffset or 0
			for slot = offset + 1, offset + (info.numSpellBookItems or 0) do
				local name, subName = C_SpellBook.GetSpellBookItemName(slot, bank)
				if name then
					fn(slot, name, subName)
				end
			end
		end
	end
end

-- true / false, or nil when the client cannot tell (no range, unknown spell)
function Compat.SpellInRange(spellName, unit)
	if IsSpellInRange then
		local result = IsSpellInRange(spellName, unit)
		if result == nil then
			return nil
		end
		return result == 1
	end
	local result = C_Spell.IsSpellInRange(spellName, unit)
	if result == nil or (issecretvalue and issecretvalue(result)) then
		return nil
	end
	return result and true or false
end

function Compat.ItemCount(itemID)
	local count = GetItemCount and GetItemCount(itemID) or C_Item.GetItemCount(itemID)
	return count or 0
end

-- buffs -------------------------------------------------------------------------

-- The modern client hides auras from addon code in combat ("secret" values;
-- reading one throws). Each lookup's last readable answer is cached per unit and
-- buff, and served while auras are locked. The cache holds the absolute
-- expiration time, so remaining time keeps counting down correctly.
local buffCache = {}

local function AurasLocked()
	return C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil and C_Secrets.ShouldAurasBeSecret()
end

local function IsSecret(value)
	return issecretvalue ~= nil and value ~= nil and issecretvalue(value)
end

-- one pass over the unit's buffs; returns found, duration, expirationTime.
-- Errors (secret data) propagate to the caller's pcall.
local function ScanBuffs(unit, nameA, nameB)
	for i = 1, MAX_BUFFS do
		local name, duration, expirationTime
		if UnitBuff then
			local _
			name, _, _, _, duration, expirationTime = UnitBuff(unit, i)
		else
			local aura = C_UnitAuras.GetBuffDataByIndex(unit, i)
			if aura then
				name, duration, expirationTime = aura.name, aura.duration, aura.expirationTime
			end
		end
		if not name then
			return false, nil, nil
		end
		if IsSecret(name) or IsSecret(duration) or IsSecret(expirationTime) then
			error("secret aura")
		end
		if name == nameA or (nameB and name == nameB) then
			return true, duration, expirationTime
		end
	end
	return false, nil, nil
end

-- does the unit carry a buff named nameA (or nameB)? Returns found, duration,
-- expirationTime (0 / nil = no expiry). While auras are unreadable the last
-- readable answer is used; an expired cached buff counts as gone.
function Compat.FindBuff(unit, nameA, nameB)
	if not unit or not nameA then
		return false, nil, nil
	end
	local key = unit .. "\031" .. nameA
	if not AurasLocked() then
		local ok, found, duration, expirationTime = pcall(ScanBuffs, unit, nameA, nameB)
		if ok then
			buffCache[key] = { found = found, duration = duration, expirationTime = expirationTime }
			return found, duration, expirationTime
		end
	end
	local cached = buffCache[key]
	if not cached or not cached.found then
		return false, nil, nil
	end
	local expirationTime = cached.expirationTime
	if expirationTime and expirationTime > 0 and expirationTime <= GetTime() then
		return false, nil, nil
	end
	return true, cached.duration, expirationTime
end

-- unit tokens get reassigned on roster changes; a stale cache must not survive
HO.RegisterEvent("GROUP_ROSTER_UPDATE", function()
	wipe(buffCache)
end)

-- talents -----------------------------------------------------------------------

-- every trait config the client exposes (class talents plus any extra trees),
-- deduplicated and sorted so scans are deterministic
local function TraitConfigIDs()
	local ids, seen = {}, {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
		local ok, id = pcall(C_ClassTalents.GetActiveConfigID)
		if ok then
			add(id)
		end
	end
	if Enum.TraitConfigType and C_Traits.GetConfigsByType then
		for _, configType in pairs(Enum.TraitConfigType) do
			local ok, list = pcall(C_Traits.GetConfigsByType, configType)
			if ok and type(list) == "table" then
				for _, id in ipairs(list) do
					add(id)
				end
			end
		end
	end
	table.sort(ids)
	return ids
end

-- calls fn(icon, rank) for every trait the player has invested in
local function ForEachTrait(fn)
	for _, configID in ipairs(TraitConfigIDs()) do
		local config = C_Traits.GetConfigInfo(configID)
		for _, treeID in ipairs(config and config.treeIDs or {}) do
			for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
				local node = C_Traits.GetNodeInfo(configID, nodeID)
				local rank = node and (node.activeRank or node.currentRank) or 0
				local entryID = node and node.activeEntry and node.activeEntry.entryID
				if rank > 0 and entryID then
					local entry = C_Traits.GetEntryInfo(configID, entryID)
					local definition = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
					local spellID = definition and (definition.overriddenSpellID or definition.spellID)
					local icon = spellID and C_Spell.GetSpellTexture(spellID)
					if icon then
						fn(icon, rank)
					end
				end
			end
		end
	end
end

-- calls onTalent(tab, icon, rank) for each own talent. On the trait client there
-- are no ordered spec tabs, so every talent reports tab 0 and callers must not
-- read a spec from tab totals.
function Compat.ForEachOwnTalent(onTalent)
	if Compat.HAS_TALENT_TABS then
		for tab = 1, GetNumTalentTabs() do
			for index = 1, GetNumTalents(tab) do
				local _, icon, _, _, rank = GetTalentInfo(tab, index)
				onTalent(tab, icon, rank or 0)
			end
		end
		return
	end
	if not (C_Traits and C_Traits.GetConfigInfo) then
		return
	end
	local ok, err = pcall(ForEachTrait, function(icon, rank)
		onTalent(0, icon, rank)
	end)
	if not ok then
		HO.Log("talents", "trait scan failed: " .. tostring(err))
	end
end

-- debug snapshot of the trait layout (trait client only): which configs and
-- trees exist, points per tree, and every invested node, so own-spec
-- detection can be built against the real tree structure
local function DescribeTraitsCore(lines)
	local function add(fmt, ...)
		lines[#lines + 1] = string.format(fmt, ...)
	end
	local sis = C_SpecializationInfo
	if sis and sis.GetSpecialization then
		local index = sis.GetSpecialization()
		add("spec index=%s", tostring(index))
		if index and sis.GetSpecializationInfo then
			local id, name, _, _, role = sis.GetSpecializationInfo(index)
			add("spec id=%s name=%s role=%s", tostring(id), tostring(name), tostring(role))
		end
	end
	for _, configID in ipairs(TraitConfigIDs()) do
		local config = C_Traits.GetConfigInfo(configID)
		add("config %s type=%s name=%s", tostring(configID), tostring(config and config.type), tostring(config and config.name))
		for _, treeID in ipairs(config and config.treeIDs or {}) do
			local spent, invested = 0, {}
			for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
				local node = C_Traits.GetNodeInfo(configID, nodeID)
				local rank = node and (node.activeRank or node.currentRank) or 0
				if rank > 0 then
					spent = spent + rank
					local entryID = node.activeEntry and node.activeEntry.entryID
					local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
					local definition = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
					local spellID = definition and (definition.overriddenSpellID or definition.spellID)
					invested[#invested + 1] = string.format("  node %s rank=%d spell=%s %s x=%s y=%s sub=%s",
						tostring(nodeID), rank, tostring(spellID), tostring(spellID and C_Spell.GetSpellName(spellID)),
						tostring(node.posX), tostring(node.posY), tostring(node.subTreeID))
				end
			end
			add(" tree %s spent=%d", tostring(treeID), spent)
			for _, line in ipairs(invested) do
				lines[#lines + 1] = line
			end
		end
	end
end

function Compat.DescribeTraits()
	if Compat.HAS_TALENT_TABS or not (C_Traits and C_Traits.GetConfigInfo) then
		return nil
	end
	local lines = {}
	local ok, err = pcall(DescribeTraitsCore, lines)
	if not ok then
		lines[#lines + 1] = "error: " .. tostring(err)
	end
	return lines
end

-- events that signal a talent change on this client
Compat.TALENT_EVENTS = Compat.HAS_TALENT_TABS and { "CHARACTER_POINTS_CHANGED" }
	or { "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED" }

-- events ------------------------------------------------------------------------

-- registering an event the client does not know throws on the modern client,
-- so optional events are checked first (assumed present where no check exists)
function Compat.EventExists(event)
	if C_EventUtils and C_EventUtils.IsEventValid then
		return C_EventUtils.IsEventValid(event)
	end
	return true
end

-- addon comms -------------------------------------------------------------------

-- true while the client refuses outgoing addon messages (the modern client
-- locks addon comms during restricted content); senders keep messages queued
function Compat.AddonCommsLocked()
	local check = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	if not check then
		return false
	end
	local ok, locked = pcall(check)
	return ok and locked == true
end
