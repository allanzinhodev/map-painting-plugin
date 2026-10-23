-- Rendering and editable-scene model tests shared by the standalone and full suites.
local function equalImage(a,b,message)
  if a.width~=b.width or a.height~=b.height or a.bytes~=b.bytes then
    local diff=" dimensions "..a.width.."x"..a.height.." vs "..b.width.."x"..b.height
    if a.width==b.width and a.height==b.height then
      local aa,bb=a.bytes,b.bytes
      for i=1,#aa do if aa:byte(i)~=bb:byte(i) then
        diff=" first byte mismatch "..i.." actual="..aa:byte(i).." expected="..bb:byte(i).." (pixel "..((i-1)//4%a.width)..","..((i-1)//4//a.width)..")";break
      end end
    end
    error((message or "Images differ")..diff)
  end
end
return function(root,source,note)

  local R=dofile(root.."/extension/lib/render.lua")
  local T=R.codec
  local function fixture(width,height,layers)
    local g={width=width,height=height,layers=layers,patternX=1,patternY=1,patternZ=1,frames=1,
      spriteIds={},spritePositions={},durations={{minimum=100,maximum=100}}}
    local item={id=100,category="items",groups={g},offsetX=0,offsetY=0,elevation=0}
    local p={items={[100]=item},categories={},flags={transparency=true,extended=true},changes={},revision=0,cache={},spriteAddresses={},sprBytes=""}
    p.categories.items=p.items
    p.spriteCount=width*height*layers
    for id=1,p.spriteCount do
      g.spriteIds[id]=id; g.spritePositions[id]=id*4
      p.cache[id]=string.rep(string.char(id*10,20,30,255),1024)
    end
    return p,item,g
  end
  local p,item,g=fixture(2,2,1)
  local image=R.render(p,100)
  assert(app.pixelColor.rgbaR(image:getPixel(0,0))==40)
  assert(app.pixelColor.rgbaR(image:getPixel(32,0))==30)
  assert(app.pixelColor.rgbaR(image:getPixel(0,32))==20)
  assert(app.pixelColor.rgbaR(image:getPixel(32,32))==10)
  local layout=R.layout(item)
  equalImage(R.sheetLayer(p,100,layout,0),image,"Sheet tile orientation differs from scene")
  image:putPixel(41,45,app.pixelColor.rgba(211,37,51,173))
  assert(R.applySheetLayer(p,100,layout,0,image))
  equalImage(R.render(p,100),image,"Sheet edits do not roundtrip in a multi-tile item")
  note("Multi-tile orientation and sheet editing roundtrip verified")
  p,item,g=fixture(1,1,2)
  p.cache[1]=string.rep(string.char(30,50,70,255),1024)
  p.cache[2]=string.rep(string.char(128,150,170,99),1024)
  local edited=R.render(p,100)
  edited:putPixel(12,13,app.pixelColor.rgba(221,77,44,99))
  assert(R.applyVariant(p,100,nil,edited))
  equalImage(R.render(p,100),edited,"Partial alpha on composite must match user edit")
  assert(T.getItemSprite(p,100,1,1):sub(1,4)==string.char(30,50,70,255),"Untouched pixel changed")
  edited:putPixel(12,13,0)
  assert(R.applyVariant(p,100,nil,edited))
  equalImage(R.render(p,100),edited,"Erasing must remove underlying composite pixels")
  note("Layered composite partial alpha, erasing, and untouched pixels verified")

  local Scene=dofile(root.."/extension/lib/scene.lua")
  local real=T.load(source)
  local schema={format="tibia-aseprite-scene",version=1,tileSize=32,origin={x=500,y=600,z=7},
    tiles={{x=500,y=600,z=7,flags=3,houseId=42,zones={11,19},items={
      {clientId=110,serverId=1010,count=3,otbmHex="fe066e00ff"},
      {clientId=111,serverId=1011,count=1,otbmHex="fe066f00ff"}}}}}
  app.fs.makeAllDirectories(root.."/tests/output-integration")
  local exchangePath=root.."/tests/output-integration/scene.json"
  Scene.write(schema,exchangePath)
  local sceneSprite=Scene.import(real,Scene.read(exchangePath))
  local exported=Scene.export(sceneSprite)
  assert(#exported.tiles==1 and #exported.tiles[1].items==2)
  assert(exported.tiles[1].flags==3 and exported.tiles[1].houseId==42 and exported.tiles[1].zones[2]==19)
  assert(exported.tiles[1].items[1].serverId==1010 and exported.tiles[1].items[2].serverId==1011)
  assert(exported.tiles[1].items[1].otbmHex=="fe066e00ff")
  local scenePath=root.."/tests/output-integration/persistent-scene.aseprite"
  sceneSprite:saveAs(scenePath)
  sceneSprite:close()
  sceneSprite=assert(app.open(scenePath))
  exported=Scene.export(sceneSprite)
  assert(exported.tiles[1].houseId==42 and exported.tiles[1].items[2].otbmHex=="fe066f00ff")
  local firstLayer
  R.walk(sceneSprite.layers,function(layer)
    local m=R.metadata(layer)
    if m and m.role=="instance" and m.clientId==110 then firstLayer=layer end
  end)
  assert(firstLayer,"Layer metadata lost after .aseprite reload")
  local cel=firstLayer:cel(1)
  cel.position=Point(cel.position.x+32,cel.position.y)
  exported=Scene.export(sceneSprite)
  local moved
  for _,tile in ipairs(exported.tiles) do for _,entry in ipairs(tile.items) do
    if entry.clientId==110 then moved=tile; assert(entry.serverId==1010 and entry.otbmHex=="fe066e00ff") end
  end end
  assert(moved and moved.x==501 and moved.y==600 and moved.z==7,"Moved item not exported to adjacent tile")
  sceneSprite:close()
  note("Scene IDs, stacking, tile attributes, OTBM nodes, movement, and .aseprite metadata persistence verified")

  return R,T,real,schema
end
