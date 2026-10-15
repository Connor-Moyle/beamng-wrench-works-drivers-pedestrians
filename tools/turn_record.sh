#!/usr/bin/env bash
# Record the driver in game for review: spawns each test car on Valo City's long straight, runs the
# scene list (idle, pulling away, hard acceleration with shifts, hard braking, cornering at speed,
# full lock at walking pace) with the pose recorder on, and saves one recording per car to the game's
# user folder (temp/slrr_rec_<car>.json). Render them with tools/render_pose.py.
#   tools/turn_record.sh            # needs BeamNG running with -enablemcp and the level loaded
set -e
cd "$(dirname "$0")"
lua() { node bng.js run_lua "$1"; }
inp() { node bng.js inject_input "{\"event\":\"$1\",\"value\":$2}" >/dev/null; }

# the far-sea fix (GPU timeouts) and the camera next to the car
lua "for _,n in ipairs({'bd_sea_north','bd_sea_south','bd_sea_west','bd_sea_east'}) do local o=scenetree.findObject(n) if o then o:setField('gridElementSize',0,'200') o:postApply() end end return 'seas'"

for car in "etk800:844_150_M" "wendover:" "vivace:ardente_230_DCT"; do
  model=${car%%:*}; config=${car#*:}
  cfg=""; [ -n "$config" ] && cfg=", config='vehicles/$model/$config.pc'"
  lua "local q=quatFromDir(vec3(0,-1,0), vec3(0,0,1)) local v=core_vehicles.spawnNewVehicle('$model', {pos=vec3(2336.88,330,6.6), rot=q, autoEnterVehicle=true, cling=true$cfg}) M_rec=v:getId() return M_rec"
  sleep 6
  node bng.js run_lua_vehicle '{"code":"controller.mainController.setGearboxMode(\"arcade\") return 1"}' >/dev/null
  lua "commands.setGameCamera() core_camera.setByName(0,'orbit') slrrDrivers.startRecording(M_rec) local c=slrrDrivers.getState(M_rec) return dumps({manual=c and c.manual, knob=c and c.knobNode, clutch=c and c.hasClutch})"
  inp parkingbrake 0; inp brake 0
  sleep 4                                            # idle: breathing, head drift, glances
  inp throttle 0.35; sleep 4                         # pulling away
  inp throttle 1.0; sleep 6                          # hard acceleration through the gears
  inp throttle 0; inp brake 1; sleep 3; inp brake 0  # hard braking
  inp throttle 0.5; sleep 2
  inp steering 0.25; sleep 3; inp steering -0.25; sleep 3; inp steering 0   # cornering at speed
  inp throttle 0; inp brake 1; sleep 3; inp brake 0
  inp throttle 0.2
  inp steering 1; sleep 3; inp steering -1; sleep 3; inp steering 0          # full lock at walking pace
  inp throttle 0; inp brake 1; sleep 2
  lua "local perf, n = slrrDrivers.getPerf() local frames = slrrDrivers.stopRecording(M_rec, '/temp/slrr_rec_$model.json') be:getObjectByID(M_rec):delete() return string.format('$model: %d frames recorded, drivers %.2f ms/frame for %d cars', frames, perf, n)"
  inp brake 0
done
echo "recordings in %LOCALAPPDATA%/BeamNG/BeamNG.drive/current/temp/slrr_rec_*.json"
