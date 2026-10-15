// Pedestrian game turn (T1), run against the game's MCP server with Valo City loaded:
//   node tools/t1_peds.js [outDir]
// 1. frame time with 0 / 30 / 60 pedestrians (auto-reduce off), 2. the traffic-signal state names seen,
// 3. a screenshot over a sidewalk in 5 districts (K1), 4. a 40 s recording at junction_0 with traffic
// (walk/idle swaps, crossings, cars) for tools/t1_report.py. Restores the pedestrian options afterwards.
const fs = require('fs'), path = require('path');
const OUT = process.argv[2] || 'C:/Dev/SLRR BeamNG Graph/review/t1';
const WALK = path.join(__dirname, '..', 'mod', 'art', 'slrr_pedestrians', 'walk_slrr_valo_city.json');
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function call(name, args) {
  for (const port of [29292, 29293, 29294]) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/mcp`, {method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'tools/call', params: {name, arguments: args}})});
      const j = await r.json();
      const c = j.result ? j.result.content[0] : {text: JSON.stringify(j.error)};
      return c;
    } catch (e) { if (port === 29294) throw e; }
  }
}
const lua = async code => (await call('run_lua', {code})).text;
const shot = async file => {
  const c = await call('screenshot_image', {});
  if (c.type === 'image') fs.writeFileSync(file, Buffer.from(c.data, 'base64'));
  else console.log('screenshot failed:', c.text);
};
const look = (p, from) => lua(`commands.setFreeCamera() core_camera.setPosition(0, vec3(${from})) ` +
  `core_camera.setRotation(0, quatFromDir((vec3(${p}) - vec3(${from})):normalized(), vec3(0,0,1)))`);

// a sidewalk point near the middle of each district box (density_slrr_valo_city.json)
const DISTRICTS = {downtown: [-600, 150, 600, 800], beachfront: [-650, 800, 600, 1100], 'south end': [-1350, -1470, 1300, -100],
                   'industrial east': [700, -700, 1300, 0], island: [-550, 1330, 270, 1900]};
function districtPoints() {
  const walk = JSON.parse(fs.readFileSync(WALK, 'utf8'));
  const lines = walk.lines || walk, out = {};
  for (const [name, b] of Object.entries(DISTRICTS)) {
    const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
    let best = null, bd = Infinity;
    for (const l of lines) for (const p of l) {
      if (p[0] < b[0] || p[0] > b[2] || p[1] < b[1] || p[1] > b[3]) continue;
      const d = Math.hypot(p[0] - cx, p[1] - cy);
      if (d < bd) { bd = d; best = p; }
    }
    out[name] = best;
  }
  return out;
}

(async () => {
  fs.mkdirSync(OUT, {recursive: true});
  const report = {};
  console.log('level:', await lua('return getCurrentLevelIdentifier()'));
  const saved = await lua('return jsonEncode(slrrPedestrians.getOptions()) .. "|" .. slrrPedestrians.getCount()');
  console.log('options before:', saved);
  await lua('slrrPedestrians.setOptions({autoReduce = false, maxCount = 200, amount = "medium"})');

  // 1. frame time at junction_0, standing still
  await look('-340,210,7', '-310,180,22');
  report.frameMs = {};
  for (const n of [0, 30, 60]) {
    await lua(`slrrPedestrians.setCount(${n})`);
    await sleep(15000);
    report.frameMs[n] = Number(await lua('return slrrPedestrians.getState().frameMs'));
    console.log(`${n} pedestrians: ${report.frameMs[n].toFixed(2)} ms`);
  }

  // 2. signal state names over 40 s
  const names = new Set();
  for (let i = 0; i < 20; i++) {
    const t = await lua('local s = {} for _, i in ipairs(core_trafficSignals.getSignals()) do s[#s+1] = (i:getState()) end ' +
                        'return table.concat(s, ",")');
    t.split(',').forEach(x => names.add(x));
    await sleep(2000);
  }
  report.signalStates = [...names];
  console.log('signal states seen:', report.signalStates.join(' '));

  // 3. one screenshot per district, 30 pedestrians
  await lua('slrrPedestrians.setCount(30)');
  for (const [name, p] of Object.entries(districtPoints())) {
    if (!p) { console.log('no sidewalk in', name); continue; }
    await look(p.join(','), `${p[0] + 10},${p[1] - 10},${p[2] + 8}`);
    await sleep(8000);
    const file = path.join(OUT, `k1_${name.replace(/ /g, '_')}.jpg`);
    await shot(file);
    console.log('screenshot', file);
  }

  // 4. junction_0 with traffic, recorded 40 s
  await look('-340,210,7', '-310,180,22');
  await lua('if gameplay_traffic then gameplay_traffic.setupTraffic(10) end');
  await sleep(10000);
  await lua('slrrPedestrians.record(40, "/temp/slrr_peds_t1.json")');
  await sleep(45000);
  report.recording = '%LOCALAPPDATA%/BeamNG/BeamNG.drive/current/temp/slrr_peds_t1.json';

  await lua('slrrPedestrians.setOptions({autoReduce = true, maxCount = 60}) slrrPedestrians.setCount(30)');
  console.log('options after:', await lua('return jsonEncode(slrrPedestrians.getOptions())'));
  fs.writeFileSync(path.join(OUT, 't1.json'), JSON.stringify(report, null, 1));
  console.log('done ->', OUT, '; then: python tools/t1_report.py');
})();
