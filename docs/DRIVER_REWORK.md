# Driver rework: design note (draft, before building)

## What the engine gives us (checked in game Lua 0.39)
- Vehicle meshes are **props** (rigid, one transform each: what we use now) or **flexbodies**: a mesh bound to a
  node group (`addFlexmesh` + `addNodeBinding`, common/jbeam/sections/meshs.lua) and **deformed by those physics
  nodes every frame**. This is BeamNG's only skinning: nodes are the bones. There is no bone/sequence playback on a
  vehicle mesh (TSStatic has sequences, but that is the scene-object path that lags and smears).
- `onJbeamLoadingPhase1` runs after node/beam ids exist and before group resolution: we can add nodes, beams and
  flexbodies (with `group`) there (slrrDriverMount already adds nodes/beams; the ragdoll prototype proves it).
- Hydros (`inputSource` = any electrics key) and `obj:setBeamLength` change beam lengths live; a vehicle-side
  extension (slrrDriverFeed) can write electrics values. That is the animation channel.

## Plan
1. **Rig** (skeleton + skinned mesh): the existing 14-piece rig is a skeleton by another name. Keep the standard
   Biped hierarchy (pelvis > spine > neck > head; clavicle > upperarm > forearm > hand; thigh > calf > foot) as the
   asset's source of truth (rig.json + the SLRR/HD skinned meshes). The converters bake ONE skinned body mesh whose
   vertex weights are mapped to ~18 joint nodes (not 14 rigid pieces), so joints bend smoothly.
2. **Slot in the car**: a real part `slrr_driver` (jbeam: nodes, beams, one flexbody, group `slrr_driver`),
   injected into every vehicle in `onJbeamLoadingPhase1` from a template (seat positions from the driver camera
   node, else the steering prop hub, else extents; the existing fallbacks). It is added to the vehicle data and to
   `activeParts` (`slotPartMap`), so the UI/part-condition/damage systems see it. No jbeam of any car is edited.
3. **Physics and weight**: joint nodes carry the body mass (about 75 kg, per driver `mass`): this REPLACES the
   mass-spread hack in slrrDriverFeed. Bones are stiff beams, joint limits are bounded beams, a seat/belt links to
   the nearest non-panel car nodes (all reused from the ragdoll prototype, already written). He moves with the
   car and adds weight; the injury add-on reads the same nodes (head/chest accelerations).
4. **Animation**: pose = target joint-node positions in the seat frame (steering IK, pedals, shifter, head look,
   idle breathing) driven through soft position-holding beams (hydros) fed from the vehicle extension each physics
   step, with per-bone smoothing. Entering/exiting: a pose track played by the same channel with the door node
   as the start. Timing is physics-rate, so no render-time lag; mirrors show him because the car draws him.
5. **Existing characters**: tools/convert_drivers.py and convert_hd.py already read the skinned source (SCX/FBX);
   add an output step "one mesh + node weights" (flexbody weights come from the engine's nearest-node binding, so
   the joint nodes must sit at the real joints and the mesh be in the seat frame).
6. **Migration**: three stages, each shippable. (A) flexbody replaces the props for traffic cars, ragdoll nodes
   always on for the player's car. (B) hydro animation replaces slrrDrivers' prop posing and the TSStatic path
   (deleted: that is the lag/blur). (C) enter/exit and injuries. Feature flag `driverRig = 'props'|'flex'` until
   stage B is signed off; props stay as fallback.
7. **Career compatibility**: keep every slrrDrivers.* the Street Legal modules call: setDriver, getDriver,
   getDrivers, setDefaultDriver/getDefaultDriver, setAppearance/getAppearance, setPartOverlay, wave, setSlump,
   setDisplayMode/getDisplayMode, feed, onAiModeChange. They become thin setters over the new part (appearance =
   material/tint on the flexbody; wave/slump = animation tracks). Same names, same arguments, same return shapes.

## Risks / unknowns (to settle with a small in-game test before building)
- Flexbody weighting of a whole-body mesh to ~18 nodes: quality unknown; fallback = one flexbody per limb segment.
- Physics-driven animation must stay stable at 2000 Hz with 18 light nodes (stress_driver.py + the earlier W9
  crash on a 28-prop truck show this engine is touchy); needs a spawn-crash test on stock + modded cars.
- A driver mesh bound to car nodes disappears with them if the car is destroyed: acceptable.
- Pedestrians (connor-a5) are untouched; they share only the converters' output folder format.

## First in-game test (manager)
Spawn one car; `slrrDriverMount.setFlags({ragdoll=true})`; respawn; check the log and that 16 nodes + belts exist,
then I add a single flexbody bound to those nodes and we look at the deformation while driving.
