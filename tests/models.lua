-- Standalone render / scene model suite. Does not load the application UI.
local root=app.params.root or "C:/Users/Allan/Aseprite_tibia"
local source=app.params.source or "C:/Users/Allan/backlands-workflow/client/data/things/860"
local lines={}
local function note(message) print(message); lines[#lines+1]=message end
local ok,err=xpcall(function()
  dofile(root.."/tests/lib/models.lua")(root,source,note)
  note("PASS")
end,debug.traceback)
if not ok then note("FAIL: "..tostring(err)) end
local f=assert(io.open(root.."/tests/models-result.txt","w"))
f:write(table.concat(lines,"\n"),"\n"); f:close()
if not ok then error(err) end
