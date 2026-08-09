-- HolyOrders — secure cast bar
-- One button per class duty; clicking casts the engine's chosen blessing on
-- its chosen target. Secure attributes and the icon that mirrors them only
-- change out of combat, so the display always matches the actual cast.

local HO = HolyOrders
local Bar = {}
HO.Bar = Bar
local L = HO.L

local BUTTON_SIZE = 34
local GAP = 5
local HANDLE_WIDTH = 22 -- gem-node thickness (along the bar)
local HANDLE_ACROSS = 44 -- gem-node length (across the bar); 2:1 keeps the gem round
local MAX_BUTTONS = 9
-- legacy skin: the bar is a vertical stack of WIDE rows (icon left, timer right)
-- with class-coloured tooltip backdrops and a small round status ball as handle
local LEGACY_W = 100
local LEGACY_HANDLE = 16

-- handle "gem node" sprite: a golden rail with a faceted gem knob. The gem
-- colour is the status light — a red-gem variant is swapped in while a force
-- rebuff is active. Bundled TGA, referenced without extension.
-- gem variants: the handle gem is an overall status light — blue at rest / no
-- duties, green when everything is covered, yellow when a class needs attention
-- (unmet request or expiring/out of range), red when a buff is missing or a
-- force rebuff is active.
local HANDLE_TEX = "Interface\\AddOns\\HolyOrders\\Icons\\GemHandle" -- blue
local HANDLE_TEX_ACTIVE = "Interface\\AddOns\\HolyOrders\\Icons\\GemHandleActive" -- red
local HANDLE_TEX_GREEN = "Interface\\AddOns\\HolyOrders\\Icons\\GemHandleGreen"
local HANDLE_TEX_YELLOW = "Interface\\AddOns\\HolyOrders\\Icons\\GemHandleYellow"
-- handle status per skin: gem sprites (default), stock round indicators
-- (legacy's little status ball) or a flat tinted block (forga)
local HANDLE_SPRITES = { rest = HANDLE_TEX, red = HANDLE_TEX_ACTIVE, yellow = HANDLE_TEX_YELLOW, green = HANDLE_TEX_GREEN }
local HANDLE_DOTS = {
	rest = "Interface\\COMMON\\Indicator-Gray",
	red = "Interface\\COMMON\\Indicator-Red",
	yellow = "Interface\\COMMON\\Indicator-Yellow",
	green = "Interface\\COMMON\\Indicator-Green",
}
local WHITE8 = "Interface\\Buttons\\WHITE8x8"
-- biker skin: tintable wheel sprite (dark tire, bright rim/spokes take the tint)
local WHEEL_TEX = "Interface\\AddOns\\HolyOrders\\Icons\\WheelHandle"
local WHEEL_SIZE = 28
local WHEEL_SPIN_SECONDS = 1.2 -- one full turn while a force rebuff runs

-- the wide-row legacy bar only stacks vertically: a horizontal grow option is
-- treated as "down" there, every other skin honours the option as-is
local function EffectiveGrow()
	local grow = HO.db.options.bar and HO.db.options.bar.grow or "right"
	if HO.Skin.WideBar() and (grow == "left" or grow == "right") then
		return "down" -- the wide-row bar only stacks vertically
	end
	return grow
end

-- per-skin bar geometry: cross-axis button extent and the handle's along-axis size
local function ButtonCross()
	return HO.Skin.WideBar() and LEGACY_W or BUTTON_SIZE
end

local STRIP_HANDLE_HIT = 14 -- strip handle: grab area along the bar; the strip is slimmer

local function HandleAlong()
	local style = HO.Skin.HandleStyle()
	if style == "dot" then
		return LEGACY_HANDLE + 2
	elseif style == "strip" then
		return STRIP_HANDLE_HIT
	elseif style == "wheel" then
		return WHEEL_SIZE + 2
	end
	return HANDLE_WIDTH
end

-- icon chrome (corner mask + tintable status ring) comes from HO.Skin: rounded
-- on the default skin, square on the alternatives
local UPDATE_INTERVAL = 1.0
local NONE_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" -- "no aura" placeholder (matches the window)
-- colour language for status borders: green = everyone has their assigned buff,
-- red = someone in range is missing it, amber = only expiring/out-of-range.
-- Buff requests never colour the bar (they feed auto + the assignment window).

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local bar, handle, ticker
local auraButton -- dedicated self-cast aura slot at the origin end (next to the handle)
local selfBuffButton -- protection only: the threat self-buff, right after the aura slot
local buttons = {}
local lastGrow
local pendingReset

-- anchor a frame at a linear distance from the origin end, for the current
-- grow direction (the origin end is always where the handle sits). Out of
-- combat only — the placed frames are protected.
local function PlaceAtOffset(frame, offset)
	local grow = EffectiveGrow()
	frame:ClearAllPoints()
	if grow == "right" then
		frame:SetPoint("LEFT", bar, "LEFT", offset, 0)
	elseif grow == "left" then
		frame:SetPoint("RIGHT", bar, "RIGHT", -offset, 0)
	elseif grow == "down" then
		frame:SetPoint("TOP", bar, "TOP", 0, -offset)
	else
		frame:SetPoint("BOTTOM", bar, "BOTTOM", 0, offset)
	end
end

-- protection paladins get the threat self-buff slot; everyone else does not
local function SelfBuffRelevant()
	if select(2, UnitClass("player")) ~= "PALADIN" then
		return false
	end
	if not (HO.Data.selfBuff and HO.Data.selfBuff.known) then
		return false
	end
	return HO.Planner and HO.Planner.OwnSpec and HO.Planner.OwnSpec() == "protection"
end

-- place a class button into the nth visible slot (slot 0 is the aura button,
-- slot 1 the self-buff button when a protection paladin shows it). Buttons are
-- class-fixed, so the visible set is compacted here per refresh.
local function SlotOffset()
	return SelfBuffRelevant() and 1 or 0
end

local function PlaceButtonInSlot(btn, slot)
	PlaceAtOffset(btn, HandleAlong() + GAP + (slot + SlotOffset()) * (BUTTON_SIZE + GAP))
end

-- arranges the frame, handle and aura slot for the configured growth direction;
-- must only run out of combat (buttons are protected frames)
local function LayoutBar()
	local skin = HO.Skin.current
	local grow = EffectiveGrow()
	local horizontal = (grow == "left" or grow == "right")
	-- +2 slots at the origin end: the always-present aura button and the
	-- protection self-buff slot (reserved so the bar never resizes in combat)
	local length = HandleAlong() + GAP + (MAX_BUTTONS + 2) * (BUTTON_SIZE + GAP)
	local cross = ButtonCross() + 4
	if horizontal then
		bar:SetSize(length, cross)
	else
		bar:SetSize(cross, length)
	end
	-- handle geometry per skin: the gem rail (default), the little status ball
	-- (legacy) or a slim status strip inside a larger invisible grab area (forga)
	handle.tex:ClearAllPoints()
	local handleStyle = HO.Skin.HandleStyle()
	if handleStyle == "dot" then
		handle:SetSize(LEGACY_HANDLE, LEGACY_HANDLE)
		handle.tex:SetAllPoints(handle)
	elseif handleStyle == "wheel" then
		handle:SetSize(WHEEL_SIZE, WHEEL_SIZE)
		handle.tex:SetAllPoints(handle)
	elseif handleStyle == "strip" then
		local bc = ButtonCross()
		if horizontal then
			handle:SetSize(STRIP_HANDLE_HIT, bc - 4)
			handle.tex:SetSize(5, bc - 10)
		else
			handle:SetSize(bc - 4, STRIP_HANDLE_HIT)
			handle.tex:SetSize(bc - 10, 5)
		end
		handle.tex:SetPoint("CENTER")
	elseif horizontal then
		handle:SetSize(HANDLE_WIDTH, HANDLE_ACROSS)
		handle.tex:SetAllPoints(handle)
	else
		handle:SetSize(HANDLE_ACROSS, HANDLE_WIDTH)
		handle.tex:SetAllPoints(handle)
	end
	handle:ClearAllPoints()
	if grow == "right" then
		handle:SetPoint("LEFT", bar, "LEFT", 0, 0)
	elseif grow == "left" then
		handle:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
	elseif grow == "down" then
		handle:SetPoint("TOP", bar, "TOP", 0, 0)
	else -- up
		handle:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
	end
	-- the gem sprite is a horizontal rail; rotate it 90° when the bar (and thus
	-- the handle) runs vertically so the rail lines up with the buttons. The
	-- other skins' handle textures are rotation-neutral.
	if handle.tex and handle.tex.SetRotation then
		handle.tex:SetRotation((handleStyle == "gem" and horizontal) and (math.pi / 2) or 0)
	end
	-- the aura button takes the first slot (slot 0) right after the handle; the
	-- class buttons follow, compacted into slots 1..n by the refresh
	if auraButton then
		PlaceAtOffset(auraButton, HandleAlong() + GAP)
	end
	if selfBuffButton then
		PlaceAtOffset(selfBuffButton, HandleAlong() + GAP + (BUTTON_SIZE + GAP))
	end
	lastGrow = HO.db.options.bar and HO.db.options.bar.grow or "right"
end

local function BarOptions()
	HO.db.options.bar = HO.db.options.bar or {}
	return HO.db.options.bar
end

-- the client re-anchors a dragged frame to the nearest corner, so the full
-- anchor (point + relativePoint + offsets) must be saved, not just offsets
local function SavePosition()
	local opts = BarOptions()
	local point, _, relativePoint, x, y = bar:GetPoint()
	opts.point, opts.relPoint, opts.x, opts.y = point, relativePoint, x, y
end

function Bar.ResetPosition()
	-- the bar is a protected frame (secure buttons anchor to it); moving it in
	-- combat would taint, so defer to PLAYER_REGEN_ENABLED
	if InCombatLockdown() then
		pendingReset = true
		HO.Print(L["can't move the bar in combat — will reset it after combat"])
		return
	end
	local opts = BarOptions()
	opts.point, opts.relPoint, opts.x, opts.y = nil, nil, nil, nil
	bar:ClearAllPoints()
	bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
end

local function RestorePosition()
	local opts = BarOptions()
	bar:ClearAllPoints()
	if opts.point then
		bar:SetPoint(opts.point, UIParent, opts.relPoint or opts.point, opts.x or 0, opts.y or 0)
	else
		bar:SetPoint("CENTER", UIParent, "CENTER", opts.x or 0, opts.y or -180)
	end
end

-- frame strata is user-configurable: default "LOW" keeps the bar below standard
-- Blizzard windows (calendar, group finder) yet above the world; opt-in "HIGH"
-- lifts it over unit-frame addons (VuhDo etc.) that would otherwise cover it.
-- The bar is implicitly protected (secure buttons anchor to it), so SetFrameStrata
-- may only run out of combat; a combat-time toggle re-applies on the next
-- PLAYER_REGEN_ENABLED refresh.
function Bar.ApplyStrata()
	if not bar or InCombatLockdown() then
		return
	end
	bar:SetFrameStrata(BarOptions().front and "HIGH" or "LOW")
end

local function FormatShort(seconds)
	if not seconds then
		return ""
	end
	if seconds >= 60 then
		return string.format("%dm", math.floor(seconds / 60))
	end
	return string.format("%ds", math.floor(seconds))
end

-- colour the button's status border (nil = hide it): green all covered, red
-- someone in range missing, amber only-expiring or only-out-of-range
-- status border: the ring texture around the buttons. Colour ops only — safe
-- in combat. The neutral (no-status) colour follows the skin: gold on the
-- default look, plain grey on the alternatives.
local function SetButtonBorder(btn, r, g, b)
	if not btn.frame then
		return
	end
	if r then
		btn.frame:SetVertexColor(r, g, b, 1)
	else
		btn.frame:SetVertexColor(HO.Colors.rgb("borderNeutral", 0.85)) -- no status
	end
end

-- one class duty's status: "red" (someone in range is missing), "yellow"
-- (expiring/out of range), or "green" (all covered). Requests deliberately do
-- NOT colour anything here: a per-paladin "unmet request" would mislead —
-- another paladin may fulfil it, or a lower-ranked wish may already be active.
-- Requests feed the auto-planner and the assignment window instead.
local function TaskSeverity(task)
	if task.noneAssigned then
		return "green"
	end
	local inRangeMissing = task.missing - (task.outOfRange or 0)
	if inRangeMissing > 0 then
		return "red"
	end
	if task.expiring > 0 or (task.outOfRange or 0) > 0 then
		return "yellow"
	end
	return "green"
end

-- worst status across all class duties, feeding the handle gem status light
-- (nil when there are no duties at all)
local function BarStatus()
	local worst
	for _, task in pairs(HO.Engine.tasks) do
		local s = TaskSeverity(task)
		if s == "red" then
			return "red"
		elseif s == "yellow" then
			worst = "yellow"
		elseif not worst then
			worst = "green"
		end
	end
	return worst
end

-- button backdrop tint; the wide legacy rows keep their class-coloured fill
-- (set per duty in Bar.Refresh), so status shows on the border alone there
local function TintButtonBg(btn, r, g, b, a)
	if btn.bg and not HO.Skin.WideBar() then
		-- SetVertexColor, NOT SetColorTexture: that would replace the WHITE8x8
		-- texture and drop the rounded corner mask
		btn.bg:SetVertexColor(r, g, b, a)
	end
end

-- button visuals that are safe to update in combat
local function UpdateButtonTexts(btn, task)
	btn.count:SetText(task.missing > 0 and tostring(task.missing) or "")
	btn.timer:SetText(FormatShort(task.minRemaining))
	-- during a force rebuff a class stays red only while IT still has reachable
	-- work (the sweep re-casts anything older than 2 minutes); a finished class
	-- turns green right away so per-class progress is visible. The handle gem
	-- stays red for the sweep as a whole until everything is fresh.
	if HO.Engine.ForceActive() and (task.reachable or 0) > 0 then
		TintButtonBg(btn, 0.55, 0.10, 0.10, 0.85)
		SetButtonBorder(btn, 0.85, 0.15, 0.15)
		return
	end
	-- in-range missing counts toward "red"; a purely out-of-range gap is amber,
	-- since it is not something you can act on right now
	local inRangeMissing = task.missing - (task.outOfRange or 0)
	if task.noneAssigned then
		TintButtonBg(btn, 0, 0, 0, 0.65)
		SetButtonBorder(btn) -- no assignment: no status
	elseif inRangeMissing > 0 then
		TintButtonBg(btn, 0.55, 0.10, 0.10, 0.85)
		SetButtonBorder(btn, 0.85, 0.15, 0.15) -- red
	elseif task.expiring > 0 or (task.outOfRange or 0) > 0 then
		TintButtonBg(btn, 0.55, 0.45, 0.05, 0.85)
		SetButtonBorder(btn, 0.90, 0.70, 0.10) -- amber
	else
		TintButtonBg(btn, 0, 0, 0, 0.65)
		SetButtonBorder(btn, 0.10, 0.80, 0.10) -- green: everyone covered
	end
end

-- per-class SECURE fly-out ----------------------------------------------------
-- One protected panel per class, each holding pre-created secure member rows.
-- Everything (rows, cast attributes, sizes, anchors, shown-state of rows) is
-- configured ONLY out of combat; the panel itself is shown by the class
-- button's `_onenter` SECURE SNIPPET, which the restricted environment is
-- allowed to run even in combat — so the fly-out opens mid-fight, and its rows
-- (plain secure action buttons, pre-baked spell/unit) cast on click. Closing is
-- the restricted auto-hide facility (RegisterAutoHide), which also replaces the
-- old insecure hover-close timer out of combat: one code path for both.
-- Wheel/right-click row edits stay insecure and simply refuse in combat.
local flyoutPanels = {} -- [classIndex] = secure panel, aligned with CLASS_ORDER

local FLYOUT_ROW_H = 30
local FLYOUT_HEADER = 20
local FLYOUT_FOOTER = 5 -- bottom padding only (no hint line)
local FLYOUT_PAD = 6
local FLYOUT_WIDTH = 190
local FLYOUT_ICON = FLYOUT_ROW_H - 6
local FLYOUT_EXPIRING = 120 -- seconds left below which the row timer turns yellow
local FLYOUT_MAX_ROWS = 15 -- pre-created secure rows per class (raid-size bound)
-- close delay once the cursor has left button AND panel: short enough to feel
-- responsive, long enough to cross the small gap between button and rows
local FLYOUT_AUTOHIDE = 0.2

-- fly-out geometry per skin: the legacy skin shows bare wide rows (same style
-- as its bar rows, no titled panel box around them); the others use the titled
-- panel with narrow rows
local function FlyoutIsBare()
	return HO.Skin.BareFlyout()
end
local function FlyoutRowW()
	return FlyoutIsBare() and LEGACY_W or (FLYOUT_WIDTH - 2 * FLYOUT_PAD)
end
local function FlyoutRowH()
	return FlyoutIsBare() and BUTTON_SIZE or FLYOUT_ROW_H
end
local function FlyoutRowStep()
	return FlyoutRowH() + (FlyoutIsBare() and 1 or 0) -- 1 px breathing between bare rows
end
local function FlyoutHeaderH()
	return FlyoutIsBare() and 0 or FLYOUT_HEADER
end
local function FlyoutFooterH()
	return FlyoutIsBare() and 0 or FLYOUT_FOOTER
end
local function FlyoutPanelW()
	return FlyoutIsBare() and LEGACY_W or FLYOUT_WIDTH
end

local function SetRowBorder(row, r, g, b)
	if not row.iconFrame then
		return
	end
	if r then
		row.iconFrame:SetVertexColor(r, g, b, 1)
	else
		row.iconFrame:SetVertexColor(HO.Colors.rgb("goldMuted", 0.85)) -- neutral gold frame, no status
	end
end

-- paint a row's member data, icon and green/red status border. All non-secure
-- (textures/fontstrings), so it is safe any time; also stores the fields the row
-- tooltip and right-click/wheel handlers read.
local function UpdateRowStatus(row, m)
	row.memberName = m.name
	row.isPet = m.isPet
	row.blessingID = m.blessingID
	row.hasBuff = m.hasBuff
	row.inRange = m.inRange
	row.requestID = m.requestID
	local blessing = m.blessingID and HO.Data.blessings[m.blessingID]
	row.icon:SetTexture((blessing and blessing.icon) or NONE_ICON)
	local short = m.name:match("^([^%-]+)") or m.name
	if m.isPet then
		local ownerShort = m.owner and (m.owner:match("^([^%-]+)") or m.owner) or "?"
		row.name:SetText(short .. " |cff9d9d9d" .. string.format(L["(pet of %s)"], ownerShort) .. "|r")
	else
		row.name:SetText(short)
	end
	-- remaining time on this member's blessing (refreshes each update tick); yellow
	-- once it is expiring soon, a subdued light tone otherwise, blank when unbuffed
	if m.remaining and m.remaining > 0 then
		row.timer:SetText(FormatShort(m.remaining))
		if m.remaining < FLYOUT_EXPIRING then
			row.timer:SetTextColor(HO.Colors.rgb("yellow"))
		else
			row.timer:SetTextColor(HO.Colors.rgb("timerIdle"))
		end
	else
		row.timer:SetText("")
	end
	-- out-of-range is unknowable, so neutral/dim rather than a false red
	if not m.blessingID then
		SetRowBorder(row) -- no assignment → neutral
		row.icon:SetDesaturated(true)
		row.icon:SetAlpha(0.8)
	elseif m.inRange == false then
		SetRowBorder(row) -- can't know the buff at range → neutral, dimmed
		row.icon:SetDesaturated(false)
		row.icon:SetAlpha(0.35)
	elseif m.hasBuff == true then
		SetRowBorder(row, HO.Colors.rgb("green")) -- green: has it
		row.icon:SetDesaturated(false)
		row.icon:SetAlpha(1)
	elseif m.hasBuff == false then
		SetRowBorder(row, HO.Colors.rgb("red")) -- red: assigned but missing
		row.icon:SetDesaturated(false)
		row.icon:SetAlpha(1)
	else
		SetRowBorder(row) -- status unknown → neutral
		row.icon:SetDesaturated(false)
		row.icon:SetAlpha(1)
	end
	-- request badge (right side): the requested blessing's icon — INFORMATIONAL
	-- only, it never colours the row border (requests feed the auto-planner and
	-- the assignment window). Greenish once the member actually HAS the requested
	-- blessing (from any paladin), full colour while they don't.
	if m.requestID then
		local reqBlessing = HO.Data.blessings[m.requestID]
		row.reqBadge:SetTexture((reqBlessing and reqBlessing.icon) or NONE_ICON)
		if m.requestSatisfied then
			row.reqBadge:SetVertexColor(0.4, 1, 0.4) -- satisfied: greenish
			row.reqBadge:SetAlpha(0.7)
		else
			row.reqBadge:SetVertexColor(1, 1, 1)
			row.reqBadge:SetAlpha(1)
		end
		row.reqBadge:Show()
	else
		row.reqBadge:Hide()
	end
end

-- clicking a row casts the member's assigned SINGLE blessing on them. Secure
-- attributes may only change out of combat; the caller guarantees that.
local function ConfigureRowSecure(row, m)
	local blessing = m.blessingID and HO.Data.blessings[m.blessingID]
	if blessing and blessing.name and m.unit then
		row:SetAttribute("type1", "spell")
		row:SetAttribute("spell1", blessing.name) -- the 10-min single
		row:SetAttribute("unit1", m.unit)
	else
		-- no assignment (or no unit): nothing to cast
		row:SetAttribute("type1", nil)
		row:SetAttribute("spell1", nil)
		row:SetAttribute("unit1", nil)
	end
end

-- ring of override blessings for the player: every castable blessing in id order,
-- then none (0). Mirrors the assignment window's member-cell cycle (same id set
-- and order, overrides bypass eligibility); wheel-up advances, wheel-down retreats.
local function CycleMemberOverride(me, current, delta)
	local ring = {}
	for id = 1, HO.Data.NUM_BLESSINGS do
		if HO.Planner.IsAvailable(me, id) then
			ring[#ring + 1] = id
		end
	end
	ring[#ring + 1] = 0 -- none closes the ring
	local cur = current or 0
	local idx = #ring -- default to the none slot (also covers an unknown current)
	for i, id in ipairs(ring) do
		if id == cur then
			idx = i
			break
		end
	end
	local nextIdx = ((idx - 1 + delta) % #ring) + 1
	return ring[nextIdx]
end

-- apply an override change through the SAME public path the assignment window's
-- member cell uses, so the edit syncs and the member "liking" stays consistent.
-- Pets never record a liking (a pet blessing is an option, not a member wish).
local function ApplyMemberOverride(memberName, isPet, newID, classToken)
	local me = HO.FullName("player")
	if not me then
		return
	end
	HO.Plan.SetPlayerOverride(me, memberName, newID)
	if not isPet then
		HO.Plan.SetMemberPref(memberName, (newID and newID ~= 0) and newID or nil)
	end
	-- Bar.Refresh recomputes the engine and re-renders the fly-out rows; keep the
	-- window in sync too. A fly-out edit is a per-member OVERRIDE, which only
	-- shows in the window's expanded member row — so expand that class so the
	-- change is actually visible, not silently hidden under a collapsed row.
	Bar.Refresh()
	if HO.Window then
		if HO.Window.Expand and classToken then
			HO.Window.Expand(classToken)
		elseif HO.Window.Refresh then
			HO.Window.Refresh()
		end
	end
end

-- pre-created secure member row inside a class panel. Position is FIXED at
-- creation (slot-based); visuals and cast attributes are (re)baked only out of
-- combat, so in combat the row is a frozen, clickable secure cast button.
local function AcquireFlyoutRow(panel, index)
	panel.rows = panel.rows or {}
	local row = panel.rows[index]
	if row then
		return row
	end
	row = CreateFrame("Button", nil, panel, "SecureActionButtonTemplate")
	row:SetSize(FlyoutRowW(), FlyoutRowH())
	row:SetPoint("TOPLEFT", panel, "TOPLEFT", FlyoutIsBare() and 0 or FLYOUT_PAD,
		-(FlyoutHeaderH() + (index - 1) * FlyoutRowStep()))
	row:RegisterForClicks("AnyDown", "AnyUp")
	row:EnableMouseWheel(true)
	row:Hide()
	row.classToken = panel.classToken
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	if FlyoutIsBare() then
		-- legacy: each row is a self-contained wide box like the bar rows — dark
		-- fill, square status ring around the WHOLE row, icon left, timer
		-- top-right, member name bottom-right
		row.bg:SetColorTexture(0, 0, 0, 0.85)
		row.iconFrame = row:CreateTexture(nil, "OVERLAY", nil, 1)
		row.iconFrame:SetPoint("TOPLEFT", -1, 1)
		row.iconFrame:SetPoint("BOTTOMRIGHT", 1, -1)
		row.iconFrame:SetTexture(HO.Skin.IconFrame())
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(26, 26)
		row.icon:SetPoint("LEFT", 4, 0)
		row.timer = row:CreateFontString(nil, "OVERLAY", "HolyOrdersFontHighlightSmall")
		row.timer:SetPoint("TOPRIGHT", -6, -5)
		row.timer:SetJustifyH("RIGHT")
		row.name = row:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		row.name:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 4, 1)
		row.name:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 4)
		row.name:SetJustifyH("RIGHT")
		row.name:SetWordWrap(false)
		row.reqBadge = row:CreateTexture(nil, "OVERLAY")
		row.reqBadge:SetSize(14, 14)
		row.reqBadge:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 5, -3)
		row.reqBadge:Hide()
	else
		row.bg:SetColorTexture(1, 1, 1, 0.05)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(FLYOUT_ICON, FLYOUT_ICON)
		row.icon:SetPoint("LEFT", 3, 0)
		HO.Skin.MaskIcon(row.icon)
		-- frame ring around the member icon; tinted per status in SetRowBorder
		-- (green has / red missing / neutral otherwise)
		row.iconFrame = row:CreateTexture(nil, "OVERLAY", nil, 1)
		row.iconFrame:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1)
		row.iconFrame:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1)
		row.iconFrame:SetTexture(HO.Skin.IconFrame())
		row.name = row:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		-- remaining-buff timer, sitting between the name and the request-badge slot
		row.timer = row:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		row.timer:SetPoint("RIGHT", row, "RIGHT", -(FLYOUT_ICON + 6), 0)
		row.timer:SetJustifyH("RIGHT")
		-- name fills the middle; the request badge keeps its slot on the far right
		row.name:SetPoint("RIGHT", row.timer, "LEFT", -3, 0)
		row.name:SetJustifyH("LEFT")
		-- request badge: the requested blessing's icon on the row's right side,
		-- kept distinct from the assigned-blessing icon on the left
		row.reqBadge = row:CreateTexture(nil, "OVERLAY")
		row.reqBadge:SetSize(FLYOUT_ICON, FLYOUT_ICON)
		row.reqBadge:SetPoint("RIGHT", -2, 0)
		HO.Skin.MaskIcon(row.reqBadge)
		row.reqBadge:Hide()
	end
	row:SetScript("OnMouseWheel", function(self, delta)
		if not self.memberName then
			return
		end
		if InCombatLockdown() then
			-- mirror the class wheel's combat guard: the resulting secure-attribute
			-- update on the bar must wait for combat end anyway
			HO.Print(L["assignment changes apply after combat"])
			return
		end
		local me = HO.FullName("player")
		if not me then
			return
		end
		local plan = HO.Plan.Active()
		local cur = plan.player[me] and plan.player[me][self.memberName]
		local newID = CycleMemberOverride(me, cur, delta > 0 and 1 or -1)
		ApplyMemberOverride(self.memberName, self.isPet, newID, self.classToken)
	end)
	-- left-click casts the secure blessing; right-click clears the assignment.
	-- PostClick runs after the (suppressed for right) secure action, so editing
	-- here never taints. Guard to fire the clear once, on the down edge.
	row:SetScript("PostClick", function(self, mouseBtn, down)
		if mouseBtn == "RightButton" and down and self.memberName then
			if InCombatLockdown() then
				HO.Print(L["assignment changes apply after combat"])
				return
			end
			ApplyMemberOverride(self.memberName, self.isPet, 0, self.classToken) -- clear the override (and liking)
		end
	end)
	-- no tooltip and no hover scripts: the restricted auto-hide keeps the panel
	-- open while the cursor is anywhere over it (rows included)
	panel.rows[index] = row
	return row
end

-- one secure panel per class. The panel inherits a secure-handler template so
-- it is a PROTECTED frame the class button's snippet may Show/Hide in combat;
-- its skin/title are ordinary textures. Parented to the bar: it inherits the
-- bar's scale and hides with it.
local function CreatePanels()
	for i, classToken in ipairs(CLASS_ORDER) do
		local panel = CreateFrame("Frame", "HolyOrdersFlyout" .. i, bar, "SecureHandlerShowHideTemplate, BackdropTemplate")
		panel.classToken = classToken
		panel:SetWidth(FlyoutPanelW())
		panel:SetHeight(FlyoutHeaderH() + FlyoutRowStep() + FlyoutFooterH())
		panel:EnableMouse(true) -- swallow clicks; keeps the auto-hide hover alive
		panel:SetClampedToScreen(true)
		panel:SetFrameStrata("DIALOG") -- always reads over the bar
		panel:SetToplevel(true)
		panel.title = panel:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		panel.title:SetPoint("TOPLEFT", FLYOUT_PAD + 2, -5)
		panel.title:SetPoint("TOPRIGHT", -(FLYOUT_PAD + 2), -5)
		panel.title:SetJustifyH("LEFT")
		panel.title:SetTextColor(HO.Colors.rgb("goldBright"))
		if FlyoutIsBare() then
			-- bare rows carry their own chrome; no panel box, no title line
			panel.title:Hide()
		else
			-- same dark rounded panel + thin gold border as the assignment window,
			-- with a gold seam under the title (shared HO.Skin builder)
			HO.Skin.Panel(panel)
			panel.seam = HO.Skin.Seam(panel, -(FLYOUT_HEADER - 2))
		end
		panel:SetAttribute("active", 0) -- gates the secure show (set out of combat)
		panel:Hide()
		flyoutPanels[i] = panel
	end
end

-- panel header: class name + a compact coverage summary (the class tooltip is
-- suppressed while the panel is open). Plain text — safe to refresh any time.
local function FlyoutTitle(classToken, task)
	local status = ""
	if task and not task.noneAssigned then
		if (task.missing or 0) > 0 then
			status = "  |cff" .. HO.Colors.hex("red") .. string.format(L["%d missing"], task.missing) .. "|r"
		elseif (task.outOfRange or 0) > 0 then
			status = "  |cff" .. HO.Colors.hex("yellow") .. string.format("%d %s", task.outOfRange, L["out of range"]) .. "|r"
		else
			status = "  |cff" .. HO.Colors.hex("green") .. L["all covered"] .. "|r"
		end
	end
	return classToken .. status
end

-- (re)build one class panel from the engine's per-member status: row visuals,
-- secure cast attributes, shown-state, panel size/anchor and the `active` gate.
-- OUT OF COMBAT ONLY — in combat everything stays frozen and the secure snippet
-- merely shows/hides the pre-configured panel.
local function FlyoutConfigure(classIndex, classToken, task, anchorBtn, anchorShown)
	local panel = flyoutPanels[classIndex]
	if not panel then
		return
	end
	local members = HO.Engine.ClassMembers(classToken)
	local count = math.min(#members, FLYOUT_MAX_ROWS)
	if count == 0 or not anchorShown then
		panel:SetAttribute("active", 0)
		panel:Hide()
		return
	end
	panel.title:SetText(FlyoutTitle(classToken, task))
	for i = 1, count do
		local row = AcquireFlyoutRow(panel, i)
		UpdateRowStatus(row, members[i]) -- non-secure visuals
		ConfigureRowSecure(row, members[i]) -- secure cast attributes
		row:Show()
	end
	for i = count + 1, #(panel.rows or {}) do
		panel.rows[i]:Hide()
	end
	panel:SetHeight(FlyoutHeaderH() + count * FlyoutRowStep() + FlyoutFooterH())
	-- fly-out direction is user-configurable (default: to the LEFT of the class
	-- button, like the classic paladin buff addons); SetClampedToScreen keeps it
	-- on-screen near an edge. Anchoring is out-of-combat only, so the option
	-- takes effect on the next refresh tick.
	panel:ClearAllPoints()
	local dir = BarOptions().flyout or "left"
	if dir == "right" then
		panel:SetPoint("TOPLEFT", anchorBtn, "TOPRIGHT", 4, 0)
	elseif dir == "up" then
		panel:SetPoint("BOTTOMLEFT", anchorBtn, "TOPLEFT", 0, 4)
	elseif dir == "down" then
		panel:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -4)
	else
		panel:SetPoint("TOPRIGHT", anchorBtn, "TOPLEFT", -4, 0)
	end
	panel:SetAttribute("active", 1)
end

-- hide every panel (out of combat; used when the bar itself hides)
local function FlyoutHideAll()
	for _, panel in ipairs(flyoutPanels) do
		panel:SetAttribute("active", 0)
		panel:Hide()
	end
end

-- COMBAT-SAFE visual refresh for rows that are already on screen: textures and
-- fontstrings are not protected, so green/red borders, timers and badges can
-- keep tracking reality mid-fight — only the secure bits (attributes, layout,
-- shown-state) stay frozen. Rows are matched by member NAME so a frozen row is
-- never repainted with a different member's status.
local function FlyoutRefreshShownVisuals()
	for i, classToken in ipairs(CLASS_ORDER) do
		local panel = flyoutPanels[i]
		if panel and panel:IsShown() and panel.rows then
			local byName = {}
			for _, m in ipairs(HO.Engine.ClassMembers(classToken)) do
				if m.name then
					byName[m.name] = m
				end
			end
			for _, row in ipairs(panel.rows) do
				if row:IsShown() and row.memberName then
					local m = byName[row.memberName]
					if m then
						UpdateRowStatus(row, m)
					end
				end
			end
			-- the coverage summary in the title is a plain fontstring: keep it live
			panel.title:SetText(FlyoutTitle(classToken, HO.Engine.tasks[classToken]))
		end
	end
end

-- class buttons are CLASS-FIXED (buttons[i] <-> CLASS_ORDER[i]) so the secure
-- button<->panel wiring is static; the visible set is compacted out of combat.
local function CreateButton(classIndex)
	local btn = CreateFrame("Button", "HolyOrdersBarButton" .. classIndex,
		bar, "SecureActionButtonTemplate, SecureHandlerEnterLeaveTemplate")
	btn.classToken = CLASS_ORDER[classIndex]
	btn.classIndex = classIndex
	btn:SetSize(ButtonCross(), BUTTON_SIZE)
	-- ONE click edge only, mirroring the ActionButtonUseKeyDown cvar (set in
	-- Bar.Refresh): registering both edges would run the OnClick wrap twice per
	-- click and double-advance the combat cycle
	btn:RegisterForClicks("AnyUp")
	-- left-click is a MACRO: out of combat Bar.Refresh bakes the engine's planned
	-- cast into it; in combat the OnClick wrap below rewrites it per click to
	-- cycle through the class's members (see SPEC-secure-flyout)
	btn:SetAttribute("type1", "macro")
	-- right-click: always the 10-min single on the auto-target
	btn:SetAttribute("type2", "spell")

	-- SECURE hover: show my class panel, hide the others, and let the restricted
	-- auto-hide close it once the cursor has left panel+button. Runs in the
	-- restricted environment, so it works in combat — this is what makes the
	-- fly-out usable mid-fight. Frame refs flyout1..N are wired in Bar.Create.
	btn:SetAttribute("_onenter", [[
		local mine = self:GetAttribute("classIndex")
		local total = self:GetAttribute("numPanels") or 0
		for i = 1, total do
			local panel = self:GetFrameRef("flyout" .. i)
			if panel then
				if i == mine then
					if panel:GetAttribute("active") == 1 then
						panel:Show()
						panel:RegisterAutoHide(]] .. FLYOUT_AUTOHIDE .. [[)
						panel:AddToAutoHide(self)
					end
				else
					panel:Hide()
				end
			end
		end
	]])

	-- SECURE in-combat rebuff cycling: each combat click rewrites this button's
	-- own macro to cast on the NEXT viable member. Targets and their spells are
	-- baked out of combat as paired attributes — players by NAME (stable), pets
	-- by UNIT TOKEN (pets have no reliable name targeting), and each target with
	-- ITS OWN single (pets/overrides may differ from the class blessing). Out of
	-- combat the snippet does nothing, so the engine's smart macro applies. The
	-- button is registered for exactly ONE click edge (Bar.Refresh mirrors the
	-- ActionButtonUseKeyDown cvar), so this runs once per click.
	btn:WrapScript(btn, "OnClick", [[
		if SecureCmdOptionParse("[combat] 1;") ~= "1" then return end
		local total = self:GetAttribute("cycleCount") or 0
		if total == 0 then return end
		local step = self:GetAttribute("cycleStep") or 1
		for _ = 1, total do
			if step > total then step = 1 end
			local target = self:GetAttribute("cycleName" .. step)
			local spell = self:GetAttribute("cycleSpell" .. step)
			step = step + 1
			if target and spell and SecureCmdOptionParse("[@" .. target .. ",help,nodead] 1;") == "1" then
				self:SetAttribute("macrotext1", "/cast [@" .. target .. ",help,nodead] " .. spell)
				break
			end
		end
		self:SetAttribute("cycleStep", step)
	]])

	-- wheel: cycle my class assignment (out of combat; syncs + updates window)
	btn:EnableMouseWheel(true)
	btn:SetScript("OnMouseWheel", function(self, delta)
		if InCombatLockdown() then
			return
		end
		local task = self.task
		if task then
			-- a duty that exists only as a single-member override has no
			-- class-wide assignment to cycle; wheeling would fabricate one
			if task.overrideOnly then
				HO.Print(L["this duty is a single-member override — change it in the assignment window"])
				return
			end
			HO.Window.CycleMyClass(task.classToken, delta > 0 and 1 or -1)
		end
	end)
	btn.hoBarButton = true -- marks our buttons for the tooltip re-render check

	if HO.Skin.WideBar() then
		-- wide row: class-coloured dark fill (tinted per duty in Bar.Refresh) with
		-- a square status ring, icon on the left, timer top-right, missing count
		-- bottom-right. Plain textures only — no Backdrop mixin on secure frames.
		btn.bg = btn:CreateTexture(nil, "BACKGROUND")
		btn.bg:SetAllPoints()
		btn.bg:SetTexture(WHITE8)
		btn.bg:SetVertexColor(0, 0, 0, 0.8)
		btn.frame = btn:CreateTexture(nil, "OVERLAY", nil, 1)
		btn.frame:SetPoint("TOPLEFT", -1, 1)
		btn.frame:SetPoint("BOTTOMRIGHT", 1, -1)
		btn.frame:SetTexture(HO.Skin.IconFrame())
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetSize(26, 26)
		btn.icon:SetPoint("LEFT", 4, 0)
		btn.classIcon = btn:CreateTexture(nil, "OVERLAY")
		btn.classIcon:SetDrawLayer("OVERLAY", 2)
		btn.classIcon:SetSize(12, 12)
		btn.classIcon:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", -4, 4)
		btn.classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
		btn.timer = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontHighlight")
		btn.timer:SetPoint("TOPRIGHT", -7, -6)
		btn.timer:SetJustifyH("RIGHT")
		btn.count = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormal")
		btn.count:SetPoint("BOTTOMRIGHT", -7, 5)
		btn.count:SetJustifyH("RIGHT")
	else
		-- square button: rounded (default) or square (forga) icon chrome with a
		-- tintable status ring, timer overlaid on the icon
		btn.bg = btn:CreateTexture(nil, "BACKGROUND")
		btn.bg:SetAllPoints()
		btn.bg:SetTexture(WHITE8)
		btn.bg:SetVertexColor(0, 0, 0, 0.65)
		HO.Skin.MaskIcon(btn.bg)

		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetPoint("TOPLEFT", 2, -2)
		btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
		HO.Skin.MaskIcon(btn.icon)

		btn.classIcon = btn:CreateTexture(nil, "OVERLAY")
		-- draw above the status border (both are OVERLAY) so the corner class icon
		-- is not clipped by the green/red/yellow edge
		btn.classIcon:SetDrawLayer("OVERLAY", 2)
		btn.classIcon:SetSize(15, 15)
		btn.classIcon:SetPoint("TOPLEFT", -5, 5)
		btn.classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")

		-- status frame ring (tintable): green = everyone covered, red = someone
		-- missing, amber = expiring/out of range. Recoloured in UpdateButtonTexts
		-- — a plain vertex recolour, safe in combat.
		btn.frame = btn:CreateTexture(nil, "OVERLAY", nil, 1)
		btn.frame:SetPoint("TOPLEFT", -1, 1)
		btn.frame:SetPoint("BOTTOMRIGHT", 1, -1)
		btn.frame:SetTexture(HO.Skin.IconFrame())

		btn.count = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalLarge")
		btn.count:SetPoint("BOTTOMRIGHT", -1, 1)
		btn.count:SetDrawLayer("OVERLAY", 3) -- above the status frame ring

		-- timer overlaid on the icon (centered), larger and outlined for readability
		btn.timer = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalLarge")
		btn.timer:SetPoint("CENTER", btn, "CENTER", 0, 0)
		btn.timer:SetDrawLayer("OVERLAY", 4) -- above icon, frame and class badge
		local tf, ts = btn.timer:GetFont()
		btn.timer:SetFont(tf, (ts or 14) + 3, "THICKOUTLINE")
	end

	-- INSECURE hover extras ride along via HookScript (SetScript would overwrite
	-- the EnterLeave template's secure handler and kill the snippet above)
	btn:HookScript("OnEnter", function(self)
		local task = self.task
		if not task then
			return
		end
		local panel = flyoutPanels[self.classIndex]
		if panel and panel:IsShown() then
			-- the fly-out already shows the class, its members and coverage, so
			-- the big class tooltip would just be redundant noise on top of it
			return
		end
		-- no fly-out (empty class / inactive): the tooltip is the info source
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		local blessing = HO.Data.blessings[task.blessingID]
		GameTooltip:SetText(task.classToken)
		if task.noneAssigned then
			GameTooltip:AddLine(L["no blessing assigned — wheel to assign"], 0.8, 0.8, 0.8)
			GameTooltip:Show()
			return
		end
		if task.spellName and task.unitName then
			GameTooltip:AddLine(string.format(L["left: %s on %s"], task.spellName, task.unitName), 1, 1, 1)
		elseif task.missing > 0 then
			GameTooltip:AddLine(L["all remaining targets are out of range"], 1, 0.6, 0.3)
		else
			GameTooltip:AddLine(string.format(L["%s — all covered"], blessing and (blessing.name or blessing.key) or "?"), 0.6, 1, 0.6)
		end
		if self.rightSpell then
			GameTooltip:AddLine(string.format(
				self.rightIsGreater and L["right-click: %s (whole class, 1 Symbol)"] or L["right: %s (single)"],
				self.rightSpell), 1, 1, 1)
		end
		if task.outOfRange and task.outOfRange > 0 then
			GameTooltip:AddLine(string.format(L["%d out of range (skipped)"], task.outOfRange), 1, 0.6, 0.3)
		end
		if task.missing > 0 then
			GameTooltip:AddLine(string.format(L["%d missing"], task.missing), 1, 0.4, 0.4)
		end
		if task.expiring > 0 then
			GameTooltip:AddLine(string.format(L["%d expiring soon"], task.expiring), 1, 0.85, 0.3)
		end
		GameTooltip:AddLine(L["mouse wheel: change my assignment"], 0.8, 0.8, 0.8)
		GameTooltip:AddLine(L["in combat: click cycles through the class's members"], 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	btn:HookScript("OnLeave", function()
		GameTooltip:Hide()
		-- no close timer: the panel's restricted auto-hide closes it on its own
	end)
	return btn
end

-- wheel-cycle MY aura through the known auras then none (out of combat only,
-- like the class wheel); edits my own assignment, which syncs and refreshes.
local function CycleMyAura(delta)
	local me = HO.FullName("player")
	if not me then
		return
	end
	-- ring: known auras in id order, then none (0). Wheel-up advances, down retreats.
	local ring = HO.Data.KnownAuras()
	ring[#ring + 1] = 0
	local cur = HO.Plan.GetAura(me) or 0
	local idx = #ring -- default to the none slot (also covers an unknown assigned aura)
	for i, id in ipairs(ring) do
		if id == cur then
			idx = i
			break
		end
	end
	local nextIdx = ((idx - 1 + delta) % #ring) + 1
	HO.Plan.SetAura(me, ring[nextIdx])
	Bar.Refresh()
	HO.Window.Refresh()
end

-- the always-present self-cast aura slot; sits at the origin end so it reads as
-- "my aura", separate from the class-duty buttons
local function CreateAuraButton()
	local btn = CreateFrame("Button", "HolyOrdersBarAura", bar, "SecureActionButtonTemplate")
	btn:SetSize(ButtonCross(), BUTTON_SIZE)
	btn:RegisterForClicks("AnyDown", "AnyUp")
	-- auras are self-cast; unit1 never changes, so it is safe to set once here.
	-- spell1 (the aura name) is set from RefreshAuraButton, out of combat only.
	btn:SetAttribute("type1", "spell")
	btn:SetAttribute("unit1", "player")
	btn:EnableMouseWheel(true)
	btn:SetScript("OnMouseWheel", function(_, delta)
		if InCombatLockdown() then
			return -- changing the secure spell attribute is forbidden in combat
		end
		CycleMyAura(delta > 0 and 1 or -1)
	end)
	btn.hoAuraButton = true -- marks the aura button for the tooltip re-render check

	if HO.Skin.WideBar() then
		-- wide row like the class rows: blue-tinted fill + blue ring, icon left,
		-- label on the right. Plain textures — no Backdrop mixin on secure frames.
		btn.bg = btn:CreateTexture(nil, "BACKGROUND")
		btn.bg:SetAllPoints()
		btn.bg:SetTexture(WHITE8)
		btn.bg:SetVertexColor(0.08, 0.10, 0.28, 0.85)
		btn.frame = btn:CreateTexture(nil, "OVERLAY", nil, 1)
		btn.frame:SetPoint("TOPLEFT", -1, 1)
		btn.frame:SetPoint("BOTTOMRIGHT", 1, -1)
		btn.frame:SetTexture(HO.Skin.IconFrame())
		btn.frame:SetVertexColor(0.35, 0.55, 1.0, 1)
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetSize(26, 26)
		btn.icon:SetPoint("LEFT", 4, 0)
		btn.label = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		btn.label:SetPoint("RIGHT", -7, 0)
		btn.label:SetText(L["Aura"])
	else
		btn.bg = btn:CreateTexture(nil, "BACKGROUND")
		btn.bg:SetAllPoints()
		btn.bg:SetTexture(WHITE8)
		btn.bg:SetVertexColor(0.10, 0.10, 0.32, 0.85) -- blue tint distinguishes it from duty buttons
		HO.Skin.MaskIcon(btn.bg)

		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetPoint("TOPLEFT", 2, -2)
		btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
		HO.Skin.MaskIcon(btn.icon)

		-- blue frame ring to match the aura's blue theme
		btn.frame = btn:CreateTexture(nil, "OVERLAY", nil, 1)
		btn.frame:SetPoint("TOPLEFT", -1, 1)
		btn.frame:SetPoint("BOTTOMRIGHT", 1, -1)
		btn.frame:SetTexture(HO.Skin.IconFrame())
		btn.frame:SetVertexColor(0.35, 0.55, 1.0, 1)

		btn.label = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		btn.label:SetPoint("BOTTOM", btn, "BOTTOM", 0, 1)
		btn.label:SetText(L["Aura"])
		btn.label:SetDrawLayer("OVERLAY", 3) -- above the frame ring
	end

	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["My Aura"])
		local me = HO.FullName("player")
		local id = me and HO.Plan.GetAura(me)
		local name = id and HO.Data.AuraName(id)
		if name then
			GameTooltip:AddLine(name, 1, 1, 1)
		else
			GameTooltip:AddLine(L["no aura assigned"], 0.8, 0.8, 0.8)
		end
		GameTooltip:AddLine(L["mouse wheel: change your aura"], 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return btn
end

-- true if the player currently has the given aura active (auras show as a
-- self-buff on the paladin), so the button can grey out when it is already up
local function PlayerHasAura(auraName)
	if not auraName then
		return false
	end
	for i = 1, 40 do
		local name = UnitBuff("player", i)
		if not name then
			break
		end
		if name == auraName then
			return true
		end
	end
	return false
end

-- the protection threat self-buff slot: a plain self-cast button whose icon is
-- bright while the buff is up and greyed out while it is missing — the whole
-- point is noticing a dropped Righteous Fury at a glance
local function CreateSelfBuffButton()
	local btn = CreateFrame("Button", "HolyOrdersBarSelfBuff", bar, "SecureActionButtonTemplate")
	btn:SetSize(ButtonCross(), BUTTON_SIZE)
	btn:RegisterForClicks("AnyDown", "AnyUp")
	-- always the same self-cast; spell1 is written out of combat in the refresh
	btn:SetAttribute("type1", "spell")
	btn:SetAttribute("unit1", "player")
	btn.hoSelfBuffButton = true

	btn.bg = btn:CreateTexture(nil, "BACKGROUND")
	btn.bg:SetAllPoints()
	btn.bg:SetTexture(WHITE8)
	btn.bg:SetVertexColor(0.30, 0.10, 0.10, 0.85) -- red tint: threat, not a blessing
	HO.Skin.MaskIcon(btn.bg)

	if HO.Skin.WideBar() then
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetSize(26, 26)
		btn.icon:SetPoint("LEFT", 4, 0)
		btn.label = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		btn.label:SetPoint("RIGHT", -7, 0)
	else
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetPoint("TOPLEFT", 2, -2)
		btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
		btn.label = btn:CreateFontString(nil, "OVERLAY", "HolyOrdersFontNormalSmall")
		btn.label:SetPoint("BOTTOM", btn, "BOTTOM", 0, 1)
		btn.label:SetDrawLayer("OVERLAY", 3)
	end
	HO.Skin.MaskIcon(btn.icon)
	btn.label:SetText(L["Fury"])

	btn.frame = btn:CreateTexture(nil, "OVERLAY", nil, 1)
	btn.frame:SetPoint("TOPLEFT", -1, 1)
	btn.frame:SetPoint("BOTTOMRIGHT", 1, -1)
	btn.frame:SetTexture(HO.Skin.IconFrame())

	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(HO.Data.selfBuff.name or L["Fury"])
		if PlayerHasAura(HO.Data.selfBuff.name) then
			GameTooltip:AddLine(L["active"], 0.4, 1, 0.4)
		else
			GameTooltip:AddLine(L["MISSING — click to cast"], 1, 0.4, 0.4)
		end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return btn
end

-- self-buff visuals: green ring while it is up, red while missing. Texture
-- work is not protected, so the state stays live in combat too; only the
-- secure spell attribute is written out of combat.
local function RefreshSelfBuffButton()
	if not selfBuffButton then
		return
	end
	local buff = HO.Data.selfBuff
	if not SelfBuffRelevant() then
		if not InCombatLockdown() then
			selfBuffButton:Hide()
		end
		return
	end
	local up = PlayerHasAura(buff.name)
	selfBuffButton.icon:SetTexture(buff.icon)
	selfBuffButton.icon:SetDesaturated(not up)
	selfBuffButton.icon:SetAlpha(up and 1 or 0.45)
	-- rgb() returns four values; inside an and/or expression Lua truncates it
	-- to the first one, so the call must stand alone in each branch
	if up then
		selfBuffButton.frame:SetVertexColor(HO.Colors.rgb("green", 1))
	else
		selfBuffButton.frame:SetVertexColor(HO.Colors.rgb("red", 1))
	end
	if not InCombatLockdown() then
		selfBuffButton:SetAttribute("spell1", buff.name)
		selfBuffButton:Show()
	end
end

-- aura-button visuals + secure self-cast attribute. The attribute is written
-- only out of combat; the combat branch refreshes the icon alone. The icon is
-- greyed out (desaturated + dimmed) when the assigned aura is NOT active, so a
-- bright icon means the correct aura is up.
local function RefreshAuraButton()
	if not auraButton then
		return
	end
	local me = HO.FullName("player")
	local id = me and HO.Plan.GetAura(me)
	local aura = id and HO.Data.auras[id]
	local castable = aura and aura.known and aura.name
	local dim = castable and not PlayerHasAura(aura.name)
	if InCombatLockdown() then
		auraButton.icon:SetTexture((castable and aura.icon) or NONE_ICON)
		auraButton.icon:SetDesaturated(dim or false)
		auraButton.icon:SetAlpha(dim and 0.45 or 1)
		return
	end
	if castable then
		auraButton:SetAttribute("spell1", aura.name)
		auraButton.icon:SetTexture(aura.icon)
	else
		-- none, or an assigned aura this paladin does not know: clear the cast and
		-- show the placeholder icon (same as the class-duty none marker)
		auraButton:SetAttribute("spell1", nil)
		auraButton.icon:SetTexture(NONE_ICON)
	end
	auraButton.icon:SetDesaturated(dim or false)
	auraButton.icon:SetAlpha(dim and 0.45 or 1)
end

-- user-configurable UI scale for the cast bar. The bar is implicitly protected
-- (secure buttons anchor to it), so SetScale may only run out of combat — a
-- combat-time change self-applies on the next PLAYER_REGEN_ENABLED, exactly like
-- Bar.ApplyStrata. The class/aura buttons are children of the bar, so they scale
-- with it automatically; only the fly-out (parented to UIParent) needs its own
-- SetScale to match.
function Bar.ApplyScale()
	if not bar or InCombatLockdown() then
		return
	end
	local scale = HO.db.options.bar and HO.db.options.bar.scale or 1
	bar:SetScale(scale)
	-- fly-out panels are children of the bar, so they inherit the scale
end

function Bar.Create()
	if bar then
		return
	end
	bar = CreateFrame("Frame", "HolyOrdersBar", UIParent)
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	bar:SetFrameStrata(BarOptions().front and "HIGH" or "LOW") -- see Bar.ApplyStrata

	handle = CreateFrame("Frame", nil, bar)
	handle:SetPoint("TOPLEFT", 0, 0)
	handle:SetSize(HANDLE_WIDTH, HANDLE_ACROSS)
	handle:EnableMouse(true)
	handle:RegisterForDrag("LeftButton")
	-- the bundled gem-node sprite (golden rail + faceted gem) fills the handle;
	-- it is rotated for vertical bars in LayoutBar, and swapped to the red-gem
	-- variant while a force rebuff is active
	handle.tex = handle:CreateTexture(nil, "ARTWORK")
	handle.tex:SetAllPoints()
	handle.tex:SetTexture(HANDLE_TEX)
	-- true while (and briefly after) a ctrl-drag, so releasing the drag is never
	-- mistaken for a click that would open the assignment window
	local handleDragging = false
	handle:SetScript("OnDragStart", function()
		if InCombatLockdown() then
			return -- moving the protected bar in combat would taint it
		end
		-- hold Ctrl to move; prevents accidental drags without a lock toggle
		if IsControlKeyDown() then
			handleDragging = true
			bar:StartMoving()
		end
	end)
	handle:SetScript("OnDragStop", function()
		-- ALWAYS stop the drag, even in combat: skipping this leaves the bar glued
		-- to the cursor (it eats every click). Only the position SAVE (a SetPoint on
		-- a frame with secure children) is unsafe in combat, so guard just that.
		bar:StopMovingOrSizing()
		if not InCombatLockdown() then
			SavePosition()
		end
		C_Timer.After(0.1, function()
			handleDragging = false
		end)
	end)
	handle:SetScript("OnMouseUp", function(_, mouseButton)
		if mouseButton == "LeftButton" then
			-- ctrl-left is the move gesture; a bare left click opens the window
			if not IsControlKeyDown() and not handleDragging then
				HO.Window.Toggle()
			end
		elseif mouseButton == "RightButton" then
			if IsShiftKeyDown() then
				HO.Options.Toggle()
			else
				Bar.ToggleForceRebuff()
			end
		end
	end)
	-- "[Gesture] action" hint line: gesture in bracket-gold, action in white
	local function HandleHint(gesture, action)
		return "|cff" .. HO.Colors.hex("goldBright") .. "[" .. L[gesture] .. "]|r " .. L[action]
	end
	handle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("HolyOrders")
		GameTooltip:AddLine(HandleHint("Left-Click", "Open the assignment window"), 1, 1, 1)
		GameTooltip:AddLine(HandleHint("Right-Click", "Toggle the force rebuff (pre-pull refresh)"), 1, 1, 1)
		GameTooltip:AddLine(HandleHint("Ctrl-Left-Drag", "Move the cast bar"), 1, 1, 1)
		GameTooltip:AddLine(HandleHint("Shift-Right-Click", "Open the options"), 1, 1, 1)
		if HO.Engine.ForceActive() then
			GameTooltip:AddLine("|cff" .. HO.Colors.hex("red") .. L["force rebuff is running — right-click cancels"] .. "|r")
		end
		GameTooltip:Show()
	end)
	handle:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	CreatePanels() -- per-class secure fly-out panels (before the buttons that reference them)
	for i = 1, MAX_BUTTONS do
		local btn = CreateButton(i)
		btn:Hide()
		buttons[i] = btn
	end
	-- wire every class button to every panel: the _onenter snippet needs refs to
	-- its OWN panel (to show) and to all others (to cross-hide on switch). Frame
	-- refs may only be created out of combat — login qualifies.
	for i = 1, MAX_BUTTONS do
		local btn = buttons[i]
		btn:SetAttribute("classIndex", i)
		btn:SetAttribute("numPanels", MAX_BUTTONS)
		for j = 1, MAX_BUTTONS do
			SecureHandlerSetFrameRef(btn, "flyout" .. j, flyoutPanels[j])
		end
	end
	auraButton = CreateAuraButton() -- always present; follows the bar's visibility
	selfBuffButton = CreateSelfBuffButton() -- protection only; hidden otherwise
	selfBuffButton:Hide()
	-- keep the golden handle as the topmost element of the bar (above the buttons)
	-- so it stays visible and grabbable when the bar is raised over other windows
	handle:SetFrameLevel((bar:GetFrameLevel() or 1) + 10)
	LayoutBar()
	RestorePosition()
	Bar.ApplyScale() -- apply the saved cast-bar scale (out of combat at login)
	bar:Hide()
end

function Bar.ToggleForceRebuff()
	if HO.Engine.ForceActive() then
		HO.Engine.StopForceRebuff()
		HO.Print(L["force rebuff cancelled"])
	else
		HO.Engine.StartForceRebuff()
		HO.Print(L["force rebuff: refreshing everything older than 2 minutes (ends when all fresh)"])
	end
	Bar.Refresh()
end

function Bar.Refresh()
	if not bar or not HO.db then
		return
	end
	HO.Engine.Update()
	if handle then
		-- overall status light: rest (no duties) / red (missing or force rebuff)
		-- / yellow (attention) / green (all covered)
		local state = "rest"
		if HO.Engine.ForceActive() then
			state = "red"
		else
			local worst = BarStatus()
			if worst then
				state = worst
			end
		end
		local handleStyle = HO.Skin.HandleStyle()
		if handleStyle == "dot" then
			handle.tex:SetTexture(HANDLE_DOTS[state]) -- little round status ball
			handle.tex:SetVertexColor(1, 1, 1, 1)
		elseif handleStyle == "wheel" then
			handle.tex:SetTexture(WHEEL_TEX) -- rim and spokes take the status tint
			if state == "rest" then
				handle.tex:SetVertexColor(HO.Colors.rgb("handleRest", 1))
			else
				handle.tex:SetVertexColor(HO.Colors.rgb(state, 1))
			end
			-- the wheel spins while a force rebuff runs (texture animation only —
			-- nothing protected, safe in combat)
			if not handle.spin and handle.tex.CreateAnimationGroup then
				handle.spin = handle.tex:CreateAnimationGroup()
				local rot = handle.spin:CreateAnimation("Rotation")
				rot:SetDegrees(-360)
				rot:SetDuration(WHEEL_SPIN_SECONDS)
				handle.spin:SetLooping("REPEAT")
			end
			if handle.spin then
				if HO.Engine.ForceActive() then
					if not handle.spin:IsPlaying() then
						handle.spin:Play()
					end
				elseif handle.spin:IsPlaying() then
					handle.spin:Stop()
				end
			end
		elseif handleStyle == "strip" then
			handle.tex:SetTexture(WHITE8) -- slim strip tinted by status
			if state == "rest" then
				handle.tex:SetVertexColor(HO.Colors.rgb("handleRest", 0.95))
			else
				handle.tex:SetVertexColor(HO.Colors.rgb(state, 0.95))
			end
		else
			handle.tex:SetTexture(HANDLE_SPRITES[state]) -- gem sprite variants
			handle.tex:SetVertexColor(1, 1, 1, 1)
		end
	end

	if InCombatLockdown() then
		-- attributes and shown-state are frozen; only refresh texts of the
		-- buttons that are already visible, matched by their frozen class
		for i = 1, MAX_BUTTONS do
			local btn = buttons[i]
			if btn:IsShown() and btn.task then
				local task = HO.Engine.tasks[btn.task.classToken]
				if task then
					UpdateButtonTexts(btn, task)
					-- texture ops are not protected: keep the done-state dim live
					btn.icon:SetDesaturated(task.spellName == nil and not task.noneAssigned)
				end
			end
		end
		RefreshAuraButton() -- icon only in combat; never touches attributes
		RefreshSelfBuffButton() -- same: live icon/ring, no attribute writes
		-- fly-out panels stay usable in combat (secure snippets show/hide them);
		-- their layout/attributes are frozen, but the VISUALS of shown rows are
		-- plain textures/fontstrings — keep those tracking reality
		FlyoutRefreshShownVisuals()
		return
	end

	if (BarOptions().grow or "right") ~= lastGrow then
		-- the frame changes shape (long ↔ tall) while keeping its corner anchor,
		-- which would fling the whole bar ~320 px; record the handle's screen
		-- position (the handle is the origin end in every mode, so users read it
		-- as "the" location) and shift the bar so the handle stays put
		local hLeft, hTop = handle:GetLeft(), handle:GetTop()
		LayoutBar()
		local nhLeft, nhTop = handle:GetLeft(), handle:GetTop()
		if hLeft and hTop and nhLeft and nhTop then
			local point, _, relPoint, x, y = bar:GetPoint()
			if point then
				bar:ClearAllPoints()
				bar:SetPoint(point, UIParent, relPoint or point,
					(x or 0) + (hLeft - nhLeft), (y or 0) + (hTop - nhTop))
				SavePosition()
			end
		end
	end

	-- class-fixed buttons: each button permanently owns its CLASS_ORDER slot; the
	-- visible ones are compacted into consecutive bar slots here (out of combat)
	local shown = 0
	-- one click edge, following the user's cvar (defaults to cast-on-up). Kept in
	-- sync out of combat so the OnClick wrap runs exactly once per click.
	local clickEdge = (GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")) and "AnyDown" or "AnyUp"
	local haveSymbols = HO.Data.SymbolCount() > 0 -- gates the right-click greater
	for i, classToken in ipairs(CLASS_ORDER) do
		local btn = buttons[i]
		local task = HO.Engine.tasks[classToken]
		btn.task = task
		if task then
			shown = shown + 1
			PlaceButtonInSlot(btn, shown)
			if HO.Skin.WideBar() then
				-- class-coloured row fill, the classic look
				local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
				if cc then
					btn.bg:SetVertexColor(cc.r * 0.32, cc.g * 0.32, cc.b * 0.32, 0.9)
				else
					btn.bg:SetVertexColor(0, 0, 0, 0.8)
				end
			end
			local blessing = HO.Data.blessings[task.blessingID]
			-- right-click: ALWAYS the greater blessing of this duty (one cast covers
			-- the whole class) when it is known and a Symbol of Kings is on hand —
			-- falls back to the single otherwise. Anchored to the engine's target or
			-- any class member, so it also works as a re-buff when all are covered.
			local rightSpell = task.singleSpellName or (blessing and blessing.name)
			local rightIsGreater = false
			if blessing and blessing.greaterKnown and blessing.greaterName and haveSymbols then
				rightSpell = blessing.greaterName
				rightIsGreater = true
			end
			local rightUnit = task.unit
			if not rightUnit then
				for _, m in ipairs(HO.Engine.ClassMembers(classToken)) do
					if not m.isPet and m.unit then
						rightUnit = m.unit
						break
					end
				end
			end
			btn.rightSpell, btn.rightIsGreater = rightSpell, rightIsGreater
			btn:SetAttribute("spell2", rightSpell)
			btn:SetAttribute("unit2", rightUnit)
			-- out-of-combat left-click: the engine's planned cast on its chosen
			-- target. In combat the secure OnClick wrap rewrites this macro per
			-- click to cycle the class's members, so no combat clauses are needed.
			local macro = ""
			if task.spellName and task.unit then
				macro = "/cast [@" .. task.unit .. ",help,nodead] " .. task.spellName
			end
			btn:SetAttribute("macrotext1", macro)
			-- bake the combat-cycle data as paired attributes, one per target:
			--   players → by name (stable across roster shifts), with the GREATER
			--   when the engine would use it (one cast covers the class incl. its
			--   pets), else their OWN assigned single (overrides may differ);
			--   pets → by unit token (no reliable name targeting), with their own
			--   single — skipped in greater mode, which reaches them anyway
			local useGreater = blessing and blessing.greaterName and HO.Engine.WouldUseGreater(classToken)
			local n = 0
			for _, m in ipairs(HO.Engine.ClassMembers(classToken)) do
				if n >= FLYOUT_MAX_ROWS then
					break
				end
				local targetRef, targetSpell
				if m.isPet then
					if not useGreater then
						local mb = m.blessingID and HO.Data.blessings[m.blessingID]
						targetRef, targetSpell = m.unit, mb and mb.name
					end
				else
					if useGreater then
						targetRef, targetSpell = m.name, blessing.greaterName
					else
						local mb = m.blessingID and HO.Data.blessings[m.blessingID]
						targetRef, targetSpell = m.name, mb and mb.name
					end
				end
				if targetRef and targetSpell then
					n = n + 1
					btn:SetAttribute("cycleName" .. n, targetRef)
					btn:SetAttribute("cycleSpell" .. n, targetSpell)
				end
			end
			for k = n + 1, btn.cycleBaked or 0 do
				btn:SetAttribute("cycleName" .. k, nil)
				btn:SetAttribute("cycleSpell" .. k, nil)
			end
			btn.cycleBaked = n
			btn:SetAttribute("cycleCount", n)
			btn:SetAttribute("cycleStep", 1)
			btn:RegisterForClicks(clickEdge)
			btn.icon:SetTexture(task.icon)
			-- placeholder (none) buttons show their icon at full colour; ordinary
			-- passive tasks (nothing to cast right now) stay desaturated
			btn.icon:SetDesaturated(task.spellName == nil and not task.noneAssigned)
			local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classToken]
			if coords then
				btn.classIcon:SetTexCoord(unpack(coords))
				btn.classIcon:Show()
			else
				btn.classIcon:Hide()
			end
			UpdateButtonTexts(btn, task)
			btn:Show()
		else
			btn:Hide()
			btn.rightSpell, btn.rightIsGreater = nil, nil
			btn:SetAttribute("macrotext1", nil)
			btn:SetAttribute("spell2", nil)
			btn:SetAttribute("unit2", nil)
			btn:SetAttribute("cycleCount", 0)
		end
		-- (re)configure this class's fly-out panel to match (rows, size, anchor)
		FlyoutConfigure(i, classToken, task, btn, task ~= nil)
	end

	RefreshAuraButton()
	RefreshSelfBuffButton()
	local isPally = select(2, UnitClass("player")) == "PALADIN"
	-- the aura slot is always relevant to a paladin, so the bar shows when there
	-- are duties OR an aura is assigned (so the aura button is reachable to wheel)
	local me = HO.FullName("player")
	local hasAura = me and HO.Plan.GetAura(me)
	-- the self-buff slot keeps the bar reachable too, so a protection paladin
	-- without duties still sees their threat buff status
	if isPally and not BarOptions().hidden and (shown > 0 or hasAura or SelfBuffRelevant()) then
		bar:Show()
		auraButton:Show()
	else
		bar:Hide()
		FlyoutHideAll() -- the bar (and its buttons) went away; close the fly-outs
	end

	-- a tooltip open over a button now describes freshly-reassigned data; a
	-- single owner check re-renders it (or hides it if the button went away)
	local owner = GameTooltip:GetOwner()
	if owner and owner.hoAuraButton then
		if owner:IsShown() then
			local onEnter = owner:GetScript("OnEnter")
			if onEnter then
				onEnter(owner)
			end
		else
			GameTooltip:Hide()
		end
	elseif owner and owner.hoBarButton then
		if owner:IsShown() and owner.task then
			local onEnter = owner:GetScript("OnEnter")
			if onEnter then
				onEnter(owner)
			end
		else
			GameTooltip:Hide()
		end
	end
end

-- one-line-per-class diagnostic for /ho bar: why is a button/panel (not) shown,
-- what would the combat cycle do, and what keeps a force rebuff alive
function Bar.Debug()
	local lines = {}
	local forceLeft = HO.Engine.forceUntil and math.floor(HO.Engine.forceUntil - GetTime()) or 0
	lines[#lines + 1] = "force rebuff: " .. (HO.Engine.ForceActive() and ("ACTIVE, " .. forceLeft .. "s until timeout") or "off")
	for i, classToken in ipairs(CLASS_ORDER) do
		local btn = buttons[i]
		local task = HO.Engine.tasks[classToken]
		local members = HO.Engine.ClassMembers(classToken)
		local panel = flyoutPanels[i]
		if task or #members > 0 or (btn and btn:IsShown()) then
			lines[#lines + 1] = string.format(
				"%s: task=%s btn=%s members=%d cycle=%s panel=%s reach=%d miss=%d exp=%d oor=%d",
				classToken,
				task and (task.noneAssigned and "none" or (task.spellName or "passive")) or "NIL",
				(btn and btn:IsShown()) and "shown" or "hidden",
				#members,
				btn and tostring(btn:GetAttribute("cycleCount")) or "?",
				panel and ((panel:GetAttribute("active") == 1) and "active" or "inactive") or "?",
				task and (task.reachable or 0) or 0,
				task and (task.missing or 0) or 0,
				task and (task.expiring or 0) or 0,
				task and (task.outOfRange or 0) or 0)
		end
	end
	return lines
end

function Bar.Init()
	Bar.Create()
	if not ticker then
		ticker = C_Timer.NewTicker(UPDATE_INTERVAL, Bar.Refresh)
	end
	HO.Roster.OnChanged(Bar.Refresh)
end

HO.RegisterEvent("PLAYER_LOGIN", Bar.Init)
HO.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingReset then
		pendingReset = nil
		Bar.ResetPosition()
	end
	Bar.ApplyStrata() -- apply any strata change made during combat
	Bar.ApplyScale() -- apply any scale change attempted during combat
	Bar.Refresh()
end)
HO.RegisterEvent("PLAYER_REGEN_DISABLED", function()
	-- fly-out panels intentionally stay available: the secure snippets keep
	-- opening/closing them during combat with their pre-baked rows.
	-- End any in-progress bar drag so it can't keep following the cursor into
	-- combat (where OnDragStop would otherwise be unable to persist the move)
	if bar then
		bar:StopMovingOrSizing()
	end
end)
