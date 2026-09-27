-- HolyOrders — assignment window
-- Class grid: rows are classes (expandable to members), columns are paladins.
-- Left-click a cell cycles blessings, right-click clears, shift-click cycles
-- the cast mode. Member rows carry per-member overrides, tank flag and spec
-- tag. Everything edits the active plan; no secure frames involved.

local HO = HolyOrders
local Window = {}
HO.Window = Window
local L = HO.L

local NAME_W = 175
local COL_W = 34
local COL_GAP = 4
local HEADER_H = 30
local ROW_H = 30
local MEMBER_ROW_H = 28
local PAD = 8
local MAX_COLS = 8
local LABEL_INDENT = 14 -- member-row label indent (rows themselves stay aligned)
local HEADER_MAX_CHARS = 5
local MAX_WIN_H = 700 -- height clamp; taller rosters scroll via the mouse wheel
local BOTTOM_PAD = 68 -- reserved space under the last row for the 4 hint lines + corner crest
local FIRST_ROW_OFFSET = 20 -- gap between the column headers and the first row
local ICON_SIZE = 24 -- cell icon size (rows grow with it so icons don't overflow)
-- mini request-preference icons on a member row (top N shown, full list in tooltip)
local PREF_ICON = 16
local PREF_STEP = 18
local MAX_ROW_PREFS = 3

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
-- cast-mode tag shown on a cell: A auto, G great (greater), S small (10-min
-- single). Distinct bright colours + an outlined font read on any blessing icon.
local MODE_TAG = { auto = "|cff40c0ffA|r", greater = "|cffffd100G|r", normal = "|cff40ff40S|r" }
local EMPTY_SLOT = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local NONE_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" -- explicit-none marker (matches the bar)
-- cell icon chrome (mask + status ring) comes from HO.Skin, like the cast bar
-- the dark rounded panel + gold border, seam, gem/close/button textures all come
-- from the shared HO.Skin module (same look as the cast-bar fly-out)

local win
local expanded = {} -- [classToken] = true
local classRows, memberRows = {}, {}
local auraRow -- single "Aura" strip: each paladin column's assigned aura
local scrollOffset = 0 -- pixels scrolled down; clamped in Window.Refresh

-- helpers ---------------------------------------------------------------------

-- truncate to at most maxChars whole UTF-8 characters; :sub on a byte count
-- can split a multi-byte glyph (German names) and print garbage
local function Utf8Truncate(str, maxChars)
	local chars, i, n = 0, 1, #str
	while i <= n and chars < maxChars do
		local b = str:byte(i)
		local size = 1
		if b >= 0xF0 then
			size = 4
		elseif b >= 0xE0 then
			size = 3
		elseif b >= 0xC0 then
			size = 2
		end
		i = i + size
		chars = chars + 1
	end
	return str:sub(1, i - 1)
end

local function BlessingName(id)
	local blessing = HO.Data.blessings[id]
	return blessing and (blessing.name or blessing.key) or tostring(id)
end

-- next assignable blessing for a class cell (0 = none). A manual choice, so any
-- castable blessing qualifies (the usefulness rules only bind the auto-planner);
-- availability best-effort (exact for the player, permissive for remotes)
local function CycleClassBlessing(pally, current, delta)
	delta = delta or 1
	local id = current or 0
	for _ = 1, HO.Data.NUM_BLESSINGS + 1 do
		id = (id + delta) % (HO.Data.NUM_BLESSINGS + 1)
		if id == 0 then
			return 0
		end
		if HO.Planner.IsAvailable(pally, id) then
			return id
		end
	end
	return 0
end

-- wheel-cycling from the cast bar: edits the player's own row, which syncs
-- to the group and refreshes the window like any other edit
function Window.CycleMyClass(classToken, delta)
	local me = HO.FullName("player")
	if not me then
		return
	end
	local plan = HO.Plan.Active()
	local cur = plan.class[me] and plan.class[me][classToken]
	-- ring: each castable blessing, then NONE (a visible, re-assignable placeholder),
	-- then back to the first blessing. A none marker starts the cycle at 0 (like an
	-- unassigned class), so wheel-up lands on the first blessing and wheel-down on
	-- the last. This ring NEVER produces the true-clear state — that stays a
	-- right-click in the assignment window.
	local nextID = CycleClassBlessing(me, cur and cur.id or 0, delta)
	if nextID == 0 then
		HO.Plan.SetClassNone(me, classToken)
	else
		HO.Plan.SetClassAssignment(me, classToken, nextID, cur and cur.mode or nil)
	end
	-- RefreshAll is declared later in this file and not in scope here
	Window.Refresh()
	HO.Bar.Refresh()
end

-- overrides may force anything castable (eligibility intentionally bypassed)
local function CycleOverrideBlessing(pally, current)
	local id = current or 0
	for _ = 1, HO.Data.NUM_BLESSINGS + 1 do
		id = (id + 1) % (HO.Data.NUM_BLESSINGS + 1)
		if id == 0 then
			return 0
		end
		if HO.Planner.IsAvailable(pally, id) then
			return id
		end
	end
	return 0
end

local function RefreshAll()
	Window.Refresh()
	HO.Bar.Refresh()
end

-- classes currently present in the roster (a class button/row is shown for each);
-- pets count under their owner's class, matching the class-row presence rule
local function PresentClasses()
	local set = {}
	for _, entry in ipairs(HO.Roster.units) do
		if entry.name then
			local class = entry.class
			if entry.isPet then
				local owner = entry.owner and HO.Roster.byName[entry.owner]
				class = (owner and owner.class) or class
			end
			if class then
				set[class] = true
			end
		end
	end
	return set
end

-- one button toggles every class open/closed: if any present class is collapsed,
-- expand them all; otherwise collapse everything
local function ToggleExpandAll()
	local present = PresentClasses()
	local anyCollapsed = false
	for class in pairs(present) do
		if not expanded[class] then
			anyCollapsed = true
			break
		end
	end
	if anyCollapsed then
		for class in pairs(present) do
			expanded[class] = true
		end
	else
		wipe(expanded)
	end
	Window.Refresh()
end

-- the "+" popup runs outside the slash dispatcher's pcall, so errors there
-- would vanish silently; protect and surface them the same way
function Window.ExpectFromPopup(name)
	name = name and name:match("^%s*(%S+)%s*$") -- trim; popup input may have stray spaces
	if not name then
		-- never silent: an unreadable edit box or empty input must say so
		HO.Print("no name entered — '/ho expect <name>' works too")
		return
	end
	local ok, err = pcall(HO.commands["expect"], name)
	if not ok then
		HO.Log("error", "expect: " .. tostring(err))
		HO.Print("error in 'expect' (logged): " .. tostring(err))
	end
end

-- lane swap: first header click selects the source, the second swaps ----------

local swapFrom = nil

function Window.HeaderClick(pally)
	if not pally then
		return
	end
	if not swapFrom then
		swapFrom = pally
		HO.Print(string.format(L["swap: %s selected — click another paladin's name to swap assignments (same name cancels)"], pally))
	elseif swapFrom == pally then
		swapFrom = nil
		HO.Print(L["swap cancelled"])
	else
		local a = swapFrom
		swapFrom = nil
		local ok, err = HO.Plan.SwapPaladins(a, pally)
		if ok then
			HO.Print(string.format(L["assignments swapped: %s and %s"], a, pally))
		else
			HO.Print(L["swap failed: "] .. tostring(err))
		end
	end
	Window.Refresh()
end

-- cell click handlers ---------------------------------------------------------

local function MayEdit(pally)
	local editor = HO.FullName("player")
	if HO.Comm and editor and not HO.Comm.CanEdit(editor, pally) then
		HO.Print("no permission to edit " .. pally .. "'s assignments (in a raid: lead/assist or their open-edit)")
		return false
	end
	return true
end

local function ClassCellClick(cell, mouseBtn)
	if not MayEdit(cell.pally) then
		return
	end
	local plan = HO.Plan.Active()
	local cur = plan.class[cell.pally] and plan.class[cell.pally][cell.classToken]
	if mouseBtn == "RightButton" then
		HO.Plan.SetClassAssignment(cell.pally, cell.classToken, 0)
	elseif IsShiftKeyDown() then
		-- a none marker has no id/mode to cycle; leave it (wheel or a left-click
		-- re-assigns it to a real blessing first)
		if cur and cur.id then
			local nextMode = (cur.mode == "auto" and "greater") or (cur.mode == "greater" and "normal") or "auto"
			HO.Plan.SetClassAssignment(cell.pally, cell.classToken, cur.id, nextMode)
		end
	else
		local nextID = CycleClassBlessing(cell.pally, cur and cur.id or 0)
		HO.Plan.SetClassAssignment(cell.pally, cell.classToken, nextID, cur and cur.mode or nil)
	end
	RefreshAll()
end

local function MemberCellClick(cell, mouseBtn)
	if not MayEdit(cell.pally) then
		return
	end
	local plan = HO.Plan.Active()
	local cur = plan.player[cell.pally] and plan.player[cell.pally][cell.memberName]
	-- pets are excluded from likings: a pet blessing choice is an option, not a
	-- member wish, so it is never recorded as a persistent preference
	local rosterEntry = HO.Roster.byName[cell.memberName]
	local isPet = rosterEntry and rosterEntry.isPet
	if mouseBtn == "RightButton" then
		HO.Plan.SetPlayerOverride(cell.pally, cell.memberName, 0)
		if not isPet then
			HO.Plan.SetMemberPref(cell.memberName, nil) -- clearing the override forgets the liking
		end
	else
		local newID = CycleOverrideBlessing(cell.pally, cur)
		HO.Plan.SetPlayerOverride(cell.pally, cell.memberName, newID)
		if not isPet then
			-- a manual override records the member's liking (0 = cycled to none = forget)
			HO.Plan.SetMemberPref(cell.memberName, newID ~= 0 and newID or nil)
		end
	end
	RefreshAll()
end

local function CellTooltip(cell)
	GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
	if cell.memberName then
		GameTooltip:SetText(cell.memberName)
		local plan = HO.Plan.Active()
		local cur = plan.player[cell.pally] and plan.player[cell.pally][cell.memberName]
		GameTooltip:AddLine(string.format(L["override by %s: %s"], cell.pally, cur and BlessingName(cur) or L["none"]), 1, 1, 1)
		if not cur and cell.inheritedID then
			GameTooltip:AddLine(string.format(L["inherited from class assignment: %s"], BlessingName(cell.inheritedID)), 0.7, 0.7, 0.7)
		end
		-- remembered liking (pets never have one)
		local rosterEntry = HO.Roster.byName[cell.memberName]
		if not (rosterEntry and rosterEntry.isPet) then
			local pref = HO.Plan.MemberPref(cell.memberName)
			if pref then
				GameTooltip:AddLine(string.format(L["remembered preference: %s"], BlessingName(pref)), 0.6, 0.8, 1)
			end
		end
		-- this member's ranked buff requests (yellow, like the cast bar)
		local req = HO.Comm and HO.Comm.requests[cell.memberName]
		if type(req) == "table" and #req > 0 then
			local names = {}
			for i, id in ipairs(req) do
				names[i] = i .. ". " .. BlessingName(id)
			end
			GameTooltip:AddLine(string.format(L["requested: %s"], table.concat(names, "  ")), 0.95, 0.85, 0.15, true)
		end
		GameTooltip:AddLine(L["click: next blessing — right-click: clear"], 0.8, 0.8, 0.8)
	else
		GameTooltip:SetText(cell.classToken)
		local plan = HO.Plan.Active()
		local cur = plan.class[cell.pally] and plan.class[cell.pally][cell.classToken]
		if cur and cur.none then
			GameTooltip:AddLine(L["no blessing assigned"], 1, 1, 1)
		elseif cur then
			GameTooltip:AddLine(cell.pally .. ": " .. BlessingName(cur.id), 1, 1, 1)
			local n = cell.memberCount or 0
			local min = HO.db.options.greaterMin or 2
			if cur.mode == "auto" then
				-- the engine decides greater vs singles from eligible castable
				-- members, symbol count and greater-known; prefer its verdict
				-- when available, else fall back to the raw member-count heuristic
				local useGreater
				if HO.Engine and HO.Engine.WouldUseGreater then
					useGreater = HO.Engine.WouldUseGreater(cell.classToken)
				end
				if useGreater == nil then
					useGreater = (n >= min)
				end
				local effective = useGreater
					and L["greater (30 min, whole class, 1 Symbol of Kings)"]
					or L["10-min singles (too few members for greater)"]
				GameTooltip:AddLine(string.format(L["mode: auto — greater from %d+ members, singles otherwise"], min), 0.9, 0.9, 0.9, true)
				GameTooltip:AddLine(string.format(L["with %d member(s) now: %s"], n, effective), 0.6, 1, 0.6, true)
			elseif cur.mode == "greater" then
				GameTooltip:AddLine(L["mode: greater — always the Greater Blessing: 30 min, hits the whole class, costs a Symbol of Kings per cast"], 0.9, 0.9, 0.9, true)
			else
				GameTooltip:AddLine(L["mode: normal — always 10-min single blessings on each member, no reagent"], 0.9, 0.9, 0.9, true)
			end
		else
			GameTooltip:AddLine(cell.pally .. ": " .. L["no assignment"], 1, 1, 1)
		end
		GameTooltip:AddLine(L["click: next blessing — right-click: clear"], 0.8, 0.8, 0.8)
		GameTooltip:AddLine(L["shift-click: change the cast mode"], 0.8, 0.8, 0.8)
	end
	GameTooltip:Show()
end

-- widget construction ---------------------------------------------------------

local function CreateCell(parent)
	local cell = CreateFrame("Button", nil, parent)
	cell:SetSize(COL_W - COL_GAP, ROW_H - 4)
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	cell.bg = cell:CreateTexture(nil, "BACKGROUND")
	cell.bg:SetAllPoints()
	cell.bg:SetColorTexture(1, 1, 1, 0.06)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("CENTER")
	cell.icon:SetSize(ICON_SIZE, ICON_SIZE)
	HO.Skin.MaskIcon(cell.icon)
	-- static neutral rounded frame around the icon; the window is an editor, so
	-- there is no green/red status colour on cells (mirrors the bar's neutral gold)
	cell.frame = cell:CreateTexture(nil, "OVERLAY", nil, 1)
	cell.frame:SetPoint("TOPLEFT", cell.icon, "TOPLEFT", -1, 1)
	cell.frame:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", 1, -1)
	cell.frame:SetTexture(HO.Skin.IconFrame())
	cell.frame:SetVertexColor(0.5, 0.42, 0.22, 0.7)
	cell.mode = cell:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
	-- nudged out toward the bottom-right corner so the big letter clears the icon
	cell.mode:SetPoint("BOTTOMRIGHT", 4, -4)
	cell.mode:SetDrawLayer("OVERLAY", 5) -- above the icon and frame
	local mf, ms = cell.mode:GetFont()
	cell.mode:SetFont(mf, (ms or 12) + 3, "THICKOUTLINE") -- larger, outlined for contrast
	cell:SetScript("OnEnter", CellTooltip)
	cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
	cell.hoCell = true -- marks our cells for the tooltip re-render check
	return cell
end

local function AcquireRow(pool, index, height, labelIndent)
	labelIndent = labelIndent or 0
	local row = pool[index]
	if not row then
		row = CreateFrame("Frame", nil, win)
		row:SetHeight(height)
		row.cells = {}
		row.label = CreateFrame("Button", nil, row)
		-- indent the label only (not the row), so cells stay aligned with the
		-- class-row cells and the column headers
		row.label:SetPoint("LEFT", 4 + labelIndent, 0)
		row.label:SetSize(NAME_W - 8 - labelIndent, height)
		row.label.text = row.label:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
		row.label.text:SetPoint("LEFT", 2, 0)
		row.label.text:SetJustifyH("LEFT")
		-- bound to the label area (never into the cell columns) and truncate instead
		-- of wrapping; member rows narrow this further to make room for pref icons
		row.label.defaultTextWidth = NAME_W - 12 - labelIndent
		row.label.text:SetWidth(row.label.defaultTextWidth)
		row.label.text:SetWordWrap(false)
		pool[index] = row
	end
	row:SetHeight(height)
	return row
end

-- a member's ranked buff-request icons, right-aligned in the label area (rank 1
-- leftmost) with a small priority badge on each. Only the top MAX_ROW_PREFS are
-- drawn on the row; the tooltip lists the whole chain. Returns the pixel width the
-- strip consumes so the name text can be narrowed to never run under it.
local function RenderMemberPrefs(mrow, list)
	mrow.prefIcons = mrow.prefIcons or {}
	local count = math.min(list and #list or 0, MAX_ROW_PREFS)
	for i = 1, count do
		local w = mrow.prefIcons[i]
		if not w then
			w = {}
			w.tex = mrow:CreateTexture(nil, "OVERLAY")
			w.tex:SetSize(PREF_ICON, PREF_ICON)
			w.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			w.rank = mrow:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
			w.rank:SetPoint("BOTTOMRIGHT", w.tex, "BOTTOMRIGHT", 1, -1)
			w.rank:SetDrawLayer("OVERLAY", 2)
			local f, s = w.rank:GetFont()
			w.rank:SetFont(f, (s or 10), "THICKOUTLINE")
			mrow.prefIcons[i] = w
		end
		local blessing = HO.Data.blessings[list[i]]
		w.tex:SetTexture((blessing and blessing.icon) or EMPTY_SLOT)
		w.tex:ClearAllPoints()
		local x = (NAME_W - 4) - count * PREF_STEP + (i - 1) * PREF_STEP
		w.tex:SetPoint("LEFT", mrow, "LEFT", x, 0)
		w.rank:SetText(tostring(i))
		w.tex:Show()
		w.rank:Show()
	end
	for i = count + 1, #mrow.prefIcons do
		mrow.prefIcons[i].tex:Hide()
		mrow.prefIcons[i].rank:Hide()
	end
	return count > 0 and (count * PREF_STEP + 4) or 0
end

local function RowCell(row, colIndex, clickHandler)
	local cell = row.cells[colIndex]
	if not cell then
		cell = CreateCell(row)
		cell:SetPoint("LEFT", row, "LEFT", NAME_W + (colIndex - 1) * COL_W, 0)
		row.cells[colIndex] = cell
	end
	cell:SetScript("OnClick", clickHandler)
	return cell
end

-- aura strip ------------------------------------------------------------------

-- ring of aura choices for a paladin: my own column offers only auras I know
-- (matching the bar); assigning for another paladin offers every aura (their
-- known set is not synced). None (0) always closes the ring.
local function AuraRing(pally)
	local me = HO.FullName("player")
	local ring
	if pally == me then
		ring = HO.Data.KnownAuras()
	else
		ring = {}
		for id = 1, HO.Data.NUM_AURAS do
			ring[id] = id
		end
	end
	ring[#ring + 1] = 0
	return ring
end

local function NextAura(pally, delta)
	local ring = AuraRing(pally)
	local cur = HO.Plan.GetAura(pally) or 0
	local idx = #ring -- default to the none slot (also covers an unknown current aura)
	for i, id in ipairs(ring) do
		if id == cur then
			idx = i
			break
		end
	end
	local nextIdx = ((idx - 1 + (delta or 1)) % #ring) + 1
	return ring[nextIdx]
end

local function AuraCellClick(cell, mouseBtn)
	if not MayEdit(cell.pally) then
		return
	end
	if mouseBtn == "RightButton" then
		HO.Plan.SetAura(cell.pally, 0)
	else
		HO.Plan.SetAura(cell.pally, NextAura(cell.pally, 1))
	end
	RefreshAll()
end

local function AuraCellTooltip(cell)
	GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
	GameTooltip:SetText(cell.pally)
	local id = HO.Plan.GetAura(cell.pally)
	local name = id and HO.Data.AuraName(id)
	GameTooltip:AddLine(string.format(L["aura: %s"], name or L["none"]), 1, 1, 1)
	GameTooltip:AddLine(L["click: next aura — right-click: clear"], 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function AuraRowCell(row, colIndex)
	local cell = row.cells[colIndex]
	if not cell then
		cell = CreateFrame("Button", nil, row)
		cell:SetSize(COL_W - COL_GAP, ROW_H - 4)
		cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cell.bg = cell:CreateTexture(nil, "BACKGROUND")
		cell.bg:SetAllPoints()
		cell.bg:SetColorTexture(0.20, 0.20, 0.55, 0.20) -- blue tint marks the aura strip
		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetPoint("CENTER")
		cell.icon:SetSize(ICON_SIZE, ICON_SIZE)
		HO.Skin.MaskIcon(cell.icon)
		-- static neutral rounded frame around the icon (editor: no status colour)
		cell.frame = cell:CreateTexture(nil, "OVERLAY", nil, 1)
		cell.frame:SetPoint("TOPLEFT", cell.icon, "TOPLEFT", -1, 1)
		cell.frame:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", 1, -1)
		cell.frame:SetTexture(HO.Skin.IconFrame())
		cell.frame:SetVertexColor(0.5, 0.42, 0.22, 0.7)
		cell:SetScript("OnEnter", AuraCellTooltip)
		cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
		cell:SetScript("OnClick", AuraCellClick)
		cell.hoCell = true -- re-render an open tooltip after a refresh
		cell:SetPoint("LEFT", row, "LEFT", NAME_W + (colIndex - 1) * COL_W, 0)
		row.cells[colIndex] = cell
	end
	return cell
end

local function AcquireAuraRow()
	if not auraRow then
		local row = CreateFrame("Frame", nil, win)
		row:SetHeight(ROW_H)
		row.cells = {}
		row.label = row:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
		row.label:SetPoint("LEFT", 6, 0)
		row.label:SetJustifyH("LEFT")
		row.label:SetText(L["Aura"])
		auraRow = row
	end
	return auraRow
end

-- user-configurable UI scale for the assignment window. Non-secure, so it is
-- safe to apply any time (unlike the cast bar).
function Window.ApplyScale()
	if win then
		win:SetScale((HO.db.options.window and HO.db.options.window.scale) or 1)
	end
end

-- the window position persists in SavedVariables so it opens where the user left
-- it, not always re-centered. The client re-anchors a dragged frame to the
-- nearest corner, so the full anchor is saved (point + relPoint + offsets).
local function SaveWindowPos()
	if not win then
		return
	end
	local point, _, relPoint, x, y = win:GetPoint()
	HO.db.options.window = HO.db.options.window or {}
	HO.db.options.window.pos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestoreWindowPos()
	local pos = HO.db.options.window and HO.db.options.window.pos
	win:ClearAllPoints()
	if pos and pos.point then
		win:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		win:SetPoint("CENTER")
	end
end

function Window.Create()
	if win then
		return
	end
	win = CreateFrame("Frame", "HolyOrdersWindow", UIParent, "BackdropTemplate")
	-- MEDIUM (standard panel strata) so higher-priority windows like the calendar
	-- draw cleanly OVER us instead of interleaving/bleeding through at HIGH
	win:SetFrameStrata("MEDIUM")
	win:SetMovable(true)
	win:SetClampedToScreen(true)
	win:EnableMouse(true)
	win:EnableMouseWheel(true)
	win:SetScript("OnMouseWheel", function(_, delta)
		-- wheel scrolls whole rows; cell/label child buttons don't register the
		-- wheel, so the event propagates up here. Refresh re-clamps the offset.
		scrollOffset = scrollOffset - delta * 3 * ROW_H
		if scrollOffset < 0 then
			scrollOffset = 0
		end
		Window.Refresh()
	end)
	RestoreWindowPos() -- open where the user left it (persisted), else centered
	win:Hide()
	table.insert(UISpecialFrames, "HolyOrdersWindow")

	HO.Skin.Panel(win) -- dark rounded panel + thin gold border (decorative; tracks size)

	-- addon crest tucked into the bottom-right corner. It draws on ARTWORK, so every
	-- row/cell/header/hint renders over it: in a full roster the grid covers it, in a
	-- small one it shows as an emblem in the empty area. The hint is bounded to its
	-- left (below) so its text never runs across the crest.
	win.brand = win:CreateTexture(nil, "ARTWORK")
	win.brand:SetSize(64, 64)
	win.brand:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 6)
	win.brand:SetTexture(HO.Skin.tex.logo)
	win.brand:SetAlpha(0.9)
	if not HO.Skin.Decorated() then
		win.brand:Hide() -- the crest belongs to decorated skins only
	end

	win.header = CreateFrame("Frame", nil, win)
	win.header:SetPoint("TOPLEFT")
	win.header:SetPoint("TOPRIGHT")
	win.header:SetHeight(HEADER_H)
	win.header:EnableMouse(true)
	win.header:RegisterForDrag("LeftButton")
	win.header:SetScript("OnDragStart", function() win:StartMoving() end)
	win.header:SetScript("OnDragStop", function()
		win:StopMovingOrSizing()
		SaveWindowPos()
	end)
	-- blue title gem, then the title text, then a gold seam under the header row
	win.header.gem = win.header:CreateTexture(nil, "ARTWORK")
	win.header.gem:SetSize(18, 18)
	win.header.gem:SetPoint("LEFT", 8, 0)
	win.header.gem:SetTexture(HO.Skin.tex.gem)
	win.header.title = win.header:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
	if HO.Skin.Decorated() then
		win.header.title:SetPoint("LEFT", win.header.gem, "RIGHT", 6, 0)
	else
		-- undecorated skins drop the gem for a plainer header
		win.header.gem:Hide()
		win.header.title:SetPoint("LEFT", 10, 0)
	end
	win.header.title:SetText(L["HolyOrders — Assignments"])
	win.header.title:SetTextColor(HO.Colors.rgb("goldBright"))
	win.seam = HO.Skin.Seam(win, -HEADER_H)

	-- expand/collapse-all toggle: sits in the header row, just left of the
	-- No Salv button (anchored below, once that button exists)
	win.expandBtn = CreateFrame("Button", nil, win.header, "UIPanelButtonTemplate")
	win.expandBtn:SetSize(24, 20)
	win.expandBtn:SetText("+")
	HO.Skin.Button(win.expandBtn)
	win.expandBtn:SetScript("OnClick", ToggleExpandAll)
	win.expandBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["expand or collapse all classes"], 1, 1, 1)
		GameTooltip:Show()
	end)
	win.expandBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- parent the close button to the window, not the header: the template's
	-- default OnClick hides its PARENT, which used to hide only the title bar
	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
	close:SetSize(22, 22)
	close:SetFrameLevel(win.header:GetFrameLevel() + 1)
	HO.Skin.CloseButton(close)
	close:SetScript("OnClick", function()
		win:Hide()
	end)

	local function HeaderButton(text, offsetX, onClick, tooltip)
		local btn = CreateFrame("Button", nil, win.header, "UIPanelButtonTemplate")
		btn:SetSize(60, 20)
		btn:SetPoint("RIGHT", win.header, "RIGHT", offsetX, 0)
		btn:SetText(text)
		HO.Skin.Button(btn)
		btn:SetScript("OnClick", onClick)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tooltip, 1, 1, 1)
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return btn
	end

	HeaderButton("Auto", -30, function()
		local ok, msg = HO.Planner.Run()
		HO.Print(ok and ("auto-plan: " .. msg) or ("auto-plan failed: " .. msg))
		RefreshAll()
	end, L["Run the deterministic auto-planner"])
	HeaderButton("Rebuff", -94, function()
		HO.Bar.ToggleForceRebuff()
	end, L["Force rebuff: refresh everything before the pull"])
	HeaderButton(L["Save"], -158, function()
		local sig = HO.Plan.Save()
		HO.Print(sig and ("plan saved for roster: " .. sig) or "cannot save: no paladins in roster")
	end, L["Save the current plan for this paladin roster"])
	win.salvBtn = HeaderButton(L["No-Salv OFF"], -222, function()
		HO.commands["nosalv"]("")
	end, L["Encounter toggle: swap Salvation for substitutes, click again to restore the previous plan (lead/assist)"])
	win.salvBtn:SetSize(76, 20) -- state label is wider than the other buttons'
	-- place the expand/collapse-all toggle just left of the No Salv button
	win.expandBtn:SetPoint("RIGHT", win.salvBtn, "LEFT", -6, 0)

	win.colHeader = {}

	-- "+" column button: pre-plan a paladin who has not joined yet
	StaticPopupDialogs["HOLYORDERS_EXPECT"] = StaticPopupDialogs["HOLYORDERS_EXPECT"] or {
		text = "HolyOrders: %s",
		button1 = _G.ACCEPT or "OK",
		button2 = _G.CANCEL or "Cancel",
		hasEditBox = true,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3, -- avoid tainting the default popup slots
		-- name autocompletion from friends, guild and recent contacts; the
		-- INVITE preset excludes people already in the group — exactly the
		-- pool expected paladins come from. All guarded: without the API the
		-- popup is a plain edit box.
		autoCompleteSource = GetAutoCompleteResults,
		autoCompleteArgs = (AUTOCOMPLETE_LIST and AUTOCOMPLETE_LIST.INVITE)
			and { AUTOCOMPLETE_LIST.INVITE.include, AUTOCOMPLETE_LIST.INVITE.exclude } or nil,
		OnAccept = function(self)
			-- the editBox property is not guaranteed on this client: fall back
			-- to resolving the child frame by its global name
			local eb = self.editBox or (self.GetName and _G[(self:GetName() or "") .. "EditBox"])
			Window.ExpectFromPopup(eb and eb:GetText())
		end,
		EditBoxOnEnterPressed = function(self)
			-- enter first accepts a highlighted autocomplete suggestion; only
			-- an enter the autocomplete did not consume submits the name
			if AutoCompleteEditBox_OnEnterPressed and AutoCompleteEditBox_OnEnterPressed(self) then
				return
			end
			-- self IS the edit box here; read it directly before hiding
			local text = self:GetText()
			self:GetParent():Hide()
			Window.ExpectFromPopup(text)
		end,
		EditBoxOnEscapePressed = function(self)
			self:GetParent():Hide()
		end,
	}
	win.addPallyBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	win.addPallyBtn:SetSize(22, 18)
	win.addPallyBtn:SetText("+")
	HO.Skin.Button(win.addPallyBtn)
	win.addPallyBtn:SetScript("OnClick", function()
		local dialog = StaticPopup_Show("HOLYORDERS_EXPECT", L["Pre-plan a paladin who has not joined yet — enter their name:"])
		-- the popup's edit box does not forward Tab to the autocomplete (only
		-- dedicated autocomplete boxes do), so its "Press Tab" hint was dead;
		-- hook once per recycled popup frame
		local eb = dialog and (dialog.editBox or (dialog.GetName and _G[(dialog:GetName() or "") .. "EditBox"]))
		if eb and AutoCompleteEditBox_OnTabPressed and not eb.hoTabHooked then
			eb.hoTabHooked = true
			eb:HookScript("OnTabPressed", function(self)
				AutoCompleteEditBox_OnTabPressed(self)
			end)
		end
	end)
	win.addPallyBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Add an expected paladin: assign their blessings before they join"], 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	win.addPallyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- sync lock: while a plan snapshot stream or a pull settle window is
	-- active, the window dims, swallows clicks and shows a spinner; it
	-- releases itself the moment the sync is over (checked 4x/second)
	win.syncOverlay = CreateFrame("Frame", nil, win)
	win.syncOverlay:SetAllPoints(win)
	win.syncOverlay:SetFrameLevel(win:GetFrameLevel() + 40)
	win.syncOverlay:EnableMouse(true) -- the lock: clicks stop here
	local dim = win.syncOverlay:CreateTexture(nil, "BACKGROUND")
	dim:SetAllPoints()
	dim:SetColorTexture(0, 0, 0, 0.55)
	win.syncOverlay.spin = win.syncOverlay:CreateTexture(nil, "ARTWORK")
	win.syncOverlay.spin:SetSize(28, 28)
	win.syncOverlay.spin:SetPoint("CENTER", 0, 14)
	win.syncOverlay.spin:SetTexture("Interface\\COMMON\\StreamCircle")
	win.syncOverlay.spin:SetVertexColor(HO.Colors.rgb("goldBright", 1))
	local spinAnim = win.syncOverlay.spin:CreateAnimationGroup()
	local spinRot = spinAnim:CreateAnimation("Rotation")
	spinRot:SetDegrees(-360)
	spinRot:SetDuration(1.5)
	spinAnim:SetLooping("REPEAT")
	local syncLabel = win.syncOverlay:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
	syncLabel:SetPoint("TOP", win.syncOverlay.spin, "BOTTOM", 0, -8)
	syncLabel:SetText(L["Synchronizing with the group..."])
	win.syncOverlay:SetScript("OnShow", function() spinAnim:Play() end)
	win.syncOverlay:SetScript("OnHide", function() spinAnim:Stop() end)
	win.syncOverlay:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 0.25 then
			self.t = 0
			if not (HO.Comm and HO.Comm.SyncActive and HO.Comm.SyncActive()) then
				self:Hide()
				Window.Refresh() -- show the settled state immediately
			end
		end
	end)
	win.syncOverlay:Hide()

	win.hint = win:CreateFontString(nil, "OVERLAY", "HolyOrdersFontDisableSmall")
	win.hint:SetPoint("BOTTOMLEFT", 10, 6)
	win.hint:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -78, 6) -- clear the corner crest
	win.hint:SetJustifyH("LEFT")

	Window.ApplyScale() -- apply the saved window scale on first open
	win.built = true -- set last: Refresh bails if Create ever errors partway
end

-- layout ----------------------------------------------------------------------

-- expand a class row (so its member rows and their override cells are shown) and
-- refresh. Called when an edit elsewhere — the cast-bar fly-out — changes a
-- member override, so the change is visible instead of hidden under a collapsed
-- class row (a per-member override only appears in the expanded member row).
function Window.Expand(classToken)
	if not classToken then
		return
	end
	expanded[classToken] = true
	if win and win:IsShown() then
		Window.Refresh()
	end
end

function Window.Refresh()
	-- win.built guards against a half-constructed window (Create erroring partway):
	-- refreshing one would crash on a nil child widget instead of failing quietly
	if not win or not win.built or not win:IsShown() then
		return
	end
	-- reflect the sync state on the lock overlay (it hides itself when done)
	if win.syncOverlay then
		local syncing = HO.Comm and HO.Comm.SyncActive and HO.Comm.SyncActive()
		if syncing and not win.syncOverlay:IsShown() then
			win.syncOverlay:Show()
		elseif not syncing and win.syncOverlay:IsShown() then
			win.syncOverlay:Hide()
		end
	end

	local plan = HO.Plan.Active()
	local pallys = HO.Roster.Paladins()
	-- expected paladins get columns after the present ones, greyed in the header
	local expectedCol = {}
	for _, name in ipairs(HO.Plan.Expected()) do
		pallys[#pallys + 1] = name
		expectedCol[name] = true
	end
	local numCols = math.min(#pallys, MAX_COLS)

	-- reflect the expand/collapse-all state on its toggle ("-" = all open)
	if win.expandBtn then
		local present, allExpanded, hasAny = PresentClasses(), true, false
		for class in pairs(present) do
			hasAny = true
			if not expanded[class] then
				allExpanded = false
				break
			end
		end
		win.expandBtn:SetText((hasAny and allExpanded) and "-" or "+")
	end

	if win.salvBtn then
		-- English labels show the MODE state (No-Salv ON = mode running); the
		-- German localization deliberately uses action labels instead
		local active = HO.Plan.NoSalvationActive() or HO.db.noSalvBy
		win.salvBtn:SetText(active and ("|cffff4040" .. L["No-Salv ON"] .. "|r") or L["No-Salv OFF"])
	end
	-- four short plain-language lines: icon clicks, name clicks (spec/tank),
	-- then what the three cast-mode letters on the icons mean
	win.hint:SetText(L["Click an icon = pick a blessing · right-click = remove · class name = show members"] .. "\n"
		.. L["Click a member's name = change their spec/role · right-click the name = mark as tank"] .. "\n"
		.. L["Shift-click an icon changes how it is cast:"] .. "\n"
		.. string.format(L["|cff40c0ffA|r automatic: big from %d members, small otherwise — |cffffd100G|r always big (whole class, 1 Symbol) — |cff40ff40S|r always small (10 min each)"], HO.db.options.greaterMin or 2))

	-- column headers (paladin short names): clickable — click one name, then
	-- another, to swap the two paladins' complete assignments (lane swap)
	for c = 1, numCols do
		local btn = win.colHeader[c]
		if not btn then
			btn = CreateFrame("Button", nil, win)
			btn:SetHeight(14)
			btn.text = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
			btn.text:SetAllPoints(btn)
			btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			btn:SetScript("OnClick", function(self, mouseBtn)
				if mouseBtn == "RightButton" then
					-- right-click removes an EXPECTED paladin's column; present
					-- paladins leave with their group, not with a click
					if self.expected then
						HO.Plan.ToggleExpected(self.pally)
						HO.Print(self.pally .. " removed from the expected list (their pre-planned row is kept)")
						Window.Refresh()
					end
				else
					Window.HeaderClick(self.pally)
				end
			end)
			btn:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:SetText(self.pally, 1, 1, 1)
				GameTooltip:AddLine(L["Click a paladin's name, then another, to swap their assignments"], nil, nil, nil, true)
				if self.expected then
					GameTooltip:AddLine(L["Right-click removes this expected paladin"], nil, nil, nil, true)
				end
				GameTooltip:Show()
			end)
			btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
			win.colHeader[c] = btn
		end
		btn.pally = pallys[c]
		btn.expected = expectedCol[pallys[c]] or nil
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", win, "TOPLEFT", NAME_W + (c - 1) * COL_W, -(HEADER_H + 4))
		btn:SetWidth(COL_W - COL_GAP)
		local short = pallys[c]:match("^([^%-]+)") or pallys[c]
		short = Utf8Truncate(short, HEADER_MAX_CHARS)
		if swapFrom == pallys[c] then
			short = "|cffffff00" .. short .. "|r" -- selected as swap source
		elseif expectedCol[pallys[c]] then
			short = "|cff9d9d9d" .. short .. "|r" -- grey = pre-planned, not in the group yet
		end
		btn.text:SetText(short)
		btn:Show()
	end
	for c = numCols + 1, #win.colHeader do
		win.colHeader[c]:Hide()
	end

	-- "+" adds an expected paladin's column (see /ho expect); hidden when full
	if win.addPallyBtn then
		if numCols < MAX_COLS then
			win.addPallyBtn:ClearAllPoints()
			win.addPallyBtn:SetPoint("TOPLEFT", win, "TOPLEFT", NAME_W + numCols * COL_W + 2, -(HEADER_H + 1))
			win.addPallyBtn:Show()
		else
			win.addPallyBtn:Hide()
		end
	end

	-- group roster members and pets by class
	local members = {} -- [classToken] = { playerEntry, ... }
	local petsByClass = {} -- [classToken] = { petEntry, ... }
	for _, entry in ipairs(HO.Roster.units) do
		if entry.class and entry.name then
			local bucket = entry.isPet and petsByClass or members
			local key = entry.class
			if entry.isPet then
				-- pets are listed under their OWNER's class
				local ownerEntry = entry.owner and HO.Roster.byName[entry.owner]
				key = (ownerEntry and ownerEntry.class) or entry.class
			end
			bucket[key] = bucket[key] or {}
			table.insert(bucket[key], entry)
		end
	end
	local function SortByName(a, b)
		return (a.name or "") < (b.name or "")
	end
	for _, list in pairs(members) do
		table.sort(list, SortByName)
	end
	for _, list in pairs(petsByClass) do
		table.sort(list, SortByName)
	end

	local y = HEADER_H + FIRST_ROW_OFFSET
	local classIndex, memberIndex = 0, 0
	local placed = {} -- { {frame, y, h}, ... } positioned after contentHeight is known

	-- aura strip: one row above the class grid, a cell per paladin column showing
	-- that paladin's assigned aura (left-click cycles, right-click clears)
	do
		local row = AcquireAuraRow()
		placed[#placed + 1] = { frame = row, y = y, h = ROW_H }
		for c = 1, numCols do
			local cell = AuraRowCell(row, c)
			cell.pally = pallys[c]
			local id = HO.Plan.GetAura(pallys[c])
			local aura = id and HO.Data.auras[id]
			cell.icon:SetTexture((aura and aura.icon) or NONE_ICON)
			cell.icon:SetDesaturated(false)
			cell:Show()
		end
		for c = numCols + 1, #row.cells do
			row.cells[c]:Hide()
		end
		y = y + ROW_H
	end

	for _, classToken in ipairs(CLASS_ORDER) do
		local list = members[classToken]
		local petList = petsByClass[classToken]
		if list or petList then
			local playerCount = list and #list or 0
			local petCount = petList and #petList or 0
			classIndex = classIndex + 1
			local row = AcquireRow(classRows, classIndex, ROW_H)
			placed[#placed + 1] = { frame = row, y = y, h = ROW_H }
			row.label.text:SetText((expanded[classToken] and "- " or "+ ") .. classToken
				.. " (" .. playerCount .. (petCount > 0 and ("+" .. petCount .. " pets") or "") .. ")")
			row.label:SetScript("OnClick", function()
				expanded[classToken] = not expanded[classToken] or nil
				Window.Refresh()
			end)
			for c = 1, numCols do
				local cell = RowCell(row, c, ClassCellClick)
				cell.pally, cell.classToken, cell.memberName = pallys[c], classToken, nil
				cell.memberCount = playerCount
				local cur = plan.class[pallys[c]] and plan.class[pallys[c]][classToken]
				if cur and cur.none then
					-- explicit-none: a visible placeholder (no mode tag) the user can
					-- wheel/click back to a real blessing
					cell.icon:SetTexture(NONE_ICON)
					cell.icon:SetDesaturated(false)
					cell.mode:SetText("")
				elseif cur then
					cell.icon:SetTexture(HO.Data.blessings[cur.id] and HO.Data.blessings[cur.id].icon or EMPTY_SLOT)
					cell.icon:SetDesaturated(false)
					cell.mode:SetText(MODE_TAG[cur.mode] or "")
				else
					cell.icon:SetTexture(EMPTY_SLOT)
					cell.icon:SetDesaturated(true)
					cell.mode:SetText("")
				end
				cell:Show()
			end
			for c = numCols + 1, #row.cells do
				row.cells[c]:Hide()
			end
			y = y + ROW_H

			if expanded[classToken] then
				local rows = {}
				if list then
					for _, e in ipairs(list) do
						table.insert(rows, e)
					end
				end
				if petList then
					for _, e in ipairs(petList) do
						table.insert(rows, e)
					end
				end
				for _, entry in ipairs(rows) do
					memberIndex = memberIndex + 1
					local mrow = AcquireRow(memberRows, memberIndex, MEMBER_ROW_H, LABEL_INDENT)
					placed[#placed + 1] = { frame = mrow, y = y, h = MEMBER_ROW_H }
					local short = entry.name:match("^([^%-]+)") or entry.name
					if entry.isPet then
						local ownerShort = entry.owner and (entry.owner:match("^([^%-]+)") or entry.owner) or "?"
						mrow.label.text:SetText(short .. " |cff9d9d9d" .. string.format(L["(pet of %s)"], ownerShort) .. "|r")
						mrow.label:SetScript("OnClick", nil)
					else
						local isTank = HO.Plan.IsTank(entry.name, entry.tankRole)
						local spec = HO.db.specCache[entry.name]
						mrow.label.text:SetText(short
							.. (spec and (" |cff9d9d9d(" .. spec .. ")|r") or "")
							.. (isTank and (" |cffff6060" .. L["[tank]"] .. "|r") or ""))
						mrow.label:SetScript("OnClick", function(_, mouseBtn)
							if mouseBtn == "RightButton" then
								if HO.Comm and not HO.Comm.CanFlagTank(entry.name) then
									HO.Print(L["in a raid only lead/assist may flag others as tank"])
									return
								end
								local flagged = HO.Plan.ToggleTank(entry.name)
								HO.Print(entry.name .. (flagged and " flagged as tank" or " unflagged as tank"))
							else
								-- cycle spec tag: none -> spec1..specN -> other -> none.
								-- "other" is a real, durable tag ("none of the special
								-- specs", e.g. a dps warrior): it pins the member as
								-- NOT-protection so a bad auto-inference can be overruled.
								local ring = {}
								for _, s in ipairs(HO.Planner.ValidSpecs(entry.class)) do
									ring[#ring + 1] = s
								end
								if #ring > 0 then
									ring[#ring + 1] = "other"
									local cur = HO.db.specCache[entry.name]
									local nextSpec = ring[1]
									for i, s in ipairs(ring) do
										if s == cur then
											nextSpec = ring[i + 1]
											break
										end
									end
									HO.db.specCache[entry.name] = nextSpec
									-- a hand-set tag is authoritative (never re-inspected);
									-- cycling back to none returns it to auto-inference
									HO.db.specManual = HO.db.specManual or {}
									HO.db.specManual[entry.name] = nextSpec and true or nil
									if HO.Comm and HO.Comm.SendSpecTag and nextSpec then
										HO.Comm.SendSpecTag(entry.name, nextSpec)
									end
								end
							end
							RefreshAll()
						end)
					end
					-- ranked request icons (pets never request); narrow the name text
					-- so it never runs under the strip
					local prefList = (not entry.isPet) and HO.Comm and HO.Comm.requests[entry.name] or nil
					local prefWidth = RenderMemberPrefs(mrow, prefList)
					mrow.label.text:SetWidth((mrow.label.defaultTextWidth or (NAME_W - 12 - LABEL_INDENT)) - prefWidth)
					mrow.label:RegisterForClicks("LeftButtonUp", "RightButtonUp")
					for c = 1, numCols do
						local cell = RowCell(mrow, c, MemberCellClick)
						cell.pally, cell.classToken, cell.memberName = pallys[c], nil, entry.name
						local cur = plan.player[pallys[c]] and plan.player[pallys[c]][entry.name]
						-- no override: show what this member effectively gets
						-- from that paladin's class assignment (dimmed)
						local inheritedID
						if not cur then
							if entry.isPet then
								if HO.Engine.PetIncluded(entry) then
									local ownerEntry = entry.owner and HO.Roster.byName[entry.owner]
									local ownerClass = ownerEntry and ownerEntry.class
									local ownerAssign = ownerClass and plan.class[pallys[c]] and plan.class[pallys[c]][ownerClass]
									-- a none-marked owner class inherits nothing to its pets
									if ownerAssign and ownerAssign.id then
										inheritedID = (HO.db.options.pets and HO.db.options.pets.blessing) or 2
									end
								end
							else
								local classAssign = plan.class[pallys[c]] and plan.class[pallys[c]][entry.class]
								-- a none-marked class assignment (no id) inherits NOTHING: the
								-- member cell shows empty, not a none icon
								if classAssign and classAssign.id and HO.Data.IsAllowed(classAssign.id, HO.Plan.IsTank(entry.name, entry.tankRole)) then
									inheritedID = classAssign.id
								end
							end
						end
						cell.inheritedID = inheritedID
						if cur then
							cell.icon:SetTexture(HO.Data.blessings[cur] and HO.Data.blessings[cur].icon or EMPTY_SLOT)
							cell.icon:SetDesaturated(false)
							cell.icon:SetAlpha(1)
						elseif inheritedID then
							cell.icon:SetTexture(HO.Data.blessings[inheritedID] and HO.Data.blessings[inheritedID].icon or EMPTY_SLOT)
							cell.icon:SetDesaturated(false)
							cell.icon:SetAlpha(0.45)
						else
							cell.icon:SetTexture(EMPTY_SLOT)
							cell.icon:SetDesaturated(true)
							cell.icon:SetAlpha(1)
						end
						cell.mode:SetText("")
						cell:Show()
					end
					for c = numCols + 1, #mrow.cells do
						mrow.cells[c]:Hide()
					end
					y = y + MEMBER_ROW_H
				end
			end
		end
	end
	for i = classIndex + 1, #classRows do
		classRows[i]:Hide()
	end
	for i = memberIndex + 1, #memberRows do
		memberRows[i]:Hide()
	end

	-- virtual scroll: clamp the window to MAX_WIN_H and shift every row by
	-- scrollOffset, hiding any that would fall into the fixed header area or past
	-- the visible bottom. Headers and the top button bar are not in `placed`, so
	-- they stay fixed. When the content fits, offset is forced to 0 (show all).
	local contentHeight = y
	local viewHeight = math.min(contentHeight, MAX_WIN_H)
	local scrolling = contentHeight > viewHeight
	if scrolling then
		local maxOffset = contentHeight - viewHeight
		if scrollOffset < 0 then
			scrollOffset = 0
		elseif scrollOffset > maxOffset then
			scrollOffset = maxOffset
		end
	else
		scrollOffset = 0
	end
	local firstRowY = HEADER_H + FIRST_ROW_OFFSET
	for _, p in ipairs(placed) do
		local top = p.y - scrollOffset
		p.frame:ClearAllPoints()
		p.frame:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -top)
		p.frame:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -top)
		if scrolling and (top < firstRowY or top + p.h > viewHeight) then
			p.frame:Hide()
		else
			p.frame:Show()
		end
	end

	-- reserve one extra column of width while the "+" add button is shown
	local addW = (numCols < MAX_COLS) and COL_W or 0
	win:SetSize(math.max(NAME_W + numCols * COL_W + addW + PAD, 520), viewHeight + BOTTOM_PAD)

	-- a tooltip open over a cell now describes a repurposed cell; a single
	-- owner check re-renders it (or hides it if the cell went away)
	local owner = GameTooltip:GetOwner()
	if owner and owner.hoCell then
		if owner:IsShown() then
			local onEnter = owner:GetScript("OnEnter")
			if onEnter then
				onEnter(owner)
			end
		else
			GameTooltip:Hide()
		end
	end
end

function Window.Toggle()
	Window.Create()
	if win:IsShown() then
		win:Hide()
	else
		win.header:Show() -- defensive: never present a headless window
		win:Show()
		Window.Refresh()
	end
end

HO.RegisterEvent("PLAYER_LOGIN", function()
	HO.Roster.OnChanged(function()
		Window.Refresh()
	end)
end)
