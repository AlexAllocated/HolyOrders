-- HolyOrders — sync protocol (SPEC-sync)
-- Revision-numbered per-paladin rows, capture-at-send debounced SETs,
-- explicit clears, atomic plan application, symmetric permissions.
-- No state is ever wiped on join/leave; convergence is by revision only.

local HO = HolyOrders
local Comm = {}
HO.Comm = Comm

local PREFIX = "HolyOrders"
-- v4: PLANAPPLY is an authoritative snapshot (tank list in its own PT messages,
-- atomic PE apply), spec-tag overlay sync (ST). Breaking wire change from v3.
local PROTO = "4"
Comm.PROTO = PROTO
local SET_DELAY = 1.0
local HELLO_DELAY = 2.0
local CAPS_SETTLE = 2.0 -- seconds to batch spellbook/talent updates before re-announcing
local MAX_MSG = 250 -- WoW addon messages cap at 255 bytes
local MAX_FRAGMENTS = 10 -- messages needing more chunks than this are dropped, not sent

-- compact wire encoding: class tokens and modes as single characters so a
-- full row stays far below the message size cap
local CLASS_CODE = { WARRIOR = "W", PALADIN = "P", HUNTER = "H", ROGUE = "R", PRIEST = "I", SHAMAN = "S", MAGE = "M", WARLOCK = "L", DRUID = "D" }
local CODE_CLASS = {}
for token, code in pairs(CLASS_CODE) do
	CODE_CLASS[code] = token
end
local MODE_CODE = { auto = "a", greater = "g", normal = "n" }
local CODE_MODE = { a = "auto", g = "greater", n = "normal" }

Comm.peers = {} -- [fullName] = { version, openEdit, caps = {[id]={known,greater,talent}}, greeted }
Comm.suspended = false -- true while the planner bulk-edits (PLANAPPLY follows)
Comm.specSync = {} -- [fullName] = spec tag, synced overlay (session only, not saved)
Comm.requests = {} -- [fullName] = { blessingID, ... } ordered priority list; own reflected too; never saved

local me -- own full name, set on login
-- incoming PLANAPPLY buffers, one per sender ({ rows={}, tanks={} }, applied
-- atomically at PE): two leads broadcasting at once must not clobber each other
local planBuffers = {}
local SYNC_SETTLE = 4 -- seconds after a pull during which replies still land
local PLAN_STREAM_TIMEOUT = 10 -- an abandoned snapshot stream stops counting as active
local syncSettleUntil = 0

local UPDATE_URL = "https://www.curseforge.com/wow/addons/holyorders"

-- "X.Y.Z" to a comparable number; nil for anything malformed
local function ParseVersion(v)
	if type(v) ~= "string" then
		return nil
	end
	local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
	if not a then
		return nil
	end
	return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

local function IsPaladin()
	return select(2, UnitClass("player")) == "PALADIN"
end

-- transport -------------------------------------------------------------------

local function Channel()
	if IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
	return nil
end

-- low-level rate limiter: classic clients silently drop addon-message bursts,
-- so a token bucket paces us and a FIFO queue (drained by a ticker) preserves
-- order once anything is queued
local BURST = 8 -- bucket capacity
local REFILL = 4 -- tokens per second
local tokens = BURST
local lastRefill = nil
local sendQueue = {} -- FIFO of { wire, channel, target, msgType }
local drainTicker = nil

local function ChannelAlive(channel, target)
	if channel == "WHISPER" then
		return target ~= nil
	elseif channel == "RAID" then
		return IsInRaid()
	elseif channel == "PARTY" then
		return IsInGroup()
	end
	return true
end

local function Refill()
	local now = GetTime()
	if not lastRefill then
		lastRefill = now
		return
	end
	local elapsed = now - lastRefill
	if elapsed > 0 then
		tokens = math.min(BURST, tokens + elapsed * REFILL)
		lastRefill = now
	end
end

local function DrainTick()
	Refill()
	-- comms locked (restricted content): hold the queue, the ticker retries
	if HO.Compat.AddonCommsLocked() then
		return
	end
	while sendQueue[1] and tokens >= 1 do
		local item = table.remove(sendQueue, 1)
		if ChannelAlive(item.channel, item.target) then
			tokens = tokens - 1
			C_ChatInfo.SendAddonMessage(PREFIX, item.wire, item.channel, item.target)
		else
			HO.Log("comm", "dropped queued " .. tostring(item.msgType) .. " (channel gone)")
		end
	end
	if not sendQueue[1] and drainTicker then
		drainTicker:Cancel()
		drainTicker = nil
	end
end

local function Throttle(wire, channel, target, msgType)
	-- once anything is queued everything queues behind it, so order never breaks
	if #sendQueue == 0 and not HO.Compat.AddonCommsLocked() then
		Refill()
		if tokens >= 1 then
			if ChannelAlive(channel, target) then
				tokens = tokens - 1
				C_ChatInfo.SendAddonMessage(PREFIX, wire, channel, target)
			end
			return
		end
	end
	sendQueue[#sendQueue + 1] = { wire = wire, channel = channel, target = target, msgType = msgType }
	if not drainTicker then
		drainTicker = C_Timer.NewTicker(1 / REFILL, DrainTick)
	end
end

-- drop still-queued outgoing messages of a type (used when a snapshot
-- supersedes pre-snapshot single-message edits)
local function CancelQueued(msgType)
	local i = 1
	while sendQueue[i] do
		if sendQueue[i].msgType == msgType then
			table.remove(sendQueue, i)
		else
			i = i + 1
		end
	end
end

-- transparent fragmentation: a message whose wire would exceed MAX_MSG is split
-- into "PROTO:FG:k:<chunk>" fragments (k = B first, C middle, E last), enqueued
-- back-to-back so both WoW and our FIFO preserve their order; the receiver
-- reassembles and dispatches the original TYPE:payload. Nothing legitimate needs
-- more than MAX_FRAGMENTS chunks, so anything larger is logged and dropped.
local function Send(msg, channel, target)
	channel = channel or Channel()
	if not channel then
		return
	end
	if HO.db and HO.db.options.trace then
		HO.Log("tx", channel .. (target and ("/" .. target) or "") .. " " .. msg:sub(1, 120))
	end
	local wire = PROTO .. ":" .. msg
	if #wire <= MAX_MSG then
		Throttle(wire, channel, target, msg:match("^(%u+)"))
		return
	end
	local maxChunk = MAX_MSG - (#PROTO + 6) -- room left after the "PROTO:FG:k:" header
	local total = math.ceil(#msg / maxChunk)
	if total > MAX_FRAGMENTS then
		HO.Log("comm", "message too large to fragment (" .. #wire .. "b) dropped: " .. wire:sub(1, 60))
		return
	end
	local pos = 1
	local first = true
	while pos <= #msg do
		local chunk = msg:sub(pos, pos + maxChunk - 1)
		pos = pos + maxChunk
		local k
		if first then
			k = "B"
			first = false
		elseif pos > #msg then
			k = "E"
		else
			k = "C"
		end
		Throttle(PROTO .. ":FG:" .. k .. ":" .. chunk, channel, target, "FG")
	end
end

-- debounced sends: one pending timer per key, payload captured at queue time
local sendTimers = {}
local function QueueSend(key, msg)
	if sendTimers[key] then
		sendTimers[key]:Cancel()
	end
	sendTimers[key] = C_Timer.NewTimer(SET_DELAY, function()
		sendTimers[key] = nil
		Send(msg)
	end)
end

-- permissions (one shared rule for sender and receiver) -----------------------

function Comm.CanEdit(editor, owner)
	if editor == owner then
		return true
	end
	-- outside a raid (solo and 5-man parties) everyone may edit every row:
	-- a party has no assist rank, and coordination among five people must
	-- not hang on the lead or on per-owner consent flags. Raids keep the
	-- strict rules below.
	if not IsInRaid() then
		return true
	end
	local entry = HO.Roster.byName[editor]
	if entry and (entry.rank or 0) > 0 then
		return true -- raid leader or assist
	end
	if owner == me then
		return HO.db.options.openEdit or false
	end
	local peer = Comm.peers[owner]
	if not peer then
		-- the owner runs no HolyOrders (legacy blessing addon, or none at
		-- all): there is no consent flag to honor and no client of ours to
		-- convince. Their row is a local plan plus, at most, a legacy push —
		-- and the LEGACY client enforces its own acceptance rule (lead/assist
		-- or its free-assignment option), so gating here protects nothing
		-- and only blocks the coordinator scenario.
		return true
	end
	-- honor a peer's openEdit only while that peer is still in the group roster
	-- (a leaver's stale permission must not survive)
	return (peer.openEdit and HO.Roster.byName[owner] and true) or false
end

function Comm.CanBulk(editor)
	local entry = HO.Roster.byName[editor]
	return (entry and (entry.rank or 0) > 0) or not IsInGroup()
end

-- sender-side mirror of the receiver's TANK gate: outside a raid (solo and
-- 5-man parties) everyone may fix tank marks — there is no assist rank in a
-- party and a wrong mark must not require the lead. In raids: self or
-- lead/assist.
function Comm.CanFlagTank(name)
	if not IsInRaid() then
		return true
	end
	if name == me then
		return true
	end
	local myEntry = HO.Roster.byName[me]
	return (myEntry and (myEntry.rank or 0) > 0) or false
end

-- revisions -------------------------------------------------------------------

local function Revs(plan)
	plan.rev = plan.rev or {}
	return plan.rev
end

-- a revision off the wire must be a finite, non-negative integer below 1e9;
-- anything else (nan/inf/float/garbage) is rejected so it can never poison the
-- monotonic rev comparisons
local function ValidRev(x)
	x = tonumber(x)
	if not x then
		return nil
	end
	if x ~= x or x < 0 or x >= 1e9 or math.floor(x) ~= x then
		return nil
	end
	return x
end

local function BumpRev(owner)
	local revs = Revs(HO.Plan.Active())
	revs[owner] = (revs[owner] or 0) + 1
	return revs[owner]
end

-- serialization ---------------------------------------------------------------

local function Caps()
	local parts = {}
	for id, blessing in ipairs(HO.Data.blessings) do
		parts[id] = (blessing.known and "1" or "0")
			.. (blessing.greaterKnown and "1" or "0")
			.. tostring(math.min(HO.Talents.ranks[id] or 0, 9))
			.. string.format("%02d", math.min(blessing.rankNum or 0, 99))
	end
	return table.concat(parts, ",")
end

local function SerializeRow(owner)
	local plan = HO.Plan.Active()
	local classParts = {}
	for classToken, a in pairs(plan.class[owner] or {}) do
		local code = CLASS_CODE[classToken]
		-- an explicit-none marker (no numeric id) is local-only: skip it so the
		-- wire shows the class as unassigned (identical semantics for peers)
		if code and a.id then
			table.insert(classParts, code .. a.id .. (MODE_CODE[a.mode] or "a"))
		end
	end
	table.sort(classParts)
	local ovParts = {}
	for target, id in pairs(plan.player[owner] or {}) do
		table.insert(ovParts, target .. "=" .. id)
	end
	table.sort(ovParts)
	return owner .. ";" .. (Revs(plan)[owner] or 0) .. ";"
		.. table.concat(classParts, "|") .. ";" .. table.concat(ovParts, "|")
end

-- applies a serialized row if permitted and newer; direct table writes only
-- (never through Plan.Set*, which would echo back into Comm).
-- force = true is used by the PLANAPPLY snapshot: bulk permission is already
-- checked, so every row is adopted unconditionally (rev too, even if lower).
local function ApplyRow(payload, sender, force)
	local owner, revStr, classCsv, ovCsv = strsplit(";", payload)
	if not owner then
		return
	end
	local rev = ValidRev(revStr)
	if not rev then
		HO.Log("comm", "dropped row for " .. tostring(owner) .. " from " .. sender .. ": invalid rev " .. tostring(revStr))
		return
	end
	if not force and not Comm.CanEdit(sender, owner) then
		HO.Log("comm", "rejected row for " .. owner .. " from " .. sender)
		return
	end
	local plan = HO.Plan.Active()
	local localRev = Revs(plan)[owner] or 0
	if not force then
		-- the owner is authoritative for their own row: accept it unconditionally
		-- and adopt its rev as sent (heals an editor who forked a foreign row via
		-- a lost send). Everyone else needs a strictly newer revision.
		if sender ~= owner and rev <= localRev then
			return
		end
	end
	local class = {}
	if classCsv and classCsv ~= "" then
		for pair in string.gmatch(classCsv, "[^|]+") do
			local code, id, modeCode = pair:match("^(%u)(%d)(%a)$")
			local token = code and CODE_CLASS[code]
			if token and HO.Data.blessings[tonumber(id)] then
				class[token] = { id = tonumber(id), mode = CODE_MODE[modeCode] or "auto" }
			end
		end
	end
	local player = {}
	if ovCsv and ovCsv ~= "" then
		for pair in string.gmatch(ovCsv, "[^|]+") do
			local target, id = pair:match("^(.+)=(%d+)$")
			if target and HO.Data.blessings[tonumber(id)] then
				player[target] = tonumber(id)
			end
		end
	end
	plan.class[owner] = class
	plan.player[owner] = player
	Revs(plan)[owner] = rev
	return true
end

-- outgoing --------------------------------------------------------------------

-- capabilities last announced to the whole group (nil: never)
local lastGroupCaps

function Comm.SendHello(channel, target)
	local caps = Caps()
	if not channel then
		lastGroupCaps = caps
	end
	Send("H:" .. HO.VERSION .. ";" .. (HO.db.options.openEdit and "1" or "0") .. ";" .. caps, channel, target)
end

-- learning a blessing, a new rank or a talent changes what I can cast; the
-- other paladins' planners must see it, not only after the next roster change.
-- Batched (spellbook events come in bursts) and sent only when the
-- capabilities really differ from the last group announcement.
local capsTimer
local function ScheduleCapsAnnounce()
	if capsTimer then
		return
	end
	capsTimer = C_Timer.NewTimer(CAPS_SETTLE, function()
		capsTimer = nil
		if IsPaladin() and Channel() and lastGroupCaps and Caps() ~= lastGroupCaps then
			Comm.SendHello()
		end
	end)
end

HO.RegisterEvent("SPELLS_CHANGED", ScheduleCapsAnnounce)
for _, event in ipairs(HO.Compat.TALENT_EVENTS) do
	HO.RegisterEvent(event, ScheduleCapsAnnounce)
end

function Comm.SendFull(target)
	Send("F:" .. SerializeRow(me), target and "WHISPER" or nil, target)
end

-- bump and broadcast only the player's own row (always permitted).
-- non-paladin clients hold no blessing row and never announce one.
function Comm.BroadcastOwnRow()
	if not me or not IsPaladin() then
		return
	end
	BumpRev(me)
	Comm.SendFull()
end

-- spec-tag overlay: share a member's tag so every client computes the same
-- tank set (divergent local inspect results otherwise split the Salvation plan)
function Comm.SendSpecTag(name, tag)
	if not me or not name or not tag or tag == "" then
		return
	end
	Send("ST:" .. name .. ";" .. tag)
end

-- piggybacked onto a greet: only "protection" tags matter for correctness,
-- so a new peer learns exactly the tank-relevant tags we hold
function Comm.SendKnownSpecTags(channel, target)
	if not me or not HO.db then
		return
	end
	for name, tag in pairs(HO.db.specCache) do
		if tag == "protection" then
			Send("ST:" .. name .. ";" .. tag, channel, target)
		end
	end
end

-- called by Plan.Set* after every local edit (unless suspended for a bulk op)
function Comm.OnClassEdited(owner, classToken)
	if Comm.suspended or not me then
		return
	end
	local plan = HO.Plan.Active()
	local rev = BumpRev(owner)
	local a = plan.class[owner] and plan.class[owner][classToken]
	local msg = "SC:" .. owner .. ";" .. rev .. ";" .. (CLASS_CODE[classToken] or "?") .. ";"
		.. (a and a.id or 0) .. ";" .. (a and MODE_CODE[a.mode] or "a")
	QueueSend("SC:" .. owner .. ":" .. classToken, msg)
end

function Comm.OnOverrideEdited(owner, target)
	if Comm.suspended or not me then
		return
	end
	local plan = HO.Plan.Active()
	local rev = BumpRev(owner)
	local id = plan.player[owner] and plan.player[owner][target] or 0
	QueueSend("SP:" .. owner .. ":" .. target, "SP:" .. owner .. ";" .. rev .. ";" .. target .. ";" .. id)
end

function Comm.OnTankToggled(name, flagged)
	if Comm.suspended or not me then
		return
	end
	-- send immediately: tank clicks are rare, and a debounce window is exactly
	-- what let a racing PLANAPPLY reverse the click
	Send("T:" .. name .. ";" .. (flagged and "1" or "0"))
end

-- aura assignments are low-churn and last-writer-wins (like ST/MP), so they
-- carry no revision: send immediately AU:<paladin>;<auraID or 0>.
function Comm.OnAuraEdited(paladin)
	if Comm.suspended or not me or not paladin then
		return
	end
	local plan = HO.Plan.Active()
	local id = plan.aura and plan.aura[paladin] or 0
	Send("AU:" .. paladin .. ";" .. (id or 0))
end

-- emit a list of pre-encoded entries as one or more TYPE messages, each kept
-- under the size cap by splitting only on entry ("|") boundaries
local function SendEntryChunks(msgType, entries, channel, target)
	local budget = MAX_MSG - #PROTO - #(":" .. msgType .. ":") -- payload bytes left after the header
	local chunk, len = {}, 0
	local function flush()
		if #chunk > 0 then
			Send(msgType .. ":" .. table.concat(chunk, "|"), channel, target)
			chunk, len = {}, 0
		end
	end
	for _, entry in ipairs(entries) do
		local add = (#chunk > 0 and 1 or 0) + #entry -- separator + entry
		if #chunk > 0 and len + add > budget then
			flush()
			add = #entry
		end
		chunk[#chunk + 1] = entry
		len = len + add
	end
	flush()
end

-- emit the tank name list as one or more PT messages
local function SendTankChunks(names)
	SendEntryChunks("PT", names)
end

-- immediate broadcast of a member-liking change (rare event, no debounce):
-- MP:<name>;<id> where id 0 means "forget". Direct write on receipt (below).
function Comm.OnMemberPrefChanged(name, id)
	if Comm.suspended or not me or not name then
		return
	end
	Send("MP:" .. name .. ";" .. (id or 0))
end

-- piggybacked onto a greet: share every remembered member liking in one or more
-- MB batches (each entry "name=id", split on entry boundaries under the cap).
-- Adds/updates only — deletions travel via explicit MP:name;0.
function Comm.SendKnownMemberPrefs(channel, target)
	if not me or not HO.db or not HO.db.memberPrefs then
		return
	end
	local entries = {}
	for name, id in pairs(HO.db.memberPrefs) do
		if id and id ~= 0 then
			table.insert(entries, name .. "=" .. id)
		end
	end
	if #entries == 0 then
		return
	end
	table.sort(entries)
	SendEntryChunks("MB", entries, channel, target)
end

-- piggybacked onto a greet: share every non-zero aura assignment in one or more
-- AB batches (each entry "pally=id", split on entry boundaries under the cap).
function Comm.SendKnownAuras(channel, target)
	if not me then
		return
	end
	local plan = HO.Plan.Active()
	if not plan.aura then
		return
	end
	local entries = {}
	for pally, id in pairs(plan.aura) do
		-- roster members only: the plan persists across sessions, and a
		-- long-gone paladin's aura must not be resurrected into the group
		if id and id ~= 0 and HO.Roster.byName[pally] then
			table.insert(entries, pally .. "=" .. id)
		end
	end
	if #entries == 0 then
		return
	end
	table.sort(entries)
	SendEntryChunks("AB", entries, channel, target)
end

-- re-broadcast every non-zero aura assignment as live AU messages. PLANAPPLY
-- carries no auras, so a lead that applied a stored plan uses this to teach the
-- group each paladin's aura (receivers CanEdit-gate every AU by owner).
function Comm.BroadcastAuras()
	if not me then
		return
	end
	local plan = HO.Plan.Active()
	if not plan.aura then
		return
	end
	for pally, id in pairs(plan.aura) do
		if id and id ~= 0 then
			Comm.OnAuraEdited(pally)
		end
	end
end

-- authoritative plan snapshot: a row for EVERY paladin in the roster (empty
-- rows serialize as explicit clears so a de-assigned paladin's stale row cannot
-- resurrect), then the tank list as its own PT stream, then an empty PE.
-- override = true bypasses the CanBulk gate when authority comes from elsewhere
-- (a remote lead's revert request routed to the snapshot holder).
function Comm.SendPlanApply(override)
	if not me or not Channel() then
		return false
	end
	if not override and not Comm.CanBulk(me) then
		return false
	end
	local plan = HO.Plan.Active()
	local owners, seen = {}, {}
	for _, name in ipairs(HO.Roster.Paladins()) do
		if not seen[name] then
			seen[name] = true
			table.insert(owners, name)
		end
	end
	for owner in pairs(plan.class) do
		if not seen[owner] then
			seen[owner] = true
			table.insert(owners, owner)
		end
	end
	for owner in pairs(plan.player) do
		if not seen[owner] then
			seen[owner] = true
			table.insert(owners, owner)
		end
	end
	table.sort(owners)
	-- prune tanks no longer in the roster before broadcasting. Explicit
	-- suppressions travel as "!name"; an old client applies that as a positive
	-- mark for a name that matches nobody — harmless, pruned on its next apply
	local tanks = {}
	for name, flag in pairs(plan.tanks) do
		if HO.Roster.byName[name] then
			table.insert(tanks, flag and name or ("!" .. name))
		else
			plan.tanks[name] = nil
		end
	end
	table.sort(tanks)
	-- the snapshot supersedes every single edit still sitting in the debounce or
	-- the send queue; their revs are stale the moment the rows below are bumped
	for key, timer in pairs(sendTimers) do
		if key:find("^SC:") or key:find("^SP:") then
			timer:Cancel()
			sendTimers[key] = nil
		end
	end
	CancelQueued("SC")
	CancelQueued("SP")
	Send("PS:" .. #owners)
	for _, owner in ipairs(owners) do
		BumpRev(owner)
		-- Send fragments oversize rows transparently, so a paladin with many
		-- per-member overrides no longer loses part of the snapshot
		Send("PR:" .. SerializeRow(owner))
	end
	SendTankChunks(tanks)
	Send("PE:" .. #owners)
	HO.Log("comm", "plan apply sent: " .. #owners .. " rows")
	return true
end

-- incoming --------------------------------------------------------------------

local function RefreshUI()
	HO.Window.Refresh()
	HO.Bar.Refresh()
end

local handlers = {}

-- a lead-sanctioned no-Salvation revert makes the SNAPSHOT HOLDER broadcast
-- the restored plan — and the holder may have lost lead/assist since enabling
-- the mode. Receivers therefore accept the holder's next plan apply for a
-- short window after the lead's end-mode message; without this the restore
-- was silently discarded and the swapped plan stuck.
local SALV_REVERT_WINDOW = 10 -- seconds
local salvRevertFrom = nil
local salvRevertUntil = 0

handlers["H"] = function(sender, payload)
	local version, openEdit, caps = strsplit(";", payload)
	local peer = Comm.peers[sender] or {}
	peer.version = version
	peer.openEdit = (openEdit == "1")
	peer.caps = {}
	if caps then
		local id = 0
		for triplet in string.gmatch(caps, "[^,]+") do
			id = id + 1
			peer.caps[id] = {
				known = triplet:sub(1, 1) == "1",
				greater = triplet:sub(2, 2) == "1",
				talent = tonumber(triplet:sub(3, 3)) or 0,
				rank = tonumber(triplet:sub(4, 5)) or 0,
			}
		end
	end
	Comm.peers[sender] = peer
	HO.Log("comm", "hello from " .. sender .. " v" .. tostring(version))
	-- same protocol, but a newer release exists in the group: nudge once per
	-- session (compatible sync keeps working, this is just an update hint)
	if not Comm.updateNotified then
		local theirs, mine = ParseVersion(version), ParseVersion(HO.VERSION)
		if theirs and mine and theirs > mine then
			Comm.updateNotified = true
			HO.Print("a newer HolyOrders (v" .. version .. ") is in your group — you run v"
				.. HO.VERSION .. "; update: " .. UPDATE_URL)
		end
	end
	-- greet back once and share our state directly with the newcomer — but only
	-- if we are a paladin, so non-paladin clients never announce a row
	if not peer.greeted and IsPaladin() then
		peer.greeted = true
		C_Timer.After(math.random() * HELLO_DELAY, function()
			Comm.SendHello("WHISPER", sender)
			Comm.SendFull(sender)
			Comm.SendKnownSpecTags("WHISPER", sender)
			Comm.SendKnownMemberPrefs("WHISPER", sender)
			Comm.SendKnownAuras("WHISPER", sender)
		end)
	end
end

handlers["R"] = function(sender)
	-- session-only state a freshly reloaded requester cannot recover from disk:
	-- our buff request (runs for every client — requesting is the one thing
	-- non-paladins do)
	if HO.db and HO.db.myRequests then
		Send("RQ:" .. table.concat(HO.db.myRequests, ","), "WHISPER", sender)
	end
	if not IsPaladin() then
		return -- non-paladins hold no row to share
	end
	C_Timer.After(math.random() * HELLO_DELAY, function()
		-- hello first: a client that reloaded mid-group pulls with R, and the
		-- once-per-session greet-back stays silent for it — this reply is how
		-- its peer list (versions, caps) gets rebuilt
		Comm.SendHello("WHISPER", sender)
		Comm.SendFull(sender)
	end)
end

handlers["F"] = function(sender, payload)
	if ApplyRow(payload, sender) then
		RefreshUI()
	end
end

handlers["SC"] = function(sender, payload)
	local owner, revStr, classCode, id, modeCode = strsplit(";", payload)
	local classToken = classCode and CODE_CLASS[classCode]
	local mode = modeCode and CODE_MODE[modeCode] or "auto"
	local rev = ValidRev(revStr)
	id = tonumber(id)
	if not owner or not id or not classToken then
		return
	end
	if not rev then
		HO.Log("comm", "dropped SC for " .. owner .. " from " .. sender .. ": invalid rev " .. tostring(revStr))
		return
	end
	if not Comm.CanEdit(sender, owner) then
		return
	end
	local plan = HO.Plan.Active()
	local localRev = Revs(plan)[owner] or 0
	-- owner wins ties (rev == localRev accepted); everyone else needs strictly newer
	if sender == owner then
		if rev < localRev then
			return
		end
	elseif rev <= localRev then
		return
	end
	plan.class[owner] = plan.class[owner] or {}
	if id == 0 then
		plan.class[owner][classToken] = nil
	else
		plan.class[owner][classToken] = { id = id, mode = mode or "auto" }
	end
	Revs(plan)[owner] = rev
	RefreshUI()
end

handlers["SP"] = function(sender, payload)
	local owner, revStr, target, id = strsplit(";", payload)
	local rev = ValidRev(revStr)
	id = tonumber(id)
	if not owner or not id or not target then
		return
	end
	if not rev then
		HO.Log("comm", "dropped SP for " .. owner .. " from " .. sender .. ": invalid rev " .. tostring(revStr))
		return
	end
	if not Comm.CanEdit(sender, owner) then
		return
	end
	local plan = HO.Plan.Active()
	local localRev = Revs(plan)[owner] or 0
	-- owner wins ties; everyone else needs strictly newer (mirrors ApplyRow)
	if sender == owner then
		if rev < localRev then
			return
		end
	elseif rev <= localRev then
		return
	end
	plan.player[owner] = plan.player[owner] or {}
	plan.player[owner][target] = (id ~= 0) and id or nil
	Revs(plan)[owner] = rev
	RefreshUI()
end

handlers["T"] = function(sender, payload)
	local name, flag = strsplit(";", payload)
	if not name then
		return
	end
	if not HO.Roster.byName[name] then
		return -- only flag members currently in the roster
	end
	local entry = HO.Roster.byName[sender]
	-- mirror of CanFlagTank: outside a raid every group member may fix marks
	local allowed = (sender == name) or (entry and (entry.rank or 0) > 0) or not IsInRaid()
	if not allowed then
		return
	end
	local plan = HO.Plan.Active()
	-- store the mark explicitly in both directions: `false` suppresses a
	-- role-icon or spec-derived tank (matches the sender's toggle semantics)
	plan.tanks[name] = (flag == "1") and true or false
	RefreshUI()
end

handlers["PS"] = function(sender)
	-- start (or restart) a snapshot buffer for this sender, discarding any
	-- half-received one from the same sender; the timestamp feeds the
	-- sync-in-progress indicator and ages out abandoned streams
	if Comm.CanBulk(sender) then
		planBuffers[sender] = { rows = {}, tanks = {}, t = GetTime() }
		RefreshUI() -- show the sync lock immediately, not on the next message
	end
end

handlers["PR"] = function(sender, payload)
	local buf = planBuffers[sender]
	if buf then
		table.insert(buf.rows, payload)
	end
end

handlers["PT"] = function(sender, payload)
	local buf = planBuffers[sender]
	if buf and payload then
		for name in string.gmatch(payload, "[^|]+") do
			table.insert(buf.tanks, name)
		end
	end
end

handlers["PE"] = function(sender)
	local buf = planBuffers[sender]
	if not buf then
		return
	end
	local rows, tanks = buf.rows, buf.tanks
	planBuffers[sender] = nil
	-- re-check bulk permission at apply time: a demotion mid-stream discards the
	-- whole buffer rather than applying a snapshot the sender may no longer own.
	-- Exception: the no-Salvation holder answering a lead's revert (see above).
	local sanctioned = (sender == salvRevertFrom) and GetTime() < salvRevertUntil
	if not Comm.CanBulk(sender) and not sanctioned then
		HO.Log("comm", "plan apply from " .. sender .. " discarded (no bulk permission at PE)")
		return
	end
	if sanctioned then
		salvRevertFrom = nil
	end
	local plan = HO.Plan.Active()
	local applied = 0
	-- adopt every buffered row unconditionally (bulk permission was checked)
	for _, row in ipairs(rows) do
		if ApplyRow(row, sender, true) then
			applied = applied + 1
		end
	end
	wipe(plan.tanks)
	for _, name in ipairs(tanks) do
		local suppressed = name:match("^!(.+)$")
		if suppressed then
			plan.tanks[suppressed] = false -- explicit "never a tank" mark
		else
			plan.tanks[name] = true
		end
	end
	-- a remote bulk apply is a new clean baseline
	plan.meta = plan.meta or {}
	plan.meta.dirty = false
	-- the snapshot supersedes any pre-snapshot tank click still waiting to send
	CancelQueued("T")
	HO.Log("comm", "plan apply from " .. sender .. ": " .. applied .. "/" .. #rows .. " rows")
	HO.Announce("blessing plan received from " .. sender)
	RefreshUI()
end

handlers["PING"] = function(sender)
	HO.Print("comm loopback OK (from " .. sender .. ")")
end

-- remote log pull: a group member requests our recent log; we whisper it
-- back in chunks so it ends up in THEIR SavedVariables for offline analysis
local LOG_SHARE_MAX = 25
local LR_COOLDOWN = 10 -- seconds a requester must wait between log pulls
local LL_STORE_MAX = 50 -- stored entries per sender
local lrLast = {} -- [requester] = GetTime() of last honored request

handlers["LR"] = function(sender)
	if not HO.Roster.byName[sender] then
		return -- group members only
	end
	-- rate-limit each requester so a single member cannot make us flood whispers
	local now = GetTime()
	if lrLast[sender] and (now - lrLast[sender]) < LR_COOLDOWN then
		return
	end
	lrLast[sender] = now
	local log = HO.db.log
	local from = math.max(1, #log - LOG_SHARE_MAX + 1)
	local total = #log - from + 1
	if total <= 0 then
		Send("LL:1;1;<empty log>", "WHISPER", sender)
		return
	end
	local idx = 0
	for i = from, #log do
		idx = idx + 1
		local entry, myIdx = log[i], idx
		C_Timer.After(myIdx * 0.1, function()
			Send("LL:" .. myIdx .. ";" .. total .. ";" .. tostring(entry):sub(1, 180), "WHISPER", sender)
		end)
	end
	HO.Announce("sent " .. total .. " log entries to " .. sender)
end

handlers["LL"] = function(sender, payload)
	local idx, total, entry = payload:match("^(%d+);(%d+);(.*)$")
	idx, total = tonumber(idx), tonumber(total)
	if not idx then
		return
	end
	if idx <= 1 then
		-- keep only the most recent pull; remoteLogs must not grow forever
		HO.db.remoteLogs = { [sender] = {} }
	end
	HO.db.remoteLogs = HO.db.remoteLogs or {}
	local list = HO.db.remoteLogs[sender]
	if list then
		if #list < LL_STORE_MAX then
			table.insert(list, entry)
		end
		if idx == total then
			HO.Print("received " .. #list .. " log entries from " .. sender .. " — /reload writes them to SavedVariables")
		end
	end
end

function Comm.RequestLog(target)
	Send("LR:", "WHISPER", target)
end

-- no-Salvation mode state sync ------------------------------------------------

function Comm.SendNoSalv(active)
	Send("NS:" .. (active and "1" or "0"))
end

handlers["NS"] = function(sender, payload)
	local entry = HO.Roster.byName[sender]
	if not (entry and (entry.rank or 0) > 0) then
		return -- lead/assist only, like the feature itself
	end
	if payload == "1" then
		HO.db.noSalvBy = sender
		HO.Announce("no-Salvation mode enabled by " .. sender)
	else
		-- open the acceptance window for the holder's restore snapshot
		salvRevertFrom = HO.db.noSalvBy or sender
		salvRevertUntil = GetTime() + SALV_REVERT_WINDOW
		HO.db.noSalvBy = nil
		if HO.Plan.NoSalvationActive() then
			-- we hold the snapshot; a lead asked for the revert — restore
			-- exactly and share both the plan and the ended state. The revert's
			-- authority is the requesting lead, so broadcast even if WE were
			-- demoted meanwhile (override the local CanBulk gate).
			HO.Plan.SetNoSalvation(false)
			Comm.SendPlanApply(true)
			Comm.SendNoSalv(false)
			HO.Announce("no-Salvation mode reverted (requested by " .. sender .. ")")
		else
			HO.Announce("no-Salvation mode ended by " .. sender)
		end
	end
	RefreshUI()
end

-- spec-tag overlay sync -------------------------------------------------------

handlers["ST"] = function(sender, payload)
	local name, tag = strsplit(";", payload)
	if not name or not tag or tag == "" then
		return
	end
	if Comm.specSync[name] ~= tag then
		Comm.specSync[name] = tag
		RefreshUI()
	end
end

-- member-liking sync: last-writer-wins, no revisioning (likings change rarely).
-- Direct table writes only (never via Plan.SetMemberPref, which would echo back).
handlers["MP"] = function(sender, payload)
	local name, idStr = strsplit(";", payload)
	if not name then
		return
	end
	local id = tonumber(idStr)
	HO.db.memberPrefs = HO.db.memberPrefs or {}
	if not id or id == 0 then
		HO.db.memberPrefs[name] = nil
	elseif HO.Data.blessings[id] then
		HO.db.memberPrefs[name] = id
	end
	RefreshUI()
end

-- batched likings from a greet; adds/updates only, never deletes local entries
handlers["MB"] = function(sender, payload)
	if not payload then
		return
	end
	HO.db.memberPrefs = HO.db.memberPrefs or {}
	for entry in string.gmatch(payload, "[^|]+") do
		local name, idStr = entry:match("^(.+)=(%d+)$")
		local id = name and tonumber(idStr)
		if id and HO.Data.blessings[id] then
			HO.db.memberPrefs[name] = id
		end
	end
	RefreshUI()
end

-- live aura assignment: last-writer-wins, no revisioning (auras change rarely).
-- CanEdit gates by owner (self / lead / open-edit), the same gate row edits use.
-- Direct write only (never via Plan.SetAura, which would echo back into Comm).
handlers["AU"] = function(sender, payload)
	local paladin, idStr = strsplit(";", payload)
	if not paladin then
		return
	end
	if not Comm.CanEdit(sender, paladin) then
		return
	end
	local id = tonumber(idStr)
	local plan = HO.Plan.Active()
	plan.aura = plan.aura or {}
	if not id or id == 0 then
		plan.aura[paladin] = nil
	elseif HO.Data.auras[id] then
		plan.aura[paladin] = id
	else
		return -- unknown aura id: reject
	end
	RefreshUI()
end

-- batched aura assignments from a greet; CanEdit-gated per owner, direct writes
handlers["AB"] = function(sender, payload)
	if not payload then
		return
	end
	local plan = HO.Plan.Active()
	plan.aura = plan.aura or {}
	local changed = false
	for entry in string.gmatch(payload, "[^|]+") do
		local paladin, idStr = entry:match("^(.+)=(%d+)$")
		local id = paladin and tonumber(idStr)
		-- GAP-FILL ONLY: greet batches fly from every client on every join,
		-- in random arrival order — letting them overwrite existing values
		-- made auras flip with whoever's batch landed last. Deliberate edits
		-- travel as live AU singles, which do overwrite.
		if id and HO.Data.auras[id] and not plan.aura[paladin]
			and Comm.CanEdit(sender, paladin) then
			plan.aura[paladin] = id
			changed = true
		end
	end
	if changed then
		RefreshUI()
	end
end

-- buff requests ---------------------------------------------------------------
-- Any player (paladins included, but especially non-paladins who are otherwise
-- passive) may request blessings for THEMSELVES, as an ordered priority list.
-- The message is always about the sender: RQ:<id,id,...> ("0" or empty = clear).
-- Low-churn and last-writer-wins, so it needs no revision. This is the one
-- message a non-paladin client ever sends.
Comm.REQUEST_MAX = 6 -- at most one entry per blessing

-- validate + copy an ordered request list: keep known blessing ids in priority
-- order, drop duplicates (keeping the earliest) and cap the length
local function NormalizeRequests(ids)
	if type(ids) == "number" then
		ids = { ids }
	end
	local out, seen = {}, {}
	if type(ids) == "table" then
		for _, id in ipairs(ids) do
			id = tonumber(id)
			if id and id ~= 0 and HO.Data.blessings[id] and not seen[id] and #out < Comm.REQUEST_MAX then
				seen[id] = true
				out[#out + 1] = id
			end
		end
	end
	return out
end

function Comm.SendRequest(ids)
	if not me then
		return
	end
	local list = NormalizeRequests(ids)
	-- persist the local player's own request list (nil clears); survives /reload
	-- and is re-announced from the roster hook so late-joining paladins see it
	HO.db.myRequests = (#list > 0) and list or nil
	-- reflect it locally too, so a self-covering paladin sees their own badge
	Comm.requests[me] = HO.db.myRequests
	if IsInGroup() then
		Send("RQ:" .. (#list > 0 and table.concat(list, ",") or "0"))
	end
	if HO.Request then
		HO.Request.Refresh()
	end
	RefreshUI()
end

-- a request is always about its sender; parse the priority list and store/clear it
handlers["RQ"] = function(sender, payload)
	local list = {}
	for token in tostring(payload):gmatch("[^,]+") do
		local id = tonumber(token)
		if id and id ~= 0 and HO.Data.blessings[id] then
			list[#list + 1] = id
		end
	end
	Comm.requests[sender] = (#list > 0) and NormalizeRequests(list) or nil
	RefreshUI()
end

local protoWarned = {} -- [sender] = their protocol number; also feeds /ho peers
Comm.protoMismatch = protoWarned

-- mutating message types require the sender to be a current group member; when
-- ungrouped there is no roster so all of these are rejected. FG only ever wraps
-- row data, so it is mutating too (the reassembled inner type re-checks anyway).
local MUTATING = {
	SC = true, SP = true, F = true, T = true,
	PS = true, PR = true, PT = true, PE = true,
	NS = true, LR = true, LL = true, ST = true,
	MP = true, MB = true,
	AU = true, AB = true,
	RQ = true,
	FG = true,
}

-- messages from members our roster has not caught up with yet: greet replies
-- and rows arrive within seconds while GROUP_ROSTER_UPDATE fills the roster
-- over many events during raid formation, so a hard drop loses real state.
-- Stash them per sender and replay once the roster adds the sender; a sender
-- who never joins ages out.
local PENDING_MAX = 8 -- stashed messages per unknown sender
local PENDING_TTL = 60 -- seconds until an unclaimed stash is junk
local pendingMsgs = {} -- [sender] = { t = GetTime(), {msgType, payload, channel}, ... }

-- one dispatch path shared by the live event and by FG reassembly: the
-- group-membership gate, trace logging and handler lookup, so a reassembled
-- message passes exactly the gate a normal one would
local function HandleMessage(sender, msgType, payload, channel)
	if MUTATING[msgType] and not (sender and HO.Roster.byName[sender]) then
		if sender then
			local stash = pendingMsgs[sender]
			if not stash then
				stash = { t = GetTime() }
				pendingMsgs[sender] = stash
			end
			if #stash < PENDING_MAX then
				stash[#stash + 1] = { msgType, payload, channel }
			end
		end
		if HO.db and HO.db.options.trace then
			HO.Log("rx", "stashed " .. msgType .. " from not-yet-known " .. tostring(sender))
		end
		return
	end
	if HO.db and HO.db.options.trace and msgType ~= "LL" then
		HO.Log("rx", sender .. " " .. msgType .. ":" .. tostring(payload):sub(1, 100))
	end
	local handler = handlers[msgType]
	if handler then
		local ok, err = pcall(handler, sender, payload, channel)
		if not ok then
			HO.Log("error", "comm " .. tostring(msgType) .. ": " .. tostring(err))
		end
	end
end

-- fragment reassembly, keyed by sender AND channel: one sender may interleave a
-- fragmented RAID message with a fragmented WHISPER, so each channel gets its own
-- buffer. B starts/restarts a buffer, C appends, E appends then dispatches the
-- rebuilt inner message; orphaned C/E (no matching B) and runaway buffers drop.
local FRAG_BUFFER_MAX = 10
local fragBuffers = {} -- [sender] = { [channel] = { chunk, chunk, ... } }

handlers["FG"] = function(sender, payload, channel)
	local k, chunk = payload:match("^(%u):(.*)$")
	if not k then
		return
	end
	channel = channel or "?"
	if k == "B" then
		local perSender = fragBuffers[sender] or {}
		fragBuffers[sender] = perSender
		perSender[channel] = { chunk }
		return
	end
	local perSender = fragBuffers[sender]
	local buf = perSender and perSender[channel]
	if not buf then
		return -- C/E without a live B: discard
	end
	if #buf >= FRAG_BUFFER_MAX then
		perSender[channel] = nil -- runaway: drop rather than grow without bound
		HO.Log("comm", "fragment buffer overflow from " .. sender .. " — dropped")
		return
	end
	buf[#buf + 1] = chunk
	if k == "E" then
		perSender[channel] = nil
		local msg = table.concat(buf)
		local innerType, innerPayload = msg:match("^(%u+):?(.*)$")
		if innerType then
			HandleMessage(sender, innerType, innerPayload, channel)
		end
	end
end

HO.RegisterEvent("CHAT_MSG_ADDON", function(prefix, message, channel, senderFull)
	if prefix ~= PREFIX or not me then
		return -- not ours, or before login init
	end
	-- the classic client delivers same-realm senders WITHOUT the realm suffix;
	-- peers, plan rows and the roster are all keyed by full "Name-Realm" names,
	-- so qualify bare senders with our own realm (cross-realm senders carry theirs)
	local sender = senderFull
	if sender and not sender:find("-", 1, true) then
		sender = sender .. "-" .. (GetNormalizedRealmName() or "")
	end
	local proto, msgType, payload = message:match("^(%d+):(%u+):?(.*)$")
	if proto ~= PROTO then
		-- incompatible protocol: warn once per sender instead of silence
		if proto and sender and sender ~= me and not protoWarned[sender] then
			protoWarned[sender] = proto
			HO.Log("comm", "protocol mismatch from " .. sender .. " (theirs " .. proto .. ", ours " .. PROTO .. ")")
			-- say WHO is outdated: the lower protocol number needs the update
			local theirs, ours = tonumber(proto), tonumber(PROTO)
			if theirs and ours and theirs > ours then
				HO.Print("your HolyOrders is OUT OF DATE — sync with " .. sender
					.. " is DISABLED until you update: " .. UPDATE_URL)
			else
				HO.Print(sender .. " runs an outdated HolyOrders — sync with them is DISABLED until they update ("
					.. UPDATE_URL .. ")")
			end
		end
		return
	end
	if sender == me and msgType ~= "PING" then
		return -- own broadcasts echo back; PING is the deliberate loopback
	end
	HandleMessage(sender, msgType, payload, channel)
end)

-- deliver stashed messages whose sender the roster now knows; age out the rest
local function ReplayPending()
	local now = GetTime()
	for sender, stash in pairs(pendingMsgs) do
		if now - stash.t > PENDING_TTL then
			pendingMsgs[sender] = nil
		elseif HO.Roster.byName[sender] then
			pendingMsgs[sender] = nil
			for _, m in ipairs(stash) do
				HandleMessage(sender, m[1], m[2], m[3])
			end
		end
	end
end

-- session wiring --------------------------------------------------------------

local lastPallySig
local pulled = false -- one state pull per session, on the first grouped roster

-- drop peer + fragment state for members who left the group: a leaver's stale
-- openEdit/caps/greeted and any half-received fragments must not linger. Own
-- entry is always kept; specSync is a deliberate session cache and left alone.
local function PruneDeparted()
	local grouped = IsInGroup()
	local function departed(name)
		if name == me then
			return false
		end
		return (not grouped) or not HO.Roster.byName[name]
	end
	for name in pairs(Comm.peers) do
		if departed(name) then
			Comm.peers[name] = nil
		end
	end
	for name in pairs(fragBuffers) do
		if departed(name) then
			fragBuffers[name] = nil
		end
	end
	-- forget mismatch flags of leavers: they stop cluttering /ho peers, and a
	-- rejoin after updating warns (or clears) freshly
	for name in pairs(protoWarned) do
		if departed(name) then
			protoWarned[name] = nil
		end
	end
	-- a leaver's buff request must not linger on our screen (own is kept)
	for name in pairs(Comm.requests) do
		if departed(name) then
			Comm.requests[name] = nil
		end
	end
	-- a leaver's half-received plan snapshot can never complete
	for name in pairs(planBuffers) do
		if departed(name) then
			planBuffers[name] = nil
		end
	end
end

HO.RegisterEvent("PLAYER_LOGIN", function()
	me = HO.FullName("player")
	-- migrate a legacy single request into the new ordered list
	if HO.db and HO.db.myRequest ~= nil and HO.db.myRequests == nil then
		HO.db.myRequests = { HO.db.myRequest }
		HO.db.myRequest = nil
	end
	-- reflect our own persisted request so the badge shows before any regroup
	if HO.db then
		Comm.requests[me] = HO.db.myRequests
	end
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	HO.Roster.OnChanged(function()
		PruneDeparted()
		ReplayPending()
		-- the no-Salvation encounter mode is group-scoped: leaving the group
		-- ends it. The snapshot holder restores their own plan locally (solo,
		-- nothing to send); everyone else clears the synced flag. This also
		-- heals an orphaned snapshot that would otherwise block re-enabling
		-- ("already active") in the next session.
		if not IsInGroup() and HO.db then
			if HO.Plan.NoSalvationActive() then
				HO.Plan.SetNoSalvation(false)
				HO.Announce("no-Salvation mode ended (left the group) — plan restored")
				RefreshUI()
			end
			if HO.db.noSalvBy then
				HO.db.noSalvBy = nil
				RefreshUI()
			end
		end
		-- greet whenever the paladin composition changes; non-paladin
		-- clients listen but never announce themselves as paladins
		local sig = table.concat(HO.Roster.Paladins(), ";")
		if sig ~= lastPallySig then
			lastPallySig = sig
			if IsPaladin() and Channel() then
				Comm.SendHello()
				Comm.SendFull()
				Comm.SendKnownSpecTags()
				Comm.SendKnownMemberPrefs()
				Comm.SendKnownAuras()
			end
			-- re-announce our own buff request so paladins who just joined see
			-- it again; runs for non-paladins too (the one message they send),
			-- so a requester who relogs or regroups is not forgotten
			if HO.db and HO.db.myRequests and IsInGroup() then
				Comm.SendRequest(HO.db.myRequests)
			end
			-- loaded into a group whose members already greeted us in THEIR
			-- sessions (mid-raid /reload): our hello draws no replies, so pull —
			-- every paladin answers R with a whispered hello + row
			if not pulled and IsInGroup() then
				pulled = true
				Comm.RequestSync()
			end
		end
	end)
end)

function Comm.Ping()
	if not me then
		return
	end
	C_ChatInfo.SendAddonMessage(PREFIX, PROTO .. ":PING:", "WHISPER", me)
end

-- ask every paladin to re-broadcast their authoritative row; the R handler
-- answers with a random-delayed whisper, so a burst of requests self-limits
function Comm.RequestSync()
	syncSettleUntil = GetTime() + SYNC_SETTLE
	Send("R:")
	if HO.Window and HO.Window.Refresh then
		HO.Window.Refresh() -- show the sync lock for the settle window
	end
end

-- is a sync visibly in progress? True while a plan snapshot stream is
-- mid-flight (start received, atomic apply pending) or during the settle
-- window after a pull while the replies land. Drives the window's lock.
function Comm.SyncActive()
	if GetTime() < syncSettleUntil then
		return true
	end
	for _, buf in pairs(planBuffers) do
		if GetTime() - (buf.t or 0) < PLAN_STREAM_TIMEOUT then
			return true
		end
	end
	return false
end
