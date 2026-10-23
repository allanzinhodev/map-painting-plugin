local root=app.params.root or app.fs.filePath(app.fs.filePath(debug.getinfo(1,'S').source:sub(2)))
local path=root..'/tests/ui-smoke-result.txt'
local function report(text) local f=assert(io.open(path,'w')); f:write(text); f:close() end
local ok,err=xpcall(function()
  assert(app.isUIAvailable,'Run this smoke test with the Aseprite UI enabled')
  local M=dofile(root..'/extension/main.lua')
  local extension={preferences={}}
  function extension:newMenuGroup(options) assert(options.title=='Open Tibia Painting') end
  function extension:newCommand() end
  init(extension)
  M.loadProject(assert(app.params.source,'Pass --script-param source=<DAT/SPR directory>'))
  local browser=M.show()
  local timer
  timer=Timer{interval=tonumber(app.params.duration) or 1,ontick=function()
    timer:stop()
    local passed,failure=xpcall(function()
      local bounds=browser.bounds
      assert(bounds.width<=325 and bounds.height<=400,
        string.format('Browser too large: %dx%d UI pixels',bounds.width,bounds.height))
      M.status=string.rep('Recursos aplicados · C:/pasta/longa/ç/',12)
      browser=M.show()
      local updated=browser.bounds
      assert(updated.width<=325 and updated.height<=400,'Long status expanded the browser')
      report(string.format('PASS: Open Tibia Painting painted at %dx%d UI pixels; long status remained compact.\n',bounds.width,bounds.height))
    end,debug.traceback)
    if not passed then report('FAIL: '..failure) end
    exit({}); app.exit()
  end}
  timer:start()
end,debug.traceback)
if not ok then report('FAIL: '..err); app.exit() end
