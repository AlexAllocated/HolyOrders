-- HolyOrders — skin registry and dispatcher
-- Every skin is an ADAPTER living in Skins/<Name>.lua and registered via
--     HO.Skin.Register("name", def)
-- Third-party addons can ship their own skin the same way: depend on
-- HolyOrders, call HO.Skin.Register from your addon file, and the skin shows
-- up in the options dropdown (registration is re-resolved at PLAYER_LOGIN, so
-- dependent addons register in time). A def supports:
--   palette      table of HO.Colors overrides, or a function returning one
--                (resolved at load; see Colors.lua for the available keys)
--   font         a font file path, or a function returning one — swaps the
--                face of every HolyOrders text (sizes and flags are kept)
--   Panel        function(frame, corner) — paint window/fly-out panel chrome
--   Button       function(btn) — restyle a UIPanelButtonTemplate (nil = stock)
--   CloseButton  function(btn) — restyle a UIPanelCloseButton (nil = stock)
--   available    function() -> ok, reason — gate (e.g. requires another addon)
--   roundIcons   true: icons keep the rounded mask + round status ring
--   decorated    true: show the title gem and the corner crest
--   handle       "gem" | "dot" | "strip" — cast-bar handle style
--   wideBar      true: the cast bar uses wide class-coloured rows
--   bareFlyout   true: fly-out shows bare wide rows instead of a titled panel
-- Skins apply at UI load; switching prompts for a reload.

local HO = HolyOrders
local Skin = {}
HO.Skin = Skin

local PATH = "Interface\\AddOns\\HolyOrders\\Icons\\"
Skin.tex = {
	bg = PATH .. "WindowBg",
	button = PATH .. "WindowButton",
	buttonHi = PATH .. "WindowButtonHi",
	buttonPush = PATH .. "WindowButtonPushed",
	close = PATH .. "WindowClose",
	closeHi = PATH .. "WindowCloseHi",
	gem = PATH .. "TitleGem",
	logo = PATH .. "Logo",
	mask = PATH .. "ButtonMask",
	frameRound = PATH .. "ButtonFrame",
	frameSquare = PATH .. "ButtonFrameSquare",
}
Skin.WHITE = "Interface\\Buttons\\WHITE8x8"
-- 9-slice geometry of the default panel art (used by Skins/Default.lua)
Skin.CORNER = 16

-- fonts --------------------------------------------------------------------------
-- HolyOrders texts use these font objects instead of the Blizzard ones, so a
-- skin can swap the face in ONE place (font-object changes propagate to every
-- attached FontString live). Each mirrors the Blizzard object it inherits.

local FONT_ROLES = {
	{ name = "HolyOrdersFontNormal", inherit = "GameFontNormal" },
	{ name = "HolyOrdersFontNormalSmall", inherit = "GameFontNormalSmall" },
	{ name = "HolyOrdersFontNormalLarge", inherit = "GameFontNormalLarge" },
	{ name = "HolyOrdersFontHighlight", inherit = "GameFontHighlight" },
	{ name = "HolyOrdersFontHighlightSmall", inherit = "GameFontHighlightSmall" },
	{ name = "HolyOrdersFontDisableSmall", inherit = "GameFontDisableSmall" },
}
for _, role in ipairs(FONT_ROLES) do
	if not _G[role.name] then
		local f = CreateFont(role.name)
		f:CopyFontObject(role.inherit)
	end
end

-- apply a skin's font face: re-copy from the Blizzard base (resets a previous
-- skin's face and picks up sizes/flags), then swap only the face
local function ApplyFont(face)
	for _, role in ipairs(FONT_ROLES) do
		local f = _G[role.name]
		f:CopyFontObject(role.inherit)
		if face then
			local _, size, flags = f:GetFont()
			-- 2.5.6 validates the flag argument strictly; GetFont() hands back
			-- nil when a font object carries no flags, so pass "" instead.
			f:SetFont(face, size, flags or "")
		end
	end
end

-- registry ---------------------------------------------------------------------

local defs = {}
Skin.SKINS = {} -- registration order; drives the options dropdown

function Skin.Register(name, def)
	if type(name) ~= "string" or type(def) ~= "table" or defs[name] then
		return
	end
	def.name = name
	defs[name] = def
	Skin.SKINS[#Skin.SKINS + 1] = name
end

Skin.current = "default"
Skin.active = nil

-- resolve the active skin from the saved option and merge its palette into
-- HO.Colors. Runs before any skinned frame is created.
function Skin.Init()
	local s = HO.db and HO.db.options and HO.db.options.skin
	local def = s and defs[s]
	if def and def.available then
		local ok, reason = def.available()
		if not ok then
			HO.Log("skin", "skin '" .. tostring(s) .. "' unavailable (" .. tostring(reason) .. ") — using default")
			def = nil
		end
	end
	if not def then
		def = defs["default"]
		s = "default"
	end
	Skin.current = s
	Skin.active = def
	local palette = def and def.palette
	if type(palette) == "function" then
		palette = palette()
	end
	if palette then
		for key, colour in pairs(palette) do
			HO.Colors[key] = colour
		end
	end
	local face = def and def.font
	if type(face) == "function" then
		face = face()
	end
	ApplyFont(face) -- nil restores the Blizzard faces
	HO.Log("skin", "active skin: " .. tostring(s)
		.. " (option: " .. tostring(HO.db and HO.db.options and HO.db.options.skin) .. ")")
end

local booted = false
HO.RegisterEvent("ADDON_LOADED", function()
	if HO.db and not booted then
		booted = true
		Skin.Init()
	end
end)
-- re-resolve at PLAYER_LOGIN (still before frame creation): skins registered by
-- DEPENDENT addons load after us and must be picked up too
HO.RegisterEvent("PLAYER_LOGIN", Skin.Init)

-- dispatchers -------------------------------------------------------------------

function Skin.Panel(frame, corner)
	local def = Skin.active
	if def and def.Panel then
		def.Panel(frame, corner)
	end
end

function Skin.Button(btn)
	local def = Skin.active
	if def and def.Button then
		def.Button(btn)
	end
end

function Skin.CloseButton(btn)
	local def = Skin.active
	if def and def.CloseButton then
		def.CloseButton(btn)
	end
end

-- flag helpers (safe defaults when no skin resolved yet) ------------------------

function Skin.MaskIcon(texture)
	if Skin.active and Skin.active.roundIcons then
		texture:SetMask(Skin.tex.mask)
	end
end

-- the tintable status ring drawn around icons/rows: round or square
function Skin.IconFrame()
	return (Skin.active and Skin.active.roundIcons) and Skin.tex.frameRound or Skin.tex.frameSquare
end

function Skin.HandleStyle()
	return (Skin.active and Skin.active.handle) or "gem"
end

function Skin.WideBar()
	return (Skin.active and Skin.active.wideBar) or false
end

function Skin.BareFlyout()
	return (Skin.active and Skin.active.bareFlyout) or false
end

function Skin.Decorated()
	if not Skin.active then
		return true
	end
	return Skin.active.decorated or false
end

-- shared building blocks for skin files -----------------------------------------

-- a thin palette-coloured seam line across `frame` at vertical offset y
-- (negative = below the top edge), inset to clear the panel corners
function Skin.Seam(frame, y)
	local seam = frame:CreateTexture(nil, "ARTWORK")
	seam:SetHeight(1)
	seam:SetPoint("TOPLEFT", frame, "TOPLEFT", Skin.CORNER, y)
	seam:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Skin.CORNER, y)
	seam:SetColorTexture(HO.Colors.rgb("goldDeep", 0.8))
	return seam
end

-- template buttons carry their own SetTexCoord; reset it so a full-frame
-- texture fills the button instead of showing a sliced region
function Skin.StripCoords(t)
	if t then
		t:SetTexCoord(0, 1, 0, 1)
	end
end

-- flat panel: palette fill + 1 px palette border (the shared look of the flat
-- skin family; requires the frame to carry BackdropTemplate)
function Skin.FlatPanel(frame)
	if not frame.SetBackdrop then
		return
	end
	frame:SetBackdrop({
		bgFile = Skin.WHITE,
		edgeFile = Skin.WHITE,
		edgeSize = 1,
	})
	frame:SetBackdropColor(HO.Colors.rgb("panelBg", 0.96))
	frame:SetBackdropBorderColor(HO.Colors.rgb("goldDeep", 1))
end

-- flat button: palette fills with a light label
function Skin.FlatButton(btn)
	btn:SetNormalTexture(Skin.WHITE)
	btn:SetPushedTexture(Skin.WHITE)
	btn:SetHighlightTexture(Skin.WHITE)
	btn:GetNormalTexture():SetVertexColor(HO.Colors.rgb("btnNormal", 0.95))
	btn:GetPushedTexture():SetVertexColor(HO.Colors.rgb("btnPushed", 0.95))
	local hl = btn:GetHighlightTexture()
	hl:SetVertexColor(HO.Colors.rgb("btnHover", 0.6))
	hl:SetBlendMode("BLEND")
	local fs = btn:GetFontString()
	if fs then
		fs:SetTextColor(HO.Colors.rgb("goldBright"))
	end
end
