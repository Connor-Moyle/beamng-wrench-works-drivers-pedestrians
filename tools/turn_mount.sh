#!/usr/bin/env bash
# One game turn for the driver drawn by the car (slrrDriverMount): A) runtime addProp of a driver mesh,
# B) the spawn-hook props (pose calibration, blur at speed, cost with traffic), C) the ragdoll prototype in
# a 15 km/h crash into a parked truck, with recordings. Restarts the game so the meshes in
# vehicles/common are there from the start; leaves the flags off.
#   bash tools/turn_mount.sh
set -e
cd "$(dirname "$0")"
REVIEW="C:/Dev/SLRR BeamNG Graph/review"
USER_TEMP="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/temp"
lua() { node bng.js run_lua "$1"; }
inp() { node bng.js inject_input "{\"event\":\"$1\",\"value\":$2}" >/dev/null; }
shot() { SHOT="$REVIEW/$1" node bng.js screenshot_image >/dev/null; sleep 3; SHOT="$REVIEW/$1" node bng.js screenshot_image; }
spawn() {   # model, y: an etk800-sized car on Valo City's long straight, facing -y, player in it
  lua "local q=quatFromDir(vec3(0,-1,0), vec3(0,0,1)) local v=core_vehicles.spawnNewVehicle('$1', {pos=vec3(2336.88,${2:-330},6.6), rot=q, autoEnterVehicle=${3:-true}, cling=true}) return v:getId()"
}
xray() {    # screenshot the driver from the car's left, car see-through
  lua "local v=be:getObjectByID($1) v:setMeshAlpha(0.15,'',false) local c=slrrDrivers.getState($1) local eye=v:getPosition()+vec3(v:getNodePositionXYZ(c.camNode)) local f=v:getDirectionVector():normalized() local r=f:cross(vec3(0,0,1)) local t=eye+f*0.35-vec3(0,0,0.45) local cam=t-r*1.6+vec3(0,0,0.15) commands.setFreeCamera() core_camera.setPosition(0,cam) core_camera.setRotation(0, quatFromDir((t-cam):normalized(), vec3(0,0,1))) return 1" >/dev/null
  sleep 2; shot "$2"
  lua "be:getObjectByID($1):setMeshAlpha(1,'',false) commands.setGameCamera() return 1" >/dev/null
}

echo "== setup: driver meshes into vehicles/common, restart"
mkdir -p ../mod/vehicles/common
cp -r ../build/props/vehicles/common/slrr_drivers ../mod/vehicles/common/
powershell -NoProfile -File "C:/Dev/SLRR map for beam ng/tools/launch.ps1" -Restart
lua "for _,n in ipairs({'bd_sea_north','bd_sea_south','bd_sea_west','bd_sea_east'}) do local o=scenetree.findObject(n) if o then o:setField('gridElementSize',0,'200') o:postApply() end end slrrDriverMount.setFlags({props=false, ragdoll=false}) return 'ready'"

echo "== A: runtime addProp"
V=$(spawn etk800); sleep 8
lua "local v=be:getObjectByID($V) local c=slrrDrivers.getState($V) for _,o in pairs(c.parts) do o:setHidden(true) end local vd=core_vehicle_manager.getVehicleData($V).vdata local sp for _,p in pairs(vd.props) do if p.func=='steering' then sp=p end end local pid=v:addProp('slrr_vin_body') local p=v:getProp(pid) p:setRefNodes(sp.idRef, sp.idX, sp.idY) local cam=vd.nodes[c.camNode].pos p:setBaseTranslationGlobal(vec3(cam.x, cam.y, cam.z)) p:setVisible(true) return 'A: prop '..pid..' '..p:getMeshName()"
xray "$V" mount_A_addprop.jpg
lua "be:getObjectByID($V):delete() return 1" >/dev/null

echo "== B: spawn-hook props"
lua "slrrDriverMount.setFlags({props=true}) return 1" >/dev/null
for conv in 1 2; do
  V=$(spawn etk800); sleep 8
  lua "slrrDrivers.setPropConvention($conv) local c=slrrDrivers.getState($V) return 'B conv $conv: drawn by car '..tostring(c and c.drawnByCar)"
  sleep 1; xray "$V" "mount_B_conv$conv.jpg"
  lua "be:getObjectByID($V):delete() return 1" >/dev/null
done
echo "   (pick the convention whose x-ray shows the driver seated; set it with slrrDrivers.setPropConvention)"
V=$(spawn etk800); sleep 8
lua "slrrDrivers.setDisplayMode('full') core_camera.setByName(0,'driver') return 1" >/dev/null
node bng.js run_lua_vehicle '{"code":"controller.mainController.setGearboxMode(\"arcade\") return 1"}' >/dev/null
inp parkingbrake 0; inp brake 0; inp throttle 1; sleep 14
lua "local v=be:getObjectByID($V) return string.format('B: %.1f m/s', vec3(v:getVelocity()):length())"
shot mount_B_speed_fp.jpg
lua "commands.setGameCamera() core_camera.setByName(0,'orbit') return 1" >/dev/null; sleep 1
shot mount_B_speed_chase.jpg
inp throttle 0; inp brake 1; sleep 7; inp brake 0
lua "be:getObjectByID($V):delete() slrrDrivers.setDisplayMode('hideFirstPerson') return 1" >/dev/null
lua "gameplay_traffic.setupTraffic(14) return 1" >/dev/null; sleep 20
lua "local perf, n = slrrDrivers.getPerf() local drawn = 0 for _, v in ipairs(getAllVehicles()) do local c = slrrDrivers.getState(v:getId()) if c and c.drawnByCar then drawn = drawn + 1 end end return string.format('B J6: %d drivers (%d drawn by the car) cost %.2f ms per frame', n, drawn, perf)"
lua "gameplay_traffic.deleteVehicles() return 1" >/dev/null

echo "== C: ragdoll, 15 km/h into a parked truck"
lua "slrrDriverMount.setFlags({props=false}) return 1" >/dev/null
T=$(spawn us_semi 300 false); sleep 6
lua "slrrDriverMount.ragdollNextSpawn() return 1" >/dev/null
V=$(spawn etk800 335); sleep 8
lua "local r=slrrDriverMount.getRagdoll($V) return 'C: ragdoll '..(r and (tableSize(r.nodes)..' nodes, '..r.belts..' belt anchors') or 'MISSING')"
lua "slrrDriverMount.startRagdollRec($V) return 1" >/dev/null
node bng.js run_lua_vehicle '{"code":"controller.mainController.setGearboxMode(\"arcade\") return 1"}' >/dev/null
inp parkingbrake 0; inp brake 0; inp throttle 0.35
for i in $(seq 1 20); do
  s=$(lua "return string.format('%.1f', vec3(be:getObjectByID($V):getVelocity()):length())")
  awk "BEGIN{exit !($s >= 4.2)}" && break; sleep 0.5
done
inp throttle 0; sleep 8
lua "return 'C: '..slrrDriverMount.stopRagdollRec($V, '/temp/slrr_ragdoll_crash15.json')..' frames'"
xray "$V" mount_C_after_crash.jpg

echo "== cleanup"
lua "be:getObjectByID($V):delete() be:getObjectByID($T):delete() slrrDriverMount.setFlags({props=false, ragdoll=false}) slrrDrivers.setPropConvention(1) return 'flags off'"
echo "recordings: $USER_TEMP/slrr_ragdoll_crash15.json; screenshots: $REVIEW/mount_*.jpg"
