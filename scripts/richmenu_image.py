"""Starfish dark-theme Rich Menu: 2500x843, three tap areas (開團 / 缺人場次 / 我的揪團).

Usage: python scripts/richmenu_image.py web/liff/richmenu.jpg <starfishlarp>/pwa/icon-512.png
Colors follow the starfishlarp site theme (index.css); fonts are Windows Noto Serif/Sans TC.
"""
import math, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2500, 843
OUT = Path(sys.argv[1])
EMBLEM = Path(sys.argv[2])
BLACK, DARK, SURFACE = (8, 6, 3), (16, 12, 7), (26, 20, 13)
GOLD, GOLD_L, GOLD_D = (200, 160, 86), (236, 208, 138), (122, 94, 44)
CRIM = (139, 26, 26)
TEXT_D = (154, 138, 108)

def font(name, size, weight=None):
    f = ImageFont.truetype(f'C:/Windows/Fonts/{name}', size)
    if weight:
        try: f.set_variation_by_axes([weight])
        except Exception: pass
    return f

serif = lambda s: font('NotoSerifTC-VF.ttf', s, 900)
sans = lambda s: font('NotoSansTC-VF.ttf', s, 500)

# Background: vertical dark gradient with a warm crimson glow behind each column.
img = Image.new('RGB', (W, H), BLACK)
px = img.load()
for y in range(H):
    t = y / H
    c = tuple(int(DARK[i] * (1 - t) + BLACK[i] * t) for i in range(3))
    for x in range(W):
        px[x, y] = c
glow = Image.new('RGB', (W, H), (0, 0, 0))
gd = ImageDraw.Draw(glow)
col = W / 3
for i in range(3):
    cx = int(col * i + col / 2)
    gd.ellipse([cx - 360, 150, cx + 360, 870], fill=(70, 14, 10))
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = Image.blend(img, Image.composite(glow, img, Image.new('L', (W, H), 150)), 0.6)

# Faint emblem watermark behind the middle column.
emblem = Image.open(EMBLEM).convert('RGB').resize((760, 760), Image.LANCZOS)
mask = Image.new('L', emblem.size, 0)
ImageDraw.Draw(mask).ellipse([40, 40, 720, 720], fill=38)
mask = mask.filter(ImageFilter.GaussianBlur(40))
img.paste(emblem, (W // 2 - 380, (H - 760) // 2 + 20), mask)

d = ImageDraw.Draw(img)

# Gold frame and column dividers with diamond ornaments.
d.rectangle([24, 24, W - 25, H - 25], outline=GOLD_D, width=3)
d.rectangle([38, 38, W - 39, H - 39], outline=(60, 46, 24), width=2)
for i in (1, 2):
    x = int(col * i)
    d.line([x, 110, x, H - 110], fill=GOLD_D, width=3)
    d.polygon([(x, H // 2 - 22), (x + 14, H // 2), (x, H // 2 + 22), (x - 14, H // 2)], fill=GOLD)

def icon_plus(cx, cy):
    d.ellipse([cx - 92, cy - 92, cx + 92, cy + 92], outline=GOLD, width=10)
    d.line([cx - 46, cy, cx + 46, cy], fill=GOLD_L, width=14)
    d.line([cx, cy - 46, cx, cy + 46], fill=GOLD_L, width=14)

def icon_seats(cx, cy):
    # Three seats, the last one open: "還有空位".
    for k, filled in enumerate((True, True, False)):
        x = cx - 110 + k * 110
        d.rounded_rectangle([x - 40, cy - 70, x + 40, cy + 10], radius=18,
                            fill=GOLD if filled else None, outline=GOLD_L, width=8)
        d.rounded_rectangle([x - 48, cy + 20, x + 48, cy + 50], radius=10,
                            fill=GOLD if filled else None, outline=GOLD_L, width=8)
    d.line([cx + 60, cy + 78, cx + 160, cy + 78], fill=CRIM, width=10)

def icon_ticket(cx, cy):
    d.rounded_rectangle([cx - 120, cy - 70, cx + 120, cy + 70], radius=22, outline=GOLD, width=10)
    # Ticket notches: arcs cut into the outline rather than dark blobs.
    d.rectangle([cx - 126, cy - 18, cx - 112, cy + 18], fill=(20, 12, 8))
    d.rectangle([cx + 112, cy - 18, cx + 126, cy + 18], fill=(20, 12, 8))
    d.arc([cx - 140, cy - 22, cx - 100, cy + 22], -90, 90, fill=GOLD, width=10)
    d.arc([cx + 100, cy - 22, cx + 140, cy + 22], 90, 270, fill=GOLD, width=10)
    for k in range(5):
        d.line([cx - 40, cy - 52 + k * 26, cx - 40, cy - 40 + k * 26], fill=GOLD_D, width=6)
    d.line([cx - 5, cy - 18, cx + 80, cy - 18], fill=GOLD_L, width=10)
    d.line([cx - 5, cy + 18, cx + 55, cy + 18], fill=GOLD_L, width=10)

items = [(icon_plus, '我要開團', '選人數・挑劇本・約時間'),
         (icon_seats, '缺人場次', '還有空位的公開團'),
         (icon_ticket, '我的揪團', '揪團與預約紀錄')]
title_f, sub_f = serif(118), sans(50)
for i, (icon, title, sub) in enumerate(items):
    cx = int(col * i + col / 2)
    icon(cx, 270)
    for dx, dy, color in ((0, 4, (0, 0, 0)), (0, 0, GOLD_L)):  # soft shadow, then gold title
        d.text((cx + dx, 520 + dy), title, font=title_f, fill=color, anchor='mm')
    d.text((cx, 640), sub, font=sub_f, fill=TEXT_D, anchor='mm')

brand = '海星劇本殺'
bf = sans(34)
bx = W - 70 - d.textlength(brand, font=bf)
d.text((W - 70, H - 62), brand, font=bf, fill=GOLD_D, anchor='rm')
sx, sy = bx - 30, H - 62  # four-point star drawn by hand (the font lacks ✦)
d.polygon([(sx, sy - 16), (sx + 5, sy - 5), (sx + 16, sy), (sx + 5, sy + 5), (sx, sy + 16), (sx - 5, sy + 5), (sx - 16, sy), (sx - 5, sy - 5)], fill=GOLD_D)

img.save(OUT, 'JPEG', quality=90, optimize=True, progressive=True)
print(OUT, OUT.stat().st_size, 'bytes')
