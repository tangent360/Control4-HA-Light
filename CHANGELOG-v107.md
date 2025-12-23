# HA Light Driver v107 - Technical Documentation

## Summary

### New Features
- **Color On Mode Previous** - Enables the "Previous" color restore option in Composer Pro
- **Color On Mode Fade (Dim-to-Warm)** - Linear color interpolation between dim and bright colors based on brightness level
- **Configurable Color Trace Tolerance** - Adjustable Delta E tolerance for scene color matching

### Fixes
- **Transition Rate Handling** - Brightness and color ramp times now properly respected
- **Advanced Lighting Scenes (ALS)** - Full `advanced_scene_support` API implementation
- **Scene Color Tracking** - Scenes now correctly mark as "Active" when color matches within tolerance

### Improvements
- **Preset ID Support** - Daylight Agent preset tracking for brightness commands
- **Combined Scene Commands** - Brightness and color sent together to prevent visual artifacts
- **Ramp Timer Management** - Deferred state notifications during transitions for accurate scene tracking

---

## Technical Details

### 1. Color On Mode Capabilities

Two new capabilities were added to `driver.xml`:

```xml
<capabilities>
    <color_on_mode_previous>True</color_on_mode_previous>
    <color_on_mode_fade>True</color_on_mode_fade>
</capabilities>
```

**`color_on_mode_previous`**: Enables the "Previous" option in Composer Pro's Color On Mode settings. The proxy automatically tracks the last reported color before brightness goes to 0 and restores it on the next turn-on command. No driver-side logic is required beyond declaring the capability.

**`color_on_mode_fade`**: Enables dim-to-warm behavior where the driver calculates an interpolated color based on brightness level.

### 2. Dim-to-Warm Implementation

When the dealer configures "Fade" mode in Composer Pro, the proxy sends `UPDATE_COLOR_ON_MODE` with two color presets:
- **On color** - The target color at 100% brightness
- **Dim color** - The target color at 1% brightness

The driver stores these values:

```lua
COLOR_ON_X, COLOR_ON_Y     -- On color (100%)
COLOR_FADE_X, COLOR_FADE_Y -- Dim color (1%)
COLOR_ON_MODE_FADE_ENABLED -- True when both presets are defined
```

The interpolation formula in `SET_BRIGHTNESS_TARGET`:

```lua
fadeX = COLOR_FADE_X + (COLOR_ON_X - COLOR_FADE_X) * brightness * 0.01
fadeY = COLOR_FADE_Y + (COLOR_ON_Y - COLOR_FADE_Y) * brightness * 0.01
```

The calculated color is sent alongside brightness in a single Home Assistant service call:

```lua
brightnessServiceCall.service_data.color_temp_kelvin = C4:ColorXYtoCCT(fadeX, fadeY)
```

### 3. Suppressing Unwanted Color Commands in Fade Mode

**Discovery**: When fade mode is active, the C4 proxy periodically sends `SET_COLOR_TARGET` commands with the preset On or Dim color values. These commands would override the driver's calculated fade color, causing the light to jump to the preset color instead of the interpolated color.

**Solution**: The driver compares incoming `SET_COLOR_TARGET` coordinates against the stored preset colors and ignores commands that match:

```lua
if COLOR_ON_MODE_FADE_ENABLED then
    -- Check if target matches "On" color
    if COLOR_ON_X and COLOR_ON_Y then
        local dx = math.abs(targetX - COLOR_ON_X)
        local dy = math.abs(targetY - COLOR_ON_Y)
        if dx < 0.005 and dy < 0.005 then
            return  -- Ignore this command
        end
    end

    -- Check if target matches "Dim" color
    if COLOR_FADE_X and COLOR_FADE_Y then
        local dx = math.abs(targetX - COLOR_FADE_X)
        local dy = math.abs(targetY - COLOR_FADE_Y)
        if dx < 0.005 and dy < 0.005 then
            return  -- Ignore this command
        end
    end
end
```

The tolerance of 0.005 in XY space accounts for floating-point rounding. Commands with different colors (e.g., scene activations, manual color changes) pass through normally.

**Limitation**: If the Composer UI has other color presets configured that don't match the current On/Dim presets, those sync commands will still reach the driver. This appears to be a Composer configuration issue rather than a driver issue.

### 4. Ramp Timer Management

**Discovery**: Home Assistant reports the target state immediately when a transition command is sent, rather than waiting for the transition to complete. If the driver forwards this state to C4 immediately, C4's scene tracking compares the target against the current (mid-transition) state and may incorrectly mark the scene as inactive.

**Solution**: When a brightness or color command includes a rate > 0, the driver:
1. Sets a timer for the duration of the ramp
2. Defers `LIGHT_BRIGHTNESS_CHANGED` and `LIGHT_COLOR_CHANGED` notifications until the timer expires
3. Stores pending state data if HA reports during the ramp

```lua
if rate > 0 then
    BRIGHTNESS_RAMP_PENDING = false
    BRIGHTNESS_RAMP_TIMER = C4:SetTimer(rate, function(timer)
        BRIGHTNESS_RAMP_TIMER = nil
        if BRIGHTNESS_RAMP_PENDING then
            BRIGHTNESS_RAMP_PENDING = false
            C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', ...)
        end
    end)
end
```

In the `Parse()` function that handles HA state updates:

```lua
if BRIGHTNESS_RAMP_TIMER then
    BRIGHTNESS_RAMP_PENDING = true  -- Defer notification
else
    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', ...)  -- Immediate
end
```

### 5. Combined Scene Commands

**Discovery**: When `ACTIVATE_SCENE` includes both brightness and color, the driver originally executed them as separate HA commands. With dim-to-warm enabled, this caused a visual flash:
1. `SET_BRIGHTNESS_TARGET` applied the dim-to-warm interpolated color
2. Milliseconds later, `SET_COLOR_TARGET` applied the scene's actual color

**Solution**: When a scene has both brightness and color enabled, send them as a single HA service call:

```lua
if (levelEnabled or el.level ~= nil or el.brightness ~= nil) and colorEnabled then
    local sceneServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {
            brightness = targetMappedValue,
            color_temp_kelvin = kelvin,  -- or xy_color
            transition = maxRate / 1000
        },
        target = { entity_id = EntityID }
    }
    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(sceneServiceCall) })
    return  -- Skip individual brightness/color handling
end
```

### 6. C4 Color Conversion Functions

**Critical**: Always use C4's native color conversion functions to stay within C4's color space. Using external formulas produces different XY values that break scene tracking.

Available functions:
- `C4:ColorCCTtoXY(kelvin)` - Kelvin to CIE 1931 xy
- `C4:ColorXYtoCCT(x, y)` - xy to Kelvin
- `C4:ColorHSVtoXY(h, s, v)` - HSV to xy
- `C4:ColorXYtoHSV(x, y)` - xy to HSV
- `C4:ColorRGBtoXY(r, g, b)` - RGB to xy
- `C4:ColorXYtoRGB(x, y)` - xy to RGB

The round-trip through C4's conversion ensures matching XY coordinates:
1. Receive XY from C4 scene
2. Convert to Kelvin: `C4:ColorXYtoCCT(x, y)`
3. Send to HA as `color_temp_kelvin`
4. Receive `color_temp_kelvin` from HA
5. Convert back: `C4:ColorCCTtoXY(kelvin)`
6. Report to C4 with `LIGHT_COLOR_CHANGED`

### 7. Color Trace Tolerance

The `color_trace_tolerance` capability controls scene color matching precision. Exposed as a configurable property in Composer Pro (range 0.5 to 10.0, default 1.0).

```lua
function OPC.Color_Trace_Tolerance(value)
    COLOR_TRACE_TOLERANCE = tonumber(value) or 1.0
    C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', {
        color_trace_tolerance = COLOR_TRACE_TOLERANCE
    }, "NOTIFY")
end
```

Comparison methods (handled by C4 Director):
- Delta > 0.01: Uses CIE L*a*b* Delta E formula
- Delta <= 0.01: Uses xy chromaticity Euclidean distance

Most humans detect color differences at Delta E >= 3.0.

### 8. Preset ID Support

For Daylight Agent integration, the driver tracks preset IDs from `SET_BRIGHTNESS_TARGET`:

```lua
LIGHT_BRIGHTNESS_PRESET_ID = tonumber(tParams.LIGHT_BRIGHTNESS_TARGET_PRESET_ID)
LIGHT_BRIGHTNESS_PRESET_LEVEL = target

function BuildBrightnessChangedParams(level)
    local params = { LIGHT_BRIGHTNESS_CURRENT = level }
    if LIGHT_BRIGHTNESS_PRESET_ID and LIGHT_BRIGHTNESS_PRESET_LEVEL == level then
        params.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = LIGHT_BRIGHTNESS_PRESET_ID
    end
    return params
end
```

The preset ID is included in `LIGHT_BRIGHTNESS_CHANGED` only when the reported level matches the preset's target level.

### 9. Advanced Lighting Scenes (ALS) Implementation

The driver declares `advanced_scene_support` capability in `driver.xml`:

```xml
<capabilities>
    <advanced_scene_support>True</advanced_scene_support>
</capabilities>
```

This capability requires implementing the following commands:

| Command | Status | Description |
|---------|--------|-------------|
| `PUSH_SCENE` | ✓ Implemented | Stores scene XML data for later activation |
| `ACTIVATE_SCENE` | ✓ Implemented | Executes a stored scene with brightness, color, and rates |
| `RAMP_SCENE_UP` | ✓ Implemented | Ramps to scene's target level (HA lacks continuous ramping) |
| `RAMP_SCENE_DOWN` | ✓ Implemented | Ramps to 0 (HA lacks continuous ramping) |
| `STOP_SCENE_RAMP` | ✓ Implemented | Freezes at current level by sending transition=0 |
| `SYNC_SCENE` | Not needed | Legacy command (pre-3.0.0), handled by PUSH_SCENE |
| `SYNC_ALL_SCENES` | Not needed | Legacy command (pre-3.0.0), handled by PUSH_SCENE |

**PUSH_SCENE**: Parses the scene XML and stores it via `C4:PersistSetValue()`. Scene elements include:
- `level`/`brightness` - Target brightness (0-100)
- `levelEnabled`/`brightnessEnabled` - Whether brightness is part of scene
- `rate`/`brightnessRate` - Transition time in milliseconds
- `colorX`, `colorY` - CIE 1931 xy coordinates
- `colorMode` - 0 (full color) or 1 (CCT)
- `colorEnabled` - Whether color is part of scene
- `colorRate` - Color transition time in milliseconds

**ACTIVATE_SCENE**: Retrieves stored scene data and executes it. When both brightness and color are enabled, they are sent as a single HA command to prevent race conditions with dim-to-warm.

**RAMP_SCENE_UP/DOWN**: Since Home Assistant doesn't support continuous ramping (press-and-hold behavior), we implement these by:
- UP: Ramp to the scene's target brightness level
- DOWN: Ramp to 0

**STOP_SCENE_RAMP**: Sends the current brightness level to HA with `transition=0` to freeze at the current position.

**Note on SYNC_SCENE/SYNC_ALL_SCENES**: Per C4 documentation, these are legacy commands used as workarounds pre-3.0.0. They are not needed if `PUSH_SCENE` is properly handled, which it is.

**Performance requirement**: The driver uses the Brightness Target API (`LIGHT_BRIGHTNESS_CHANGING`/`LIGHT_BRIGHTNESS_CHANGED`) and only sends one level update when the hardware reaches the final scene level. This is achieved through ramp timer management that defers `CHANGED` notifications until the transition completes.

---

## Files Modified

- `driver.xml` - Added `color_on_mode_previous` and `color_on_mode_fade` capabilities
- `commands.lua` - All handler implementations

## Testing Notes

1. Enable Debug Mode in Composer Pro to see detailed logging
2. Test dim-to-warm by adjusting brightness and observing color temperature
3. Test scene activation with both brightness and color enabled
4. Verify scene shows "Active" status after activation
5. Test transition rates by observing ramp timing matches configured values
6. Test scene ramp up/down by holding buttons in Navigator (if keypads support it)
7. Verify PUSH_SCENE stores data correctly (check debug output on driver load)
