-- HolyOrders — debug/utility slash commands

local HO = HolyOrders

local CLASS_TOKENS = {
	WARRIOR = true, ROGUE = true, PRIEST = true, MAGE = true, WARLOCK = true,
	HUNTER = true, SHAMAN = true, DRUID = true, PALADIN = true,
}

local function BlessingLabel(id)
	local blessing = HO.Data.blessings[id]
	return blessing and (blessing.name or blessing.key) or ("#" .. tostring(id))
end

HO.commands["spells"] = function()
	HO.Print("blessings:")
	for id, blessing in ipairs(HO.Data.blessings) do
		local normal
		if blessing.known then
			local rank = (blessing.rank and blessing.rank ~= "") and (" [" .. blessing.rank .. "]") or ""
			normal = (blessing.name or blessing.key) .. rank
		else
			normal = (blessing.name or blessing.key) .. " — NOT known"
		end
		local greater
		if blessing.greaterKnown then
			local grank = (blessing.greaterRank and blessing.greaterRank ~= "") and (" [" .. blessing.greaterRank .. "]") or ""
			greater = "greater" .. grank
		else
			greater = "no greater"
		end
		local talent = HO.Talents.ranks[id]
		HO.PrintLine(string.format("%d. %s | %s | talent: %s", id, normal, greater, talent and tostring(talent) or "-"))
	end
	HO.Print("Symbol of Kings: " .. HO.Data.SymbolCount())
	HO.Print("talent distribution: " .. HO.Talents.SpecSummary())
end

HO.commands["roster"] = function()
	local units = HO.Roster.units
	if #units == 0 then
		HO.Print("roster is empty — scan pending or not grouped (try again in a second)")
		HO.Roster.Queue()
		return
	end
	HO.Print(string.format("roster: %d units, paladins: %s", #units, table.concat(HO.Roster.Paladins(), ", ")))
	for _, entry in ipairs(units) do
		local tags = {}
		if entry.isPet then
			table.insert(tags, "pet of " .. (entry.owner or "?"))
		end
		if entry.tankRole then
			table.insert(tags, "MAINTANK")
		end
		if not entry.online then
			table.insert(tags, "offline")
		end
		HO.PrintLine(string.format(
			"[%s] %s (L%s) g%s%s",
			entry.class or "?",
			entry.name or "?",
			tostring(entry.level or "?"),
			tostring(entry.subgroup or "?"),
			#tags > 0 and (" — " .. table.concat(tags, ", ")) or ""
		))
	end
end

-- plan management ------------------------------------------------------------

local storedList = {} -- last /ho plan list order, for delete by number

HO.commands["plan"] = function(rest)
	local sub, arg = rest:match("^(%S*)%s*(.*)$")
	sub = (sub or ""):lower()

	if sub == "show" then
		local plan = HO.Plan.Active()
		HO.Print("active plan — roster: " .. (HO.db.activeSignature or "?"))
		for paladin, classes in pairs(plan.class) do
			HO.PrintLine(paladin .. ":")
			for classToken, a in pairs(classes) do
				if a.id then
					HO.PrintLine(string.format("   %s > %s (%s)", classToken, BlessingLabel(a.id), a.mode or "auto"))
				else
					HO.PrintLine(string.format("   %s > none (explicit)", classToken))
				end
			end
		end
		for paladin, targets in pairs(plan.player) do
			for target, id in pairs(targets) do
				HO.PrintLine(string.format("   override: %s buffs %s on %s", paladin, BlessingLabel(id), target))
			end
		end
		local tanks, suppressed = {}, {}
		for name, flag in pairs(plan.tanks) do
			table.insert(flag and tanks or suppressed, name)
		end
		if #tanks > 0 then
			table.sort(tanks)
			HO.PrintLine("tanks: " .. table.concat(tanks, ", "))
		end
		if #suppressed > 0 then
			table.sort(suppressed)
			HO.PrintLine("explicitly NOT tanks: " .. table.concat(suppressed, ", "))
		end
	elseif sub == "save" then
		local sig = HO.Plan.Save(arg)
		if sig then
			HO.Print("plan saved for roster: " .. sig .. (arg ~= "" and (" ('" .. arg .. "')") or ""))
		else
			HO.Print("cannot save: no paladins in roster (scan pending?)")
		end
	elseif sub == "list" then
		wipe(storedList)
		for sig, plan in pairs(HO.db.plans) do
			table.insert(storedList, { sig = sig, plan = plan })
		end
		table.sort(storedList, function(a, b)
			return (a.plan.meta.lastUsed or 0) > (b.plan.meta.lastUsed or 0)
		end)
		HO.Print(#storedList .. " stored plan(s):")
		for i, item in ipairs(storedList) do
			HO.PrintLine(string.format("%d. %s%s", i, item.plan.meta.name and ("'" .. item.plan.meta.name .. "' — ") or "", item.sig))
		end
	elseif sub == "apply" then
		if HO.Plan.ApplySuggestion() then
			HO.Print("suggested plan applied")
		else
			HO.Print("no plan suggestion pending")
		end
	elseif sub == "delete" then
		local index = tonumber(arg)
		local item = index and storedList[index]
		-- identity check: the list may be stale if the sig was re-saved
		if item and HO.db.plans[item.sig] == item.plan then
			HO.db.plans[item.sig] = nil
			HO.Print("deleted plan " .. index .. " (" .. item.sig .. ")")
		else
			HO.Print("usage: /ho plan list, then /ho plan delete <number>")
		end
	elseif sub == "clear" then
		local n = 0
		for _ in pairs(HO.db.plans) do
			n = n + 1
		end
		if arg == "yes" then
			wipe(HO.db.plans)
			wipe(storedList)
			HO.db.activeSignature = nil
			HO.Print("all " .. n .. " stored plan(s) deleted (the active plan is untouched)")
		else
			HO.Print("this deletes all " .. n .. " stored plan(s) — '/ho plan clear yes' to confirm")
		end
	else
		HO.Print("usage: /ho plan show | save [label] | list | apply | delete <number> | clear")
	end
end

-- assignment editing (debug interface until the UI exists) --------------------

HO.commands["assign"] = function(rest)
	local classToken, id, mode = rest:match("^(%S+)%s+(%S+)%s*(%S*)$")
	classToken = classToken and classToken:upper()
	id = tonumber(id)
	if not classToken or not CLASS_TOKENS[classToken] or not id or not (id == 0 or HO.Data.blessings[id]) then
		HO.Print("usage: /ho assign <class> <blessing 0-" .. HO.Data.NUM_BLESSINGS .. "> [auto|greater|normal]")
		HO.Print("example: /ho assign WARRIOR 2  (0 clears)")
		return
	end
	local me = HO.FullName("player")
	HO.Plan.SetClassAssignment(me, classToken, id, mode ~= "" and mode:lower() or nil)
	if id == 0 then
		HO.Print("cleared " .. classToken)
	else
		HO.Print(classToken .. " > " .. BlessingLabel(id))
	end
end

HO.commands["override"] = function(rest)
	local target, id = rest:match("^(%S+)%s+(%S+)$")
	id = tonumber(id)
	if not target or not id or not (id == 0 or HO.Data.blessings[id]) then
		HO.Print("usage: /ho override <playerName> <blessing 0-" .. HO.Data.NUM_BLESSINGS .. ">  (0 clears)")
		return
	end
	local entry
	target, entry = HO.Roster.Resolve(target)
	if not entry then
		HO.Print("target is not in the roster")
		return
	end
	HO.Plan.SetPlayerOverride(HO.FullName("player"), target, id)
	-- a manual override records the member's liking (0 clears both); pets excluded
	if not entry.isPet then
		HO.Plan.SetMemberPref(target, id ~= 0 and id or nil)
	end
	if id == 0 then
		HO.Print("override cleared for " .. target)
	else
		HO.Print("override: " .. BlessingLabel(id) .. " on " .. target)
	end
end

HO.commands["prefs"] = function(rest)
	local sub, arg = rest:match("^(%S*)%s*(.*)$")
	sub = (sub or ""):lower()
	local prefs = HO.db.memberPrefs or {}
	if sub == "" then
		local names = {}
		for name in pairs(prefs) do
			table.insert(names, name)
		end
		if #names == 0 then
			HO.Print("no member preferences remembered")
			return
		end
		table.sort(names)
		HO.Print(#names .. " remembered member preference(s):")
		for _, name in ipairs(names) do
			HO.PrintLine(name .. " — " .. BlessingLabel(prefs[name]))
		end
	elseif sub == "clear" then
		if arg:lower() == "all" then
			local names = {}
			for name in pairs(prefs) do
				table.insert(names, name)
			end
			for _, name in ipairs(names) do
				HO.Plan.SetMemberPref(name, nil)
			end
			HO.Print("forgot all " .. #names .. " remembered member preference(s)")
		elseif arg ~= "" then
			-- resolve case-insensitively against the stored keys, exact key first
			local match
			if prefs[arg] then
				match = arg
			else
				local lower = arg:lower()
				for name in pairs(prefs) do
					if name:lower() == lower then
						match = name
						break
					end
				end
			end
			if match then
				HO.Plan.SetMemberPref(match, nil)
				HO.Print("forgot remembered preference for " .. match)
			else
				HO.Print("no remembered preference for " .. arg)
			end
		else
			HO.Print("usage: /ho prefs clear <name> | clear all")
		end
	else
		HO.Print("usage: /ho prefs  (list) | clear <name> | clear all")
	end
end

-- debugging -------------------------------------------------------------------

HO.commands["log"] = function(rest)
	if rest == "clear" then
		wipe(HO.db.log)
		HO.Print("debug log cleared")
		return
	end
	local n = tonumber(rest) or 15
	local log = HO.db.log
	HO.Print(string.format("debug log (%d entries, showing last %d):", #log, math.min(n, #log)))
	for i = math.max(1, #log - n + 1), #log do
		HO.PrintLine(log[i])
	end
end

-- full state snapshot into SavedVariables; visible after /reload or logout
HO.commands["dump"] = function()
	local dump = {
		at = date("%Y-%m-%d %H:%M:%S"),
		version = HO.VERSION,
		signature = HO.db.activeSignature,
		talentSummary = HO.Talents.SpecSummary(),
		ownSpec = HO.Planner.OwnSpec(),
		talentRanks = {},
		blessings = {},
		roster = {},
	}
	for id, rank in pairs(HO.Talents.ranks) do
		dump.talentRanks[id] = rank
	end
	for id, blessing in ipairs(HO.Data.blessings) do
		dump.blessings[id] = string.format(
			"%s known=%s rank=%s greater=%s grank=%s",
			blessing.key,
			tostring(blessing.known), tostring(blessing.rank),
			tostring(blessing.greaterKnown), tostring(blessing.greaterRank)
		)
	end
	for _, entry in ipairs(HO.Roster.units) do
		table.insert(dump.roster, string.format(
			"%s class=%s level=%s group=%s%s%s%s",
			entry.name or "?", entry.class or "?",
			tostring(entry.level), tostring(entry.subgroup),
			entry.isPet and (" pet-of=" .. (entry.owner or "?")) or "",
			entry.tankRole and " MAINTANK" or "",
			entry.online and "" or " offline"
		))
	end
	dump.traits = HO.Compat.DescribeTraits()
	HO.db.dump = dump
	HO.Log("dump", "state snapshot stored")
	HO.Print("state snapshot stored in SavedVariables — do /reload (or log out) so it is written to disk")
end

-- cast bar --------------------------------------------------------------------

HO.commands["bar"] = function(rest)
	local opts = HO.db.options.bar or {}
	HO.db.options.bar = opts
	local sub = rest:lower()
	if sub == "show" then
		opts.hidden = false
		HO.Bar.Refresh()
		HO.Print("bar shown (appears when you have duties)")
	elseif sub == "hide" then
		opts.hidden = true
		HO.Bar.Refresh()
		HO.Print("bar hidden")
	elseif sub == "reset" then
		HO.Bar.ResetPosition()
		HO.Print("bar position reset")
	elseif sub == "debug" then
		-- per-class button/fly-out/cycle state + what keeps a force rebuff alive
		for _, line in ipairs(HO.Bar.Debug()) do
			HO.PrintLine(line)
		end
	elseif sub:match("^grow") then
		local dir = sub:match("^grow%s+(%a+)$")
		if dir == "left" or dir == "right" or dir == "up" or dir == "down" then
			opts.grow = dir
			if InCombatLockdown() then
				HO.Print("bar grows " .. dir .. " (applies after combat)")
			else
				HO.Bar.Refresh()
				HO.Print("bar grows " .. dir)
			end
		else
			HO.Print("usage: /ho bar grow left|right|up|down")
		end
	elseif sub:match("^flyout") then
		local dir = sub:match("^flyout%s+(%a+)$")
		if dir == "left" or dir == "right" or dir == "up" or dir == "down" then
			opts.flyout = dir
			if InCombatLockdown() then
				HO.Print("fly-out opens " .. dir .. " (applies after combat)")
			else
				HO.Bar.Refresh()
				HO.Print("fly-out opens " .. dir)
			end
		else
			HO.Print("usage: /ho bar flyout left|right|up|down")
		end
	else
		HO.Print("usage: /ho bar show|hide|reset|debug|grow <dir>|flyout <dir>  (hold Ctrl and drag the handle to move)")
	end
end

-- UI skin: chrome is built at load, so switching prompts for a reload
HO.commands["skin"] = function(rest)
	local s = rest:match("^%s*(%S*)"):lower()
	local valid = false
	for _, name in ipairs(HO.Skin.SKINS) do
		if s == name then
			valid = true
			break
		end
	end
	if valid then
		HO.db.options.skin = s
		HO.Print("skin set to " .. s)
		HO.Options.PromptSkinReload()
	else
		-- the option is what will load next time; "active" is what THIS session
		-- resolved at startup — differing values mean a reload is still pending
		HO.Print("usage: /ho skin " .. table.concat(HO.Skin.SKINS, "|")
			.. " — option: " .. (HO.db.options.skin or "default")
			.. ", active now: " .. (HO.Skin.current or "?"))
	end
end

HO.commands["rebuff"] = function()
	HO.Bar.ToggleForceRebuff()
end

HO.commands["win"] = function()
	HO.Window.Toggle()
end

HO.commands["opt"] = function()
	HO.Options.Toggle()
end

-- announce missing blessings to the group (lead tool)
HO.commands["report"] = function()
	HO.Engine.Update()
	local lines = {}
	for classToken, task in pairs(HO.Engine.tasks) do
		if task.missing > 0 then
			table.insert(lines, classToken .. ": " .. task.missing)
		end
	end
	if #lines == 0 then
		HO.Print("no assigned blessings are missing")
		return
	end
	table.sort(lines)
	local msg = "HolyOrders — missing blessings: " .. table.concat(lines, ", ")
	local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY")
	if channel then
		SendChatMessage(msg, channel)
	else
		HO.Print(msg)
	end
end

-- sync ------------------------------------------------------------------------

HO.commands["sync"] = function()
	HO.Comm.SendHello()
	HO.Comm.RequestSync()
	HO.Print("sync requested from the group")
end

HO.commands["peers"] = function()
	local n = 0
	for name, peer in pairs(HO.Comm.peers) do
		n = n + 1
		HO.PrintLine(name .. " — v" .. tostring(peer.version) .. (peer.openEdit and " (open edit)" or ""))
	end
	-- clients heard on the wire but speaking another protocol version: sync with
	-- them is disabled, but silence here would look like they have no addon
	local bad = 0
	for name, proto in pairs(HO.Comm.protoMismatch) do
		bad = bad + 1
		HO.PrintLine(name .. " — INCOMPATIBLE (their protocol " .. tostring(proto)
			.. ", ours " .. HO.Comm.PROTO .. ") — no sync until "
			.. (tonumber(proto) and tonumber(HO.Comm.PROTO) and tonumber(proto) < tonumber(HO.Comm.PROTO)
				and "they update" or "you update"))
	end
	-- legacy blessing-addon clients seen on their wire (bridge must be enabled)
	local legacy = 0
	if HO.Interop and HO.Interop.LegacyClients then
		for _, c in ipairs(HO.Interop.LegacyClients()) do
			legacy = legacy + 1
			local fa
			if c.freeassign == true then
				fa = ", free assignment |cff40ff40ON|r"
			elseif c.freeassign == false then
				fa = ", free assignment |cffff4040OFF|r"
			else
				fa = ", free assignment unknown"
			end
			HO.PrintLine(c.name .. " — legacy blessing addon" .. (c.pally and "" or " (non-paladin)") .. fa)
		end
		if HO.Interop.Probe then
			HO.Interop.Probe() -- freshens the state for the next call, silently
		end
	end
	HO.Print(n .. " HolyOrders paladin(s) known"
		.. (bad > 0 and (", " .. bad .. " incompatible") or "")
		.. (legacy > 0 and (", " .. legacy .. " legacy") or "")
		.. (n == 0 and bad == 0 and legacy == 0 and " — none seen yet (are they in your group?)" or ""))
	if legacy == 0 and HO.Interop and not HO.Interop.IsEnabled() then
		HO.PrintLine("note: detecting legacy clients needs the legacy-broadcast option (Options > Group)")
	end
end

HO.commands["openedit"] = function()
	HO.db.options.openEdit = not HO.db.options.openEdit
	HO.Print("open edit " .. (HO.db.options.openEdit and "ENABLED — any HolyOrders paladin may edit your row" or "disabled"))
	HO.Comm.SendHello()
end

HO.commands["ping"] = function()
	HO.Comm.Ping()
end

HO.commands["trace"] = function()
	HO.db.options.trace = not HO.db.options.trace
	HO.Print("comm trace " .. (HO.db.options.trace and "ON — every sync message is logged (both directions)" or "off"))
end

HO.commands["getlog"] = function(rest)
	local target = rest:match("^(%S+)$")
	if not target then
		HO.Print("usage: /ho getlog <playerName> — pulls their recent HolyOrders log into your SavedVariables")
		return
	end
	local full = HO.Roster.Resolve(target)
	if not full then
		HO.Print("target is not in the roster")
		return
	end
	HO.Comm.RequestLog(full)
	HO.Print("log requested from " .. full)
end

-- encounter toggle: swap Salvation out, revert afterwards
-- who buffs which pet? Shows the deterministic split per pet, with each
-- paladin's addon version — an off-script client (older addon, or none) is
-- immediately identifiable, since every client computes its own pet duty.
HO.commands["pets"] = function()
	local found = false
	local mine = HO.FullName("player")
	for _, entry in ipairs(HO.Roster.units) do
		if entry.isPet then
			found = true
			local included = HO.Engine.PetIncluded(entry)
			HO.Print((entry.name or "?") .. " (pet of " .. (entry.owner or "?") .. ")"
				.. (included and "" or " — excluded by the pet options"))
			if included then
				local split = HO.Engine.PetSplit(entry)
				if #split == 0 then
					HO.PrintLine("nobody covers the owner's class — no pet buffs")
				end
				for _, duty in ipairs(split) do
					local ver
					if duty.pally == mine then
						ver = "you"
					else
						local peer = HO.Comm and HO.Comm.peers[duty.pally]
						ver = peer and ("v" .. tostring(peer.version)) or "no HolyOrders — follows its own rules"
					end
					HO.PrintLine(duty.pally .. " > " .. (duty.id and BlessingLabel(duty.id) or "no pet duty") .. " (" .. ver .. ")")
				end
			end
		end
	end
	if not found then
		HO.Print("no pets in the roster")
		return
	end
	HO.Print("note: the split needs every paladin on v0.27+ — older clients all cast the configured pet blessing")
end

-- pre-planning: /ho expect <name> toggles a paladin who has not joined yet;
-- their window column appears immediately and can be assigned like any other
HO.commands["expect"] = function(rest)
	local name = rest:match("^(%S+)$")
	if not name then
		local list = HO.Plan.Expected()
		if #list == 0 then
			HO.Print("no expected paladins — '/ho expect <name>' pre-plans one before they join")
		else
			HO.Print(#list .. " expected paladin(s): " .. table.concat(list, ", ") .. " — '/ho expect <name>' removes")
		end
		return
	end
	if name:lower() == "clear" then
		local n = #HO.Plan.Expected()
		HO.db.expected = {}
		HO.Print(n .. " expected paladin(s) cleared (their pre-planned rows are kept)")
		HO.Window.Refresh()
		return
	end
	name = name:gsub("^%l", string.upper)
	if not name:find("-", 1, true) then
		name = name .. "-" .. (GetNormalizedRealmName() or "")
	end
	if HO.Roster.byName[name] then
		HO.Print(name .. " is already in the group — assign them normally")
		return
	end
	if HO.Plan.ToggleExpected(name) then
		HO.Print(name .. " added as expected paladin — their grey column in the window is ready to assign")
	else
		HO.Print(name .. " removed from the expected list (their pre-planned row is kept)")
	end
	HO.Window.Refresh()
end

HO.commands["nosalv"] = function()
	local myself = HO.FullName("player")
	if IsInGroup() and HO.Comm and not HO.Comm.CanBulk(myself) then
		HO.Print("no-Salvation mode changes every paladin's assignments — lead or assist only")
		return
	end
	if HO.Plan.NoSalvationActive() then
		-- we hold the snapshot: restore and share plan + ended state
		HO.Plan.SetNoSalvation(false)
		HO.db.noSalvBy = nil
		HO.Print("Salvation restored — plan reverted to the pre-encounter state")
		HO.Comm.SendNoSalv(false)
	elseif HO.db.noSalvBy then
		-- active, but another paladin holds the snapshot: ask them to revert
		HO.db.noSalvBy = nil
		HO.Comm.SendNoSalv(false)
		HO.Print("revert requested from the paladin who enabled no-Salvation mode")
		HO.Window.Refresh()
		HO.Bar.Refresh()
		return
	else
		local ok, changed = HO.Plan.SetNoSalvation(true)
		if not ok then
			HO.Print("no-Salvation mode: " .. tostring(changed))
			return
		end
		HO.Print("no-Salvation mode ON: " .. changed .. " assignment(s) swapped — '/ho nosalv' reverts")
		HO.Comm.SendNoSalv(true)
	end
	if HO.Comm and HO.Comm.SendPlanApply() then
		HO.Print("plan broadcast to the group")
	end
	HO.Window.Refresh()
	HO.Bar.Refresh()
end

-- auto-planner ----------------------------------------------------------------

HO.commands["auto"] = function()
	local ok, msg = HO.Planner.Run()
	if ok then
		HO.Print("auto-plan: " .. msg)
		HO.Announce("'/ho plan show' for details, '/ho plan save [label]' to keep it")
	else
		HO.Print("auto-plan failed: " .. msg)
	end
end

HO.commands["spec"] = function(rest)
	local target, spec = rest:match("^(%S+)%s*(%S*)$")
	if not target then
		HO.Print("usage: /ho spec <playerName> [<spec>|clear] — tags a member's spec for the planner")
		return
	end
	local entry
	target, entry = HO.Roster.Resolve(target)
	if not entry then
		HO.Print("target is not in the roster")
		return
	end
	local valid = HO.Planner.ValidSpecs(entry.class)
	spec = (spec or ""):lower()
	if spec == "" then
		HO.Print(target .. " spec: " .. (HO.db.specCache[target] or "not set")
			.. (#valid > 0 and (" — valid: " .. table.concat(valid, ", ")) or ""))
	elseif spec == "clear" then
		HO.db.specCache[target] = nil
		if HO.db.specManual then
			HO.db.specManual[target] = nil -- back to auto-inference
		end
		HO.Print(target .. " spec tag cleared")
	else
		-- "other"/"dps" is a durable NOT-any-special-spec tag (e.g. a dps warrior),
		-- there to overrule a bad auto-inference like a false "protection"
		if spec == "dps" then
			spec = "other"
		end
		local ok = (spec == "other" and #valid > 0)
		for _, s in ipairs(valid) do
			if s == spec then
				ok = true
			end
		end
		if not ok then
			HO.Print("invalid spec for " .. entry.class
				.. (#valid > 0 and (" — valid: " .. table.concat(valid, ", ") .. ", other") or " (no spec rules for this class)"))
			return
		end
		HO.db.specCache[target] = spec
		HO.db.specManual = HO.db.specManual or {}
		HO.db.specManual[target] = true -- authoritative: never re-inspected/overwritten
		HO.Print(target .. " tagged as " .. spec)
		-- share the tag so every client computes the same tank set
		if HO.Comm then
			HO.Comm.SendSpecTag(target, spec)
		end
	end
end

HO.commands["tank"] = function(rest)
	local target = rest:match("^(%S+)$")
	if not target then
		HO.Print("usage: /ho tank <playerName>  (toggles the tank flag)")
		return
	end
	local entry
	target, entry = HO.Roster.Resolve(target)
	if not entry then
		HO.Print("target is not in the roster")
		return
	end
	if HO.Comm and not HO.Comm.CanFlagTank(target) then
		HO.Print("in a raid only lead/assist may flag others as tank")
		return
	end
	local isTank = HO.Plan.ToggleTank(target)
	HO.Print(target .. (isTank and " is now flagged as tank" or " is no longer flagged as tank"))
end

-- paladin aura ----------------------------------------------------------------

HO.commands["aura"] = function(rest)
	local me = HO.FullName("player")
	local arg = rest:match("^%s*(.-)%s*$") -- trim surrounding whitespace
	if arg == "" then
		local cur = HO.Plan.GetAura(me)
		HO.Print("your aura: " .. (cur and (HO.Data.AuraName(cur) or ("#" .. cur)) or "none"))
		local known = HO.Data.KnownAuras()
		if #known == 0 then
			HO.Print("no auras known")
			return
		end
		HO.Print("known auras (use number or name):")
		for _, id in ipairs(known) do
			HO.PrintLine(id .. ". " .. (HO.Data.AuraName(id) or ("#" .. id)))
		end
		return
	end
	local lower = arg:lower()
	if lower == "none" or lower == "0" or lower == "clear" then
		HO.Plan.SetAura(me, 0)
		HO.Print("aura cleared")
		return
	end
	-- resolve by number (= aura id) or case-insensitive name prefix, both against
	-- the auras this paladin actually knows
	local id
	local num = tonumber(arg)
	if num and HO.Data.auras[num] and HO.Data.auras[num].known then
		id = num
	else
		for _, kid in ipairs(HO.Data.KnownAuras()) do
			local name = HO.Data.AuraName(kid)
			if name and name:lower():sub(1, #lower) == lower then
				id = kid
				break
			end
		end
	end
	if not id then
		HO.Print("no known aura matches '" .. arg .. "' — '/ho aura' lists them")
		return
	end
	HO.Plan.SetAura(me, id)
	HO.Print("aura: " .. (HO.Data.AuraName(id) or ("#" .. id)))
end

-- buff request (available to everyone, non-paladins included) -----------------

HO.commands["request"] = function(rest)
	local arg = rest:match("^%s*(.-)%s*$") -- trim surrounding whitespace
	if arg == "" then
		HO.Request.Toggle()
		return
	end
	local lower = arg:lower()
	if lower == "clear" or lower == "none" or lower == "0" then
		HO.Comm.SendRequest(0)
		HO.Print("buff request cleared")
		return
	end
	-- resolve by number (= blessing id) or case-insensitive name prefix
	local id
	local num = tonumber(arg)
	if num and HO.Data.blessings[num] then
		id = num
	else
		for bid, blessing in ipairs(HO.Data.blessings) do
			local name = blessing.name or blessing.key
			if name and name:lower():sub(1, #lower) == lower then
				id = bid
				break
			end
		end
	end
	if not id then
		HO.Print("no blessing matches '" .. arg .. "' — use a name or 1-" .. HO.Data.NUM_BLESSINGS .. " (or 'clear')")
		return
	end
	-- append to the current priority list (the request window reorders/removes);
	-- already-requested blessings are left in place
	local list = {}
	local present = false
	if HO.db and HO.db.myRequests then
		for i, v in ipairs(HO.db.myRequests) do
			list[i] = v
			if v == id then
				present = true
			end
		end
	end
	if not present then
		list[#list + 1] = id
	end
	HO.Comm.SendRequest(list)
	HO.Print("requesting " .. BlessingLabel(id) .. " for yourself")
end

-- legacy blessing-addon bridge diagnostics: show status, the exact strings we
-- would emit, and force a broadcast now
HO.commands["interop"] = function()
	if not HO.Interop then
		HO.Print("interop bridge not loaded")
		return
	end
	local s = HO.Interop.Status()
	HO.Print("legacy broadcast: " .. (s.enabled and "|cff40ff40ON|r" or "|cffff4040OFF|r (enable it in Options)")
		.. " — paladin: " .. (s.paladin and "yes" or "no")
		.. " — channel: " .. (s.channel or "|cffff4040solo — nothing sends|r"))
	if s.selfMsg then
		HO.Print("would emit: " .. s.selfMsg)
	end
	for _, p in ipairs(s.pushes) do
		HO.Print("would push: " .. p)
	end
	for _, e in ipairs(s.overrides) do
		HO.Print("            NASSIGN " .. e)
	end
	if #s.pushes > 0 then
		HO.Print("note: legacy clients accept pushed rows only from the lead/assist, or with their free-assignment option on")
	end
	if HO.Interop.ForceBroadcast() then
		HO.Print("|cff40ff40re-broadcast sent to the group|r")
	else
		HO.Print("not sending — needs: option ON and you are in a group")
	end
	HO.Print("note: a legacy client on your OWN character ignores your own broadcasts — verify from a SECOND character running it")
end

-- help ------------------------------------------------------------------------

-- diagnostic/experimental commands, kept out of the default /ho help listing
local DEBUG = {
	spells = true, roster = true, dump = true, log = true, getlog = true,
	trace = true, ping = true, sync = true, peers = true, openedit = true,
	bar = true,
}

-- one very short line per command; player-facing and debug alike
local DESC = {
	-- player-facing
	auto = "compute blessing assignments",
	rebuff = "toggle pre-pull force rebuff",
	nosalv = "toggle no-Salvation encounter mode",
	expect = "pre-plan a paladin who has not joined yet",
	pets = "show who buffs which pet, with versions",
	plan = "manage stored roster plans",
	skin = "switch the UI skin",
	assign = "set a class blessing assignment",
	override = "set a per-player blessing override",
	prefs = "list or clear remembered member blessings",
	tank = "toggle a member's tank flag",
	request = "request a blessing for yourself (non-paladins too)",
	aura = "set or show your paladin aura",
	spec = "tag a member's spec for the planner",
	win = "toggle the assignment window",
	opt = "open the options panel",
	report = "announce missing blessings to the group",
	help = "show this help (/ho help debug for more)",
	-- debug
	spells = "list known blessings and ranks",
	roster = "dump the scanned roster",
	dump = "snapshot state into SavedVariables",
	log = "show or clear the debug log",
	getlog = "pull a member's log to you",
	trace = "toggle comm message logging",
	ping = "ping other HolyOrders paladins",
	sync = "request a sync from the group",
	peers = "list known HolyOrders paladins",
	openedit = "toggle letting others edit your row",
	bar = "control the cast bar (lock/show/grow)",
}

HO.commands["help"] = function(rest)
	local debug = (rest or ""):lower():match("^(%S*)") == "debug"
	local names = {}
	for name in pairs(HO.commands) do
		if (DEBUG[name] and true or false) == debug then
			table.insert(names, name)
		end
	end
	table.sort(names)
	HO.Print("v" .. HO.VERSION .. (debug and " — debug commands:" or " — commands:"))
	for _, name in ipairs(names) do
		HO.PrintLine("/ho " .. name .. (DESC[name] and (" — " .. DESC[name]) or ""))
	end
	if not debug then
		HO.PrintLine("debug commands: /ho help debug")
	end
end
