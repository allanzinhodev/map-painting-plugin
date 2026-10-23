-- Aseprite batch integration test; root and source are optional --script-param values.
local root = app.params.root or "C:/Users/Allan/Aseprite_tibia"
local source = app.params.source or "C:/Users/Allan/backlands-workflow/client/data/things/860"
local lines = {}
local function note(s) print(s); lines[#lines+1]=s end
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
local function run()
  local R,T,real,schema=dofile(root.."/tests/lib/models.lua")(root,source,note)
  local M=dofile(root.."/extension/main.lua")
  assert(type(M)=="table","main.lua must return its testable module")
  M.loadProject(source)
  assert(M.project and M.project.items[100],"Project not loaded")
  local sheet=M.openItem(110)
  assert(sheet,"openItem did not return sprite")
  local sceneA=M.importScene(schema)
  local sceneB=M.importScene(schema)
  local function findLayer(sprite,role,id)
    local found
    R.walk(sprite.layers,function(layer)
      local m=R.metadata(layer)
      if m and m.role==role and m.clientId==id and not found then found=layer end
    end)
    return assert(found,"Missing "..role.." layer #"..id)
  end
  local sheetLayer=findLayer(sheet,"sheet",110)
  R.walk(sheet.layers,function(layer)
    local m=R.metadata(layer)
    if m and m.role=="sheet" and m.sourceLayer>R.metadata(sheetLayer).sourceLayer then sheetLayer=layer end
  end)
  local selectedSourceLayer=R.metadata(sheetLayer).sourceLayer
  local layerA=findLayer(sceneA,"instance",110)
  local layerB=findLayer(sceneB,"instance",110)
  local untouchedLayer=findLayer(sceneA,"instance",111)
  local untouchedBytes=untouchedLayer:cel(1).image.bytes
  local uuids={}
  for _,sprite in ipairs({sheet,sceneA,sceneB}) do R.walk(sprite.layers,function(layer)
    assert(layer.uuid,"Missing layer UUID")
    local key=sprite.id..":"..tostring(layer.uuid)
    assert(not uuids[key],"Duplicate layer UUID key"); uuids[key]=true
  end) end
  assert(not M.sync(true),"Unedited documents should not modify resources")
  local editedSheet=Image(sheetLayer:cel(1).image)
  editedSheet:putPixel(13,14,app.pixelColor.rgba(217,43,71,255))
  app.transaction("Test sheet edit",function() sheetLayer:cel(1).image=editedSheet end)
  assert(M.dirty[sheet.id],"Aseprite change event did not schedule automatic synchronization")
  assert(M.sync(false),"Sheet edit not detected")
  assert(M.render.render(M.project,110):getPixel(13,14)==app.pixelColor.rgba(217,43,71,255),"Visual sheet edit was not stored in the item")
  for _,layer in ipairs({layerA,layerB}) do
    local m=R.metadata(layer)
    equalImage(R.capture(layer:cel(1),m.width,m.height,m.anchorX,m.anchorY),M.render.render(M.project,110,m.variant),"Sheet edit did not propagate to scene")
  end
  assert(untouchedLayer:cel(1).image.bytes==untouchedBytes,"Shared sprite edit propagated into different client ID")
  assert(not M.sync(true),"Synchronization feedback loop")
  note("Sheet edits propagate across documents, preserving other IDs; layer UUID keys are unique")

  local ca,cb=Image(layerA:cel(1).image),Image(layerB:cel(1).image)
  local colorA,colorB=app.pixelColor.rgba(2,93,147,255),app.pixelColor.rgba(239,83,191,255)
  ca:putPixel(1,2,colorA); cb:putPixel(3,4,colorB)
  app.transaction("Test simultaneous occurrence edits",function()
    layerA:cel(1).image=ca; layerB:cel(1).image=cb
  end)
  assert(M.sync(false),"Simultaneous occurrence edits were not detected")
  local combined=M.render.render(M.project,110)
  assert(combined:getPixel(1,2)==colorA and combined:getPixel(3,4)==colorB,"Independent simultaneous edits to one ID overwrote each other")
  note("Aseprite events schedule automatic sync and simultaneous independent occurrence edits are merged")

  -- A cropped cel simulates Aseprite's brush/eraser trimming. Its logical origin
  -- must remain anchored while its bitmap gets smaller and changes position.
  local am=R.metadata(layerA)
  local crop=Image(8,9,ColorMode.RGB)
  crop:putPixel(2,3,app.pixelColor.rgba(17,199,101,161))
  app.transaction("Test cropped occurrence edit",function()
    layerA:cel(1).image=crop
    layerA:cel(1).position=Point(am.anchorX+5,am.anchorY+6)
  end)
  assert(M.sync(false),"Cropped occurrence edit not detected")
  local expected=Image(am.width,am.height,ColorMode.RGB)
  expected:drawImage(crop,Point(5,6))
  equalImage(M.render.render(M.project,110,am.variant),expected,"Cropped edit moved logical origin or lost pixels")
  local bm=R.metadata(layerB)
  equalImage(R.capture(layerB:cel(1),bm.width,bm.height,bm.anchorX,bm.anchorY),expected,"Occurrence edit not propagated to other scene")
  equalImage(R.capture(sheetLayer:cel(1),sheet.width,sheet.height,0,0),M.render.sheetLayer(M.project,110,M.render.layout(M.project.items[110]),selectedSourceLayer),"Occurrence edit not propagated to spritesheet")
  assert(R.metadata(layerA).anchorX==am.anchorX and R.metadata(layerA).anchorY==am.anchorY,"Cropping changed item anchor")
  note("Cropped occurrence edits propagate to sheet and second scene without changing anchors")

  local manual=Sprite(am.width,am.height,ColorMode.RGB)
  local manualLayer=manual.layers[1]
  manualLayer.name="#110 teste"
  manual:newCel(manualLayer,1,expected,Point(0,0))
  M.scan(); M.sync(true)
  assert(R.metadata(manualLayer).clientId==110,"Regular #ID layer was not bound")
  equalImage(M.render.render(M.project,110,am.variant),expected,"Manual binding changed prior edit")
  note("Regular #ID layer naming binds to the correct item")

  local persistent=root.."/tests/output-integration/linked-sheet.aseprite"
  local uuid=tostring(sheetLayer.uuid)
  sheet:saveAs(persistent); sheet:close(); M.scan()
  sheet=assert(app.open(persistent)); M.scan()
  R.walk(sheet.layers,function(layer)
    local m=R.metadata(layer)
    if m and m.role=="sheet" and m.sourceLayer==selectedSourceLayer then sheetLayer=layer end
  end)
  equalImage(R.capture(sheetLayer:cel(1),sheet.width,sheet.height,0,0),M.render.sheetLayer(M.project,110,M.render.layout(M.project.items[110]),selectedSourceLayer),"Saved sheet pixels changed on reopening")
  assert(tostring(sheetLayer.uuid)==uuid,"Layer UUID did not persist")
  assert(R.metadata(sheetLayer).assetsDirectory==source,"Project binding did not persist")
  -- A fresh resource load must recover the saved edited sheet as pending edits.
  -- Close other documents so the deliberately fresh project has one authority.
  sceneA:close(); sceneB:close(); manual:close(); M.scan()
  M.loadProject(source)
  assert(M.sync(true),"Saved edited sheet was not recovered after reload")
  equalImage(M.render.render(M.project,110,am.variant),expected,"Reopened sheet lost item edits")
  note("Saved .aseprite layer UUIDs, source metadata, and edited pixels recover after resource reload")
  sheet:close(); M.scan()
  note("PASS")
end
local ok,err=xpcall(run,debug.traceback)
if not ok then note("FAIL: "..tostring(err)) end
local f=assert(io.open(root.."/tests/integration-result.txt","w")); f:write(table.concat(lines,"\n"),"\n");f:close()
if not ok then error(err) end
