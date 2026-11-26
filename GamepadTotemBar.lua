-- Keeps Blizzard's own totem bar visible when the gamepad UI (or Edit Mode) hides it,
-- and adds a bar scale row to the totem bar's HUD Edit Mode settings dialog.
-- Position: use WoW's built-in HUD Edit Mode.
--
-- Rule for this addon: never run Blizzard's own Lua (update functions, click/hover handlers) from
-- addon code and never write to Blizzard's tables. That taints the game's code, which then errors in
-- combat on values the game hides from addons. Only plain frame calls (Show, SetScale, SetTexture...).

local _, class = UnitClass("player")
if class ~= "SHAMAN" then return end

local ADDON, ns = ...
local MIN_SCALE, MAX_SCALE = 0.5, 2.0
local DB, settingScale
local Safe = ns.Safe

-- Where the focus-mode spell tooltip goes: "item" = next to the selected totem, "default" = the game's own
-- tooltip position, "off" = no tooltip
local TIP_MODES = { "item", "default", "off" }
local TIP_LABEL = { item = "Totem", default = "Default", off = "Off" }
local TIP_HELP = {
    item = "Next to the selected totem: the spell tooltip is shown beside the totem you have selected with the gamepad.",
    default = "Default tooltip position: the spell tooltip is shown where the game puts its own tooltips.",
    off = "Off: no spell tooltip is shown in focus mode.",
}
function ns.TooltipMode()
    local m = DB and DB.tooltipMode
    return TIP_LABEL[m] and m or "item"
end

local function BlizzFrame() return _G.MultiCastActionBarFrame or _G.TotemFrame end

---------------------------------------------------------------- spell helpers (also used by Focus.lua)
local CALL_SPELLS = { 66842, 66843, 66844 }   -- Call of the Elements / Ancestors / Spirits
local RECALL_SPELL = 36936                    -- Totemic Recall

local function SpellIcon(id)
    if not id then return nil end
    local ok, tex
    if C_Spell and C_Spell.GetSpellTexture then ok, tex = pcall(C_Spell.GetSpellTexture, id)
    elseif GetSpellTexture then ok, tex = pcall(GetSpellTexture, id) end
    return ok and tex or nil
end

local function KnownSpell(id)
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok then return known end
    end
    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, id)
        if ok then return known end
    end
    return false
end

ns.CALL_SPELLS, ns.RECALL_SPELL, ns.SpellIcon, ns.KnownSpell = CALL_SPELLS, RECALL_SPELL, SpellIcon, KnownSpell

-- The call / recall buttons' icons are only filled in by Blizzard's own update functions, which can't
-- be run from addon code. When one is empty, set its texture ourselves (a plain texture call);
-- Blizzard overwrites it whenever it updates the button itself.
local function FillCallIcon(buttonName, spells)
    local icon = _G[buttonName .. "Icon"]
    local button = _G[buttonName]
    if not icon or not button or icon:GetTexture() then return end
    local id = tonumber(button.spellId) or tonumber(button.spellID) or tonumber(button.spell)
    if not id then
        for _, candidate in ipairs(spells) do
            if KnownSpell(candidate) then id = candidate; break end
        end
    end
    local tex = SpellIcon(id)
    if tex then icon:SetTexture(tex) end
end

---------------------------------------------------------------- keep the bar visible
local function ApplyScale()
    local fr = BlizzFrame()
    if not fr or not DB or InCombatLockdown() then return end
    if math.abs((fr:GetScale() or 1) - DB.scale) > 0.001 then
        settingScale = true
        fr:SetScale(DB.scale)
        settingScale = false
    end
end

local function Restore()
    local fr = BlizzFrame()
    if not fr then return end
    if not fr.__gtbHooked then
        fr.__gtbHooked = true
        hooksecurefunc(fr, "Hide", function(self)
            if not InCombatLockdown() then self:Show() end
        end)
        hooksecurefunc(fr, "SetAlpha", function(self, a)
            -- other addons (e.g. fade-out-of-combat) may pass a secret value; can't compare those
            if type(a) == "number" and not (issecretvalue and issecretvalue(a)) and a == 0 then
                self:SetAlpha(1)
            end
        end)
        -- keep our scale if the game or an Edit Mode layout resets it
        hooksecurefunc(fr, "SetScale", function() if not settingScale then ApplyScale() end end)
    end
    if not InCombatLockdown() then fr:Show() end
    fr:SetAlpha(1)
    ApplyScale()
    if not InCombatLockdown() then
        FillCallIcon("MultiCastSummonSpellButton", CALL_SPELLS)
        FillCallIcon("MultiCastRecallSpellButton", { RECALL_SPELL })
    end
end

-- Dead / ghost darkens the totem buttons (they can't be cast), but the game's own update doesn't reach
-- this bar on death / revive: it stays light after dying, or dark after resurrecting, until a totem is
-- changed. Every icon is tinted by hand (plain texture calls); the game overwrites the colour itself the
-- next time it updates a button (out of mana, out of range, a totem change), so this is only a starting
-- point. Each Call of the ... has its own bar, so every "MultiCast*" frame is covered, not just the
-- first bar.
local DEAD_SHADE = 0.4   -- brightness of icons while dead (1 = normal, lower = darker)

local function TintIcons(frame, dead, seen, depth)
    if not frame or seen[frame] or depth > 8 then return end
    seen[frame] = true
    local function tint(tex)
        if tex and tex.SetVertexColor then
            -- the dead look is the same icon at lower brightness, not desaturated
            local v = dead and DEAD_SHADE or 1
            tex:SetVertexColor(v, v, v)
            if tex.SetDesaturated then tex:SetDesaturated(false) end
        end
    end
    if type(frame.icon) == "table" then tint(frame.icon) end
    if frame.GetRegions then
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                local n = r.GetName and r:GetName() or ""
                if n:find("Icon") then tint(r) end
            end
        end
    end
    if frame.GetChildren then
        for _, c in ipairs({ frame:GetChildren() }) do TintIcons(c, dead, seen, depth + 1) end
    end
end

local function ResetShade(forceDead)
    local dead = forceDead == nil and UnitIsDeadOrGhost("player") or forceDead or false
    local seen = {}
    TintIcons(BlizzFrame(), dead, seen, 0)
    -- the other bars (and their buttons) may not be children of the first bar's frame
    for name, v in pairs(_G) do
        if type(name) == "string" and name:find("^MultiCast") and type(v) == "table"
            and type(v.GetObjectType) == "function" then
            TintIcons(v, dead, seen, 0)
        end
    end
    for i = 1, 12 do TintIcons(_G["SpellFlyoutButton" .. i], dead, seen, 5) end
end

---------------------------------------------------------------- Edit Mode scale row
-- A "Scale" row added to Blizzard's own Edit Mode settings dialog (the one that opens when you
-- click the totem bar in Edit Mode). Shown only while the totem bar is the selected system.
local row

local function DialogIsForBar(dlg, system)
    local fr = BlizzFrame()
    system = system or dlg.attachedToSystem
    return fr and system == fr
end

local function BuildRow(dlg)
    if row then return row end
    row = CreateFrame("Frame", nil, dlg.Settings or dlg)
    row:SetSize(310, 32)
    row.layoutIndex = 1000          -- after Blizzard's own settings in the dialog's layout
    row.leftPadding = 0
    row:Hide()

    local name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
    name:SetPoint("LEFT", 0, 0)
    name:SetWidth(95)
    name:SetJustifyH("LEFT")
    name:SetText("Scale")

    local value = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    value:SetPoint("RIGHT", 0, 0)

    local function Changed(raw)
        local v = math.floor(raw * 20 + 0.5) / 20
        v = math.max(MIN_SCALE, math.min(MAX_SCALE, v))
        value:SetText(math.floor(v * 100 + 0.5) .. "%")
        if DB and v ~= DB.scale then DB.scale = v; ApplyScale() end
    end

    local modern
    if type(MinimalSliderWithSteppersMixin) == "table" and type(MinimalSliderWithSteppersMixin.Event) == "table" then
        local ok, created = pcall(CreateFrame, "Frame", nil, row, "MinimalSliderWithSteppersTemplate")
        if ok and created and created.Init and created.RegisterCallback then modern = created end
    end
    if modern then
        modern:SetSize(160, 32)
        modern:SetPoint("LEFT", 107, 0)
        modern:Init(DB.scale, MIN_SCALE, MAX_SCALE, math.floor((MAX_SCALE - MIN_SCALE) / 0.05 + 0.5), {})
        modern:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, raw) Changed(raw) end)
        row.set = function(v) modern:SetValue(v); value:SetText(math.floor(v * 100 + 0.5) .. "%") end
    else
        local bar = CreateFrame("Slider", nil, row, "OptionsSliderTemplate")
        bar:SetSize(165, 17)
        bar:SetPoint("LEFT", 105, 0)
        bar:SetMinMaxValues(MIN_SCALE, MAX_SCALE)
        bar:SetValueStep(0.05)
        if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
        bar:SetScript("OnValueChanged", function(_, raw) Changed(raw) end)
        row.set = function(v) bar:SetValue(v); value:SetText(math.floor(v * 100 + 0.5) .. "%") end
    end
    return row
end

-- Second row: where the focus-mode tooltip appears
local tipRow
local function BuildTipRow(dlg)
    if tipRow then return tipRow end
    tipRow = CreateFrame("Frame", nil, dlg.Settings or dlg)
    tipRow:SetSize(310, 32)
    tipRow.layoutIndex = 1001
    tipRow.leftPadding = 0
    tipRow:Hide()

    local name = tipRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
    name:SetPoint("LEFT", 0, 0)
    name:SetWidth(95)
    name:SetJustifyH("LEFT")
    name:SetText("Tooltip")

    -- three side-by-side buttons, the active one lit
    local buttons = {}
    local function Refresh()
        local cur = ns.TooltipMode()
        for m, b in pairs(buttons) do
            local fs = b:GetFontString()
            if m == cur then
                b:LockHighlight()
                if fs then fs:SetTextColor(1, 0.82, 0) end
            else
                b:UnlockHighlight()
                if fs then fs:SetTextColor(1, 1, 1) end
            end
        end
    end
    for i, m in ipairs(TIP_MODES) do
        local b = CreateFrame("Button", nil, tipRow, "UIPanelButtonTemplate")
        b:SetSize(68, 24)
        b:SetPoint("LEFT", 105 + (i - 1) * 68, 0)
        b:SetText(TIP_LABEL[m])
        b:SetScript("OnClick", function()
            if DB then DB.tooltipMode = m end
            Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Spell tooltip in focus mode")
            GameTooltip:AddLine(TIP_HELP[m], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        buttons[m] = b
    end
    tipRow.refresh = Refresh
    return tipRow
end

-- The dialog is sized for a system with no settings, so our row would overlap its buttons.
-- Grow the dialog by the row's height and move the button area down by the same amount,
-- and undo that again when the dialog is attached to something else.
local ROW_PAD = 8
local function ButtonsFrame(dlg) return dlg.Buttons or dlg.ButtonContainer end

local function CopyPoints(frame)
    local pts = {}
    for i = 1, frame:GetNumPoints() do pts[i] = { frame:GetPoint(i) } end
    return pts
end

local function ApplyPoints(frame, pts, dy)
    frame:ClearAllPoints()
    for _, p in ipairs(pts) do
        frame:SetPoint(p[1], p[2], p[3], p[4] or 0, (p[5] or 0) + (dy or 0))
    end
end

local function Unfit(dlg)
    local st = dlg.__gtbFit
    if not st then return end
    dlg.__gtbFit = nil
    -- only undo if Blizzard hasn't already re-laid the dialog out itself
    if math.abs(dlg:GetHeight() - st.adjH) < 0.5 then
        dlg:SetHeight(st.origH)
        if st.buttons and st.pts then ApplyPoints(st.buttons, st.pts, 0) end
    end
end

local function Fit(dlg)
    Unfit(dlg)
    local delta = (row and row:GetHeight() or 32) + (tipRow and tipRow:GetHeight() or 32) + ROW_PAD
    local btns = ButtonsFrame(dlg)
    local st = { origH = dlg:GetHeight(), buttons = btns }
    if btns then st.pts = CopyPoints(btns) end
    dlg:SetHeight(st.origH + delta)
    if btns and st.pts then ApplyPoints(btns, st.pts, -delta) end
    st.adjH = dlg:GetHeight()
    dlg.__gtbFit = st
end

local function Relayout(dlg)
    if dlg.Settings and not dlg.Settings:IsShown() then dlg.Settings:Show() end
    dlg.Settings:Layout()
    if dlg.Layout then dlg:Layout() end
    Fit(dlg)
end

local function UpdateRow(dlg, system)
    if not DB or not dlg then return end
    if DialogIsForBar(dlg, system) then
        local r = BuildRow(dlg)
        r.set(DB.scale)
        r:Show()
        local t = BuildTipRow(dlg)
        t.refresh()
        t:Show()
        if dlg.Settings and dlg.Settings.Layout then
            Relayout(dlg)
            -- Blizzard may rebuild its settings after this hook runs, so lay out again shortly
            C_Timer.After(0.15, function()
                if row and row:IsShown() then Safe("relayout", Relayout, dlg) end
            end)
        else
            -- no layout container found: hang the row just under the dialog instead
            r:SetParent(dlg)
            r:ClearAllPoints()
            r:SetPoint("TOP", dlg, "BOTTOM", 0, -6)
            t:SetParent(dlg)
            t:ClearAllPoints()
            t:SetPoint("TOP", r, "BOTTOM", 0, -2)
        end
    else
        Unfit(dlg)
        if tipRow then tipRow:Hide() end
        if row then
            row:Hide()
            if dlg.Settings and dlg.Settings.Layout then
                dlg.Settings:Layout()
                if dlg.Layout then dlg:Layout() end
            end
        end
    end
end

local hooked
local function HookEditMode()
    local dlg = _G.EditModeSystemSettingsDialog
    if hooked or not dlg then return end
    hooked = true
    if dlg.AttachToSystemFrame then
        hooksecurefunc(dlg, "AttachToSystemFrame", function(self, system)
            Safe("UpdateRow(attach)", UpdateRow, self, system)
        end)
    end
    dlg:HookScript("OnShow", function(self) Safe("UpdateRow(show)", UpdateRow, self) end)
    dlg:HookScript("OnHide", function(self) if row then row:Hide() end; if tipRow then tipRow:Hide() end; Unfit(self) end)
    if EditModeManagerFrame then
        EditModeManagerFrame:HookScript("OnShow", Restore)
        EditModeManagerFrame:HookScript("OnHide", function() C_Timer.After(0.5, Restore) end)
    end
end

---------------------------------------------------------------- events
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_ALIVE")
f:RegisterEvent("PLAYER_DEAD")
pcall(f.RegisterEvent, f, "PLAYER_GHOST")   -- only if this client has it
f:RegisterEvent("PLAYER_UNGHOST")
pcall(f.RegisterEvent, f, "GAME_PAD_ACTIVE_CHANGED")
pcall(f.RegisterEvent, f, "GAME_PAD_CONNECTED")
pcall(f.RegisterEvent, f, "GAME_PAD_DISCONNECTED")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            GamepadTotemBarDB = GamepadTotemBarDB or {}
            DB = GamepadTotemBarDB
            -- drop leftovers from older versions of this addon
            DB.mode, DB.locked, DB.hidden, DB.log, DB.pos, DB.defaultBindDone, DB.dbg, DB.lastLog =
                nil, nil, nil, nil, nil, nil, nil, nil
            DB.off, DB.refreshOn, DB.pagestateOn, DB.callPickOff, DB.callBlizzOn, DB.callBlizzOff =
                nil, nil, nil, nil, nil, nil
            DB.scale = DB.scale or 1
            if not TIP_LABEL[DB.tooltipMode] then DB.tooltipMode = "item" end
        end
        Safe("HookEditMode", HookEditMode)   -- Edit Mode may load on demand
        return
    end
    -- restoring the bar comes first and never depends on the Edit Mode code below
    Safe("Restore", Restore)
    Safe("HookEditMode", HookEditMode)
    if event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" or event == "PLAYER_DEAD" or event == "PLAYER_GHOST" then
        Safe("ResetShade", ResetShade)
        -- the game's "can't cast" state lands a little after the event, so redraw again as it settles
        C_Timer.After(0.5, function() Safe("ResetShade", ResetShade) end)
        C_Timer.After(1.5, function() Safe("ResetShade", ResetShade) end)
    end
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, function() Safe("Restore", Restore) end)
        C_Timer.After(3, function() Safe("Restore", Restore) end)
    end
end)
