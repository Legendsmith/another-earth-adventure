class_name GameConfig
extends Resource
## Every tunable number of the campaign in one place. The design documents leave many of these undefined; the defaults
## here are first guesses meant to be tuned in play (see data/game_config.tres, which the Campaign autoload loads).

@export_group("Run setup")
## Fuel needed in the tanks to charge the long range FTL jump home.
@export var fuel_to_win: float = 400.0
## Crew (alive, not counting special characters) needed aboard before the jump home is allowed.
@export var crew_to_win: int = 24
## Systems on the FTL map.
@export var map_systems: int = 18
## Generic crew rescued in the intro dungeon, on top of the main character.
@export var intro_rescued_crew: int = 8

@export_group("Starting stores")
@export var start_fuel: float = 60.0
@export var start_metal: float = 20.0
@export var start_supplies: float = 40.0
## Units of fuel one fuel tank module holds.
@export var fuel_per_tank: float = 100.0
## Units of metal and supplies (together) one cargo hold module holds.
@export var cargo_per_hold: float = 50.0
@export var start_fuel_tanks: int = 2
@export var start_cargo_holds: int = 2
## Ship mass (tonnes, arbitrary unit) of one unit of any stored resource.
@export var mass_per_unit: float = 0.05
## Metal cost of building one more fuel tank or cargo hold (area based, no module core needed).
@export var storage_build_cost: float = 8.0

@export_group("FTL")
## Fuel per FTL map distance unit for a ship of dry_ship_mass. Heavier ships pay proportionally more.
@export var ftl_fuel_per_distance: float = 0.12
## Mass the FTL and burn costs are normalised against.
@export var dry_ship_mass: float = 20.0

@export_group("Orbit")
## Fuel a full reactor burns per orbital hour at 100% output (consumption goes with output squared).
@export var reactor_fuel_per_hour: float = 0.6
## Reactor output while cruising, 0..1.
@export var reactor_cruise_output: float = 0.4
## Reactor output at combat power (can exceed 1: engines and reactor are pushed hard).
@export var reactor_combat_output: float = 1.0
## Performance multiplier on engines and weapons at combat power.
@export var combat_power_bonus: float = 1.5
## Seconds (real time) the crew take to bring the ship to combat power once combat is not avoided.
@export var combat_prep_seconds: float = 12.0
## Maintenance clocks run this many times faster at combat power.
@export var combat_maintenance_rate: float = 3.0
## Seconds with too few crew to man the bridge, reactor and engines before the ship is lost.
@export var undercrewed_loss_seconds: float = 10.0
## Distance and time of the boarding countdown (Orbital Gameplay, Loss).
@export var boarding_distance_m: float = 200.0
@export var boarding_countdown_seconds: float = 5.0
## Supplies lost when surrendering to pirates, as a share of what is stored.
@export_range(0.0, 1.0, 0.01) var surrender_supplies_share: float = 0.5
@export_range(0.0, 1.0, 0.01) var surrender_metal_share: float = 0.3
## Supplies pirates ask for in a demand, as a share of what is stored (at least 5).
@export_range(0.0, 1.0, 0.01) var pirate_demand_share: float = 0.25
## Time limit of an expedition launched from a low flyby, in seconds of expedition time.
@export var flyby_expedition_seconds: float = 240.0

@export_group("Maintenance")
## Maintenance interval (orbital seconds) of a module that does not set its own.
@export var default_maintenance_interval: float = 21600.0
## Supplies spent per maintenance of a size 1 module.
@export var maintenance_supplies_per_size: float = 0.5
## Malfunction chance of a check with the maintenance clock just at 0.
@export_range(0.0, 1.0, 0.0001) var malfunction_base_chance: float = 0.0005
## Extra chance per check for each full maintenance interval the clock is overdue (see ModuleState.malfunction_chance).
@export_range(0.0, 1.0, 0.0001) var malfunction_overdue_chance: float = 0.01
## Chance of a combat malfunction when the ship goes to combat power with a module at 0 maintenance.
@export_range(0.0, 1.0, 0.01) var combat_malfunction_chance: float = 0.35
## Maintenance clock lost (as a share of the interval) when a module is knocked offline.
@export_range(0.0, 1.0, 0.01) var knockout_clock_penalty: float = 0.25
## Seconds of crew work per module size to bring an offline module back (repair skill speeds it up).
@export var repair_seconds_per_size: float = 6.0
## Metal to repair one point of armor.
@export var metal_per_armor_point: float = 0.5

@export_group("Expedition")
@export var max_expedition_crew: int = 12
## Supplies spent per expedition member on ammunition, medical kits and oxygen.
@export var supplies_per_kit: float = 1.0
## Extra supplies per member for oxygen on toxic worlds.
@export var oxygen_supplies_per_member: float = 0.5
## Metal per basic body armor (1 metal + 1 supplies in the design notes; the supplies are in the kit).
@export var metal_per_armor: float = 1.0
## Seconds between enemies trickling back into cleared parts of the dungeon.
@export var enemy_trickle_seconds: float = 25.0
## Seconds a dying Twitch crewmember has for last words.
@export var last_words_seconds: float = 30.0
## Physics frames an off-screen actor skips between AI and medical updates.
@export var actor_skip_frames: int = 3
## Explosions add this much to the Lava eruption gauge (0..100).
@export var eruption_per_explosion: float = 12.0
@export var eruption_countdown_seconds: float = 5.0

@export_group("Medical")
## Litres of blood a healthy body holds.
@export var blood_volume: float = 5.0
## Seconds for clotting to halve a wound's bleeding.
@export var clot_half_life: float = 90.0
## Chance per attempt that CPR and a stimulant restart a stopped heart, plus per Medical skill level.
@export_range(0.0, 1.0, 0.01) var resuscitation_chance: float = 0.3
@export_range(0.0, 1.0, 0.01) var resuscitation_chance_per_skill: float = 0.08
## Heart rate above which fibrillation can set in, and its chance per second at 40 bpm over.
@export var fibrillation_heart_rate: float = 185.0
@export_range(0.0, 1.0, 0.001) var fibrillation_chance: float = 0.02
## Ship medical bay: supplies per point of healing.
@export var medbay_supplies_per_heal: float = 0.02
## Ship medical bay: healing points per hour (body part HP, brain above 50, blood...).
@export var medbay_heal_per_hour: float = 60.0
## Metal cost of a bionic limb or brain augmentation.
@export var bionic_metal_cost: float = 6.0

@export_group("Crew growth")
## Experience for one skill level at level 0; each level needs this much more than the last (diminishing returns).
@export var xp_per_level: float = 60.0
## Speed bonus of the first skill level; each further level adds less (bonus = 1 - 1 / (1 + level * this)).
@export var skill_speed_factor: float = 0.25
