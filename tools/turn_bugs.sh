#!/usr/bin/env bash
# In-game checks for B14 (a driver only in a driven car), B17 (feet in the footwell on 10 layouts, gate J5) and
# B18 (hands follow a steering wheel pushed in by a crash). Needs BeamNG running with -enablemcp and the level.
#   bash tools/turn_bugs.sh
cd "$(dirname "$0")"
USER_TEMP="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/temp"
lua() { node bng.js run_lua "$1"; }
inp() { node bng.js inject_input "{\"event\":\"$1\",\"value\":$2}" >/dev/null; }
spawn() {   # model, y, enter
  lua "local q=quatFromDir(vec3(0,-1,0), vec3(0,0,1)) local v=core_vehicles.spawnNewVehicle('$1', {pos=vec3(2336.88,${2:-330},6.6), rot=q, autoEnterVehicle=${3:-true}, cling=true}) return v:getId()"
}
has() { lua "return slrrDrivers.getState($1) and 'driver' or 'empty'"; }
verdict() { [ "$2" = "$3" ] && echo "$1: PASS ($2)" || echo "$1: FAIL (got $2, want $3)"; }

echo "== B14: a driver only while the car is driven"
V=$(spawn etk800 300 false); sleep 6
verdict "B14 parked spawn, nobody in it" "$(has $V)" empty
lua "be:getObjectByID($V):queueLuaCommand('ai.setMode(\"traffic\")') return 1" >/dev/null; sleep 4
verdict "B14 AI traffic on" "$(has $V)" driver
lua "be:getObjectByID($V):queueLuaCommand('ai.setMode(\"stop\")') return 1" >/dev/null; sleep 10
verdict "B14 told to stop, stood still (ai flips itself to disabled)" "$(has $V)" empty
lua "be:enterVehicle(0, be:getObjectByID($V)) return 1" >/dev/null; sleep 3
verdict "B14 player got in" "$(has $V)" driver
lua "be:getObjectByID($V):delete() return 1" >/dev/null

echo "== B17 / J5: ten layouts, 3 s of idle recorded each (feet against the measured footwell)"
for model in etk800 pickup van citybus bx etki moonhawk us_semi bolide autobello; do
  V=$(spawn $model 330 true); sleep 6
  lua "slrrDrivers.startRecording($V) return 1" >/dev/null; sleep 3
  lua "local c=slrrDrivers.getState($V) if not c then return '$model: NO DRIVER' end local n=slrrDrivers.stopRecording($V, '/temp/slrr_rec_j5_$model.json') return string.format('$model: %d frames, pads %s, floor %s', n, c.pads and 'found' or 'default', c.ankleFloor and 'measured' or 'none')"
  lua "be:getObjectByID($V):delete() return 1" >/dev/null
done
python check_recording.py "$USER_TEMP"/slrr_rec_j5_*.json | grep -i "^slrr_rec\|feet\|floor\|firewall"

echo "== B18: 15 km/h into a parked truck, the wheel pushed in"
T=$(spawn us_semi 300 false); sleep 6
V=$(spawn etk800 335 true); sleep 6
lua "slrrDrivers.startRecording($V) return 1" >/dev/null
node bng.js run_lua_vehicle '{"code":"controller.mainController.setGearboxMode(\"arcade\") return 1"}' >/dev/null
inp parkingbrake 0; inp brake 0; inp throttle 0.35
for i in $(seq 1 20); do
  s=$(lua "return string.format('%.1f', vec3(be:getObjectByID($V):getVelocity()):length())")
  awk "BEGIN{exit !($s >= 4.2)}" && break; sleep 0.5
done
inp throttle 0; sleep 8
lua "return 'B18: '..slrrDrivers.stopRecording($V, '/temp/slrr_rec_b18.json')..' frames'"
python - "$USER_TEMP/slrr_rec_b18.json" <<'PY'
import json, sys, math
f = json.load(open(sys.argv[1]))["frames"]
a, b = f[0], f[-1]
hub = a["wheel"][1] - b["wheel"][1]                       # the wheel came this much closer (seat y is forward)
hand = sum(a["parts"][h][1] - b["parts"][h][1] for h in ("r_hand", "l_hand")) / 2
print("B18: wheel moved %.3f m toward the driver, hands %.3f m: %s" % (hub, hand, "PASS" if hub < 0.02 or hand > 0.5 * hub else "FAIL"))
PY
lua "be:getObjectByID($V):delete() be:getObjectByID($T):delete() return 'done'"
