local root=app.params.root or 'C:/Users/Allan/Aseprite_tibia'
local T=dofile(root..'/extension/lib/tibia.lua')
local P=dofile(root..'/extension/lib/publish.lua')
local base=root..'/tests/output-publish'
local source=base..'/source'
local output=base..'/export'
local function read(path) local f=assert(io.open(path,'rb')); local s=f:read('a'); f:close(); return s end
local function write(path,s) local f=assert(io.open(path,'wb')); assert(f:write(s)); f:close() end
local function run()
  app.fs.makeAllDirectories(source)
  local original='C:/Users/Allan/backlands-workflow/client/data/things/860'
  for _,name in ipairs({'Tibia.dat','Tibia.spr','Tibia.otfi'}) do write(source..'/'..name,read(original..'/'..name)) end
  local project=T.load(source)
  local oldDat,oldSpr=project.datBytes,project.sprBytes
  local rgba=string.rep(string.char(7,11,23,128),1024)
  T.setItemSprite(project,100,1,1,rgba)
  local applied,backup=P.apply(project,output)
  assert(T.getItemSprite(applied,100,1,1)==rgba)
  assert(T.changeCount(applied)==0)
  assert(read(backup..'/Tibia.dat')==oldDat and read(backup..'/Tibia.spr')==oldSpr)
  -- An external modification must stop publication before any source replacement.
  T.setItemSprite(applied,100,1,1,string.rep(string.char(9,13,27,255),1024))
  local beforeDat,beforeSpr=read(source..'/Tibia.dat'),read(source..'/Tibia.spr')
  write(source..'/Tibia.otfi',applied.otfiBytes..'\n# changed externally\n')
  local ok=pcall(P.apply,applied,output)
  assert(not ok,'Conflicting source change was accepted')
  assert(read(source..'/Tibia.dat')==beforeDat and read(source..'/Tibia.spr')==beforeSpr)
  return 'PASS: publication parsed, alpha preserved, source backup exact, external changes rejected; live assets untouched.'
end
local ok,result=xpcall(run,debug.traceback)
write(root..'/tests/publish-result.txt',(ok and result or 'FAIL: '..result)..'\n')
assert(ok,result)
print(result)
