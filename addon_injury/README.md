# Wrench Works: Driver Injuries

An optional add-on to Wrench Works: Drivers. Crashes hurt the driver: bruises, a broken arm (one-handed
steering, less lock), a broken right leg (no more than 70 % throttle or brake), unconsciousness (controls cut
until he comes round) and, only at forces no restrained driver survives, death. With the Street Legal career,
injuries cost hospital time and money; in hardcore a death ends the career.

Settings (Wrench Works garage, Settings, next to Driver), or the console:

```lua
slrrInjury.setMode('injuries')   -- default; 'full' adds blood and limb loss; 'off'
slrrInjury.getState()            -- the player's driver: level, severity, parts, recoverySeconds, limits
slrrInjury.heal()
```

For other mods: `onSlrrDriverInjured(vehId, injuries)` once per crash that hurts, and
`onSlrrDriverDied(vehId, cause, detail)` once. See the design in the project notes (DESIGN_injury.md).

Death is a setting: only 'full' ("Injuries and death") and a Hardcore career (`slrrInjury.setDeathOverride(true)`, set by Street Legal) allow it; in 'injuries' the worst a crash does is knock the driver out, and he slumps over the wheel until he wakes (`slrrDrivers.setSlump`). Only the player's own driver is tracked; traffic drivers are props and nobody else gets hurt.

When it counts, death is deliberate: the head over 200 g or the chest over 150 g sustained 25 ms; any force must last two
physics steps to count; nothing counts for 3 s after a spawn, reset, teleport or vehicle switch, or on a step
where the car jumps (a glitch).

Voice clips go in `art/sounds/slrr_injury/` as `hurt_*.ogg`, `wake_*.ogg` and `angry_*.ogg` (CC0, see
CREDITS.md); 16 clips, 128 KB. Without clips the driver is silent.

## Credits

Voice clips: CC0, from OpenGameArt (HaelDB, qubodup). See [CREDITS.md](CREDITS.md).
