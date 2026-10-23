-- Tibia 8.60 Default metadata / SPR codec. No Aseprite dependency.
-- Sprite coordinates and frame coordinates are zero based; Lua array slots are one based.
local M = { VERSION = 1, SPRITE_SIZE = 32 }
local ZERO = string.rep("\0", 4096)
local categoryOrder = {"items", "outfits", "effects", "missiles"}

local function readFile(path)
  local f, err = io.open(path, "rb")
  assert(f, "Não foi possível abrir " .. path .. ": " .. tostring(err))
  local bytes = assert(f:read("a")); f:close(); return bytes
end

local function join(a, b) return a:gsub("[/\\]+$", "") .. "/" .. b end
local function basename(p) return p:match("([^/\\]+)$") end
local function normalized(path)
  local prefix = path:sub(1, 2) == "\\\\" and "//" or ""
  path = path:gsub("\\", "/")
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      assert(#parts > 1, "Caminho de exportação inválido")
      table.remove(parts)
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return (prefix .. table.concat(parts, "/")):lower()
end

local function reader(data, label)
  local r = {data = data, pos = 1, label = label}
  function r:take(n)
    assert(n >= 0 and self.pos + n - 1 <= #self.data,
      (self.label or "Arquivo") .. " truncado no byte " .. self.pos)
    local s = self.data:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n; return s
  end
  function r:u8() return self:take(1):byte() end
  function r:u16() return string.unpack("<I2", self:take(2)) end
  function r:i16() return string.unpack("<i2", self:take(2)) end
  function r:u32() return string.unpack("<I4", self:take(4)) end
  function r:i32() return string.unpack("<i4", self:take(4)) end
  function r:i8() return string.unpack("<i1", self:take(1)) end
  return r
end

local booleanAttrs = {
  [1]="isGroundBorder", [2]="isOnBottom", [3]="isOnTop", [4]="isContainer",
  [5]="stackable", [6]="forceUse", [7]="multiUse", [10]="isFluidContainer",
  [11]="isFluid", [12]="isUnpassable", [13]="isUnmoveable", [14]="blockMissile",
  [15]="blockPathfind", [16]="pickupable", [17]="hangable", [18]="isVertical",
  [19]="isHorizontal", [20]="rotatable", [22]="dontHide", [23]="isTranslucent",
  [26]="isLyingObject", [27]="animateAlways", [30]="isFullGround", [31]="ignoreLook",
}

local function readAttributes(r, item)
  local start = r.pos
  while true do
    local flag = r:u8()
    if flag == 255 then break end
    item.attributes[flag] = true
    if booleanAttrs[flag] then item[booleanAttrs[flag]] = true
    elseif flag == 0 then item.isGround = true; item.groundSpeed = r:u16()
    elseif flag == 8 then item.writable = true; item.maxReadWriteChars = r:u16()
    elseif flag == 9 then item.writableOnce = true; item.maxReadChars = r:u16()
    elseif flag == 21 then item.hasLight = true; item.lightLevel = r:u16(); item.lightColor = r:u16()
    elseif flag == 24 then item.hasOffset = true; item.offsetX = r:i16(); item.offsetY = r:i16()
    elseif flag == 25 then item.hasElevation = true; item.elevation = r:u16()
    elseif flag == 28 then item.miniMap = true; item.miniMapColor = r:u16()
    elseif flag == 29 then item.isLensHelp = true; item.lensHelp = r:u16()
    elseif flag == 32 then item.cloth = true; item.clothSlot = r:u16()
    elseif flag == 33 then
      item.isMarketItem = true
      item.marketCategory = r:u16(); item.marketTradeAs = r:u16(); item.marketShowAs = r:u16()
      item.marketName = r:take(r:u16())
      item.marketRestrictProfession = r:u16(); item.marketRestrictLevel = r:u16()
    elseif flag == 39 then
      item.hasBones = true; item.bones = {}
      for n = 1, 4 do item.bones[n] = {x = r:i16(), y = r:i16()} end
    else error(string.format("Atributo DAT 0x%02X desconhecido: %s #%d, byte %d", flag, item.category, item.id, r.pos - 1)) end
  end
  item.rawAttributes = r.data:sub(start, r.pos - 1)
end

local function readGroup(r, project, item)
  local g = {spriteIds = {}, spritePositions = {}, durations = {}}
  if item.category == "outfits" and project.flags.frameGroups then g.type = r:u8() else g.type = 0 end
  g.width = r:u8(); g.height = r:u8()
  if g.width > 1 or g.height > 1 then g.exactSize = r:u8() else g.exactSize = 32 end
  g.layers = r:u8(); g.patternX = r:u8(); g.patternY = r:u8(); g.patternZ = r:u8(); g.frames = r:u8()
  for _, key in ipairs({"width", "height", "layers", "patternX", "patternY", "patternZ", "frames"}) do
    assert(g[key] > 0, "Dimensão DAT inválida: " .. item.category .. " #" .. item.id .. " " .. key)
  end
  if g.frames > 1 and project.flags.improvedAnimations then
    g.animationMode = r:u8(); g.loopCount = r:i32(); g.startFrame = r:i8()
    for f = 1, g.frames do
      local min, max = r:u32(), r:u32()
      assert(min <= max, "Duração de animação inválida em " .. item.category .. " #" .. item.id)
      g.durations[f] = {minimum = min, maximum = max}
    end
  else
    g.animationMode = 0; g.loopCount = 0; g.startFrame = 0
    local duration = item.category == "effects" and 75 or 100
    for f = 1, g.frames do g.durations[f] = {minimum = duration, maximum = duration} end
  end
  local total = g.width * g.height * g.layers * g.patternX * g.patternY * g.patternZ * g.frames
  assert(total <= 65536, "Quantidade de sprites por grupo excessiva")
  for i = 1, total do
    g.spritePositions[i] = r.pos
    local id = project.flags.extended and r:u32() or r:u16()
    assert(id <= project.spriteCount, "ID de sprite fora do SPR: " .. id .. " em " .. item.category .. " #" .. item.id)
    g.spriteIds[i] = id
  end
  return g
end

function M.parseOtfi(text)
  local flags = {extended = false, transparency = false, improvedAnimations = false, frameGroups = false, spriteSize = 32}
  local keys = {extended="extended", transparency="transparency", ["frame-durations"]="improvedAnimations", ["frame-groups"]="frameGroups"}
  local files = {metadata = "Tibia.dat", sprites = "Tibia.spr", controller = "Default"}
  for key, value in text:gmatch("([%w-]+)%s*:%s*([^\r\n]+)") do
    value = value:gsub("%s+#.*$", ""):match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1")
    if keys[key] then
      assert(value == "true" or value == "false", "Flag OTFI inválida: " .. key)
      flags[keys[key]] = value == "true"
    elseif key == "metadata-file" then files.metadata = value
    elseif key == "sprites-file" then files.sprites = value
    elseif key == "metadata-controller" then files.controller = value
    elseif key == "sprite-size" then flags.spriteSize = tonumber(value) end
  end
  assert(flags.spriteSize == 32, "A extensão suporta sprites de 32x32")
  assert(files.controller:lower() == "default", "Metadata-controller não suportado: " .. files.controller)
  for _, name in ipairs({files.metadata, files.sprites}) do
    assert(not name:find("[/\\]") and not name:find("%.%."), "Nome de arquivo OTFI inválido")
  end
  return flags, files
end

function M.load(directory, options)
  options = options or {}
  assert(type(directory) == "string" and directory ~= "", "Informe a pasta dos arquivos DAT/SPR")
  local project = {directory = directory, version = 860, categories = {}, changes = {}, revision = 0, cache = {}}
  project.otfiPath = join(directory, options.otfiName or "Tibia.otfi")
  project.otfiBytes = readFile(project.otfiPath)
  project.flags, project.files = M.parseOtfi(project.otfiBytes)
  project.datPath = join(directory, project.files.metadata); project.sprPath = join(directory, project.files.sprites)
  project.datBytes = readFile(project.datPath); project.sprBytes = readFile(project.sprPath)
  local sr = reader(project.sprBytes, "SPR")
  project.sprSignature = sr:u32(); project.spriteCount = project.flags.extended and sr:u32() or sr:u16()
  project.sprHeaderSize = sr.pos - 1
  assert(project.spriteCount <= (#project.sprBytes - project.sprHeaderSize) // 4, "Tabela de endereços SPR truncada")
  project.spriteAddresses = {}
  for id = 1, project.spriteCount do
    local address = sr:u32()
    if address ~= 0 then
      assert(address >= project.sprHeaderSize + project.spriteCount * 4 and address + 5 <= #project.sprBytes,
        "Endereço SPR inválido: sprite #" .. id)
      local length = string.unpack("<I2", project.sprBytes, address + 4)
      assert(address + 5 + length <= #project.sprBytes, "Dados SPR truncados: sprite #" .. id)
    end
    project.spriteAddresses[id] = address
  end
  local r = reader(project.datBytes, "DAT")
  project.datSignature = r:u32(); project.counts = {}
  for _, category in ipairs(categoryOrder) do project.counts[category] = r:u16() end
  project.itemCount = math.max(0, project.counts.items - 99)
  for _, category in ipairs(categoryOrder) do
    local list = {}; project.categories[category] = list; project[category] = list
    for id = category == "items" and 100 or 1, project.counts[category] do
      local item = {id = id, category = category, groups = {}, attributes = {}, offsetX = 0, offsetY = 0, elevation = 0}
      item.startPosition = r.pos
      readAttributes(r, item)
      local groups = 1
      if category == "outfits" and project.flags.frameGroups then groups = r:u8() end
      assert(groups > 0 and groups <= 16, "Número de grupos DAT inválido")
      for n = 1, groups do item.groups[n] = readGroup(r, project, item) end
      item.endPosition = r.pos - 1; list[id] = item
    end
  end
  assert(r.pos == #project.datBytes + 1, "DAT contém " .. (#project.datBytes - r.pos + 1) .. " bytes não reconhecidos. Verifique versão e OTFI.")
  return project
end

function M.spriteSlot(g, x, y, layer, px, py, pz, frame)
  x, y, layer, px, py, pz, frame = x or 0, y or 0, layer or 0, px or 0, py or 0, pz or 0, frame or 0
  for _, p in ipairs({{x,g.width},{y,g.height},{layer,g.layers},{px,g.patternX},{py,g.patternY},{pz,g.patternZ},{frame,g.frames}}) do
    assert(p[1] >= 0 and p[1] < p[2] and p[1] % 1 == 0, "Coordenada de sprite fora do grupo")
  end
  return ((((((frame * g.patternZ + pz) * g.patternY + py) * g.patternX + px) * g.layers + layer) * g.height + y) * g.width + x) + 1
end

function M.decodeSprite(project, id)
  assert(type(id) == "number" and id >= 0 and id <= project.spriteCount, "ID de sprite inválido")
  if id == 0 then return ZERO end
  if project.cache[id] then return project.cache[id] end
  local address = project.spriteAddresses[id]
  if address == 0 then return ZERO end
  local size = string.unpack("<I2", project.sprBytes, address + 4)
  if size == 0 then return ZERO end
  local r = reader(project.sprBytes:sub(address + 6, address + 5 + size), "Sprite #" .. id)
  local pieces, count = {}, 0
  while r.pos <= #r.data do
    local skip, run = r:u16(), r:u16()
    assert(count + skip + run <= 1024 and skip + run > 0, "RLE SPR inválido: #" .. id)
    if skip > 0 then pieces[#pieces + 1] = string.rep("\0", skip * 4) end
    if project.flags.transparency then pieces[#pieces + 1] = r:take(run * 4)
    else for _ = 1, run do pieces[#pieces + 1] = r:take(3) .. "\255" end end
    count = count + skip + run
  end
  if count < 1024 then pieces[#pieces + 1] = string.rep("\0", (1024 - count) * 4) end
  local rgba = table.concat(pieces)
  -- Bound decoded cache (the complete SPR can be large).
  project.cacheSize = (project.cacheSize or 0) + 1
  if project.cacheSize > 1024 then project.cache = {}; project.cacheSize = 1 end
  project.cache[id] = rgba; return rgba
end

local function itemGroup(project, itemId, groupIndex, category)
  category = category or "items"
  local item = assert(project.categories[category] and project.categories[category][itemId], "Item inexistente: " .. tostring(itemId))
  local group = assert(item.groups[groupIndex or 1], "Grupo inexistente")
  return item, group, category
end

function M.getItemSprite(project, itemId, groupIndex, slot, category)
  local item, g, cat = itemGroup(project, itemId, groupIndex, category)
  assert(g.spriteIds[slot] ~= nil, "Posição de sprite inexistente")
  -- JSON metadata decodes integral values as Lua floats. Numeric slots 1 and
  -- 1.0 must address the same change even though tostring differs.
  local key = string.format("%s:%d:%d:%d", cat, item.id, groupIndex or 1, slot)
  return project.changes[key] and project.changes[key].rgba or M.decodeSprite(project, g.spriteIds[slot])
end

function M.setItemSprite(project, itemId, groupIndex, slot, rgba, category)
  local item, g, cat = itemGroup(project, itemId, groupIndex, category)
  assert(g.spriteIds[slot] ~= nil, "Posição de sprite inexistente")
  assert(type(rgba) == "string" and #rgba == 4096, "A sprite precisa conter 4096 bytes RGBA")
  if not project.flags.transparency then
    for p = 4, #rgba, 4 do local a = rgba:byte(p); assert(a == 0 or a == 255, "O SPR sem transparência não aceita alpha parcial") end
  end
  local key = string.format("%s:%d:%d:%d", cat, item.id, groupIndex or 1, slot)
  if rgba == M.decodeSprite(project, g.spriteIds[slot]) then project.changes[key] = nil
  else project.changes[key] = {category = cat, itemId = itemId, groupIndex = groupIndex or 1, slot = slot, rgba = rgba, position = g.spritePositions[slot]} end
  project.revision = project.revision + 1
end

function M.changeCount(project)
  local n = 0; for _ in pairs(project.changes) do n = n + 1 end; return n
end

local function encodeSprite(rgba, transparency)
  local parts, p = {}, 1
  while p <= 4096 do
    local skip = 0
    while p <= 4096 and rgba:byte(p + 3) == 0 do skip = skip + 1; p = p + 4 end
    if p > 4096 then break end
    local start = p
    while p <= 4096 and rgba:byte(p + 3) ~= 0 do p = p + 4 end
    local run = (p - start) // 4
    parts[#parts + 1] = string.pack("<I2I2", skip, run)
    if transparency then parts[#parts + 1] = rgba:sub(start, p - 1)
    else for q = start, p - 1, 4 do parts[#parts + 1] = rgba:sub(q, q + 2) end end
  end
  return table.concat(parts)
end

-- Rewrites only sprite IDs in DAT, preserving all raw metadata and durations.
-- New SPR IDs isolate edits from every other thing that shares the old sprite.
function M.build(project)
  local changes = {}
  for _, c in pairs(project.changes) do changes[#changes + 1] = c end
  table.sort(changes, function(a,b) return a.position < b.position end)
  if #changes == 0 then return project.datBytes, project.sprBytes, 0 end
  local additions, byPixels, nextId = {}, {}, project.spriteCount
  local datParts, last = {}, 1
  for _, c in ipairs(changes) do
    local id = byPixels[c.rgba]
    if not id then
      local encoded = encodeSprite(c.rgba, project.flags.transparency)
      if #encoded == 0 then id = 0
      else
        nextId = nextId + 1; id = nextId
        assert(project.flags.extended or nextId <= 65535, "Limite de IDs SPR atingido")
        additions[#additions + 1] = "\255\0\255" .. string.pack("<I2", #encoded) .. encoded
      end
      byPixels[c.rgba] = id
    end
    datParts[#datParts + 1] = project.datBytes:sub(last, c.position - 1)
    datParts[#datParts + 1] = string.pack(project.flags.extended and "<I4" or "<I2", id)
    last = c.position + (project.flags.extended and 4 or 2)
  end
  datParts[#datParts + 1] = project.datBytes:sub(last)
  local extraCount = nextId - project.spriteCount
  if extraCount == 0 then return table.concat(datParts), project.sprBytes, 0 end
  local shift = extraCount * 4
  local sprParts = {string.pack("<I4", project.sprSignature), string.pack(project.flags.extended and "<I4" or "<I2", nextId)}
  for id = 1, project.spriteCount do
    local address = project.spriteAddresses[id]
    sprParts[#sprParts + 1] = string.pack("<I4", address == 0 and 0 or address + shift)
  end
  local nextAddress = #project.sprBytes + shift
  for _, raw in ipairs(additions) do
    sprParts[#sprParts + 1] = string.pack("<I4", nextAddress); nextAddress = nextAddress + #raw
  end
  sprParts[#sprParts + 1] = project.sprBytes:sub(project.sprHeaderSize + project.spriteCount * 4 + 1)
  for _, raw in ipairs(additions) do sprParts[#sprParts + 1] = raw end
  return table.concat(datParts), table.concat(sprParts), extraCount
end

function M.export(project, outputDir)
  assert(type(outputDir) == "string" and outputDir ~= "", "Informe uma pasta de exportação")
  assert(normalized(outputDir) ~= normalized(project.directory), "Exporte para uma pasta separada dos recursos originais")
  local dat, spr, count = M.build(project)
  local result = {datPath = join(outputDir, basename(project.datPath)), sprPath = join(outputDir, basename(project.sprPath)),
    otfiPath = join(outputDir, basename(project.otfiPath)), changedSprites = count, changedSlots = M.changeCount(project)}
  local outputs = {{result.datPath, dat}, {result.sprPath, spr}, {result.otfiPath, project.otfiBytes}}
  local token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999))
  -- Stage all three files before touching any existing output.
  local staged = {}
  local ok, err = pcall(function()
    for _, pair in ipairs(outputs) do
      for _, source in ipairs({project.datPath, project.sprPath, project.otfiPath}) do
        assert(normalized(pair[1]) ~= normalized(source), "A exportação não pode substituir os recursos originais")
      end
      local tmp = pair[1] .. ".tmp-" .. token
      local f = assert(io.open(tmp, "wb"), "Não foi possível gravar em " .. outputDir .. ". Crie a pasta e confira a permissão.")
      staged[#staged + 1] = tmp
      local written, writeError = f:write(pair[2]); local closed, closeError = f:close()
      assert(written and closed, tostring(writeError or closeError))
    end
  end)
  if not ok then for _, path in ipairs(staged) do os.remove(path) end; error(err) end
  local backups, committed = {}, {}
  ok, err = pcall(function()
    for i, pair in ipairs(outputs) do
      local existing = io.open(pair[1], "rb")
      if existing then
        existing:close(); local backup = pair[1] .. ".bak-" .. token
        assert(os.rename(pair[1], backup)); backups[i] = backup
      end
      assert(os.rename(staged[i], pair[1])); committed[i] = true
    end
  end)
  if not ok then
    for i, pair in ipairs(outputs) do
      if committed[i] then os.remove(pair[1]) end
      if backups[i] then os.rename(backups[i], pair[1]) end
      os.remove(staged[i])
    end
    error("Falha na exportação; arquivos anteriores restaurados: " .. tostring(err))
  end
  result.backups = backups
  return result
end

return M
