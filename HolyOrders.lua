-- HolyOrders — paladin blessing coordination
-- Core: addon namespace, saved variables, event dispatch, slash commands.

local ADDON_NAME = ...

HolyOrders = HolyOrders or {}
local HO = HolyOrders

HO.VERSION = "0.40.0"

local DB_DEFAULTS = {
	options = {},
	plans = {},     -- stored blessing plans, keyed by roster signature
	prefs = {},     -- class/spec blessing preferences
	memberPrefs = {}, -- [fullName] = blessingID: remembered per-member blessing likings
	specCache = {}, -- per-character spec tags
	expected = {},  -- [fullName] = true: paladins pre-planned before they join
	log = {},       -- persistent debug log (ring buffer, see HO.Log)
}

-- event dispatch -------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function HO.RegisterEvent(event, handler)
	if not eventHandlers[event] then
		eventHandlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(eventHandlers[event], handler)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, handler in ipairs(eventHandlers[event]) do
		handler(...)
	end
end)

-- lifecycle ------------------------------------------------------------------

HO.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON_NAME then
		return
	end
	HolyOrdersDB = HolyOrdersDB or {}
	for key, value in pairs(DB_DEFAULTS) do
		if HolyOrdersDB[key] == nil then
			HolyOrdersDB[key] = value
		end
	end
	HO.db = HolyOrdersDB
	-- others may adjust your assignments by default (opt out in the options).
	-- nil = never chosen → default on; an explicit false the user set is kept.
	if HO.db.options.openEdit == nil then
		HO.db.options.openEdit = true
	end
end)

HO.RegisterEvent("PLAYER_LOGIN", function()
	HO.Data.Refresh()
	HO.Talents.Scan()
	HO.Roster.Queue()
	HO.Log("core", "login v" .. HO.VERSION .. " talents " .. HO.Talents.SpecSummary())
end)

-- debug log ------------------------------------------------------------------
-- Persisted in SavedVariables so problems can be analyzed offline after a
-- /reload or logout. Ring buffer: capped, oldest entries dropped.

local LOG_MAX = 300
local LOG_TRIM_TO = 250

function HO.Log(category, msg)
	local log = HO.db and HO.db.log
	if not log then
		return
	end
	table.insert(log, date("%m-%d %H:%M:%S") .. " [" .. category .. "] " .. tostring(msg))
	if #log > LOG_MAX then
		local keep = {}
		for i = #log - LOG_TRIM_TO + 1, #log do
			table.insert(keep, log[i])
		end
		HO.db.log = keep
	end
end

-- output ---------------------------------------------------------------------

function HO.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cfff0c817HolyOrders|r: " .. tostring(msg))
end

-- ambient status output (routine sync / auto-plan events). Silent unless the
-- user opts into verbose chat in the options; direct command responses, errors
-- and important warnings always use HO.Print.
function HO.Announce(msg)
	if HO.db and HO.db.options and HO.db.options.verbose then
		HO.Print(msg)
	end
end

function HO.PrintLine(msg)
	DEFAULT_CHAT_FRAME:AddMessage("  " .. tostring(msg))
end

-- helpers --------------------------------------------------------------------

-- realm-qualified unit name ("Name-Realm"), used for roster signatures
function HO.FullName(unit)
	local name, realm = UnitName(unit)
	if not name then
		return nil
	end
	if realm and realm ~= "" then
		return name .. "-" .. realm
	end
	return name .. "-" .. (GetNormalizedRealmName() or "")
end

-- slash commands -------------------------------------------------------------

local commands = {}
HO.commands = commands

SLASH_HOLYORDERS1 = "/holyorders"
SLASH_HOLYORDERS2 = "/ho"
SlashCmdList["HOLYORDERS"] = function(input)
	input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = input:match("^(%S+)%s*(.*)$")
	cmd = cmd and cmd:lower() or ""
	if cmd == "" then
		-- bare /ho opens the assignment window
		if HO.Window and HO.Window.Toggle then
			HO.Window.Toggle()
		end
	elseif commands[cmd] then
		HO.Log("cmd", "/ho " .. cmd .. (rest ~= "" and (" " .. rest) or ""))
		local ok, err = pcall(commands[cmd], rest)
		if not ok then
			HO.Log("error", cmd .. ": " .. tostring(err))
			HO.Print("error in '" .. cmd .. "' (logged): " .. tostring(err))
		end
	else
		HO.Print("unknown command '" .. cmd .. "' — /ho help")
	end
end
