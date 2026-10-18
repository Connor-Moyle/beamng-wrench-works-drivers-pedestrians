# Changelog: Wrench Works: Driver Injuries

## Unreleased

- **How injuries feel.** After a hard hit the edges of the screen go blurry and his hearing is muffled, both fading over a few seconds (a knock-out keeps them until he wakes), and on foot with a broken leg he cannot sprint until it has healed. Each has its own switch and strength in the Injury tab, modest by default, and one **Reduce motion** switch turns the screen effects off. (The game offers no camera shake we could use, so there is none.)
- **Settings.** Toughness, recovery times, the bruise, break and knock-out thresholds and the voice gap are settings in the Injury tab; `setTune`/`getTune`/`resetTune` do the same from the console.
- **Injury tab in the Mods menu** (ESC > Mods, with Wrench Works installed): the injury mode (off, injuries, injuries and death) is a setting there; `slrrInjury.settingsSchema()` offers it and slrrDrivers registers the page.

## 0.1.0

- Crashes hurt the driver: bruises, a broken arm (one-handed steering, less lock), a broken right leg (no more than 70 % throttle or brake) and unconsciousness (controls cut until he comes round).
- **Death is a setting.** Only "Injuries and death" and a Hardcore career allow it; in the default "Injuries" mode the worst a crash does is knock the driver out. Death needs forces no restrained driver survives, held for a moment.
- **A knocked-out driver slumps over the wheel** until he wakes up.
- Settings next to the driver settings in the Wrench Works garage: off, injuries, injuries and death (blood and limb loss).
- Hospital time and money in the Street Legal career; in Hardcore a death ends the career.
- Voice clips for hurt, waking and angry (optional; without them the driver is silent).
