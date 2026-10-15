#!/usr/bin/env bash
# One QA round for the driver (QA_MASTER.md J1-J6): records in game, checks every recording, and
# prints PASS / FAIL per gate. Needs BeamNG running with -enablemcp and Valo City loaded.
#   bash tools/qa_round.sh
cd "$(dirname "$0")"
LOG=$(mktemp)
USER_TEMP="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/temp"
lua() { node bng.js run_lua "$1"; }

echo "== recording (turn_record.sh)"
bash turn_record.sh | tee "$LOG"

echo "== J3 / J4: camera and display modes"
lua "local q=quatFromDir(vec3(0,-1,0), vec3(0,0,1)) local v=core_vehicles.spawnNewVehicle('etk800', {pos=vec3(2336.88,330,6.6), rot=q, autoEnterVehicle=true, cling=true}) M_qa=v:getId() return M_qa" >/dev/null
sleep 6
J34=$(lua "
local vid, out = M_qa, {}
local function hidden() local c = slrrDrivers.getState(vid) local n = 0 for _, o in pairs(c.parts) do if o:isHidden() then n = n + 1 end end return n, c.parts.head:isHidden() end
commands.setGameCamera() core_camera.setByName(0, 'driver')
return 'pending'" )
sleep 2
J34=$(lua "
local vid = M_qa
local c = slrrDrivers.getState(vid)
local function count() local n = 0 for _, o in pairs(c.parts) do if o:isHidden() then n = n + 1 end end return n end
local res = {}
-- J3: in the driver camera the camera sits inside the head: the head is drawn (for the mirrors) and nothing else hidden
local v = be:getObjectByID(vid)
local eye = v:getPosition() + vec3(v:getNodePositionXYZ(c.camNode))
res[#res + 1] = string.format('J3 %s: camera %.3f m from the eye, head hidden %s, parts hidden %d', (core_camera.getPosition():distance(eye) < 0.1 and not c.parts.head:isHidden() and count() == 0) and 'PASS' or 'FAIL', core_camera.getPosition():distance(eye), tostring(c.parts.head:isHidden()), count())
return table.concat(res, '\n')")
echo "$J34"
for mode in full still hideFirstPerson hidden full; do
  lua "slrrDrivers.setDisplayMode('$mode') return 1" >/dev/null; sleep 1
  lua "local c=slrrDrivers.getState(M_qa) local n=0 for _, o in pairs(c.parts) do if o:isHidden() then n=n+1 end end local want = ('$mode'=='hidden' or '$mode'=='hideFirstPerson') and 14 or 0 return string.format('J4 %s: $mode in the driver camera hides %d of 14 parts', n == want and 'PASS' or 'FAIL', n)"
done | tee -a "$LOG"
lua "core_camera.setByName(0,'orbit') be:getObjectByID(M_qa):delete() return 1" >/dev/null

echo "== J1 / J2 / J6: recordings"
python check_recording.py "$USER_TEMP"/slrr_rec_*.json | tee -a "$LOG"

echo "== summary"
python - "$LOG" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
recs = re.findall(r"^(slrr_rec_\S+\.json): (PASS|MED|HIGH)", t, re.M)
j1 = "FAIL" if any(v == "HIGH" for _, v in recs) else ("PASS" if recs else "NO DATA")
j2 = "FAIL" if "J2 body" in t else ("PASS" if recs else "NO DATA")
j3 = "PASS" if "J3 PASS" in t else "FAIL"
j4 = "PASS" if t.count("J4 PASS") == 5 else "FAIL"
lay = re.findall(r"^(\w+): seat ", t, re.M)
j5 = "PASS" if len(lay) >= 10 and "NO DRIVER" not in t else "FAIL (%d layouts)" % len(lay)
m = re.search(r"J6: (\d+) drivers cost ([\d.]+) ms", t)
j6 = ("PASS" if float(m.group(2)) <= 1.0 else "FAIL") + " (%s drivers, %s ms)" % m.groups() if m else "NO DATA"
meds = sum(v == "MED" for _, v in recs)
for k, v in (("J1", j1), ("J2", j2), ("J3", j3 + " (mirrors: check by eye)"), ("J4", j4), ("J5", j5 + " (poses: review the j5 renders)"), ("J6", j6)):
    print(k, v)
print("recordings: %d, MED: %d" % (len(recs), meds))
PY
