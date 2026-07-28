local Players = game:GetService("Players")
local pg   = Players.LocalPlayer:WaitForChild("PlayerGui")
local gui  = pg:WaitForChild("GameUI")
local shop = gui:WaitForChild("Shop")

--== CONFIG ====================================================
-- Trigger is ROOM-based: buy when an item has at least this much empty
-- storage space. Needs no capacity knowledge, so it works on every item
-- and every server with no calibration and no per-item floors.
local ROOM_TRIGGER = 10

-- Excluded by name, applied to STORES, SECTIONS and ITEMS alike.
-- "Syntin Petrol Co" is the gasoline store — matched by name and by "petrol".
local EXCLUDE_NAMES = {
	["Syntin Petrol Co"] = true,
	["Gasoline"] = true, ["Gas"] = true, ["Fuel"] = true, ["Diesel"] = true,
}
local EXCLUDE_PATTERNS = { "gasoline", "petrol", "diesel", "^fuel$" }

-- UI templates, not real stores/sections/items.
local SKIP_NAMES    = { Item = true, Section = true, Dummy = true, Template = true }
local SKIP_PATTERNS = { "^dummy%d*$", "^section%d*$", "^item%d*$", "template" }

local FUNDS        = "BuyPlayer"
local INTERVAL     = 2
local SETTLE       = 1.5
local COOLDOWN     = 5
local SPEND_BUDGET = 5000
local DRY_RUN      = false
local VERBOSE      = false   -- true = log every item every cycle
local AUTO_OPEN    = true
local SWITCH_WAIT  = 2.0     -- max seconds to wait for ShopTitle to confirm a store switch

-- Poll interval while the shop is shut. With AUTO_OPEN off the script cannot
-- reopen it, so retrying every INTERVAL just floods the log.
local CLOSED_BACKOFF = 10

-- Hide the shop without closing it. The script has to READ the shop to work,
-- and the game only updates Price/Amount while the shop is open, so Visible
-- stays true and the frame is parked off-screen instead. This is the game's
-- own idiom — the employee panel's Close button tweens itself to y=-1.1.
local HIDE_UI   = true
local PARK_POS  = UDim2.fromScale(3, 3)
--==============================================================

local RS = {}
_G.RESTOCK = RS
RS.dry, RS.paused, RS.stop, RS.spent = DRY_RUN, false, false, 0
RS.cycles, RS.buys, RS.failed = 0, 0, 0
RS.last, RS.cap, RS.reason, RS.seen, RS.skipped = {}, {}, {}, {}, {}
RS.trigger, RS.budget = ROOM_TRIGGER, SPEND_BUDGET

-- Warnings go through print() as well as warn(). The Opiumware dev console
-- captures MessageOutput and MessageError but NOT MessageWarning — a 392-line
-- capture had 0 warning lines — so anything warn()-only is invisible in logs.
local function log(f, ...) print("[restock] " .. f:format(...)) end
local function warnf(f, ...)
	local line = "[restock] WARN " .. f:format(...)
	print(line)
	pcall(warn, line)
end

----------------------------------------------------------------
-- UI parking — move a frame off-screen instead of hiding it, so the game
-- keeps updating its labels and its buttons stay live.
----------------------------------------------------------------
local parked = {}   -- [GuiObject] = original Position

-- Re-applies if the position drifted: the game rewrites Position when it
-- opens or closes the shop, which would otherwise un-hide it mid-run.
local function park(g)
	if not g then return end
	if parked[g] == nil then parked[g] = g.Position end
	if g.Position ~= PARK_POS then g.Position = PARK_POS end
end

local function unpark(g)
	if not g or not parked[g] then return end
	g.Position, parked[g] = parked[g], nil
end

local function unparkAll()
	for g in pairs(parked) do unpark(g) end
end

function RS.hide()
	RS.hidden = true
	park(shop)
	log("shop parked off-screen (Visible stays true so labels keep updating)")
end

function RS.show()
	RS.hidden = false
	unpark(shop)
	log("shop restored to its original position")
end

----------------------------------------------------------------
-- unlock events
----------------------------------------------------------------
-- Consumers (staff.lua, shelf assignment) subscribe with RS.on(fn).
-- Events:  "ready"  -> array of items unlocked at join
--          "unlock" -> array of items that unlocked since the last cycle
RS.unlocked = {}    -- [key] = true once seen unlocked
RS.listeners = {}

function RS.on(fn) table.insert(RS.listeners, fn) end

local function emit(event, payload)
	for _, fn in ipairs(RS.listeners) do
		local ok, err = pcall(fn, event, payload)
		if not ok then warnf("listener error on %q: %s", event, tostring(err)) end
	end
end

local function childNames(inst)
	local t = {}
	for _, c in ipairs(inst:GetChildren()) do table.insert(t, c.Name) end
	return table.concat(t, ", ")
end

local function matches(name, patterns)
	local low = name:lower()
	for _, p in ipairs(patterns) do
		if low:match(p) then return true end
	end
	return false
end

local function isTemplate(name) return SKIP_NAMES[name] or matches(name, SKIP_PATTERNS) end
local function isExcluded(name) return EXCLUDE_NAMES[name] or matches(name, EXCLUDE_PATTERNS) end

-- Switching stores rebuilds Frame.Content, so nothing under it is cached.
local function sections() return shop.Background.Frame:FindFirstChild("Content") end
local function bulk()     return shop.Background.Bottom:FindFirstChild("Bulk") end
local function title()    return shop.Background:FindFirstChild("ShopTitle") end

local function click(btn, label)
	if not btn then
		warnf("click FAILED: %s is nil", tostring(label))
		return false
	end
	local ok, conns = pcall(getconnections, btn.Activated)
	if ok and conns then
		if #conns == 0 then
			warnf("click FAILED: %s has 0 connections", label)
			return false
		end
		for _, c in ipairs(conns) do c:Fire() end
		return true, "getconnections x" .. #conns
	end
	if pcall(firesignal, btn.Activated) then
		return true, "firesignal"
	end
	warnf("click FAILED: %s — no click method available", label)
	return false
end

-- Every reading is stale until Bulk.Max is clicked; Bulk is shared across stores.
local function refresh()
	local b = bulk()
	local maxBtn = b and b:FindFirstChild("Max")
	if not maxBtn then
		warnf("Bulk.Max missing — readings will be STALE")
		return false
	end
	click(maxBtn, "Bulk.Max")
	task.wait(0.3)
	return true
end

----------------------------------------------------------------
-- shop opening
----------------------------------------------------------------
local function openButton()
	local sm = gui:FindFirstChild("SideMenu")
	local sb = sm and sm:FindFirstChild("SideButtons")
	local hub = sb and sb:FindFirstChild("DeskHub")
	local acts = hub and hub:FindFirstChild("Actions")
	return acts and acts:FindFirstChild("Shop")
end

local function ensureOpen()
	if shop.Visible then return true, "already" end
	if not AUTO_OPEN then return false, "auto-open disabled" end

	local btn = openButton()
	if btn then
		click(btn, "SideMenu.Shop")
		task.wait(0.5)
		if shop.Visible then return true, "button" end
	end

	shop.Visible = true
	task.wait(0.3)
	if shop.Visible then return true, "direct" end
	return false, "failed"
end

----------------------------------------------------------------
-- store navigation
----------------------------------------------------------------
local function storeList()
	local root = shop:FindFirstChild("Shops")
	if not root then return {} end
	local t = {}
	for _, f in ipairs(root:GetChildren()) do
		local btn = f:FindFirstChild("Button")
		if btn and btn:IsA("GuiButton") and not isTemplate(f.Name) then
			table.insert(t, { name = f.Name, button = btn, skip = isExcluded(f.Name) })
		end
	end
	table.sort(t, function(a, b) return a.name < b.name end)
	return t
end

-- ShopTitle is the only reliable confirmation that the swap actually landed.
local function switchTo(store)
	local t = title()
	if t and t.Text == store.name then return true, "already" end
	if not click(store.button, "Shops." .. store.name) then
		return false, "click failed"
	end
	-- Re-fetch the label each iteration: if ShopTitle is rebuilt along with
	-- Frame.Content, the ref captured above is stale and its .Text would never
	-- update, timing out every switch that actually succeeded.
	local waited = 0
	while waited < SWITCH_WAIT do
		task.wait(0.1)
		waited = waited + 0.1
		local cur = title()
		if cur and cur.Text == store.name then return true, "switched" end
	end
	local cur = title()
	return false, string.format("title still %q", cur and cur.Text or "?")
end

----------------------------------------------------------------
-- reading / scanning
----------------------------------------------------------------
local function readRoom(entry)
	local price = entry:FindFirstChild("Price")
	if not price then return nil, nil, "<no Price>" end
	local txt = price.Text
	local qty, cost = txt:match("(%d+)%s+for%s+%$([%d%.,]+)")
	if not qty then return nil, nil, txt end
	qty, cost = tonumber(qty), tonumber((cost:gsub(",", "")))

	-- The game builds this label as
	--     math.floor(math.max(1, math.min(bulk, MaxStorage - Storage)))
	-- so a displayed "1 for $x" means room is either 1 OR 0 — buying on it when
	-- the shelf is actually full wastes a purchase and shows up as NO EFFECT.
	-- That is the off-by-one seen when a Max buy of 2 left room at 1.
	-- workspace.Storage carries the exact figures, so trust those for the
	-- quantity and keep the label only for the price (which drifts over time).
	local storage = workspace:FindFirstChild("Storage")
	local slot = storage and storage:FindFirstChild(entry.Name)
	if slot then
		local have, max = slot:GetAttribute("Storage"), slot:GetAttribute("MaxStorage")
		if have and max then
			local room = math.max(max - have, 0)
			return room, (cost / qty) * room, txt
		end
	end
	return qty, cost, txt
end

-- Templates read Amount/Price = "nil" and have an EMPTY Viewport.World;
-- real items have a Model in there. Either signal is enough on its own.
local function isRealItem(e)
	if isTemplate(e.Name) or isExcluded(e.Name) then return false end
	local price = e:FindFirstChild("Price")
	if not price then return false end
	if price.Text:match("(%d+)%s+for%s+%$") then return true end
	local vp = e:FindFirstChild("Viewport")
	local world = vp and vp:FindFirstChild("World")
	return world ~= nil and #world:GetChildren() > 0
end

-- Scan the store that is on screen RIGHT NOW. Entries are never cached
-- across store switches — Content is rebuilt and stale refs would read
-- the wrong store's numbers.
local function scanStore(storeName)
	local items = {}
	local content = sections()
	if not content then
		warnf("%s: Frame.Content missing", storeName)
		return items
	end
	for _, sec in ipairs(content:GetChildren()) do
		local inner = sec:FindFirstChild("Content")
		if inner and sec:IsA("GuiObject") and sec.Visible
			and not isTemplate(sec.Name) and not isExcluded(sec.Name) then
			for _, e in ipairs(inner:GetChildren()) do
				if isRealItem(e) then
					table.insert(items, {
						key     = storeName .. "/" .. e.Name,
						name    = e.Name,
						section = sec.Name,
						entry   = e,
						buy     = e:FindFirstChild(FUNDS),
						locked  = not e.Visible,
					})
				end
			end
		end
	end
	table.sort(items, function(a, b) return a.key < b.key end)
	return items
end

local function announce(it)
	if RS.seen[it.key] then return end
	RS.seen[it.key] = true
	local room, _, raw = readRoom(it.entry)
	local price = it.entry:FindFirstChild("Price")
	local c = price and price.TextColor3
	log("+ %-26s section=%-20s buy=%-5s %-8s room=%-4s pcol=%s raw=%q",
		it.key, it.section, tostring(it.buy ~= nil),
		it.locked and "LOCKED" or "unlocked", tostring(room),
		c and string.format("%d,%d,%d", math.floor(c.R * 255), math.floor(c.G * 255),
			math.floor(c.B * 255)) or "?", raw)
	if not it.buy then
		warnf("  %s has no %s. children: %s", it.key, FUNDS, childNames(it.entry))
	end
end

----------------------------------------------------------------
-- decision
----------------------------------------------------------------
local function decide(it)
	-- Items not unlocked on this server stay in the tree with a live price and
	-- a working BuyPlayer, but Visible=false on the entry frame. That is the
	-- ONLY client-side signal — every other property matches an unlocked item.
	-- Read live rather than from the scan flag, so unlocking mid-session is
	-- picked up on the next cycle with no restart.
	if not it.entry.Visible then
		return "LOCKED"
	end

	local room, cost, raw = readRoom(it.entry)
	if not room then
		return "PARSE_FAIL raw=" .. string.format("%q", raw)
	end

	if room > (RS.cap[it.key] or 0) then RS.cap[it.key] = room end
	local cap   = RS.cap[it.key] or 0
	local stock = cap > 0 and string.format("%d/%d", cap - room, cap) or "?"

	if room == 0 then
		return "FULL"
	elseif room < RS.trigger then
		return string.format("OK room=%d (stock %s)", room, stock)
	elseif not it.buy then
		return "NO_BUY_BUTTON"
	elseif not shop.Visible then
		return "SHOP_CLOSED"
	end

	local since = tick() - (RS.last[it.key] or 0)
	if since < COOLDOWN then
		return string.format("COOLING %.1fs", COOLDOWN - since)
	elseif RS.spent + cost > RS.budget then
		return string.format("BUDGET %.2f + %.2f > %d", RS.spent, cost, RS.budget)
	elseif RS.dry then
		return string.format("DRY would buy %d for $%.2f (stock %s)", room, cost, stock)
	end
	return "BUYING", room, cost
end

local function execute(it, before, cost)
	local ok, method = click(it.buy, it.key .. "." .. FUNDS)
	if not ok then
		RS.failed = RS.failed + 1
		return
	end
	RS.last[it.key] = tick()
	task.wait(SETTLE)
	refresh()

	local after = readRoom(it.entry)
	if after and after < before then
		local got  = before - after
		-- the label price covers `before` units; charge for what actually landed
		local paid = cost * (got / before)
		RS.spent = RS.spent + paid
		RS.buys  = RS.buys + 1
		log("%-26s CONFIRMED (%s): room %d -> %d, +%d/%d units, $%.2f (total $%.2f)",
			it.key, method, before, after, got, before, paid, RS.spent)
		if got < before then
			warnf("  %s PARTIAL: asked %d, got %d — funds cap or per-buy limit?",
				it.key, before, got)
		end
	else
		RS.failed = RS.failed + 1
		warnf("%-26s NO EFFECT (%s): room %d -> %s", it.key, method, before, tostring(after))
	end
end

----------------------------------------------------------------
-- walk every watched store, applying fn to each item
----------------------------------------------------------------
local function forEachStore(fn)
	local stores = storeList()
	if #stores == 0 then
		-- no store selector (older UI) — treat whatever is on screen as the only store
		local t = title()
		fn(t and t.Text or "Shop", scanStore(t and t.Text or "Shop"))
		return 1
	end
	local visited = 0
	for _, s in ipairs(stores) do
		if s.skip then
			if not RS.skipped[s.name] then
				RS.skipped[s.name] = true
				log("EXCLUDED store: %s", s.name)
			end
		else
			local ok, how = switchTo(s)
			if not ok then
				warnf("store %s: switch failed (%s)", s.name, how)
			else
				refresh()
				visited = visited + 1
				fn(s.name, scanStore(s.name))
			end
		end
	end
	return visited
end

----------------------------------------------------------------
-- manual controls
----------------------------------------------------------------
function RS.status()
	local n, nLocked = 0, 0
	forEachStore(function(storeName, items)
		log("--- %s (%d items) ---", storeName, #items)
		for _, it in ipairs(items) do
			local room = readRoom(it.entry)
			local cap  = RS.cap[it.key] or 0
			log("  %-26s %-8s room=%-4s cap=%-4s stock=%s", it.name,
				it.locked and "LOCKED" or "", tostring(room),
				cap > 0 and tostring(cap) or "?",
				(room and cap > 0) and tostring(cap - room) or "?")
			if it.locked then nLocked = nLocked + 1 else n = n + 1 end
		end
	end)
	log("%d buyable, %d locked | trigger room>=%d | dry=%s | spent $%.2f/%d",
		n, nLocked, RS.trigger, tostring(RS.dry), RS.spent, RS.budget)
end

function RS.calibrate()
	log("calibrating — assuming storage is EMPTY right now")
	forEachStore(function(_, items)
		for _, it in ipairs(items) do
			local room = readRoom(it.entry)
			if room then
				RS.cap[it.key] = room
				log("  %-26s capacity := %d", it.key, room)
			end
		end
	end)
end

function RS.setCap(key, n)
	RS.cap[key] = n
	log("%s capacity forced to %d", key, n)
end

function RS.unwatch(name)
	EXCLUDE_NAMES[name] = true
	log("%s unwatched (store, section or item)", name)
end

function RS.stores()
	for _, s in ipairs(storeList()) do
		log("store %-24s %s", s.name, s.skip and "EXCLUDED" or "watched")
	end
end

----------------------------------------------------------------
-- startup
----------------------------------------------------------------
log("=== HEALTH CHECK ===")
local opened, how = ensureOpen()
log("shop open: %s (%s)", tostring(opened), how)
log("open button found: %s", tostring(openButton() ~= nil))
local b = bulk()
log("Bulk.Max present: %s", tostring(b ~= nil and b:FindFirstChild("Max") ~= nil))
RS.stores()

local total, lockedCount = 0, 0
local visited = forEachStore(function(storeName, items)
	local nLocked = 0
	for _, it in ipairs(items) do
		if it.locked then nLocked = nLocked + 1 end
	end
	log("store %s: %d items (%d locked)", storeName, #items, nLocked)
	for _, it in ipairs(items) do
		announce(it)
		total = total + 1
		if it.locked then lockedCount = lockedCount + 1 end
	end
end)
log("watching %d buyable items (%d locked, skipped) across %d stores | trigger room>=%d | funds=%s",
	total - lockedCount, lockedCount, visited, RS.trigger, FUNDS)
log("=== END HEALTH CHECK ===")

----------------------------------------------------------------
-- main loop
----------------------------------------------------------------
-- A reason is logged only when it CHANGES; every transition still prints,
-- but ~40 items across 3 stores every 2s would otherwise be unreadable.
local function report(it, reason)
	local code = reason:match("^%S+")
	if VERBOSE or RS.reason[it.key] ~= code then
		log("%-26s %s", it.key, reason)
	end
	RS.reason[it.key] = code
end

task.spawn(function()
	while not RS.stop do
		if not RS.paused then
			RS.cycles = RS.cycles + 1

			local isOpen, mode = ensureOpen()
			if not isOpen then
				-- Log the transition, then go quiet. Repeating this every 2s
				-- produced hundreds of identical lines and buried everything
				-- else in the console.
				if RS.wasOpen ~= false then
					warnf("cycle %d: shop not open (%s) — backing off to %ds until it reopens",
						RS.cycles, mode, CLOSED_BACKOFF)
					RS.wasOpen = false
				elseif RS.cycles % 30 == 0 then
					log("still waiting for the shop (cycle %d, %s)", RS.cycles, mode)
				end
				task.wait(CLOSED_BACKOFF)
			else
				if RS.wasOpen == false then log("shop is open again — resuming") end
				RS.wasOpen = true
				if mode ~= "already" then log("shop reopened via %s", mode) end
				if HIDE_UI and RS.hidden then park(shop) end

				-- "First scan", not "cycle 1". Cycles tick while the shop is
				-- shut, so keying off RS.cycles meant a couple of skipped
				-- cycles at startup turned the join batch into 47 individual
				-- UNLOCKED lines.
				local firstPass = not RS.scanned
				RS.scanned = true
				local fresh = {}

				forEachStore(function(_, items)
					for _, it in ipairs(items) do
						-- One bad item must not kill the loop. Without this a
						-- Fire() on a dead connection or a destroyed instance
						-- ends the thread silently and restocking just stops.
						local ok, err = pcall(function()
							announce(it)

							-- Visible=false is the ONLY client-side lock signal
							-- (see decide()), so false -> true is an unlock.
							-- Polling beats GetPropertyChangedSignal here: store
							-- switching rebuilds Frame.Content and destroys every
							-- entry, so per-instance connections would need
							-- constant re-arming for no gain over this.
							if it.entry.Visible and not RS.unlocked[it.key] then
								RS.unlocked[it.key] = true
								table.insert(fresh, it)
							end

							local reason, room, cost = decide(it)
							report(it, reason)
							if reason == "BUYING" then
								execute(it, room, cost)
							end
						end)
						if not ok then
							RS.failed = RS.failed + 1
							warnf("%s ERROR: %s", it.key, tostring(err))
						end
					end
				end)

				if #fresh > 0 then
					if firstPass then
						log("READY: %d items unlocked at join", #fresh)
						emit("ready", fresh)
					else
						for _, it in ipairs(fresh) do
							log("UNLOCKED: %s", it.key)
						end
						emit("unlock", fresh)
					end
				end
			end

			if RS.cycles % 10 == 0 then
				log("--- cycles=%d buys=%d failed=%d spent=$%.2f ---",
					RS.cycles, RS.buys, RS.failed, RS.spent)
			end
		end
		task.wait(INTERVAL)
	end
	log("stopped")
end)

log("running | dry=%s | funds=%s | trigger room>=%d | _G.RESTOCK",
	tostring(RS.dry), FUNDS, RS.trigger)
