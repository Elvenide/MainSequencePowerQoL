-- Eqol Feature: Power Overview
-- 1. Customizable hotkey (default P, configurable in Settings -> Controls) to toggle Power Overview
--    inside space stations.
-- 2. Summary header progress bars (Production, Consumption, and Power Satisfaction) in WBP_PowerOverview.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "PowerOverview",
    DisplayName = "Station Power Overview",
    Description = "Hotkey (default P) for station Power Overview plus summary production/consumption bars.",
}

local DEFAULT_KEY = "P"
local MAPPING_NAME = "Eqol_PowerOverview"

local PATHS = {
    PowerOverviewClass = "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C",
    ProgressBarClass   = "/Game/Blueprints/Widgets/Basic/WBP_ProgressBar.WBP_ProgressBar_C",
    TextClass          = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    IMCSystem          = "/Game/Data/Input/IMC_System.IMC_System",
    IAEscape           = "/Game/Data/Input/Common/IA_Escape.IA_Escape",
}

-- Exact FLinearColor values extracted from WBP_PowerGrid
local STATUS_COLORS = {
    Green = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Amber = { R = 0.8917,  G = 0.6242, B = 0.0,     A = 1.0 },
    Red   = { R = 0.5177,  G = 0.0,    B = 0.04122, A = 1.0 },
}

local UnmappedPFromSystem = false
local AllHooksLogged = false

-- Per-widget state keyed by UObject memory address to prevent duplicate UI injection
local InjectedOverviews = {}

--------------------------------------------------------------------------------
-- Power Overview Hotkey (Space Stations)
--------------------------------------------------------------------------------

local function ResolvePlayerFrameAndGrid(playerObj)
    if not Core.IsValidObj(playerObj) then return nil, nil end

    local candidates = {}
    local okFrame, walkFrame = pcall(function() return playerObj:GetFrame() end)
    if okFrame and Core.IsValidObj(walkFrame) then
        table.insert(candidates, walkFrame)
    end

    for _, frame in ipairs(candidates) do
        local pg = nil
        if frame.GetPowerGrid then
            local okPG, resPG = pcall(function() return frame:GetPowerGrid() end)
            if okPG and Core.IsValidObj(resPG) then
                pg = resPG
            end
        end
        if not Core.IsValidObj(pg) and Core.IsValidObj(frame.PowerGrid) then
            pg = frame.PowerGrid
        end
        if Core.IsValidObj(pg) then
            return frame, pg
        end
    end

    return nil, nil
end

local function TogglePowerOverview()
    if not Core.IsFeatureEnabled("PowerOverview") then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then
        Core.Log("TogglePowerOverview: no PlayerController")
        return
    end

    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if not Core.IsValidObj(widgetSub) then
        Core.Log("TogglePowerOverview: no WidgetSubsystem")
        return
    end

    if Core.IsAnyTextInputFocused() then
        return
    end

    local powerOverviewClass = Core.FindOrLoadClass(PATHS.PowerOverviewClass)
    if Core.IsValidObj(powerOverviewClass) then
        Core.EnsureAllHooks()
    end

    -- Close if WBP_PowerOverview is already the active window
    local curWin = widgetSub.CurrentWindow
    if Core.IsValidObj(curWin) then
        if Core.IsValidObj(powerOverviewClass) and curWin:IsA(powerOverviewClass) then
            pcall(function() widgetSub:CloseCurrentWindow() end)
        else
            Core.Log("TogglePowerOverview: another window is active")
        end
        return
    end

    -- Do not trigger while navigating menus or rebinding keys
    if Core.IsSelectingAnyRegisteredKeybind()
        or Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
    then
        Core.Log("TogglePowerOverview: blocked by visible menu/keybind selector")
        return
    end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then
        Core.Log("TogglePowerOverview: no PlayerObject")
        return
    end

    -- Prevent opening Power Management while on a ship (only supported on stations)
    local inStation = StationData.IsPlayerInStation(pc)
    if not inStation then
        Core.Log("TogglePowerOverview: blocked (player is not on a station)")
        return
    end

    if not pc.CharacterInputEnabled then
        Core.Log("TogglePowerOverview: blocked (CharacterInputEnabled=false)")
        return
    end

    local frame, powerGrid = ResolvePlayerFrameAndGrid(playerObj)
    if not Core.IsValidObj(frame) or not Core.IsValidObj(powerGrid) or not Core.IsValidObj(powerOverviewClass) then
        Core.Log("TogglePowerOverview: missing frame, powerGrid, or WBP_PowerOverview class")
        return
    end

    local gridOwner = frame
    local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
    if Core.IsValidObj(worldSub) then
        local okOwner, obj = pcall(function() return worldSub:GetObject(powerGrid.ParentID) end)
        if okOwner and Core.IsValidObj(obj) then
            gridOwner = obj
        end
    end

    local okShow, errShow = pcall(function()
        widgetSub:ShowWindow(powerOverviewClass, gridOwner, nil, false)
    end)
    if not okShow then
        Core.Log("TogglePowerOverview: ShowWindow failed: " .. tostring(errShow))
        pcall(function()
            pc:ToggleWidget(powerOverviewClass, gridOwner, nil)
        end)
    end
end

local function SyncIMCSystemBinding(forceRebuild)
    local imcSystem = Core.FindOrLoadClass(PATHS.IMCSystem)
    local iaEscape = Core.FindOrLoadClass(PATHS.IAEscape)
    if not Core.IsValidObj(imcSystem) or not Core.IsValidObj(iaEscape) then
        return
    end

    local keyP = { KeyName = FName("P") }
    local changed = false

    if Core.IsFeatureEnabled("PowerOverview") and Core.Config.PowerOverviewKey == "P" then
        if not UnmappedPFromSystem or forceRebuild then
            local wasUnmapped = UnmappedPFromSystem
            local okUnmap = pcall(function() imcSystem:UnmapKey(iaEscape, keyP) end)
            if okUnmap then
                UnmappedPFromSystem = true
                if not wasUnmapped or forceRebuild then
                    changed = true
                end
                if not wasUnmapped then
                    Core.Log("Unmapped P from IMC_System IA_Escape")
                end
            end
        end
    elseif UnmappedPFromSystem then
        local okMap = pcall(function() imcSystem:MapKey(iaEscape, keyP) end)
        if okMap then
            UnmappedPFromSystem = false
            changed = true
        end
    end

    if changed then
        local eiLib = Core.GetCDO(Core.PATHS.EnhancedInputLibCDO)
        if Core.IsValidObj(eiLib) then
            pcall(function() eiLib:RequestRebuildControlMappingsUsingContext(imcSystem, true) end)
        end
    end
end

--------------------------------------------------------------------------------
-- Power Overview Header Progress Bars
--------------------------------------------------------------------------------

local function CopyTextStyle(dstText, srcText)
    if not Core.IsValidObj(dstText) or not Core.IsValidObj(srcText) then return end
    pcall(function()
        dstText.Size = srcText.Size
        dstText.Strength = srcText.Strength
        dstText.bOverrideColour = srcText.bOverrideColour
        dstText.Colour = srcText.Colour
        dstText.Justification = srcText.Justification
        if dstText.SetSize then dstText:SetSize(srcText.Size) end
        if dstText.SetColour then dstText:SetColour(srcText.Colour) end
        if dstText.SetJustification then dstText:SetJustification(srcText.Justification) end
        if dstText.PreConstruct then dstText:PreConstruct(false) end
        if Core.IsValidObj(srcText.TextBlock) and Core.IsValidObj(dstText.TextBlock) then
            dstText.TextBlock:SetColorAndOpacity(srcText.TextBlock.ColorAndOpacity)
        end
    end)
end

local function CreateSizedProgressBar(overviewWidget, owningPC, outer)
    local sizeBox = Core.CreateRawWidget(Core.PATHS.SizeBoxClass, outer)
    local bar = Core.CreateUserWidget(PATHS.ProgressBarClass, overviewWidget, owningPC)
    if not Core.IsValidObj(sizeBox) or not Core.IsValidObj(bar) then
        return nil, nil
    end

    pcall(function() sizeBox:SetHeightOverride(14.0) end)
    sizeBox:AddChild(bar)
    return sizeBox, bar
end

local function UpdateProgressBarWidget(barWidget, ratio, fillColor)
    if not Core.IsValidObj(barWidget) then return end
    local clamped = Core.Clamp(ratio, 0.0, 1.0)
    local pb = barWidget.ProgressBar
    if Core.IsValidObj(pb) then
        pcall(function()
            pb:SetPercent(clamped)
            pb:SetFillColorAndOpacity(fillColor)
        end)
    elseif barWidget.SetProgress then
        pcall(function() barWidget:SetProgress(clamped, 1.0) end)
    end
end

local function EnsureOverviewBars(overviewWidget)
    if not Core.IsValidObj(overviewWidget) then return nil end

    local addr = overviewWidget:GetAddress()
    local state = InjectedOverviews[addr]
    if state and Core.IsValidObj(state.Bar1) and Core.IsValidObj(state.Bar2) and Core.IsValidObj(state.Bar3) then
        return state
    end

    local totalProdText = overviewWidget.TotalProductionText
    local totalConsText = overviewWidget.TotalConsumptionText
    local solarValueText = overviewWidget.SolarEfficiencyText
    if not Core.IsValidObj(totalProdText) or not Core.IsValidObj(totalConsText) or not Core.IsValidObj(solarValueText) then
        return nil
    end

    local prodHBox = totalProdText:GetParent()
    local consHBox = totalConsText:GetParent()
    local solarHBox = solarValueText:GetParent()
    if not Core.IsValidObj(prodHBox) or not Core.IsValidObj(consHBox) or not Core.IsValidObj(solarHBox) then
        return nil
    end

    local prodVBox = prodHBox:GetParent()
    local consVBox = consHBox:GetParent()
    if not Core.IsValidObj(prodVBox) or not Core.IsValidObj(consVBox) then
        return nil
    end

    local gridPanel = prodVBox:GetParent()
    if not Core.IsValidObj(gridPanel) then
        return nil
    end

    local outer = Core.GetWidgetOuter(overviewWidget)
    local okPC, owningPC = pcall(function() return overviewWidget:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    -- Create and validate ALL summary bar widgets before attaching any to parent panels
    -- so a partial construction failure never leaves orphaned duplicate bars behind.
    local bar1Box, bar1 = CreateSizedProgressBar(overviewWidget, pc, outer)
    local bar2Box, bar2 = CreateSizedProgressBar(overviewWidget, pc, outer)
    local satVBox = Core.CreateRawWidget(Core.PATHS.VerticalBoxClass, outer)
    local satHeaderBox = Core.CreateRawWidget(Core.PATHS.HorizontalBoxClass, outer)
    local satLabelText = Core.CreateUserWidget(PATHS.TextClass, overviewWidget, pc)
    local satValueText = Core.CreateUserWidget(PATHS.TextClass, overviewWidget, pc)
    local bar3Box, bar3 = CreateSizedProgressBar(overviewWidget, pc, outer)
    if not (Core.IsValidObj(bar1Box) and Core.IsValidObj(bar2Box)
        and Core.IsValidObj(satVBox) and Core.IsValidObj(satHeaderBox)
        and Core.IsValidObj(satLabelText) and Core.IsValidObj(satValueText)
        and Core.IsValidObj(bar3Box))
    then
        return nil
    end

    -- Bar 1: Production Current / Max
    local bar1Slot = prodVBox:AddChildToVerticalBox(bar1Box)
    if Core.IsValidObj(bar1Slot) then
        pcall(function()
            bar1Slot:SetPadding({ Left = 32.0, Top = 8.0, Right = 32.0, Bottom = 4.0 })
            bar1Slot:SetHorizontalAlignment(0) -- HAlign_Fill
        end)
    end

    -- Bar 2: Consumption Current / Max
    local bar2Slot = consVBox:AddChildToVerticalBox(bar2Box)
    if Core.IsValidObj(bar2Slot) then
        pcall(function()
            bar2Slot:SetPadding({ Left = 32.0, Top = 8.0, Right = 32.0, Bottom = 4.0 })
            bar2Slot:SetHorizontalAlignment(0) -- HAlign_Fill
        end)
    end

    -- Bar 3: Power Satisfaction (Production / Consumption)

    local okSolarLabel, solarLabelText = pcall(function() return solarHBox:GetChildAt(0) end)
    if okSolarLabel and Core.IsValidObj(solarLabelText) then
        CopyTextStyle(satLabelText, solarLabelText)
    end
    CopyTextStyle(satValueText, solarValueText)

    pcall(function()
        satLabelText:SetText(Core.MakeText("Power Satisfaction"))
        satValueText:SetText(Core.MakeText("0%"))
    end)

    local lblHSlot = satHeaderBox:AddChildToHorizontalBox(satLabelText)
    if Core.IsValidObj(lblHSlot) then
        pcall(function()
            lblHSlot:SetSize({ Value = 1.0, SizeRule = 1 }) -- Fill
            lblHSlot:SetVerticalAlignment(2) -- VAlign_Center
        end)
    end

    local valHSlot = satHeaderBox:AddChildToHorizontalBox(satValueText)
    if Core.IsValidObj(valHSlot) then
        pcall(function()
            valHSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            valHSlot:SetSize({ Value = 1.0, SizeRule = 0 }) -- Automatic
            valHSlot:SetVerticalAlignment(2) -- VAlign_Center
        end)
    end

    local hdrVSlot = satVBox:AddChildToVerticalBox(satHeaderBox)
    if Core.IsValidObj(hdrVSlot) then
        pcall(function() hdrVSlot:SetHorizontalAlignment(0) end)
    end

    local bar3Slot = satVBox:AddChildToVerticalBox(bar3Box)
    if Core.IsValidObj(bar3Slot) then
        pcall(function()
            bar3Slot:SetPadding({ Left = 0.0, Top = 6.0, Right = 0.0, Bottom = 0.0 })
            bar3Slot:SetHorizontalAlignment(0)
        end)
    end

    local targetRow = 1
    local targetCol = 2
    local cellPadding = { Left = 32.0, Top = 0.0, Right = 32.0, Bottom = 8.0 }

    local layoutLib = Core.GetCDO(Core.PATHS.WidgetLayoutLibCDO)
    local solarSlot = Core.IsValidObj(layoutLib) and select(2, pcall(function() return layoutLib:SlotAsGridSlot(solarHBox) end)) or nil
    if not Core.IsValidObj(solarSlot) then solarSlot = solarHBox.Slot end
    if Core.IsValidObj(solarSlot) then
        pcall(function()
            targetRow = solarSlot.Row
            cellPadding = solarSlot.Padding
            solarSlot:SetVerticalAlignment(1) -- VAlign_Top
        end)
    end

    local consSlot = Core.IsValidObj(layoutLib) and select(2, pcall(function() return layoutLib:SlotAsGridSlot(consVBox) end)) or nil
    if not Core.IsValidObj(consSlot) then consSlot = consVBox.Slot end
    if Core.IsValidObj(consSlot) then
        pcall(function() targetCol = consSlot.Column end)
    end

    local satGridSlot = gridPanel:AddChildToGrid(satVBox, targetRow, targetCol)
    if Core.IsValidObj(satGridSlot) then
        pcall(function()
            satGridSlot:SetPadding(cellPadding)
            satGridSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            satGridSlot:SetVerticalAlignment(1)   -- VAlign_Top
        end)
    end

    state = {
        Overview = overviewWidget,
        Bar1Box = bar1Box,
        Bar2Box = bar2Box,
        SatVBox = satVBox,
        Bar1 = bar1,
        Bar2 = bar2,
        Bar3 = bar3,
        SatValueText = satValueText,
    }
    InjectedOverviews[addr] = state
    return state
end

local function SetOverviewBarsVisible(state, visible)
    if not state then return end
    local vis = visible and 0 or 1
    if Core.IsValidObj(state.Bar1Box) then pcall(function() state.Bar1Box:SetVisibility(vis) end) end
    if Core.IsValidObj(state.Bar2Box) then pcall(function() state.Bar2Box:SetVisibility(vis) end) end
    if Core.IsValidObj(state.SatVBox) then pcall(function() state.SatVBox:SetVisibility(vis) end) end
end

local function UpdateOverviewBars(overviewWidget)
    if not Core.IsValidObj(overviewWidget) then return end
    if not Core.IsFeatureEnabled("PowerOverview") then
        local existing = InjectedOverviews[overviewWidget:GetAddress()]
        if existing then SetOverviewBarsVisible(existing, false) end
        return
    end

    local state = EnsureOverviewBars(overviewWidget)
    if not state then return end
    SetOverviewBarsVisible(state, true)

    local frame = overviewWidget.Frame
    if not Core.IsValidObj(frame) then return end

    local pg = frame.PowerGrid
    if not Core.IsValidObj(pg) and frame.GetPowerGrid then
        local okPG, resPG = pcall(function() return frame:GetPowerGrid() end)
        if okPG then pg = resPG end
    end
    if not Core.IsValidObj(pg) then return end

    local curProd = Core.GetFPFloat(pg.DisplayProduction)
    local maxProd = Core.GetFPFloat(pg.MaxProduction)
    local curCons = Core.GetFPFloat(pg.DisplayConsumption)
    local maxCons = Core.GetFPFloat(pg.MaxConsumption)

    -- Bar 1: Current / Max Production (Static Green)
    local prodRatio = (maxProd > 0.0001) and (curProd / maxProd) or 0.0
    UpdateProgressBarWidget(state.Bar1, prodRatio, STATUS_COLORS.Green)

    -- Bar 2: Current / Max Consumption (Static Green)
    local consRatio = (maxCons > 0.0001) and (curCons / maxCons) or 0.0
    UpdateProgressBarWidget(state.Bar2, consRatio, STATUS_COLORS.Green)

    -- Bar 3: Production out of Consumption (Dynamic Status Colors)
    local satRatio
    local satColor
    if curCons <= 0.0001 then
        if curProd > 0.0001 then
            satRatio = 1.0
            satColor = STATUS_COLORS.Green
        else
            satRatio = 0.0
            satColor = STATUS_COLORS.Red
        end
    else
        satRatio = curProd / curCons
        if satRatio >= 0.9999 then
            satColor = STATUS_COLORS.Green
        elseif satRatio >= 0.5 then
            satColor = STATUS_COLORS.Amber
        else
            satColor = STATUS_COLORS.Red
        end
    end

    UpdateProgressBarWidget(state.Bar3, satRatio, satColor)
    if Core.IsValidObj(state.SatValueText) then
        local pctInt = math.floor(satRatio * 100.0 + 0.5)
        pcall(function()
            state.SatValueText:SetText(Core.MakeText(string.format("%d%%", pctInt)))
        end)
    end
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_PowerOverview_C = function(widget)
        UpdateOverviewBars(widget)
    end,
}

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey              = "PowerOverviewKey",
        DefaultKey             = DEFAULT_KEY,
        MappingName            = MAPPING_NAME,
        Label                  = "Power Overview",
        AllowNativeWindowClass = PATHS.PowerOverviewClass,
        OnPress                = TogglePowerOverview,
        OnChanged              = function()
            SyncIMCSystemBinding(false)
        end,
    })
    SyncIMCSystemBinding(false)
end

function Feature.RegisterHooks()
    local r1 = Core.TryRegisterHook(
        "PowerOverview_SetupWidget",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:SetupWidget",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    local r2 = Core.TryRegisterHook(
        "PowerOverview_RefreshTotals",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:RefreshTotals",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    local r3 = Core.TryRegisterHook(
        "PowerOverview_Refresh",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:Refresh",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    if r1 and r2 and r3 and not AllHooksLogged then
        AllHooksLogged = true
        SyncIMCSystemBinding(false)
        Core.Log("All PowerOverview Blueprint hooks registered")
    end
end

function Feature.OnToggle(enabled)
    SyncIMCSystemBinding(true)
    for _, st in pairs(InjectedOverviews) do
        if st then
            SetOverviewBarsVisible(st, enabled)
            if enabled and Core.IsValidObj(st.Overview) then
                UpdateOverviewBars(st.Overview)
            end
        end
    end
end

function Feature.OnClientRestart()
    SyncIMCSystemBinding(true)
    ExecuteInGameThreadWithDelay(500, function() SyncIMCSystemBinding(true) end)
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedOverviews) do
        if not Core.IsValidObj(st.Bar1) then
            InjectedOverviews[addr] = nil
        end
    end
end

return Feature
