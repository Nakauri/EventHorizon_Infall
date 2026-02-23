# EventHorizon Infall

Cooldown timeline bars for World of Warcraft: Midnight (12.0). Reads your Cooldown Manager and mirrors it as horizontal bars showing cooldowns, casts, buffs, and debuffs sliding across a relative timeline.

Built for the Midnight secret value system from the ground up.

## Install

1. Download this repo as a zip (green **Code** button > **Download ZIP**)
2. Extract the folder
3. Rename it to `EventHorizon_Infall`
4. Drop it into `World of Warcraft/_retail_/Interface/AddOns/`
5. Restart WoW or type `/reload`

## Setup

Type `/infall setup` or go to **Escape > Options > AddOns > EventHorizon Infall** to open the settings panel. Everything is configurable from the GUI: bar layout, colours, fonts, toggles, buff/cast/stack pairings, and profiles.

For class-specific spell configs, see the `ClassConfig/` folder. For a full guide on every setting, see [CUSTOMIZATION.md](CUSTOMIZATION.md).

## Slash Commands

`/infall` or `/infallhelp` for the full command list. Key commands:

- `/infall setup` open settings
- `/infall lock` / `/infall unlock` toggle frame dragging
- `/infall scale <n>` set UI scale
- `/infall reload` rebuild bars from CDM

## Features

- Timeline bars driven by Blizzard's Cooldown Manager
- Cooldown, cast, buff, debuff, and GCD bars
- Charge spell support with split N-lane bars
- Empowered cast stages (Evoker) with configurable colours
- Past slide history bars
- Reactive icon colours (usable, OOM, out of range, on cooldown)
- Pandemic pulse indicators
- Spell variant colours and names (IE Roll the Bones outcomes)
- Full Settings GUI with 5 tabs
- Per-character, per-spec auto-profiles with named profile support
- Configurable fonts via LibSharedMedia

## Requirements

- World of Warcraft: Midnight (12.0+)
- Blizzard Cooldown Manager enabled (default on)
