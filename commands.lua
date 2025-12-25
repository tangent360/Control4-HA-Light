--[[=============================================================================
    HA Light Driver - Proxy Command Handlers

    Handles Light V2 proxy commands from C4 Director and translates them to
    Home Assistant service calls via the HA_CALL_SERVICE binding (999).

    Key concepts:
    - RFP.* functions handle commands FROM the C4 proxy
    - OPC.* functions handle property changes from Composer
    - C4:SendToProxy(5001, ...) sends notifications TO the C4 proxy
    - C4:SendToProxy(999, "HA_CALL_SERVICE", ...) sends commands to Home Assistant
===============================================================================]]


Helpers = require('helpers')

PROXY_DEVICE_STATE = nil

-- Light capabilities (populated from HA state)
SUPPORTED_ATTRIBUTES = {}
MIN_K_TEMP = 500
MAX_K_TEMP = 20000
HAS_BRIGHTNESS = true
HAS_EFFECTS = false
LAST_EFFECT = "Select Effect"
EFFECTS_LIST = {}

-- Current state tracking
WAS_ON = false
LIGHT_LEVEL = 0  -- Current brightness (0-100)

-- Daylight Agent preset tracking
LIGHT_BRIGHTNESS_PRESET_ID = nil
LIGHT_BRIGHTNESS_PRESET_LEVEL = nil

-- Ramp timer state: HA reports target state immediately during transitions,
-- but C4 expects CHANGED notifications only after the ramp completes.
-- We defer notifications until the timer expires to ensure accurate scene tracking.
BRIGHTNESS_RAMP_TIMER = nil
BRIGHTNESS_RAMP_PENDING = false
COLOR_RAMP_TIMER = nil
COLOR_RAMP_PENDING = false
COLOR_RAMP_PENDING_DATA = nil

-- Dim-to-Warm (Color Fade Mode): When enabled, color interpolates linearly
-- between Dim color (at 1%) and On color (at 100%) based on brightness.
-- These values are set by UPDATE_COLOR_ON_MODE from the proxy.
COLOR_ON_MODE_FADE_ENABLED = false
COLOR_ON_X = nil
COLOR_ON_Y = nil
COLOR_ON_MODE = nil
COLOR_FADE_X = nil
COLOR_FADE_Y = nil
COLOR_FADE_MODE = nil

-- Defaults for correct switch on behavior
DEFAULT_BRIGHTNESS_RATE = 0
DEFAULT_COLOR_RATE = 0
COLOR_PRESET_ORIGIN = 0  -- 1 = Previous, 2 = Preset
PREVIOUS_ON_COLOR_X = nil
PREVIOUS_ON_COLOR_Y = nil
PREVIOUS_ON_COLOR_MODE = nil

--[[===========================================================================
    Driver Load Functions
    Scene color matching tolerance (Delta E in CIE L*a*b* space)
===========================================================================]]

function DRV.OnDriverInit(init)
    -- 1. Read Static Capabilities (Hardware definitions from XML)
    local color_tolerance = C4:GetCapability("color_trace_tolerance")
    if color_tolerance ~= nil then
        local parsed = tonumber(color_tolerance)
    
        if parsed then
            COLOR_TRACE_TOLERANCE = parsed
            print("Driver Init: COLOR_TRACE_TOLERANCE set to " .. COLOR_TRACE_TOLERANCE)
        else
            -- Explicit failure logging
            print("[ERROR] Driver XML Capability 'color_trace_tolerance' defined but invalid: '" .. tostring(color_tolerance) .. "'. Expected a number.")
            -- Optionally: leave COLOR_TOLERANCE as nil to force a crash later if that's preferred.
        end
    else
        print("[WARNING] Driver XML Capability 'color_trace_tolerance' is missing.")
    end
end

function DRV.OnDriverLateInit(init)
    local proxyId = C4:GetProxyDevicesById(C4:GetDeviceID())
    local setupResult = C4:SendUIRequest(proxyId, "GET_SETUP", {})
    local setupTable = Helpers.xmlToTable(setupResult)
    setupTable = Helpers.convertTableTypes(setupTable)

    DEFAULT_BRIGHTNESS_RATE = setupTable.light_brightness_rate_default

    if DEBUGPRINT then
        print("[DEBUG OnDriverLateInit] light_brightness_rate_default set:" .. tostring(DEFAULT_BRIGHTNESS_RATE))
    end
end

--[[===========================================================================
    Helper Functions
===========================================================================]]
function BuildBrightnessChangedParams(level)
    local params = { LIGHT_BRIGHTNESS_CURRENT = level }
    -- Include preset ID if level matches the preset target
    if LIGHT_BRIGHTNESS_PRESET_ID and LIGHT_BRIGHTNESS_PRESET_LEVEL == level then
        params.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = LIGHT_BRIGHTNESS_PRESET_ID
    end
    return params
end

function SetLightValue( brightnessTarget, rate)
    local tParams = {
        LIGHT_BRIGHTNESS_TARGET = brightnessTarget
    }

    if rate then
        tParams.RATE = rate
    end
    
    RFP.SET_BRIGHTNESS_TARGET(nil, nil, tParams)
end


--[[===========================================================================
    Proxy Command Handlers (RFP.*)
===========================================================================]]

-- Simple on/off commands (no brightness/color specified)
function RFP.ON(idBinding, strCommand, tParams)
    local turnOnServiceCall = {
        domain = "light",
        service = "turn_on",

        service_data = {},

        target = {
            entity_id = EntityID
        }
    }
    tParams = {
        JSON = JSON:encode(turnOnServiceCall)
    }
    C4:SendToProxy(999, "HA_CALL_SERVICE", tParams)
end

function RFP.OFF(idBinding, strCommand, tParams)
    local turnOffServiceCall = {
        domain = "light",
        service = "turn_off",

        service_data = {},

        target = {
            entity_id = EntityID
        }
    }
    tParams = {
        JSON = JSON:encode(turnOffServiceCall)
    }
    C4:SendToProxy(999, "HA_CALL_SERVICE", tParams)
end

-- Button link handlers 
-- Handle physical button presses (Top=On, Bottom=Off, Toggle)
--
-- Bindings:
--  200=Top
--  201=Bottom
--  202=Toggle
--
-- From the c4 docs for BUTTON_ACTION():
--
--  BUTTON_ID. ID for the button:
--      0 - Top
--      1 - Bottom
--      2 - Toggle
--  ACTION :
--      0 - RELEASE (HOLD)
--      1 - PRESS
--      2 - RELEASE (CLICK)

function RFP.DO_PUSH(idBinding, strCommand, tParams) 
    local tParams = { ACTION = "1", BUTTON_ID = "" }
    if idBinding == 200 then tParams.BUTTON_ID = "0"
    elseif idBinding == 201 then tParams.BUTTON_ID = "1"
    elseif idBinding == 202 then tParams.BUTTON_ID = "2" end
    RFP:BUTTON_ACTION(strCommand, tParams)
end

function RFP.DO_RELEASE(idBinding, strCommand, tParams) 
    local tParams = { ACTION = "0", BUTTON_ID = "" }
    if idBinding == 200 then tParams.BUTTON_ID = "0"
    elseif idBinding == 201 then tParams.BUTTON_ID = "1"
    elseif idBinding == 202 then tParams.BUTTON_ID = "2" end
    RFP:BUTTON_ACTION(strCommand, tParams)
end

function RFP.DO_CLICK(idBinding, strCommand, tParams)
    local tParams = { ACTION = "2", BUTTON_ID = "" }
    if idBinding == 200 then tParams.BUTTON_ID = "0"
    elseif idBinding == 201 then tParams.BUTTON_ID = "1"
    elseif idBinding == 202 then tParams.BUTTON_ID = "2" end
    RFP:BUTTON_ACTION(strCommand, tParams)
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams)

    -- PRESS physical action ... dont know if this will be a 
    -- CLICK or a HOLD, so start a long ramp immediately in 
    -- the correct direction ... the CLICK is coming immenently
    -- and we'll correct, or else it's a HOLD.
    -- The lack of of a stop command in HA makes this difficult.
    if tParams.ACTION == "1" then
        local rate = 5000. -- this is controling the press & hold ramp rate.
        RAMP_START_TIME_MS = C4:GetTime() -- system time in ms.
        RAMP_DURATION_MS = rate
        RAMP_START_LEVEL = LIGHT_LEVEL -- Current level when ramp starts

        if tParams.BUTTON_ID == "0" then 
            RAMP_TARGET_LEVEL = 100
            SetLightValue(RAMP_TARGET_LEVEL, rate)
        elseif tParams.BUTTON_ID == "1" then
            -- ridiculous situation where a turn_off followed by
            -- an overriding turn_off at HA results in immediate 
            -- turn off.  So turn_on to low (1%), then turn_off
            -- if it turns out to be a click event.
            RAMP_TARGET_LEVEL = 1
            SetLightValue(RAMP_TARGET_LEVEL, rate)
        else
            if WAS_ON then
                RAMP_TARGET_LEVEL = 1
                SetLightValue(RAMP_TARGET_LEVEL, rate)
            else
                RAMP_TARGET_LEVEL = 100
                SetLightValue(RAMP_TARGET_LEVEL, rate)
            end
        end
    end

    -- RELEASE from a HOLD event
    -- Set the brightness to the current level.
    if tParams.ACTION == "0" then
        SetLightValue(Helpers.lerp(RAMP_START_LEVEL, 
                            RAMP_TARGET_LEVEL, 
                            C4:GetTime() - RAMP_START_TIME_MS,
                            RAMP_DURATION_MS), 0)
    end

    -- Release from a CLICK event
    if tParams.ACTION == "2" then
        if tParams.BUTTON_ID == "0" then
            SetLightValue(100, nil)
        elseif tParams.BUTTON_ID == "1" then
            SetLightValue(0, nil)
        else
            if WAS_ON then
                SetLightValue(0, nil)
            else
                SetLightValue(100, nil)
            end
        end
    end
end

-- Called by Director to sync current state
function RFP.SYNCHRONIZE(idBinding, strCommand, tParams)
    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
end

function RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams)
    DEFAULT_BRIGHTNESS_RATE = tonumber(tParams.RATE) or 0
    if DEBUGPRINT then
        print("[DEBUG] Default brightness rate set to: " .. tostring(DEFAULT_BRIGHTNESS_RATE) .. "ms")
    end
end

function RFP.UPDATE_COLOR_RATE_DEFAULT(idBinding, strCommand, tParams)
    DEFAULT_COLOR_RATE = tonumber(tParams.RATE) or 0
    if DEBUGPRINT then
        print("[DEBUG] Default color rate set to: " .. tostring(DEFAULT_COLOR_RATE) .. "ms")
    end
end

function RFP.UPDATE_COLOR_PRESET(idBinding, strCommand, tParams)
    -- Track "Previous On" color when light turns off
    if tParams.NAME == "Previous On" then
        PREVIOUS_ON_COLOR_X = tonumber(tParams.COLOR_X)
        PREVIOUS_ON_COLOR_Y = tonumber(tParams.COLOR_Y)
        PREVIOUS_ON_COLOR_MODE = tonumber(tParams.COLOR_MODE)
        if DEBUGPRINT then
            print("[DEBUG COLOR] Previous On color updated: XY(" .. 
                  tostring(PREVIOUS_ON_COLOR_X) .. "," .. tostring(PREVIOUS_ON_COLOR_Y) .. ")")
        end
    end
end

--[[===========================================================================
    Advanced Lighting Scene (ALS) Handlers

    Required by advanced_scene_support capability. See driver.xml.
    SYNC_SCENE and SYNC_ALL_SCENES are legacy (pre-3.0.0) and not needed
    when PUSH_SCENE is properly implemented.
===========================================================================]]

-- Store scene data from Director. Called when scenes are created/modified.
-- Scene data is persisted and retrieved by ACTIVATE_SCENE.
function RFP.PUSH_SCENE(idBinding, strCommand, tParams)
    -- Parse scene XML into simple key-value table
    local xml = C4:ParseXml(tParams.ELEMENTS)
    local element = {}

    if DEBUGPRINT then
        print("[DEBUG ALS] PUSH_SCENE " .. tParams.SCENE_ID .. " raw XML name: " .. tostring(xml.Name))
    end

    -- Handle nested <element> wrapper if present
    local nodes = xml.ChildNodes
    if xml.Name == "element" then
        nodes = xml.ChildNodes
    end

    for _, child in ipairs(nodes) do
        local value = child.Value
        -- Convert to appropriate type
        if value == "True" or value == "true" then
            value = true
        elseif value == "False" or value == "false" then
            value = false
        else
            value = tonumber(value) or value
        end
        element[child.Name] = value
    end

    C4:PersistSetValue("ALS:" .. tParams.SCENE_ID, element, false)

    if DEBUGPRINT then
        print("[DEBUG ALS] PUSH_SCENE " .. tParams.SCENE_ID .. " stored:")
        for k, v in pairs(element) do
            print("[DEBUG ALS]   " .. k .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
        end
    end
end

-- Execute a previously stored scene. Retrieves scene data and sends to HA.
function RFP.ACTIVATE_SCENE(idBinding, strCommand, tParams)
    local el = C4:PersistGetValue("ALS:" .. tParams.SCENE_ID, false)

    if el == nil then
        print("No scene data for scene " .. tParams.SCENE_ID)
        return
    end

    if DEBUGPRINT then
        print("[DEBUG ALS] ACTIVATE_SCENE " .. tParams.SCENE_ID .. ":")
        for k, v in pairs(el) do
            print("[DEBUG ALS]   " .. k .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
        end
    end

    local levelEnabled = (el.brightnessEnabled == true) or (el.levelEnabled == true)
    local colorEnabled = (el.colorEnabled == true) and el.colorX ~= nil and el.colorY ~= nil

    if DEBUGPRINT then
        print("[DEBUG ALS] levelEnabled=" .. tostring(levelEnabled) ..
              " colorEnabled=" .. tostring(colorEnabled))
    end

    -- When scene has both brightness and color, send them together to avoid
    -- dim-to-warm applying a conflicting color before the scene color arrives
    if (levelEnabled or el.level ~= nil or el.brightness ~= nil) and colorEnabled then
        local target = el.level or el.brightness or 0
        local rate = el.rate or el.brightnessRate or 0
        local colorRate = el.colorRate or 0

        if DEBUGPRINT then
            print("[DEBUG ALS] Scene has brightness AND color - sending combined command")
        end

        -- Notify proxy that brightness is changing
        C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGING', {
            LIGHT_BRIGHTNESS_CURRENT = LIGHT_LEVEL,
            LIGHT_BRIGHTNESS_TARGET = target,
            RATE = rate
        })

        -- Notify proxy that color is changing
        C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
            LIGHT_COLOR_TARGET_X = el.colorX,
            LIGHT_COLOR_TARGET_Y = el.colorY,
            LIGHT_COLOR_TARGET_COLOR_MODE = el.colorMode or 0,
            LIGHT_COLOR_TARGET_COLOR_RATE = colorRate
        })

        -- Cancel any existing ramp timers
        if BRIGHTNESS_RAMP_TIMER then
            BRIGHTNESS_RAMP_TIMER:Cancel()
            BRIGHTNESS_RAMP_TIMER = nil
        end
        if COLOR_RAMP_TIMER then
            COLOR_RAMP_TIMER:Cancel()
            COLOR_RAMP_TIMER = nil
        end

        -- Set up ramp timer for brightness (use the longer of the two rates)
        local maxRate = math.max(rate, colorRate)
        if maxRate > 0 then
            BRIGHTNESS_RAMP_PENDING = false
            COLOR_RAMP_PENDING = false
            COLOR_RAMP_PENDING_DATA = nil
            BRIGHTNESS_RAMP_TIMER = C4:SetTimer(maxRate, function(timer)
                BRIGHTNESS_RAMP_TIMER = nil
                if BRIGHTNESS_RAMP_PENDING then
                    BRIGHTNESS_RAMP_PENDING = false
                    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
                end
                if COLOR_RAMP_PENDING and COLOR_RAMP_PENDING_DATA then
                    COLOR_RAMP_PENDING = false
                    local data = COLOR_RAMP_PENDING_DATA
                    COLOR_RAMP_PENDING_DATA = nil
                    C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                        LIGHT_COLOR_CURRENT_X = data.x,
                        LIGHT_COLOR_CURRENT_Y = data.y,
                        LIGHT_COLOR_CURRENT_COLOR_MODE = data.mode
                    })
                end
            end)
        end

        -- Build combined HA service call with brightness AND color
        local targetMappedValue = MapValue(target, 255, 100)
        local sceneServiceCall = {
            domain = "light",
            service = "turn_on",
            service_data = {
                brightness = targetMappedValue
            },
            target = {
                entity_id = EntityID
            }
        }

        -- Add transition time (use the longer rate)
        if maxRate >= 0 then
            sceneServiceCall.service_data.transition = maxRate / 1000
        end

        -- Add color (as CCT or XY depending on light capabilities)
        local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
        if lightSupportsCCT and (el.colorMode == 1 or el.colorMode == nil) then
            local kelvin = C4:ColorXYtoCCT(el.colorX, el.colorY)
            sceneServiceCall.service_data.color_temp_kelvin = kelvin
            if DEBUGPRINT then
                print("[DEBUG ALS] Combined: brightness=" .. target .. ", CCT=" .. kelvin .. "K")
            end
        else
            sceneServiceCall.service_data.xy_color = { el.colorX, el.colorY }
            if DEBUGPRINT then
                print("[DEBUG ALS] Combined: brightness=" .. target .. ", XY=(" .. el.colorX .. "," .. el.colorY .. ")")
            end
        end

        -- Handle turn off
        if target == 0 then
            sceneServiceCall.service_data = { transition = sceneServiceCall.service_data.transition }
            sceneServiceCall.service = "turn_off"
        end

        C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(sceneServiceCall) })
        return
    end

    -- Execute brightness
    if levelEnabled or (el.level ~= nil or el.brightness ~= nil) then
        RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
            LIGHT_BRIGHTNESS_TARGET = el.level or el.brightness or 0,
            RATE = el.rate or el.brightnessRate or 0
        })
    end

    -- Execute color
    if colorEnabled then
        RFP.SET_COLOR_TARGET(nil, nil, {
            LIGHT_COLOR_TARGET_X = el.colorX,
            LIGHT_COLOR_TARGET_Y = el.colorY,
            LIGHT_COLOR_TARGET_MODE = el.colorMode or 0,
            LIGHT_COLOR_TARGET_RATE = el.colorRate or 0
        })
    end
end

-- Ramp scene up continuously (used when user holds button).
-- Since HA doesn't support continuous ramping, we ramp to the scene's target level.
function RFP.RAMP_SCENE_UP(idBinding, strCommand, tParams)
    local sceneId = tParams.SCENE_ID

    if DEBUGPRINT then
        print("[DEBUG ALS] RAMP_SCENE_UP: scene=" .. tostring(sceneId)) 
    end

    local rate = tonumber(tParams.RATE) or 0
    local el = C4:PersistGetValue("ALS:" .. sceneId, false)
    if el == nil then
        print("No scene data for scene " .. tostring(sceneId))
        return
    end

    local target = el.level or el.brightness or 100
    RAMP_START_TIME_MS = C4:GetTime() -- system time in ms.
    RAMP_DURATION_MS = rate
    RAMP_START_LEVEL = LIGHT_LEVEL -- Current level when ramp starts
    RAMP_TARGET_LEVEL = target

    if DEBUGPRINT then
        print("rate = " .. tostring(rate))
        print("target = " .. tostring(target))
        print("RAMP_START_TIME_MS = " .. tostring(RAMP_START_TIME_MS))
        print("RAMP_DURATION_MS = " .. tostring(RAMP_DURATION_MS))
        print("RAMP_START_LEVEL = " .. tostring(RAMP_START_LEVEL))
        print("RAMP_TARGET_LEVEL = " .. tostring(RAMP_TARGET_LEVEL))
    end

    -- Ramp to scene's target brightness
    RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
        LIGHT_BRIGHTNESS_TARGET = target,
        RATE = rate
    })
end

-- Ramp scene down continuously (used when user holds button).
-- Since HA doesn't support continuous ramping, we ramp to 0.
function RFP.RAMP_SCENE_DOWN(idBinding, strCommand, tParams)
    local sceneId = tParams.SCENE_ID
    local rate = tonumber(tParams.RATE) or 0

    if DEBUGPRINT then
        print("[DEBUG ALS] RAMP_SCENE_DOWN: scene=" .. tostring(sceneId) .. ", rate=" .. tostring(rate))
    end

    local el = C4:PersistGetValue("ALS:" .. sceneId, false)
    local target = el.level or el.brightness or 100
    RAMP_START_TIME_MS = C4:GetTime() -- system time in ms.
    RAMP_DURATION_MS = rate
    RAMP_START_LEVEL = LIGHT_LEVEL -- Current level when ramp starts
    RAMP_TARGET_LEVEL = 0

    if DEBUGPRINT then
        print("rate = " .. tostring(rate))
        print("target = " .. tostring(target))
        print("RAMP_START_TIME_MS = " .. tostring(RAMP_START_TIME_MS))
        print("RAMP_DURATION_MS = " .. tostring(RAMP_DURATION_MS))
        print("RAMP_START_LEVEL = " .. tostring(RAMP_START_LEVEL))
        print("RAMP_TARGET_LEVEL = " .. tostring(RAMP_TARGET_LEVEL))
    end

    -- Ramp to 0
    RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
        LIGHT_BRIGHTNESS_TARGET = 0,
        RATE = rate
    })
end

-- Stop an in-progress scene ramp (user released button).
-- Sends current level to HA to freeze at current position.
function RFP.STOP_SCENE_RAMP(idBinding, strCommand, tParams)
    local elapsedTimeMs = C4:GetTime() - RAMP_START_TIME_MS
    local sceneId = tParams.SCENE_ID

    if DEBUGPRINT then
        print("[DEBUG ALS] STOP_SCENE_RAMP: scene=" .. tostring(sceneId) .. ", freezing at level=" .. tostring(LIGHT_LEVEL))
        Helpers.dumpTable(tParams, "RFP.STOP_SCENE_RAMP tParams")
    end

    -- Cancel any pending ramp timer
    if BRIGHTNESS_RAMP_TIMER then
        BRIGHTNESS_RAMP_TIMER:Cancel()
        BRIGHTNESS_RAMP_TIMER = nil
    end

    newTargetLevel = Helpers.lerp(RAMP_START_LEVEL, 
                        RAMP_TARGET_LEVEL, 
                        elapsedTimeMs,
                        RAMP_DURATION_MS)

    if DEBUGPRINT then
        print("[DEBUG ALS] STOP_SCENE_RAMP: elapsedTimeMs=" .. tostring(elapsedTimeMs) .. ", newTargetLevel=" .. tostring(newTargetLevel))
    end


    -- Send current level to HA to stop ramping at current position
    local stopServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {
            brightness = MapValue(newTargetLevel, 255, 100),
            transition = 0
        },
        target = { entity_id = EntityID }
    }


    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(stopServiceCall) })

    -- Notify proxy of current level
    --C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
end

-- Receive color presets from proxy when Color On Mode is configured.
-- In "Fade" mode, stores On/Dim colors for dim-to-warm interpolation.
function RFP.UPDATE_COLOR_ON_MODE(idBinding, strCommand, tParams)
    if DEBUGPRINT then
        Helpers.dumpTable(tParams, "RFP.UPDATE_COLOR_ON_MODE tParams")
    end

    -- Track origin: 1 = Previous, 2 = Preset
    COLOR_PRESET_ORIGIN = tonumber(tParams.COLOR_PRESET_ORIGIN) or 0

    -- Store the "On" color (at 100% brightness)
    COLOR_ON_X = tonumber(tParams.COLOR_PRESET_COLOR_X)
    COLOR_ON_Y = tonumber(tParams.COLOR_PRESET_COLOR_Y)
    COLOR_ON_MODE = tonumber(tParams.COLOR_PRESET_COLOR_MODE)

    -- Store the "Dim" color (at 1% brightness) for fade/dim-to-warm mode
    COLOR_FADE_X = tonumber(tParams.COLOR_FADE_PRESET_COLOR_X)
    COLOR_FADE_Y = tonumber(tParams.COLOR_FADE_PRESET_COLOR_Y)
    COLOR_FADE_MODE = tonumber(tParams.COLOR_FADE_PRESET_COLOR_MODE)

    -- Fade mode is enabled if fade preset ID is non-zero and we have both colors
    local fadePresetId = tonumber(tParams.COLOR_FADE_PRESET_ID) or 0
    COLOR_ON_MODE_FADE_ENABLED = (fadePresetId ~= 0) and (COLOR_FADE_X ~= nil) and (COLOR_ON_X ~= nil)

    if DEBUGPRINT then
        print("[DEBUG COLOR] UPDATE_COLOR_ON_MODE: origin=" .. tostring(COLOR_PRESET_ORIGIN) ..
              ", fade_enabled=" .. tostring(COLOR_ON_MODE_FADE_ENABLED))
        print("[DEBUG COLOR]   On color: X=" .. tostring(COLOR_ON_X) .. ", Y=" .. tostring(COLOR_ON_Y))
        print("[DEBUG COLOR]   Dim color: X=" .. tostring(COLOR_FADE_X) .. ", Y=" .. tostring(COLOR_FADE_Y))
    end
end


-- Set light color. 
-- Converts C4 XY coordinates to CCT if light only supports CCT.
-- In fade mode, ignores commands matching On/Dim presets to prevent override.
function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams)
    local targetX = tonumber(tParams.LIGHT_COLOR_TARGET_X)
    local targetY = tonumber(tParams.LIGHT_COLOR_TARGET_Y)
    local colorMode = tonumber(tParams.LIGHT_COLOR_TARGET_MODE) or 0  -- 0=Full Color, 1=CCT

    -- In fade mode, ignore SET_COLOR_TARGET if it matches the preset "On" or "Dim" color
    -- The proxy sometimes sends these to "correct" the color, but we're handling
    -- the fade color calculation ourselves in SET_BRIGHTNESS_TARGET
    if COLOR_ON_MODE_FADE_ENABLED then
        local ignored = false
        local reason = nil

        -- Check if it matches the "On" color (100% brightness preset)
        if COLOR_ON_X and COLOR_ON_Y then
            local dx = math.abs(targetX - COLOR_ON_X)
            local dy = math.abs(targetY - COLOR_ON_Y)
            if dx < 0.005 and dy < 0.005 then
                ignored = true
                reason = "matches preset On color"
            end
        end

        -- Check if it matches the "Dim" color (1% brightness preset)
        if not ignored and COLOR_FADE_X and COLOR_FADE_Y then
            local dx = math.abs(targetX - COLOR_FADE_X)
            local dy = math.abs(targetY - COLOR_FADE_Y)
            if dx < 0.005 and dy < 0.005 then
                ignored = true
                reason = "matches preset Dim color"
            end
        end

        if ignored then
            if DEBUGPRINT then
                print("[DEBUG COLOR] SET_COLOR_TARGET ignored (fade mode, " .. reason .. ")")
                print("[DEBUG COLOR]   Target: X=" .. tostring(targetX) .. ", Y=" .. tostring(targetY))
            end
            return
        end
    end

    local rate = tonumber(tParams.LIGHT_COLOR_TARGET_RATE) or 0  -- Rate in milliseconds (renamed from RATE in 3.3.2)

    -- Determine what color modes the light supports
    local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
    local lightSupportsFullColor = HasValue(SUPPORTED_ATTRIBUTES, "hs") or
                                    HasValue(SUPPORTED_ATTRIBUTES, "xy") or
                                    HasValue(SUPPORTED_ATTRIBUTES, "rgb") or
                                    HasValue(SUPPORTED_ATTRIBUTES, "rgbw") or
                                    HasValue(SUPPORTED_ATTRIBUTES, "rgbww")

    -- DEBUG: Log incoming parameters
    if DEBUGPRINT then
        print("[DEBUG COLOR] SET_COLOR_TARGET: X=" .. tostring(targetX) .. ", Y=" .. tostring(targetY) .. ", mode=" .. tostring(colorMode) .. ", rate=" .. tostring(rate) .. "ms")
        print("[DEBUG COLOR] Light supports: CCT=" .. tostring(lightSupportsCCT) .. ", FullColor=" .. tostring(lightSupportsFullColor))
    end

    -- Cancel any existing color ramp timer
    if COLOR_RAMP_TIMER then
        COLOR_RAMP_TIMER:Cancel()
        COLOR_RAMP_TIMER = nil
    end

    -- Set up ramp timer to send CHANGED after ramp completes
    -- HA reports target state immediately, so we suppress CHANGED during ramp
    if rate > 0 then
        COLOR_RAMP_PENDING = false
        COLOR_RAMP_PENDING_DATA = nil
        COLOR_RAMP_TIMER = C4:SetTimer(rate, function(timer)
            COLOR_RAMP_TIMER = nil
            if DEBUGPRINT then
                print("[DEBUG COLOR] Color ramp timer complete, pending=" .. tostring(COLOR_RAMP_PENDING))
            end
            -- If we received a state update during ramp, now send CHANGED
            if COLOR_RAMP_PENDING and COLOR_RAMP_PENDING_DATA then
                COLOR_RAMP_PENDING = false
                local data = COLOR_RAMP_PENDING_DATA
                COLOR_RAMP_PENDING_DATA = nil
                if DEBUGPRINT then
                    print("[DEBUG COLOR] Forwarding LIGHT_COLOR_CHANGED: X=" .. tostring(data.x) .. ", Y=" .. tostring(data.y) .. ", mode=" .. tostring(data.mode))
                end
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = data.x,
                    LIGHT_COLOR_CURRENT_Y = data.y,
                    LIGHT_COLOR_CURRENT_COLOR_MODE = data.mode
                })
            end
        end)
    end

    -- Notify proxy that color is changing (Color Target API)
    C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
        LIGHT_COLOR_TARGET_X = targetX,
        LIGHT_COLOR_TARGET_Y = targetY,
        LIGHT_COLOR_TARGET_COLOR_MODE = colorMode,
        LIGHT_COLOR_TARGET_COLOR_RATE = rate
    })

    local colorServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {},
        target = {
            entity_id = EntityID
        }
    }

    -- Determine what to send based on C4's request and light's capabilities
    -- Priority: honor C4's mode if light supports it, otherwise convert
    local sendAsCCT = false

    if colorMode == 1 then
        -- C4 requests CCT
        if lightSupportsCCT then
            sendAsCCT = true
        else
            -- Light doesn't support CCT, send as xy (rare case)
            sendAsCCT = false
        end
    else
        -- C4 requests full color (mode=0)
        if lightSupportsFullColor then
            sendAsCCT = false
        elseif lightSupportsCCT then
            -- Light only supports CCT, must convert
            sendAsCCT = true
        end
    end

    if sendAsCCT then
        -- Send as color_temp_kelvin
        local kelvin = C4:ColorXYtoCCT(targetX, targetY)
        colorServiceCall.service_data.color_temp_kelvin = kelvin
        if DEBUGPRINT then
            print("[DEBUG COLOR] Sending as CCT: XY(" .. tostring(targetX) .. "," .. tostring(targetY) .. ") -> " .. tostring(kelvin) .. "K")
        end
    else
        -- Send as xy_color
        colorServiceCall.service_data.xy_color = { targetX, targetY }
        if DEBUGPRINT then
            print("[DEBUG COLOR] Sending as XY: (" .. tostring(targetX) .. "," .. tostring(targetY) .. ")")
        end
    end

    -- Add transition time (convert ms to seconds)
    if rate > 0 then
        colorServiceCall.service_data.transition = rate / 1000
    end

    local jsonPayload = JSON:encode(colorServiceCall)

    if DEBUGPRINT then
        print("[DEBUG COLOR] SET_COLOR_TARGET sending to HA: " .. jsonPayload)
    end

    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = jsonPayload })
end

-- Set light brightness with optional transition rate.
-- In fade mode, also calculates and applies interpolated color.
function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams)

    if DEBUGPRINT then
        Helpers.dumpTable(tParams, "RFP.SET_BRIGHTNESS_TARGET tParams")
    end

    local target = tonumber(tParams.LIGHT_BRIGHTNESS_TARGET)
    local rate = tonumber(tParams.RATE)
    local presetId = tParams.LIGHT_BRIGHTNESS_TARGET_PRESET_ID

    -- Apply default rate if not specified
    if rate == nil then
        rate = DEFAULT_BRIGHTNESS_RATE
    end

    -- Detect off→on transition
    local turningOn = (LIGHT_LEVEL == 0 or not WAS_ON) and target > 0

    -- Track preset ID and target level for reporting in LIGHT_BRIGHTNESS_CHANGED
    if presetId ~= nil then
        LIGHT_BRIGHTNESS_PRESET_ID = tonumber(presetId)
        LIGHT_BRIGHTNESS_PRESET_LEVEL = target
    else
        LIGHT_BRIGHTNESS_PRESET_ID = nil
        LIGHT_BRIGHTNESS_PRESET_LEVEL = nil
    end

    -- Cancel any existing ramp timer
    if BRIGHTNESS_RAMP_TIMER then
        BRIGHTNESS_RAMP_TIMER:Cancel()
        BRIGHTNESS_RAMP_TIMER = nil
    end

    -- Set up ramp timer to send CHANGED after ramp completes
    if rate > 0 then
        BRIGHTNESS_RAMP_PENDING = false
        BRIGHTNESS_RAMP_TIMER = C4:SetTimer(rate, function(timer)
            BRIGHTNESS_RAMP_TIMER = nil
            if DEBUGPRINT then
                print("[DEBUG RAMP] Ramp timer complete, LIGHT_LEVEL=" .. tostring(LIGHT_LEVEL) .. 
                      ", pending=" .. tostring(BRIGHTNESS_RAMP_PENDING))
            end
            if BRIGHTNESS_RAMP_PENDING then
                BRIGHTNESS_RAMP_PENDING = false
                C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
            end
        end)
    end

    -- Notify proxy that brightness is changing
    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGING', {
        LIGHT_BRIGHTNESS_CURRENT = LIGHT_LEVEL,
        LIGHT_BRIGHTNESS_TARGET = target,
        RATE = rate
    })

    local targetMappedValue = MapValue(target, 255, 100)
    local brightnessServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {
            brightness = targetMappedValue
        },
        target = {
            entity_id = EntityID
        }
    }

    -- Add transition time for dimmable lights
    if HAS_BRIGHTNESS then
        print("[DEBUG RAMP] SET_BRIGHTNESS_TARGET: Adding transition time of " .. tostring(rate) .. "ms")
        brightnessServiceCall.service_data.transition = rate / 1000
    end

    -- Determine color to apply
    local colorX, colorY, colorMode = nil, nil, nil

    if target > 0 then
        if COLOR_ON_MODE_FADE_ENABLED and COLOR_ON_X and COLOR_FADE_X then
            -- Fade/Dim-to-warm: Always interpolate color based on brightness level
            colorX = COLOR_FADE_X + (COLOR_ON_X - COLOR_FADE_X) * target * 0.01
            colorY = COLOR_FADE_Y + (COLOR_ON_Y - COLOR_FADE_Y) * target * 0.01
            colorMode = COLOR_ON_MODE
            
            if DEBUGPRINT then
                print("[DEBUG COLOR] Dim-to-warm: brightness=" .. tostring(target) .. 
                      "% -> XY(" .. tostring(colorX) .. "," .. tostring(colorY) .. ")")
            end
        elseif turningOn then
            -- Not fade mode, but turning on - check preset vs previous
            if COLOR_PRESET_ORIGIN == 1 and PREVIOUS_ON_COLOR_X then
                -- Previous mode: restore last color
                colorX = PREVIOUS_ON_COLOR_X
                colorY = PREVIOUS_ON_COLOR_Y
                colorMode = PREVIOUS_ON_COLOR_MODE
                
                if DEBUGPRINT then
                    print("[DEBUG COLOR] Applying previous on-color: XY(" .. 
                          tostring(colorX) .. "," .. tostring(colorY) .. ")")
                end
            elseif COLOR_PRESET_ORIGIN == 2 and COLOR_ON_X then
                -- Preset mode: apply configured preset color
                colorX = COLOR_ON_X
                colorY = COLOR_ON_Y
                colorMode = COLOR_ON_MODE
                
                if DEBUGPRINT then
                    print("[DEBUG COLOR] Applying preset on-color: XY(" .. 
                          tostring(colorX) .. "," .. tostring(colorY) .. ")")
                end
            end
        end

        -- Apply color if determined
        if colorX and colorY then
            local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
            if lightSupportsCCT and (colorMode == 1 or colorMode == nil) then
                local kelvin = C4:ColorXYtoCCT(colorX, colorY)
                brightnessServiceCall.service_data.color_temp_kelvin = kelvin
                if DEBUGPRINT then
                    print("[DEBUG COLOR] Sending as CCT " .. tostring(kelvin) .. "K")
                end
            else
                brightnessServiceCall.service_data.xy_color = { colorX, colorY }
                if DEBUGPRINT then
                    print("[DEBUG COLOR] Sending as XY")
                end
            end

            -- Notify proxy of color change
            C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
                LIGHT_COLOR_TARGET_X = colorX,
                LIGHT_COLOR_TARGET_Y = colorY,
                LIGHT_COLOR_TARGET_COLOR_MODE = colorMode or 0,
                LIGHT_COLOR_TARGET_COLOR_RATE = DEFAULT_COLOR_RATE
            })
        end
    end


    if not HAS_BRIGHTNESS then
        brightnessServiceCall.service_data = {}
    end

    if target == 0 then
        local transition = brightnessServiceCall.service_data.transition
        brightnessServiceCall.service_data = { transition = transition }
        brightnessServiceCall["service"] = "turn_off"
    end


    Helpers.dumpTable(brightnessServiceCall, "Brightness Service Call to HA")

    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(brightnessServiceCall) })
end

-- Legacy level commands - redirect to SET_BRIGHTNESS_TARGET
function RFP.SET_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

function RFP.GROUP_SET_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

function RFP.GROUP_RAMP_TO_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

-- Apply a light effect (if supported by HA entity)
function RFP.SELECT_LIGHT_EFFECT(idBinding, strCommand, tParams)
    local brightnessServiceCall = {
        domain = "light",
        service = "turn_on",

        service_data = {
            effect = tostring(tParams.value)
        },

        target = {
            entity_id = EntityID
        }
    }

    tParams = {
        JSON = JSON:encode(brightnessServiceCall)
    }

    C4:SendToProxy(999, "HA_CALL_SERVICE", tParams)
end

--[[===========================================================================
    Home Assistant State Handlers
===========================================================================]]

-- Handle initial state response from HA
function RFP.RECEIEVE_STATE(idBinding, strCommand, tParams)
    local jsonData = JSON:decode(tParams.response)
    if jsonData ~= nil then Parse(jsonData) end
end

-- Handle real-time state change events from HA
function RFP.RECEIEVE_EVENT(idBinding, strCommand, tParams)
    local jsonData = JSON:decode(tParams.data)
    if jsonData ~= nil then
        Parse(jsonData["event"]["data"]["new_state"])
    end
end

-- Parse HA state and notify C4 proxy of changes.
-- Handles brightness, color, effects, and dynamic capability updates.
function Parse(data)
    if data == nil then
        print("NO DATA")
        return
    end

    if data["entity_id"] ~= EntityID then
        return
    end

    if not Connected then
        C4:SendToProxy(5001, 'ONLINE_CHANGED', { STATE = true })
        Connected = true
    end

    local attributes = data["attributes"]
    local state = data["state"]

    if state ~= nil then
        if state == "off" then
            WAS_ON = false
            LIGHT_LEVEL = 0
            -- If ramping, defer CHANGED notification until ramp completes
            if BRIGHTNESS_RAMP_TIMER then
                BRIGHTNESS_RAMP_PENDING = true
            else
                C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(0))
            end
        elseif state == "on" and not HAS_BRIGHTNESS then
            WAS_ON = true
            LIGHT_LEVEL = 100
            -- If ramping, defer CHANGED notification until ramp completes
            if BRIGHTNESS_RAMP_TIMER then
                BRIGHTNESS_RAMP_PENDING = true
            else
                C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(100))
            end
        elseif state == "on" then
            WAS_ON = true
        end
    end

    if attributes == nil then
        C4:SendToProxy(5001, 'ONLINE_CHANGED', { STATE = false })
        return
    end

    local selectedAttribute = attributes["brightness"]
    if selectedAttribute ~= nil then
        LIGHT_LEVEL = MapValue(tonumber(selectedAttribute), 100, 255)
        -- If ramping, defer CHANGED notification until ramp completes
        if BRIGHTNESS_RAMP_TIMER then
            BRIGHTNESS_RAMP_PENDING = true
        else
            C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
        end
    end

    -- Handle color updates from HA
    -- Check HA's color_mode to determine if CCT or Full Color
    local haColorMode = attributes["color_mode"]  -- "color_temp", "xy", "hs", "rgb", etc.

    if haColorMode == "color_temp" then
        -- CCT mode: use color_temp_kelvin and convert to XY
        local kelvin = attributes["color_temp_kelvin"]
        if kelvin ~= nil then
            local x, y = C4:ColorCCTtoXY(kelvin)
            if DEBUGPRINT then
                print("[DEBUG COLOR] HA CCT mode: " .. tostring(kelvin) .. "K -> XY(" .. tostring(x) .. "," .. tostring(y) .. ")")
            end
            -- If color ramping, defer CHANGED notification until ramp completes
            if COLOR_RAMP_TIMER then
                COLOR_RAMP_PENDING = true
                COLOR_RAMP_PENDING_DATA = { x = x, y = y, mode = 1 }
                if DEBUGPRINT then
                    print("[DEBUG COLOR] LIGHT_COLOR_CHANGED postponed (color ramp in progress)")
                end
            else
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = x,
                    LIGHT_COLOR_CURRENT_Y = y,
                    LIGHT_COLOR_CURRENT_COLOR_MODE = 1  -- CCT mode
                })
            end
        end
    elseif haColorMode ~= nil then
        -- Full color mode: use xy_color directly (HA normalizes to xy internally)
        local xyTable = attributes["xy_color"]
        if xyTable ~= nil then
            if DEBUGPRINT then
                print("[DEBUG COLOR] HA Full Color mode (" .. haColorMode .. "): XY(" .. tostring(xyTable[1]) .. "," .. tostring(xyTable[2]) .. ")")
            end
            -- If color ramping, defer CHANGED notification until ramp completes
            if COLOR_RAMP_TIMER then
                COLOR_RAMP_PENDING = true
                COLOR_RAMP_PENDING_DATA = { x = xyTable[1], y = xyTable[2], mode = 0 }
                if DEBUGPRINT then
                    print("[DEBUG COLOR] LIGHT_COLOR_CHANGED postponed (color ramp in progress)")
                end
            else
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = xyTable[1],
                    LIGHT_COLOR_CURRENT_Y = xyTable[2],
                    LIGHT_COLOR_CURRENT_COLOR_MODE = 0  -- Full color mode
                })
            end
        end
    end

    selectedAttribute = attributes["min_color_temp_kelvin"]
    if selectedAttribute ~= nil and MIN_K_TEMP ~= tonumber(selectedAttribute) then
        MIN_K_TEMP = tonumber(selectedAttribute)
    end

    selectedAttribute = attributes["max_color_temp_kelvin"]
    if selectedAttribute ~= nil and MAX_K_TEMP ~= tonumber(selectedAttribute) then
        MAX_K_TEMP = tonumber(selectedAttribute)
    end

    selectedAttribute = attributes["effect"]
    if selectedAttribute ~= nil and LAST_EFFECT ~= selectedAttribute then
        LAST_EFFECT = selectedAttribute

        C4:SendToProxy(5001, 'EXTRAS_STATE_CHANGED', { XML = GetEffectsStateXML() }, 'NOTIFY')
    elseif selectedAttribute == nil then
        LAST_EFFECT = "Select Effect"
        C4:SendToProxy(5001, 'EXTRAS_STATE_CHANGED', { XML = GetEffectsStateXML() }, 'NOTIFY')
    end

    selectedAttribute = attributes["effect_list"]
    if selectedAttribute ~= nil and not TablesMatch(EFFECTS_LIST, selectedAttribute) then
        EFFECTS_LIST = selectedAttribute
        HAS_EFFECTS = true

        C4:SendToProxy(5001, 'EXTRAS_SETUP_CHANGED', { XML = GetEffectsXML() }, 'NOTIFY')
    elseif selectedAttribute == nil then
        EFFECTS_LIST = {}
        HAS_EFFECTS = false
    end

    selectedAttribute = attributes["supported_color_modes"]
    if selectedAttribute ~= nil and not TablesMatch(SUPPORTED_ATTRIBUTES, selectedAttribute) then
        SUPPORTED_ATTRIBUTES = selectedAttribute

        HAS_BRIGHTNESS = true
        local hasColor = false
        local hasCCT = false

        if HasValue(SUPPORTED_ATTRIBUTES, "onoff") then
            HAS_BRIGHTNESS = false
        elseif HasValue(SUPPORTED_ATTRIBUTES, "brightness") then
            HAS_BRIGHTNESS = true
        end

        if GetStatesHasColor() then
            hasColor = true
        end

        if GetStatesHasCCT() then
            hasCCT = true
        end

        if hasCCT == false then
            MIN_K_TEMP = 0
            MAX_K_TEMP = 0
        end

        local tParams = {
            dimmer = HAS_BRIGHTNESS,
            set_level = HAS_BRIGHTNESS,
            supports_target = HAS_BRIGHTNESS,
            supports_color = hasColor,
            supports_color_correlated_temperature = hasCCT,
            color_correlated_temperature_min = MIN_K_TEMP,
            color_correlated_temperature_max = MAX_K_TEMP,
            has_extras = HAS_EFFECTS,
            color_trace_tolerance = COLOR_TRACE_TOLERANCE
        }

        C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', tParams, "NOTIFY")
    end
end

-- Check if light supports any color mode
function GetStatesHasColor()
    return HasValue(SUPPORTED_ATTRIBUTES, "hs")
        or HasValue(SUPPORTED_ATTRIBUTES, "xy") or HasValue(SUPPORTED_ATTRIBUTES, "rgb")
        or HasValue(SUPPORTED_ATTRIBUTES, "rgbw") or HasValue(SUPPORTED_ATTRIBUTES, "rgbww")
end

function GetStatesHasCCT()
    return HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
        or GetStatesHasColor()  
        -- Ok, maybe this a bit ambitious to call RGB as CCT capable, but it 
        -- will display the CCT slider for RGB lights, which is better than not
        -- displaying it.  I don't knwo if there are other knock on effects.
end

-- Build XML for current effect state (for Navigator display)
function GetEffectsStateXML()
    return '<extras_state><extra><object id="effect" value="' .. LAST_EFFECT .. '"/></extra></extras_state>'
end

-- Build XML for effect picker UI
function GetEffectsXML()
    local items = ""
    for _, effect in pairs(EFFECTS_LIST) do
        items = items .. '<item text="' .. effect .. '" value="' .. effect .. '"/>'
    end
    return '<extras_setup><extra><section label="Effects"><object type="list" id="effect" label="Effect" command="SELECT_LIGHT_EFFECT" value="'
        .. LAST_EFFECT .. '"><list maxselections="1" minselections="1">' .. items .. '</list></object></section></extra></extras_setup>'
end

--[[===========================================================================
    Property Change Handlers (OPC.*)
===========================================================================]]

-- Handle Color Trace Tolerance property change from Composer
function OPC.Color_Trace_Tolerance(value)
    COLOR_TRACE_TOLERANCE = tonumber(value)

    if DEBUGPRINT then
        print("[DEBUG] OPC.Color_Trace_Tolerance :: Color Trace Tolerance set to: " .. tostring(COLOR_TRACE_TOLERANCE))
    end

    C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', {
        color_trace_tolerance = COLOR_TRACE_TOLERANCE
    }, "NOTIFY")

    C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', {
        color_trace_tolerance = 0.01
    }, "NOTIFY")
end
