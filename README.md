# Infinite Maintainer

Lets you passive lines easily, without lag and randomness of AE2 maintainer.
Also supports having a threshold.

Fork of [Echoloquate/Level-Maintainer](https://github.com/Echoloquate/Level-Maintainer) with fixes for the lookup cache, NBT item and fluid thresholds and crash recovery, a `settings.lua` for timing, retry and CPU options, and optional auto-start.

# Setup

## Hardware

- An OpenComputers computer: case, CPU, RAM, hard drive, EEPROM (Lua BIOS), GPU, screen and keyboard
- An internet card (needed to download the scripts)
- An adapter touching a full-block ME interface on your network
- A Crafting Monitor on every crafting CPU (used to see what is already being crafted)
- Optional: a redstone card and a slow redstone clock, to turn the computer back on after a power loss (see [Auto-start and crash recovery](#auto-start-and-crash-recovery))

## Install OpenOS

The maintainer runs on OpenOS, so install it to the hard drive first:

1. Get the OpenOS floppy. It is normally crafted from a blank floppy and the OpenComputers manual (check NEI for the recipe in your pack).
2. Put the floppy in a disk drive next to the computer and turn it on.
3. Run `install`, pick the hard drive and let it reboot.
4. Remove the floppy. The computer now boots OpenOS from the hard drive.

# Installation

Download it (run the same command again later to update)

```bash
wget -f https://raw.githubusercontent.com/Willshaper/Level-Maintainer/master/installer.lua && installer
```

The installer replaces the scripts but keeps an existing `config.lua` and `settings.lua`. It then asks:

- **Replace settings.lua with the new one?** Only asked when your `settings.lua` is missing settings that were added since you installed (or is from before the settings were simplified). Your values are carried over, and the old file is kept as `settings.lua.old`.
- **Start Maintainer automatically when the computer boots?** Adds a line to `/home/.shrc`.
- **Turn the computer on when it receives a redstone signal?** Only asked when a redstone card is installed.

Then it reboots.

Run it from the folder you installed to (not needed if auto-start is on)

```bash
Maintainer
```

Stop it by pressing Q, or holding Ctrl+Alt+C for a second. Crafts already sent to AE2 keep running.

# Screen and keys

By default the screen shows a status table, redrawn every cycle:

```
14:02:11   CPUs free: 7/8   Entries: 4   Next cycle in 7s
Name                 Stock     Want   Batch  Status
Tantalum Dust            -        -    2048  failed
Blank Pattern          385      256     512  stocked
Fluorescent Dye          -        -    1000  requested
Phthalic Acid       11.97M   10.00M   3.00M  stocked
-- Recent -----------------------------------------------
[14:01:51] Requested Fluorescent Dye x 1000
[14:01:51] Failed to request Tantalum Dust x 2048 (request
           failed (missing resources?)), retrying in 60s
E edit config  S edit settings  R reload  Q quit
```

The header shows the time, the crafting CPUs (`settings.cpuDisplay`), the number of entries and a countdown to the next cycle. On a narrow screen the less important parts are left out.

**Columns**

- **Stock**: the amount in the ME system, for entries with a threshold. Fluids are in mB. It isn't read while an entry is crafting, waiting to retry or waiting for a CPU; the last value is then shown in gray.
- **Want**: the threshold, the first number in `config.lua`. `-` means the entry has no threshold (`nil`): the maintainer keeps one batch crafting at all times and never reads its stock, so Stock shows `-` too.
- **Batch**: how many are requested at once, the second number in `config.lua`.
- **Status**: what the entry is doing, in its row color:

| Status | Color | Short word | Symbol |
|---|---|---|---|
| `stocked`: at or above the threshold | green | | `✓` |
| `crafting`: already being crafted | blue | | `▶` |
| `requested`: a craft was started this cycle | yellow | | `●` |
| `waiting for CPU`: no free crafting CPU | orange | `no CPU` | `…` |
| `failed`: the request failed; Recent says when it is retried | red | | `✗` |
| `not craftable`: no pattern for it | red | `no pattern` | `?` |
| `error`: something went wrong; see Recent | red | | `!` |
| `waiting`: not checked yet | white | | `·` |

The short words are used on screens taller than wide, the symbols with the `Symbol` column.

`settings.columns` picks which columns are shown; see [Table columns](#table-columns). For example `"Name Stock Want Symbol"` on a 2x3 screen, with the Recent panel off:

```
Next cycle in 10s
Name           Stock   Want
Tantalum Dust      -      - ✗
Blank Pattern    385    256 ✓
Fluorescent ~      -      - ●
Phthalic Acid 11.97M 10.00M ✓
✓ stocked  ● requested
✗ failed
E/S edit  R reload  Q quit
```

Without a Status column, the line under the table explains the colors and symbols that appear in the table (`settings.legend = false` hides it).

**Layout**

- Rows that need attention (`failed`, `error`, `not craftable`) are listed first; the rest are alphabetical.
- By default (`settings.screen = "fit"`) the maintainer picks the screen resolution itself, so the table fills the screen with text as large as possible: with few entries or few columns the text is big, with many it gets smaller. On a screen taller than wide (e.g. 2x3 blocks) it uses narrower columns and the short status words, cutting long names to make the text larger; `"wide"` keeps the full-width columns and whole names there too (smaller text, and the spare lines go to the Recent panel). `"columns"` instead keeps the resolution and splits the rows into side-by-side tables on wide screens.
- If there are more entries than fit, the table has pages: the header shows `Page 1/3`, and Page Up/Down or the Up/Down arrows switch pages.
- The Recent panel shows the latest log lines; long lines wrap onto the next line. `settings.showRecent = false` gives the table the whole screen, and `settings.log` sets how much is logged.
- `settings.screen = "log"` shows a plain scrolling log instead of the table.

**Keys** work while the maintainer waits between cycles (and while it waits at startup for an ME interface or a fixed `config.lua`):

| Key | What it does |
|---|---|
| E | Opens `config.lua` in the editor. Save with Ctrl+S, close with Ctrl+W; the maintainer reloads it and starts a new cycle. |
| S | Same for `settings.lua`. |
| R | Reloads `config.lua` and `settings.lua` if they were saved since they were last read (e.g. edited from your PC). If the status table stopped working, it also tries the table again. |
| Q | Stops the maintainer. |
| Page Up/Down, Up/Down arrows | Switch pages of the status table when it doesn't fit on the screen. |

Each cycle starts one entry further down the list, so when crafting CPUs are scarce every entry gets its turn at a free CPU.

# Auto-start and crash recovery

While running, the maintainer recovers from problems by itself:

- An ME interface that is removed or replaced, or an AE2 error on one entry, is logged and retried on the next cycle.
- Any other unexpected error is logged, and the maintainer restarts after `retryDelay` seconds (at least 5).
- If no ME interface is attached when it starts, it waits for one instead of exiting.
- Server restarts and chunk unloads are fine: OpenComputers saves the running computer and resumes it.
- A broken entry in `config.lua` (for example a missing batch size) is reported and skipped; the other entries keep running.
- At startup, a mistake that stops `config.lua` from loading at all is reported and the maintainer waits for the file to be fixed instead of exiting. With live reload on, a mistake in a reloaded file is reported and the last working version stays in use.

It only stops when you press Ctrl+Alt+C.

## Start on boot

Answer yes to the first installer question, or add this line to `/home/.shrc` yourself (use the folder you installed to):

```bash
cd "/home" && Maintainer
```

Delete that line to turn auto-start off.

## Turn back on after a power loss

A computer that runs out of power switches off and stays off. To have it switch itself back on:

1. Put a redstone card in the computer.
2. Answer yes to the redstone question in the installer, or run `lua` and enter `require("component").redstone.setWakeThreshold(1)`. The card remembers this.
3. Wire a slow redstone clock (one pulse every 30-60 seconds) into the computer.

Each pulse turns the computer on if it is off; a running computer ignores it. With auto-start on, the maintainer starts with it.

Keep the clock's signal away from the screen: a redstone pulse into any block of an OpenComputers screen turns the screen off, and the next one turns it back on.

# Config

You can change maintained items in `config.lua`. There are two blocks, `cfg.items` and `cfg.fluids`. Items and fluids work in either one: the maintainer checks what each entry actually is and uses the right stock check. The simplest setup is to put everything in `cfg.items`.

## Items

```lua
cfg["items"] = {
    ["Osmium Dust"] = {nil, 64},                                  -- no threshold
    ["drop of Molten SpaceTime"] = {1000000, 1, "spacetime"},     -- fluid drop with threshold + fluid name
}
```

Pattern: `["item_label"] = {threshold, batch_size, fluid_name?}`. The third value is only needed for `ae2fc:fluid_drop` items and is the fluid's registry name -- this path works on any GTNH version.

Numbers can end in `k` (thousand), `m` (million), `g` or `b` (billion) and `t` (trillion), e.g. `["Nitric Acid"] = {250m, 40m}` or `{1.5k, 500}`. Names in quotes are never changed, so `["64k ME Storage Cell"]` stays as it is.

## Fluids (GTNH 2.9+)

GTNH 2.9 unified items and fluids in the OpenComputers AE2 integration, so fluid craftables can now be requested directly without going through `ae2fc:fluid_drop`. Threshold checks use real fluid amounts in mB.

```lua
cfg["fluids"] = {
    ["Molten SpaceTime"] = {1000000, 1000},
}
```

Pattern: `["fluid_label"] = {threshold_mb, batch_mb[, fluid_registry_name]}`. The label is the fluid's display name as shown in the AE crafting terminal. The fluid registry name is auto-detected from the craftable's stack -- pass it as a third value only as an override if auto-detection ever resolves to the wrong fluid. Omit the block entirely on pre-2.9 setups (the maintainer skips it with a warning there). Fluids can also go in `cfg.items` with the same values.

## Settings

Timing and behaviour live in `settings.lua` (anything missing falls back to a default):

| Setting | Default | What it does |
|---|---|---|
| `sleep` | `10` | Seconds between cycles. Each cycle checks every entry once. |
| `retryDelay` | `60` | Seconds to wait before recalculating an entry whose request failed (missing ingredients, no suitable CPU). `0` retries every cycle. Also the pause before the maintainer restarts itself after an unexpected error (at least 5). |
| `cpuName` | `nil` | Send every request to this named crafting CPU. `nil` lets AE2 pick. |
| `utcOffset` | `0` | Hours added to UTC for log timestamps (e.g. `1` for CET, `2` for CEST). Timestamps use the server's real clock, not in-game time. |
| `screen` | `"fit"` | `"fit"` shows the status table described under [Screen and keys](#screen-and-keys) and changes the screen resolution so it fills the screen with the largest text that fits (the old resolution comes back when the maintainer stops). On a screen taller than wide it uses narrow columns and short status words (`no CPU`, `no pattern`). `"columns"` keeps the resolution and puts the rows in side-by-side tables when the screen is wide enough. `"log"` shows a scrolling log instead of the table. `"wide"` is `"fit"` that always uses the full-width columns and whole names, also on a screen taller than wide (smaller text there). Also accepted: `"tall"` (always the narrow columns) and `"fixed"` (keep the resolution, one table). |
| `showRecent` | `true` | Show the recent log lines below the status table. `false` gives the whole screen to the table. |
| `log` | `"changes"` | What the Recent log shows. `"changes"`: each entry's status when it changes. `"all"`: everything that happens, every cycle. `"problems"`: only requests, failures and errors, no "stocked" / "already crafting" / "waiting" lines. The scrolling log (`screen = "log"`) logs each status once with `"all"` too. |
| `cpuDisplay` | `"free"` | How the header counts crafting CPUs: `"free"` shows idle CPUs (`CPUs free: 9/11`), `"busy"` shows CPUs running a job (`CPUs busy: 2/11`). |
| `columns` | `"Name Stock Want Batch Status"` | The status table's columns, left to right. See [Table columns](#table-columns). |
| `legend` | `true` | With no `Status` column, show a line above the key help that explains the row colors (and symbols). `false` hides it. |
| `shortNumbers` | `false` | `true` shows numbers with 3 digits (`112M`, `12.5k`) instead of 4 (`112.5M`, `12.50k`), one character narrower per number column. |

Advanced, at the bottom of `settings.lua`:

| Setting | Default | What it does |
|---|---|---|
| `requireFreeCpu` | `true` | Only start a calculation when a crafting CPU (or `cpuName`) is idle. |
| `cacheDuration` | `600` | Seconds craftable lookups are cached. New patterns are picked up after at most this long. |
| `pollInterval` | `1` | Seconds between checks while AE2 calculates a request. |
| `reloadCheck` | `0` | Live reload: seconds between checks for a saved `config.lua` or `settings.lua` while running, e.g. `30`. Only useful if you can edit the files outside the game. `0` = off. |

### Table columns

`settings.columns` lists the table's columns, left to right. Remove a word to hide that column; case and commas don't matter, and the name is always shown.

| Column | Shows |
|---|---|
| `Name` | The entry's label. |
| `Stock` | Amount in the ME system (entries with a threshold). Gray when it wasn't read this cycle. |
| `Want` | The threshold. |
| `Batch` | How many are requested at once. |
| `Percent` | Stock as a percentage of Want (`112%`, `>999%`); narrower than Stock and Want together. |
| `Status` | The status word (`stocked`, `crafting`, `failed`, ...). |
| `Symbol` | A one-character status: `✓` stocked, `▶` crafting, `●` requested, `…` waiting for a CPU, `✗` failed, `?` not craftable, `!` error. |

Without `Status`, a line under the table explains the row colors (and the symbols, with `Symbol`), listing only the statuses that appear in the table; `settings.legend = false` hides it. On a screen without colors, keep `Status` or use `Symbol`.

Fewer columns make the rows narrower, so with `screen = "fit"` the text gets larger. For example, on a 2x3 screen with 18 entries:

| `columns` | Row width |
|---|---|
| `"Name Stock Want Batch Status"` | 44 |
| `"Name Stock Want Batch"` | 33 |
| `"Name Stock Want Symbol"` | 28 |
| `"Name Percent Batch"` | 26 |

```
Name               %  Batch
Tantalum Dust      -   2048
Drilling Fluid  112% 25.00M
Ethanol         145% 400.0k
stocked  failed
```

Older `settings.lua` files still work: `display` and `layout` are read as `screen`, and `logSkips = false` / `logRepeats = true` as `log = "problems"` / `"all"`.

**!! Threshold has a performance impact -- only add it when necessary, and preferably not on mainnet !!**

## Changing the config while it runs

No reboot or restart is needed: press E while the maintainer runs to edit `config.lua` (S for `settings.lua`), save with Ctrl+S and close with Ctrl+W. The maintainer reloads the file and carries on. The files are also read fresh every time the maintainer starts.

### Live reload (off by default)

If you edit the files outside the game (singleplayer, or a server on your own PC), press R to load the changes, or let the maintainer pick them up by itself: set `reloadCheck` in `settings.lua` to how often to check, e.g. `30` seconds, then edit the file in the world save: `saves/<world>/opencomputers/<drive address>/home/config.lua` (run `df` in OC to see the drive address). At the next check the maintainer logs

```
Reloaded config.lua (1 added, 0 changed, 0 removed)
```

and starts a new cycle with it. If a saved file has a mistake, it logs the error and keeps using the previous version until a fixed one is saved.

On a server you usually can't reach these files, so leave it off.
