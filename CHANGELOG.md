# Changelog: Wrench Works: Drivers & Pedestrians

## 1.6.0 (release candidate)

### Pedestrians
- **Rain.** In rain people walk a faster walk (some run), the streets empty (up to 40 % of the crowd at the heaviest rain), and some stop under a
  roof on their pavement (an awning, a bus stop, a doorway, a bridge: found by rays upward along the pavement) for 20 to 60 s, or until the rain
  stops. Options `rainReact`, `rainShelter`, `rainThin`; `setRain(0..1)` overrides the weather (`slrrValoWeather` or Street Legal's weather is read otherwise).
- **A limp with a broken leg.** On foot, the injury add-on's `limits.slowWalk` (or `slrrPedestrians.setLimp(true)`) cuts the walker's speed to
  `limpPace` % (55 by default) of a walk and takes sprinting away. Options `limp`, `limpPace`.
- **The Mods menu page** (`slrrPedestrians.settingsSchema()`) lists every option above, with the crowd size and the other options.

### Built, not yet tested in game
Built, with offline tests, but not yet seen working in the game. An item leaves this list only when the tester posts a pass.
- **Many more settings.** The Drivers tab (and the Injury tab of the injury add-on) offer the numbers that were fixed in the code: hand and foot speed, hand-over-hand timing, arm stretch, lever timing, breathing, head turn and speed, mirror glances, reversing look, body sway and its limits, what counts as a crash and how he reacts, how far drivers are drawn and animated, the prop driver's weight; for injuries: toughness, recovery times, the bruise, break and knock-out thresholds, the voice gap. The expert ones are under Show advanced. `slrrDrivers.setTune(key, value)` / `getTune` / `resetTune`, and `slrrInjury.setTune` do the same from the console; changed values are saved in the settings files.
- **The driver and the car's controls.** When the wipers, the lights or the indicators change, the hand on that stalk reaches for it and goes back to the wheel (never while the wheel is turned well over), and at low speed with the wipers on he leans forward a little to see through the wet windscreen. Switches and timings in the Drivers tab (Controls); the car reports the changes (slrrDriverFeed polls its electrics).
- **The limp's speed cut** (Pedestrians): rewritten to wrap the walker's own walk inputs, because the vehicle sandbox blocks the old way (`debug.setupvalue`), so the cut never applied before. Wrapping is tested offline; the real walking pace (55 % of a walk, no sprint, normal again after healing) is waiting for the tester.
- **Quick setup presets.** Display mode, how far drivers are drawn and animated, collision distance, the far-driver update interval and the helmet declare Performance / Balanced / Quality / Max values for the Mods menu's quick setup (never the rigged driver).

### Drivers
- Reversing: the arm on the passenger side lies along the seat top (the elbow goes forward, not down) with the hand on the nearest top edge of that seat's back; the torso turns 30 degrees and the head looks back. Shown in every camera, below 6 m/s. Checked in the game on the rigged driver: the recorded knuckles ended 7 cm from the seat-back point, the forearm near level.
- The rigged driver is now the default for your own car **on the models that have been checked for it** (a skeleton in the car, his weight in the seat; at present the Covet, Bastion, BX, ETK I-Series, Hopper, Legran, Miramar, Pessima, Roamer, SBR, the van and Vivace: `VERIFIED` in slrrDriverMount, from the coverage sweep: wheel measured, rim within 3 cm, 14 cm of head room, a passenger seat back found, no big joint jumps); any other model gets the props, with a log line. Traffic, parked and AI cars always keep the prop driver. Mods > Driver model: Rigged on checked cars (default), Rigged on every car of yours (forces it, which can look wrong where it is unchecked), or Props; the choice is saved. Proved in game: a crash and a reset of the same car, reversing with a look back over the seat (seen from outside), the frame cost (0.6 to 1.0 ms over props, within noise).
- Steering is push-pull: each hand stays on its own side of the wheel (left 7 to 11 o'clock, right 12 to 5) and re-grips there, so no arm crosses the hub or the instrument cluster. Checked on a real-steering cockpit sheet at -1 to +1 and a fast sweep.
- **A hand that grips.** The HD characters' hands are re-baked with a looser curl (a hole of 17 to 23 mm where the rim goes) and each hand is placed so that hole is on the rim's centre line with its axis along the rim, the wrist straight to the forearm: the fingers close round the rim instead of the knuckles resting on it. A re-grip is eased, a hand turns at most 8 rad/s, a hand lets go 45 degrees (was 60) above its home spot, and the other hand never lets go until it has landed (the held hand slides). The rigged driver keeps the plain-fist hands (the new hand meshes drew white in a flexbody): `hd_*_handf`. `tools/grip_hands.py`, `tools/hand_hole.py`, `tools/test_grip.py` (the hole stays within 6 mm of the rim line in 95 % of a drive's frames). Seen by the tester on props in the Covet, pickup and Vivace; the full-lock look is better but not perfect.
- **Both hands are closed fists now.** The four HD characters' left hands were half open with the thumb stuck out (the finger curl bake turned the wrong way on that side); each left hand is rebuilt as the mirror of the right one (`tools/mirror_hands.py`). Before/after sheets from the tester: Covet, pickup and Vivace on the props and the rigged driver.
- **The rigged driver is for the player's car only** (the default for your own car; Props in Mods > Driver model if you see problems): traffic, parked and AI cars always get the props. A car gets the rig when it is spawned to be entered, when Street Legal says it is the player's (`playerCarNext`/`playerCarDone`), or when it is the car he is in being rebuilt; a swap into another car keeps its props until that car is respawned. The log says how long the build took (9 ms in the game's test). A diagnostic warns in the log when the player's car has no driver mount three seconds after it became the player's.
- **Tested in the game (tester posts, 2026-10-18):** per-car steering wheel (Covet, pickup, Vivace; the pickup's hands are on the rim), crashes scored and felt in the Street Legal career (30 km/h bruise with blur and muffle, 50 km/h bruise or worse, 80 and 120 km/h knock-out and hospital, damage adding up over crashes), the hurt voice plays (the tester cannot hear audio: Connor to confirm by ear), the rigged driver's crash handling (no broken beams, no false injuries) and head following the camera. Frame cost of the rigged driver with traffic is not yet measured cleanly (one run, +18 %, before it was made player-only).
- **Known, rigged driver on other models** (they get the props by default; Mods > Driver model can force the rig): not yet cleared by the sweep are autobello and midsize (hands 3.3 and 3.8 cm off the rim), barstow, bolide, wendover and wigeon (under 14 cm of head room), nine (4 cm off the rim), pickup, pigeon, md_series, racetruck, citybus and us_semi (no passenger seat back found), moonhawk, sunburst2 and burnside (the steering wheel was not read: the hands are on a default wheel), bluebuck, atv, etk800, etkc, fullsize, lansdale, midtruck, scintilla and utv (the wheel was not read or no steering wheel prop was found). The rigged driver was checked by numbers (recorded poses), not by a picture of every car.
- **Known:** at full wheel lock one hand can end above the rim (Vivace worst; may be camera parallax); the rigged driver's reversing arm and a same-car reset after a flex crash were shown in the game (2026-10-19); a vehicle-switch stress with the rig on is still to run before a release.
- **The Pedestrians & Drivers page in the Mods menu:** the Pedestrians, Drivers and Injury tabs (the pedestrian tab comes from the pedestrian settings).
- **How injuries feel (injury add-on).** After a hard hit the edges of the screen go blurry and his hearing is muffled, fading over a few seconds; on foot with a broken leg he cannot sprint until it heals. Switches and strengths in the Injury tab, one Reduce motion switch for the screen effects. Injury toughness, recovery times and thresholds are settings too.
- **Settings in the Mods menu.** With Wrench Works installed, the driver's settings (show the driver, who drives, size, helmet and its colour, shirt and trousers colours, the experimental rigged driver and its clothing colours) are on the Drivers tab of ESC > Mods; without it nothing changes. `slrrDrivers.settingsSchema()` and `onSlrrSettingsReady()` register them.
- The hands are placed on each car's own steering wheel (its tilt, hub position and rim size are read from the wheel prop), which fixes the pickup's hands; lever reaches and foot moves now speed up and slow down instead of starting at full speed. At full lock on the Vivace one hand still ends above the rim (known).
- The rigged driver (his head now turns to follow the camera (a node ahead of the head gives it a facing), each hand has its own roll (two nodes round the wrist, so the fingers wrap the rim and the palm faces it), he is animated up to 150 m from the camera (a watched car's driver froze beyond 40 m), more damping on the seat. Tried in game on the Covet (hands, head, no ring); the pickup's and the Vivace's hands are not right yet (rim size is one number for all cars).
- **The Driver model choice is saved** (key `rig` in the mount settings; test calls to `setDriverRig` do not save; the old `driverRig` key is ignored). A flex driver is no longer rebuilt when the player switches car, its pose
  feed pauses for half a second around a vehicle switch or reset, and his head is not hidden or shown within half a second of a switch
  (a game crash at a vehicle switch with flex cars about, 2026-10-18).

### From the earlier 1.6.0 candidate (never released)

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
