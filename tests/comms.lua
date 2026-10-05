local H = ...
local function receiver()
	local f = H.fixture(true)
	f:add("Lead-Realm", "PALADIN", "raid1", 2)
	f:add("Holder-Realm", "PALADIN", "raid2", 0)
	f:add("Tank-Realm", "WARRIOR", "raid3")
	local plan = f.HO.Plan.Active()
	plan.class["Holder-Realm"] = { WARRIOR = { id = 2, mode = "normal" } }
	plan.player["Holder-Realm"] = { ["Tank-Realm"] = 3 }
	plan.tanks["Tank-Realm"] = true
	plan.meta.dirty = true
	plan.rev = { ["Holder-Realm"] = 10 }
	f.original = plan.class["Holder-Realm"]
	return f
end
local function unchanged(f)
	local plan = f.HO.Plan.Active()
	assert(plan.class["Holder-Realm"] == f.original, "incomplete snapshot changed the row")
	assert(plan.player["Holder-Realm"]["Tank-Realm"] == 3)
	assert(plan.tanks["Tank-Realm"] and plan.meta.dirty and plan.rev["Holder-Realm"] == 10)
	assert(#f.announcements == 0, "incomplete snapshot was announced as received")
end
H.test("incomplete snapshot leaves the whole active plan intact", function()
	local f = receiver()
	f:message("Lead-Realm", "PS:2;1")
	f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;")
	f:message("Lead-Realm", "PE:2;1")
	unchanged(f)
end)
for _, snapshotRev in ipairs({ 11, 12 }) do
	H.test("snapshot revision " .. snapshotRev .. " preserves edits received during transfer", function()
		local f = receiver()
		local plan = f.HO.Plan.Active()
		plan.class["Lead-Realm"] = { MAGE = { id = 1, mode = "auto" } }
		local leadRow = plan.class["Lead-Realm"]
		f:message("Lead-Realm", "PS:2;0")
		f:message("Lead-Realm", "PR:Lead-Realm;1;;")
		f:message("Lead-Realm", "PR:Holder-Realm;" .. snapshotRev .. ";W4n;")
		f:message("Holder-Realm", "SC:Holder-Realm;12;W;2;n")
		f:message("Lead-Realm", "PE:2;0")
		assert(plan.class["Holder-Realm"].WARRIOR.id == 2 and plan.rev["Holder-Realm"] == 12)
		assert(plan.class["Lead-Realm"] == leadRow, "a conflicting snapshot must not partly apply")
		assert(plan.tanks["Tank-Realm"] and plan.meta.dirty)
		assert(#f.announcements == 0)
		assert(f.sent[#f.sent].message == "4:R:", "request authoritative rows after a conflict")
	end)
end
H.test("snapshot already older at the start is rejected", function()
	local f = receiver()
	f:message("Lead-Realm", "PS:1;0")
	f:message("Lead-Realm", "PR:Holder-Realm;9;W4n;")
	f:message("Lead-Realm", "PE:1;0")
	unchanged(f)
end)
H.test("missing tank messages reject an otherwise complete snapshot", function()
	local f = receiver()
	f:message("Lead-Realm", "PS:1;1")
	f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;")
	f:message("Lead-Realm", "PE:1;1")
	unchanged(f)
end)
H.test("malformed and duplicate rows reject the entire snapshot", function()
	local invalid = {
		"Holder-Realm;11;W4n|broken;",
		"Holder-Realm;11;W4z;",
		"Holder-Realm;11;W4n|W2a;",
		"Holder-Realm;11;W4n;Tank-Realm=3|broken",
		"Holder-Realm;bad;W4n;",
		"Holder-Realm;11;W4n;Tank-Realm=3|Tank-Realm=5",
		"Holder-Realm;11;W4n;",
	}
	for _, row in ipairs(invalid) do
		local f = receiver()
		f:message("Lead-Realm", "PS:2;0")
		f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;")
		f:message("Lead-Realm", "PR:" .. row)
		f:message("Lead-Realm", "PE:2;0")
		unchanged(f)
	end
end)
H.test("mismatched totals duplicate tank marks and expired streams are rejected", function()
	for _, kind in ipairs({ "count", "duplicate tank", "expired", "legacy" }) do
		local f = receiver()
		f:message("Lead-Realm", kind == "legacy" and "PS:1" or "PS:1;1")
		f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;")
		f:message("Lead-Realm", "PT:Tank-Realm")
		if kind == "duplicate tank" then
			f:message("Lead-Realm", "PT:!Tank-Realm")
		end
		if kind == "expired" then
			f.clock:advance(11)
		end
		f:message("Lead-Realm", kind == "legacy" and "PE:1" or kind == "count" and "PE:2;1" or "PE:1;1")
		unchanged(f)
	end
end)
H.test("complete snapshots apply rows clears and tank suppressions together", function()
	local f = receiver()
	f.HO.Plan.Active().class["Lead-Realm"] = { MAGE = { id = 1, mode = "auto" } }
	f:message("Lead-Realm", "PS:2;1")
	f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;Tank-Realm=5")
	f:message("Lead-Realm", "PR:Lead-Realm;1;;")
	assert(f.HO.Plan.Active().class["Holder-Realm"] == f.original)
	f:message("Lead-Realm", "PT:!Tank-Realm")
	f:message("Lead-Realm", "PE:2;1")
	local plan = f.HO.Plan.Active()
	assert(plan.class["Holder-Realm"].WARRIOR.id == 4 and next(plan.class["Lead-Realm"]) == nil)
	assert(plan.player["Holder-Realm"]["Tank-Realm"] == 5 and plan.tanks["Tank-Realm"] == false)
	assert(plan.meta.dirty == false and #f.announcements == 1)
end)
H.test("demoted holder can complete a sanctioned No-Salvation restore", function()
	local f = receiver()
	f.HO.db.noSalvBy = "Holder-Realm"
	f:message("Lead-Realm", "NS:0")
	f:message("Holder-Realm", "PS:1;0")
	f:message("Holder-Realm", "PR:Holder-Realm;11;W4n;")
	f:message("Holder-Realm", "PE:1;0")
	assert(f.HO.Plan.Active().class["Holder-Realm"].WARRIOR.id == 4, "demoted holder restore was rejected")
	f:message("Holder-Realm", "PS:1;0")
	f:message("Holder-Realm", "PR:Holder-Realm;12;W5a;")
	f:message("Holder-Realm", "PE:1;0")
	assert(f.HO.Plan.Active().class["Holder-Realm"].WARRIOR.id == 4, "restore permission must be single-use")
end)
H.test("restore permission excludes other senders and expires", function()
	local f = receiver()
	f:add("Other-Realm", "PALADIN", "raid4", 0)
	f.HO.db.noSalvBy = "Holder-Realm"
	f:message("Lead-Realm", "NS:0")
	f.announcements = {}
	for _, sender in ipairs({ "Other-Realm", "Holder-Realm" }) do
		if sender == "Holder-Realm" then
			f.clock:advance(11)
		end
		f:message(sender, "PS:1;0")
		f:message(sender, "PR:Holder-Realm;11;W4n;")
		f:message(sender, "PE:1;0")
		unchanged(f)
	end
end)
H.test("demotion during an ordinary snapshot rejects it", function()
	local f = receiver()
	f:message("Lead-Realm", "PS:1;0")
	f:message("Lead-Realm", "PR:Holder-Realm;11;W4n;")
	f.HO.Roster.byName["Lead-Realm"].rank = 0
	f:message("Lead-Realm", "PE:1;0")
	unchanged(f)
end)
H.test("received manual overrides cease to be auto owned", function()
	local f = receiver()
	local plan = f.HO.Plan.Active()
	plan.autoPlayer = { ["Holder-Realm"] = { ["Tank-Realm"] = true } }
	f:message("Lead-Realm", "SP:Holder-Realm;11;Tank-Realm;5")
	assert(plan.player["Holder-Realm"]["Tank-Realm"] == 5)
	assert(not plan.autoPlayer["Holder-Realm"]["Tank-Realm"])
end)
H.test("sender totals and fragmented rows round trip through the wire", function()
	local sender = H.fixture(true)
	local HO = sender.HO
	sender:add("Tank-Realm", "WARRIOR", "raid1")
	local plan = HO.Plan.Active()
	plan.class["Me-Realm"] = { WARRIOR = { id = 4, mode = "normal" } }
	plan.player["Me-Realm"] = {}
	for i = 1, 35 do
		plan.player["Me-Realm"]["LongPlayerName" .. i .. "-Realm"] = 3
	end
	plan.tanks["Tank-Realm"] = false
	assert(HO.Comm.SendPlanApply())
	sender.clock:advance(10)
	local packets = sender.sent
	assert(packets[1].message == "4:PS:1;1")
	assert(packets[#packets].message:match("^4:PE:1;1;%d+$"))
	local f = H.fixture(true)
	f.HO.FullName = function()
		return "Receiver-Realm"
	end
	f:event("PLAYER_LOGIN") -- receiving identity differs from snapshot owner
	f:add("Tank-Realm", "WARRIOR", "raid1")
	for _, packet in ipairs(packets) do
		f:event("CHAT_MSG_ADDON", packet.prefix, packet.message, packet.channel, "Me-Realm")
	end
	local received = f.HO.Plan.Active()
	assert(received.class["Me-Realm"].WARRIOR.id == 4)
	assert(received.player["Me-Realm"]["LongPlayerName35-Realm"] == 3)
	assert(received.tanks["Tank-Realm"] == false)
end)

H.test("checksum rejects a parseable row damaged in transit", function()
	local f = receiver()
	local original = "Holder-Realm;11;W4n;Tank-Realm=5|Other-Realm=3"
	local damaged = "Holder-Realm;11;W4n;Tank-Realm=5"
	f:message("Lead-Realm", "PS:1;0")
	f:message("Lead-Realm", "PR:" .. damaged)
	f:message("Lead-Realm", "PE:1;0;" .. H.checksum({ original }, {}))
	unchanged(f)
end)

H.test("demoted snapshot holder restores and sends the original plan", function()
	local sender = H.fixture(true)
	sender:add("Lead-Realm", "PALADIN", "raid1", 2)
	sender:add("Tank-Realm", "WARRIOR", "raid2")
	sender.HO.Plan.SetClassAssignment("Me-Realm", "WARRIOR", 4, "normal")
	sender.clock:advance(1)
	sender.sent = {}
	assert(sender.HO.Plan.SetNoSalvation(true))
	assert(sender.HO.Plan.Active().class["Me-Realm"].WARRIOR.id ~= 4)
	sender.HO.Roster.byName["Me-Realm"].rank = 0
	sender:message("Lead-Realm", "NS:0")
	assert(not sender.HO.Plan.NoSalvationActive())
	sender.clock:advance(5)
	local packets = sender.sent
	assert(packets[1].message:match("^4:PS:"), "demoted holder must send its restored snapshot")
	local f = H.fixture(true)
	f.HO.FullName = function()
		return "Receiver-Realm"
	end
	f:event("PLAYER_LOGIN")
	f.HO.Roster.byName["Me-Realm"].rank = 0
	f:add("Lead-Realm", "PALADIN", "raid1", 2)
	f.HO.db.noSalvBy = "Me-Realm"
	f:message("Lead-Realm", "NS:0")
	for _, packet in ipairs(packets) do
		f:event("CHAT_MSG_ADDON", packet.prefix, packet.message, packet.channel, "Me-Realm")
	end
	assert(f.HO.Plan.Active().class["Me-Realm"].WARRIOR.id == 4)
end)
