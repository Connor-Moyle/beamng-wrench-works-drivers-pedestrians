# Changelog: Wrench Works: Drivers & Pedestrians

## 1.4.0 (release 1 candidate, not yet released)

What is new since 1.3.0, for players.

### Drivers
- **A driver in every car.** Traffic cars now show a driver (and a passenger in some), hands on the wheel, even the simple pooled traffic cars. They are drawn by the car, cost almost nothing, and only animate within about 40 m of the camera. Your own car keeps the full driver with its physics (90 kg, leaning with the car); the car you were in becomes a prop driver when you get into another.
- **A driver leaves a car** that has braked to a stop. A car with no camera of its own still gets a driver, seated at the wheel. A car nobody drives (for sale on a lot, in a garage) gets none, and the player's own car never gets a passenger.
- **Your driver, your way.** Choose who drives, shirt and trouser colours, size and a helmet; four HD characters (Alison, Carla, Eric, Manuel) join the SLRR drivers. They look back over the shoulder when reversing, glance at the mirrors, shift with the car's own gear pattern and keep their feet in the footwell.
- **Waving.** A driver can wave out of the window with the hand that is not on the lever, turning his head to the person he waves at.
- **Slumped over the wheel.** A driver who is knocked out slumps forward until he wakes up.
- **Clothing colours stay right** after a new level loads (the tinted materials are rebuilt when the game drops them).

### Pedestrians
- **West Coast USA and other maps.** Sidewalks are made from the road graph on first use. Busier downtown, Chinatown and beachfront, quieter suburbs; workers in hi-vis at the docks, industrial areas and the quarry, business people in the centre; SLRR's clothing variants recoloured.
- **Walkers for the HD drivers.** Alison, Carla, Eric and Manuel also walk, with walk, slow, fast and idle animations.
- **They behave on the road.** People wait for the crossing and keep off the road; someone caught on a carriageway crosses to the far kerb, a little faster, and never stops or turns back on the road. They stand about less (short stops, few start standing), nobody waits at a kerb for more than 20 seconds, they jump out of the way of fast cars and stop and look at, or hurry away from, a crash.
- **Spectators** at venues, the drag strip, race tracks and car meets, who cheer when a race ends or a win comes in. Mods for other levels can add their own crowds.
- **A scripted walker** (a driver's walker walking to a point, waiting, standing) for scenes such as the garage arrival.
- **In a career the walker is your body:** the unicycle's snowman mesh is hidden while the walker is shown, there is no body in first person, and a walker is dropped if you are not on the unicycle (no figure lying on a roof).
- **Frame rate.** The crowd thins out when the frame rate drops, but never below half of what you asked for. The default is 36 people at once, fewer in quiet districts; change it in the settings.
- **Materials survive a level change.** Pedestrian and driver textures are loaded again on every level load; some pedestrians no longer appear untextured after the second level.

### Settings
- The drivers' and the world's settings appear in the Wrench Works settings: driver mode, how many pedestrians, frame-rate thinning, idling, crossing.
- **Driver injuries** are a separate add-on (see its own changelog); with it, a crash can hurt, knock out or kill the driver.

### Fixed
- A door latch broke when you entered a car (the driver's weight sat on the latch).
- A late driver camera is retried; errors in the walk generator stop after one instead of flooding the log; no bad transform ever reaches the engine; a far driver no longer costs a frame.
- A driver appeared on the roof of a car entered right after it spawned.
- A scripted walker given as a position no longer stops the scene that uses it.
