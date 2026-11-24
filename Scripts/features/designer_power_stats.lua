-- Eqol Feature: Designer Power Generation & Consumption Stats
-- Displays total Power Generation and Power Consumption alongside Mass/Hull/Dimensions
-- in Ship Designer and Station Designer, matching the exact native column styling.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "DesignerPowerStats",
    DisplayName = "Ship Designer Power Stats",
    Description = "Displays live power generation, consumption, and balance stats inside the Ship Designer.",
}

local PATHS = {
    WBPTextClass     = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    VerticalBoxClass = "/Script/UMG.VerticalBox",
    BorderClass      = "/Script/UMG.Border",
    SizeBoxClass     = "/Script/UMG.SizeBox",
    DesignerHUDClass = "/Game/Blueprints/Widgets/HUDs/Designer/WBP_DesignerHUD.WBP_DesignerHUD_C",
    BPCDesignerClass = "/Game/Blueprints/Player/Designer/BPC_Designer.BPC_Designer_C",
    SolarPanelCDO    = "/Game/Blueprints/Machines/BPO_SolarPanel.Default__BPO_SolarPanel_C",
}

local COLORS = {
    GoldAccent = { R = 0.94, G = 0.65, B = 0.05, A = 1.0 },
    WhiteValue = { R = 0.95, G = 0.96, B = 0.98, A = 1.0 },
    RedValue   = { R = 1.00, G = 0.35, B = 0.35, A = 1.0 },
    GreenValue = { R = 0.30, G = 0.90, B = 0.40, A = 1.0 },
}

local InjectedDesigners = {}       -- hudAddr -> { Hud, PowerText, PowerLabel, LabelColor, SolarEfficiency, SolarEffSource, InitialLoadedGen, InitialLoadedCons, ResetBaseline, LastPendingSig, LastStepDiag }
local ActorClassPowerCache = {}    -- actorClsAddr -> { info = table, clsName = string }
local ActorBlockInfoCache = {}     -- actorAddr -> { info = table, clsAddr = number, clsName = string }
local RefreshScheduled = false
local RefreshDesignerPowerStats    -- forward declaration

local function FormatPower(kw)
    local val = tonumber(kw) or 0.0
    if math.abs(val) >= 1000.0 then
        return string.format("%.1f MW", val / 1000.0)
    end
    return string.format("%.0f kW", val)
end

local function ReadFPNum(val)
    if type(val) == "number" then return val end
    if val ~= nil then return Core.GetFPFloat(val) end
    return 0.0
end

local function UnwrapStruct(val)
    if val == nil then return nil end
    local ok, inner = pcall(function()
        if type(val.get) == "function" then
            return val:get()
        end
        return val
    end)
    if ok and inner ~= nil then return inner end
    return val
end

local function SafeObjName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return "?"
end

local function GetCDOFromUClass(uclass)
    uclass = Core.UnwrapArrayElem(uclass)
    if not Core.IsValidObj(uclass) then return nil end

    if uclass.GetDefaultObject then
        local okDef, defObj = pcall(function() return uclass:GetDefaultObject() end)
        if okDef and Core.IsValidObj(defObj) then
            return defObj
        end
    end

    local ok, full = pcall(function() return uclass:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    local objPath = full:match("^%S+ (.+)$") or full
    local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
    if not pkg or not clsName then return nil end
    if string.sub(clsName, 1, 9) == "Default__" then
        return Core.GetCDO(objPath)
    end
    return Core.GetCDO(pkg .. ".Default__" .. clsName)
end

local function HasClassOrName(obj, classPath, nameSubstrings, excludeSubstring)
    if not Core.IsValidObj(obj) then return false end
    if classPath then
        local okIsA, isA = pcall(function() return obj:IsA(classPath) end)
        if okIsA and isA == true then
            return true
        end
    end
    local okCls, clsName = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if not okCls or type(clsName) ~= "string" then
        return false
    end
    if excludeSubstring and string.find(clsName, excludeSubstring, 1, true) then
        return false
    end
    if nameSubstrings then
        for _, sub in ipairs(nameSubstrings) do
            if string.find(clsName, sub, 1, true) then
                return true
            end
        end
    end
    return false
end

local function IsBuildingBlockClass(obj)
    if not Core.IsValidObj(obj) then return false end
    return HasClassOrName(obj, "/Script/MainSequence.BuildingBlockObject", { "BuildingBlock" }, nil)
        or HasClassOrName(obj, "/Script/MainSequence.BuildingBlock", nil, nil)
end

local function IsMachineObject(obj)
    if not Core.IsValidObj(obj) then return false end
    if IsBuildingBlockClass(obj) then return false end
    if HasClassOrName(obj, "/Script/MainSequence.MachineObject", { "Machine", "SolarPanel", "Reactor", "Generator" }, nil) then
        return true
    end
    local okFn, hasFn = pcall(function()
        return type(obj.GetDisplayMaxPower) == "function" or type(obj.GetDisplayPower) == "function"
    end)
    return okFn and hasFn == true
end

local function IsSolarPanelObject(obj)
    if IsBuildingBlockClass(obj) then return false end
    return HasClassOrName(obj, "/Script/MainSequence.SolarPanelObject", { "SolarPanel" }, nil)
end

local function IsProducerObject(obj)
    if IsBuildingBlockClass(obj) then return false end
    if IsSolarPanelObject(obj) then return true end
    return HasClassOrName(obj, "/Script/MainSequence.ReactorObject", { "SolarPanel", "Reactor", "Generator" }, "Shield")
end

-- Note: Never call UMachineObject:GetDisplayMaxPower() or GetDisplayPower() on CDOs
-- because Ship machine CDOs lack a runtime BuildingFrame and crash reading [Frame + 0x48].
local function ReadSafeNumericProp(obj, propNames)
    local best = 0.0
    for _, name in ipairs(propNames) do
        local okV, raw = pcall(function() return obj[name] end)
        if okV and raw ~= nil then
            local v = math.abs(ReadFPNum(raw))
            if v > best then
                best = v
            end
        end
    end
    return best
end

local function ComputePowerFromObject(obj)
    if not IsMachineObject(obj) then return 0.0, 0.0, 0.0 end

    if IsSolarPanelObject(obj) then
        local rate = ReadSafeNumericProp(obj, { "PowerGenRate", "MaxPower" })
        return 0.0, rate, 0.0
    elseif IsProducerObject(obj) then
        local rate = ReadSafeNumericProp(obj, { "PowerGenRate", "MaxPower" })
        return rate, 0.0, 0.0
    else
        local cons = ReadSafeNumericProp(obj, { "PowerConsumptionRate", "PowerDraw", "MaxPower" })
        return 0.0, 0.0, cons
    end
end

local MACHINE_ENTRY_FIELDS = {
    "Class",
    "MachineClass",
    "DefaultMachineClass",
    "MachineObjectClass",
    "ObjectClass",
    "Machine",
    "MachineObject",
    "DefaultMachine",
    "Value",
}

local function ResolveMachineCDOFromEntry(entry)
    if entry == nil then return nil end
    local unwrapped = UnwrapStruct(entry)
    if unwrapped == nil then return nil end

    if Core.IsValidObj(unwrapped) then
        if IsMachineObject(unwrapped) then
            return unwrapped
        end
        local cdo = GetCDOFromUClass(unwrapped)
        if Core.IsValidObj(cdo) and IsMachineObject(cdo) then
            return cdo
        end
        -- unwrapped could also be a sub-object holding one of the machine fields
    end

    for _, fieldName in ipairs(MACHINE_ENTRY_FIELDS) do
        local okF, ref = pcall(function() return unwrapped[fieldName] end)
        if okF and ref ~= nil then
            local cand = Core.UnwrapArrayElem(ref)
            if Core.IsValidObj(cand) then
                if IsMachineObject(cand) then
                    return cand
                end
                local cdo = GetCDOFromUClass(cand)
                if Core.IsValidObj(cdo) and IsMachineObject(cdo) then
                    return cdo
                end
            end
        end
    end
    return nil
end

local function AddMachineEntryPower(entry, nsg, sbg, cons)
    local mObj = ResolveMachineCDOFromEntry(entry)
    if Core.IsValidObj(mObj) and IsMachineObject(mObj) then
        local g, sg, c = ComputePowerFromObject(mObj)
        return nsg + g, sbg + sg, cons + c, mObj
    end
    return nsg, sbg, cons, nil
end

local function IsBuildingBlockObject(obj)
    if not Core.IsValidObj(obj) then return false end
    if HasClassOrName(obj, "/Script/MainSequence.BuildingBlockObject", nil, nil) then
        return true
    end
    local okFn, hasFn = pcall(function() return type(obj.GetDefaultMachine) == "function" end)
    return okFn and hasFn == true
end

local function ResolveBlockObjectCDOFromActor(actor)
    if not Core.IsValidObj(actor) then return nil, "invalid_actor" end

    -- 1. Resolve CDO from runtime actor.BlockObject (always prefer CDO; never return a runtime BlockObject instance)
    local rawObj = nil
    pcall(function() rawObj = Core.UnwrapArrayElem(actor.BlockObject) end)
    if Core.IsValidObj(rawObj) then
        local okC, cls = pcall(function() return rawObj:GetClass() end)
        if okC and Core.IsValidObj(cls) then
            local cdo = GetCDOFromUClass(cls)
            if IsBuildingBlockObject(cdo) then
                return cdo, "actor.BlockObject:CDO"
            end
        end
        local okFull, full = pcall(function() return rawObj:GetFullName() end)
        if okFull and type(full) == "string" and string.find(full, "Default__", 1, true) and IsBuildingBlockObject(rawObj) then
            return rawObj, "actor.BlockObject(CDO)"
        end
    end

    -- 2. actor.BlockClass (usually TSubclassOf<UBuildingBlockObject>, e.g. BPO_SolarPanelBlock_C)
    local bCls = nil
    pcall(function() bCls = Core.UnwrapArrayElem(actor.BlockClass) end)
    if Core.IsValidObj(bCls) then
        local cdo = GetCDOFromUClass(bCls)
        if IsBuildingBlockObject(cdo) then
            return cdo, "actor.BlockClass->CDO"
        end
        if Core.IsValidObj(cdo) then
            local innerObj = nil
            pcall(function() innerObj = Core.UnwrapArrayElem(cdo.BlockObject) end)
            if IsBuildingBlockObject(innerObj) then
                return innerObj, "actor.BlockClass->CDO.BlockObject"
            end
            local innerCls = nil
            pcall(function() innerCls = Core.UnwrapArrayElem(cdo.BlockClass) end)
            if Core.IsValidObj(innerCls) then
                local innerCDO = GetCDOFromUClass(innerCls)
                if IsBuildingBlockObject(innerCDO) then
                    return innerCDO, "actor.BlockClass->CDO.BlockClass"
                end
            end
        end
    end

    -- 3. Actor class CDO -> BlockClass / BlockObject
    local actorCls = nil
    pcall(function() actorCls = actor:GetClass() end)
    if Core.IsValidObj(actorCls) then
        local actorCDO = GetCDOFromUClass(actorCls)
        if Core.IsValidObj(actorCDO) then
            local cdoObj = nil
            pcall(function() cdoObj = Core.UnwrapArrayElem(actorCDO.BlockObject) end)
            if IsBuildingBlockObject(cdoObj) then
                return cdoObj, "actorCDO.BlockObject"
            end
            local cdoCls = nil
            pcall(function() cdoCls = Core.UnwrapArrayElem(actorCDO.BlockClass) end)
            if Core.IsValidObj(cdoCls) then
                local innerCDO = GetCDOFromUClass(cdoCls)
                if IsBuildingBlockObject(innerCDO) then
                    return innerCDO, "actorCDO.BlockClass"
                end
            end
        end

        -- 4. BP_<Name>_C -> /Game/Blueprints/BuildingBlocks/BPO_<Name>.Default__BPO_<Name>_C
        local okFull, full = pcall(function() return actorCls:GetFullName() end)
        if okFull and type(full) == "string" then
            local objPath = full:match("^%S+ (.+)$") or full
            local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
            if pkg and clsName then
                local bpLeaf = clsName:gsub("_C$", "")
                if bpLeaf:sub(1, 3) == "BP_" then
                    local bpoLeaf = "BPO_" .. bpLeaf:sub(4)
                    local pkgDir = pkg:match("^(.*)/[^/]+$") or "/Game/Blueprints/BuildingBlocks"
                    local candidatePath = string.format("%s/%s.Default__%s_C", pkgDir, bpoLeaf, bpoLeaf)
                    local candCDO = Core.GetCDO(candidatePath)
                    if not Core.IsValidObj(candCDO) then
                        local bpoCls = Core.FindOrLoadClass(string.format("%s/%s.%s_C", pkgDir, bpoLeaf, bpoLeaf))
                        if Core.IsValidObj(bpoCls) then
                            candCDO = GetCDOFromUClass(bpoCls)
                        end
                    end
                    if IsBuildingBlockObject(candCDO) then
                        return candCDO, "name_pair:" .. bpoLeaf
                    end
                end
            end
        end
    end

    return nil, "unresolved"
end

local function ComputePowerFromBlockCDO(blockCDO)
    if not Core.IsValidObj(blockCDO) then
        return { nonSolarGen = 0.0, solarBaseGen = 0.0, cons = 0.0 }, "none", "nil"
    end

    local nsg, sbg, cons = 0.0, 0.0, 0.0
    local machSrc = "none"
    local machNames = {}
    local attachedCount = 0

    local function collectFromArray(arr, srcLabel)
        local arrCount = 0
        StationData.ForEachArray(arr, function(_, elem)
            arrCount = arrCount + 1
            local usedObj = nil
            nsg, sbg, cons, usedObj = AddMachineEntryPower(elem, nsg, sbg, cons)
            if Core.IsValidObj(usedObj) then
                machSrc = srcLabel
                table.insert(machNames, SafeObjName(usedObj))
            end
        end)
        return arrCount
    end

    -- 1. Check AttachedMachines on UBuildingBlockObject CDO (primary editor-configured machine list)
    local okAM, attachedMachines = pcall(function() return blockCDO.AttachedMachines end)
    if okAM and attachedMachines then
        attachedCount = collectFromArray(attachedMachines, "AttachedMachines")
    end

    -- 2. Check DefaultMachines array if still 0
    if nsg == 0.0 and sbg == 0.0 and cons == 0.0 then
        local okDM, defMachines = pcall(function() return blockCDO.DefaultMachines end)
        if okDM and defMachines then
            collectFromArray(defMachines, "DefaultMachines")
        end
    end

    -- 3. Check single-machine properties (do NOT call UBuildingBlockObject::GetDefaultMachine,
    --    which dereferences a null Cast<Frame> pointer at +0x188 when called outside its expected frame type)
    if nsg == 0.0 and sbg == 0.0 and cons == 0.0 then
        for _, propName in ipairs({ "DefaultMachine", "DefaultMachineClass", "MachineClass", "Machine" }) do
            local okP, val = pcall(function() return blockCDO[propName] end)
            if okP and val ~= nil then
                local usedObj = nil
                nsg, sbg, cons, usedObj = AddMachineEntryPower(val, nsg, sbg, cons)
                if Core.IsValidObj(usedObj) then
                    machSrc = "prop:" .. propName
                    table.insert(machNames, SafeObjName(usedObj))
                    break
                end
            end
        end
    end

    -- 4. Fallback: check blockCDO itself only if it actually is a MachineObject
    if nsg == 0.0 and sbg == 0.0 and cons == 0.0 and IsMachineObject(blockCDO) then
        nsg, sbg, cons = ComputePowerFromObject(blockCDO)
        machSrc = "blockCDO_self"
        table.insert(machNames, SafeObjName(blockCDO))
    end

    if machSrc == "none" and attachedCount > 0 then
        machSrc = string.format("AttachedMachines_unresolved(count=%d)", attachedCount)
    end
    local machName = (#machNames > 0) and table.concat(machNames, "+") or "nil"
    return { nonSolarGen = nsg, solarBaseGen = sbg, cons = cons }, machSrc, machName
end

local function GetActorPowerInfo(actor)
    if not Core.IsValidObj(actor) then
        return { nonSolarGen = 0.0, solarBaseGen = 0.0, cons = 0.0 }, "invalid"
    end

    local aAddr = actor:GetAddress()
    local actorCls = nil
    pcall(function() actorCls = actor:GetClass() end)
    local clsAddr = Core.IsValidObj(actorCls) and actorCls:GetAddress() or 0

    local cachedActor = ActorBlockInfoCache[aAddr]
    if cachedActor and clsAddr ~= 0 and cachedActor.clsAddr == clsAddr then
        return cachedActor.info, cachedActor.clsName
    end

    local clsName = SafeObjName(actorCls)

    local cachedCls = (clsAddr ~= 0) and ActorClassPowerCache[clsAddr] or nil
    if cachedCls then
        ActorBlockInfoCache[aAddr] = { actor = actor, info = cachedCls.info, clsAddr = clsAddr, clsName = cachedCls.clsName }
        return cachedCls.info, cachedCls.clsName
    end

    local blockCDO, resolveVia = ResolveBlockObjectCDOFromActor(actor)
    local info, machSrc, machName = ComputePowerFromBlockCDO(blockCDO)

    if clsAddr ~= 0 then
        ActorClassPowerCache[clsAddr] = { info = info, clsName = clsName }
    end
    ActorBlockInfoCache[aAddr] = { actor = actor, info = info, clsAddr = clsAddr, clsName = clsName }

    return info, clsName
end

local function EvalPowerInfo(info, solarEfficiency)
    local eff = (type(solarEfficiency) == "number" and solarEfficiency >= 0) and solarEfficiency or 1.0
    return (info.nonSolarGen or 0.0) + (info.solarBaseGen or 0.0) * eff, (info.cons or 0.0)
end

local function ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designerHud) then return nil end

    -- WBP_DesignerHUD_C stores ["Designer Pawn"] -> BPC_Designer -> Designer
    local designer = nil
    pcall(function()
        local pawn = designerHud["Designer Pawn"]
        if Core.IsValidObj(pawn) and Core.IsValidObj(pawn.BPC_Designer) then
            designer = pawn.BPC_Designer.Designer
        end
    end)
    if Core.IsValidObj(designer) then return designer end

    pcall(function() designer = designerHud.Designer end)
    if Core.IsValidObj(designer) then return designer end

    local pc = Core.GetLocalPlayerController()
    if Core.IsValidObj(pc) and Core.IsValidObj(pc.Pawn) then
        pcall(function()
            if Core.IsValidObj(pc.Pawn.BPC_Designer) then
                designer = pc.Pawn.BPC_Designer.Designer
            end
        end)
    end
    return designer
end

local function IsHudVisible(hud)
    if not Core.IsValidObj(hud) then return false end
    local inVp, vis = false, false
    pcall(function()
        inVp = hud:IsInViewport() == true
        vis = hud:IsVisible() == true
    end)
    return inVp and vis
end

local function IsActorDesignerPending(actor)
    local okPend, pendRes = pcall(function()
        if actor.IsDesignerPending then
            return actor:IsDesignerPending()
        end
        return actor.bPending == true
    end)
    return okPend and pendRes == true
end

local function CountPreviewBlocksPending(previewBlocks)
    if not previewBlocks then return 0, 0 end
    local okN, len = pcall(function()
        return previewBlocks.GetArrayNum and previewBlocks:GetArrayNum() or #previewBlocks
    end)
    if not okN or type(len) ~= "number" or len <= 0 then
        return 0, 0
    end
    local previewCount, pendingCount = 0, 0
    for i = 1, len do
        local elem = previewBlocks[i]
        local actor = (elem ~= nil) and Core.UnwrapArrayElem(elem) or nil
        if Core.IsValidObj(actor) then
            previewCount = previewCount + 1
            if IsActorDesignerPending(actor) then
                pendingCount = pendingCount + 1
            end
        end
    end
    return previewCount, pendingCount
end

local DesignerWatcherActive = false

local function EnsureDesignerWatcher()
    if DesignerWatcherActive then return end
    if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
    DesignerWatcherActive = true

    local function WatcherTick()
        if not Core.IsFeatureEnabled("DesignerPowerStats") then
            DesignerWatcherActive = false
            return
        end
        local anyVisible = false
        for addr, st in pairs(InjectedDesigners) do
            if not Core.IsValidObj(st.Hud) then
                InjectedDesigners[addr] = nil
            elseif IsHudVisible(st.Hud) then
                anyVisible = true
                local designer = ResolveDesignerObject(st.Hud)
                local previewCount, pendingCount = 0, 0
                if Core.IsValidObj(designer) then
                    local okP, previewBlocks = pcall(function()
                        return Core.IsValidObj(designer.Visualizer) and designer.Visualizer.PreviewBlocks or nil
                    end)
                    if okP and previewBlocks then
                        local okN, rawLen = pcall(function()
                            return previewBlocks.GetArrayNum and previewBlocks:GetArrayNum() or #previewBlocks
                        end)
                        if okN and type(rawLen) == "number" and st.WatchedRawLen ~= nil and rawLen ~= st.WatchedRawLen then
                            st.WatchedRawLen = rawLen
                            st.LastFullPendingScanClock = os.clock()
                            RefreshDesignerPowerStats(st.Hud)
                            previewCount = st.WatchedPreviewCount or rawLen
                            pendingCount = st.WatchedPendingCount or 0
                        else
                            st.WatchedRawLen = rawLen
                            local now = os.clock()
                            -- Throttle full PreviewBlocks pending scan to ~1.6s when rawLen is unchanged
                            if (now - (st.LastFullPendingScanClock or 0)) >= 1.6 then
                                st.LastFullPendingScanClock = now
                                previewCount, pendingCount = CountPreviewBlocksPending(previewBlocks)
                            else
                                previewCount = st.WatchedPreviewCount or 0
                                pendingCount = st.WatchedPendingCount or 0
                            end
                        end
                    end
                end
                if previewCount ~= st.WatchedPreviewCount or pendingCount ~= st.WatchedPendingCount then
                    st.WatchedPreviewCount = previewCount
                    st.WatchedPendingCount = pendingCount
                    RefreshDesignerPowerStats(st.Hud)
                end
            end
        end

        if not anyVisible then
            DesignerWatcherActive = false
            return
        end
        ExecuteInGameThreadWithDelay(400, WatcherTick)
    end

    ExecuteInGameThreadWithDelay(400, WatcherTick)
end

local function ScanAndRefreshAllDesigners(triggerSource, allowFindAll)
    local seen = {}
    local anyTracked = false
    for addr, st in pairs(InjectedDesigners) do
        if not Core.IsValidObj(st.Hud) then
            InjectedDesigners[addr] = nil
        else
            anyTracked = true
            seen[addr] = true
            if IsHudVisible(st.Hud) then
                RefreshDesignerPowerStats(st.Hud)
            end
        end
    end
    if allowFindAll or not anyTracked then
        local okHud, hud = pcall(FindFirstOf, "WBP_DesignerHUD_C")
        if okHud and Core.IsValidObj(hud) and not seen[hud:GetAddress()] and IsHudVisible(hud) then
            RefreshDesignerPowerStats(hud)
        end
    end
end

local function ScheduleAllDesignersRefresh(triggerSource, targetHud)
    if RefreshScheduled then return end
    RefreshScheduled = true
    ExecuteInGameThreadWithDelay(40, function()
        RefreshScheduled = false
        if Core.IsValidObj(targetHud) then
            local tAddr = targetHud:GetAddress()
            if IsHudVisible(targetHud) then
                RefreshDesignerPowerStats(targetHud)
            elseif not InjectedDesigners[tAddr] then
                -- Skip closed/unshown HUDs
                return
            end
            for addr, st in pairs(InjectedDesigners) do
                if addr ~= tAddr and Core.IsValidObj(st.Hud) and IsHudVisible(st.Hud) then
                    RefreshDesignerPowerStats(st.Hud)
                end
            end
            return
        end
        ScanAndRefreshAllDesigners(nil, false)
    end)
end

local function ResolveStationSolarEfficiency(frame, pg)
    local eff = nil
    local effSource = "default_1.0"
    if Core.IsValidObj(pg) then
        local okProds, prods = pcall(function() return pg.Producers end)
        if okProds and prods then
            StationData.ForEachArray(prods, function(_, elem)
                if eff ~= nil then return end
                local prod = Core.UnwrapArrayElem(elem)
                if not IsSolarPanelObject(prod) then return end

                local rate = 0.0
                pcall(function() rate = ReadFPNum(prod.PowerGenRate) end)
                local maxP = 0.0
                if prod.GetDisplayMaxPower then
                    local okMaxP, mp = pcall(function() return prod:GetDisplayMaxPower() end)
                    if okMaxP and type(mp) == "number" then maxP = mp end
                end
                if rate > 0 and maxP > 0 then
                    eff = maxP / rate
                    effSource = string.format("grid_producer(%s:max=%.2f/rate=%.2f)", SafeObjName(prod), maxP, rate)
                    return
                end

                local okDE, deVal = pcall(function() return prod.DistanceEfficiency end)
                if okDE and deVal ~= nil then
                    local de = ReadFPNum(deVal)
                    if de > 0 then
                        eff = de
                        effSource = string.format("grid_producer_DistanceEfficiency(%s:%.3f)", SafeObjName(prod), de)
                    end
                end
            end)
        end
    end

    if eff ~= nil then return eff, effSource end

    -- Fallback when the station has no existing solar panels: compute from distance to sun and solar CDO bounds
    if Core.IsValidObj(frame) and frame.GetDistanceToSun then
        local okD, rawDist = pcall(function() return frame:GetDistanceToSun() end)
        local dist = okD and ReadFPNum(rawDist) or 0.0
        if dist > 0 then
            local solarCDO = Core.GetCDO(PATHS.SolarPanelCDO)
            if not Core.IsValidObj(solarCDO) then
                local solarCls = Core.FindOrLoadClass("/Game/Blueprints/Machines/BPO_SolarPanel.BPO_SolarPanel_C")
                solarCDO = GetCDOFromUClass(solarCls)
            end
            if Core.IsValidObj(solarCDO) then
                local minDist, maxDist, minEff, maxEff = 0.0, 0.0, 0.0, 1.0
                pcall(function()
                    minDist = ReadFPNum(solarCDO.MinDistance)
                    maxDist = ReadFPNum(solarCDO.MaxDistance)
                    minEff  = ReadFPNum(solarCDO.MinEfficiency)
                    maxEff  = ReadFPNum(solarCDO.MaxEfficiency)
                end)
                if maxEff > 0 and maxDist > minDist then
                    local t = Core.Clamp((dist - minDist) / (maxDist - minDist), 0.0, 1.0)
                    eff = maxEff + t * (minEff - maxEff)
                    if eff >= 0 then
                        effSource = string.format("dist_to_sun(dist=%.1f,range=[%.1f..%.1f],eff=[%.2f..%.2f])",
                            dist, minDist, maxDist, maxEff, minEff)
                        return eff, effSource
                    end
                end
            end
        end
    end

    return 1.0, effSource
end

local function ComputeDesignerPower(designerHud, st)
    local designer = ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designer) then
        return 0.0, 0.0, "[DesignerStats Step1] designer=nil"
    end

    local frame = nil
    pcall(function() frame = designer:GetFrame() end)

    local frameAddr = Core.IsValidObj(frame) and frame:GetAddress() or nil
    if st and st.FrameAddr ~= frameAddr then
        st.FrameAddr = frameAddr
        st.SolarEfficiency = nil
        st.SolarEffSource = nil
        st.InitialLoadedGen = nil
        st.InitialLoadedCons = nil
        st.InitialLoadedCount = nil
        st.ResetBaseline = true
    end

    local isStationFrame = false
    local frameCls = nil
    if Core.IsValidObj(frame) then
        pcall(function() frameCls = frame:GetClass() end)
    end
    local frameClsName = SafeObjName(frameCls)
    if Core.IsValidObj(frame) and string.find(frameClsName, "Station", 1, true) then
        isStationFrame = true
    end

    local pgGen, pgCons = 0.0, 0.0
    local pg = nil
    if isStationFrame and frame.GetPowerGrid then
        local okPG, foundPG = pcall(function() return frame:GetPowerGrid() end)
        if okPG and Core.IsValidObj(foundPG) then
            pg = foundPG
            pgGen = ReadFPNum(pg.MaxProduction)
            pgCons = ReadFPNum(pg.MaxConsumption)
        end
    end

    local solarEfficiency = 1.0
    local solarEffSource = "ship_1.0"
    if isStationFrame then
        if st and type(st.SolarEfficiency) == "number" and st.SolarEffSource then
            solarEfficiency = st.SolarEfficiency
            solarEffSource = st.SolarEffSource
        else
            solarEfficiency, solarEffSource = ResolveStationSolarEfficiency(frame, pg)
            if st then
                st.SolarEfficiency = solarEfficiency
                st.SolarEffSource = solarEffSource
            end
        end
    end

    local previewPendingGen, previewPendingCons = 0.0, 0.0
    local previewLoadedGen, previewLoadedCons = 0.0, 0.0
    local previewCount, pendingCount, loadedCount = 0, 0, 0

    local okPreview, previewBlocks = pcall(function()
        if Core.IsValidObj(designer.Visualizer) then
            return designer.Visualizer.PreviewBlocks
        end
        return nil
    end)
    if okPreview and previewBlocks then
        local okN, len = pcall(function()
            return previewBlocks.GetArrayNum and previewBlocks:GetArrayNum() or #previewBlocks
        end)
        if st then st.WatchedRawLen = (okN and type(len) == "number") and len or nil end
        if okN and type(len) == "number" and len > 0 then
            for i = 1, len do
                local elem = previewBlocks[i]
                local actor = (elem ~= nil) and Core.UnwrapArrayElem(elem) or nil
                if Core.IsValidObj(actor) then
                    previewCount = previewCount + 1
                    local info = GetActorPowerInfo(actor)
                    local isPending = IsActorDesignerPending(actor)

                    local g, c = EvalPowerInfo(info, solarEfficiency)
                    if isPending then
                        pendingCount = pendingCount + 1
                        previewPendingGen = previewPendingGen + g
                        previewPendingCons = previewPendingCons + c
                    else
                        loadedCount = loadedCount + 1
                        previewLoadedGen = previewLoadedGen + g
                        previewLoadedCons = previewLoadedCons + c
                    end
                end
            end
        end
    end
    if st then
        st.WatchedPreviewCount = previewCount
        st.WatchedPendingCount = pendingCount
    end

    if st then
        local shouldBaseline = (st.InitialLoadedGen == nil)
            or (st.ResetBaseline == true and pendingCount == 0)
            or (st.InitialLoadedCount == 0 and loadedCount > 0 and pendingCount == 0)
            or (isStationFrame and pendingCount == 0 and st.InitialLoadedCount ~= nil and loadedCount ~= st.InitialLoadedCount)
        if shouldBaseline then
            st.InitialLoadedGen = previewLoadedGen
            st.InitialLoadedCons = previewLoadedCons
            st.InitialLoadedCount = loadedCount
            st.ResetBaseline = false
        end
    end

    local totalGen, totalCons = 0.0, 0.0
    if isStationFrame then
        local baseLoadedGen = st and st.InitialLoadedGen or previewLoadedGen
        local baseLoadedCons = st and st.InitialLoadedCons or previewLoadedCons
        local deltaLoadedGen = previewLoadedGen - baseLoadedGen
        local deltaLoadedCons = previewLoadedCons - baseLoadedCons
        totalGen = math.max(0.0, pgGen + deltaLoadedGen + previewPendingGen)
        totalCons = math.max(0.0, pgCons + deltaLoadedCons + previewPendingCons)
    else
        totalGen = previewLoadedGen + previewPendingGen
        totalCons = previewLoadedCons + previewPendingCons
    end

    return totalGen, totalCons
end

local function CopyTextStyle(dstText, srcText, fallbackSize, overrideColor)
    if not Core.IsValidObj(dstText) then return end
    pcall(function()
        local sz = nil
        if Core.IsValidObj(srcText) and srcText.Size ~= nil then
            local n = tonumber(srcText.Size)
            if n and n >= 8 then sz = n end
        end
        if not sz and Core.IsValidObj(srcText) and Core.IsValidObj(srcText.TextBlock) and srcText.TextBlock.Font then
            local n = tonumber(srcText.TextBlock.Font.Size)
            if n and n >= 8 then sz = n end
        end
        if dstText.SetSize then dstText:SetSize(sz or fallbackSize or 15) end

        local just = nil
        if Core.IsValidObj(srcText) and srcText.Justification ~= nil then
            just = srcText.Justification
        end
        if dstText.SetJustification then dstText:SetJustification(just or 1) end

        if overrideColor and Core.IsValidObj(dstText.TextBlock) then
            dstText.TextBlock:SetColorAndOpacity({ SpecifiedColor = overrideColor, ColorUseRule = 0 })
        end
    end)
end

local function CreateDesignerStatColumn(hud, pc, outer, statsHBox, refColVBox, refLabelText, refValueText, labelStr, gridColIdx, labelColor, labelSize)
    local colVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local lblTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    local divBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local divLine = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local valTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)

    if not (Core.IsValidObj(colVBox) and Core.IsValidObj(lblTxt) and Core.IsValidObj(divBox)
        and Core.IsValidObj(divLine) and Core.IsValidObj(valTxt)) then
        return nil, nil
    end

    local accentCol = labelColor or COLORS.GoldAccent
    CopyTextStyle(lblTxt, refLabelText, labelSize or 15, accentCol)
    CopyTextStyle(valTxt, refValueText, 18, COLORS.WhiteValue)

    pcall(function()
        lblTxt:SetText(Core.MakeText(labelStr))
        valTxt:SetText(Core.MakeText("0 kW / 0 kW"))
        divBox:SetHeightOverride(1.75)
        divLine:SetBrushColor(accentCol)
    end)
    divBox:AddChild(divLine)

    local s1 = colVBox:AddChildToVerticalBox(lblTxt)
    if Core.IsValidObj(s1) then
        pcall(function()
            s1:SetHorizontalAlignment(2) -- HAlign_Center
            s1:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 1.5 })
        end)
    end
    local s2 = colVBox:AddChildToVerticalBox(divBox)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetHorizontalAlignment(0) -- HAlign_Fill
            s2:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 3.0 })
        end)
    end
    local s3 = colVBox:AddChildToVerticalBox(valTxt)
    if Core.IsValidObj(s3) then
        pcall(function() s3:SetHorizontalAlignment(2) end) -- HAlign_Center
    end

    local hBoxCls = Core.FindOrLoadClass("/Script/UMG.HorizontalBox")
    local gridCls = Core.FindOrLoadClass("/Script/UMG.GridPanel")

    if Core.IsValidObj(hBoxCls) and statsHBox:IsA(hBoxCls) then
        local okH, hSlot = pcall(function() return statsHBox:AddChildToHorizontalBox(colVBox) end)
        if okH and Core.IsValidObj(hSlot) then
            pcall(function()
                hSlot:SetVerticalAlignment(2) -- VAlign_Center
                if Core.IsValidObj(refColVBox) and Core.IsValidObj(refColVBox.Slot) then
                    hSlot:SetPadding(refColVBox.Slot.Padding)
                else
                    hSlot:SetPadding({ Left = 24.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end
            end)
        end
    elseif Core.IsValidObj(gridCls) and statsHBox:IsA(gridCls) then
        local colIdx = gridColIdx or 3
        local okG, gSlot = pcall(function() return statsHBox:AddChildToGrid(colVBox, 0, colIdx) end)
        if okG and Core.IsValidObj(gSlot) then
            pcall(function()
                gSlot:SetVerticalAlignment(2)
                gSlot:SetHorizontalAlignment(2)
                local pad = { Left = 22.0, Top = 0.0, Right = 22.0, Bottom = 0.0 }
                if Core.IsValidObj(refColVBox) and Core.IsValidObj(refColVBox.Slot) then
                    local rp = refColVBox.Slot.Padding
                    if rp and ((tonumber(rp.Left) or 0) >= 16 or (tonumber(rp.Right) or 0) >= 16) then
                        pad = rp
                    end
                end
                gSlot:SetPadding(pad)
            end)
        end
    else
        pcall(function() statsHBox:AddChild(colVBox) end)
    end

    -- Re-apply colors/sizes after parenting because WBP_Text_C Construct() resets TextBlock defaults
    CopyTextStyle(lblTxt, refLabelText, labelSize or 15, accentCol)
    CopyTextStyle(valTxt, refValueText, 18, COLORS.WhiteValue)

    return valTxt, lblTxt, colVBox
end

local function FindStatsContainerPanel(hud)
    local hullText = hud.HullText
    local hullColVBox = Core.IsValidObj(hullText) and hullText:GetParent() or nil
    local hBoxCls = Core.FindOrLoadClass("/Script/UMG.HorizontalBox")
    local gridCls = Core.FindOrLoadClass("/Script/UMG.GridPanel")

    -- Walk up from HullText to find the HorizontalBox or GridPanel holding the stat columns
    local cur = hullColVBox
    for _ = 1, 4 do
        if not Core.IsValidObj(cur) then break end
        local parent = nil
        pcall(function() parent = cur:GetParent() end)
        if Core.IsValidObj(parent) then
            if (Core.IsValidObj(hBoxCls) and parent:IsA(hBoxCls)) or (Core.IsValidObj(gridCls) and parent:IsA(gridCls)) then
                return parent, cur, hullText, hullColVBox
            end
        end
        cur = parent
    end

    -- Fallback: drill down from StatsContainer
    if Core.IsValidObj(hud.StatsContainer) then
        local okC, ch = pcall(function() return hud.StatsContainer:GetChildAt(0) end)
        if okC and Core.IsValidObj(ch) then
            return ch, hullColVBox, hullText, hullColVBox
        end
    end
    return nil, nil, nil, nil
end

RefreshDesignerPowerStats = function(hud)
    if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    local st = InjectedDesigners[addr]

    if st and not IsHudVisible(hud) then
        return
    end

    if not st or not Core.IsValidObj(st.PowerText) then
        local statsPanel, refCol, hullText, hullColVBox = FindStatsContainerPanel(hud)
        if not Core.IsValidObj(statsPanel) then
            Core.Log(string.format(
                "[DesignerStats Warn] FindStatsContainerPanel returned nil (HullText=%s StatsContainer=%s)",
                tostring(Core.IsValidObj(hud.HullText)), tostring(Core.IsValidObj(hud.StatsContainer))
            ))
            return
        end

        local refLabelText = nil
        local labelColor = COLORS.GoldAccent
        local labelSize = 15
        if Core.IsValidObj(hullColVBox) then
            pcall(function()
                local cnt = hullColVBox:GetChildrenCount()
                local hullAddr = Core.IsValidObj(hullText) and hullText:GetAddress() or 0
                for i = 0, cnt - 1 do
                    local ch = hullColVBox:GetChildAt(i)
                    if Core.IsValidObj(ch) and ch:GetAddress() ~= hullAddr and Core.IsValidObj(ch.TextBlock) then
                        refLabelText = ch
                        local okS, s = pcall(function() return tonumber(ch.Size) end)
                        if okS and s and s >= 8 then
                            labelSize = s
                        else
                            local okFS, fs = pcall(function() return tonumber(ch.TextBlock.Font.Size) end)
                            if okFS and fs and fs >= 8 then labelSize = fs end
                        end
                        pcall(function()
                            local c = ch.TextBlock.ColorAndOpacity.SpecifiedColor
                            if c and c.A and c.A > 0.1 then
                                labelColor = { R = c.R, G = c.G, B = c.B, A = c.A }
                            end
                        end)
                        break
                    end
                end
            end)
        end

        local outer = Core.GetWidgetOuter(hud)
        local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
        local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

        local nextCol = 3
        pcall(function()
            local maxCol = -1
            local count = statsPanel:GetChildrenCount()
            for i = 0, count - 1 do
                local child = statsPanel:GetChildAt(i)
                if Core.IsValidObj(child) and Core.IsValidObj(child.Slot) and child.Slot.Column ~= nil then
                    local c = tonumber(child.Slot.Column)
                    if c and c > maxCol then maxCol = c end
                end
            end
            if maxCol >= 0 then
                nextCol = maxCol + 1
            elseif count > 0 then
                nextCol = count
            end
        end)

        local pwrTxt, pwrLbl, colRoot = CreateDesignerStatColumn(hud, pc, outer, statsPanel, refCol, refLabelText, hullText, "Power", nextCol, labelColor, labelSize)
        if not Core.IsValidObj(pwrTxt) then
            Core.Log("[DesignerStats Warn] CreateDesignerStatColumn returned nil")
            return
        end

        st = { Hud = hud, Root = colRoot, PowerText = pwrTxt, PowerLabel = pwrLbl, LabelColor = labelColor }
        InjectedDesigners[addr] = st
        EnsureDesignerWatcher()
    end

    local gen, cons = ComputeDesignerPower(hud, st)
    if st.LastGen == gen and st.LastCons == cons then
        return
    end
    st.LastGen = gen
    st.LastCons = cons
    pcall(function()
        st.PowerText:SetText(Core.MakeText(string.format("%s / %s", FormatPower(cons), FormatPower(gen))))
        local lblCol = st.LabelColor or COLORS.GoldAccent
        if Core.IsValidObj(st.PowerLabel) and Core.IsValidObj(st.PowerLabel.TextBlock) then
            st.PowerLabel.TextBlock:SetColorAndOpacity({ SpecifiedColor = lblCol, ColorUseRule = 0 })
        end
        local valColor = (cons > gen and cons > 0) and COLORS.RedValue or COLORS.WhiteValue
        if Core.IsValidObj(st.PowerText.TextBlock) then
            st.PowerText.TextBlock:SetColorAndOpacity({ SpecifiedColor = valColor, ColorUseRule = 0 })
        end
    end)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

-- Returns true if the hooked Designer / BPC_Designer_C instance belongs to the local player
-- (or cannot be attributed to a non-local remote controller on a listen-server host).
local function IsDesignerContextLocal(ctxObj)
    local localPC = Core.GetLocalPlayerController()
    if not Core.IsValidObj(localPC) then return false end
    if not Core.IsValidObj(ctxObj) then return true end

    local ownerPC = nil
    pcall(function()
        if ctxObj.GetOwner then
            local o = ctxObj:GetOwner()
            if Core.IsValidObj(o) then
                if o.IsLocalPlayerController then
                    ownerPC = o
                elseif o.GetController then
                    ownerPC = o:GetController()
                elseif o.Controller then
                    ownerPC = o.Controller
                end
            end
        end
        if not Core.IsValidObj(ownerPC) and ctxObj.OwningPlayerController then
            ownerPC = ctxObj.OwningPlayerController
        end
        if not Core.IsValidObj(ownerPC) and ctxObj.PlayerController then
            ownerPC = ctxObj.PlayerController
        end
        if not Core.IsValidObj(ownerPC) and ctxObj.GetOwningPlayer then
            ownerPC = ctxObj:GetOwningPlayer()
        end
    end)

    if Core.IsValidObj(ownerPC) then
        local okL, isLocal = pcall(function() return ownerPC:IsLocalPlayerController() end)
        if okL then
            return isLocal == true
        end
        return ownerPC:GetAddress() == localPC:GetAddress()
    end

    -- Fallback: check if any tracked local Designer HUD is actually visible
    for _, st in pairs(InjectedDesigners) do
        if st and Core.IsValidObj(st.Hud) and IsHudVisible(st.Hud) then
            return true
        end
    end
    return false
end

Feature.WatchWidgets = {
    WBP_DesignerHUD_C = function(hud)
        if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
        Feature.RegisterHooks()
        ExecuteInGameThreadWithDelay(150, function()
            if Core.IsFeatureEnabled("DesignerPowerStats") and Core.IsValidObj(hud) and not InjectedDesigners[hud:GetAddress()] and IsHudVisible(hud) then
                RefreshDesignerPowerStats(hud)
            end
        end)
    end,
}

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "DesignerHUD_Refresh",
        PATHS.DesignerHUDClass .. ":Refresh",
        function(Context)
            if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                ScheduleAllDesignersRefresh("HUD_Refresh", hud)
            end
        end
    )

    Core.TryRegisterHook(
        "DesignerHUD_RefreshStats",
        PATHS.DesignerHUDClass .. ":RefreshStats",
        function(Context)
            if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                ScheduleAllDesignersRefresh("RefreshStats", hud)
            end
        end
    )

    Core.TryRegisterHook(
        "Designer_RefreshBlueprintStats",
        "/Script/MainSequence.Designer:RefreshBlueprintStats",
        function(Context)
            if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
            local ctxObj = Context and Context:get() or nil
            if not IsDesignerContextLocal(ctxObj) then return end
            ScheduleAllDesignersRefresh("Designer_RefreshBlueprintStats")
        end
    )

    Core.TryRegisterHook(
        "BPCDesigner_Confirm",
        PATHS.BPCDesignerClass .. ":Confirm",
        function(Context)
            if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
            local ctxObj = Context and Context:get() or nil
            if not IsDesignerContextLocal(ctxObj) then return end
            ActorBlockInfoCache = {}
            for _, st in pairs(InjectedDesigners) do
                st.ResetBaseline = true
                st.SolarEfficiency = nil
                st.SolarEffSource = nil
                st.LastStepDiag = nil
            end
            ScheduleAllDesignersRefresh("Confirm")
        end
    )

    Core.TryRegisterHook(
        "BPCDesigner_RemoveBlock",
        PATHS.BPCDesignerClass .. ":RemoveBlock",
        function(Context)
            if not Core.IsFeatureEnabled("DesignerPowerStats") then return end
            local ctxObj = Context and Context:get() or nil
            if not IsDesignerContextLocal(ctxObj) then return end
            ScheduleAllDesignersRefresh("RemoveBlock")
        end
    )
end

function Feature.OnToggle(enabled)
    for _, st in pairs(InjectedDesigners) do
        if st and Core.IsValidObj(st.Root) then
            pcall(function() st.Root:SetVisibility(enabled and 0 or 1) end)
        end
    end
    if enabled and next(InjectedDesigners) ~= nil then
        ScanAndRefreshAllDesigners("OnToggle", false)
    end
end

function Feature.OnClientRestart()
    ActorBlockInfoCache = {}
    ActorClassPowerCache = {}
    Feature.RegisterHooks()
    if next(InjectedDesigners) ~= nil then
        ExecuteInGameThreadWithDelay(200, function()
            ScanAndRefreshAllDesigners("OnClientRestart", false)
        end)
    end
end

function Feature.OnMapLoad()
    ActorBlockInfoCache = {}
    ActorClassPowerCache = {}
    Feature.RegisterHooks()
    ExecuteInGameThreadWithDelay(200, function()
        ScanAndRefreshAllDesigners("OnMapLoad", true)
    end)
end

function Feature.PruneCaches()
    for aAddr, entry in pairs(ActorBlockInfoCache) do
        if not entry or not Core.IsValidObj(entry.actor) then
            ActorBlockInfoCache[aAddr] = nil
        end
    end
    for addr, st in pairs(InjectedDesigners) do
        if not Core.IsValidObj(st.PowerText) then
            InjectedDesigners[addr] = nil
        end
    end
end

function Feature.Init()
    Feature.RegisterHooks()
end

return Feature
