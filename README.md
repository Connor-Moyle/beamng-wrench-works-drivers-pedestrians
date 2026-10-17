# Wrench Works: Drivers & Pedestrians for BeamNG.drive

Puts the drivers and pedestrians from Street Legal Racing Redline into BeamNG.drive.

- **A driver in every car.** He sits in the driver's seat of any car, with no setup per car. His
  hands follow the steering wheel hand over hand. When the revs climb, his shifting hand goes to
  the gear lever, and on a gear change it runs the lever through the H pattern.
- **He has weight.** 90 kg is added to the car at the seat, so braking, cornering and balance
  change the way they would with someone sitting there.
- **He moves with the car.** His upper body leans into braking, acceleration and corners, held by a
  seatbelt. He stops against the wheel, doors, pillars and roof (visually: he never pushes on the car,
  so he can't knock a door open).
- **Feet on the pedals.** His right foot works the throttle and moves across to the brake, and his
  left works the clutch in manual cars. Each car's footwell is measured from its own collision
  surfaces (floor, toe board, firewall), so the feet sit on the pedals, above the floor, on every car,
  and follow a footwell crushed in a crash. Each foot pivots to match its pedal.
- **Looks where you look.** In third person your driver turns his head (and a little of his body)
  toward where the camera looks, up to about 95 degrees, smoothly; he faces forward again when you
  look behind him, and keeps his eyes mostly on the road at speed, steering hard or braking.
- **Crash damage.** The wheel is followed live, so a steering column pushed in by a crash brings his
  hands closer. After a hard crash, once the car has slowed down, he holds his head and shakes it for a
  few seconds (never at speed, and not in your own first-person view).
- **Visible in first person and in the mirrors.** Look down and you see your arms, chest and legs
  working. The camera sits inside his head, so the head never blocks your view, but it shows in the
  mirrors and turns with your view.
- **Pedestrians walk the city.** On the Valo City map (SLRR's city rebuilt for BeamNG) SLRR's six
  pedestrians walk SLRR's own sidewalks with SLRR's walk and idle animations, their feet planted.
  They go round corners, stand about on corners, wait for green to cross at traffic lights, keep out of
  each other's way, step round parked cars and jump out of the way of fast ones.
- **Waves and slumps.** A driver waves out of the window, and a knocked-out one slumps over the wheel until he wakes (with the injury add-on).
- **HD characters.** Alison, Carla, Eric and Manuel drive and also walk the streets.
- **Crowds at venues.** Spectators stand at the drag strip, the race tracks and car meets, and cheer when a race ends.
- **A scripted walker** walks a driver to a point, waits and stands, for scenes such as arriving at a garage.
- **Optional injuries add-on** (`addon_injury`): crashes bruise, break an arm or a leg, knock the driver out and, in the right mode, kill him.
- **Remastered PBR textures.** Every skin is upscaled 4x and has normal, roughness and AO maps.
- **Easy to extend.** New skins and new bodies drop in as folders. See [docs/MODDING.md](docs/MODDING.md).

It works on its own, and it also plugs into
[Wrench Works](https://github.com/Connor-Moyle/beamng-wrench-works): with both installed, the
garage's Services drawer gets a **Driver** choice.

## With the career

Part of **Wrench Works Street Legal - West Coast**. In the career the garage's **Drivers** tab picks who sits in your car, the shirt-and-trousers outfit and a helmet (only where the driver has a helmet mesh); at track events the helmet is put on for you when there is one, and your own choice comes back afterwards. People walk the sidewalks of West Coast USA (`density_west_coast_usa.json`), and the whole mod is optional: the career works without this mod.

## Requirements

BeamNG.drive 0.39. Nothing else: Wrench Works (the garage) and Street Legal (the career) are optional, and the mod works without them.

## Install

1. Download `slrr_drivers_and_pedestrians.zip` from the latest release.
2. Put it in BeamNG's mods folder (`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`). Don't unzip it.
3. Start the game.

A car has a driver while it is being driven: the player's car while you're in it, and AI cars that are
driving (traffic, racers, police). Parked, lot and garage cars, wrecks, props, trailers and the on-foot
player stay empty, and a car empties as soon as you get out or its AI is switched off.

Every car but yours is drawn by the car itself: at spawn the driver's fourteen parts are added to it as
vehicle props, posed from the game side (no body physics, no injuries, next to free), and three cars in
ten get a passenger in another skin beside him. Your own car keeps the full driver: body physics, the
look, and the injury add-on. Get into another car and the full driver moves with you; the one you left
becomes a prop driver.

## Drivers

| id | Looks | SLRR body |
|---|---|---|
| `slrr_mitch` | Mitch, SLRR's player (the default) | vin |
| `slrr_opponent1` | street racer | vin |
| `slrr_opponent2` | street racer | vin |
| `slrr_police` | police officer | police |

### Choosing a driver

In Wrench Works, open a garage, then **Services → Driver**. Without Wrench Works, use the Lua
console (`~`):

```lua
slrrDrivers.setDefaultDriver('slrr_police')               -- every car, saved
slrrDrivers.setDriver(be:getPlayerVehicleID(0), 'slrr_opponent1')  -- just this car
slrrDrivers.setDriver(be:getPlayerVehicleID(0), nil)      -- no driver in this car
```

### The rigged driver (option)

The default driver is drawn as vehicle props. A second kind, off by default, is built into the car: sixteen joint nodes in the seat
carry his weight (69 kg), and the character is drawn by the car as flexbodies bound to them, so he rides exactly in the seat and
shows in the mirrors. Turn it on (saved, for cars spawned afterwards) and off in the Lua console:

```lua
slrrDriverMount.setDriverRig('flex')    -- the rigged driver
slrrDriverMount.setDriverRig('props')   -- the prop driver (default)
slrrDriverMount.setOptOut('pickup', true)   -- a car model that always keeps the prop driver
```

A car where no seat is found keeps the prop driver. Limits for now: no clothing colours, size, helmet or passenger on the rigged
driver, and on big cabs (pickup, midtruck) the hands may not show on the wheel.

### Display modes

Wrench Works' garage has a **Driver** setting for this. Without the garage, use the console:

```lua
slrrDrivers.setDisplayMode('full')             -- animated driver everywhere (default)
slrrDrivers.setDisplayMode('still')            -- seated, no animation
slrrDrivers.setDisplayMode('hideFirstPerson')  -- animated, but not drawn in your own driver camera
slrrDrivers.setDisplayMode('hidden')           -- no driver at all
```

### Clothing colours, size and a helmet

```lua
slrrDrivers.setAppearance(nil, {shirt = {0.8, 0.1, 0.1}, trousers = {0.1, 0.1, 0.3}})   -- everyone (saved)
slrrDrivers.setAppearance(be:getPlayerVehicleID(0), {helmet = true, helmetColor = {1, 0.8, 0}, scale = 1.05})
```

## Pedestrians

They appear around the camera on maps that have a sidewalk file. Valo City has one; it's converted
from SLRR's own pedestrian paths. 36 walk at a time by default (busy districts get more of them, quiet ones fewer), fewer while the frame rate is low, but never below half:

```lua
slrrPedestrians.setCount(50)   -- more (saved)
slrrPedestrians.setCount(0)    -- none
```

Other maps can get pedestrians too: see *Sidewalks for other maps* in [docs/MODDING.md](docs/MODDING.md).
On West Coast USA they walk the pavements made from its roads (never the road itself), busiest in Belasco
City and Chinatown, sparse in the suburbs and out of town; workers in hi-vis in the industrial areas, the docks
and the quarry, business people in the centre, the rest casual (clothing variants recoloured from SLRR's six).

## How it works

**Seating.** BeamNG cars all have a driver's camera, placed at the driver's eyes, and the driver is
seated so his eyes are there. The steering wheel is found from the car's steering-wheel prop, and
the gear lever from its shifter, when they're within reach. Otherwise sensible defaults are used.

**The driver model** is split into fourteen pieces: body, head, and upper arm, forearm, hand, thigh,
calf and foot on each side. The converter bakes a seated pose from SLRR's skeleton and skin weights. In the game a two-bone
arm solver puts the hands on the wheel or the lever every frame.

**Pedals.** The car's pedal props tell which pedals it has (throttle, brake, clutch) and how far
each one swings. The pedal height comes from the car's cabin floor, and the pedals line up with
the steering column. The leg solver puts the ball of each foot on its pedal, presses the pad in as
far as the pedal moves, and turns the foot at the ankle to the pedal's angle.

**Steering.** Each hand holds the rim and turns with it. After about 90° it lets go and grabs
again further round, while the other hand keeps hold. The hand climbing over the top lets go first,
so the two never run out of reach together.

**Weight and body.** 90 kg is spread over the car's structure around the seat, in proportion to
each part's own weight. It's checked once a second, so fuel use or a reset can't wipe it. His upper
body is a damped spring on his hips, pushed by the car's acceleration and stopped by a seatbelt and
by the cabin. His head, chest and shoulders are collision spheres tested against the car's own
physics points around him. His weight sits on the floor and seat, never on doors, hood or trunk.

**Textures.** The SLRR skins are remastered: upscaled 4x (2048 px for drivers, 1024 for
pedestrians), with normal, roughness and ambient-occlusion maps added, so they work as full PBR
materials under BeamNG's lighting.

**Pedestrians** are skinned models with SLRR's walk cycle built in, so the game animates them by
itself. The mod moves them along the sidewalks at the speed measured from each walk cycle, so the feet
stay planted, keeps about 36 near the camera and removes the ones you leave behind. Each has its own
pace (three tempos per type) and its own habit of stopping; standing ones switch to SLRR's idle
animation. At a signalled junction they cross only when the light for their direction will stay green
until they're over. When the frame time goes over the budget (18 ms, 55 fps, by default), they thin out, to half of the number asked for at the least, and they come back
once it drops again.

## Settings

In the Wrench Works garage (Settings): driver mode (full, still, hidden in first person, hidden), who drives, shirt and trouser colours, size and helmet, how many pedestrians (off, low, medium, high, very high, and a maximum), thinning with the frame rate and the frame rate aimed at, idling, crossing, busy districts. The console commands above do the same. Settings are saved between sessions.

## Known issues

- Pedestrians have no collision; cars drive through them and they only dodge.
- The driver is not a ragdoll: he cannot be thrown out of the car, and because a car's physics points are spread out his head can slip between two of them through a panel.
- The arms are rigid pieces, so a thin seam can show at the elbows up close.
- A car bought or built away from its record may keep the full driver (and its small lag behind the car) until it is next spawned from its record.
- Nobody is in cars that are parked, for sale on a lot or in a garage.

## Limits

- He isn't a ragdoll. He can't be thrown out of the car, and because a car's physics points are
  spread out, his head can slip between two of them through a panel.
- The arms are rigid pieces, so a thin seam can show at the elbows up close.
- Pedestrians have no collision. Cars drive through them, and they only dodge.

## Rebuilding from SLRR

The converted models, textures and animations are already in `mod/art/`. To convert them again,
for example after changing the seated pose or adding SLRR models to the converters, you need a
copy of Street Legal Racing Redline and Python 3 with numpy, pillow and matplotlib
(`pip install numpy pillow matplotlib`):

```
python tools/build.py "C:/Program Files (x86)/Steam/steamapps/common/Street Legal Racing Redline"
```

This rewrites `mod/art/` and packs `dist/slrr_drivers_and_pedestrians.zip`.

## Credits

Driver and pedestrian models, textures, animations and sidewalk paths are from Street Legal Racing
Redline and belong to their owners.
