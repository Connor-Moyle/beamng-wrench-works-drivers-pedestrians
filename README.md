# Wrench Works: Drivers & Pedestrians for BeamNG.drive

Puts the drivers and pedestrians from Street Legal Racing Redline into BeamNG.drive.

- **A driver in every car.** He sits in the driver's seat of any car, with no setup per car. His
  hands follow the steering wheel hand over hand. When the revs climb, his shifting hand goes to
  the gear lever, and on a gear change it runs the lever through the H pattern.
- **He has weight.** 90 kg is added to the car at the seat, so braking, cornering and balance
  change the way they would with someone sitting there.
- **He moves with the car.** His upper body leans into braking, acceleration and corners, held by a
  seatbelt. He bumps into the wheel, doors, pillars and roof, and a hard hit pushes on the part he
  hits.
- **First person stays clear.** In your own driver camera his head and upper arms are hidden, so
  you only see forearms and hands on the wheel.
- **Pedestrians walk the city.** On the Valo City map (SLRR's city rebuilt for BeamNG) SLRR's six
  pedestrians walk SLRR's own sidewalks with SLRR's walk animation. They go round corners, cross
  streets, step round parked cars and jump out of the way of fast ones.
- **Easy to extend.** New skins and new bodies drop in as folders. See [docs/MODDING.md](docs/MODDING.md).

It works on its own, and it also plugs into
[Wrench Works](https://github.com/Connor-Moyle/beamng-wrench-works): with both installed, the
garage's Services drawer gets a **Driver** choice.

## What you need

- BeamNG.drive
- Your own copy of **Street Legal Racing Redline** (Steam). The models, textures and animations are
  converted from your install. None of SLRR's files are in this repository.
- Python 3 with numpy, pillow and matplotlib, to run the converter once:
  `pip install numpy pillow matplotlib`

## Install

1. Download or clone this repository.
2. Build the mod from your SLRR folder:

   ```
   python tools/build.py "C:/Program Files (x86)/Steam/steamapps/common/Street Legal Racing Redline"
   ```

   This writes `dist/slrr_drivers_and_pedestrians.zip`.
3. Copy that zip into BeamNG's mods folder
   (`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`) and start the game.

Every car with a driver's camera gets a driver straight away. Props, trailers, the on-foot player and
cars parked by traffic stay empty, as in SLRR.

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

## Pedestrians

They appear around the camera on maps that have a sidewalk file. Valo City has one; it's converted
from SLRR's own pedestrian paths. 30 walk at a time by default:

```lua
slrrPedestrians.setCount(50)   -- more (saved)
slrrPedestrians.setCount(0)    -- none
```

Other maps can get pedestrians too: see *Sidewalks for other maps* in [docs/MODDING.md](docs/MODDING.md).

## How it works

**Seating.** BeamNG cars all have a driver's camera, placed at the driver's eyes, and the driver is
seated so his eyes are there. The steering wheel is found from the car's steering-wheel prop, and
the gear lever from its shifter, when they're within reach. Otherwise sensible defaults are used.

**The driver model** is split into eight pieces: body, head, and upper arm, forearm and hand on each
side. The converter bakes a seated pose from SLRR's skeleton and skin weights. In the game a two-bone
arm solver puts the hands on the wheel or the lever every frame.

**Steering.** Each hand holds the rim and turns with it. After about 90° it lets go and grabs
again further round, while the other hand keeps hold. The hand climbing over the top lets go first,
so the two never run out of reach together.

**Weight and body.** 90 kg is spread over the car's structure around the seat, in proportion to
each part's own weight. It's checked once a second, so fuel use or a reset can't wipe it. His upper
body is a damped spring on his hips, pushed by the car's acceleration and stopped by a seatbelt and
by the cabin. His head, chest and shoulders are collision spheres tested against the car's own
physics points around him.

**Pedestrians** are skinned models with SLRR's walk cycle built in, so the game animates them by
itself. The mod moves them along the sidewalks, keeps about 30 near the camera and removes the ones
you leave behind.

## Limits

- He isn't a ragdoll. He can't be thrown out of the car, and because a car's physics points are
  spread out, his head can slip between two of them through a panel.
- The arms are rigid pieces, so a thin seam can show at the elbows up close.
- Pedestrians have no collision. Cars drive through them, and they only dodge.

## Credits

Driver and pedestrian models, textures, animations and sidewalk paths are from Street Legal Racing
Redline and belong to their owners. This project ships only the code that converts and uses them.
