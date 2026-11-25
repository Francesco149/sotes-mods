#!/usr/bin/env python3
"""make_art.py — the testroom mod's ORIGINAL sprite sheets (no game data): writes bit.bmp (and slime.bmp) next to
the mod's init.lua as 8-bit indexed, uncompressed BMPs — the format mod.game.sprites.bmp reads.

  python3 mods/testroom/art/make_art.py          (needs Pillow)

Layout = the game's townsfolk sheets: 8 x 4 cells of 80 x 96 px, feet on the cell's bottom row, centred on x 40;
rows 2-3 are rows 0-1 mirrored (the bank's mirror offset 16 = facing left).  Index 0 (black) is transparent.

bit.bmp — "Bit", a clockwork robot:  frames 0-3 idle (bob + antenna blink), 4-7 wave, 8-15 walk.
"""
import math
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
CW, CH = 80, 96

PAL = [
    (0, 0, 0),          # 0 transparent
    (24, 22, 38),       # 1 outline
    (214, 226, 232),    # 2 metal light
    (150, 172, 186),    # 3 metal mid
    (92, 110, 128),     # 4 metal dark
    (34, 40, 58),       # 5 visor
    (120, 255, 236),    # 6 eye glow
    (40, 170, 160),     # 7 eye dim
    (255, 214, 90),     # 8 bulb
    (200, 120, 40),     # 9 bulb dark
    (220, 70, 70),      # 10 accent red
    (150, 40, 50),      # 11 accent dark
    (255, 250, 220),    # 12 highlight
    (60, 64, 80),       # 13 joint
]


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[0] * w for _ in range(h)]

    def set(self, x, y, c):
        x, y = int(math.floor(x + 0.5)), int(math.floor(y + 0.5))
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self.set(x, y, c)

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                    self.set(x, y, c)

    def rrect(self, x0, y0, x1, y1, r, c):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                dx = max(x0 + r - x, 0, x - (x1 - r))
                dy = max(y0 + r - y, 0, y - (y1 - r))
                if dx * dx + dy * dy <= r * r + 0.5:
                    self.set(x, y, c)

    def line(self, x0, y0, x1, y1, c, t=1):
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for i in range(n + 1):
            x = x0 + (x1 - x0) * i / n
            y = y0 + (y1 - y0) * i / n
            if t == 1:
                self.set(x, y, c)
            else:
                self.rect(x - t // 2, y - t // 2, x - t // 2 + t - 1, y - t // 2 + t - 1, c)

    def outline(self, c=1):
        src = [row[:] for row in self.px]
        for y in range(self.h):
            for x in range(self.w):
                if src[y][x] != 0:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < self.w and 0 <= yy < self.h and src[yy][xx] not in (0, c):
                        self.px[y][x] = c
                        break


def limb(cv, x0, y0, x1, y1):
    cv.line(x0, y0, x1, y1, 4, 4)
    cv.line(x0, y0, x1, y1, 3, 2)


def bit_frame(kind, f):
    """one 80x96 cell of Bit, facing right"""
    cv = Canvas(CW, CH)
    bob = 0
    wave = None
    step = None
    blink = False
    if kind == 'idle':
        bob = (0, 1, 1, 0)[f]
        blink = f == 2
    elif kind == 'wave':
        bob = (0, 1, 0, 1)[f]
        wave = (-55, -90, -125, -90)[f]
    elif kind == 'walk':
        ph = f / 8 * 2 * math.pi
        bob = 1 if f % 4 in (1, 2) else 0
        step = ph
    feet = 95
    hip = feet - 14 + bob
    cx = 40
    # legs
    if step is None:
        for lx in (cx - 6, cx + 6):
            limb(cv, lx, hip, lx, feet - 4)
            cv.rrect(lx - 4, feet - 4, lx + 5, feet, 1, 4)
            cv.rect(lx - 3, feet - 4, lx + 4, feet - 3, 3)
    else:
        for side, lx in ((0, cx - 5), (1, cx + 5)):
            s = math.sin(step + side * math.pi)
            fx = lx + 5 * s
            lift = max(0.0, math.cos(step + side * math.pi)) * 3
            limb(cv, lx, hip, fx, feet - 4 - lift)
            cv.rrect(fx - 4, feet - 4 - lift, fx + 5, feet - lift, 1, 4)
            cv.rect(fx - 3, feet - 4 - lift, fx + 4, feet - 3 - lift, 3)
    # body
    by0, by1 = hip - 22, hip
    cv.rrect(cx - 13, by0, cx + 13, by1, 4, 3)
    cv.rrect(cx - 13, by0, cx + 11, by1 - 3, 4, 2)
    cv.rect(cx - 13, by1 - 3, cx + 13, by1, 4)
    # chest emblem: a gear
    gx, gy = cx + 1, by0 + 10
    for a in range(8):
        ang = a * math.pi / 4
        cv.set(gx + 5 * math.cos(ang), gy + 5 * math.sin(ang), 11)
    cv.ellipse(gx, gy, 4, 4, 10)
    cv.ellipse(gx, gy, 1.5, 1.5, 12)
    # back arm (behind body: drawn first would be hidden; draw short stub)
    sx, sy = cx - 12, by0 + 6
    if step is not None:
        a = math.sin(step + math.pi) * 0.6
        limb(cv, sx, sy, sx - 2 + 7 * math.sin(a), sy + 12 * math.cos(a))
    # front arm
    fx0, fy0 = cx + 12, by0 + 6
    if wave is not None:
        elx, ely = fx0 + 8, fy0 - 2                    # elbow out to the side, forearm up and swinging
        ang = math.radians(wave)
        ex, ey = elx + 11 * math.cos(ang), ely + 11 * math.sin(ang)
        limb(cv, fx0, fy0, elx, ely)
        limb(cv, elx, ely, ex, ey)
        cv.ellipse(elx, ely, 2, 2, 13)
        cv.ellipse(ex, ey, 3.5, 3.5, 3)
        cv.set(ex - 1, ey - 1, 2)
    else:
        a = (math.sin(step) * 0.6) if step is not None else 0.15
        ex, ey = fx0 + 2 + 7 * math.sin(a), fy0 + 12 * math.cos(a)
        limb(cv, fx0, fy0, ex, ey)
        cv.ellipse(ex, ey, 3, 3, 3)
    cv.ellipse(fx0, fy0, 3, 3, 13)
    # neck + head
    hy1 = by0 - 1
    cv.rect(cx - 3, hy1 - 2, cx + 3, hy1 + 1, 13)
    hy0 = hy1 - 22
    cv.rrect(cx - 15, hy0, cx + 15, hy1 - 2, 6, 3)
    cv.rrect(cx - 15, hy0, cx + 13, hy1 - 5, 6, 2)
    cv.rect(cx - 14, hy0 + 2, cx - 12, hy0 + 4, 12)
    # visor + eyes (looking right)
    cv.rrect(cx - 9, hy0 + 6, cx + 14, hy0 + 16, 3, 5)
    if blink:
        cv.rect(cx - 1, hy0 + 11, cx + 3, hy0 + 11, 7)
        cv.rect(cx + 7, hy0 + 11, cx + 11, hy0 + 11, 7)
    else:
        cv.rrect(cx - 1, hy0 + 8, cx + 3, hy0 + 13, 1, 6)
        cv.rrect(cx + 7, hy0 + 8, cx + 11, hy0 + 13, 1, 6)
        cv.set(cx, hy0 + 9, 12)
        cv.set(cx + 8, hy0 + 9, 12)
    # cheek light
    cv.rect(cx + 10, hy0 + 17, cx + 12, hy0 + 18, 10)
    # ear bolt
    cv.ellipse(cx - 15, hy0 + 11, 2.5, 3.5, 4)
    # antenna
    cv.line(cx - 2, hy0, cx - 4, hy0 - 8, 4)
    lit = kind != 'idle' or f in (0, 1)
    cv.ellipse(cx - 4, hy0 - 10, 3, 3, 8 if lit else 9)
    if lit:
        cv.set(cx - 5, hy0 - 11, 12)
    cv.outline(1)
    return cv


def sheet(frames):
    """frames: list of 16 Canvas (row 0 = 0..7, row 1 = 8..15); rows 2-3 = mirrored"""
    im = Image.new('P', (CW * 8, CH * 4), 0)
    flat = []
    for c in PAL:
        flat += list(c)
    flat += [0, 0, 0] * (256 - len(PAL))
    im.putpalette(flat)
    for i, cv in enumerate(frames):
        cell = Image.new('P', (CW, CH), 0)
        cell.putdata([v for row in cv.px for v in row])
        x, y = (i % 8) * CW, (i // 8) * CH
        im.paste(cell, (x, y))
        im.paste(cell.transpose(Image.FLIP_LEFT_RIGHT), (x, y + 2 * CH))
    return im


def save_bmp(im, path):
    im.save(path, format='BMP')
    print('wrote', path, im.size)


# ── the Glitch Cube: a monster in the slime's sheet layout (4 x 12 cells of 80 x 80, mirror +24) ──────────────────
# Pose slots (what the slime's own clips / skills show there): 0-2 idle, 3 unused, 4-7 squash before a hop,
# 8 stretch (take-off), 9 land, 10-11 airborne, 12-13 leap, 14 idle, 15 lunge, 16-19 attack, 20-21 hit / flatten,
# 22 the death burst.  Baseline = the cell's bottom row, centred on x 40.
CUBE_PAL = [
    (0, 0, 0),          # 0 transparent
    (30, 16, 46),       # 1 outline
    (176, 120, 236),    # 2 front
    (120, 74, 190),     # 3 side / shade
    (222, 196, 255),    # 4 top
    (255, 255, 255),    # 5 shine
    (40, 230, 255),     # 6 glitch cyan
    (255, 60, 200),     # 7 glitch magenta
    (24, 20, 40),       # 8 eye
    (90, 50, 150),      # 9 deep shade
    (255, 120, 120),    # 10 mouth
]
CC = 80


def cube(cv, cx, bottom, w, h, shear=0.0, eyes='open', glitch=0, spikes=0, seed=0):
    """a cube of front face w x h (bottom-centred at cx, bottom), a top face of depth d, a side face to the left
    (it faces right), sheared forward by `shear` px at the top; spikes = length of the attack spikes (front)"""
    d = max(3, int(min(w, h) * 0.22))
    x0 = cx - w // 2
    y0 = bottom - h + 1
    def sx(y):  # shear offset at row y
        return shear * (bottom - y) / max(1, h + d)
    # side (back) face: a parallelogram to the left
    for y in range(int(y0 - d), int(bottom) + 1):
        for x in range(int(x0 - d), int(x0) + 1):
            # inside the side face if below its top edge and above its bottom edge
            t = x0 - x
            if y >= y0 - t and y <= bottom - t * 0.5:
                cv.set(x + sx(y), y, 3)
    # top face
    for y in range(int(y0 - d), int(y0) + 1):
        t = y0 - y
        for x in range(int(x0 - t), int(x0 + w - t)):
            cv.set(x + sx(y), y, 4)
    # front face
    for y in range(int(y0), int(bottom) + 1):
        for x in range(int(x0), int(x0 + w)):
            c = 2
            if y > bottom - max(2, h // 6):
                c = 3
            cv.set(x + sx(y), y, c)
    # shine
    for i in range(min(6, w // 4)):
        cv.set(x0 + 3 + i + sx(y0 + 3), y0 + 3, 5)
    cv.set(x0 + 3 + sx(y0 + 4), y0 + 4, 5)
    cv.set(x0 + 3 + sx(y0 + 5), y0 + 5, 5)
    # face (towards the front-right)
    ey = y0 + h * 0.38
    ex1, ex2 = x0 + w * 0.55, x0 + w * 0.82
    for ex in (ex1, ex2):
        if eyes == 'open':
            cv.rect(ex - 2 + sx(ey), ey - 3, ex + 1 + sx(ey), ey + 3, 8)
            cv.set(ex - 1 + sx(ey), ey - 2, 5)
        elif eyes == 'angry':
            cv.rect(ex - 2 + sx(ey), ey - 1, ex + 1 + sx(ey), ey + 3, 8)
            cv.line(ex - 3 + sx(ey), ey - 4, ex + 2 + sx(ey), ey - 2, 8)
        elif eyes == 'x':
            cv.line(ex - 2 + sx(ey), ey - 2, ex + 2 + sx(ey), ey + 2, 8)
            cv.line(ex - 2 + sx(ey), ey + 2, ex + 2 + sx(ey), ey - 2, 8)
        else:  # closed
            cv.rect(ex - 2 + sx(ey), ey, ex + 2 + sx(ey), ey, 8)
    my = y0 + h * 0.62
    if eyes == 'angry':
        cv.rect(ex1 + 1 + sx(my), my, ex2 - 1 + sx(my), my + 2, 8)
        cv.rect(ex1 + 2 + sx(my), my + 1, ex2 - 2 + sx(my), my + 1, 10)
    elif eyes != 'x':
        cv.rect(ex1 + 3 + sx(my), my, ex2 - 3 + sx(my), my, 8)
    # spikes out of the front face
    if spikes:
        for k, yy in enumerate((y0 + h * 0.3, y0 + h * 0.55, y0 + h * 0.8)):
            ln = spikes * (1.0, 0.8, 1.0)[k]
            bx = x0 + w + sx(yy)
            for i in range(int(ln)):
                half = max(0, int(3 * (1 - i / max(1, ln))))
                for j in range(-half, half + 1):
                    cv.set(bx + i, yy + j, 6 if i > ln * 0.6 else 2)
    # glitch: displaced rows + stray pixels
    rnd = (seed * 2654435761) & 0xffffffff
    for _ in range(glitch):
        rnd = (rnd * 1103515245 + 12345) & 0x7fffffff
        gy = y0 + rnd % max(1, h)
        rnd = (rnd * 1103515245 + 12345) & 0x7fffffff
        off = (rnd % 7) - 3
        row = [cv.px[int(gy)][x] if 0 <= int(gy) < cv.h else 0 for x in range(cv.w)]
        for x in range(cv.w):
            if row[x]:
                cv.set(x + off, gy, row[x])
        rnd = (rnd * 1103515245 + 12345) & 0x7fffffff
        cv.set(x0 + w + 2 + rnd % 5, gy, 6 if rnd & 1 else 7)
        cv.set(x0 - d - 3 - rnd % 4, gy + 2, 7 if rnd & 1 else 6)


def cube_frame(i):
    cv = Canvas(CC, CC)
    B = CC - 1
    if i in (0, 1, 2, 3, 14):
        k = {0: 0, 1: 1, 2: 2, 3: 0, 14: 1}[i]
        cube(cv, 40, B, (40, 42, 44)[k], (38, 36, 34)[k], glitch=1 if k == 2 else 0, seed=i)
    elif i in (4, 5, 6, 7):
        w, h = {4: (52, 26), 5: (50, 28), 6: (46, 32), 7: (40, 40)}[i]
        cube(cv, 40, B, w, h, eyes='closed' if i == 4 else 'open')
    elif i == 8:
        cube(cv, 40, B, 30, 56, seed=8, glitch=2)
    elif i == 9:
        cube(cv, 40, B, 46, 32)
    elif i in (10, 11):
        cube(cv, 40, B - (8, 11)[i - 10], (36, 40)[i - 10], (42, 38)[i - 10])
    elif i in (12, 13):
        cube(cv, 38, B - 6, 34, 52, shear=(10, 14)[i - 12], eyes='angry', glitch=2, seed=i)
    elif i == 15:
        cube(cv, 36, B, 42, 38, shear=10, eyes='angry')
    elif i in (16, 17, 18, 19):
        sh, sp = {16: (6, 0), 17: (-4, 0), 18: (8, 14), 19: (10, 26)}[i]
        cube(cv, 32, B, 40, 40 if i != 17 else 46, shear=sh, eyes='angry', spikes=sp, glitch=1, seed=i)
    elif i == 20:
        cube(cv, 40, B, 54, 24, eyes='x', glitch=3, seed=20)
    elif i == 21:
        cube(cv, 40, B, 66, 12, eyes='x', glitch=4, seed=21)
    elif i == 22:
        for k, (cx, bb, s) in enumerate(((22, B, 16), (56, B - 6, 14), (40, B - 20, 12))):
            cube(cv, cx, bb, s, s, eyes='x' if k == 0 else 'closed', glitch=2, seed=30 + k)
    if i == 3:
        pass
    cv.outline(1)
    return cv


def cube_sheet():
    im = Image.new('P', (CC * 4, CC * 12), 0)
    flat = []
    for c in CUBE_PAL:
        flat += list(c)
    flat += [0, 0, 0] * (256 - len(CUBE_PAL))
    im.putpalette(flat)
    for i in range(24):
        cv = cube_frame(i)
        cell = Image.new('P', (CC, CC), 0)
        cell.putdata([v for row in cv.px for v in row])
        x, y = (i % 4) * CC, (i // 4) * CC
        im.paste(cell, (x, y))
        im.paste(cell.transpose(Image.FLIP_LEFT_RIGHT), (x, y + 6 * CC))
    return im


def main():
    frames = [bit_frame('idle', f) for f in range(4)] + [bit_frame('wave', f) for f in range(4)]
    frames += [bit_frame('walk', f) for f in range(8)]
    im = sheet(frames)
    save_bmp(im, os.path.join(OUT, 'bit.bmp'))
    cim = cube_sheet()
    save_bmp(cim, os.path.join(OUT, 'cube.bmp'))
    if '--png' in sys.argv:
        im.convert('RGB').resize((im.width * 2, im.height * 2), Image.NEAREST).save(os.path.join(HERE, 'bit_preview.png'))
        cim.convert('RGB').resize((cim.width * 2, cim.height * 2), Image.NEAREST).save(os.path.join(HERE, 'cube_preview.png'))


if __name__ == '__main__':
    main()
