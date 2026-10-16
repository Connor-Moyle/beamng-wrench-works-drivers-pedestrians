-- slrrWalkGen: sidewalks for maps that ship none (X34), made from BeamNG's road graph on first use and cached.
--
-- Loaded by slrrPedestrians only on a level without walk_<level>.json and only while pedestrians are on, so it
-- costs nothing elsewhere. Roads are chained through ordinary bends (graph nodes joining just two roads), so a
-- sidewalk ends only at a junction or a dead end: crossings then happen at junctions, never mid-block. Each chain
-- gets a line on both sides, half the road's width plus OFFSET out; a point is kept where there's solid ground a
-- pedestrian could stand on and no road within reach, checked a slice per frame. The result goes to
-- /settings/slrr_pedestrians/walk_<level>.json in the walk file format ({lines, room}); slrrPedestrians links
-- the ends by distance as for any bare walk file.

local M = {}

local OFFSET = 1.5          -- metres beyond the road's edge
local STEP = 3              -- metres between points along a road
local JUNCTION_GAP = 3      -- metres kept clear of a junction's mouth, beyond its radius
local MIN_DRIVABILITY = 0.9 -- below this a link is a track or offroad: no pavement
local MAX_SPEED = 25        -- m/s: faster roads (highways) get no pavement
local ROOM = 0.4            -- metres a pedestrian may stray either side (no pavement scan on stock maps)
local SLICE = 0.0004        -- seconds of work per frame
local MIN_LINE = 10         -- metres: shorter pieces are dropped

local job                   -- the generation in progress
local failed = {}           -- level -> true after an error in step: never tried again on that level (B46)

-- roads, each once: those worth a pavement, or (all = true) every road, to keep pavement off them
local function edges(nodes, all)
  local out = {}
  for a, n in pairs(nodes) do
    for b, l in pairs(n.links or {}) do
      if a < b and nodes[b] and (all or ((l.drivability or 1) >= MIN_DRIVABILITY and not l.hiddenInNavi
          and (l.speedLimit or 0) < MAX_SPEED)) then
        table.insert(out, {a = a, b = b})
      end
    end
  end
  return out
end

-- chains of edges joined through nodes of degree 2; each chain is a list of node names
local function chains(nodes, es)
  local adj, deg = {}, {}
  for i, e in ipairs(es) do
    for _, k in ipairs({e.a, e.b}) do
      adj[k] = adj[k] or {}
      table.insert(adj[k], i)
      deg[k] = (deg[k] or 0) + 1
    end
  end
  local used, out = {}, {}
  local function walk(start, ei)
    local chain, at = {start}, start
    while ei and not used[ei] do
      used[ei] = true
      local e = es[ei]
      at = e.a == at and e.b or e.a
      table.insert(chain, at)
      if deg[at] ~= 2 then break end
      local nxt
      for _, j in ipairs(adj[at]) do if not used[j] then nxt = j end end
      ei = nxt
    end
    return chain
  end
  for k, list in pairs(adj) do      -- chains start at junctions and dead ends
    if deg[k] ~= 2 then
      for _, ei in ipairs(list) do
        if not used[ei] then table.insert(out, walk(k, ei)) end
      end
    end
  end
  for i in ipairs(es) do            -- closed loops with no junction
    if not used[i] then table.insert(out, walk(es[i].a, i)) end
  end
  return out, deg
end

-- candidate points of the two sidewalks along a chain: {{pos = vec3}, ...} per side
local function sides(nodes, chain, deg)
  local out = {{}, {}}
  local total = #chain
  for i = 1, total - 1 do
    local na, nb = nodes[chain[i]], nodes[chain[i + 1]]
    local a, b = vec3(na.pos), vec3(nb.pos)
    local d = b - a
    local len = d:length()
    if len > 0.1 then
      d = d / len
      local n = vec3(d.y, -d.x, 0):normalized()
      -- keep clear of the junction mouths at the chain's ends
      local s0 = (i == 1 and (deg[chain[i]] or 0) >= 3) and (na.radius + JUNCTION_GAP) or 0
      local s1 = (i == total - 1 and (deg[chain[i + 1]] or 0) >= 3) and len - (nb.radius + JUNCTION_GAP) or len
      local s = s0
      while s <= s1 do
        local t = s / len
        local q = a + (b - a) * t
        local r = na.radius + (nb.radius - na.radius) * t
        table.insert(out[1], q + n * (r + OFFSET))
        table.insert(out[2], q - n * (r + OFFSET))
        s = s + STEP
      end
    end
  end
  return out
end

-- every road segment in a grid, to tell whether a point is on a road
local function roadGrid(nodes, es)
  local g = {}
  for _, e in ipairs(es) do
    local a, b = nodes[e.a], nodes[e.b]
    local x0, x1 = math.min(a.pos.x, b.pos.x), math.max(a.pos.x, b.pos.x)
    local y0, y1 = math.min(a.pos.y, b.pos.y), math.max(a.pos.y, b.pos.y)
    for cx = math.floor(x0 / 20) - 1, math.floor(x1 / 20) + 1 do
      for cy = math.floor(y0 / 20) - 1, math.floor(y1 / 20) + 1 do
        local k = cx .. ',' .. cy
        g[k] = g[k] or {}
        table.insert(g[k], e)
      end
    end
  end
  return g
end

local function onRoad(nodes, grid, p)
  for _, e in ipairs(grid[math.floor(p.x / 20) .. ',' .. math.floor(p.y / 20)] or {}) do
    local a, b = nodes[e.a], nodes[e.b]
    local ab = vec3(b.pos.x - a.pos.x, b.pos.y - a.pos.y, 0)
    local l2 = ab:dot(ab)
    local t = l2 > 0 and math.max(0, math.min(1, ((p.x - a.pos.x) * ab.x + (p.y - a.pos.y) * ab.y) / l2)) or 0
    local qx, qy = a.pos.x + ab.x * t, a.pos.y + ab.y * t
    local r = a.radius + (b.radius - a.radius) * t
    if (p.x - qx) ^ 2 + (p.y - qy) ^ 2 < (r + 0.3) ^ 2 and math.abs(p.z - (a.pos.z + (b.pos.z - a.pos.z) * t)) < 3 then
      return true
    end
  end
  return false
end

-- ground under p a pedestrian could stand on: a static surface within 2 m above to 4 m below, not steep
local function ground(p)
  local d = castRayStatic(p + vec3(0, 0, 2), vec3(0, 0, -1), 6)
  if not d or d >= 6 then return nil end
  return vec3(p.x, p.y, p.z + 2 - d)
end

-- start generating for a level: nodes as map.getMap().nodes; done(path) when written
local function start(level, nodes, done)
  if failed[level] then return false end
  local es = edges(nodes)
  local cs, deg = chains(nodes, es)
  job = {level = level, nodes = nodes, grid = roadGrid(nodes, edges(nodes, true)), chains = cs, deg = deg, ci = 1, side = 1,
         pts = nil, pi = 1, piece = {}, lines = {}, done = done}
  log('I', 'slrrWalkGen', string.format('%s: %d roads in %d chains, making sidewalks', level, #es, #cs))
  return true
end

local function flush()
  local p = job.piece
  local len = 0
  for i = 2, #p do len = len + p[i]:distance(p[i - 1]) end
  if len >= MIN_LINE then
    local l = {}
    for i, v in ipairs(p) do l[i] = {v.x, v.y, v.z} end
    table.insert(job.lines, l)
  end
  job.piece = {}
end

-- a slice of work: validate points until the time is up
local function step()
  local t0 = os.clock()
  while job and os.clock() - t0 < SLICE do
    if not job.pts then
      local c = job.chains[job.ci]
      if not c then                      -- all done: write and hand over
        local room = {}
        for i = 1, #job.lines do room[i] = {ROOM, ROOM} end
        local path = '/settings/slrr_pedestrians/walk_' .. job.level .. '.json'
        jsonWriteFile(path, {lines = job.lines, room = room}, false)
        log('I', 'slrrWalkGen', string.format('%s: %d sidewalks -> %s', job.level, #job.lines, path))
        local done = job.done
        job = nil
        if done then done(path) end
        return
      end
      job.pts = sides(job.nodes, c, job.deg)[job.side]
      job.pi = 1
    end
    local p = job.pts[job.pi]
    if p then
      local g = ground(p)
      if g and not onRoad(job.nodes, job.grid, g) then table.insert(job.piece, g) else flush() end
      job.pi = job.pi + 1
    else
      flush()
      job.pts = nil
      if job.side == 1 then job.side = 2 else job.side, job.ci = 1, job.ci + 1 end
    end
  end
end

M.start = start
-- an error in a slice logs once and ends the generation for this level: thrown every frame it flooded the
-- log until the game's control server died (B46)
M.onUpdate = function()
  if not job then return end
  local ok, err = pcall(step)
  if not ok then
    failed[job.level] = true
    log('E', 'slrrWalkGen', job.level .. ': sidewalk generation stopped: ' .. tostring(err))
    job = nil
  end
end
M.onClientEndMission = function() job = nil end   -- the road graph goes with the level: a stale job threw every frame (B46)
M.busy = function() return job ~= nil end
-- for tests
M._edges, M._chains, M._sides, M._step = edges, chains, sides, step

return M
