local H = ...
H.test("manual changes to auto overrides survive another Auto run", function()
	local f = H.fixture()
	f:add("Tank-Realm", "WARRIOR", "raid1")
	f:add("Damage-Realm", "WARRIOR", "raid2")
	local HO = f.HO
	local plan = HO.Plan.Active()
	plan.tanks["Tank-Realm"] = true
	assert(HO.Planner.Run())
	assert(plan.autoPlayer["Me-Realm"]["Tank-Realm"])
	HO.Plan.SetPlayerOverride("Me-Realm", "Tank-Realm", 5)
	assert(not plan.autoPlayer["Me-Realm"]["Tank-Realm"], "manual setter must remove automatic ownership")
	assert(HO.Planner.Run())
	assert(plan.player["Me-Realm"]["Tank-Realm"] == 5)
end)
H.test("manual overrides survive matching class assignments", function()
	local f = H.fixture()
	f:add("Mage-Realm", "MAGE", "raid1")
	f.HO.Plan.SetPlayerOverride("Me-Realm", "Mage-Realm", 4)
	assert(f.HO.Planner.Run())
	assert(f.HO.Plan.Active().player["Me-Realm"]["Mage-Realm"] == 4)
end)
H.test("unedited auto overrides are still replaced", function()
	local f = H.fixture()
	f:add("Tank-Realm", "WARRIOR", "raid1")
	f:add("Damage-Realm", "WARRIOR", "raid2")
	local plan = f.HO.Plan.Active()
	plan.tanks["Tank-Realm"] = true
	assert(f.HO.Planner.Run())
	assert(plan.autoPlayer["Me-Realm"]["Tank-Realm"])
	plan.tanks["Tank-Realm"] = false
	assert(f.HO.Planner.Run())
	assert(not plan.player["Me-Realm"]["Tank-Realm"])
end)
H.test("received spec tags affect the preference chain", function()
	local f = H.fixture(true)
	f:add("Peer-Realm", "PALADIN", "raid1")
	f:add("Shaman-Realm", "SHAMAN", "raid2")
	f:message("Peer-Realm", "ST:Shaman-Realm;enhancement")
	assert(
		f.HO.Planner.ResolvePreference("Shaman-Realm", "SHAMAN", false)[1] == 2,
		"received Enhancement tag must select Might"
	)
	f.HO.db.specCache["Shaman-Realm"] = "elemental"
	assert(f.HO.Planner.ResolvePreference("Shaman-Realm", "SHAMAN", false)[1] == 1)
	assert(f.HO.Planner.ResolvePreference("Shaman-Realm", "SHAMAN", true)[1] == 3)
end)
H.test("local inference takes precedence over synced own spec", function()
	local f = H.fixture(true)
	f.HO.Comm.specSync["Me-Realm"] = "holy"
	f.HO.Talents.tabPoints = { 0, 0, 40 }
	assert(f.HO.Planner.OwnSpec() == "retribution")
	assert(f.HO.Planner.ResolvePreference("Me-Realm", "PALADIN", false)[1] == 2)
	f.HO.Talents.tabPoints = { 0, 0, 0 }
	assert(f.HO.Planner.OwnSpec() == "holy")
	assert(f.HO.Planner.ResolvePreference("Me-Realm", "PALADIN", false)[1] == 1)
end)
local function arrival()
	local f = H.fixture(true)
	f.HO.Plan.SetClassAssignment("Arrival-Realm", "WARRIOR", 2, "greater")
	f.HO.Plan.ToggleExpected("Arrival-Realm")
	f:add("Arrival-Realm", "PALADIN", "raid3")
	f.rosterCallbacks[1]() -- actual Plan roster callback
	f:message("Arrival-Realm", "F:Arrival-Realm;1;W3a|M1a;")
	assert(f.HO.Plan.Active().class["Arrival-Realm"].WARRIOR.id == 3)
	return f
end
for _, delay in ipairs({ 2, 7 }) do
	H.test("arrival work preserves manual edits at second " .. delay, function()
		local f = arrival()
		f.clock:advance(delay)
		f.HO.Plan.SetClassAssignment("Arrival-Realm", "WARRIOR", 5, "normal")
		f.clock:advance(15)
		local row = f.HO.Plan.Active().class["Arrival-Realm"]
		assert(
			row.WARRIOR.id == 5 and row.WARRIOR.mode == "normal",
			"stale arrival callback overwrote an edit"
		)
	end)
end
H.test("arrival work still replaces stale greetings and retries once", function()
	local f = arrival()
	f.clock:advance(6)
	local row = f.HO.Plan.Active().class["Arrival-Realm"]
	assert(row.WARRIOR.id == 2 and row.MAGE == nil)
	f:message("Arrival-Realm", "F:Arrival-Realm;1;W3a;")
	f.clock:advance(12)
	assert(f.HO.Plan.Active().class["Arrival-Realm"].WARRIOR.id == 2)
	f:message("Arrival-Realm", "F:Arrival-Realm;1;W5a;")
	f.clock:advance(30)
	assert(f.HO.Plan.Active().class["Arrival-Realm"].WARRIOR.id == 5)
end)
H.test("received deliberate edits cancel arrival retries", function()
	local f = arrival()
	f.clock:advance(7)
	f:message("Arrival-Realm", "SC:Arrival-Realm;99;W;5;n")
	f.clock:advance(15)
	assert(f.HO.Plan.Active().class["Arrival-Realm"].WARRIOR.id == 5)
end)
H.test("arrival work cannot modify a replacement plan", function()
	local f = arrival()
	f.HO.db.activePlan = nil
	local replacement = f.HO.Plan.Active()
	replacement.class["Arrival-Realm"] = { WARRIOR = { id = 5, mode = "auto" } }
	f.clock:advance(15)
	assert(replacement.class["Arrival-Realm"].WARRIOR.id == 5)
end)
H.test("arrival work stops when the expected paladin leaves", function()
	local f = arrival()
	f.HO.Roster.byName["Arrival-Realm"] = nil
	f.rosterCallbacks[1]()
	f:add("Arrival-Realm", "PALADIN", "raid3")
	f.clock:advance(15)
	assert(f.HO.Plan.Active().class["Arrival-Realm"].WARRIOR.id == 3)
end)
H.test("explicit none and player override cancel pending arrival work", function()
	for _, edit in ipairs({ "none", "override" }) do
		local f = arrival()
		if edit == "none" then
			f.HO.Plan.SetClassNone("Arrival-Realm", "WARRIOR")
		else
			f.HO.Plan.SetPlayerOverride("Arrival-Realm", "Tank-Realm", 5)
		end
		f.clock:advance(15)
		local row = f.HO.Plan.Active().class["Arrival-Realm"]
		if edit == "none" then
			assert(row.WARRIOR.none)
		else
			assert(row.WARRIOR.id == 3)
		end
	end
end)
