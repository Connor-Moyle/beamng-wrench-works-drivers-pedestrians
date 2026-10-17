# Changelog: Wrench Works: Drivers & Pedestrians

## Unreleased

### Drivers
- **The rigged driver is a per-session choice.** `setDriverRig('flex')` is no longer saved (a saved setting from an earlier version is
  ignored), so the game never starts with it on by surprise. A flex driver is no longer rebuilt when the player switches car, its pose
  feed pauses for half a second around a vehicle switch or reset, and his head is not hidden or shown within half a second of a switch
  (a game crash at a vehicle switch with flex cars about, 2026-10-18).

## 1.6.0

### Pedestrians
- **More pedestrians by default.** The base count is 48 (was 36); a night run with the career's traffic at 36, 60 and 72 showed no extra frame cost.
- **Less work each frame.** The cars' axes and boxes are read ten times a second a car (their positions and speeds every frame), the pedestrian cells use integer keys and are rebuilt five times a second, and each car's speed is worked out once, not for every pedestrian. Same behaviour; a hitch recording showed this update at 4.7 ms in busy frames.

### Drivers
- **The rigged driver is EXPERIMENTAL:** it can crash the game when switching cars. Leave it off (it is off by default) until this is fixed.
- **The rigged driver takes setAppearance.** Size (0.9 to 1.1) resizes his nodes and meshes when the car spawns; a helmet (models that
  have one) is a fifteenth flexbody bound to the head; the helmet colour switches
  material per car, so other cars keep theirs. Shirt and trousers colours are not applied to him yet. A car with a flex driver
  still gets the props passenger beside him.
- **The rigged driver rests on the seat.** Pelvis and chest rest on up to three seat nodes each (a big cab has none within 0.4 m of the
  old spot, so the driver sank 0.4 m in a pickup), and once the car has stood still for 3 s the arms and legs are measured from where
  the torso settled, so the hands reach the wheel in the Covet and the pickup.
- **The rigged driver's hands reach the wheel in big cabs.** Hands, knees and feet are also tied by soft beams (20000 N/m, limited in length) to the
  steering, seat and floor nodes of the cabin (never the dash, glass, mirrors or roof), so they no longer flip to the wrong side of the
  torso: the midtruck driver's hands are on the wheel now too, without any damage to the car's glass.

## 1.5.0 (the rigged driver, an option)

### Drivers
- **The rigged driver (option, off by default).** A driver that is part of the car: sixteen joint nodes in the seat carry his 69 kg
  (instead of 90 kg spread over the seat's nodes), stiff beams hold them in the seated pose, and the character's fourteen
  pieces are drawn by the car as flexbodies bound to those nodes. The car draws him, so he sits exactly in the seat, shows in the
  mirrors and cannot lag behind. His hands, legs and head are posed as before (hand over hand on the wheel, the pedals, the lever,
  looking round) and the car moves the joints smoothly.
- Turn it on with `slrrDriverMount.setDriverRig('flex')` in the Lua console (for this session only: not saved, it applies to cars spawned afterwards) and back
  with `setDriverRig('props')`. A car with no seat found gets no flex driver and keeps the prop driver (logged);
  `slrrDriverMount.setOptOut('modelname', true)` keeps one car model on props.
- Not in the rigged driver yet: clothing colours, size and helmet, the passenger, ragdoll injuries. The injury add-on is unchanged.
- Known: on large cabs (pickup, midtruck) the hands may not show on the wheel; the feet and head do.

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
- **Frame rate.** The crowd thins out when the frame rate drops, but never below half of what you asked for. The default is 48 people at once (was 36; a night run of the career with 36, 60 and 72 showed no extra frame cost), fewer in quiet districts; change it in the settings.
- **Materials survive a level change.** Pedestrian and driver textures are loaded again on every level load; some pedestrians no longer appear untextured after the second level.

### Settings
- The drivers' and the world's settings appear in the Wrench Works settings: driver mode, how many pedestrians, frame-rate thinning, idling, crossing.
- **Driver injuries** are a separate add-on (see its own changelog); with it, a crash can hurt, knock out or kill the driver.

### Fixed
- A door latch broke when you entered a car (the driver's weight sat on the latch).
- A late driver camera is retried; errors in the walk generator stop after one instead of flooding the log; no bad transform ever reaches the engine; a far driver no longer costs a frame.
- A driver appeared on the roof of a car entered right after it spawned.
- A scripted walker given as a position no longer stops the scene that uses it.
