# Changelog: Wrench Works: Drivers & Pedestrians

## Unreleased (release 1 candidate; proposed version 1.4.0, now 1.3.0)

What is new since 1.3.0, for players:

- **A driver in every car.** Traffic and parked-up cars now show a driver (and a passenger in some), hands on the wheel, even the simple pooled traffic cars. They are drawn by the car, cost almost nothing, and only animate within about 40 m of the camera. Your own car keeps the full driver with its physics (90 kg, leaning with the car).
- **A driver leaves a car** that has braked to a stop. A car with no camera of its own still gets a driver, seated at the wheel.
- **Your driver, your way.** Choose who drives, shirt and trouser colours, size and a helmet; four HD characters join the SLRR drivers. They look back over the shoulder when reversing, glance at the mirrors, shift with the car's own gear pattern and keep their feet in the footwell.
- **Pedestrians on West Coast USA** (and other maps): sidewalks are made from the road graph on first use, with busier downtown and beachfront areas, SLRR's clothing variants recoloured, people who wait for the crossing and keep off the road, and spectators at venues and car meets. When you get out, your driver walks.
- **Settings for the drivers and the world** appear in the Wrench Works settings: driver mode, how many pedestrians, frame-rate thinning, idling, crossing.
- **Driver injuries** are a separate add-on (not part of this build); with it, a crash can hurt or kill the driver.

Fixed: a door latch broke when you entered a car (the driver's weight sat on the latch); a late driver camera is retried; errors in the walk generator stop after one instead of flooding the log; no bad transform ever reaches the engine; a far driver no longer costs a frame.
