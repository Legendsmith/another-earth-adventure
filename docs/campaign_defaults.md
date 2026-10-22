# Campaign build: tunable defaults and open points

The design documents leave a number of values undefined. Every one of them lives in
`data/game_config.tres` (script `globals/campaign/game_config.gd`), so they can be tuned in the
inspector without touching code. These are the defaults picked for the first build.

## Defaults chosen where the docs give no number

| Area | Setting | Default | Notes |
| --- | --- | --- | --- |
| Win | `fuel_to_win` / `crew_to_win` | 400 fuel, 24 crew | "Set upon game start"; no difficulty screen yet. |
| Map | `map_systems` | 18 | FTL short-jump range 520 map units (`StarMap.MAX_JUMP`). |
| Start | fuel / metal / supplies | 60 / 20 / 40 | 2 fuel tanks (100 each), 2 cargo holds (50 each). |
| Storage | `storage_build_cost` | 8 metal | Flat cost per tank or hold (area based in the docs). |
| Mass | `mass_per_unit` | 0.05 t per unit | Every stored unit adds to ship mass; FTL and burn costs scale with it. |
| FTL | `ftl_fuel_per_distance` | 0.12 fuel per map unit | Scaled by (dry mass + cargo) / dry mass. |
| Reactor | `reactor_fuel_per_hour` | 0.6 fuel per orbital hour at 100% | Base rate; consumption goes with output squared. Cruise 40%, combat 100%. |
| Combat prep | `combat_prep_seconds` | 12 s | Window between refusing a demand and combat power. |
| Combat power | `combat_maintenance_rate` | x3 clock wear | Plus `combat_power_bonus` 1.5 on readiness and repair speed. |
| Weapons | load cost | 1 supply per module size | Loaded once, kept until used. |
| Maintenance | `default_maintenance_interval` | 21600 orbital s (6 h) | Per-module override in `ShipModule.maintenance_interval`. |
| Maintenance | `maintenance_supplies_per_size` | 0.5 supplies | Per module size per service. |
| Malfunctions | chance curve | 0.05% per check at 0, +1% per interval overdue | Checks once at 0 and then every orbital second; time warp rolls them together. |
| Malfunctions | `combat_malfunction_chance` | 35% | On going to combat power, and on a surviving hit, for overdue modules. |
| Knockout | `knockout_clock_penalty` | 25% of the interval | Clock lost when a module is knocked offline. |
| Repair | `repair_seconds_per_size` | 6 s | Crew up to the module's size work together; Repair skill speeds it up. |
| Pirates | `pirate_demand_share` | 25% of supplies (min 5) | Dark Light ask 40% (min 10). |
| Surrender | supplies / metal lost | 50% / 30% | Dark Light (and losing to boarders) also strip one non-essential module. |
| Flyby | `flyby_expedition_seconds` | 240 s | Insertion = bound orbit with apoapsis inside 1.25x low orbit; anything else is a flyby. |
| Expedition | kit cost | 1 supply per member, +0.5 oxygen on Toxic | Kit = 120 ammo, 3 dressings, 1 stim, 2 painkillers, 1 sedative. |
| Expedition | armor | 1 metal per member | Body armor takes 35% off thorax/abdomen hits. |
| Expedition | `enemy_trickle_seconds` | 25 s | One enemy returns to an explored room out of sight. |
| Medical | `clot_half_life` | 90 s | Wounds halve their bleeding every 90 s; dressings much faster. |
| Medical | resuscitation | 30% + 8% per Medical level | CPR on cardiac arrest (the docs' resuscitation gap). |
| Medical | fibrillation | above 185 bpm, 2% per second at +40 bpm | |
| Medbay | 60 healing points per hour, 0.02 supplies each | Bionics 6 metal per patient. |
| Crew growth | `xp_per_level` | 60, rising per level | Skill speed bonus 1 - 1/(1 + 0.25 x level). |
| Eruption | +12 per explosion, 5 s countdown | Lava worlds. |
| Crew needs | Bridge 2, Reactor 1, Fusion drive 2, Sensors 1, Torpedo tubes 1, Medbay 1 | Essential crew = 5; the intro guarantees at least 6. |

## How the layers connect

- `Campaign` autoload (`globals/campaign/campaign.gd`) holds the run and saves it through `SaveSystem`.
- Main menu (`ui/main_menu`) -> intro dungeon (`world/expedition`) -> orbit (`ui/ship_console/ship_hud.tscn`
  with `CampaignOrbit` as the first node of the orbital space) -> expeditions / FTL map (`ui/ftl_map`) -> end
  screen (`ui/game_over`).
- The orbital sandbox still runs on its own when no campaign is active ("Orbital sandbox" on the menu).

## Known gaps

- Cold Gas / Resistojet thrusters do not yet burn Supplies, and TVC thruster installs are not modelled.
- Satellites are not separate bodies yet: known caches are recovered from low orbit with a button.
- Tiny debris does not yet degrade sensors; debris strikes only damage armor and modules.
- Enemy ships have no crew simulation: they are beaten by knocking out modules or armor, not by casualties.
- Special characters beyond the Captain (preset loadouts, dialogue) are supported by `CrewRecord.special` but none
  are generated yet.
- Counter-boarding the enemy after repelling boarders is not in.
- The art title screen (`ui/title_screen`) references audio and shader files that are not in the repo, so the
  plain main menu is the entry scene for now.
