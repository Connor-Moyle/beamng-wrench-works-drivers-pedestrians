# Modding guide

How to add your own drivers, skins, bodies, pedestrians and sidewalks. Everything is found by
scanning folders when the game starts, so your additions can live in your own mod zip. You don't
need to edit this mod.

## Folder layout

```
art/slrr_drivers/
  models/<body>/            one folder per driver body
    body.dae head.dae r_upperarm.dae r_forearm.dae r_hand.dae l_upperarm.dae l_forearm.dae l_hand.dae
    r_thigh.dae r_calf.dae r_foot.dae l_thigh.dae l_calf.dae l_foot.dae
    rig.json
  models/main.materials.json   the shared placeholder material "base_driver"
  <driverId>/               one folder per driver
    driver.json
    main.materials.json
    <texture>.color.png     base colour         (the PBR set: made by tools/remaster_textures.py,
    <texture>.normal.png    normal map           or paint your own)
    <texture>_r.data.png    roughness
    <texture>_ao.data.png   ambient occlusion
    preview.png             optional, shown in the Wrench Works garage

art/slrr_pedestrians/
  <name>/<name>.dae         one folder per pedestrian; the folder and file names must match
  <name>/ped.json           optional: walk shapes with their speeds, and an idle shape
  <name>/main.materials.json
  <name>/<texture>.color.png, .normal.png, _r.data.png, _ao.data.png
  walk_<levelName>.json     sidewalks for one map

lua/ge/extensions/slrrDrivers.lua          drivers: seating, arms, weight, collision, API
lua/ge/extensions/slrrPedestrians.lua      pedestrians
lua/vehicle/extensions/slrrDriverFeed.lua  vehicle side: steering/rpm/gear feed, driver weight, impacts
tools/                                     converters (Python)
```

After adding files, restart the game, or run `slrrDrivers.reload()` in the Lua console.

## 1. A new skin on an existing body

The quickest change: a new texture on the vin or police body.

1. Copy `art/slrr_drivers/slrr_mitch/` to `art/slrr_drivers/<yourId>/`, using a lowercase id with no
   spaces, e.g. `my_racer`.
2. Paint your texture over `*.color.png`, which shows the UV layout (2048 x 2048). Either paint
   matching normal, roughness and AO maps too, or let the remaster tool make them (see below).
3. Edit `main.materials.json` so the material is named `<yourId>_driver` (both `name` and `mapTo`)
   and the maps point at your files:

   ```json
   {
     "my_racer_driver": {
       "name": "my_racer_driver", "mapTo": "my_racer_driver", "class": "Material",
       "version": 1.5, "materialTag0": "beamng",
       "Stages": [{
         "baseColorMap": "/art/slrr_drivers/my_racer/my_racer.color.png",
         "normalMap": "/art/slrr_drivers/my_racer/my_racer.normal.png",
         "roughnessMap": "/art/slrr_drivers/my_racer/my_racer_r.data.png",
         "ambientOcclusionMap": "/art/slrr_drivers/my_racer/my_racer_ao.data.png",
         "metallicFactor": 0
       }, {}, {}, {}]
     }
   }
   ```

   Only `baseColorMap` is required. Keep the file-name endings: BeamNG reads `.color` files as
   colour (sRGB), and `.normal` and `.data` files as linear data.

4. Edit `driver.json`:

   ```json
   { "name": "My Racer", "model": "vin", "skin": "my_racer", "mass": 85 }
   ```

   | field | meaning |
   |---|---|
   | `name` | shown in menus |
   | `model` | which body: a folder in `art/slrr_drivers/models/` (`vin`, `police`, or yours) |
   | `skin` | the material prefix: the game looks for `<skin>_driver` |
   | `mass` | optional, kg added to the car (default 90) |

5. Optional: add a 640x320 `preview.png`.

The body's shapes all use the material `base_driver`. For each driver the mod writes copies of the
shapes, with that name replaced by `<skin>_driver`, into BeamNG's `temp/slrr_drivers/` folder. You
never edit the shapes for a new skin.

## 2. A new body

### Option A: an SLRR-style skinned model (easiest)

If your model is an SLRR human (a skinned `.SCX` plus its `.skl`), add it to the `DRIVERS` list in
`tools/convert_drivers.py` and run the converter. It bakes the seated pose, splits the pieces and
writes `rig.json`. Any biped with 3ds Max "Bip01" bone names works, at least:

`Bip01 Pelvis, Spine, Neck, Head, R/L Clavicle, R/L UpperArm, R/L Forearm, R/L Hand,
R/L Thigh, R/L Calf, R/L Foot`

### Option B: build the fourteen pieces yourself (any 3D package)

Make a folder `art/slrr_drivers/models/<body>/` with the fourteen Collada shapes and a `rig.json`.

**Coordinates.** The driver's seat frame, in metres: **x right, y forward, z up**. The origin is
the driver's **eyes**. The body sits in a normal driving pose with both hands on a wheel centred at
about (0, 0.56, -0.30): a 0.185 m radius, its face tilted back 25°, hands at a quarter past nine.

**Pieces.** Cut the model at the neck, shoulders, elbows, wrists, hips, knees and ankles. Each piece goes in its own
`.dae`, with **its pivot at the joint it turns around**:

| file | contains | origin at |
|---|---|---|
| `body.dae` | torso and hips | the eye point (0, 0, 0) |
| `head.dae` | head and neck | the base of the neck |
| `r_upperarm.dae`, `l_upperarm.dae` | upper arm | the shoulder joint |
| `r_forearm.dae`, `l_forearm.dae` | forearm | the elbow |
| `r_hand.dae`, `l_hand.dae` | hand | the wrist |
| `r_thigh.dae`, `l_thigh.dae` | thigh | the hip joint |
| `r_calf.dae`, `l_calf.dae` | lower leg | the knee |
| `r_foot.dae`, `l_foot.dae` | foot | the ankle |

Keep each piece in the seat frame's orientation; just move its origin to the joint. Let the
geometry overlap a little at each joint, which hides gaps when the joint bends. Use the material
name `base_driver` for everything. Export Collada with Z up, in metres.

**rig.json** gives the joint positions in seat coordinates, the same points as the origins above:

```json
{
  "model": "mybody",
  "parts": {
    "body": [0, 0, 0], "head": [0, -0.06, -0.15],
    "r_upperarm": [0.18, -0.05, -0.19], "r_forearm": [0.29, 0.17, -0.43], "r_hand": [0.18, 0.37, -0.28],
    "l_upperarm": [-0.18, -0.05, -0.19], "l_forearm": [-0.29, 0.17, -0.43], "l_hand": [-0.18, 0.37, -0.28]
  },
  "pelvis": [0, -0.12, -0.62],
  "arms": {
    "r": {"shoulder": [0.18, -0.05, -0.19], "elbow": [0.29, 0.17, -0.43], "wrist": [0.18, 0.37, -0.28]},
    "l": {"shoulder": [-0.18, -0.05, -0.19], "elbow": [-0.29, 0.17, -0.43], "wrist": [-0.18, 0.37, -0.28]}
  },
  "legs": {
    "r": {"hip": [0.12, 0.08, -0.70], "knee": [0.16, 0.50, -0.66], "ankle": [0.18, 0.76, -1.03], "ball": [0.16, 0.96, -0.97]},
    "l": {"hip": [-0.12, 0.08, -0.70], "knee": [-0.16, 0.50, -0.66], "ankle": [-0.18, 0.75, -1.02], "ball": [-0.16, 0.96, -0.97]}
  }
}
```

The arm lengths are worked out from shoulder→elbow and elbow→wrist, and the solver keeps them. The
pose you model is the "rest" pose, and in the game each piece turns away from it. `pelvis` is the
pivot the upper body leans about. `ball` is the ball of the foot, the point that presses a pedal.
The head must enclose the eye point (0, 0, 0). In first person the camera sits there, so the head
can't be seen from inside but still shows in the mirrors.

Then make a driver folder that uses it (`"model": "mybody"`), as in section 1.

### Making PBR maps from a plain texture

`tools/remaster_textures.py` turns a plain skin into a full PBR set. Put your texture in the
driver's or pedestrian's folder as a `.dds` file, next to its `main.materials.json`, and run:

```
python tools/remaster_textures.py --upscaler path/to/realesrgan-ncnn-vulkan.exe
```

It upscales the texture 4x (to 2048 for drivers, 1024 for pedestrians), writes the colour, normal,
roughness and AO maps, and points the material at them. The upscaler is the free Real-ESRGAN
ncnn-vulkan build (github.com/xinntao/Real-ESRGAN, releases); without `--upscaler` it falls back
to a plain sharpened resize. The roughness comes from colour: skin about 0.55, cloth 0.85, and
dark hair, shoes and belts 0.6. Edit `*_r.data.png` (darker = shinier) if your outfit needs
something else, such as a leather jacket.

## 3. Pedestrians

Every `art/slrr_pedestrians/<name>/<name>.dae` is a pedestrian type. Add a folder and it joins the
crowd.

The shape must:

- **face +Y, with Z up, in metres**, with the feet at z = 0 and the origin between the feet;
- **walk in place**: the walk cycle loops as the shape's own animation (BeamNG plays it as the
  "ambient" sequence). A skinned mesh with a skeleton and one looping walk animation, exported from
  Blender or similar as Collada, works;
- loop about once a second, so the feet match the walking speed (about 1.15–1.5 m/s).

Add a `main.materials.json` for its textures, the same as for a driver skin (any material name). The
remaster tool works on pedestrian folders too.

Optionally add a `ped.json` next to the shape:

```json
{ "walks": {"kim.dae": 0.85, "kim_slow.dae": 0.765, "kim_fast.dae": 0.935}, "idle": "kim_idle.dae" }
```

`walks` lists the walk shapes in the folder with the speed (m/s) at which each one's feet stay planted;
each pedestrian picks one. `idle` is a shape that stands in place, played while it waits or stands
about. Without `ped.json` the folder's shape walks at 1.3 m/s and never stops. The converter measures
the speeds for SLRR's pedestrians; to check one, `python tools/walk_review.py <name> <skin.dds> out.mp4`
renders the cycle over a scrolling grid and prints how far a planted foot slides.

To convert more SLRR pedestrians, add them to `PEDS` in `tools/convert_peds.py`. The converter
writes the skeleton, skin weights and walk animation into the Collada file.

## 4. Sidewalks for other maps

Pedestrians walk only on maps that have `art/slrr_pedestrians/walk_<levelName>.json`. Here
`<levelName>` is the map's folder name, as in `/levels/<levelName>/`. The file is a list of polylines
in world coordinates:

```json
[
  [[x, y, z], [x, y, z], [x, y, z]],
  [[x, y, z], [x, y, z]]
]
```

Run one line along each sidewalk, a metre or so in from the kerb. Where two lines end within 14 m of
each other, pedestrians walk from one to the other: around corners, and across the street at
junctions. Heights are snapped to the ground, so they don't have to be exact. If the map has traffic
signals (`core_trafficSignals`, the level's `signals.json`), a crossing of 5 m or more within 35 m of a
signal group's centre waits for the green of the approach running alongside it.

You can get the points from the World Editor: place a decal road or a path along the sidewalk and
copy its node positions.

## 5. Tuning

The numbers at the top of `slrrDrivers.lua` are meant to be tweaked:

| constant | default | what it does |
|---|---|---|
| `WHEEL_CENTER`, `WHEEL_TILT`, `WHEEL_RADIUS` | (0, .56, -.3), 25°, .185 m | the wheel, when a car has no steering prop |
| `HAND_RANGE` | 90° | how far a hand turns with the wheel before it re-grips |
| `REACH_RPM` | 0.82 | share of max rpm at which the hand goes to the lever |
| `DRIVER_MASS` | 90 kg | default added weight |
| `SWAY_GAIN`, `SWAY_HZ`, `SWAY_DAMP` | 0.7, 1.6, 0.45 | how much and how fast the body leans |
| `SEATBELT` | 0.07 m | hard limit on how far the head can travel from its seated place |
| `CULL_DIST` | 150 m | drivers farther from the camera are hidden |

In `slrrPedestrians.lua`: spawn and despawn distances, `LINK_DIST` (how far apart sidewalk ends can
be and still connect), `CAR_MARGIN` (room left around parked cars), `PERSONAL` (room kept from other
pedestrians), `IDLE_MIN`/`IDLE_MAX` (how long they stand), `CROSS_MIN` and `JUNCTION_REACH` (which
crossings obey signals) and `FRAME_BUDGET` (the frame time above which pedestrians are thinned out).

If you change the wheel defaults, change them in `tools/convert_drivers.py` too and run it again,
because the seated pose is baked around them.

## 6. Script API

```lua
slrrDrivers.getDrivers()             -- {{id=, name=, preview=}, ...}
slrrDrivers.setDriver(vehId, id)     -- id nil or "none": no driver in that car
slrrDrivers.getDriver(vehId)         -- id or nil
slrrDrivers.setDefaultDriver(id)     -- for cars with no choice of their own (saved)
slrrDrivers.getDefaultDriver()
slrrDrivers.setDisplayMode(mode [, vehId])   -- "full" (default), "still", "hideFirstPerson", "hidden"
slrrDrivers.getDisplayMode([vehId])          -- without vehId: the global mode (saved); with it: that car
slrrDrivers.setAnimated(on)          -- shortcut: true = "full", false = "still"
slrrDrivers.reload()                 -- rescan driver folders
slrrDrivers.getState(vehId)          -- internal state, for debugging

slrrPedestrians.setCount(n)          -- how many walk at once (saved)
slrrPedestrians.getCount()
```

Choices made with `setDriver` survive part changes, resets and respawns of the same vehicle. A
career or garage mod that respawns cars under new ids should call `setDriver` again after the
spawn.

## 7. SLRR file formats (for the curious)

These are what the converters read, worked out from the files:

- **Skinned `.SCX`** (version 4): a directory of chunks, tagged 0 material, 3 bone palette (indices
  into the `.skl`), 4 vertices, 5 indices (u16 triangles). Vertex flags: 0x2 blend indices
  (u8 x4 into the palette); 0x4 / 0x8 / 0x10 = 1 / 2 / 3 stored weights, the last being 1 minus the
  rest. The layout is position f3, weights, indices u8x4, normal f3, uv f2. Units are cm, y up.
- **`.skl` / `.bon`**: text. Per bone: name, parent index, three rows of the local rotation, the
  local translation (3ds Max row-vector form), and three lines of joint limits.
- **`.matrixdata`**: u32 bone count, then per bone (in `.skl` order) a u32 key count and keys of
  time, quaternion x y z w (the local rotation), and the unit direction of the bone's offset (its
  length comes from the `.skl`). A list of bone names closes the file.
- **`maps/city/ai/city.walk`**: one text line per walk-mesh cell: its bounding box, an id, then the
  cell's binary data written as hex using the letters A–P. The sidewalk polylines inside are runs of
  24-byte records (a point, then the step to the next).
