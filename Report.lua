-- Error / blocked-action capture and a copyable report window (/gtb report), like /if report.
-- Loaded first: it defines the shared ns.Log / ns.Safe used by the other files.

local ADDON, ns = ...
local _, class = UnitClass("player")
if class ~= "SHAMAN" then return end

local MAX_LINES = 300
local lines = {}

function ns.Log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    lines[#lines + 1] = date("%H:%M:%S ") .. table.concat(parts, " ")
    while #lines > MAX_LINES do table.remove(lines, 1) end
end

-- Tell the player how to report a problem, each time one happens (the same one repeating
-- within a few seconds is shown once, so a looping error can't flood the chat).
local lastNotice, lastKind
local function Notify(kind)
    local now = GetTime()
    if lastKind == kind and lastNotice and now - lastNotice < 5 then return end
    lastNotice, lastKind = now, kind
    print("|cff33ff99GamepadTotemBar|r: " .. kind .. " Type |cffffff00/gtb report|r, copy the text (Ctrl+C) and send it to report the bug.")
end

function ns.Safe(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        ns.Log("ERROR in " .. what .. ": " .. tostring(err))
        Notify("An error occurred.")
    end
    return ok
end

local function OneLine(s) return (tostring(s or ""):gsub("\n", " | ")) end

local function Context() return "combat=" .. tostring(InCombatLockdown() and true or false) end

-- Lua errors that mention this addon (chains to whatever handler was there first)
local function InstallErrorHandler()
    local previous = geterrorhandler()
    seterrorhandler(function(err)
        if tostring(err):find("GamepadTotemBar", 1, true) then
            ns.Log("LUA ERROR:", OneLine(err), "|", Context())
            Notify("An error occurred.")
        end
        return previous(err)
    end)
end
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    InstallErrorHandler()
end)

-- "An addon tried to use a protected action" (ADDON_ACTION_BLOCKED / FORBIDDEN), ours only
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_ACTION_BLOCKED")
events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
events:SetScript("OnEvent", function(_, event, addon, func)
    if addon ~= ADDON then return end
    ns.Log(event == "ADDON_ACTION_FORBIDDEN" and "FORBIDDEN" or "BLOCKED", tostring(func), "|", Context(),
        "| stack:", OneLine(debugstack and debugstack(3, 8, 0)))
    Notify("The game blocked an action from this addon.")
end)

local function BuildReport()
    local out = {}
    local function add(t) out[#out + 1] = t end
    local version, build = GetBuildInfo()
    add("Gamepad Totem Bar report " .. date("%Y-%m-%d %H:%M"))
    add("Client: " .. tostring(version) .. " (" .. tostring(build) .. ")  Scale: " ..
        tostring(GamepadTotemBarDB and GamepadTotemBarDB.scale))
    add("")
    add("Errors and blocked actions (newest last):")
    if #lines == 0 then add("  (empty)") end
    for _, l in ipairs(lines) do add("  " .. l) end
    return table.concat(out, "\n")
end

local window
local function Show()
    if not window then
        window = CreateFrame("Frame", "GamepadTotemBarReport", UIParent, "BackdropTemplate")
        window:SetSize(620, 400)
        window:SetPoint("CENTER")
        window:SetFrameStrata("DIALOG")
        window:SetMovable(true)
        window:EnableMouse(true)
        window:RegisterForDrag("LeftButton")
        window:SetScript("OnDragStart", window.StartMoving)
        window:SetScript("OnDragStop", window.StopMovingOrSizing)
        window:SetClampedToScreen(true)
        window:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -14)
        title:SetText("Gamepad Totem Bar report")
        local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOP", 0, -38)
        hint:SetText("Click the text, Ctrl+A, Ctrl+C, then paste it where you are reporting the problem.")
        local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", "GamepadTotemBarReportScroll", window, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -58)
        scroll:SetPoint("BOTTOMRIGHT", -38, 18)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject("ChatFontNormal")
        box:SetWidth(550)
        box:SetMaxLetters(0)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); window:Hide() end)
        scroll:SetScrollChild(box)
        window.box = box
    end
    window.box:SetText(BuildReport())
    window:Show()
    window.box:SetFocus()
    window.box:HighlightText()
end

function ns.ShowReport() Show() end
function ns.ClearReport() wipe(lines) end
