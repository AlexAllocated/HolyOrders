-- HolyOrders — options (AceConfig)
-- A tree-navigated options dialog built on the bundled Ace3 config libraries:
-- categories on the left, the selected page on the right with headers, square
-- toggles, sliders for scales and dropdowns for multi-choice values. Mounted
-- in Blizzard's Interface Options; /ho opt navigates straight to it.

local HO = HolyOrders
local Options = {}
HO.Options = Options
local L = HO.L

local PET_CYCLE = { 2, 1, 3 } -- Might > Wisdom > Kings
local GROW_DIRS = { "right", "left", "down", "up" }
local FLYOUT_DIRS = { "left", "right", "up", "down" }

-- switching the skin rebuilds every frame's chrome, which only happens at UI
-- load — so offer the reload right away (or let the user do it later)
StaticPopupDialogs["HOLYORDERS_SKIN_RELOAD"] = {
	text = "HolyOrders: %s",
	button1 = _G.RELOADUI or "Reload UI",
	button2 = _G.CANCEL or "Cancel",
	OnAccept = function()
		ReloadUI()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3, -- avoid tainting the default popup slots
}

function Options.PromptSkinReload()
	StaticPopup_Show("HOLYORDERS_SKIN_RELOAD", HO.L["the new skin applies after a UI reload — reload now?"])
end

function Options.Ensure()
	local o = HO.db.options
	o.bar = o.bar or {}
	o.bar.scale = o.bar.scale or 1.0
	o.window = o.window or {} -- o.window.scale defaults to nil (read as 1.0)
	o.pets = o.pets or { hunter = true, warlock = false, blessing = 2 }
	o.minimap = o.minimap or { angle = 200 }
	return o
end

-- toggles that change plan/pet display must also update an open assignment
-- window, not just the cast bar (both are nil-safe: modules may not exist yet)
local function RefreshAll()
	if HO.Bar and HO.Bar.Refresh then
		HO.Bar.Refresh()
	end
	if HO.Window and HO.Window.Refresh then
		HO.Window.Refresh()
	end
end

-- value lists -------------------------------------------------------------------

local function DirValues(dirs)
	local values, sorting = {}, {}
	for _, dir in ipairs(dirs) do
		values[dir] = dir
		sorting[#sorting + 1] = dir
	end
	return values, sorting
end

local function PetValues()
	local values, sorting = {}, {}
	for _, id in ipairs(PET_CYCLE) do
		local blessing = HO.Data.blessings[id]
		values[id] = blessing and (blessing.name or blessing.key) or tostring(id)
		sorting[#sorting + 1] = id
	end
	return values, sorting
end

local function SkinValues()
	local values, sorting = {}, {}
	for _, s in ipairs(HO.Skin.SKINS) do
		values[s] = s
		sorting[#sorting + 1] = s
	end
	return values, sorting
end

-- options table -----------------------------------------------------------------

local GROW_VALUES, GROW_SORT = DirValues(GROW_DIRS)
local FLYOUT_VALUES, FLYOUT_SORT = DirValues(FLYOUT_DIRS)

local function BuildOptionsTable()
	return {
		type = "group",
		childGroups = "tree",
		args = {
			general = {
				type = "group", name = L["General"], order = 1,
				args = {
					head = { type = "header", name = L["General"], order = 0 },
					minimap = {
						type = "toggle", name = L["Show minimap button"], order = 1, width = "full",
						desc = L["Shows or hides the round HolyOrders button on the minimap edge."],
						get = function() return not Options.Ensure().minimap.hide end,
						set = function(_, v)
							Options.Ensure().minimap.hide = not v
							HO.MinimapButton.UpdateShown()
						end,
					},
					verbose = {
						type = "toggle", name = L["Show status messages in chat"], order = 2, width = "full",
						desc = L["Prints routine status messages (sync, auto-planner results) to the chat. Errors and command replies always show."],
						get = function() return Options.Ensure().verbose == true end,
						set = function(_, v) Options.Ensure().verbose = v end,
					},
					trace = {
						type = "toggle", name = L["Log sync messages (debug)"], order = 3, width = "full",
						desc = L["Records the addon sync traffic in the debug log (/ho log). Only needed for troubleshooting."],
						get = function() return Options.Ensure().trace end,
						set = function(_, v) Options.Ensure().trace = v end,
					},
				},
			},
			bar = {
				type = "group", name = L["Cast bar"], order = 2,
				args = {
					head = { type = "header", name = L["Cast bar"], order = 0 },
					show = {
						type = "toggle", name = L["Show cast bar"], order = 1, width = "full",
						desc = L["Shows the cast bar with one button per class duty. It appears automatically when you have blessings to cast."],
						get = function() return not Options.Ensure().bar.hidden end,
						set = function(_, v)
							Options.Ensure().bar.hidden = not v
							HO.Bar.Refresh()
						end,
					},
					front = {
						type = "toggle", name = L["Keep cast bar above other windows"], order = 2, width = "full",
						desc = L["Raises the bar above other addon windows (unit frames and the like) that would otherwise cover it."],
						get = function() return Options.Ensure().bar.front == true end,
						set = function(_, v)
							Options.Ensure().bar.front = v
							if HO.Bar and HO.Bar.ApplyStrata then
								HO.Bar.ApplyStrata()
							end
						end,
					},
					grow = {
						type = "select", name = L["Bar grows"], order = 3,
						desc = L["The direction in which the bar's buttons line up, starting at the handle."],
						values = GROW_VALUES, sorting = GROW_SORT,
						get = function() return Options.Ensure().bar.grow or "right" end,
						set = function(_, v)
							Options.Ensure().bar.grow = v
							HO.Bar.Refresh()
						end,
					},
					flyout = {
						type = "select", name = L["Fly-out opens"], order = 4,
						desc = L["Which side of a class button the member list opens on."],
						values = FLYOUT_VALUES, sorting = FLYOUT_SORT,
						get = function() return Options.Ensure().bar.flyout or "left" end,
						set = function(_, v)
							Options.Ensure().bar.flyout = v
							HO.Bar.Refresh() -- re-anchors the panels out of combat
						end,
					},
					scale = {
						type = "range", name = L["Cast bar scale"], order = 5,
						desc = L["Size of the cast bar. Applies immediately; a change made in combat applies after the fight."],
						min = 0.5, max = 1.5, step = 0.05, isPercent = true, width = "full",
						get = function() return Options.Ensure().bar.scale or 1.0 end,
						-- the bar is protected: ApplyScale is combat-guarded and
						-- re-applies itself on PLAYER_REGEN_ENABLED
						set = function(_, v)
							Options.Ensure().bar.scale = v
							if HO.Bar and HO.Bar.ApplyScale then
								HO.Bar.ApplyScale()
							end
						end,
					},
				},
			},
			windows = {
				type = "group", name = L["Windows & skin"], order = 3,
				args = {
					head = { type = "header", name = L["Windows & skin"], order = 0 },
					scale = {
						type = "range", name = L["Window scale"], order = 1,
						desc = L["Size of the assignment window and the buff-request window."],
						min = 0.5, max = 1.5, step = 0.05, isPercent = true, width = "full",
						get = function() return (Options.Ensure().window and Options.Ensure().window.scale) or 1.0 end,
						set = function(_, v)
							local o = Options.Ensure()
							o.window = o.window or {}
							o.window.scale = v
							if HO.Window and HO.Window.ApplyScale then
								HO.Window.ApplyScale()
							end
							if HO.Request and HO.Request.ApplyScale then
								HO.Request.ApplyScale()
							end
						end,
					},
					skin = {
						type = "select", name = L["Skin"], order = 2,
						desc = L["The addon's look. Switching needs a UI reload — a prompt appears."],
						values = SkinValues, sorting = function()
							local _, sorting = SkinValues()
							return sorting
						end,
						get = function() return Options.Ensure().skin or "default" end,
						set = function(_, v)
							Options.Ensure().skin = v
							Options.PromptSkinReload()
						end,
					},
				},
			},
			blessings = {
				type = "group", name = L["Blessings & pets"], order = 4,
				args = {
					head = { type = "header", name = L["Blessings & pets"], order = 0 },
					greaterSingle = {
						type = "toggle", name = L["Prefer greater blessings even for single members"], order = 1, width = "full",
						desc = L["Casts the big 30-minute blessing even when only one member of a class is present. Costs a Symbol of Kings per cast."],
						get = function() return Options.Ensure().greaterMin == 1 end,
						set = function(_, v)
							Options.Ensure().greaterMin = v and 1 or 2
							RefreshAll()
						end,
					},
					hunterPets = {
						type = "toggle", name = L["Buff hunter pets"], order = 2, width = "full",
						desc = L["Includes hunter pets in planning and casting."],
						get = function() return Options.Ensure().pets.hunter ~= false end,
						set = function(_, v)
							Options.Ensure().pets.hunter = v
							RefreshAll()
						end,
					},
					warlockPets = {
						type = "toggle", name = L["Buff warlock pets"], order = 3, width = "full",
						desc = L["Includes warlock demons in planning and casting."],
						get = function() return Options.Ensure().pets.warlock == true end,
						set = function(_, v)
							Options.Ensure().pets.warlock = v
							RefreshAll()
						end,
					},
					petBlessing = {
						type = "select", name = L["Pet blessing"], order = 4,
						desc = L["The first blessing pets receive. When several paladins cover the owner's class, they stack further blessings on the pet: Kings, and Wisdom on mana pets."],
						values = PetValues, sorting = function()
							local _, sorting = PetValues()
							return sorting
						end,
						get = function() return Options.Ensure().pets.blessing or 2 end,
						set = function(_, v)
							Options.Ensure().pets.blessing = v
							RefreshAll()
						end,
					},
				},
			},
			group = {
				type = "group", name = L["Group"], order = 5,
				args = {
					head = { type = "header", name = L["Group"], order = 0 },
					openEdit = {
						type = "toggle", name = L["Open edit: others may change my assignments"], order = 1, width = "full",
						desc = L["Allows the other paladins in your group to change your assignments. When off, only lead and assist may."],
						get = function() return Options.Ensure().openEdit end,
						set = function(_, v)
							Options.Ensure().openEdit = v
							HO.Comm.SendHello()
						end,
					},
					legacy = {
						type = "toggle", name = L["Share assignments with legacy blessing addons"], order = 2, width = "full",
						desc = L["Broadcasts your own assignments in the format of older blessing addons so their users see your plan. One-way only; off by default."],
						get = function() return Options.Ensure().legacyBroadcast == true end,
						set = function(_, v)
							Options.Ensure().legacyBroadcast = v
							if HO.Interop then
								HO.Interop.SetEnabled(v)
							end
						end,
					},
				},
			},
		},
	}
end

-- registration ------------------------------------------------------------------

local registered = false
local blizPanel

function Options.Create()
	if registered then
		return
	end
	local AceConfig = LibStub and LibStub("AceConfig-3.0", true)
	local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
	if not (AceConfig and AceConfigDialog) then
		HO.Log("options", "AceConfig libraries missing — options unavailable")
		return
	end
	registered = true
	AceConfig:RegisterOptionsTable("HolyOrders", BuildOptionsTable())
	-- mounted under Interface > AddOns; Options.Toggle navigates there
	blizPanel = AceConfigDialog:AddToBlizOptions("HolyOrders", "HolyOrders")
end

-- opens the Blizzard Interface Options at our category (the Ace pages are
-- mounted there); kept as the public entry point — other modules and /ho opt
-- call this
function Options.Toggle()
	Options.Create()
	if not blizPanel then return end
	-- 2.5.6 replaced the legacy Interface Options frame with the Settings
	-- panel, so InterfaceOptionsFrame_OpenToCategory no longer navigates
	-- anywhere (it can survive as a dead stub). Settings comes first now;
	-- AceConfigDialog:AddToBlizOptions already registers us there and
	-- blizPanel.name holds the category ID it returned.
	if Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(blizPanel.name or "HolyOrders")
	elseif InterfaceOptionsFrame_OpenToCategory then
		-- classic quirk: the first call may not navigate on a cold frame
		InterfaceOptionsFrame_OpenToCategory(blizPanel)
		InterfaceOptionsFrame_OpenToCategory(blizPanel)
	end
end

HO.RegisterEvent("PLAYER_LOGIN", Options.Create)
