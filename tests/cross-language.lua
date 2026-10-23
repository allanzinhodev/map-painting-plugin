local root=app.params.root or 'C:/Users/Allan/Aseprite_tibia'
local M=dofile(root..'/extension/main.lua')
local R=M.render
local lines={}
local function note(s) print(s); lines[#lines+1]=s end
local function multiset(scene)
  local out={}; local n=0
  for _,tile in ipairs(scene.tiles) do for _,item in ipairs(tile.items) do
    local k=item.serverId..':'..item.clientId..':'..item.otbmHex
    out[k]=(out[k] or 0)+1; n=n+1
  end end
  return out,n
end
local function run()
  M.loadProject('C:/Users/Allan/backlands-workflow/client/data/things/860')
  local packet=M.scene.read(root..'/test-output/native-fixture-scene.json')
  local before,count=multiset(packet)
  local sprite=M.importScene(packet)
  local instance
  R.walk(sprite.layers,function(layer)
    local meta=R.metadata(layer)
    if not instance and meta and meta.role=='instance' then instance=layer end
  end)
  assert(instance)
  local meta=R.metadata(instance)
  local oldX=instance:cel(1).position.x
  local oldY=instance:cel(1).position.y
  -- Change actual pixels, synchronize the item sheet, and translate one map item.
  local sheet=M.openItem(meta.clientId)
  local cel=instance:cel(1)
  local image=Image(cel.image)
  image:putPixel(0,0,app.pixelColor.rgba(71,29,233,197))
  app.transaction(function() cel.image=image end)
  M.sync(true)
  local changed=M.codec.changeCount(M.project)
  assert(changed>0,'Occurrence pixels did not reach codec')
  cel=instance:cel(1)
  app.transaction(function() cel.position=Point(oldX+32,oldY) end)
  M.sync(true)
  local exported,path=M.saveScene(root..'/test-output/aseprite-roundtrip-scene.json',sprite)
  local after,afterCount=multiset(exported)
  assert(count==afterCount)
  for key,n in pairs(before) do assert(after[key]==n,'Native item attributes changed across Lua') end
  local newMeta=R.metadata(instance)
  assert(newMeta.anchorX==meta.anchorX+32,'Movement did not persist')
  sprite:saveAs(root..'/test-output/native-scene-edited.aseprite')
  Image(sprite):saveAs(root..'/test-output/native-scene-edited.png')
  note('PASS: native fixture -> Aseprite scene -> pixel edit -> linked item sheet -> 32px movement -> native packet')
  note(count..' item nodes retain exact Server IDs, Client IDs and opaque OTBM attributes; '..changed..' sprite slots changed.')
  note('Returned packet: '..path)
end
local ok,err=xpcall(run,debug.traceback)
if not ok then note('FAIL: '..err) end
local f=assert(io.open(root..'/tests/cross-language-result.txt','wb')); f:write(table.concat(lines,'\n')..'\n'); f:close()
assert(ok,err)
