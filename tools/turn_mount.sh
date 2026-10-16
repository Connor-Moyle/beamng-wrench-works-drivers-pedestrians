#!/usr/bin/env bash
# One game slot for B7, the driver drawn by the car (slrrDriverMount props). Answers "ship it or not" against
# the criteria in C:/Dev/SLRR BeamNG Graph/qa_reports/2026-10-16_driver.md.
#   bash tools/turn_mount.sh calib        # restart the game (so vehicles/common loads), props on, x-ray both
#                                         # pose conventions: pick the one with the driver seated, hands on the wheel
#   bash tools/turn_mount.sh run [conv]   # props on, speed runs with 6-shot bursts at 30/50/70 m/s (chase + first
#                                         # person), a pose recording, then J6 with 14 traffic cars
#   bash tools/turn_mount.sh off          # flags off
# Every phase ends with the flags off (game and settings file), however it ends: a saved props=true spawns
# the props for everyone's turn.
set -e
cd "$(dirname "$0")"
REVIEW="C:/Dev/SLRR BeamNG Graph/review"
USER_TEMP="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/temp"
LOG="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/beamng.log"
lua() { node bng.js run_lua "$1"; }
inp() { node bng.js inject_input "{\"event\":\"$1\",\"value\":$2}" >/dev/null; }
shot() { SHOT="$REVIEW/$1" node bng.js screenshot_image >/dev/null; }
spawn() {   # model, y: on Valo City's long straight, facing -y, player in it
  lua "local q=quatFromDir(vec3(0,-1,0), vec3(0,0,1)) local v=core_vehicles.spawnNewVehicle('$1', {pos=vec3(2336.88,${2:-330},6.6), rot=q, autoEnterVehicle=true, cling=true}) return v:getId()"
}
speed() { lua "return string.format('%.1f', vec3(be:getObjectByID($1):getVelocity()):length())"; }
xray() {    # the driver seen from the passenger's head, wide angle (no mesh alpha: the props are car meshes too)
  lua "local v=be:getObjectByID($1) local c=slrrDrivers.getState($1) local eye=v:getPosition()+vec3(v:getNodePositionXYZ(c.camNode)) local f=v:getDirectionVector():normalized() local r=f:cross(vec3(0,0,1)) local cam=eye+r*0.8-f*0.05 local t=eye+f*0.15-vec3(0,0,0.35) commands.setFreeCamera() core_camera.setPosition(0,cam) core_camera.setRotation(0, quatFromDir((t-cam):normalized(), vec3(0,0,1))) core_camera.setFOV(0,110) return 1" >/dev/null
  sleep 2; shot "$2"; sleep 3; shot "$2"
  lua "core_camera.setFOV(0,65) commands.setGameCamera() return 1" >/dev/null
}
errors() { grep -c "driver update failed\|injection failed\|unable to prop" "$LOG" || true; }
# whatever happens, the slot ends with the flags off: in the game if it answers, and in its settings file
flagsoff() {
  lua "slrrDriverMount.setFlags({props=false, ragdoll=false}) slrrDrivers.setPropConvention(1) return 'flags off'" || true
  printf '{"props":false,"ragdoll":false,"selfCollision":false}' > "$LOCALAPPDATA/BeamNG/BeamNG.drive/current/settings/slrr_drivers_mount.json"
}
trap flagsoff EXIT

case "${1:-}" in
calib)
  powershell -NoProfile -File "C:/Dev/SLRR map for beam ng/tools/launch.ps1" -Restart
  lua "for _,n in ipairs({'bd_sea_north','bd_sea_south','bd_sea_west','bd_sea_east'}) do local o=scenetree.findObject(n) if o then o:setField('gridElementSize',0,'200') o:postApply() end end slrrDriverMount.setFlags({props=true, ragdoll=false}) slrrDrivers.setDisplayMode('full') return 'ready, props on'"
  for conv in 1 2; do
    V=$(spawn etk800); sleep 12
    if (node bng.js get_status 2>&1 | grep -q "no server"); then echo "DEAD: the game crashed within 12 s of the spawn with props on (stop here, write it up)"; exit 1; fi
    echo "alive 12 s after the spawn"
    lua "slrrDrivers.setPropConvention($conv) local c=slrrDrivers.getState($V) return 'conv $conv: drawn by car '..tostring(c and c.drawnByCar)"
    sleep 1; xray "$V" "mount_calib_conv$conv.jpg"
    lua "be:getObjectByID($V):delete() return 1" >/dev/null
  done
  echo "errors in the log so far: $(errors)"
  echo "look at $REVIEW/mount_calib_conv1.jpg and conv2.jpg, then: bash tools/turn_mount.sh run <conv>"
  ;;
run)
  CONV=${2:-1}
  RUNLOG="$REVIEW/mount_run.log"; : > "$RUNLOG"
  lua "slrrDriverMount.setFlags({props=true}) slrrDrivers.setPropConvention($CONV) slrrDrivers.setDisplayMode('full') return 1" >/dev/null
  V=$(spawn scintilla); sleep 8
  lua "local c=slrrDrivers.getState($V) return 'conv $CONV: drawn by car '..tostring(c and c.drawnByCar)" | tee -a "$RUNLOG"
  lua "commands.setGameCamera() core_camera.setByName(0,'orbit') slrrDrivers.startRecording($V) return 1" >/dev/null
  node bng.js run_lua_vehicle '{"code":"controller.mainController.setGearboxMode(\"arcade\") return 1"}' >/dev/null
  inp parkingbrake 0; inp brake 0; inp throttle 1
  for target in 30 50 70; do
    for i in $(seq 1 50); do s=$(speed "$V"); awk "BEGIN{exit !($s >= $target)}" && break; sleep 0.5; done
    echo "target $target m/s: at $s m/s" | tee -a "$RUNLOG"
    for k in 1 2 3 4 5 6; do shot "mount_${target}_chase_$k.jpg"; done
    echo "  chase burst ended at $(speed "$V") m/s" | tee -a "$RUNLOG"
    lua "core_camera.setByName(0,'driver') return 1" >/dev/null; sleep 1
    shot "mount_${target}_fp_1.jpg"; shot "mount_${target}_fp_2.jpg"
    lua "core_camera.setByName(0,'orbit') return 1" >/dev/null
    ffmpeg -y -loglevel error -framerate 3 -i "$REVIEW/mount_${target}_chase_%d.jpg" -vf "scale=960:-1" "$REVIEW/driver_mount_${target}.gif"
  done
  inp throttle 0; inp brake 1; sleep 8; inp brake 0
  lua "local perf = slrrDrivers.getPerf() return string.format('recorded %d frames, one driver %.2f ms per frame', slrrDrivers.stopRecording($V, '/temp/slrr_rec_mount.json'), perf)" | tee -a "$RUNLOG"
  lua "be:getObjectByID($V):delete() return 1" >/dev/null
  echo "== J6: 14 traffic cars"
  lua "gameplay_traffic.setupTraffic(14) return 1" >/dev/null; sleep 25
  lua "local perf, n = slrrDrivers.getPerf() local drawn = 0 for _, v in ipairs(getAllVehicles()) do local c = slrrDrivers.getState(v:getId()) if c and c.drawnByCar then drawn = drawn + 1 end end return string.format('J6: %d drivers (%d drawn by the car) cost %.2f ms per frame', n, drawn, perf)" | tee -a "$RUNLOG"
  lua "gameplay_traffic.deleteVehicles() return 1" >/dev/null
  echo "errors in the log: $(errors)" | tee -a "$RUNLOG"
  python check_recording.py "$USER_TEMP/slrr_rec_mount.json" | tee -a "$RUNLOG"
  echo "shots and GIFs: $REVIEW/mount_*; log: $RUNLOG"
  ;;
off)
  ;;
*)
  sed -n '2,9p' "$0"; exit 1
  ;;
esac
