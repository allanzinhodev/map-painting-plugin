-- Aseprite image adapter. The codec itself deliberately has no GUI dependency.
local here = app.fs.filePath(debug.getinfo(1, 'S').source:sub(2))
local Tibia = dofile(app.fs.joinPath(here, 'tibia.lua'))
local R = { codec = Tibia, namespace = 'allan/tibia-workbench' }

-- Aseprite's json.decode returns JsonObj userdata, which json.encode does not
-- recursively serialize when nested in a Lua table. Normalize at the boundary.
function R.plain(value)
  if type(value)~='table' and type(value)~='userdata' then return value end
  local result={}
  for key,entry in pairs(value) do result[key]=R.plain(entry) end
  if next(result)==nil then for i=1,#value do result[i]=R.plain(value[i]) end end
  return result
end

function R.metadata(object)
  local value = object.properties(R.namespace).json
  if not value or value == '' then return nil end
  local ok, result = pcall(json.decode, value)
  if ok then return R.plain(result) end
end

function R.setMetadata(object, value)
  object.properties(R.namespace).json = json.encode(value)
end

function R.image(rgba)
  local image = Image(32, 32, ColorMode.RGB)
  image.bytes = rgba
  return image
end

function R.variant(item, value)
  value = value or {}
  local groupIndex = math.max(1, math.min(#item.groups, value.group or 1))
  local g = item.groups[groupIndex]
  return {
    group=groupIndex,
    patternX=(value.patternX or 0) % g.patternX,
    patternY=(value.patternY or 0) % g.patternY,
    patternZ=(value.patternZ or 0) % g.patternZ,
    frame=(value.frame or 0) % g.frames,
    layer=value.layer,
    flatSlot=value.flatSlot,
  }, g
end

function R.render(project, id, variant)
  local item = assert(project.items[id], 'Client ID inexistente: ' .. tostring(id))
  local v, g = R.variant(item, variant)
  if v.flatSlot then return R.image(Tibia.getItemSprite(project,id,v.group,v.flatSlot)) end
  local image = Image(g.width*32, g.height*32, ColorMode.RGB)
  local first, last = 0, g.layers-1
  if v.layer ~= nil then first, last = v.layer, v.layer end
  for layer=first,last do
    for y=0,g.height-1 do for x=0,g.width-1 do
      local slot = Tibia.spriteSlot(g,x,y,layer,v.patternX,v.patternY,v.patternZ,v.frame)
      image:drawImage(R.image(Tibia.getItemSprite(project,id,v.group,slot)),
        Point((g.width-x-1)*32,(g.height-y-1)*32))
    end end
  end
  return image
end

function R.layout(item)
  local layout = { width=32, height=0, layers=1, entries={}, variants={} }
  for gi,g in ipairs(item.groups) do
    layout.layers = math.max(layout.layers,g.layers)
    layout.width = math.max(layout.width,g.width*32*g.frames)
    for pz=0,g.patternZ-1 do for py=0,g.patternY-1 do for px=0,g.patternX-1 do
      local top = layout.height
      layout.variants[#layout.variants+1]={group=gi,patternX=px,patternY=py,patternZ=pz,y=top,width=g.width*32,height=g.height*32,frames=g.frames}
      for frame=0,g.frames-1 do for layer=0,g.layers-1 do
        for y=0,g.height-1 do for x=0,g.width-1 do
          layout.entries[#layout.entries+1]={group=gi,slot=Tibia.spriteSlot(g,x,y,layer,px,py,pz,frame),
            layer=layer,x=frame*g.width*32+(g.width-x-1)*32,y=top+(g.height-y-1)*32}
        end end
      end end
      layout.height = layout.height+g.height*32
    end end end
  end
  assert(layout.width <= 16384 and layout.height <= 16384,'Spritesheet maior que 16384 pixels; abra uma variante menor.')
  return layout
end

function R.sheetLayer(project,id,layout,layer)
  local image = Image(layout.width,layout.height,ColorMode.RGB)
  for _,entry in ipairs(layout.entries) do
    if entry.layer == layer then
      image:drawImage(R.image(Tibia.getItemSprite(project,id,entry.group,entry.slot)),Point(entry.x,entry.y))
    end
  end
  return image
end

function R.capture(cel,width,height,originX,originY)
  local image = Image(width,height,ColorMode.RGB)
  if cel then image:drawImage(cel.image,Point(cel.position.x-(originX or 0),cel.position.y-(originY or 0))) end
  return image
end

function R.applySheetLayer(project,id,layout,layer,image)
  local changed = false
  for _,entry in ipairs(layout.entries) do
    if entry.layer == layer then
      local tile = Image(image,Rectangle(entry.x,entry.y,32,32))
      if tile.bytes ~= Tibia.getItemSprite(project,id,entry.group,entry.slot) then
        Tibia.setItemSprite(project,id,entry.group,entry.slot,tile.bytes)
        changed = true
      end
    end
  end
  return changed
end

-- A scene is rendered as one image per item. A changed pixel goes to the
-- highest source layer contributing that pixel; untouched source layers stay intact.
function R.applyVariant(project,id,variant,image)
  local v,g = R.variant(assert(project.items[id]),variant)
  if v.flatSlot then
    local rgba=image.bytes
    if rgba==Tibia.getItemSprite(project,id,v.group,v.flatSlot) then return false end
    Tibia.setItemSprite(project,id,v.group,v.flatSlot,rgba)
    return true
  end
  local previous = R.render(project,id,v)
  if previous.bytes == image.bytes then return false end
  local layers,changed = {},false
  local first,last=v.layer or 0,v.layer or (g.layers-1)
  for layer=first,last do layers[layer] = R.render(project,id,{group=v.group,
    patternX=v.patternX,patternY=v.patternY,patternZ=v.patternZ,frame=v.frame,layer=layer}) end
  for y=0,image.height-1 do for x=0,image.width-1 do
    local pixel = image:getPixel(x,y)
    if pixel ~= previous:getPixel(x,y) then
      local owner = last
      for layer=last,first,-1 do
        if app.pixelColor.rgbaA(layers[layer]:getPixel(x,y)) > 0 then owner=layer break end
      end
      -- Clear contributors at this changed pixel so partial alpha also renders
      -- exactly as painted. Unchanged pixels retain the original source layers.
      for layer=first,last do layers[layer]:putPixel(x,y,0) end
      if app.pixelColor.rgbaA(pixel)>0 then layers[owner]:putPixel(x,y,pixel) end
    end
  end end
  for layer=first,last do for y=0,g.height-1 do for x=0,g.width-1 do
    local slot=Tibia.spriteSlot(g,x,y,layer,v.patternX,v.patternY,v.patternZ,v.frame)
    local rgba=Image(layers[layer],Rectangle((g.width-x-1)*32,(g.height-y-1)*32,32,32)).bytes
    if rgba ~= Tibia.getItemSprite(project,id,v.group,slot) then
      Tibia.setItemSprite(project,id,v.group,slot,rgba)
      changed=true
    end
  end end end
  return changed
end

function R.walk(layers, callback)
  for _,layer in ipairs(layers) do
    callback(layer)
    if layer.isGroup then R.walk(layer.layers,callback) end
  end
end

return R
