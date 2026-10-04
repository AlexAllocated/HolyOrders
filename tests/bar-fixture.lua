-- Records actual Bar.lua attributes and fails on insecure writes in combat.
-- Textures/fonts are unprotected; secure snippets may write during a click.
return function(H, f)
	local methods = {}
	local cosmetic = {
		"SetAllPoints",
		"SetAlpha",
		"SetClampedToScreen",
		"SetColorTexture",
		"SetDesaturated",
		"SetDrawLayer",
		"SetFrameStrata",
		"SetJustifyH",
		"SetMovable",
		"SetRotation",
		"SetScale",
		"SetTexCoord",
		"SetTextColor",
		"SetTexture",
		"SetToplevel",
		"SetVertexColor",
		"SetWordWrap",
		"EnableMouse",
		"EnableMouseWheel",
		"RegisterForClicks",
		"RegisterForDrag",
		"StopMovingOrSizing",
	}
	for _, name in ipairs(cosmetic) do
		methods[name] = H.noop
	end
	function methods:SetAttribute(k, v)
		assert(not self.protected or not f.combat or f.secureClick, "insecure attribute write in combat")
		self.attrs[k] = v
	end
	function methods:GetAttribute(k)
		return self.attrs[k]
	end
	function methods:SetScript(k, v)
		self.scripts[k] = v
	end
	function methods:GetScript(k)
		return self.scripts[k]
	end
	function methods:HookScript(k, v)
		self.scripts[k] = v
	end
	function methods:WrapScript(_, event, code)
		self.wrapped[event] = code
	end
	function methods:SetSize(w, h)
		self.width, self.height = w, h
	end
	function methods:SetWidth(w)
		self.width = w
	end
	function methods:SetHeight(h)
		self.height = h
	end
	function methods:GetWidth()
		return self.width or 34
	end
	function methods:SetPoint(...)
		self.point = { ... }
	end
	function methods:GetPoint()
		return unpack(self.point or { "CENTER", UIParent, "CENTER", 0, 0 })
	end
	function methods:ClearAllPoints()
		self.point = nil
	end
	function methods:GetFrameLevel()
		return 1
	end
	methods.SetFrameLevel = H.noop
	function methods:Show()
		self.shown = true
	end
	function methods:Hide()
		self.shown = false
	end
	function methods:IsShown()
		return self.shown
	end
	function methods:SetShown(v)
		self.shown = v
	end
	function methods:SetText(text)
		self.text = text
	end
	function methods:GetStringWidth()
		return #(self.text or "") * 6
	end
	function methods:GetFont()
		return "font", 12, ""
	end
	methods.SetFont = H.noop
	function methods:GetLeft()
		return 0
	end
	function methods:GetTop()
		return 0
	end
	local function object(protected)
		return setmetatable(
			{ attrs = {}, scripts = {}, wrapped = {}, protected = protected },
			{ __index = methods }
		)
	end
	function methods:CreateTexture()
		return object(false)
	end
	function methods:CreateFontString()
		return object(false)
	end
	f.frames = {}
	CreateFrame = function(_, name, parent, template)
		local frame = object(template and template:find("Secure", 1, true))
		if name then
			f.frames[name] = frame
		end
		return frame
	end
	UIParent = object(false)
	GameTooltip = { GetOwner = H.noop, Hide = H.noop }
	SecureHandlerSetFrameRef = H.noop
	f.HO.Skin = {
		WideBar = function()
			return false
		end,
		BareFlyout = function()
			return false
		end,
		HandleStyle = function()
			return "gem"
		end,
		IconFrame = function()
			return "frame"
		end,
		MaskIcon = H.noop,
		Panel = H.noop,
		Seam = function()
			return object(false)
		end,
	}
	f.HO.Colors = {
		rgb = function()
			return 1, 1, 1
		end,
		hex = function()
			return "ffffff"
		end,
	}
	H.load("Bar.lua")
	f.HO.Bar.Create()
	f.HO.Bar.Refresh()
	function f:button(class)
		for _, frame in pairs(self.frames) do
			if frame.hoBarButton and frame.classToken == class then
				return frame
			end
		end
		error("missing class button: " .. class)
	end
	function f:panel(class)
		for name, frame in pairs(self.frames) do
			if name:match("^HolyOrdersFlyout") and frame.classToken == class then
				return frame
			end
		end
	end
	function f:click(button)
		self.combat, self.secureClick = true, true
		SecureCmdOptionParse = function()
			return "1"
		end
		local snippet =
			assert((loadstring or load)("return function(self) " .. button.wrapped.OnClick .. " end"))()
		snippet(button)
		self.secureClick = false
		return button.attrs.macrotext1
	end
end
