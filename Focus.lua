-- Gamepad focus mode for Blizzard's totem bar (call button + 4 totem slots).
-- Hold Back/View for half a second (or type /gtb focus).
--   Bar:    D-pad Left/Right move | Up/Down/A open the picker | B/Back leave
--   Picker: D-pad Up/Down move    | A choose | B close | Left/Right move to the next slot, picker follows
--
-- Only the D-pad, A and B are taken while focused; the keyboard is never captured. The picker is drawn
-- by this addon: simulating the mouse on Blizzard's flyout ran its handlers from addon code and tainted
-- the game's totem code. In combat the game blocks changing totems for addons, so focus is out of
-- combat only.

local ADDON, ns = ...
local _, class = UnitClass("player")
if class ~= "SHAMAN" then return end

local Safe = ns.Safe
local PREFIX = "|cff33ff99GamepadTotemBar|r: "
local CALL_SPELLS, RECALL_SPELL = ns.CALL_SPELLS, ns.RECALL_SPELL

local cap, hl, picker, active, level, barIdx, pickIdx, picks
local lastKey, lastT, lastExit = nil, 0, 0
local barItems = {}

local CONFIRM = { PAD1 = true }
local BACK    = { PAD2 = true, PADBACK = true }
local LEFT    = { PADDLEFT = true }
local RIGHT   = { PADDRIGHT = true }
local UP      = { PADDUP = true }
local DOWN    = { PADDDOWN = true }

local function shown(b) return b and b.IsShown and b:IsShown() end

local function ActionButtonOf(slot)
    local i = (slot:GetName() or ""):match("MultiCastSlotButton(%d)")
    return slot.actionButton or (i and _G["MultiCastActionButton" .. i]) or select(1, slot:GetChildren())
end

-- The action of a totem slot on the active Call page. The buttons' own .action field is only updated by
-- Blizzard's code, which isn't run after we switch the page, so it is worked out here (page 1 is
-- actions 133-136, each further page the next 4).
local function SlotAction(item)
    local ab = ActionButtonOf(item)
    local slot = ab and ab:GetID()
    if not slot then return nil end
    local sm = _G.MultiCastSummonSpellButton
    local page = (sm and sm:GetID()) or 1
    if page < 1 or page > 3 then page = 1 end
    return 132 + (page - 1) * 4 + slot
end

local function CollectBar()
    wipe(barItems)
    for _, n in ipairs({ "MultiCastSummonSpellButton", "MultiCastSlotButton1", "MultiCastSlotButton2",
        "MultiCastSlotButton3", "MultiCastSlotButton4", "MultiCastRecallSpellButton" }) do
        local b = _G[n]
        if shown(b) then barItems[#barItems + 1] = b end
    end
    return #barItems > 0
end

---------------------------------------------------------------- highlight and tooltips
local function HideTip() if GameTooltip then GameTooltip:Hide() end end

-- spellId 0 is the "empty slot" choice
local function Tip(owner, spellId)
    if not spellId or not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if spellId == 0 then
        GameTooltip:SetText("Empty slot")
        GameTooltip:AddLine("No totem is placed in this slot.", 1, 1, 1, true)
    else
        pcall(GameTooltip.SetSpellByID, GameTooltip, spellId)
    end
    GameTooltip:Show()
end

-- The spell currently on a bar item, for its tooltip
local function BarSpellId(item)
    local name = item:GetName() or ""
    if name:find("Summon") then return tonumber(item.spellId) or CALL_SPELLS[1] end
    if name:find("Recall") then return RECALL_SPELL end
    local action = SlotAction(item)
    if action then
        local ok, kind, id = pcall(GetActionInfo, action)
        if ok and kind == "spell" then return id end
    end
end

local function Highlight(btn)
    if btn and (btn:GetName() or ""):find("MultiCastSlotButton") then btn = ActionButtonOf(btn) or btn end
    if not hl then
        hl = CreateFrame("Frame", nil, UIParent)
        hl:SetFrameStrata("TOOLTIP")
        hl.t = hl:CreateTexture(nil, "OVERLAY")
        hl.t:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        hl.t:SetBlendMode("ADD")
        hl.t:SetVertexColor(0.2, 1, 0.4)
        hl.t:SetAllPoints()
    end
    if not btn then hl:Hide() return end
    local w, h = btn:GetSize()
    -- match the button's on-screen scale (the bar can be scaled), so the highlight scales with it
    local ratio = btn:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if ratio > 0 then hl:SetScale(ratio) end
    hl:ClearAllPoints()
    hl:SetPoint("CENTER", btn, "CENTER")
    hl:SetSize(w * 1.9, h * 1.9)
    hl:Show()
end

local function Refresh()
    if level == "bar" then
        local item = barItems[barIdx]
        Highlight(item)
        if item then Tip(item, BarSpellId(item)) else HideTip() end
    else
        local pick = picks and picks[pickIdx]
        Highlight(pick)
        if pick then Tip(pick, pick.spellId) else HideTip() end
    end
end

---------------------------------------------------------------- picker
-- Applying a choice. Out of combat only: the game blocks these calls for addons in combat.
local function ApplyPick(btn)
    if btn.isCall then
        -- switching the Call spell = switching the active totem set (action page)
        local sm = _G.MultiCastSummonSpellButton
        if not sm then return end
        local old, new = sm:GetID(), btn.page
        if old == new then return end
        pcall(sm.SetID, sm, new)
        local o, n = _G["MultiCastActionPage" .. tostring(old)], _G["MultiCastActionPage" .. new]
        if o then pcall(o.Hide, o) end
        if n then pcall(n.Show, n) end
        local icon = _G.MultiCastSummonSpellButtonIcon
        local tex = ns.SpellIcon(btn.spellId)
        if icon and tex then icon:SetTexture(tex) end
    else
        local action = SlotAction(btn.forItem)
        if action then pcall(SetMultiCastSpell, action, btn.spellId) end
    end
end

-- What a bar item can be set to, as the game reports it
local function Choices(item)
    local list = {}
    if (item:GetName() or ""):find("Summon") then
        for page, id in ipairs(CALL_SPELLS) do
            if ns.KnownSpell(id) then list[#list + 1] = { id = id, page = page, call = true } end
        end
    else
        local ab = ActionButtonOf(item)
        local slot = ab and ab:GetID()
        if slot then
            local ok, a, b, c, d, e, f, g, h = pcall(GetMultiCastTotemSpells, slot)
            if ok then for _, id in ipairs({ a, b, c, d, e, f, g, h }) do list[#list + 1] = { id = id } end end
            -- like Blizzard's flyout: the slot can also be left empty
            list[#list + 1] = { id = 0, empty = true }
        end
    end
    return list
end

-- A column above the item, nearest choice at the bottom (like Blizzard's flyout)
local function BuildPicker(item)
    local list = Choices(item)
    if #list == 0 then return false end
    if not picker then
        picker = CreateFrame("Frame", "GamepadTotemBarPicker", UIParent, "BackdropTemplate")
        picker:SetFrameStrata("DIALOG")
        picker:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        picker:SetBackdropColor(0, 0, 0, 0.85)
        picker.buttons = {}
    end
    for _, b in ipairs(picker.buttons) do b:Hide() end
    picks = {}
    local size, gap = 32, 4
    for i, entry in ipairs(list) do
        local b = picker.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, picker)
            b:SetSize(size, size)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b:SetScript("OnEnter", function(self) Tip(self, self.spellId) end)
            b:SetScript("OnLeave", HideTip)
            picker.buttons[i] = b
        end
        b.spellId, b.page, b.isCall, b.forItem = entry.id, entry.page, entry.call, item
        local tex = entry.empty and "Interface/Buttons/UI-GroupLoot-Pass-Up" or ns.SpellIcon(entry.id)
        b.icon:SetTexture(tex or "Interface/Icons/INV_Misc_QuestionMark")
        b:ClearAllPoints()
        b:SetPoint("BOTTOM", picker, "BOTTOM", 0, 6 + (i - 1) * (size + gap))
        b:Show()
        picks[#picks + 1] = b
    end
    picker:SetSize(size + 12, 12 + #list * size + (#list - 1) * gap)
    local ratio = item:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if ratio > 0 then picker:SetScale(ratio) end
    picker:ClearAllPoints()
    picker:SetPoint("BOTTOM", item, "TOP", 0, 10)
    picker:Show()
    return true
end

local function ClosePicker()
    HideTip()
    if picker then picker:Hide() end
    picks = nil
end

local function OpenPicker()
    local b = barItems[barIdx]
    -- the recall button has no choices
    if not b or (b:GetName() or ""):find("Recall") then return end
    ClosePicker()
    if BuildPicker(b) then level = "pick"; pickIdx = 1; Refresh() end
end

---------------------------------------------------------------- entering / leaving / input
local function Exit(key)
    if not active then return end
    -- the View press that leaves must not count as the first tap of a new double-tap
    if key == "PADBACK" then lastExit = GetTime() end
    active = false
    ClosePicker()
    Highlight(nil)
    if cap then cap:Hide() end
end

local function Handle(key)
    if not active then return end
    -- the same press can arrive as both a key and a gamepad-button event
    local t = GetTime()
    if key == lastKey and t - lastT < 0.05 then return end
    lastKey, lastT = key, t

    if level == "bar" then
        if LEFT[key] then barIdx = (barIdx - 2) % #barItems + 1
        elseif RIGHT[key] then barIdx = barIdx % #barItems + 1
        elseif CONFIRM[key] or UP[key] or DOWN[key] then OpenPicker() return
        elseif BACK[key] then Exit(key) return end
    else
        if not (picker and picker:IsShown() and picks and #picks > 0) then level = "bar"; Refresh() return end
        if pickIdx > #picks then pickIdx = #picks end
        -- the picker is a column, nearest choice first: Up goes further up the column
        if UP[key] then pickIdx = pickIdx % #picks + 1
        elseif DOWN[key] then pickIdx = (pickIdx - 2) % #picks + 1
        elseif LEFT[key] or RIGHT[key] then
            -- keep moving along the bar; the picker follows to the next slot (not the recall button)
            if LEFT[key] then barIdx = (barIdx - 2) % #barItems + 1 else barIdx = barIdx % #barItems + 1 end
            ClosePicker()
            level = "bar"
            OpenPicker()
        elseif CONFIRM[key] then
            ApplyPick(picks[pickIdx])
            ClosePicker()
            level = "bar"
            C_Timer.After(0.1, function() if active then CollectBar(); Refresh() end end)
            return
        elseif BACK[key] then ClosePicker(); level = "bar" end
    end
    Refresh()
end

-- The input-capture frame is created the first time focus is used, not at login: a frame that
-- listens for gamepad buttons makes the game's gamepad input code handle it, and doing that at login
-- ran that code tainted by this addon.
local function EnsureCap()
    if cap then return end
    cap = CreateFrame("Frame", "GamepadTotemBarFocusCapture", UIParent)
    cap:SetAllPoints(UIParent)
    cap:SetFrameStrata("DIALOG")
    cap:EnableKeyboard(false)   -- the keyboard is never captured or blocked: this is gamepad-only
    if cap.EnableGamePadButton then cap:EnableGamePadButton(true) end
    cap:SetPropagateKeyboardInput(true)
    -- Only the D-pad, A and B are taken. Every other button, and Back (which also reaches other
    -- addons such as ImprovedForever's double-press), passes through to the game.
    cap:SetScript("OnGamePadButtonDown", function(self, button)
        local mine = LEFT[button] or RIGHT[button] or UP[button] or DOWN[button] or CONFIRM[button]
            or (BACK[button] and button ~= "PADBACK")
        self:SetPropagateKeyboardInput(not mine)
        Safe("OnGamePadButtonDown", Handle, button)
    end)
    cap:Hide()
end

local function Enter()
    if InCombatLockdown() then return end
    if not CollectBar() then print(PREFIX .. "Blizzard totem bar isn't visible.") return end
    active, level = true, "bar"
    barIdx = #barItems >= 2 and 2 or 1
    EnsureCap()
    cap:Show()
    if not Safe("Enter", Refresh) then active = false; cap:Hide(); Highlight(nil) end
end

-- In combat the game blocks changing totems (and this frame's input settings) for addons: leave focus.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:SetScript("OnEvent", function() Exit() end)

---------------------------------------------------------------- the Back / View button
-- Hold View for HOLD seconds to toggle totem focus from anywhere. The game owns the bare View press
-- (its own focus cycle) and doesn't tell addons about releases, so the button is read straight from the
-- controller state (C_GamePad.GetDeviceMappedState, read-only) ten times a second. A short press still
-- goes to the game untouched; leaving totem focus with a View press is handled by the capture frame.
local HOLD, TICK = 0.5, 0.1
local downSince, fired, backSlot

local function ToggleFocus()
    if active then Exit() return end
    if InCombatLockdown() then
        print(PREFIX .. "can't focus the totem bar in combat (the game doesn't let addons change totems in combat).")
        return
    end
    Enter()
    -- the game's own focus cursor would still be showing from the press: hide it while ours is active
    C_Timer.After(0.1, function()
        local sn = _G.SmartNavigation
        if active and type(sn) == "table" and type(sn.HideCursor) == "function" then pcall(sn.HideCursor, sn) end
    end)
end

local function ViewIsDown()
    if not (C_GamePad and C_GamePad.GetActiveDeviceID and C_GamePad.GetDeviceMappedState) then return false end
    local id = C_GamePad.GetActiveDeviceID()
    if not id then return false end
    if not backSlot then
        local idx = C_GamePad.ButtonBindingToIndex and C_GamePad.ButtonBindingToIndex("PADBACK")
        if not idx then return false end
        backSlot = idx + 1   -- the state's button table is 1-based
    end
    local st = C_GamePad.GetDeviceMappedState(id)
    local btns = st and st.buttons
    return btns and btns[backSlot] and true or false
end

local function Poll()
    local t = GetTime()
    if not ViewIsDown() then downSince, fired = nil, false return end
    if not downSince then
        downSince = t
        -- a hold that began with totem focus on (that press already left it) must not re-enter
        fired = active or (t - lastExit < 0.3)
        return
    end
    if not fired and t - downSince >= HOLD then
        fired = true
        Safe("ToggleFocus", ToggleFocus)
    end
end

-- the game also says this when it has nothing to focus; hide it, it's no longer our cue
local function OnGameMessage(msg)
    if type(msg) ~= "string" or not msg:lower():find("frame to focus", 1, true) then return end
    if UIErrorsFrame then UIErrorsFrame:Clear() end
end

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("ADDON_LOADED")
loadFrame:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    C_Timer.NewTicker(TICK, function() Safe("Poll", Poll) end)
    if UIErrorsFrame then hooksecurefunc(UIErrorsFrame, "AddMessage", function(_, msg) OnGameMessage(msg) end) end
    local msgFrame = CreateFrame("Frame")
    msgFrame:RegisterEvent("UI_ERROR_MESSAGE")
    msgFrame:SetScript("OnEvent", function(_, _, ...)
        for i = 1, select("#", ...) do OnGameMessage((select(i, ...))) end
    end)
end)

---------------------------------------------------------------- slash command
SLASH_GAMEPADTOTEMBAR1 = "/gtb"
SlashCmdList.GAMEPADTOTEMBAR = function(msg)
    local cmd = (msg or ""):match("^(%S*)"):lower()
    if cmd == "focus" then
        ToggleFocus()
    elseif cmd == "report" then ns.ShowReport()
    elseif cmd == "clearreport" then ns.ClearReport(); print(PREFIX .. "report log cleared.")
    else
        print(PREFIX .. "/gtb focus | report | clearreport")
    end
end
