local H = ...
local barFixture = dofile("tests/bar-fixture.lua")
local function warriors()
	local f = H.fixture()
	f:add("Tank-Realm", "WARRIOR", "raid1")
	f:add("Damage-Realm", "WARRIOR", "raid2")
	f.HO.Plan.Active().tanks["Tank-Realm"] = true
	return f
end
H.test("flyout and combat cycle exclude tanks from class Salvation", function()
	local f = warriors()
	f.HO.Plan.SetClassAssignment("Me-Realm", "WARRIOR", 4, "normal")
	barFixture(H, f)
	local panel = f:panel("WARRIOR")
	assert(panel.rows[1].attrs.spell1 == nil, "tank flyout must not cast class Salvation")
	assert(panel.rows[2].attrs.spell1 == "SALVATION")
	local button = f:button("WARRIOR")
	assert(button.attrs.cycleCount == 1 and button.attrs.cycleName1 == "Damage-Realm")
	assert(button.attrs.spell2 == "SALVATION" and button.attrs.unit2 == "raid2")
	assert(f:click(button) == "/cast [@Damage-Realm,help,nodead] SALVATION")
end)
H.test("personal override never supplies the class greater spell", function()
	local f = warriors()
	f.HO.Plan.SetClassAssignment("Me-Realm", "WARRIOR", 2, "greater")
	f.HO.Plan.SetPlayerOverride("Me-Realm", "Tank-Realm", 3)
	f.buffs.raid2 = { name = "Greater MIGHT", expires = 1800 }
	f.HO.Engine.Update()
	assert(f.HO.Engine.tasks.WARRIOR.blessingID == 3 and f.HO.Engine.WouldUseGreater("WARRIOR"))
	barFixture(H, f)
	local b = f:button("WARRIOR")
	assert(
		b.attrs.spell2 == "MIGHT",
		"right-click must use the class assignment without erasing the override"
	)
	assert(b.attrs.unit2 == "raid2")
	assert(b.attrs.cycleSpell1 == "KINGS" and b.attrs.cycleSpell2 == "MIGHT")
	assert(f:click(b) == "/cast [@Tank-Realm,help,nodead] KINGS")
	assert(f:click(b) == "/cast [@Damage-Realm,help,nodead] MIGHT")
	f.HO.Bar.Refresh() -- combat refresh must not rewrite protected attributes
	f.combat = false
	f.buffs.raid2 = nil
	f.HO.Bar.Refresh()
	assert(b.attrs.macrotext1 == "/cast [@raid2,help,nodead] Greater MIGHT")
	assert(b.attrs.cycleSpell1 == "KINGS" and b.attrs.cycleSpell2 == "MIGHT")
end)
H.test("explicit tank override stays a single even when equal to the class", function()
	local f = warriors()
	f.HO.Plan.SetClassAssignment("Me-Realm", "WARRIOR", 4, "normal")
	f.HO.Plan.SetPlayerOverride("Me-Realm", "Tank-Realm", 4)
	barFixture(H, f)
	assert(f:panel("WARRIOR").rows[1].attrs.spell1 == "SALVATION")
	assert(f:button("WARRIOR").attrs.cycleSpell1 == "SALVATION")
end)
H.test("ordinary class duties retain greater casts and reagent fallback", function()
	local f = warriors()
	f.HO.Plan.SetClassAssignment("Me-Realm", "WARRIOR", 2, "auto")
	barFixture(H, f)
	local b = f:button("WARRIOR")
	assert(b.attrs.spell2 == "Greater MIGHT" and b.attrs.cycleSpell1 == "Greater MIGHT")
	f.symbols = 0
	f.HO.Bar.Refresh()
	assert(b.attrs.spell2 == "MIGHT" and b.attrs.cycleSpell1 == "MIGHT")
end)
H.test("override-only duties never become greater casts", function()
	local f = warriors()
	f.HO.Plan.SetPlayerOverride("Me-Realm", "Tank-Realm", 3)
	barFixture(H, f)
	local b = f:button("WARRIOR")
	assert(b.attrs.spell2 == "KINGS" and b.attrs.cycleCount == 1 and b.attrs.cycleSpell1 == "KINGS")
	f.HO.Plan.SetPlayerOverride("Me-Realm", "Tank-Realm", 0)
	f.HO.Bar.Refresh()
	assert(b.attrs.spell2 == nil and b.attrs.cycleCount == 0)
end)
for _, kings in ipairs({ "Alpha-Realm", "Zulu-Realm", "nobody" }) do
	H.test("pet split uses the Kings caster: " .. kings, function()
		local f = H.fixture(true)
		local HO = f.HO
		local hunter = f:add("Hunter-Realm", "HUNTER", "raid3")
		local pet = f:add("Pet", "WARRIOR", "pet")
		pet.isPet = true
		pet.owner = hunter.name
		for _, name in ipairs({ "Alpha-Realm", "Zulu-Realm" }) do
			f:add(name, "PALADIN", name)
			HO.Plan.SetClassAssignment(name, "HUNTER", 1)
			HO.Comm.peers[name] = { caps = { [2] = { known = true }, [3] = { known = name == kings } } }
		end
		local split = HO.Engine.PetSplit(pet)
		assert(#split == 2 and split[1].pally == "Alpha-Realm" and split[2].pally == "Zulu-Realm")
		local seen = {}
		for _, duty in ipairs(split) do
			if duty.id then
				assert(HO.Planner.IsAvailable(duty.pally, duty.id))
				assert(not seen[duty.id])
				seen[duty.id] = duty.pally
			end
		end
		assert(seen[2], "configured pet blessing should remain covered")
		if kings == "nobody" then
			assert(not seen[3])
		else
			assert(seen[3] == kings, "Kings must go to a capable caster")
		end
	end)
end
H.test("pet split preserves earlier duties when no full matching exists", function()
	local f = H.fixture(true)
	local owner = f:add("Hunter-Realm", "HUNTER", "raid1")
	local pet = f:add("Pet", "WARRIOR", "pet")
	pet.isPet = true
	pet.owner = owner.name
	f.HO.Plan.SetClassAssignment("Me-Realm", "HUNTER", 1)
	f.HO.Data.blessings[3].known = false
	local split = f.HO.Engine.PetSplit(pet)
	assert(#split == 1 and split[1].id == 2)
	f.HO.Engine.Update()
	assert(f.HO.Engine.tasks.HUNTER.blessingID == 1)
	f.buffs.raid1 = { name = "WISDOM", expires = 1800 }
	f.HO.Engine.Update()
	assert(f.HO.Engine.tasks.HUNTER.blessingID == 2)
	local actions = f.HO.Engine.ClassActions("HUNTER")
	assert(actions.cycle[2].target == "pet" and actions.cycle[2].spell == "MIGHT")
end)
