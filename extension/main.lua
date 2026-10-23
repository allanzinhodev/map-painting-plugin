-- Open Tibia Painting: native Lua DAT/SPR editing and NexaMap scene exchange.
local root=app.fs.filePath(debug.getinfo(1,'S').source:sub(2))
local R=dofile(app.fs.joinPath(root,'lib','render.lua'))
local Scene=dofile(app.fs.joinPath(root,'lib','scene.lua'))
local T=R.codec
local M={render=R,scene=Scene,codec=T,snapshots={},watchers={},dirty={},busy=false,enabled=true}
local plugin,dialog,timer,siteListener
local function statusText(text)
  text=tostring(text)
  local cutoff=utf8.offset(text,39)
  return cutoff and (text:sub(1,cutoff-1)..'…') or text
end
local defaults={assetsDirectory='C:/Users/Allan/backlands-workflow/client/data/things/860',
  bridgeDirectory='C:/Users/Allan/Aseprite_tibia/runtime'}
do
  local f=io.open(app.fs.joinPath(root,'defaults.json'),'rb')
  if f then local ok,value=pcall(json.decode,f:read('a')); f:close(); if ok then for k,v in pairs(R.plain(value)) do defaults[k]=v end end end
end
local function config(key)
  return plugin and plugin.preferences[key] or defaults[key]
end
local function norm(path) return (path or ''):gsub('\\','/'):gsub('/+$',''):lower() end
local function sameProject(meta) return M.project and norm(meta.assetsDirectory)==norm(M.project.directory) end
local function notify(message)
  M.status=tostring(message)
  if dialog then dialog:modify{id='status',text=statusText(M.status)}; dialog:repaint() end
end
local function safe(callback)
  return function(...)
    local ok,result=xpcall(callback,debug.traceback,...)
    if not ok then
      notify('Falha: '..tostring(result):match('^[^\n]+'))
      if app.isUIAvailable then app.alert{title='Open Tibia Painting',text=tostring(result)} else error(result) end
    end
    return result
  end
end
local function layerKey(sprite,layer) return sprite.id..':'..tostring(layer.uuid) end
local function celSignature(cel)
  return cel and (cel.image.id..':'..cel.image.version..':'..cel.image.width..':'..cel.image.height) or 'empty'
end

function M.loadProject(directory)
  local project=T.load(directory)
  M.project=project; M.snapshots={}; M.dirty={}; M.thumbnails={}
  M.ids={}
  for id in pairs(project.items) do M.ids[#M.ids+1]=id end
  table.sort(M.ids)
  M.filtered=M.ids; M.page=0; M.selected=M.ids[1]
  if plugin then plugin.preferences.assetsDirectory=directory end
  M.scan()
  notify(project.itemCount..' itens carregados · sprites '..project.spriteCount)
  return project
end

function M.bind(layer,id,variant)
  assert(M.project,'Carregue os recursos primeiro')
  local item=assert(M.project.items[id],'Client ID inexistente: '..tostring(id))
  assert(not layer.isGroup and layer.sprite.colorMode==ColorMode.RGB,'Use uma camada de pixels em modo RGB')
  local v=R.variant(item,variant)
  local expected=R.render(M.project,id,v)
  local cel=layer:cel(1)
  local px,py=cel and cel.position.x or 0,cel and cel.position.y or 0
  layer.sprite.useLayerUuids=true
  R.setMetadata(layer,{role='instance',clientId=id,assetsDirectory=M.project.directory,variant=v,
    anchorX=px,anchorY=py,baseX=px,baseY=py,width=expected.width,height=expected.height})
  if not cel then layer.sprite:newCel(layer,1,expected,Point(px,py)) end
  layer.name='#'..id
  M.dirty[layer.sprite.id]=true
  return layer
end

function M.openItem(id)
  assert(M.project,'Carregue os recursos primeiro')
  local item=assert(M.project.items[id],'Client ID inexistente')
  local layout=R.layout(item)
  local sprite=Sprite(layout.width,layout.height,ColorMode.RGB)
  sprite.filename='Item #'..id..'.aseprite'; sprite.useLayerUuids=true
  sprite.gridBounds=Rectangle(0,0,32,32)
  app.transaction('Abrir item #'..id,function()
    local empty=sprite.layers[1]
    for layerIndex=0,layout.layers-1 do
      local layer=sprite:newLayer(); layer.name='#'..id..' · L'..(layerIndex+1)
      R.setMetadata(layer,{role='sheet',clientId=id,sourceLayer=layerIndex,assetsDirectory=M.project.directory})
      sprite:newCel(layer,1,R.sheetLayer(M.project,id,layout,layerIndex),Point(0,0))
    end
    sprite:deleteLayer(empty)
    R.setMetadata(sprite,{role='sheet',clientId=id,assetsDirectory=M.project.directory,
      explanation='Colunas: frames. Linhas: grupo, patternZ, patternY, patternX. Camadas: layers DAT. Grade: 32 px.'})
    -- Named slices make every pattern/group row identifiable after reopening.
    for _,v in ipairs(layout.variants) do
      local slice=sprite:newSlice(Rectangle(0,v.y,v.width*v.frames,v.height))
      slice.name='G'..v.group..' X'..v.patternX..' Y'..v.patternY..' Z'..v.patternZ
    end
  end)
  M.scan(); M.prime(sprite)
  return sprite
end

function M.importScene(source)
  assert(M.project,'Carregue os recursos primeiro')
  local scene=type(source)=='table' and source or Scene.read(source or app.fs.joinPath(config('bridgeDirectory'),'nexa-scene.json'))
  local sprite=Scene.import(M.project,scene)
  sprite.useLayerUuids=true
  M.scan(); M.prime(sprite)
  notify('Cena importada. Mova itens em passos de 32 px; pinte para atualizar o ID.')
  return sprite
end

local function expectedFor(meta,sprite)
  if meta.role=='sheet' then
    local layout=R.layout(M.project.items[meta.clientId])
    return R.sheetLayer(M.project,meta.clientId,layout,meta.sourceLayer),layout,0,0
  end
  return R.render(M.project,meta.clientId,meta.variant),nil,meta.anchorX or 0,meta.anchorY or 0
end

function M.prime(sprite)
  R.walk(sprite.layers,function(layer)
    local meta=R.metadata(layer)
    if meta and sameProject(meta) and (meta.role=='sheet' or meta.role=='instance') then
      local expected=expectedFor(meta,sprite)
      local cel=layer:cel(1)
      M.snapshots[layerKey(sprite,layer)]={bytes=expected.bytes,signature=celSignature(cel),
        x=cel and cel.position.x or 0,y=cel and cel.position.y or 0,anchorX=meta.anchorX or 0,anchorY=meta.anchorY or 0}
    end
  end)
end

function M.scan()
  if not M.project or M.busy then return end
  local alive={}
  for _,sprite in ipairs(app.sprites) do
    alive[sprite.id]=true
    if not M.watchers[sprite.id] then
      local callback=function() if not M.busy then M.dirty[sprite.id]=true end end
      M.watchers[sprite.id]={sprite=sprite,change=sprite.events:on('change',callback),name=sprite.events:on('layername',callback)}
      M.dirty[sprite.id]=true
    end
  end
  for id,watch in pairs(M.watchers) do if not alive[id] then M.watchers[id]=nil; M.dirty[id]=nil end end
end

local function applyOne(layer,meta,sprite,changed)
  if not M.project.items[meta.clientId] then return end
  local key=layerKey(sprite,layer)
  local old=M.snapshots[key]
  local expected,layout,ax,ay=expectedFor(meta,sprite)
  local cel=layer:cel(1)
  if not cel then return end -- Removing a scene cel removes its map occurrence.
  local signature=celSignature(cel)
  if old and old.signature==signature and old.x==cel.position.x and old.y==cel.position.y then return end
  -- Pure translations do not alter the linked bitmap. Cropped brush/eraser
  -- operations change the image signature, so retain the item's logical origin.
  if meta.role=='instance' and old and old.signature==signature then
    ax=old.anchorX+cel.position.x-old.x; ay=old.anchorY+cel.position.y-old.y
    meta.anchorX,meta.anchorY=ax,ay; R.setMetadata(layer,meta)
  end
  local image=R.capture(cel,expected.width,expected.height,ax,ay)
  local bytes=image.bytes
  local previous=old and old.bytes or expected.bytes
  if bytes~=previous then
    -- Merge only pixels changed in this occurrence. Another document may have
    -- edited a different pattern of the same item in the same timer interval.
    local before=Image(image.width,image.height,ColorMode.RGB); before.bytes=previous
    local merged=Image(expected)
    for y=0,image.height-1 do for x=0,image.width-1 do
      local pixel=image:getPixel(x,y)
      if pixel~=before:getPixel(x,y) then merged:putPixel(x,y,pixel) end
    end end
    local applied
    if meta.role=='sheet' then applied=R.applySheetLayer(M.project,meta.clientId,layout,meta.sourceLayer,merged)
    else applied=R.applyVariant(M.project,meta.clientId,meta.variant,merged) end
    if applied then changed[meta.clientId]=true end
  end
  M.snapshots[key]={bytes=bytes,signature=signature,x=cel.position.x,y=cel.position.y,anchorX=ax,anchorY=ay}
end

function M.sync(force)
  if M.busy or not M.project or (not M.enabled and not force) then return false end
  M.scan(); M.busy=true
  local changed={}
  local ok,err=xpcall(function()
    -- Consume all user edits before repainting any other occurrence. A deferred
    -- transaction keeps change callbacks read-only and prevents feedback loops.
    for _,sprite in ipairs(app.sprites) do
      if force or M.dirty[sprite.id] then
        app.transaction('Sincronizar IDs Tibia',function()
          R.walk(sprite.layers,function(layer)
            if layer.isGroup then return end
            local meta=R.metadata(layer)
            if not meta and sprite.colorMode==ColorMode.RGB then
              local id=tonumber(layer.name:match('^#(%d+)%f[%D]') or layer.name:match('^#(%d+)$'))
              if id and M.project.items[id] then M.bind(layer,id); meta=R.metadata(layer) end
            end
            if meta and sameProject(meta) and (meta.role=='sheet' or meta.role=='instance') then applyOne(layer,meta,sprite,changed) end
          end)
        end)
      end
    end
    if next(changed) then
      for _,sprite in ipairs(app.sprites) do
        app.transaction('Atualizar ocorrências Tibia',function()
          R.walk(sprite.layers,function(layer)
            local meta=R.metadata(layer)
            if not meta or not sameProject(meta) or not changed[meta.clientId] or layer.isGroup then return end
            if meta.role~='sheet' and meta.role~='instance' then return end
            local cel=layer:cel(1)
            if not cel then return end
            local image,_,ax,ay=expectedFor(meta,sprite)
            local current=R.capture(cel,image.width,image.height,ax,ay)
            if current.bytes~=image.bytes or cel.position.x~=ax or cel.position.y~=ay or cel.image.width~=image.width or cel.image.height~=image.height then
              cel.image=image; cel.position=Point(ax,ay)
            end
            M.snapshots[layerKey(sprite,layer)]={bytes=image.bytes,signature=celSignature(cel),x=cel.position.x,y=cel.position.y,anchorX=ax,anchorY=ay}
          end)
        end)
      end
      M.thumbnails={}; notify(T.changeCount(M.project)..' sprites alteradas · ocorrências sincronizadas')
    end
    M.dirty={}
  end,debug.traceback)
  M.busy=false
  if not ok then error(err) end
  return next(changed)~=nil
end

function M.saveScene(path,sprite)
  M.sync(true)
  sprite=sprite or app.sprite
  assert(sprite,'Abra uma cena primeiro')
  local scene=Scene.export(sprite)
  local directory=path and app.fs.filePath(path) or config('bridgeDirectory')
  if not app.fs.isDirectory(directory) then app.fs.makeAllDirectories(directory) end
  path=path or app.fs.joinPath(directory,'aseprite-scene.json')
  Scene.write(scene,path)
  notify('Cena copiada. No NexaMap: Editar > Colar cena do Aseprite.')
  return scene,path
end

function M.exportAssets(directory)
  assert(M.project,'Carregue os recursos primeiro')
  M.sync(true)
  if not app.fs.isDirectory(directory) then app.fs.makeAllDirectories(directory) end
  local result=T.export(M.project,directory)
  notify('Recursos exportados: '..T.changeCount(M.project)..' sprites editadas')
  return result
end

function M.applyAssets()
  assert(M.project,'Carregue os recursos primeiro')
  M.sync(true)
  local Publish=dofile(app.fs.joinPath(root,'lib','publish.lua'))
  local project,backup=Publish.apply(M.project,app.fs.joinPath(config('bridgeDirectory'),'published'))
  M.project=project; M.thumbnails={}
  for _,sprite in ipairs(app.sprites) do M.prime(sprite) end
  notify('Recursos aplicados com backup. No NexaMap: recarregar sprites. Backup: '..backup)
  if app.isUIAvailable then app.alert{title='Recursos aplicados',text={'DAT/SPR atualizados. Recarregue as sprites no NexaMap.','Backup: '..backup}} end
  return project,backup
end

local function ensureProject()
  if not M.project then M.loadProject(config('assetsDirectory')) end
end

local function settings()
  local dlg=Dialog{title='Recursos e integração'}
  dlg:entry{id='assets',label='Pasta DAT/SPR:',text=config('assetsDirectory')}
  dlg:newrow():entry{id='bridge',label='Pasta da ponte:',text=config('bridgeDirectory')}
  dlg:newrow():label{text='A pasta de recursos precisa conter Tibia.otfi, .dat e .spr.'}
  dlg:newrow():button{text='Carregar',onclick=safe(function()
    M.loadProject(dlg.data.assets)
    if plugin then plugin.preferences.bridgeDirectory=dlg.data.bridge else defaults.bridgeDirectory=dlg.data.bridge end
    dlg:close()
  end)}
  dlg:button{text='Cancelar'}
  dlg:show()
end

local function filter(text)
  if not M.project then return end
  local query=(text or ''):lower():gsub('^#','')
  M.filtered={}
  for _,id in ipairs(M.ids) do
    local item=M.project.items[id]
    if query=='' or tostring(id):find(query,1,true) or (item.marketName or ''):lower():find(query,1,true) then M.filtered[#M.filtered+1]=id end
  end
  M.page=0
  if dialog then dialog:repaint() end
end

local function selectedInfo()
  if not dialog or not M.project or not M.selected then return end
  local item=M.project.items[M.selected]
  if not item then return end
  local g=item.groups[1]
  dialog:modify{id='selected',text=string.format('#%d · %dx%d · %d frames · padrões %dx%dx%d',item.id,g.width,g.height,g.frames,g.patternX,g.patternY,g.patternZ)}
end

local function activeLink()
  local layer=app.layer
  local meta=layer and R.metadata(layer)
  if meta and meta.clientId then return meta.clientId,meta end
  return layer and tonumber(layer.name:match('^#(%d+)'))
end

function M.show()
  if dialog then dialog:close(); dialog=nil end
  ensureProject()
  local cols,rows,cellW,cellH=6,3,44,48
  local pageSize=cols*rows
  dialog=Dialog{title='Open Tibia Painting',onclose=function() dialog=nil end}
  local dlg=dialog
  dlg:entry{id='search',placeholder='ID / nome',text='',onchange=function() filter(dlg.data.search) end}
  dlg:samerow():button{text='Recursos…',onclick=safe(settings)}
  dlg:newrow():canvas{id='items',width=cols*cellW,height=rows*cellH,hexpand=false,vexpand=false,
    onpaint=function(ev)
      local gc=ev.context
      gc.color=Color{r=32,g=34,b=39}; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
      for index=0,pageSize-1 do
        local id=M.filtered and M.filtered[(M.page or 0)*pageSize+index+1]
        if id then
          local x,y=(index%cols)*cellW,(index//cols)*cellH
          gc.color=id==M.selected and Color{r=75,g=115,b=150} or Color{r=49,g=51,b=57}
          gc:fillRect(Rectangle(x+1,y+1,cellW-2,cellH-2))
          local image=M.thumbnails[id]
          if not image then image=R.render(M.project,id); M.thumbnails[id]=image end
          local scale=math.min(1,32/image.width,32/image.height)
          local w,h=math.floor(image.width*scale),math.floor(image.height*scale)
          gc:drawImage(image,Rectangle(0,0,image.width,image.height),Rectangle(x+(cellW-w)//2,y+3,w,h))
          gc.color=Color{r=235,g=235,b=230}; gc:fillText('#'..id,x+4,y+cellH-12)
        end
      end
    end,
    onmousedown=function(ev)
      local index=math.floor(ev.y/cellH)*cols+math.floor(ev.x/cellW)
      local id=M.filtered[(M.page or 0)*pageSize+index+1]
      if id then M.selected=id; selectedInfo(); dlg:repaint() end
    end,
    ondblclick=safe(function() if M.selected then M.openItem(M.selected) end end)}
  local function turn(delta)
    local max=math.max(0,math.ceil(#M.filtered/pageSize)-1)
    M.page=math.max(0,math.min(max,M.page+delta))
    dlg:modify{id='page',text=(M.page+1)..' / '..(max+1)..' · '..#M.filtered..' itens'}; dlg:repaint()
  end
  dlg:newrow():label{id='page',text='1 / '..math.max(1,math.ceil(#M.filtered/pageSize))..' · '..#M.filtered..' itens'}
  dlg:samerow():button{text='‹',onclick=function() turn(-1) end}
  dlg:button{text='›',onclick=function() turn(1) end}
  dlg:newrow():label{id='selected',text='Selecione um item'}
  dlg:newrow():canvas{id='preview',width=40,height=40,hexpand=false,vexpand=false,onpaint=function(ev)
    if not M.project or not M.selected then return end
    local g=M.project.items[M.selected].groups[1]
    local frame=(M.previewFrame or 0)%g.frames
    local image=R.render(M.project,M.selected,{frame=frame})
    local scale=math.min(1,36/image.width,36/image.height)
    ev.context:drawImage(image,Rectangle(0,0,image.width,image.height),Rectangle(2,2,math.floor(image.width*scale),math.floor(image.height*scale)))
  end}
  dlg:samerow():button{text='Abrir item',onclick=safe(function() M.openItem(M.selected) end)}
  dlg:button{text='ID da camada',onclick=safe(function()
    local id=assert(activeLink(),'Selecione uma camada #ID'); M.openItem(id)
  end)}
  dlg:newrow():check{id='automatic',text='Sincronizar #ID automaticamente',selected=M.enabled,onclick=function() M.enabled=dlg.data.automatic end}
  dlg:samerow():button{text='Sincronizar',onclick=safe(function() M.sync(true) end)}
  dlg:newrow():button{text='Colar cena',onclick=safe(function() M.importScene() end)}
  dlg:button{text='Copiar cena',onclick=safe(function() M.saveScene() end)}
  dlg:button{text='Cena PNG…',onclick=safe(function()
    assert(app.sprite,'Abra uma cena primeiro')
    local out=Dialog{title='Imagem da cena'}
    out:file{id='path',save=true,filename='cena.png',filetypes={'png'}}
    out:button{text='Salvar',onclick=safe(function()
      local image=Image(app.sprite); image:saveAs(out.data.path); out:close(); notify('Imagem da cena salva')
    end)}
    out:button{text='Cancelar'}; out:show()
  end)}
  dlg:newrow():button{text='Exportar DAT/SPR…',onclick=safe(function()
    local out=Dialog{title='Exportar recursos editados'}
    out:entry{id='directory',label='Pasta de saída:',text=app.fs.joinPath(M.project.directory,'aseprite-export')}
    out:newrow():label{text='Exporte para uma pasta separada. Depois recarregue os recursos no NexaMap.'}
    out:newrow():button{text='Exportar',onclick=safe(function() M.exportAssets(out.data.directory); out:close() end)}
    out:button{text='Cancelar'}; out:show()
  end)}
  dlg:button{text='Aplicar ao cliente',onclick=safe(M.applyAssets)}
  dlg:newrow():label{id='status',text=statusText(M.status or 'Pronto')}
  selectedInfo(); dlg:show{wait=false}
  return dlg
end

function init(extension)
  plugin=extension
  for k,v in pairs(defaults) do if plugin.preferences[k]==nil then plugin.preferences[k]=v end end
  plugin:newMenuGroup{id='tibia_workbench',title='Open Tibia Painting',group='file_scripts'}
  plugin:newCommand{id='TibiaWorkbench',title='Navegar itens…',group='tibia_workbench',onclick=safe(M.show)}
  plugin:newCommand{id='TibiaPasteScene',title='Colar cena do NexaMap',group='tibia_workbench',onclick=safe(function() ensureProject(); M.importScene() end)}
  plugin:newCommand{id='TibiaCopyScene',title='Copiar cena para NexaMap',group='tibia_workbench',onclick=safe(function() ensureProject(); M.saveScene() end)}
  plugin:newCommand{id='TibiaSync',title='Sincronizar camadas #ID',group='tibia_workbench',onclick=safe(function() ensureProject(); M.sync(true) end)}
  plugin:newCommand{id='TibiaSettings',title='Recursos e integração…',group='tibia_workbench',onclick=safe(settings)}
  plugin:newCommand{id='TibiaApplyAssets',title='Aplicar sprites ao cliente (com backup)',group='tibia_workbench',onclick=safe(function() ensureProject(); M.applyAssets() end)}
  siteListener=app.events:on('sitechange',function()
    if M.busy then return end
    if not M.project and app.sprite then
      local meta=R.metadata(app.sprite)
      if meta and meta.assetsDirectory then M.pendingDirectory=meta.assetsDirectory end
    end
    M.scan()
  end)
  if app.isUIAvailable then
    local tick=0
    timer=Timer{interval=0.15,ontick=function()
      tick=tick+1
      local ok,err=pcall(function()
        if M.pendingDirectory and not M.project then
          local directory=M.pendingDirectory; M.pendingDirectory=nil
          M.loadProject(directory)
        end
        if M.project and next(M.dirty) then M.sync(false) end
        if dialog then M.previewFrame=tick; dialog:repaint() end
      end)
      if not ok then M.enabled=false; notify('Sincronização pausada: '..tostring(err):match('^[^\n]+')) end
    end}; timer:start()
  end
end

function exit(extension)
  if timer then timer:stop() end
  if dialog then dialog:close() end
  if siteListener then app.events:off(siteListener) end
  for _,watch in pairs(M.watchers) do
    if watch.sprite.isValid then
      watch.sprite.events:off(watch.change); watch.sprite.events:off(watch.name)
    end
  end
end

return M
