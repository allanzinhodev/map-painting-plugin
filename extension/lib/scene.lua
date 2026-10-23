local here = app.fs.filePath(debug.getinfo(1,'S').source:sub(2))
local R = dofile(app.fs.joinPath(here,'render.lua'))
local Scene = {}

local function copy(value) return R.plain(json.decode(json.encode(value))) end
local function integer(value) return type(value)=='number' and value%1==0 end
local function key(x,y,z) return x..':'..y..':'..z end

function Scene.read(path)
  local f,err=io.open(path,'rb')
  assert(f,'Cena não encontrada. Copie uma seleção no NexaMap integrado primeiro.\n'..tostring(err))
  local bytes=f:read('a'); f:close()
  assert(#bytes <= 64*1024*1024,'Cena maior que 64 MB')
  local scene=R.plain(json.decode(bytes))
  Scene.validate(scene)
  return scene
end

function Scene.validate(scene)
  assert(type(scene)=='table' and scene.format=='tibia-aseprite-scene' and scene.version==1,'Formato de cena incompatível')
  assert(scene.tileSize==32,'A cena precisa usar sprites de 32 pixels')
  assert(type(scene.origin)=='table' and integer(scene.origin.x) and integer(scene.origin.y) and integer(scene.origin.z),'Origem da cena inválida')
  assert(type(scene.tiles)=='table' and #scene.tiles>0 and #scene.tiles<=20000,'Selecione de 1 a 20000 tiles')
  local count=0
  for _,tile in ipairs(scene.tiles) do
    assert(integer(tile.x) and integer(tile.y) and integer(tile.z) and tile.x>=0 and tile.x<=65535 and tile.y>=0 and tile.y<=65535 and tile.z>=0 and tile.z<=15,'Coordenadas de tile inválidas')
    assert(type(tile.items)=='table','Itens do tile ausentes')
    for _,item in ipairs(tile.items) do
      assert(integer(item.clientId) and integer(item.serverId),'IDs inválidos na cena')
      assert(type(item.otbmHex)=='string' and #item.otbmHex%2==0 and not item.otbmHex:find('[^%x]'),'Dados OTBM inválidos')
      count=count+1
    end
  end
  assert(count<=40000,'Seleção maior que 40000 itens; copie uma área menor')
end

function Scene.variant(project,item,tile)
  if item.variant then return R.variant(project.items[item.clientId],item.variant) end
  if item.visual then
    local v=item.visual
    local group=(v.group or 0)+1
    local g=project.items[item.clientId].groups[group]
    local flatSlot
    if g.width==1 and g.height==1 and v.subtype and v.subtype>=0 then flatSlot=v.subtype%#g.spriteIds+1 end
    return R.variant(project.items[item.clientId],{group=group,
      patternX=v.patternX,patternY=v.patternY,patternZ=v.patternZ,frame=v.frame,flatSlot=flatSlot})
  end
  local def=project.items[item.clientId]
  local g=def.groups[1]
  local px,py,pz=tile.x%g.patternX,tile.y%g.patternY,tile.z%g.patternZ
  if def.stackable and g.patternX==4 and g.patternY==2 then
    local n=tonumber(item.count) or 1
    local pattern=n<=1 and 0 or n<=2 and 1 or n<=3 and 2 or n<=4 and 3 or n<=9 and 4 or n<=24 and 5 or n<=49 and 6 or 7
    px,py=pattern%4,pattern//4
  end
  return {group=1,patternX=px,patternY=py,patternZ=pz,frame=0}
end

function Scene.import(project,scene)
  Scene.validate(scene)
  local tiles=copy(scene.tiles)
  table.sort(tiles,function(a,b)
    if a.z~=b.z then return a.z>b.z end
    if a.y~=b.y then return a.y<b.y end
    return a.x<b.x
  end)
  local entries,minX,minY,maxX,maxY={},math.huge,math.huge,-math.huge,-math.huge
  for _,tile in ipairs(tiles) do
    local elevation=0
    for stack,item in ipairs(tile.items) do
      local def=assert(project.items[item.clientId],'Client ID #'..item.clientId..' não existe nos recursos carregados')
      local variant=Scene.variant(project,item,tile)
      local image=R.render(project,item.clientId,variant)
      local floor=scene.origin.z-tile.z
      local visual=item.visual or {}
      local drawHeight=elevation
      local x=(tile.x-scene.origin.x+floor)*32+32-image.width-(visual.offsetX or def.offsetX or 0)-drawHeight
      local y=(tile.y-scene.origin.y+floor)*32+32-image.height-(visual.offsetY or def.offsetY or 0)-drawHeight
      entries[#entries+1]={item=item,tile=tile,stack=stack,image=image,variant=variant,x=x,y=y}
      minX=math.min(minX,x); minY=math.min(minY,y)
      maxX=math.max(maxX,x+image.width); maxY=math.max(maxY,y+image.height)
      elevation=math.min(24,elevation+(visual.drawHeight or def.elevation or 0))
    end
    local floor=scene.origin.z-tile.z
    minX=math.min(minX,(tile.x-scene.origin.x+floor)*32)
    minY=math.min(minY,(tile.y-scene.origin.y+floor)*32)
    maxX=math.max(maxX,(tile.x-scene.origin.x+floor+1)*32)
    maxY=math.max(maxY,(tile.y-scene.origin.y+floor+1)*32)
  end
  assert(maxX-minX<=16384 and maxY-minY<=16384,'Cena maior que 16384 pixels; copie uma área menor')
  local sprite=Sprite(math.max(32,maxX-minX),math.max(32,maxY-minY),ColorMode.RGB)
  sprite.filename='Cena NexaMap.aseprite'
  sprite.gridBounds=Rectangle(-minX%32,-minY%32,32,32)
  app.transaction('Importar cena NexaMap',function()
    local empty=sprite.layers[1]
    local floorGroups={}
    for _,entry in ipairs(entries) do
      local tile,item=entry.tile,entry.item
      local group=floorGroups[tile.z]
      if not group then group=sprite:newGroup(); group.name='Andar '..tile.z; floorGroups[tile.z]=group end
      local layer=sprite:newLayer(); layer.parent=group
      layer.name='#'..item.clientId..' · '..tile.x..','..tile.y..','..tile.z..' · '..entry.stack
      local anchorX,anchorY=entry.x-minX,entry.y-minY
      R.setMetadata(layer,{role='instance',clientId=item.clientId,assetsDirectory=project.directory,
        variant=entry.variant,item=item,tileX=tile.x,tileY=tile.y,tileZ=tile.z,
        stack=entry.stack,baseX=anchorX,baseY=anchorY,anchorX=anchorX,anchorY=anchorY,
        width=entry.image.width,height=entry.image.height})
      sprite:newCel(layer,1,entry.image,Point(anchorX,anchorY))
    end
    sprite:deleteLayer(empty)
    local source=copy(scene)
    -- Item nodes live with their layers. Tile attributes remain on the scene.
    for _,tile in ipairs(source.tiles) do tile.items={} end
    R.setMetadata(sprite,{role='scene',assetsDirectory=project.directory,source=source,paddingX=-minX,paddingY=-minY})
  end)
  return sprite
end

function Scene.export(sprite)
  local sm=R.metadata(sprite)
  assert(sm and sm.role=='scene','O documento ativo não é uma cena NexaMap')
  local scene=copy(sm.source)
  local tileIndex={}
  for _,tile in ipairs(scene.tiles) do tile.items={}; tileIndex[key(tile.x,tile.y,tile.z)]=tile end
  R.walk(sprite.layers,function(layer)
    local m=R.metadata(layer)
    if not m or m.role~='instance' then return end
    local cel=layer:cel(1)
    if not cel then return end
    local ax,ay=m.anchorX,m.anchorY
    -- Direct API callers can move an uncropped cel before synchronization.
    if cel.image.width==m.width and cel.image.height==m.height then ax,ay=cel.position.x,cel.position.y end
    local dx,dy=(ax-m.baseX)/32,(ay-m.baseY)/32
    assert(dx%1==0 and dy%1==0,'Mova #'..m.clientId..' em múltiplos de 32 pixels antes de copiar a cena')
    local x,y,z=m.tileX+dx,m.tileY+dy,m.tileZ
    local parent=layer.parent
    while parent and parent~=sprite do
      local floor=parent.name:match('^Andar (%d+)$')
      if floor then z=tonumber(floor); break end
      parent=parent.parent
    end
    -- The isometric floor displacement changes by 32 px per floor.
    x=x+(z-m.tileZ); y=y+(z-m.tileZ)
    assert(x>=0 and x<=65535 and y>=0 and y<=65535 and z>=0 and z<=15,'Item fora dos limites do mapa')
    local k=key(x,y,z)
    local tile=tileIndex[k]
    if not tile then tile={x=x,y=y,z=z,flags=0,houseId=0,zones={},items={}}; scene.tiles[#scene.tiles+1]=tile; tileIndex[k]=tile end
    assert(m.item,'A camada #'..m.clientId..' não tem Server ID. Para adicionar itens à cena, duplique uma camada importada do mesmo tipo.')
    local item=copy(m.item)
    local renamed=tonumber(layer.name:match('^#(%d+)'))
    assert(not renamed or renamed==m.clientId,'Para trocar o tipo de um item use o NexaMap; #ID de item importado deve ser preservado')
    item.clientId=m.clientId
    tile.items[#tile.items+1]=item
  end)
  -- A moved selection must paste relative to its new minimum coordinates.
  local minX,minY,minZ=math.huge,math.huge,15
  for _,tile in ipairs(scene.tiles) do
    minX=math.min(minX,tile.x); minY=math.min(minY,tile.y); minZ=math.min(minZ,tile.z)
  end
  scene.origin={x=minX,y=minY,z=sm.source.origin.z}
  Scene.validate(scene)
  return scene
end

function Scene.write(scene,path)
  Scene.validate(scene)
  local temp=path..'.tmp'
  local f=assert(io.open(temp,'wb'))
  assert(f:write(json.encode(scene))); f:close()
  -- Windows cannot rename over an existing file. Preserve the previous exchange
  -- document until the complete replacement is safely written.
  local old=io.open(path,'rb')
  if old then old:close(); assert(os.remove(path)) end
  assert(os.rename(temp,path))
end

return Scene
