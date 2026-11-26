-- recettear/setup.lua — the one-time setup step (the loader asks the user before it ever runs; see MOD-FORMAT
-- "First-time setup").  Finds the user's own Recettear, reads what the mod needs out of its archive and writes it,
-- converted for this game, to mod.data_dir.  Nothing of Recettear ships with the mod.
--
-- Recettear's archive (the format is documented by the recettear-repacker project and OpenRecet):
--   lnkdatas.bin   big-endian: int32 count, then 140-byte entries {name[128], size, offset, packed size}
--   bin\dataNNN.bin  10 MiB slices of one stream; each entry is LZSS-packed on its own
-- Character sprites: bmp/chr/chrNN.bmp is an atlas of 32 x 32 cells; bmp/chr/formdata.bin says which cells make
-- which 128 x 128 frame; idx/<name>.idx lists the animations (five facings per frame; the last is the side view,
-- the one a side-scroller wants).
local ffi = require('ffi')
local fs, image = mod.fs, mod.image
local band, bor, lshift = bit.band, bit.bor, bit.lshift
local floor, min, max = math.floor, math.min, math.max
local progress = mod.setup.progress
local OUT = mod.data_dir

-- ── find Recettear ───────────────────────────────────────────────────────────────────────────────────────────────
local function find_game()
  local dir = mod.config.get('recettear_dir')
  if type(dir) == 'string' and dir ~= '' then
    if not dir:match('[\\/]$') then dir = dir .. '\\' end
    if fs.exists(dir .. 'lnkdatas.bin') then return dir end
    error('The Recettear folder set in the mod\'s settings has no lnkdatas.bin:\n' .. dir, 0)
  end
  local app, why = mod.steam.app(70400, { dir = 'Recettear', marker = 'lnkdatas.bin' })
  if app then return app.dir end
  error('Recettear: An Item Shop\'s Tale was not found (' .. tostring(why) .. ').\n' ..
        'Install it through Steam, or put its folder in oss_mods.cfg as  recettear.recettear_dir=C:\\...\\Recettear', 0)
end

-- ── the archive ──────────────────────────────────────────────────────────────────────────────────────────────────
local function be32(s, o) local a, b, c, d = s:byte(o + 1, o + 4) return a * 16777216 + b * 65536 + c * 256 + d end
local SLICE = 10485760
local Arc = {}
Arc.__index = Arc
local function open_archive(dir)
  local idx = assert(fs.read(dir .. 'lnkdatas.bin'), 'cannot read lnkdatas.bin')
  local n = be32(idx, 0)
  assert(n > 0 and n < 100000 and #idx >= 4 + n * 140, 'lnkdatas.bin: unexpected layout')
  local a = setmetatable({ dir = dir, entries = {}, files = {} }, Arc)
  for i = 0, n - 1 do
    local o = 4 + i * 140
    local name = idx:sub(o + 1, o + 128):match('^[^%z]*'):lower():gsub('\\', '/')
    a.entries[name] = { size = be32(idx, o + 128), off = be32(idx, o + 132), packed = be32(idx, o + 136) }
  end
  a.count = n
  return a
end
function Arc:raw(off, len)
  local parts = {}
  while len > 0 do
    local k = floor(off / SLICE)
    local f = self.files[k]
    if not f then
      f = assert(io.open(('%sbin\\data%03d.bin'):format(self.dir, k), 'rb'), ('bin\\data%03d.bin is missing'):format(k))
      self.files[k] = f
    end
    local at = off - k * SLICE
    local take = min(len, SLICE - at)
    f:seek('set', at)
    local d = f:read(take)
    assert(d and #d == take, 'the archive is truncated')
    parts[#parts + 1] = d
    off, len = off + take, len - take
  end
  return table.concat(parts)
end
-- Recettear's LZSS: control bytes MSB first; 0 = a literal, 1 = (b1, b2): distance = (b1 & 0xF0) << 4 | b2 (0 ends
-- the stream), length = (b1 & 15) + 1, or (next byte + 17) when those bits are 0
local function lzss(src, nsrc, size)
  local out = ffi.new('uint8_t[?]', size + 64)
  local s = ffi.cast('const uint8_t *', src)
  local ip, op = 0, 0
  while ip < nsrc do
    local ctrl = s[ip]; ip = ip + 1
    local m = 128
    while m >= 1 do
      if band(ctrl, m) == 0 then
        if op >= size then return out, op end
        out[op] = s[ip]; ip = ip + 1; op = op + 1
      else
        local b1, b2 = s[ip], s[ip + 1]; ip = ip + 2
        local back = bor(lshift(band(b1, 0xF0), 4), b2)
        if back == 0 then return out, op end
        local len = band(b1, 15)
        if len == 0 then len = s[ip] + 16; ip = ip + 1 end
        len = len + 1
        if op + len > size then len = size - op end
        local from = op - back
        if from < 0 then error('lzss: bad back-reference', 0) end
        if back >= len then ffi.copy(out + op, out + from, len)
        else for i = 0, len - 1 do out[op + i] = out[from + i] end end
        op = op + len
      end
      m = m / 2
    end
  end
  return out, op
end
function Arc:read(name)
  local e = self.entries[name:lower()]
  if not e then return nil, name .. ' is not in the archive' end
  local buf, n = lzss(self:raw(e.off, e.packed), e.packed, e.size)
  if n ~= e.size then return nil, ('%s: unpacked %d of %d bytes'):format(name, n, e.size) end
  return ffi.string(buf, n)
end
function Arc:close() for _, f in pairs(self.files) do f:close() end self.files = {} end

-- ── character sprites ────────────────────────────────────────────────────────────────────────────────────────────
-- idx: line 1 sheet name, 2 atlas size, 3 frame size, 4 feet line, 5 scale, 6 facings; then blocks "/comment" +
-- lines "f1,f2,f3,f4,f5,duration" (one frame per facing; the last facing = the side view) | HALT (hold the last)
local function parse_idx(text)
  local lines = {}
  for l in (text:gsub('\r', '') .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
  local function num(i, k) local t = {} for v in (lines[i] or ''):gmatch('%-?%d+') do t[#t + 1] = tonumber(v) end return t[k or 1] end
  local d = { frame_w = num(3, 1) or 128, frame_h = num(3, 2) or 128, feet = num(4) or 112, facings = num(6) or 5, anims = {} }
  local cur
  for i = 7, #lines do
    local l = lines[i]
    if l:sub(1, 1) == '/' then
      cur = { frames = {}, dur = {}, hold = false }
      d.anims[#d.anims + 1] = cur
    elseif cur and l:match('^%s*HALT') then
      cur.hold = true
    elseif cur then
      local t = {}
      for v in l:gmatch('%d+') do t[#t + 1] = tonumber(v) end
      if #t >= d.facings + 1 then
        cur.frames[#cur.frames + 1] = t[d.facings]         -- the side view
        cur.dur[#cur.dur + 1] = t[d.facings + 1]
      end
    end
  end
  local keep = {}
  for _, a in ipairs(d.anims) do if #a.frames > 0 then keep[#keep + 1] = a end end
  d.anims = keep
  return d
end
local function be16(s, o) local a, b = s:byte(o + 1, o + 2) return a * 256 + b end
-- one frame: formdata[char] → base; base + 0x400 + 2f = cell count, + 0x600 + 2f = first atlas cell,
-- base + 0x800 + 2a = where atlas cell a goes in the frame (a grid of 32 px cells, frame_w / 32 a row)
local function compose(form, char, atlas, f, fw, fh)
  local base = be32(form, char * 4)
  if base + f * 2 + 0x602 > #form then return nil end
  local n, start = be16(form, base + f * 2 + 0x400), be16(form, base + f * 2 + 0x600)
  local out = image.new(fw, fh)
  local acols, per_row = floor(atlas.w / 32), floor(fw / 32)
  for i = 0, n - 1 do
    local a = start + i
    if base + a * 2 + 0x802 > #form then break end
    local pos = be16(form, base + a * 2 + 0x800)
    out:blit(atlas, (a % acols) * 32, floor(a / acols) * 32, 32, 32, (pos % per_row) * 32, floor(pos / per_row) * 32)
  end
  return out
end

-- name, Recettear's character slot (chrNN.bmp + formdata row), its idx file[, { lift = px }: empty rows under the
-- feet — a fairy that hovers that far above the floor her body stands on ]
local CHARS = {
  { 'recette', 0, 'recette' }, { 'tear', 1, 'tear', { lift = 40 } }, { 'louie', 29, 'rui_shop' }, { 'charme', 32, 'felm_shop' },
  { 'man', 10, 'mobu_men01' }, { 'youth', 35, 'mobu_yungmen01' }, { 'woman', 36, 'mobu_madam01' },
  { 'girl', 37, 'mobu_girl01' }, { 'oldman', 38, 'mobu_jisan01' }, { 'guild', 39, 'mobu_guild_m' },
  { 'alouette', 48, 'alouette' }, { 'euria', 43, 'euria' }, { 'prime', 66, 'prime' },
  { 'slime', 4, 'sraim' }, { 'mushroom', 18, 'kinoko' },
}
-- name, the portrait files (bmp/ivent/<file>.tga) = its expressions, in order
local FACES = {
  { 'recette', { '01recette_00', '01recette_01', '01recette_02', '01recette_03', '01recette_04', '01recette_05', '01recette_06' } },
  { 'tear', { '02tear_00', '02tear_01', '02tear_02', '02tear_03', '02tear_04', '02tear_05' } },
  { 'louie', { '03lui_00', '03lui_01', '03lui_02' } }, { 'charme', { '04charme_00', '04charme_01', '04charme_02' } },
  { 'alouette', { '11alouette_00', '11alouette_01' } }, { 'prime', { '12prime_00', '12prime_01' } },
  { 'euria', { '14eurya_00', '14eurya_01' } }, { 'guild', { '13syounin_00', '13syounin_01' } },
  { 'girl', { '21machi_00', '21machi_01' } }, { 'man', { '22machi_00', '22machi_01' } },
  { 'woman', { '25machi_00', '25machi_01' } }, { 'oldman', { '26machi_00', '26machi_01' } },
}
local MUSIC = { { 'shop', 'open.wav' }, { 'town', 'town.wav' } }
-- Items (setup 2): Recettear's own rows for the items the branch brings into this game, and their icons.
--   data/item.txt  one line per item:  NNNN:R#name+plural#price#atk#def#mt#mf#attrs#stock#audience#desc1#desc2
--                  (OpenRecet docs/formats/data-text.md; '/' in desc2 cuts it short)
--   bmp/item/itemCC.bmp  the icons of category CC = NNNN / 100: 32 x 32 cells, 8 a row, cell = NNNN % 100,
--                  key (0, 255, 0)
local ITEMS = { 2, 1002, 4014, 4101, 4109 }     -- Longsword, Windbreaker, Ham Sandwich, Ferromin, Strong Concoction
local function convert_items(arc)
  local txt = assert(arc:read('data/item.txt'))
  local want, rows = {}, {}                       -- rows by tostring(id) (assets.lua keys are strings)
  for _, id in ipairs(ITEMS) do want[id] = true end
  for line in txt:gmatch('[^\r\n]+') do
    local id = tonumber(line:match('^(%d%d%d%d):'))
    if id and want[id] then
      local f = {}
      for v in (line .. '#'):gmatch('([^#]*)#') do f[#f + 1] = v end
      local name, plural = (f[2] or ''):match('^%s*(.-)%s*$'), nil
      if name:find('+', 1, true) then name, plural = name:match('^(.-)%+(.*)$') end
      local function n(i) return tonumber((f[i] or ''):match('%-?%d+')) or 0 end
      local d1, d2 = (f[11] or ''), (f[12] or ''):gsub('/.*$', '')
      rows[tostring(id)] = { name = name, plural = plural or name, price = n(3), atk = n(4), def = n(5), mt = n(6), mf = n(7),
                   desc = (((d1:match('%-%s*$') and d1:gsub('%s+$', '') .. d2 or d1 .. ' ' .. d2)):gsub('%s+', ' '):match('^%s*(.-)%s*$')) }
    end
  end
  local atlases, sheet, k = {}, image.new(32 * #ITEMS, 32), 0
  for _, id in ipairs(ITEMS) do
    local r = rows[tostring(id)]
    if r then
      local cat = floor(id / 100)
      if not atlases[cat] then atlases[cat] = assert(image.decode(assert(arc:read(('bmp/item/item%02d.bmp'):format(cat))))):key(0, 255, 0) end
      local a, cell = atlases[cat], id % 100
      sheet:blit(a, (cell % 8) * 32, floor(cell / 8) * 32, 32, 32, k * 32, 0)
      r.icon = k
      k = k + 1
    end
  end
  assert(fs.write(OUT .. 'items.bmp', sheet:bmp()))          -- transparent = magenta
  return rows
end

local function lua_literal(v, ind)
  ind = ind or ''
  if type(v) == 'table' then
    local parts, n = {}, #v
    for i = 1, n do parts[#parts + 1] = lua_literal(v[i], ind .. ' ') end
    local keys = {}
    for k in pairs(v) do if not (type(k) == 'number' and k >= 1 and k <= n) then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do parts[#parts + 1] = ('[%q] = %s'):format(k, lua_literal(v[k], ind .. ' ')) end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
  elseif type(v) == 'string' then return ('%q'):format(v)
  else return tostring(v) end
end

local function convert_char(arc, form, c, scale)
  local name, slot, idxname = c[1], c[2], c[3]
  local d = parse_idx(assert(arc:read('idx/' .. idxname .. '.idx')))
  local atlas = assert(image.decode(assert(arc:read(('bmp/chr/chr%02d.bmp'):format(slot)))))
  local r, g, b = atlas:get(0, 0)                         -- the sheets' background colour (pure green) = transparent
  if not (g > 200 and r < 60 and b < 60) then r, g, b = 0, 255, 0 end
  atlas:key(r, g, b, 8)
  -- every distinct side-view frame, in order of first use
  local order, index = {}, {}
  for _, a in ipairs(d.anims) do
    for _, f in ipairs(a.frames) do
      if index[f] == nil then index[f] = #order; order[#order + 1] = f end
    end
  end
  local frames = {}
  local x0, y0, x1, y1 = d.frame_w, d.frame_h, -1, -1
  for i, f in ipairs(order) do
    local img = compose(form, slot, atlas, f, d.frame_w, d.frame_h) or image.new(d.frame_w, d.frame_h)
    frames[i] = img
    local a, b2, c2, e = img:bounds()
    if a then x0, y0, x1, y1 = min(x0, a), min(y0, b2), max(x1, c2), max(y1, e) end
  end
  if x1 < 0 then return nil, 'no pixels' end
  -- the cell: centred on the frame's centre line, from the highest pixel down to the lowest (the feet rest on the
  -- cell's bottom row, where this game hangs a body), sizes rounded up to 8
  local half = max(d.frame_w / 2 - x0, x1 + 1 - d.frame_w / 2)
  local cw = min(d.frame_w, math.ceil(half * 2 / 8) * 8)
  local bottom = y1 + 1
  local ch = min(bottom, math.ceil((bottom - y0) / 8) * 8)
  local cx, cy = floor(d.frame_w / 2 - cw / 2), bottom - ch
  ch = ch + (c[4] and c[4].lift or 0)
  local sw, sh = cw, ch
  if scale < 1 then sw, sh = max(8, floor(cw * scale / 8 + 0.5) * 8), max(8, floor(ch * scale / 8 + 0.5) * 8) end
  local n = #frames
  local cols = 8
  local rows = math.ceil(n * 2 / cols)
  local sheet = image.new(cols * sw, rows * sh)
  for i, img in ipairs(frames) do
    local cell = img:crop(cx, cy, cw, ch)                 -- native: facing left
    if scale < 1 then cell = cell:scale(sw, sh) end
    local right = cell:flip_h()
    local k = i - 1
    sheet:blit(right, 0, 0, sw, sh, (k % cols) * sw, floor(k / cols) * sh)                 -- 0 .. n-1: facing right
    k = k + n
    sheet:blit(cell, 0, 0, sw, sh, (k % cols) * sw, floor(k / cols) * sh)                  -- n .. 2n-1: facing left
  end
  local ix = image.quantize(sheet, { colors = 255 })
  assert(fs.write(OUT .. 'chr_' .. name .. '.osi', image.pack_indexed(ix)))
  local anims = {}
  for i, a in ipairs(d.anims) do
    local fr = {}
    for k, f in ipairs(a.frames) do fr[k] = index[f] end
    anims[i] = { frames = fr, dur = a.dur, hold = a.hold }
  end
  return { cell_w = sw, cell_h = sh, n = n, cols = cols, anims = anims, colors = ix.colors, lift = c[4] and c[4].lift or 0 }
end

-- a portrait: Recettear's are 512 x 512 full figures; this game's are 160 x 176 busts.  Take the figure's top
-- (320 x 352 around its centre line, from just above the head) at half size.
local function convert_face(arc, files)
  local cells = {}
  local ax, ay
  for i, f in ipairs(files) do
    local raw = arc:read('bmp/ivent/' .. f .. '.tga')
    if raw then
      local img = assert(image.decode(raw))
      if not ax then                                        -- one anchor for all of a character's expressions
        local x0, y0, x1 = img:bounds(64)
        if x0 then ax, ay = floor((x0 + x1) / 2) - 160, max(0, y0 - 12) else ax, ay = 96, 0 end
      end
      cells[#cells + 1] = img:crop(ax, ay, 320, 352):scale(160, 176)
    end
  end
  if #cells == 0 then return nil end
  local sheet = image.new(160 * #cells, 176)
  for i, c in ipairs(cells) do sheet:blit(c, 0, 0, 160, 176, (i - 1) * 160, 0) end
  return sheet, #cells
end

-- ── run ──────────────────────────────────────────────────────────────────────────────────────────────────────────
local t0 = os.clock()
progress(0, 'Looking for Recettear…')
local dir = find_game()
mod.log('setup: Recettear at ' .. dir)
local arc = open_archive(dir)
mod.log(('setup: archive index: %d files'):format(arc.count))
assert(fs.mkdir(OUT))
local scale = max(40, min(100, tonumber(mod.config.get('scale')) or 75)) / 100
local steps, step = #CHARS + #FACES + #MUSIC + 2, 0
local function tick(what) step = step + 1; progress(step / steps, what) end

tick('Reading the sprite layout table…')
local form = assert(arc:read('bmp/chr/formdata.bin'))
local meta = { version = 2, chars = {}, faces = {}, music = {}, items = {}, source = dir }
for _, c in ipairs(CHARS) do
  tick('Sprites: ' .. c[1])
  local ok, info, why = pcall(convert_char, arc, form, c, scale)
  if ok and info then
    meta.chars[c[1]] = info
    mod.log(('setup: %s: %d frames, cell %dx%d, %d colours, %d animations'):format(c[1], info.n, info.cell_w, info.cell_h, info.colors, #info.anims))
  else
    mod.log(('setup: %s skipped: %s'):format(c[1], tostring(ok and why or info)))
  end
end
assert(meta.chars.recette and meta.chars.tear, 'Recette\'s and Tear\'s sprites could not be read from this copy of Recettear')
for _, f in ipairs(FACES) do
  tick('Portraits: ' .. f[1])
  local ok, sheet, n = pcall(convert_face, arc, f[2])
  if ok and sheet then
    assert(fs.write(OUT .. 'face_' .. f[1] .. '.bmp', sheet:bmp()))
    meta.faces[f[1]] = n
  else
    mod.log(('setup: portrait %s skipped: %s'):format(f[1], tostring(sheet)))
  end
end
tick('Items…')
local okI, items = pcall(convert_items, arc)
if okI then
  meta.items = items
  local nI = 0 for _ in pairs(items) do nI = nI + 1 end
  mod.log(('setup: %d items (rows + icons)'):format(nI))
else
  mod.log('setup: items skipped: ' .. tostring(items))
end
arc:close()
for _, m in ipairs(MUSIC) do
  tick('Music: ' .. m[1])
  local src = dir .. 'bgm\\' .. m[2]
  local data = fs.read(src)
  if data and data:sub(1, 4) == 'RIFF' then
    assert(fs.write(OUT .. 'bgm_' .. m[1] .. '.wav', data))
    meta.music[m[1]] = #data
  else
    mod.log('setup: no music ' .. src)
  end
end
assert(fs.write(OUT .. 'assets.lua', 'return ' .. lua_literal(meta) .. '\n'))
progress(1, 'Done.')
mod.log(('setup: finished in %.1f s'):format(os.clock() - t0))
return true
