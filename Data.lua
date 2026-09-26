-- HolyOrders — blessing data
-- Only base spell IDs are stored (public game data); localized names, icons
-- and known ranks are resolved from the running client's spellbook, so the
-- addon is locale-safe and needs no per-rank tables.

local HO = HolyOrders
local Data = {}
HO.Data = Data

-- stable blessing IDs (used in SavedVariables and comm; never renumber)
Data.blessings = {
	[1] = { key = "WISDOM", normal = 19742, greater = 25894 },
	[2] = { key = "MIGHT", normal = 19740, greater = 25782 },
	[3] = { key = "KINGS", normal = 20217, greater = 25898 },
	[4] = { key = "SALVATION", normal = 1038, greater = 25895 },
	[5] = { key = "LIGHT", normal = 19977, greater = 25890 },
	[6] = { key = "SANCTUARY", normal = 20911, greater = 25899 },
}
Data.NUM_BLESSINGS = #Data.blessings

-- stable aura IDs (used in SavedVariables and comm; never renumber). Each maps
-- to a representative base spell whose localized name and icon we resolve from
-- the running client, so no localized aura name is ever hardcoded. Auras have
-- no "greater" form and rank is just level, so there is no rank scoring.
Data.auras = {
	[1] = { base = 465 },   -- Devotion Aura
	[2] = { base = 7294 },  -- Retribution Aura
	[3] = { base = 19746 }, -- Concentration Aura
	[4] = { base = 19876 }, -- Shadow Resistance Aura
	[5] = { base = 19888 }, -- Frost Resistance Aura
	[6] = { base = 19891 }, -- Fire Resistance Aura
	[7] = { base = 20218 }, -- Sanctity Aura (talent-gated)
	[8] = { base = 32223 }, -- Crusader Aura
}
Data.NUM_AURAS = #Data.auras

-- Righteous Fury: the protection paladin's threat self-buff. Not a blessing
-- and not an aura — it is only ever cast on yourself, so it lives on its own.
Data.selfBuff = { base = 25780 }

Data.SYMBOL_OF_KINGS = 21177 -- reagent for greater blessings

-- eligibility (SPEC-planner §2); manual per-member overrides may bypass this
local NO_WISDOM = { WARRIOR = true, ROGUE = true }
local NO_MIGHT = { MAGE = true, WARLOCK = true, PRIEST = true }

function Data.IsEligible(classToken, blessingID, isTank)
	local blessing = Data.blessings[blessingID]
	if not blessing then
		return false
	end
	if blessing.key == "WISDOM" and NO_WISDOM[classToken] then
		return false
	end
	if blessing.key == "MIGHT" and NO_MIGHT[classToken] then
		return false
	end
	if blessing.key == "SALVATION" and isTank then
		return false
	end
	return true
end

-- spellbook resolution -------------------------------------------------------

-- highest known entry per spell name (later book slots hold higher ranks)
local function ScanSpellbook()
	local known = {}
	HO.Compat.ForEachSpellBookItem(function(slot, name, rank)
		known[name] = { rank = rank, slot = slot }
	end)
	return known
end

function Data.Refresh()
	local book = ScanSpellbook()
	for _, blessing in ipairs(Data.blessings) do
		local nName, nIcon = HO.Compat.SpellNameIcon(blessing.normal)
		local gName, gIcon = HO.Compat.SpellNameIcon(blessing.greater)
		blessing.name, blessing.icon = nName, nIcon
		blessing.greaterName, blessing.greaterIcon = gName, gIcon
		local nEntry = nName and book[nName]
		local gEntry = gName and book[gName]
		blessing.known = nEntry ~= nil
		blessing.rank = nEntry and nEntry.rank or nil
		blessing.greaterKnown = gEntry ~= nil
		blessing.greaterRank = gEntry and gEntry.rank or nil
		-- numeric rank for buff-strength scoring; rank-less spells count as 1
		if nEntry then
			blessing.rankNum = tonumber((nEntry.rank or ""):match("%d+")) or 1
		else
			blessing.rankNum = 0
		end
	end
	Data.RefreshAuras()
end

-- auras resolve exactly like blessings: localized name/icon from the base spell,
-- known-detection from the spellbook scan (never a hardcoded localized string).
-- Called from Data.Refresh so a spellbook change refreshes both at once.
function Data.RefreshAuras()
	local book = ScanSpellbook()
	for _, aura in ipairs(Data.auras) do
		local name, icon = HO.Compat.SpellNameIcon(aura.base)
		aura.name, aura.icon = name, icon
		aura.known = (name and book[name]) ~= nil
	end
	-- the protection threat self-buff, resolved the same locale-safe way
	local name, icon = HO.Compat.SpellNameIcon(Data.selfBuff.base)
	Data.selfBuff.name, Data.selfBuff.icon = name, icon
	Data.selfBuff.known = (name and book[name]) ~= nil
end

-- ids of known auras in id order (mirrors the blessing helpers)
function Data.KnownAuras()
	local ids = {}
	for id, aura in ipairs(Data.auras) do
		if aura.known then
			ids[#ids + 1] = id
		end
	end
	return ids
end

function Data.AuraName(id)
	local aura = id and Data.auras[id]
	return aura and aura.name or nil
end

function Data.AuraIcon(id)
	local aura = id and Data.auras[id]
	return aura and aura.icon or nil
end

function Data.SymbolCount()
	return HO.Compat.ItemCount(Data.SYMBOL_OF_KINGS)
end

HO.RegisterEvent("SPELLS_CHANGED", function()
	Data.Refresh()
end)
