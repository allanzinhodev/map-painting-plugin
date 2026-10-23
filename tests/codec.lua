-- Run: Aseprite.exe --batch --script-param root=<workspace> --script tests/codec.lua
local root = (app and app.params.root) or "C:/Users/Allan/Aseprite_tibia"
local source = (app and app.params.source) or "C:/Users/Allan/backlands-workflow/client/data/things/860"
local report = root .. "/tests/codec-result.txt"
local lines = {}
local function note(s) lines[#lines + 1] = s; print(s) end
local function run()
  local T = dofile(root .. "/extension/lib/tibia.lua")
  local p = T.load(source)
  note(string.format("Loaded DAT: %d items, %d outfits, %d effects, %d missiles; SPR: %d", p.itemCount, p.counts.outfits, p.counts.effects, p.counts.missiles, p.spriteCount))
  assert(p.flags.extended and p.flags.transparency and p.flags.improvedAnimations and p.flags.frameGroups)
  local dat, spr, added = T.build(p)
  assert(dat == p.datBytes and spr == p.sprBytes and added == 0)
  note("Unchanged DAT/SPR byte-for-byte identical")
  local nonempty = 0
  for id = 0, p.spriteCount do
    local bytes = T.decodeSprite(p, id)
    assert(#bytes == 4096)
    if bytes ~= string.rep("\0", 4096) then nonempty = nonempty + 1 end
  end
  note("Every SPR entry decoded and RLE bounds verified; nonempty=" .. nonempty)
  local referenced, shared
  local bySprite = {}
  for id = 100, p.counts.items do
    for gi, g in ipairs(p.items[id].groups) do
      local seen = {}
      for frame = 0, g.frames - 1 do for pz = 0, g.patternZ - 1 do for py = 0, g.patternY - 1 do for px = 0, g.patternX - 1 do
        for layer = 0, g.layers - 1 do for y = 0, g.height - 1 do for x = 0, g.width - 1 do
          local slot = T.spriteSlot(g,x,y,layer,px,py,pz,frame)
          assert(not seen[slot]); seen[slot] = true
        end end end
      end end end end
      for slot, sid in ipairs(g.spriteIds) do
        assert(seen[slot])
        if sid > 0 then
          local ref = {id=id, group=gi, slot=slot, sid=sid}
          if bySprite[sid] and bySprite[sid].id ~= id and not shared then referenced=bySprite[sid]; shared=ref end
          bySprite[sid] = bySprite[sid] or ref
        end
      end
    end
  end
  assert(referenced and shared, "Expected a shared sprite in actual assets")
  local original = T.decodeSprite(p, referenced.sid)
  local changed = string.char(239, 17, 97, 123) .. original:sub(5)
  T.setItemSprite(p, referenced.id, referenced.group+0.0, referenced.slot+0.0, changed)
  -- Aseprite JSON metadata produces floats for integral group/slot values.
  assert(T.getItemSprite(p, referenced.id, referenced.group, referenced.slot)==changed)
  T.setItemSprite(p, referenced.id, referenced.group, referenced.slot, changed)
  assert(T.changeCount(p) == 1)
  assert(T.getItemSprite(p, referenced.id, referenced.group, referenced.slot) == changed)
  assert(T.getItemSprite(p, shared.id, shared.group, shared.slot) == original)
  local output = root .. "/tests/output-codec"
  if app then app.fs.makeAllDirectories(output) end
  local result = T.export(p, output)
  local reread = T.load(output)
  assert(reread.spriteCount == p.spriteCount + 1)
  assert(T.getItemSprite(reread,referenced.id,referenced.group,referenced.slot) == changed)
  assert(T.getItemSprite(reread,shared.id,shared.group,shared.slot) == original)
  for _, category in ipairs({"items", "outfits", "effects", "missiles"}) do
    for id, item in pairs(p.categories[category]) do
      local other = reread.categories[category][id]
      assert(item.rawAttributes == other.rawAttributes)
      for gi, g in ipairs(item.groups) do
        local og = other.groups[gi]
        assert(g.frames == og.frames and g.width == og.width and g.height == og.height)
        for f, duration in ipairs(g.durations) do assert(duration.minimum == og.durations[f].minimum and duration.maximum == og.durations[f].maximum) end
        for slot, sid in ipairs(g.spriteIds) do
          if category == "items" and id == referenced.id and gi == referenced.group and slot == referenced.slot then
            assert(og.spriteIds[slot] == p.spriteCount + 1)
          else assert(sid == og.spriteIds[slot]) end
        end
      end
    end
  end
  note(string.format("Partial alpha roundtrip; shared ID isolated: #%d changed, #%d preserved; all other IDs and metadata unchanged", referenced.id, shared.id))
  assert(not pcall(function() T.export(p, source) end))
  assert(not pcall(function() T.export(p, source .. "/sub/..") end))
  assert(not pcall(function() T.spriteSlot(p.items[100].groups[1], -1,0,0,0,0,0,0) end))
  assert(not pcall(function() T.setItemSprite(p, referenced.id, referenced.group, referenced.slot, "bad") end))
  T.setItemSprite(p, referenced.id, referenced.group, referenced.slot, original)
  assert(T.changeCount(p) == 0)
  dat, spr = T.build(p); assert(dat == p.datBytes and spr == p.sprBytes)
  note("Invalid writes rejected; reverting edit restores exact original bytes")
  note("PASS")
end
local ok, err = xpcall(run, debug.traceback)
if not ok then note("FAIL: " .. tostring(err)) end
local f = assert(io.open(report, "w")); f:write(table.concat(lines,"\n"),"\n"); f:close()
if not ok then error(err) end
