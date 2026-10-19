# Changelog: Wrench Works: Driver Injuries

## 0.2.0 (release candidate)

- **Damage adds up.** A hit scores on top of what he already carries from earlier crashes (two small knocks can bruise, a bruise plus a hard hit can knock him out), and a bruise fades from the score over ten minutes. Every scored crash restarts the blur, not only one that raises the level.
- **Real crashes now hurt.** A crash is scored as the speed lost over 0.1 s, so how the frames happen to split the stop no longer decides whether it counts, and a car stopped short by a wall is no longer mistaken for a teleport. In the Street Legal career: a 30 km/h tap bruises, 50 km/h bruises harder, about 55 km/h and up knocks him out and sends him to the hospital.
- **A bruise is clearly felt:** wider, stronger edge blur by default (the Injury tab still has the strength and a Reduce motion switch). The voice clips are still silent in the game (the sound profile is missing).
- **How injuries feel.** After a hard hit the edges of the screen go blurry and his hearing is muffled, both fading over a few seconds (a knock-out keeps them until he wakes), and on foot with a broken leg he cannot sprint until it has healed. Each has its own switch and strength in the Injury tab, and one **Reduce motion** switch turns the screen effects off. (The game offers no camera shake we could use, so there is none.)
- **Settings.** Toughness, recovery times, the bruise, break and knock-out thresholds and the voice gap are settings in the Injury tab; `setTune`/`getTune`/`resetTune` do the same from the console.
- **Injury tab in the Mods menu** (ESC > Mods, with Wrench Works installed): the injury mode (off, injuries, injuries and death) is a setting there; `slrrInjury.settingsSchema()` offers it and slrrDrivers registers the page.

## 0.1.0

- Crashes hurt the driver: bruises, a broken arm (one-handed steering, less lock), a broken right leg (no more than 70 % throttle or brake) and unconsciousness (controls cut until he comes round).
- **Death is a setting.** Only "Injuries and death" and a Hardcore career allow it; in the default "Injuries" mode the worst a crash does is knock the driver out. Death needs forces no restrained driver survives, held for a moment.
- **A knocked-out driver slumps over the wheel** until he wakes up.
- Settings next to the driver settings in the Wrench Works garage: off, injuries, injuries and death (blood and limb loss).
- Hospital time and money in the Street Legal career; in Hardcore a death ends the career.
- Voice clips for hurt, waking and angry (optional; without them the driver is silent).
