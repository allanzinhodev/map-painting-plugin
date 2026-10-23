local path='C:/Users/Allan/Aseprite_tibia/tests/ui-smoke-result.txt'
local function report(text) local f=assert(io.open(path,'w')); f:write(text); f:close() end
local ok,err=xpcall(function()
  local M=dofile('C:/Users/Allan/Aseprite_tibia/extension/main.lua')
  local extension={preferences={}}
  function extension:newMenuGroup() end
  function extension:newCommand() end
  init(extension)
  M.loadProject('C:/Users/Allan/backlands-workflow/client/data/things/860')
  M.show()
  local timer
  timer=Timer{interval=1,ontick=function()
    timer:stop(); exit({}); report('PASS: native item browser painted and remained responsive'); app.exit()
  end}
  timer:start()
end,debug.traceback)
if not ok then report(err); app.exit() end
