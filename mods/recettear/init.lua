-- recettear — a Recettear crossover for Fortune Summoners (loader api 1.12).
--
-- Recette and Tear open a branch of their item shop behind Arche's family shop:
--   * a NEW DOOR in the storeroom behind the shop (210141) leads to "Recettear, Tonkiness Branch" (a new room)
--   * Recette, Tear and their customers are drawn with their own sprites and speak with their own portraits —
--     converted ONCE from the user's own copy of Recettear by setup.lua (the loader asks first); nothing of
--     either game ships with the mod
--   * the shop itself is in shop.lua's place below: wholesale from Tear, the counter, haggling, merchant levels
local SFX
local S, SND, SPR, ACT, MAPS = mod.game.script, mod.game.sound, mod.game.sprites, mod.game.actors, mod.game.maps
local fs, image = mod.fs, mod.image
local ffi = require('ffi')
local BASE_CELL_H = 96                         -- a townsperson's sprite cell (the base type of the whole cast)

if not mod.setup.done then
  return mod.log('the first-time setup has not completed: the mod stays off (it is offered again at the next start)')
end
local chunk, lerr = loadfile(mod.data_dir .. 'assets.lua')
if not chunk then return mod.log('assets.lua: ' .. tostring(lerr)) end
local A = chunk()

local BACK, BACK_MAP = 210141, 1026            -- the storeroom behind Arche's family shop (DATA 1026, 20 x 20)
local HOUSE_MAP = 1025
local SHOP, SHOP_MAP = 210146, 4010            -- ours: an unused room id + an unused DATA id
local DOOR_ZONE = 6                            -- the storeroom's new zone (retail uses 2 and 3 there)
local FLOOR = 576                              -- the ground floor's walk line, px
local RECETTE_X = 330                          -- where Recette stands (a map record's x = her sprite cell's left)
local DOOR_X = 768 + 40                        -- the branch's door (the storeroom's, 10 columns further right)
local CELLAR, CELLAR_MAP = 210147, 4011        -- the cellar under the branch (a fight room: town rules off)
local H = { RECETTE = 991001, TEAR = 991002, HATCH = 991003 }
local CODE = { recette = 50970, tear = 50971, slime = 51970, mushroom = 51971 }

-- ── sprites: one bank per converted character, made on first use ─────────────────────────────────────────────────
local banks, clips, faces = {}, {}, {}
-- The engine hangs a character's sprite by its BASE type's cell (a townsperson: 80 x 96): the body is centred in
-- that cell and stands on its bottom row.  A converted sheet has its own, usually smaller, cell — drawn as is it
-- floats above the floor by the difference — so each cell is re-set into one at least as large as the base's,
-- bottom-centred.
local function recell(ix, cw, ch, W, Hh)
  if W == cw and Hh == ch then return ix end
  local cols, rows = math.floor(ix.w / cw), math.floor(ix.h / ch)
  local out = { w = cols * W, h = rows * Hh, pal = ix.pal, px = ffi.new('uint8_t[?]', cols * W * rows * Hh) }
  local ox, oy = math.floor((W - cw) / 2), Hh - ch
  for r = 0, rows - 1 do
    for c = 0, cols - 1 do
      for y = 0, ch - 1 do
        ffi.copy(out.px + ((r * Hh + oy + y) * out.w + c * W + ox), ix.px + ((r * ch + y) * ix.w + c * cw), cw)
      end
    end
  end
  return out
end
-- fill = true (monsters): the sheet takes the BASE's whole layout — as many cells, the same mirror offset — with
-- the converted frames repeated through it.  The base's own AI keeps playing its retail clips (hop, attack, hurt),
-- whose frame numbers must exist in the bank: a cell past the sheet's end is a null frame, and the engine draws
-- without checking (it crashed in the first cellar test).
local function char_bank(name, like, fill)
  if banks[name] == nil then
    local info = A.chars[name]
    local ix = info and image.unpack_indexed(fs.read(mod.data_dir .. 'chr_' .. name .. '.osi') or '')
    local b, err
    if ix then
      local base = SPR.bank(like)
      local W, Hh = math.max(info.cell_w, base and base.cell_w or 0), math.max(info.cell_h, base and base.cell_h or 0)
      local sheet, mirror = recell(ix, info.cell_w, info.cell_h, W, Hh), info.n
      local like_img = fill and SPR.sheet(like)
      if like_img and base.mirror > 0 then
        local lcols = math.floor(like_img.w / base.cell_w)
        local total = lcols * math.floor(like_img.h / base.cell_h)
        local scols = math.floor(sheet.w / W)
        local out = { w = lcols * W, h = math.ceil(total / lcols) * Hh, pal = sheet.pal }
        out.px = ffi.new('uint8_t[?]', out.w * out.h)
        for k = 0, total - 1 do
          local f = k < base.mirror and (k % info.n) or (info.n + (k - base.mirror) % info.n)
          local sx, sy = (f % scols) * W, math.floor(f / scols) * Hh
          local dx, dy = (k % lcols) * W, math.floor(k / lcols) * Hh
          for y = 0, Hh - 1 do ffi.copy(out.px + (dy + y) * out.w + dx, sheet.px + (sy + y) * sheet.w + sx, W) end
        end
        sheet, mirror = out, base.mirror
      end
      b, err = SPR.new_bank { like = like, image = sheet, cell_w = W, cell_h = Hh, mirror = mirror }
    end
    banks[name] = b or false
    if not b then mod.log(('no sprite for %s: %s'):format(name, tostring(err or 'not converted'))) end
  end
  return banks[name] or nil
end
-- Recettear's animations → this game's clips (same unit: ticks per frame at 60 a second)
local function char_clips(name)
  if not clips[name] then
    local t = {}
    for i, a in ipairs(A.chars[name].anims) do
      local fr = {}
      for k = 1, math.min(#a.frames, 32) do fr[k] = a.frames[k] end
      local opts = { frames = fr, dur = a.dur[1] or 10, loop = not a.hold }
      if (A.chars[name].lift or 0) > 0 then               -- a hovering fairy bobs
        opts.dy = {}
        for k = 1, #fr do opts.dy[k] = (k % 2 == 0) and -2 or 0 end
      end
      t[i] = SPR.clip(opts)
    end
    clips[name] = t
  end
  return clips[name]
end
-- portraits: a 24-bit bank of 160 x 176 busts per character, like the game's own (the first such bank = the model)
local face_like
local function face_bank(name)
  if faces[name] == nil then
    faces[name] = false
    if not face_like then
      for i = 1, SPR.capacity().retail - 1 do
        local b = SPR.bank(i)
        if b and b.cell_w == 160 and b.cell_h == 176 then face_like = i break end
      end
    end
    local raw = A.faces[name] and fs.read(mod.data_dir .. 'face_' .. name .. '.bmp')
    local img = raw and image.decode(raw)
    if img and face_like then
      img:key(255, 0, 255)
      local b, err = SPR.new_bank { like = face_like, image = img, cell_w = 160, cell_h = 176 }
      faces[name] = b or false
      if not b then mod.log(('no portrait for %s: %s'):format(name, tostring(err))) end
    end
  end
  return faces[name] or nil
end

-- ── the maps ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- The storeroom: its wall is 2-column plain panels with one 4-column door panel (113035 frame 11, columns 13–16).
-- Columns 3–4 are plain on every floor, so repeating them twice makes the room 4 columns longer without touching
-- anything that is there (objects to the right move along with their walls); the two new panels on the ground floor
-- become a second door panel.
local function edit_storeroom(m)
  local door_cell = m:cell(0, 13, 13)
  assert(door_cell[2] == 113035 and door_cell[4] == 11, 'storeroom: unexpected wall panels')
  m:widen(3, 2, 2)
  local plain = m:cell(0, 13, 5)
  m:set_cell(0, 13, 5, { door_cell[1], door_cell[2], door_cell[3], door_cell[4], plain[5], 0, 0 })
  m:set_cell(0, 13, 7, { 0, 0, 0, 0, 0, 0, 0 })
  m:add_door { like = 2, zone = DOOR_ZONE, x = 5 * 32 + 32 }
end
local function build_shop()
  local m = assert(MAPS.read(BACK_MAP))
  local house = assert(MAPS.read(HOUSE_MAP))
  m:widen(3, 2, 5)                                         -- 30 columns
  -- the storeroom's ground-floor things go (the walls, floors and both doors stay); upstairs stays as it is, inert
  m:filter(function(o)
    local r = o.rec
    return r[5] == 70102 or r[3] < 400
  end)
  for _, o in ipairs(m.objs) do
    if o.rec[5] >= 70000 and o.rec[5] ~= 70102 and #o.A >= 2 then o.A[2] = 0 end
  end
  local npc = assert(house:find(function(o) return o.rec[5] == 50240 end), 'house map: no townswoman record')
  -- shop furniture from the family shop next door: the goods shelves and their jars (structures 60521 / 60522 and
  -- the shelf devices, minus their examine handles), moved to the left half of the room
  for _, o in ipairs(house.objs) do
    local r = o.rec
    if r[3] >= 400 and r[2] >= 256 and r[2] < 440 and (r[5] == 60521 or r[5] == 60522 or r[5] == 70364 or r[5] == 70260) then
      local c = MAPS.clone(o)
      c.rec[2] = r[2] - 256 + 96
      if #c.A >= 2 then c.A[2] = 0 end
      m:add(c)
    end
  end
  m:add_character { like = npc, code = CODE.recette, x = RECETTE_X, floor = FLOOR, cell_h = math.max(BASE_CELL_H, A.chars.recette.cell_h), handle = H.RECETTE, facing = 'right' }
  m:add_character { like = npc, code = CODE.tear, x = RECETTE_X - 72, floor = FLOOR, cell_h = math.max(BASE_CELL_H, A.chars.tear.cell_h), handle = H.TEAR, facing = 'right' }
  return m
end
-- the cellar: the same shell, emptied (the fights happen on the ground floor)
local function build_cellar()
  local m = assert(MAPS.read(BACK_MAP))
  m:widen(3, 2, 5)
  m:filter(function(o) return o.rec[5] == 70102 or o.rec[3] < 400 end)
  for _, o in ipairs(m.objs) do
    if o.rec[5] >= 70000 and o.rec[5] ~= 70102 and #o.A >= 2 then o.A[2] = 0 end
  end
  return m
end

-- ── the save: everything the branch remembers lives in story flags (saved with the game) ────────────────────────
local FL = mod.game.flags.story
local F = { XP = 991000001, LOAN = 991000002, SALES = 991000003, INTRO = 991000004, TRAFFIC = 991000005,
            BEST = 991000006, CELLAR = 991000007, KIT = 991000008, STOCK = 992000000 }
local function fget(id) local v = FL.get(id) return v or 0 end
local function fset(id, v) FL.set(id, v, v == 0 and 0 or 1) end        -- (v, v2) = (0, 0) clears the flag
local function stock(id) return fget(F.STOCK + id) end
local function set_stock(id, n) fset(F.STOCK + id, math.max(0, n)) end

local LEVELS = { 0, 60, 200, 500, 1100, 2400 }                           -- merchant xp → level 1..6
local function level()
  local xp, l = fget(F.XP), 1
  for i, need in ipairs(LEVELS) do if xp >= need then l = i end end
  return l, xp, LEVELS[l + 1]
end
local TIER_CAP = { 120, 500, 1600, 5000, 14000, 1e9 }                     -- the dearest item Tear will order, by level
local function wholesale_pct() return 72 - 2 * level() end                -- 70 % of the list price, down to 60 %
local LOAN = { 1500, 6000, 20000, 50000 }                                 -- CP; the last one pays the branch off

-- money: 1 gold = 10 silver = 100 copper (the HUD counts copper)
local function money(cp)
  cp = math.floor(cp + 0.5)
  if cp >= 100 and cp % 100 == 0 then return ('%d G'):format(cp / 100) end
  if cp >= 100 then return ('%d G %d c'):format(math.floor(cp / 100), cp % 100) end
  return ('%d c'):format(cp)
end
local function gold() return (mod.game.items.gold()) or 0 end
local function pay(cp) mod.game.items.set_gold(gold() - cp) end

-- the goods: what the game's own shops could sell (a price, not a story item, not clothes)
local GOODS, BY_ID
local CATS = { { 'Food and medicine', 200000, 209999 }, { 'Weapons', 110000, 119999 }, { 'Armour and accessories', 120000, 169999 } }
local function goods()
  if not GOODS then
    GOODS, BY_ID = {}, {}
    for _, it in ipairs(mod.game.items.catalog() or {}) do
      if it.price and it.price >= 5 and it.id >= 110000 and it.id <= 209999 and it.name ~= '' then
        for c, cat in ipairs(CATS) do
          if it.id >= cat[2] and it.id <= cat[3] then
            local g = { id = it.id, name = it.name, price = it.price, cat = c }
            GOODS[#GOODS + 1] = g; BY_ID[it.id] = g
          end
        end
      end
    end
    table.sort(GOODS, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
  end
  return GOODS, BY_ID
end
local function in_stock()
  local t = {}
  for _, g in ipairs(goods()) do local n = stock(g.id) if n > 0 then t[#t + 1] = { g = g, n = n } end end
  return t
end

-- ── who is in the room ───────────────────────────────────────────────────────────────────────────────────────────
local function actor_by_handle(h) for _, a in ipairs(ACT.list() or {}) do if a.handle == h then return a end end end
local function vp(p) return ffi.cast('void *', p) end
local function body_of(p) return mod.mem.read_u32(p + 0x40) end
local function place(p, x, y) local b = body_of(p) mod.mem.write_i32(b + 4, x) if y then mod.mem.write_i32(b + 8, y) end end
local function body_x(p) return mod.mem.read_i32(body_of(p) + 4) end
local function face(p, dir) mod.mem.write_u32(body_of(p) + 0x2c, dir > 0 and 1 or 3) end
local function anim(p, name, i, as_stand)
  local c = char_clips(name)[i]
  if not (p and c) then return end
  if as_stand then SPR.set_clips(p, { stand = c }) end
  SPR.play(p, c)
end
-- a line with the speaker's own portrait: who = 'recette' | 'tear' | a customer {kind, name, ptr}
local function say(s, who, text, frame)
  local name, kind, ptr
  if who == 'recette' or who == 'tear' then
    local a = actor_by_handle(who == 'recette' and H.RECETTE or H.TEAR)
    name, kind, ptr = who == 'recette' and 'Recette' or 'Tear', who, a and a.ptr
  else
    name, kind, ptr = who.name, who.face, who.ptr
  end
  local bank = kind and face_bank(kind)
  if frame and A.faces[kind] and frame >= A.faces[kind] then frame = 0 end
  return s:say(text, { name = name, actor = ptr and vp(ptr) or nil, portrait = bank, frame = frame or 0 })
end

-- ── Tear: the wholesale order, the loan ──────────────────────────────────────────────────────────────────────────
local function order_menu(s, cat)
  local lvl = level()
  local list = {}
  for _, g in ipairs(goods()) do
    if g.cat == cat and g.price <= TIER_CAP[lvl] then list[#list + 1] = g end
  end
  if #list == 0 then say(s, 'tear', 'Nothing in that line that the guild will sell us yet.') return end
  local page, per = 1, 13
  while true do
    local rows, map = {}, {}
    for i = (page - 1) * per + 1, math.min(#list, page * per) do
      local g = list[i]
      rows[#rows + 1] = ('%-22s %7s  (%d)'):format(g.name:sub(1, 22), money(g.price * wholesale_pct() / 100), stock(g.id))
      map[#rows] = g
    end
    local more = #list > per
    if more then rows[#rows + 1] = '... more' end
    rows[#rows + 1] = 'Back'
    local c = s:choose(rows, { w = 420 })
    if not c or c == #rows then return end
    if more and c == #rows - 1 then
      page = page * per >= #list and 1 or page + 1
    else
      local g = map[c]
      local each = math.max(1, math.floor(g.price * wholesale_pct() / 100 + 0.5))
      local q = s:choose({ ('1 for %s'):format(money(each)), ('5 for %s'):format(money(each * 5)),
                           ('10 for %s'):format(money(each * 10)), 'Never mind' }, { w = 260 })
      local n = ({ 1, 5, 10 })[q or 4]
      if n then
        if gold() < each * n then
          say(s, 'tear', 'You cannot afford that. I do not extend credit twice.', 2)
        else
          pay(each * n); set_stock(g.id, stock(g.id) + n)
          s:sound(SFX.coin)
          say(s, 'tear', ('%d x %s, on the shelves. You have %d now.'):format(n, g.name, stock(g.id)), 1)
        end
      end
    end
  end
end
local function loan_menu(s)
  local paid = fget(F.LOAN)
  if paid >= #LOAN then say(s, 'tear', 'The branch is paid off. Terme Finance thanks you for your custom.', 1) return end
  local due = LOAN[paid + 1]
  say(s, 'tear', ('Instalment %d of %d on the branch\'s loan is %s. You are carrying %s.'):format(paid + 1, #LOAN, money(due), money(gold())))
  local c = s:choose({ ('Pay %s'):format(money(due)), 'Not yet' }, { w = 240 })
  if c ~= 1 then return end
  if gold() < due then say(s, 'tear', 'That is not enough. Sell more.', 2) return end
  pay(due); fset(F.LOAN, paid + 1)
  s:sound(SFX.fanfare)
  if paid + 1 < #LOAN then
    say(s, 'tear', 'Received, with thanks. As agreed, the guild will send us one more customer each time we open.', 1)
    say(s, 'recette', 'Yayifications! One step closer to not being in debt!', 4)
  else
    say(s, 'tear', 'That was the last one. The Tonkiness branch is yours, free and clear.', 1)
    say(s, 'recette', 'We did it! Capitalism, ho!', 4)
    local best
    for _, g in ipairs(goods()) do if g.cat == 3 and g.price <= 12000 then best = g end end
    if best then
      say(s, 'tear', 'A small token from head office, for our best franchisee.')
      s:give(best.id, 1)
    end
  end
end
-- ── Recettear's own items, as new items of this game (loader api 1.12) ─────────────────────────────────────────────
-- Each is a new item row (items.define: nothing of the game's is replaced) cloned from the game's own item of that
-- kind, with Recettear's name, description, numbers and icon (read from the user's Recettear by setup.lua).  The ids
-- are 70400000 + Recettear's item number (70400 = its Steam app): what saves store, so they never change.  A save
-- holding one, loaded without this mod, loses those items (the game drops records of unknown items).
local IT = { longsword = 70400002, windbreaker = 70401002, sandwich = 70404014, ferromin = 70404101, strong = 70404109 }
local ITEM_DEFS = {
  -- key, Recettear id, the game's item it works like, what changes (price: Recettear's pix over the divisor)
  { 'longsword', 2, 110010, function(r) return { attack = r.atk, price = math.floor(r.price / 2) } end },        -- Bronze Sword
  { 'windbreaker', 1002, 120010, function(r) return { defense = r.def, price = math.floor(r.price / 2) } end },  -- Cloth Armor
  { 'sandwich', 4014, 201010, function(r)                                                                          -- Herb: HP a + b*rand
      return { use = { a = r.atk, b = 0 }, price = math.floor(r.price / 50), note = ('Restores %d HP.'):format(r.atk) } end },
  { 'ferromin', 4101, 202010, function(r)                                                                          -- Power Drop: a stat for good
      return { use = { a = 5, b = 5, c = 5 }, price = math.floor(r.price / 10), note = 'Max HP +5 to 9, for good.' } end },
  { 'strong', 4109, 202010, function(r)
      return { use = { a = 1, b = 2, c = 2 }, price = math.floor(r.price / 50), note = 'Attack +2 or 3, for good.' } end },
}
local function define_items()
  local I = mod.game.items
  if not (I and I.define) then return mod.log('items: this loader has no items.define (api 1.12)') end
  if not A.items then return mod.log('items: setup data from before items (re-run the setup)') end
  local raw = fs.read(mod.data_dir .. 'items.bmp')
  local sheet = raw and image.decode(raw)
  if sheet then sheet:key(255, 0, 255) end
  local n = 0
  for _, d in ipairs(ITEM_DEFS) do
    local r = A.items[tostring(d[2])]
    if r then
      local t = d[4](r)
      t.id, t.like, t.name = IT[d[1]], d[3], r.name
      t.desc = t.note and (r.desc .. ' ' .. t.note) or r.desc
      t.note = nil
      if sheet and r.icon then t.icon = sheet:crop(r.icon * 32, 0, 32, 32) end
      local ok, err = I.define(t)
      if ok then n = n + 1 else mod.log(('items: %s: %s'):format(d[1], tostring(err))) end
    end
  end
  mod.log(('items: %d of Recettear\'s items defined'):format(n))
end

-- the starter kit Tear hands over (in the first-visit scene; once per save — saves from before 0.2 get it from her)
local KIT = { { 'longsword', 1 }, { 'windbreaker', 1 }, { 'sandwich', 3 }, { 'strong', 1 }, { 'ferromin', 1 } }
local function give_kit(s)
  if fget(F.KIT) ~= 0 or not (mod.game.items.defined and mod.game.items.defined(IT.longsword)) then return end
  fset(F.KIT, 1)
  say(s, 'tear', 'First, a starter kit from our own stock. No merchant of ours goes adventuring bare-handed.')
  for _, k in ipairs(KIT) do s:give(IT[k[1]], k[2]) end
  say(s, 'recette', 'A real Recettear longsword! Ooh, and sandwiches! Can I have one?', 4)
  say(s, 'tear', 'No.')
end

local function tear_talk(s)
  local a = actor_by_handle(H.TEAR)
  if a then anim(a.ptr, 'tear', 4) end                                     -- her notebook
  give_kit(s)                                                              -- a save from before 0.2: the kit now
  say(s, 'tear', 'Yes? Stock, or the loan?')
  while true do
    local rows
    rows = { CATS[1][1], CATS[2][1], CATS[3][1], 'The loan', 'How are we doing?', 'That is all' }
    local c = s:choose(rows, { w = 300 })
    if not c or c == 6 then break end
    if c <= 3 then order_menu(s, c)
    elseif c == 4 then loan_menu(s)
    else
      local l, xp, nxt = level()
      local sold, takings = FL.get(F.SALES)
      say(s, 'tear', ('Merchant level %d (%d xp%s). %d sales so far, %s taken at the counter.'):format(
        l, xp, nxt and (', ' .. (nxt - xp) .. ' to the next') or '', sold or 0, money((takings or 0))))
      say(s, 'tear', ('Wholesale is %d%% of the list price at your level. Best run of first-offer sales: %d.'):format(wholesale_pct(), fget(F.BEST)))
    end
  end
  if a then anim(a.ptr, 'tear', 1) end
end

-- ── customers ────────────────────────────────────────────────────────────────────────────────────────────────────
-- max = the most they will pay, % of the list price (± spread, rolled per visit); patience = how many prices they
-- will listen to; budget in CP; likes = the categories they shop for; from = the merchant level they start coming at
local KINDS = {
  { key = 'girl', name = 'Little Girl', max = 108, spread = 5, patience = 2, budget = 400, likes = { 1 }, from = 1,
    hi = 'Um, excuse me! Do you have %s?', ok = 'Yay! Thank you!', high = 'That is more than my allowance...',
    offer = 'I have %s. Is that okay?', bye = 'I will go ask my mum for more pocket money...' },
  { key = 'woman', name = 'Townswoman', max = 122, spread = 6, patience = 3, budget = 4000, likes = { 1, 3 }, from = 1,
    hi = 'Good day. I am after %s.', ok = 'Lovely. I will take it.', high = 'Oh my, that is rather dear.',
    offer = 'Would you take %s for it?', bye = 'I will try the market instead.' },
  { key = 'man', name = 'Townsman', max = 127, spread = 6, patience = 3, budget = 9000, likes = { 1, 2, 3 }, from = 1,
    hi = 'Afternoon. Got %s in?', ok = 'Fair enough. Sold.', high = 'Steady on, that is a bit steep.',
    offer = 'I could go to %s.', bye = 'No, I will leave it. Good day.' },
  { key = 'oldman', name = 'Old Gentleman', max = 134, spread = 7, patience = 3, budget = 20000, likes = { 1, 3 }, from = 2,
    hi = 'Ah, young lady. I should like %s, if you please.', ok = 'Splendid. Here you are.', high = 'In my day that cost a third as much!',
    offer = 'Shall we say %s?', bye = 'Hmph. I will take my custom elsewhere.' },
  { key = 'louie', name = 'Louie', max = 103, spread = 4, patience = 2, budget = 350, likes = { 2, 1 }, from = 2,
    hi = 'Hey! I need %s for my next adventure!', ok = 'Awesome! Thanks a bunch!', high = 'Aw, man, I am kinda broke right now...',
    offer = 'All I have got is %s...', bye = 'Guess I am adventuring without it. Again.' },
  { key = 'guild', name = 'Guild Master', max = 116, spread = 4, patience = 4, budget = 60000, likes = { 2, 3, 1 }, from = 3,
    hi = 'I am buying for the guild today. %s, please.', ok = 'A fair price. Done.', high = 'I know what these cost, miss.',
    offer = 'The guild pays %s for those.', bye = 'Then we have no business today.' },
  { key = 'charme', name = 'Charme', max = 131, spread = 8, patience = 2, budget = 30000, likes = { 2, 3 }, from = 3,
    hi = 'Hey there, cutie. Show me %s.', ok = 'Mm, I like it. Wrap it up.', high = 'Ooh, trying to rob a thief? Bold.',
    offer = 'How about %s, and I owe you a drink?', bye = 'Too rich for my blood. Later!' },
  { key = 'alouette', name = 'Alouette', max = 175, spread = 15, patience = 2, budget = 1e9, likes = { 3, 2 }, from = 4,
    hi = 'You there. I require %s. Do try to keep up.', ok = 'Hmph. A trifle. Have it sent round.', high = 'Do you take me for a fool?',
    offer = 'I shall pay %s and not a pix more.', bye = 'What a dreary little shop. Elan! We are leaving.' },
}
local shop = { open = false, queue = 0, cust = nil, combo = 0, made = 0, sold = 0, wait = 0, rng = nil, next_kind = nil }
local function rnd(a, b) return (shop.rng or math.random)(a, b) end
local function pick_kind()
  if shop.next_kind then for _, k in ipairs(KINDS) do if k.key == shop.next_kind then return k end end end
  local lvl, ok = level(), {}
  for _, k in ipairs(KINDS) do if k.from <= lvl and A.chars[k.key] then ok[#ok + 1] = k end end
  return ok[rnd(1, #ok)]
end
-- what they came for: something in stock they could pay for at list price, their favourite lines first
local function pick_want(kind)
  local st = in_stock()
  for _, cat in ipairs(kind.likes) do
    local fit = {}
    for _, e in ipairs(st) do if e.g.cat == cat and e.g.price <= kind.budget then fit[#fit + 1] = e.g end end
    if #fit > 0 then return fit[rnd(1, #fit)] end
  end
end
local PCT = { 90, 100, 105, 110, 115, 120, 125, 130, 135, 140, 150, 160, 180, 200 }
local function round_price(v) return math.max(1, math.floor(v + 0.5)) end
local function add_xp(n)
  local before = level()
  fset(F.XP, fget(F.XP) + n)
  return level() > before
end
-- the counter: Recettear's rule of thumb — every customer has a price they will pay without a word (their
-- maximum, a percentage of the list price); name one just under it for the bonus ("near pin"), one a little over
-- it and they counter-offer, far over it and they lose patience.  Sales on the first price build a combo.
local function haggle(s)
  local c = shop.cust
  if not c then return end
  local kind, g = c.kind, c.want
  local recette = actor_by_handle(H.RECETTE)
  local who = { name = kind.name, face = A.faces[kind.key] and kind.key or nil, ptr = c.ptr }
  if not g or stock(g.id) < 1 then
    say(s, who, 'Hm. Nothing I need today. Maybe next time.')
    c.result = 'none'
    return
  end
  say(s, who, kind.hi:format(g.name))
  local maxp = kind.max + rnd(-kind.spread, kind.spread)
  local patience, first, offer = kind.patience, true, nil
  while true do
    local rows = {}
    for i, p in ipairs(PCT) do rows[i] = ('%3d%%   %s'):format(p, money(round_price(g.price * p / 100))) end
    rows[#rows + 1] = 'Sorry, not for sale'
    say(s, 'recette', ('(%s. List price %s. What shall I ask?)'):format(g.name, money(g.price)), 3)
    local pick = s:choose(rows, { w = 250, default = 4, no_cancel = true })
    if not pick or pick > #PCT then
      say(s, who, kind.bye, 1)
      c.result = 'none'; shop.combo = 0
      return
    end
    local pct = PCT[pick]
    local price = round_price(g.price * pct / 100)
    local over = pct - maxp
    if price > kind.budget and over <= 0 then over = 6 end              -- would pay the rate, has not got the money
    if over <= 0 then
      -- sold
      set_stock(g.id, stock(g.id) - 1)
      mod.game.items.set_gold(gold() + price)
      local sold, takings = FL.get(F.SALES)
      FL.set(F.SALES, (sold or 0) + 1, (takings or 0) + price)
      shop.made, shop.sold = shop.made + price, shop.sold + 1
      local xp, note = 10, nil
      if first then
        shop.combo = shop.combo + 1
        xp = xp * math.min(8, 2 ^ (shop.combo - 1))
        if shop.combo > fget(F.BEST) then fset(F.BEST, shop.combo) end
        if shop.combo > 1 then note = ('Combo x%d!'):format(shop.combo) end
      else
        shop.combo = 0
      end
      local pin = over > -5 and pct >= 100
      if pin then xp = xp + 15 end
      s:sound(SFX.coin)
      if recette then anim(recette.ptr, 'recette', 5) end
      say(s, who, kind.ok, 1)
      local up = add_xp(xp)
      s:narrate(('Sold: %s for %s (%d%%).%s%s  +%d merchant xp'):format(g.name, money(price), pct,
        pin and '  Near pin!' or '', note and ('  ' .. note) or '', xp))
      if pin then say(s, 'recette', 'Capitalism, ho!', 4) end
      if up then
        s:sound(SFX.fanfare)
        say(s, 'tear', ('Merchant level %d. The guild will let us order better stock now.'):format((level())), 1)
      end
      c.result = 'sold'
      return
    end
    first = false
    patience = patience - (over > 14 and 2 or 1)
    if patience <= 0 then
      say(s, who, kind.high, 1)
      say(s, who, kind.bye, 1)
      c.result = 'left'; shop.combo = 0
      return
    end
    if over > 14 then
      say(s, who, kind.high, 1)
    else
      -- a counter-offer: a little under their maximum, a little closer to it each round
      local op = math.max(90, maxp - 6 + 3 * (kind.patience - patience - 1))
      offer = math.min(round_price(g.price * op / 100), kind.budget)
      say(s, who, kind.high, 1)
      say(s, who, kind.offer:format(money(offer)))
      local d = s:choose({ ('Deal at %s'):format(money(offer)), 'Name another price', 'No deal' }, { w = 260, no_cancel = true })
      if d == 1 then
        set_stock(g.id, stock(g.id) - 1)
        mod.game.items.set_gold(gold() + offer)
        local sold, takings = FL.get(F.SALES)
        FL.set(F.SALES, (sold or 0) + 1, (takings or 0) + offer)
        shop.made, shop.sold, shop.combo = shop.made + offer, shop.sold + 1, 0
        s:sound(SFX.coin)
        say(s, who, kind.ok, 1)
        local up = add_xp(6)
        s:narrate(('Sold: %s for %s.  +6 merchant xp'):format(g.name, money(offer)))
        if up then say(s, 'tear', ('Merchant level %d.'):format((level())), 1) end
        c.result = 'sold'
        return
      elseif d == 3 then
        say(s, who, kind.bye, 1)
        c.result = 'left'; shop.combo = 0
        return
      end
    end
  end
end

-- one customer at a time: in through the door, up to the counter, the haggle, out again
local COUNTER_GAP = 5600                                   -- centi-px between Recette and a customer at the counter
local WALK = 90                                            -- centi-px a tick
local function spawn_customer()
  local kind = pick_kind()
  if not kind then return end
  local slot = ACT.spawn(kind.code, { x = DOOR_X * 100, y = FLOOR * 100, facing = 3 })
  if not slot then return end
  local row
  for _, a in ipairs(ACT.list() or {}) do if a.slot == slot then row = a end end
  if not row then return end
  shop.cust = { kind = kind, slot = slot, ptr = row.ptr, h = row.h, state = 'in', want = pick_want(kind) }
  face(row.ptr, -1)
  anim(row.ptr, kind.key, 2, true)
  SND.play(SFX.bell)
end
local function customer_tick()
  local c = shop.cust
  if not c then return end
  local recette = actor_by_handle(H.RECETTE)
  local target = (recette and recette.x or RECETTE_X * 100) + COUNTER_GAP
  -- feet on the line Recette stands on (a spawned body starts above the floor and only settles when left alone)
  local top = recette and (recette.y + recette.h - c.h) or nil
  if c.state == 'in' then
    local x = body_x(c.ptr) - WALK
    if x <= target then
      x = target
      c.state = 'talk'
      anim(c.ptr, c.kind.key, 1, true)
      if recette then face(recette.ptr, 1) end
      S.run(function(s) haggle(s) c.state = 'out' end, { what = 'recettear haggle' })
    end
    place(c.ptr, x, top)
  elseif c.state == 'out' then
    if not c.turned then
      c.turned = true; face(c.ptr, 1); anim(c.ptr, c.kind.key, 2, true)
      if recette then anim(recette.ptr, 'recette', 1) end
    end
    local x = body_x(c.ptr) + WALK
    place(c.ptr, x, top)
    if x >= DOOR_X * 100 then
      ACT.remove(c.slot)
      shop.cust = nil
      shop.wait = 90
    end
  end
end
local function close_up(s)
  local tr = actor_by_handle(H.RECETTE)
  if tr then anim(tr.ptr, 'recette', 1, true) end
  if shop.sold > 0 then
    say(s, 'recette', ('That is everyone for now! %d sold, %s in the till.'):format(shop.sold, money(shop.made)), 4)
  else
    say(s, 'recette', 'That is everyone for now. Not our best day...', 2)
  end
  say(s, 'tear', 'Customers come back once word gets around. Go and be seen around the kingdom, then open again.')
end
local function shop_tick()
  local m = mod.game.map.get()
  if not m or m.area ~= SHOP then
    if shop.open or shop.cust then shop.open, shop.cust, shop.queue = false, nil, 0 end   -- left: the actors went with the room
    return
  end
  if not shop.open then return end
  if shop.cust then return customer_tick() end
  if shop.wait > 0 then shop.wait = shop.wait - 1 return end
  if shop.queue > 0 and #in_stock() > 0 then
    shop.queue = shop.queue - 1
    spawn_customer()
  else
    shop.open, shop.queue = false, 0
    S.run(close_up, { what = 'recettear closing' })
  end
end

-- foot traffic: customers come back as the party is seen around — one point per room entered, 3 a customer
local last_area
local function traffic_frame()
  local m = mod.game.map.get()
  local area = m and m.area
  if area and area ~= last_area then
    if last_area and area ~= SHOP and area ~= BACK and area ~= CELLAR then
      fset(F.TRAFFIC, math.min(60, fget(F.TRAFFIC) + 1))
    end
    last_area = area
  end
end

-- ── Recette ──────────────────────────────────────────────────────────────────────────────────────────────────────
local function take_home(s)
  local st = in_stock()
  if #st == 0 then say(s, 'recette', 'The shelves are empty!', 2) return end
  local page, per = 1, 13
  while true do
    st = in_stock()
    local rows, map = {}, {}
    for i = (page - 1) * per + 1, math.min(#st, page * per) do
      rows[#rows + 1] = ('%-24s x%d'):format(st[i].g.name:sub(1, 24), st[i].n); map[#rows] = st[i].g
    end
    if #rows == 0 then return end
    local more = #st > per
    if more then rows[#rows + 1] = '... more' end
    rows[#rows + 1] = 'Back'
    local c = s:choose(rows, { w = 340 })
    if not c or c == #rows then return end
    if more and c == #rows - 1 then page = page * per >= #st and 1 or page + 1
    else
      local g = map[c]
      if s:give(g.id, 1) then set_stock(g.id, stock(g.id) - 1) end       -- the game's own "obtained" / "bag is full"
    end
  end
end
local wave = { on = false, slots = nil, typed = 0 }
local function recette_talk(s)
  local me = actor_by_handle(H.RECETTE)
  if shop.open then
    say(s, 'recette', 'We are open! Stand by the counter, a customer will be along.', 1)
    local c = s:choose({ 'Keep going', 'Close up for now' }, { w = 240 })
    if c == 2 then shop.queue = 0 end
    return
  end
  say(s, 'recette', 'Welcome to Recettear, Tonkiness branch! What are we doing?', 1)
  while true do
    local c = s:choose({ 'Open the shop', 'Take stock home', 'The cellar...', 'How does this work?', 'See you' }, { w = 280 })
    if c == 1 then
      local st = in_stock()
      local visitors = math.floor(fget(F.TRAFFIC) / 3)
      if #st == 0 then
        say(s, 'recette', 'We have nothing to sell! Tear does the ordering. Ask her for stock.', 2)
      elseif visitors < 1 then
        say(s, 'recette', 'Nobody is about just now. Go out and about for a bit and they will come by!', 2)
      else
        local n = math.min(visitors, 2 + level() + fget(F.LOAN), shop.max_customers or 99)   -- (max_customers: a test knob)
        fset(F.TRAFFIC, fget(F.TRAFFIC) - 3 * n)
        shop.open, shop.queue, shop.combo, shop.made, shop.sold, shop.wait = true, n, 0, 0, 0, 60
        if me then anim(me.ptr, 'recette', 4) end
        s:sound(SFX.fanfare)
        say(s, 'recette', ('Opening up! %d customer%s on the way. Capitalism, ho!'):format(n, n == 1 and '' or 's'), 4)
        return
      end
    elseif c == 2 then
      take_home(s)
    elseif c == 3 then
      say(s, 'recette', 'There is something squishy living down there and it keeps eating the stock.', 2)
      say(s, 'recette', 'If you clear it out, you can keep whatever it has not chewed on yet!', 1)
      if s:yes_no() then
        wave.on, wave.slots = true, nil
        S.after(function() mod.game.map.warp(CELLAR, 2, true) end)
        return
      end
    elseif c == 4 then
      say(s, 'recette', 'Tear orders stock from the guild at wholesale. We sell it at the counter for more. That is the whole trick!', 1)
      say(s, 'tear', 'Each customer has a price they will pay without arguing. Ask just under it and they are delighted. Ask a little over and they haggle.')
      say(s, 'tear', 'Ask far too much and they walk out. Sales on your first price build a combo, and experience makes you a better merchant.')
      say(s, 'recette', 'And customers only come back after people have seen you out and about. So go adventuring, then come and sell!', 4)
    else
      break
    end
  end
  say(s, 'recette', 'Come back soon!', 4)
end

-- the first visit
local function intro(s)
  fset(F.INTRO, 1)
  s:pause(40)
  say(s, 'recette', 'A customer! Welcome to Recettear, Tonkiness branch! ...Oh. You live here?', 1)
  say(s, 'tear', 'Good day. I am Tear, of Terme Finance. This is Recette. Her father\'s loan is the reason we are in your storeroom.')
  say(s, 'recette', 'Your dad said we could use the back room if we kept out of his way. Is he not the nicest?', 4)
  say(s, 'tear', 'We are opening a branch here. You know this town and you can carry things. We could use a hand at the counter.')
  say(s, 'recette', 'I do the selling, Tear does the sums, and you get a cut of everything you sell. Capitalism, ho!', 4)
  give_kit(s)
end

-- ── the cellar: Recettear's slimes and mushrooms as monsters of this game ────────────────────────────────────────
local function cellar_tick()
  local m = mod.game.map.get()
  if not m or m.area ~= CELLAR then
    if wave.slots then wave.slots, wave.typed = nil, 0 end
    return
  end
  if mod.game.map.event() or not wave.on then return end
  if not wave.slots then
    wave.slots, wave.typed = {}, 0
    local n = 2 + math.min(3, fget(F.CELLAR))
    for i = 1, n do
      local code = (i % 3 == 0) and CODE.mushroom or CODE.slime
      local slot = ACT.spawn(code, { x = (160 + 110 * i) * 100, y = FLOOR * 100, facing = 1 })
      if slot then wave.slots[#wave.slots + 1] = slot; wave.typed = wave.typed + 1 end
    end
    return
  end
  if wave.typed > 0 then return end
  local alive = {}
  for _, a in ipairs(ACT.list() or {}) do alive[a.slot] = true end
  for _, sl in ipairs(wave.slots) do if alive[sl] then return end end
  wave.on, wave.slots = false, nil
  fset(F.CELLAR, fget(F.CELLAR) + 1)
  S.run(function(s)
    s:sound(SFX.fanfare)
    s:narrate('The cellar is quiet. Behind the crates: stock the slimes had not got to yet.')
    local pool, lvl = {}, level()
    for _, g in ipairs(goods()) do if g.cat == 1 and g.price <= TIER_CAP[lvl] then pool[#pool + 1] = g end end
    for _ = 1, 3 do
      local g = pool[rnd(1, #pool)]
      if g then set_stock(g.id, stock(g.id) + 2); s:narrate(('2 x %s went up to the shelves.'):format(g.name)) end
    end
    fset(F.TRAFFIC, math.min(60, fget(F.TRAFFIC) + 3))
    s:narrate('Leave through the door to go back up.')
  end, { what = 'recettear cellar reward' })
end

-- ── sounds (synthesized: nothing shipped) ────────────────────────────────────────────────────────────────────────
SFX = {}
local function make_sounds()
  local RATE = 22050
  local function tones(notes, vol)
    local out = {}
    for _, n in ipairs(notes) do
      local len = math.floor(n[2] * RATE)
      for i = 1, len do
        local t = i / RATE
        local env = math.min(1, i / 120) * math.exp(-5 * t / n[2])
        out[#out + 1] = n[1] == 0 and 0 or (vol or 0.3) * env * (math.sin(2 * math.pi * n[1] * t) + 0.35 * math.sin(4 * math.pi * n[1] * t))
      end
    end
    return SND.add(SND.wav(out, RATE))
  end
  SFX.coin = tones({ { 1975.5, 0.07 }, { 2637, 0.3 } }, 0.28)                                    -- B6 E7: a till
  SFX.bell = tones({ { 1568, 0.16 }, { 1318.5, 0.34 } }, 0.22)                                   -- the door bell
  SFX.fanfare = tones({ { 523.3, 0.1 }, { 659.3, 0.1 }, { 784, 0.1 }, { 1046.5, 0.45 } }, 0.3)
end

-- ── install ──────────────────────────────────────────────────────────────────────────────────────────────────────
local function define(name, code, base, display, extra)
  local cl = char_clips(name)
  local d = { code = code, base = base, name = display,
    bank = function(p) return char_bank(name, mod.mem.read_u16(p + 0x48)) end,
    clips = { stand = cl[1], walk = cl[2] or cl[1], run = cl[2] or cl[1] } }
  for k, v in pairs(extra or {}) do d[k] = v end
  assert(ACT.define(d))
end
local function install()
  assert(MAPS.edit(BACK_MAP, edit_storeroom, 'recettear'))
  assert(MAPS.define(SHOP_MAP, build_shop, 'recettear'))
  assert(MAPS.define(CELLAR_MAP, build_cellar, 'recettear'))
  assert(mod.game.map.add_room { key = SHOP, like = BACK, map = SHOP_MAP })
  assert(mod.game.map.add_room { key = CELLAR, like = BACK, map = CELLAR_MAP, town = false })
  assert(mod.game.map.set_exit(BACK, DOOR_ZONE, SHOP, 2))
  assert(mod.game.map.set_exit(SHOP, 2, BACK, DOOR_ZONE))
  assert(mod.game.map.set_exit(SHOP, 3, BACK, DOOR_ZONE))
  assert(mod.game.map.set_exit(CELLAR, 2, SHOP, 2))
  assert(mod.game.map.set_exit(CELLAR, 3, SHOP, 2))
  make_sounds()
  define_items()
  define('recette', CODE.recette, 50240, 'Recette')
  define('tear', CODE.tear, 50240, 'Tear')
  local code = 50972
  for _, k in ipairs(KINDS) do
    if A.chars[k.key] then k.code = code; define(k.key, code, 50240, k.name); code = code + 1 end
  end
  local function monster(name, c, display, hp, drops)     -- a slime underneath: its body, AI and clips; our sheet in its layout
    if not A.chars[name] then return end
    assert(ACT.define { code = c, base = 51010, name = display, hp = hp, drops = drops,
      bank = function(p) return char_bank(name, mod.mem.read_u16(p + 0x48), true) end,
      on_death = function() wave.typed = math.max(0, wave.typed - 1) end })
  end
  -- what they drop (per mille; the first through the game's own drop roll): Recettear's items
  monster('slime', CODE.slime, 'Slime', 40, { { id = IT.sandwich, chance = 350 }, { id = IT.strong, chance = 60 } })
  monster('mushroom', CODE.mushroom, 'Walking Mushroom', 70, { { id = IT.ferromin, chance = 250 }, { id = IT.sandwich, chance = 250 } })
  S.on_talk(H.RECETTE, recette_talk, { name = 'Recette' })
  S.on_talk(H.TEAR, tear_talk, { name = 'Tear' })
  S.on_tick(function() shop_tick() cellar_tick() end)
  mod.on_frame(function()
    traffic_frame()
    local m = mod.game.map.get()
    if not m or m.area ~= SHOP then shop.intro_queued = false return end      -- asked again on the next visit (another save?)
    if not shop.intro_queued and not mod.game.map.event() then
      if fget(F.INTRO) ~= 0 then shop.intro_queued = true return end   -- seen in this save: no flag read per frame
      shop.intro_queued = true
      S.run(intro, { what = 'recettear intro' })
    end
  end)
  if mod.config.get('music') ~= false and A.music and A.music.shop then
    SND.room_music(SHOP, mod.data_dir .. 'bgm_shop.wav')   -- at the game's music volume, levelled to its tracks
  end
  mod.log(('installed: storeroom door (zone %d) -> the branch (room %d), cellar %d; %d goods'):format(DOOR_ZONE, SHOP, CELLAR, #goods()))
end
_G.recettear = { A = A, IT = IT, SHOP = SHOP, BACK = BACK, CELLAR = CELLAR, H = H, CODE = CODE, F = F, shop = shop, wave = wave,
                 level = level, stock = stock, set_stock = set_stock, fget = fget, fset = fset, goods = goods,
                 in_stock = in_stock, KINDS = KINDS, banks = banks, faces = faces, face_bank = face_bank }
install()
