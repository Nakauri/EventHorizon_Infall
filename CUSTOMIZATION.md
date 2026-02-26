# EventHorizon Infall, Customization Guide

This guide explains every setting you can change in Infall.


## Settings GUI (The Easy Way)

Type `/infall setup` or go to **Escape > Options > AddOns > EventHorizon Infall** to open the settings panel. From there you can change everything without editing files: bar layout, colours, fonts, toggles, buff pairings, cast pairings, stack tracking, and more. Changes are saved per character and per spec automatically.

The settings panel has five tabs:

- **Bars** shows all your Cooldown Manager abilities with visibility checkboxes, buff pairing, cast pairing, and stack tracking slots. Abilities with charges also show a "Show Charge" checkbox to toggle between split and single bar display. The bottom area has two pool tabs: "Buffs" shows CDM buffs and debuffs (for Buff and Stack slots), and "Casts" auto populates from your spellbook with casts and channels (for Cast slots). Click an icon in a pool, then click a slot on a row. Right click a paired slot to unpair. Each slot has a colour swatch for custom colours.
- **Display** has sliders for bar width, height, spacing, padding, scale, timeline length, icon size, and more. Click any slider's number to type an exact value.
- **Colours** lets you change every colour in the addon, plus font settings and text anchor positions.
- **Toggles** has on/off switches for all features, plus Reload Bars and Reset Position buttons.
- **Profiles** lets you save, load, and delete named profiles. Your settings are automatically saved per character and per spec, but named profiles let you share a setup across characters or keep backups.

Most users will never need to edit files directly. The Settings GUI handles everything.


## Manual Editing (For Class Configs and Advanced Use)

Infall reads your WoW Cooldown Manager and mirrors it as a set of horizontal timeline bars. Each ability gets one row: an icon on the left and a bar on the right that shows cooldowns, casts, buffs, and debuffs sliding across a relative timeline.

The addon has a few files you might interact with:

1. **Core.lua** All the default settings (colours, sizes, spacing, fonts, and so on). You can edit this directly if you want to change defaults, but the Settings GUI is easier for most things.
2. **ClassConfig/** (`ClassConfig/Druid.lua`, `ClassConfig/Hunter.lua`, and so on) Spell mappings and class-specific settings. The Settings GUI now handles buff pairing, cast pairing, cast colours, and stack tracking visually. ClassConfig files are still useful for setting defaults that apply before the GUI loads.
3. **Bars.lua** The engine. You should not need to edit this.

**How settings work:** Core.lua sets the global defaults. Your ClassConfig file loads after Core.lua and can override any setting or add spell mappings. Settings.lua captures those defaults and manages per-character profiles. Bars.lua loads last and reads everything.

**Where to put your changes:** The Settings GUI handles everything including buff pairing, cast pairing, cast colours, and stack tracking. ClassConfig files are only needed if you want to set defaults that apply before the first profile save.

**How to edit files:** Open the file in any text editor (Notepad, VS Code, whatever). Make your change, save the file, then type `/reload` in WoW to apply it.


## The Cooldown Manager (Read This First)

Infall does not have its own ability list. It reads from WoW's built in Cooldown Manager, which is a feature Blizzard added in patch 12.0 (Midnight). The Cooldown Manager is where you choose which abilities appear as cooldown icons above or below your action bars. Infall mirrors whatever is in there, so if an ability is in the Cooldown Manager, it shows up in Infall. If it's not, it doesn't.

Infall requires the Cooldown Manager to be enabled. If it detects that the CDM is available but turned off, it will enable it automatically on login and let you know in chat. You can find the setting manually at **Escape > Options > Gameplay > Combat > Enable Cooldown Manager**.

### Opening the Cooldown Manager

Press **Escape > Edit Mode > Cooldown Manager** to open it directly. You can also open it from within Infall's settings panel (type `/infall setup`, then click "Open Cooldown Manager" on the Bars tab). You'll see a panel where you can add, remove, and reorder abilities. Each ability you add gets a cooldown icon in the default UI and a timeline bar in Infall.

### Why Do I See Abilities I Didn't Add?

When you first open the Cooldown Manager on a character, Blizzard auto populates it with a set of abilities it thinks are relevant for your class and spec. This means you might see things like Astral Recall, Heroism, or other abilities you don't care about tracking. This is normal. Blizzard picked them, not Infall.

To fix this, open the Cooldown Manager and remove the ones you don't want. You can also reorder the list, which changes the order bars appear in Infall.

### Why Do I See Nothing?

If your Cooldown Manager is empty (no abilities added), Infall has nothing to read and will show an empty frame or nothing at all. This happens on fresh characters or if you cleared the manager at some point.

To fix this, open the Cooldown Manager and add the abilities you want to track. Once they're in the manager, type `/infall reload` (or `/infall r`) and they'll appear as timeline bars.

### What Should I Put In the Cooldown Manager?

Whatever abilities you want to track. Good candidates are rotational cooldowns (abilities with a cooldown you press often), offensive and defensive cooldowns, procs, and anything with a buff or debuff you want to watch. You don't need to add every ability you have, just the ones where seeing the timeline is useful.

Infall's buff and debuff tracking, cast overlays, and stack counts are all tied to Cooldown Manager entries. If an ability isn't in the Cooldown Manager, Infall can't track anything related to it.


## In Game Commands

Many features can be toggled or adjusted in game without editing files. Toggle commands are saved to your active profile (per character and spec) and persist across sessions.

### Toggle Commands

These flip a feature on or off each time you run them. Changes are saved to your profile automatically.

| Command | What It Does |
|---|---|
| `/infall` | Show all available commands |
| `/infall reload` | Reload cooldown bars (use after changing WoW cooldown settings if they're stuck). Also available as `/infall r` |
| `/infall setup` | Open the Infall settings panel (ESC > Options > AddOns > EventHorizon Infall) |
| `/infall reactive` | Toggle reactive icon colouring where icons change colour based on usability, range, and mana. Also enables cooldown swirl overlays on icons |
| `/infall desat` | Toggle greying out icons while the ability is on cooldown |
| `/infall redshift` | Toggle Redshift, which hides the frame when you're out of combat with no target. Also available as `/infall rs` |
| `/infall pandemic` | Toggle pandemic pulse for debuff bars glowing when in the refresh window (default UI only, see Known Limitations). Also available as `/infall pan` |
| `/infall castbar` | Toggle hiding the default Blizzard cast bar. Cannot be used during combat |
| `/infall ecm` | Toggle hiding the Blizzard Cooldown Manager |
| `/infall lock` | Toggle frame lock so that when locked, you can't accidentally drag the frame |
| `/infall reset` | Reset the frame position to the centre of your screen. Cannot be used during combat |
| `/infall icons` | Toggle icon visibility. When hidden, icons collapse to a narrow strip and the bars take up more space. Charge and stack counts still show as text |
| `/infall bufflayer` | Toggle whether buff/debuff bars draw above or below cooldown bars. Default is below so cooldowns are more visible. Also available as `/infall bl` |
| `/infall clickthrough` | Toggle click through mode. When enabled, the frame ignores mouse clicks. Also available as `/infall ct` |

### Value Commands

These take a number or value after the command. Running them without a value shows the current setting. Layout changes from slash commands last until reload. To make them permanent, either use the Settings GUI (which saves everything to your profile automatically) or add the CONFIG line to Core.lua as each command tells you.

| Command | What It Does |
|---|---|
| `/infall scale 1.2` | Set the overall frame scale (0.5 to 3.0). Running `/infall scale` alone shows the current value |
| `/infall past 2.5` | Set the past timeline duration in seconds (0 to 10). Use `/infall past off` to disable. See the Past Timeline section below |
| `/infall lines 1 3 7` | Add vertical time marker lines at the given seconds. Use `/infall lines off` to disable |
| `/infall static 150` | Lock the frame to a fixed pixel height instead of growing with bar count. Optionally add a minimum bar count: `/infall static 150 4`. Use `/infall static off` to disable |
| `/infall nowline 2` | Set the now line width in pixels (1 to 6). Optionally set colour too: `/infall nowline 2 1 1 1 0.7` (width r g b a) |
| `/infall gap 0` | Set the gap between icons and bars in pixels (0 to 30). Default is 10 |
| `/infall hide 12345` | Toggle hiding a specific cooldown bar by its cooldownID. Run `/infall hide` with no ID to list all bars and their IDs |
| `/infall pos 100 -50` | Set exact frame position (offset from centre). Frame position is saved per character |

To move the frame, make sure it's unlocked (`/infall lock` to toggle), then click and drag it.


## Understanding Colours

Every colour in Infall is written as four numbers inside curly braces:

```lua
{red, green, blue, alpha}
```

Each number goes from `0` (none) to `1` (full). The fourth number (`alpha`) controls transparency so `1` is fully solid, `0` is fully invisible, and `0.5` is half transparent.

Some examples:

```lua
{1, 0, 0, 1}          -- solid red
{0, 0, 1, 0.7}        -- blue, slightly transparent
{1, 1, 1, 0.5}        -- white, half transparent
{0, 0, 0, 0}          -- fully invisible (useful for hiding the background)
{0.9, 0.5, 0.3, 0.7}  -- orange
{135/255, 194/255, 255/255, 0.6}  -- you can use math for precise values
```

If you want to pick a colour, find any online colour picker that shows RGB values from 0-255, then divide each number by 255. For example, RGB `(200, 100, 50)` becomes `{200/255, 100/255, 50/255, 1}`.


## Changing the Frame Size and Layout

These settings control how big the frame is, how the bars are spaced, and how much padding surrounds everything. The easiest way to change these is through the Settings GUI (Display tab), which saves changes to your profile automatically. You can also edit Core.lua directly to change the defaults.

### Bar and Icon Dimensions

```lua
CONFIG.width = 352       -- how wide each timeline bar is (in pixels)
CONFIG.height = 20       -- how tall each row is
CONFIG.iconSize = 30     -- how big the ability icon is (always a square)
```

The total width of the frame is: left padding + icon size + 10px gap + bar width + right padding. So with defaults, that's 5 + 30 + 10 + 352 + 5 = 402 pixels wide.

The total height adjusts automatically based on how many abilities you have tracked, unless you set a static height (see below).

### Spacing and Padding

```lua
CONFIG.spacing = 0.5     -- vertical gap between each row (0 = rows touching)
CONFIG.paddingTop = 5    -- empty space above the first row
CONFIG.paddingBottom = 5 -- empty space below the last row
CONFIG.paddingLeft = 5   -- empty space to the left of the rows
CONFIG.paddingRight = 5  -- empty space to the right of the rows
```

### Timeline Length

```lua
CONFIG.future = 16       -- how many seconds into the future the bar shows
```

This controls how much time the bar represents. The left edge of the bar area is the start of the past region (if enabled) or "now" (if past is disabled), and the right edge is this many seconds into the future. A cooldown or buff with more time remaining than this value will start off screen to the right and slide into view as it counts down.

A lower number (like 8) zooms in, so you see less total time but cooldowns and GCDs are more spread out and easier to read. A higher number (like 20) zooms out, so you can see longer cooldowns and DoTs in full, but short durations get compressed into a small area on the left.

### Past Timeline

```lua
CONFIG.past = 2.5        -- how many seconds of past history to show (0 = disabled)
```

When enabled, a region to the left of the "now" line shows recent history. Casts, cooldowns, and buffs leave coloured blocks that slide leftward through this region as they age, giving you a visual log of what just happened. The now line sits between the past and future regions.

This is also adjustable in game with `/infall past 2.5` or disabled with `/infall past off`. The in game value lasts until you reload. To make it permanent, add `CONFIG.past = 2.5` to Core.lua.

Setting this to 0 (or using `/infall past off`) disables the past region entirely and puts the now line at the left edge of the bar.

### Static Height

By default, the frame grows taller as you track more abilities. If you want the frame to stay a fixed size and have the bars scale to fit, use static height.

This is controlled in game only:

- `/infall static 150` locks the frame to 150 pixels tall
- `/infall static 150 4` locks to 150px, but only when you have 4 or more bars (fewer bars use normal sizing)
- `/infall static off` goes back to automatic sizing

The minimum height is 40 pixels. This setting lasts until reload, add `CONFIG.staticHeight = 150` to Core.lua to make it permanent.

### Scale

Scale the entire frame up or down without changing any individual sizes. Useful for high DPI displays or if you want everything proportionally larger or smaller.

- `/infall scale 1.5` makes everything 50% bigger
- `/infall scale 0.8` makes everything 20% smaller
- Range is 0.5 to 3.0, and the default is 1.0

This lasts until reload. To make it permanent, add `CONFIG.scale = 1.5` to Core.lua.

### Smooth Bar Animation

Adds a smooth filling animation to the timeline bars using the game engine's built-in interpolation. Off by default because it can be visually distracting on a fast-updating addon like EventHorizon.

Toggle this in the Settings GUI (Display tab) with the "Smooth Bar Animation" checkbox, or in Core.lua:

```lua
CONFIG.smoothBars = true    -- default: false
```

### Time Markers

Vertical lines at specific time intervals on the timeline, so you can eyeball durations at a glance.

- `/infall lines 1 3 7` draws thin vertical lines at 1s, 3s, and 7s into the future
- `/infall lines off` removes all markers

The lines are subtle and drawn on every row. This lasts until reload. To make it permanent, add `CONFIG.lines = {1, 3, 7}` to Core.lua.

### Now Line Appearance

The now line is the vertical line that separates past from future (or sits at the left edge if past is disabled). You can adjust its width and colour.

- `/infall nowline 2` sets width to 2 pixels
- `/infall nowline 2 1 1 1 0.7` sets width to 2px and colour to white at 70% opacity
- Width range is 1 to 6 pixels

This lasts until reload. To make it permanent, add the settings to Core.lua.

### Example: Making Everything Smaller

If you want a compact frame, put this in Core.lua:

```lua
CONFIG.width = 200
CONFIG.height = 14
CONFIG.iconSize = 20
CONFIG.spacing = 0
CONFIG.paddingTop = 2
CONFIG.paddingBottom = 2
CONFIG.paddingLeft = 2
CONFIG.paddingRight = 2
```

### Example: Making Everything Bigger

```lua
CONFIG.width = 450
CONFIG.height = 26
CONFIG.iconSize = 36
CONFIG.spacing = 2
CONFIG.future = 20
```

## Hiding Icons and Changing Bar Layer Order

These two features are toggled in game with slash commands or from the Settings GUI (Toggles tab). They're saved to your profile automatically, so you only need to set them once. They don't require editing any files.

### Hiding Icons

`/infall icons` collapses the icon column. Instead of the full ability icon, each row shows a narrow 20px strip with just the charge or stack count as text. The bars stretch wider to fill the freed space and the parent frame shrinks to match. This is experimental and likely needs tweaks.

This is useful if you already know your rotation by feel and just want compact timeline bars without the visual noise of icons, or if you want Infall to take up less horizontal screen space.

### Buff Layer Order

`/infall bufflayer` (or `/infall bl`) controls whether buff and debuff bars render above or below cooldown bars within each row.

By default, cooldown bars draw **above** buff bars. This means if a buff and a cooldown overlap on the timeline, the cooldown colour is what you see in that region. Toggling this puts buff bars on top instead, so the buff colour wins where they overlap.

Which you prefer depends on what information matters more to you. If you care more about seeing exactly when a cooldown ends, the default is fine. If you're mostly watching buff/debuff timers (DoT classes, proc heavy specs), toggle this on so buff bars draw on top.


## Per-Spell Charge Bars

Abilities with multiple charges (IE Fire Blast, Barbed Shot) normally display as split bars, with a separate section for each charge. If you prefer a single full height bar for a specific ability, you can disable the charge bar rendering per spell.

Open the Settings GUI (Bars tab). Abilities with charges show a "Show Charge" checkbox on their row. Uncheck it to switch to a single bar. Check it again to go back to split bars. This setting saves to your profile.

When charge bars are disabled for a spell, the bar renders as one solid bar instead of the split layout. The charge count text still shows on the icon so you can see how many charges are available.


## Charge Reset Workaround

Some abilities instantly reset all charges of another spell (IE Combustion resets Fire Blast, Bestial Wrath resets Barbed Shot). When this happens, the charge bar display can show stale cooldown bars because the game engine doesn't provide a reliable signal for charge resets during combat.

To fix this, open the Settings GUI (Bars tab). Abilities with charges show a "Reset by" slot next to the charge checkbox. Click it and select the ability that resets this spell's charges. When that ability is cast, Infall immediately clears the stale bars and corrects the charge count.

Only use this for abilities that instantly restore ALL charges. Normal charge recovery (charges refilling over time) works automatically and doesn't need this.


## Changing Colours

The Settings GUI (Colours tab) lets you change every colour visually with colour pickers. Changes save to your profile automatically. If you prefer editing files, the settings below go in Core.lua.

### Bar Colours

These control the DEFAULT colour of each bar type.

```lua
CONFIG.cooldownColor = {171/255, 191/255, 181/255, 0.5}  -- the cooldown bar (shows remaining CD time)
CONFIG.castColor = {0.2, 0.8, 0.2, 0.7}                  -- the cast bar (shows while you're casting)
CONFIG.buffColor = {0.4, 0.4, 0.9, 0.6}                  -- player buff overlay (default if no custom colour)
CONFIG.debuffColor = {0.9, 0.3, 0.3, 0.6}                -- target debuff overlay (default if no custom colour)
CONFIG.petBuffColor = {0.3, 0.6, 0.9, 0.7}               -- pet buff overlay
CONFIG.gcdColor = {1, 1, 1, 0.1}                         -- GCD bar (shows global cooldown remaining)
CONFIG.gcdSparkColor = {1, 1, 1, 0.6}                    -- the thin vertical line at the edge of the GCD
```

### Frame Background

```lua
CONFIG.bgcolor = {0, 0, 0, 0.5}     -- the background behind all the bars
CONFIG.bordercolor = {0, 0, 0, 1}   -- the thin border around the frame
```

To make the background invisible (just floating bars with no box), set both to `{0, 0, 0, 0}`.

### Icon Colours

These only work when reactive icons are enabled (they are by default). The icon changes colour to tell you the ability's state.

```lua
CONFIG.iconUsableColor = {1.0, 1.0, 1.0, 1.0}          -- spell is ready to cast (normal white)
CONFIG.iconNotEnoughManaColor = {0.5, 0.5, 1.0, 1.0}   -- you don't have enough mana/resource
CONFIG.iconNotUsableColor = {0.4, 0.4, 0.4, 1.0}       -- spell can't be used right now
CONFIG.iconNotInRangeColor = {0.64, 0.15, 0.15, 1.0}   -- target is out of range
```


## Changing Fonts

Font settings are available in the Settings GUI (Colours tab), including a font dropdown with built in fonts and any LibSharedMedia fonts you have installed. You can also edit these in Core.lua.

The font is used for the charge count (number of charges remaining) and stack count (buff stacks) shown on the ability icon.

```lua
CONFIG.font = nil                -- nil = use WoW's default font. Or set a path like:
                                 -- "Interface\\AddOns\\EventHorizon_Infall\\Fonts\\MyFont.ttf"
CONFIG.fontSize = 14             -- text size
CONFIG.fontFlags = "OUTLINE"     -- options: "OUTLINE", "THICKOUTLINE", "MONOCHROME"
                                 -- you can combine them: "OUTLINE, MONOCHROME"
```

### Charge Text Position

The charge count ("2" for a 2 charge ability) appears on the icon. You can move it:

```lua
CONFIG.chargeTextColor = {1, 1, 1, 1}             -- white
CONFIG.chargeTextAnchor = "BOTTOMRIGHT"           -- where on the icon it sits
CONFIG.chargeTextRelPoint = "BOTTOMRIGHT"         -- anchor relative to
CONFIG.chargeTextOffsetX = -2                     -- nudge left/right (negative = left)
CONFIG.chargeTextOffsetY = 2                      -- nudge up/down (positive = up)
```

### Stack Text Position

The stack count ("3" for 3 stacks of a buff) also appears on the icon, separately from charges:

```lua
CONFIG.stackTextColor = {1, 0.85, 0.3, 1}         -- gold
CONFIG.stackTextAnchor = "BOTTOMLEFT"             -- default: opposite corner from charges
CONFIG.stackTextRelPoint = "BOTTOMLEFT"
CONFIG.stackTextOffsetX = 2
CONFIG.stackTextOffsetY = 2
```

Valid anchor positions are: `"TOPLEFT"`, `"TOP"`, `"TOPRIGHT"`, `"LEFT"`, `"CENTER"`, `"RIGHT"`, `"BOTTOMLEFT"`, `"BOTTOM"`, `"BOTTOMRIGHT"`.


## Finding Spell IDs and Cooldown IDs

To set up spell mappings (extra casts, buff tracking, and so on), you need to know the IDs for your spells and buffs. There are two types of IDs:

- **spellID** is Blizzard's standard spell identifier. You can find these on Wowhead (the number in the URL, like wowhead.com/spell=**190984** for Wrath).
- **cooldownID** is the Cooldown Manager's internal identifier. This is what Infall uses to match bars. It's different from spellID and you need to look it up in game.

The easiest way to find your ability IDs is to use Arc ID https://www.curseforge.com/wow/addons/arc-ids

If you have Arc IDs installed, you can find cooldownIDs and spellIDs by hovering over ability icons in the Cooldown Manager. It adds both IDs to the tooltip, look for lines labeled cooldownID and spellID. This is much easier than running /dump commands. For abilities, just hover over them directly in the Cooldown Manager. For buff and debuff IDs, hover over the buff icon in the buff viewer while the aura is active.

### Map the IDs

Once you have both IDs, you can set up your mapping. For example, if you found:

- Ability cooldownID: `88334` (Moonfire ability)
- Buff cooldownID: `93500` (Moonfire debuff on target)

Then your mapping would be:

```lua
CONFIG.buffMappings = {
    [88334] = {
        {buffCooldownIDs = {93500}, unit = "target"},
    },
}
```

### SpellID vs CooldownID, When to Use Which

- **cooldownID**: Use as the key (the number in square brackets) for all mappings (`extraCasts`, `buffMappings`, `stackMappings`). Cooldown IDs are stable even when a spell transforms. These are what the Cooldown Manager has.
- **spellID**: Use for `extraCasts` values (the casts you want to show), `castColors` keys (which cast to colour), and looking up spells on Wowhead. These are affected the most by the new secret value restrictions, but player casts tend to be safe.

**If a spell transforms** (its icon and name change depending on your state, like Eclipse switching between Solar and Lunar), always use the cooldownID as the key, never the spellID. The spellID will change when the spell transforms, but the cooldownID stays the same.


## Setting Up Extra Casts

Extra casts let you show a cast bar on a row when you cast a related spell. For example, showing your Wrath cast on the Eclipse bar, or Steady Shot on Aimed Shot.

**The easiest way** is through the Settings GUI (Bars tab). Click the "Casts" pool tab at the bottom, which auto populates with casts and channels from your spellbook. Click a spell, then click a Cast 1 or Cast 2 slot on a cooldown row to pair it. You can also set a custom colour for each cast via the colour swatch. Everything saves to your profile.

For mounts, hearthstone, or any spell that doesn't appear in the auto-detected list, use the ClassConfig file to add them manually.

For manual setup, this goes in your ClassConfig class file. The key (number in brackets) is the cooldownID or spellID of the **bar** you want the cast to appear on. The value is a list of **spellIDs** of casts to show.

### Show One Cast on a Bar

```lua
CONFIG.extraCasts = {
    [19434] = {56641},  -- Show Steady Shot casts on the Aimed Shot bar
}
```

### Show Multiple Casts on One Bar

```lua
CONFIG.extraCasts = {
    [88481] = {190984, 194153},  -- Show both Wrath and Starfire on the Eclipse bar
}
```

### Show Casts on Multiple Bars

```lua
CONFIG.extraCasts = {
    [88481] = {190984, 194153},  -- Eclipse bar: Wrath + Starfire
    [99]    = {190984},          -- Wrath bar: Wrath
    [100]   = {194153},          -- Starfire bar: Starfire
}
```

**Note:** You don't need `extraCasts` for the spell's own cast. If your Aimed Shot bar has spellID 19434 and you cast Aimed Shot, the cast bar shows automatically. You only need `extraCasts` when you want to show a *different* spell's cast on a bar.


## Setting Up Cast Colours

By default, all cast bars use the same colour (`CONFIG.castColor`). If you want different spells to have different cast bar colours, add a `castColors` table to your ClassConfig file. The key is the **spellID** of the cast.

```lua
CONFIG.castColors = {
    [190984] = {0.9, 0.8, 0.2, 0.7},  -- Wrath casts appear yellow
    [194153] = {0.3, 0.5, 0.9, 0.7},  -- Starfire casts appear blue
}
```

Any spell not in this list uses the default `CONFIG.castColor`. This works together with `extraCasts`. If both Wrath and Starfire cast on the Eclipse bar, each one shows its own colour.


## Setting Up Buff and Debuff Tracking

The easiest way to set up buff tracking is through the Settings GUI (Bars tab). Click a buff in the pool, then click a slot on the ability row to pair them. Right click to unpair. The GUI handles colours and saves everything to your profile.

For manual setup or more advanced configurations, buff mappings let you show a coloured overlay bar on an ability's row when a related buff or debuff is active. This is how you track DoT timers, proc buffs, and other aura durations on the timeline. Target auras can act differently in raid environments, but your own debuffs should be safe. Please report any funny business in raids so it can be fixed.

### The `unit` Field

There is a default fallback for units, but for best performance, every buff mapping needs a `unit` that tells Infall where to look for the aura:

- `"player"` for a buff on you (self buffs, procs, empowerments)
- `"target"` for a debuff on your target (DoTs, applied effects)
- `"pet"` for a buff or effect from your pet (however, the better way to track this is always the player buff)

**Important for raids:** Target debuff tracking (`unit = "target"`) may stop working on certain raid bosses due to Blizzard's secret value system. This is a WoW limitation that affects all addons. If your debuff bar disappears during a boss fight, this is why. Player buffs (`unit = "player"`) always work everywhere. See the Known Limitations section at the end of this guide for more details. Please report any debuff that fails in a raid encounter in the Event Horizon discord.

### Basic Structure

```lua
CONFIG.buffMappings = {
    [abilityCooldownID] = {
        {
            buffCooldownIDs = {cooldownID1, cooldownID2},
            unit = "player" or "target" or "pet",
            color = {red, green, blue, alpha},  -- optional
        },
    },
}
```

The key (number in square brackets) is the **cooldownID of the ability bar** you want the overlay to appear on.

Inside the curly braces, `buffCooldownIDs` is a list of cooldownIDs for the buff/debuff to look for. Usually this is just one ID, but you can list multiple if different versions of the same buff share a row.

The `color` field is optional. If you leave it out, the bar uses a default colour based on the unit:
- `"target"` uses `CONFIG.debuffColor` (red by default)
- `"pet"` uses `CONFIG.petBuffColor` (blue by default)
- `"player"` or anything else uses `CONFIG.buffColor` (purple by default)

### Example: Track a DoT on Your Target

Show Moonfire's duration on the Moonfire ability row:

```lua
CONFIG.buffMappings = {
    [88334] = {
        {
            buffCooldownIDs = {93500},
            unit = "target",
            color = {0.9, 0.5, 0.3, 0.7},  -- orange
        },
    },
}
```

### Example: Track a Self Buff

Show Bestial Wrath buff duration on the Bestial Wrath bar:

```lua
CONFIG.buffMappings = {
    [31264] = {
        {
            buffCooldownIDs = {92792},
            unit = "player",
            color = {0.8, 0.2, 0.2, 0.6},  -- red
        },
    },
}
```

### Example: Track Two Auras on One Bar

You can put two entries in one mapping. The first one becomes the main bar. The second one becomes a semi transparent overlay on top (rendered at 50% opacity). This is useful for tracking two related effects on the same ability row.

Eclipse tracking to show Lunar Eclipse as a blue bar and Solar Eclipse as an orange overlay:

```lua
CONFIG.buffMappings = {
    [88481] = {
        -- First entry: primary bar (Lunar Eclipse, blue)
        {
            buffCooldownIDs = {76},
            unit = "player",
            color = {135/255, 194/255, 255/255, 0.6},
        },
        -- Second entry: overlay bar (Solar Eclipse, orange, rendered at 50% alpha on top)
        {
            buffCooldownIDs = {78},
            unit = "player",
            color = {0.9, 0.5, 0.3, 0.3},
        },
    },
}
```

When Lunar Eclipse is active, you see a blue bar. When Solar Eclipse is active, you see an orange overlay. If both were active, you'd see both layered and the colours merge.

Only the first two entries are used. A third entry would be ignored. Sorry!

### Example: Track a Buff with Default Colour

If you don't care about the specific colour and just want the default, leave out the `color` field:

```lua
CONFIG.buffMappings = {
    [31264] = {
        {
            buffCooldownIDs = {92792},
            unit = "player",
            -- no color field = uses CONFIG.buffColor (purple by default)
        },
    },
}
```

### Combining Multiple Abilities

You can track different buffs on different ability bars in the same table:

```lua
CONFIG.buffMappings = {
    -- Moonfire DoT on target
    [88334] = {
        {buffCooldownIDs = {93500}, unit = "target", color = {0.9, 0.5, 0.3, 0.7}},
    },
    -- Sunfire DoT on target
    [88314] = {
        {buffCooldownIDs = {93501}, unit = "target", color = {0.4, 0.4, 0.9, 0.6}},
    },
    -- Eclipse: two buffs on one bar
    [88481] = {
        {buffCooldownIDs = {76}, unit = "player", color = {135/255, 194/255, 255/255, 0.6}},
        {buffCooldownIDs = {78}, unit = "player", color = {0.9, 0.5, 0.3, 0.3}},
    },
}
```

### Variant Colours (Abilities With Multiple Outcomes)

Some abilities have a single buff that changes identity depending on the outcome. Roll the Bones is the main example: it always applies the same buff (cooldownID 42743), but the spellID changes for each result (One of a Kind, Double Trouble, Triple Threat, Jackpot). Infall can colour the bar differently for each outcome.

This is set up through `spellColorMap` in the buff mapping. The Settings GUI also handles this: when you click the colour swatch on a buff slot that has variant colours, a popup appears showing each variant with its own colour picker.

```lua
CONFIG.buffMappings = {
    [11860] = {   -- Roll the Bones ability
        {
            buffCooldownIDs = {42743},
            unit = "player",
            color = {0.4, 0.4, 0.9, 0.6},   -- default colour (fallback)
            spellColorMap = {
                [1214933] = {0.3, 0.8, 0.3, 0.6},  -- One of a Kind (green)
                [1214934] = {0.8, 0.8, 0.2, 0.6},  -- Double Trouble (yellow)
                [1214935] = {0.9, 0.5, 0.1, 0.6},  -- Triple Threat (orange)
                [1214937] = {0.9, 0.2, 0.9, 0.6},  -- Jackpot (magenta)
            },
        },
    },
}
```

The keys in `spellColorMap` are spellIDs for each outcome. When the buff is active, Infall reads the outcome's spellID and picks the matching colour.

**Raid limitation:** Inside raid encounters, Blizzard restricts aura details (secret values). The bar colour falls back to the default `color` field during boss fights. The variant name label (see Variant Names below) still works everywhere because spell names pass through the combat protection system.


## Setting Up Stack Tracking

Stack mappings show a number on the ability icon when a related buff has multiple stacks (like Starlord or Maelstrom Weapon stacks). One mapping per ability.

**The easiest way** is through the Settings GUI (Bars tab). Click a buff in the Buffs pool, then click the Stack slot on a cooldown row. The buff's stack count will appear on the ability icon. You can set a custom text colour via the colour swatch next to the Stack slot. Everything saves to your profile.

For manual setup:

```lua
CONFIG.stackMappings = {
    [abilityCooldownID] = {
        buffCooldownID = N,       -- the cooldownID of the stacking buff
        unit = "player",          -- or "target"
    },
}
```

Example: show Starlord stacks on the Eclipse icon:

```lua
CONFIG.stackMappings = {
    [88481] = {buffCooldownID = 117, unit = "player"},
}
```

The number appears at the position set by `CONFIG.stackTextAnchor` (bottom left by default). The charge count (if the ability has charges) appears separately at `CONFIG.chargeTextAnchor` (bottom right by default), so they don't overlap.

**Note on target stacks:** Stack tracking uses `unit` the same way buff mappings do. Using `unit = "target"` may not work during raid encounters. Use `unit = "player"` when possible.


## Variant Names

Abilities with variant colours (IE Roll the Bones) can also show the outcome name as text on the bar. When enabled, you see labels like "Double Trouble" or "Jackpot" right on the bar, so you can tell the outcome at a glance without relying on colour alone.

This feature is off by default. To enable it, open the Settings GUI (Toggles tab) and check "Variant Names." The text label works everywhere including inside raids, because spell names pass through Blizzard's combat protection system. This is especially useful during encounters where the variant colour falls back to default.

### Customizing Variant Text

The Colours tab in the Settings GUI has a "Variant Name Text" section where you can adjust:

- **Colour**: The text colour of the variant name.
- **Size**: Font size for the variant text (6 to 24). Default is 12, which is 2px smaller than the main font.
- **Anchor and Relative Point**: Where the text sits on the bar (IE LEFT, CENTER, RIGHT).
- **Offset X / Offset Y**: Nudge the text left, right, up, or down from the anchor point.

When you adjust any of these settings, a preview showing "Variant Name Anchor" appears on your actual Infall bars so you can see exactly where the text will sit and what colour it will be. The preview hides when you leave the Colours tab.

For file editing, the defaults are:

```lua
CONFIG.showVariantNames = false
CONFIG.variantTextColor = {1, 0.85, 0.3, 1}
CONFIG.variantTextSize = 12
CONFIG.variantTextAnchor = "LEFT"
CONFIG.variantTextRelPoint = "LEFT"
CONFIG.variantTextOffsetX = 5
CONFIG.variantTextOffsetY = 0
```


## Writing a Class File From Scratch

All 13 classes already have ClassConfig files. But if Blizzard adds a new class, here's how to set one up.

### Step 1: Create the File

Create `ClassConfig/NewClass.lua`.

### Step 2: Add It to the TOC File

Open `EventHorizon_Infall.toc` and add your file with the other ClassConfig entries:

```
ClassConfig\NewClass.lua
```

ClassConfig files must load after Core.lua but before Bars.lua.

### Step 3: Use This Template

```lua
-- EventHorizon Infall, NewClass
if select(2, UnitClass("player")) ~= "NEWCLASS" then return end

local CONFIG = EventHorizon_Infall.CONFIG

CONFIG.extraCasts = {
    -- [cooldownID] = {spellID, spellID, ...},
}

CONFIG.buffMappings = {
    -- [cooldownID] = {
    --     {buffCooldownIDs = {N}, unit = "player", color = {r, g, b, a}},
    -- },
}

CONFIG.stackMappings = {
    -- [cooldownID] = {buffCooldownID = N, unit = "player"},
}

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
```

Valid class names (must be all caps, spelled exactly): `WARRIOR`, `PALADIN`, `HUNTER`, `ROGUE`, `PRIEST`, `DEATHKNIGHT`, `SHAMAN`, `MAGE`, `WARLOCK`, `MONK`, `DRUID`, `DEMONHUNTER`, `EVOKER`.

### Step 4: Find Your IDs and Fill In the Mappings

Use the steps in "Finding Spell IDs and Cooldown IDs" above to discover your ability and buff cooldownIDs, then fill in the tables.


## Common Mistakes

**Missing comma between entries.** Every entry in a table needs a comma after it except the last one (though trailing commas are fine in Lua). If you get a "unexpected symbol" error, you probably forgot a comma:

```lua
-- WRONG, missing comma after first entry
CONFIG.extraCasts = {
    [88481] = {190984, 194153}     -- needs a comma here
    [88334] = {8921}
}

-- RIGHT
CONFIG.extraCasts = {
    [88481] = {190984, 194153},
    [88334] = {8921},
}
```

**Using spellID where you need cooldownID (or vice versa).** The number in square brackets for `buffMappings`, `stackMappings`, and `extraCasts` should be a cooldownID. The numbers inside `buffCooldownIDs` should also be cooldownIDs. Only the cast spellIDs inside `extraCasts` values and `castColors` keys can be spellIDs.

**Wrong class name.** The class check at the top of the file must match exactly. `"DEATHKNIGHT"` not `"DEATH_KNIGHT"` or `"DeathKnight"`.


## Known Limitations

### Target Debuff Tracking in Raids

WoW 12.0 (Midnight) introduced "secret values" in raid and dungeon encounters, where Blizzard restricts what addons can read about your target. This can cause target debuff bars (`unit = "target"`) to disappear during boss fights. When this happens, the bar simply hides instead of showing wrong information.

Player buffs (`unit = "player"`) are **never** affected and always work everywhere.

This is a Blizzard level restriction that affects all addons. If tracking your DoTs during boss fights is critical, be aware this may not be fully reliable on all encounters. Blizzard has been pretty good about providing debuffs with player auras, so if there is a version of the debuff in the Cooldown Manager, it should work.

### Pandemic Pulse with ArcUI

The pandemic pulse feature (debuff bars glow when they're in the refresh window) only works with the default Blizzard UI. If you use ArcUI, it replaces Blizzard's pandemic indicator with its own system, and Infall can't read it. The rest of the addon works fine with ArcUI. If you find any other instances of this, we can try to fix it in the future. ArcUI plans to change and update their pandemic indicator, so we'll try to fix it then.

### Icon Range Colouring in Raids

The out of range icon tinting may stop working during raid encounters due to the same secret value restrictions. Icons will fall back to their default usable colour instead. This is cosmetic only and doesn't affect any bars or tracking.

### Stack Text on Target Debuffs in Raids

Stack counts for target debuffs (like tracking debuff stacks on a boss) may not display during raid encounters. Stack counts for player buffs always work. So make sure your target debuffs are configured with the Cooldown Manager, and report any that fail in a raid environment so we can find out if it's intended.

### Charge Bar Display on External Resets

When an ability instantly resets all charges of another spell (like Combustion resetting Fire Blast), the charge bar display may briefly show stale cooldown bars until you leave combat. This is a game engine limitation that affects all addons. Use the "Reset by" pairing in the Settings GUI (Bars tab) to work around this for known reset abilities. See the Charge Reset Workaround section above.


## Quick Reference: All Settings

For copy paste convenience, here is every setting with its default value. All of these can be changed from the Settings GUI without editing files. If you prefer file editing, put any of these in Core.lua to change the default.

```lua
-- Bar dimensions
CONFIG.width = 352
CONFIG.height = 20
CONFIG.iconSize = 30

-- Spacing and padding
CONFIG.spacing = 0.5
CONFIG.paddingTop = 5
CONFIG.paddingBottom = 5
CONFIG.paddingLeft = 5
CONFIG.paddingRight = 5

-- Timeline
CONFIG.future = 16
CONFIG.past = 2.5

-- Bar colours
CONFIG.cooldownColor = {171/255, 191/255, 181/255, 0.5}
CONFIG.castColor = {0.2, 0.8, 0.2, 0.7}
CONFIG.buffColor = {0.4, 0.4, 0.9, 0.6}
CONFIG.debuffColor = {0.9, 0.3, 0.3, 0.6}
CONFIG.petBuffColor = {0.3, 0.6, 0.9, 0.7}
CONFIG.gcdColor = {1, 1, 1, 0.1}
CONFIG.gcdSparkColor = {1, 1, 1, 0.6}
CONFIG.gcdSparkWidth = 3

-- Now line
CONFIG.nowLineColor = {1, 1, 1, 0.7}
CONFIG.nowLineWidth = 2

-- Icon gap
CONFIG.iconGap = 10

-- Time lines
CONFIG.linesColor = {1, 1, 1, 0.3}

-- Frame background
CONFIG.bgcolor = {0, 0, 0, 0.5}
CONFIG.bordercolor = {0, 0, 0, 1}

-- Icon state colours
CONFIG.iconUsableColor = {1.0, 1.0, 1.0, 1.0}
CONFIG.iconNotEnoughManaColor = {0.5, 0.5, 1.0, 1.0}
CONFIG.iconNotUsableColor = {0.4, 0.4, 0.4, 1.0}
CONFIG.iconNotInRangeColor = {0.64, 0.15, 0.15, 1.0}

-- Font
CONFIG.font = nil
CONFIG.fontSize = 14
CONFIG.fontFlags = "OUTLINE"

-- Charge text position (ability charge count, like "2")
CONFIG.chargeTextColor = {1, 1, 1, 1}
CONFIG.chargeTextAnchor = "BOTTOMRIGHT"
CONFIG.chargeTextRelPoint = "BOTTOMRIGHT"
CONFIG.chargeTextOffsetX = -2
CONFIG.chargeTextOffsetY = 2

-- Stack text position (buff stack count, like "3")
CONFIG.stackTextColor = {1, 0.85, 0.3, 1}
CONFIG.stackTextAnchor = "BOTTOMLEFT"
CONFIG.stackTextRelPoint = "BOTTOMLEFT"
CONFIG.stackTextOffsetX = 2
CONFIG.stackTextOffsetY = 2

-- Empowered cast stage colours (Evoker)
CONFIG.empowerStage1Color = {0.65, 0.15, 0.15, 0.7}
CONFIG.empowerStage2Color = {0.90, 0.45, 0.10, 0.7}
CONFIG.empowerStage3Color = {1.00, 0.75, 0.00, 0.7}
CONFIG.empowerStage4Color = {1.00, 0.95, 0.45, 0.7}

-- Smooth bar animation
CONFIG.smoothBars = false

-- Variant name text (requires showVariantNames enabled in Toggles tab)
CONFIG.variantTextColor = {1, 0.85, 0.3, 1}
CONFIG.variantTextSize = 12
CONFIG.variantTextAnchor = "LEFT"
CONFIG.variantTextRelPoint = "LEFT"
CONFIG.variantTextOffsetX = 5
CONFIG.variantTextOffsetY = 0
```

### Toggle Commands (Saved to Profile)

These are adjusted with slash commands or from the Settings GUI (Toggles tab). They save to your active profile automatically and persist across reloads, relogs, and spec switches. Each character and spec has its own profile.

| Setting | Command | Default |
|---|---|---|
| Reactive icons | `/infall reactive` | on |
| Desaturation | `/infall desat` | on |
| Redshift (auto hide) | `/infall redshift` | on |
| Pandemic pulse | `/infall pandemic` | on |
| Hide Blizzard cast bar | `/infall castbar` | on (hidden) |
| Hide Cooldown Manager | `/infall ecm` | off |
| Frame lock | `/infall lock` | off |
| Icon visibility | `/infall icons` | on (visible) |
| Buff layer above | `/infall bufflayer` | off (below) |
| Click through | `/infall clickthrough` | off |
| Smooth bar animation | Settings GUI (Display tab) | off |
| Show past bars | Settings GUI (Toggles tab) | on |
| Variant names | Settings GUI (Toggles tab) | off |
| Position | drag or `/infall pos X Y` | centre |

### Layout Preview Commands (Session Only)

These let you test layout changes in game. They last until you `/reload`. To make them permanent, either use the Settings GUI (Display tab, which saves to your profile) or add the CONFIG line to Core.lua as each command tells you.

| Setting | Command | Default |
|---|---|---|
| Scale | `/infall scale N` | 1.0 |
| Past timeline | `/infall past N` | 2.5 |
| Time markers | `/infall lines N N N` | off |
| Static height | `/infall static N` | off |
| Now line | `/infall nowline N` | 2px, white 70% |
| Icon gap | `/infall gap N` | 10 |
| Hide bar | `/infall hide ID` | none |
