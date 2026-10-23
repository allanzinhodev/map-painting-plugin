-- Explicit publication of edited resources; ordinary export never touches source assets.
local here = app.fs.filePath(debug.getinfo(1,'S').source:sub(2))
local Tibia = dofile(app.fs.joinPath(here,'tibia.lua'))
local P = {}

local function read(path)
  local f = assert(io.open(path,'rb'), 'Nao foi possivel ler '..path)
  local bytes = assert(f:read('a')); f:close(); return bytes
end

local function write(path, bytes)
  local f = assert(io.open(path,'wb'), 'Nao foi possivel gravar '..path)
  local ok, err = f:write(bytes)
  local closed, closeError = f:close()
  assert(ok and closed, tostring(err or closeError))
end

function P.apply(project, outputDir)
  assert(Tibia.changeCount(project)>0, 'Nenhuma sprite alterada para aplicar')
  local records = {
    {path=project.datPath, original=project.datBytes},
    {path=project.sprPath, original=project.sprBytes},
    {path=project.otfiPath, original=project.otfiBytes},
  }
  for _,r in ipairs(records) do
    assert(read(r.path)==r.original, 'Os recursos mudaram no disco. Exporte suas edicoes e recarregue o projeto antes de aplicar: '..r.path)
  end
  app.fs.makeAllDirectories(outputDir)
  local exported = Tibia.export(project,outputDir)
  -- Parse the complete export before publishing it.
  local verified = Tibia.load(outputDir)
  assert(verified.itemCount==project.itemCount, 'Validacao da exportacao falhou')
  records[1].bytes=read(exported.datPath)
  records[2].bytes=read(exported.sprPath)
  records[3].bytes=read(exported.otfiPath)
  local token=os.date('%Y%m%d-%H%M%S')..'-'..math.random(100000,999999)
  local backupDir=app.fs.joinPath(project.directory,'.tibia-workbench-backups',token)
  app.fs.makeAllDirectories(backupDir)
  local ok,err=pcall(function()
    for _,r in ipairs(records) do
      r.stage=r.path..'.tibia-stage-'..token
      r.old=r.path..'.tibia-previous-'..token
      write(app.fs.joinPath(backupDir,app.fs.fileName(r.path)),r.original)
      write(r.stage,r.bytes)
    end
    for _,r in ipairs(records) do
      assert(read(r.path)==r.original, 'Recurso modificado por outro programa: '..r.path)
      assert(os.rename(r.path,r.old))
      r.moved=true
      assert(os.rename(r.stage,r.path))
      r.committed=true
    end
    -- Validate from the actual target paths as well, while rollback is possible.
    verified=Tibia.load(project.directory)
  end)
  if not ok then
    local rollbackErrors={}
    for i=#records,1,-1 do
      local r=records[i]
      if r.committed then os.remove(r.path) end
      if r.moved then
        local restored,why=os.rename(r.old,r.path)
        if not restored then rollbackErrors[#rollbackErrors+1]=r.old..': '..tostring(why) end
      end
      if r.stage then os.remove(r.stage) end
    end
    local detail=#rollbackErrors>0 and ('\nRestauracao pendente: '..table.concat(rollbackErrors,'; ')) or '\nRecursos anteriores preservados.'
    error(tostring(err)..detail..'\nBackup: '..backupDir)
  end
  for _,r in ipairs(records) do os.remove(r.old) end
  return verified,backupDir
end

return P
