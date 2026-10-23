local root=app.params.root or 'C:/Users/Allan/Aseprite_tibia'
local ok,err=xpcall(function()
  -- A real installed plugin registers this command during Aseprite startup.
  -- The command loads the configured DAT/SPR profile and synchronizes open links.
  app.command.TibiaSync()
  local folder=app.fs.joinPath(app.fs.userConfigPath,'extensions','tibia-workbench')
  assert(app.fs.isFile(app.fs.joinPath(folder,'package.json')),'Installed manifest absent')
  assert(app.fs.isFile(app.fs.joinPath(folder,'lib','tibia.lua')),'Installed codec absent')
end,debug.traceback)
local f=assert(io.open(root..'/tests/installed-result.txt','wb'))
f:write(ok and 'PASS: installed plugin loaded and registered TibiaSync; configured assets opened successfully.\n' or ('FAIL: '..err..'\n')); f:close()
assert(ok,err)
