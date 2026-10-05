"""Starfish dark-theme Rich Menus: 2500x1686, six cells each (新玩家 / 老玩家).

Usage: python scripts/richmenu_image.py web/liff <starfishlarp>/pwa/icon-512.png
Writes richmenu-new.jpg and richmenu-member.jpg. Cell order must match richMenuDefinition()
in supabase/functions/api/index.ts. Colors follow the starfishlarp site theme (index.css);
fonts are Windows Noto Serif/Sans TC.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2500, 1686
CELL_W, CELL_H = W / 3, H / 2
OUT_DIR = Path(sys.argv[1])
EMBLEM = Path(sys.argv[2])
BLACK, DARK = (8, 6, 3), (16, 12, 7)
GOLD, GOLD_L, GOLD_D = (200, 160, 86), (236, 208, 138), (122, 94, 44)
CRIM = (139, 26, 26)
TEXT_D = (154, 138, 108)
HOLE = (20, 12, 8)


def font(name, size, weight=None):
    f = ImageFont.truetype(f'C:/Windows/Fonts/{name}', size)
    if weight:
        try: f.set_variation_by_axes([weight])
        except Exception: pass
    return f


serif = lambda s: font('NotoSerifTC-VF.ttf', s, 900)
sans = lambda s: font('NotoSansTC-VF.ttf', s, 500)


# ---- Icons, each drawn around (cx, cy) within roughly a 260px box ----------------------
def icon_host(d, cx, cy):  # 認識海星: host behind a microphone
    d.ellipse([cx - 52, cy - 110, cx + 52, cy - 6], outline=GOLD, width=10)
    d.arc([cx - 105, cy + 10, cx + 105, cy + 200], 180, 360, fill=GOLD, width=10)
    d.rounded_rectangle([cx + 70, cy - 30, cx + 110, cy + 40], radius=20, fill=GOLD_L)
    d.line([cx + 90, cy + 40, cx + 90, cy + 80], fill=GOLD_L, width=8)


def icon_book(d, cx, cy):  # 劇本介紹: open book
    d.polygon([(cx, cy - 60), (cx - 130, cy - 90), (cx - 130, cy + 70), (cx, cy + 100)], outline=GOLD, width=10)
    d.polygon([(cx, cy - 60), (cx + 130, cy - 90), (cx + 130, cy + 70), (cx, cy + 100)], outline=GOLD, width=10)
    d.line([cx, cy - 60, cx, cy + 100], fill=GOLD, width=10)
    for k in range(3):
        y = cy - 45 + k * 35
        d.line([cx - 100, y - 12, cx - 30, y + 2], fill=GOLD_L, width=7)
        d.line([cx + 30, y + 2, cx + 100, y - 12], fill=GOLD_L, width=7)


def icon_calendar(d, cx, cy):  # 劇本預約: calendar with a plus
    d.rounded_rectangle([cx - 115, cy - 85, cx + 115, cy + 105], radius=20, outline=GOLD, width=10)
    d.line([cx - 115, cy - 30, cx + 115, cy - 30], fill=GOLD, width=10)
    for x in (cx - 60, cx + 60):
        d.line([x, cy - 115, x, cy - 60], fill=GOLD_L, width=14)
    d.line([cx - 40, cy + 38, cx + 40, cy + 38], fill=GOLD_L, width=14)
    d.line([cx, cy - 2, cx, cy + 78], fill=GOLD_L, width=14)


def icon_seats(d, cx, cy):  # 缺人場次: three seats, the last one open
    for k, filled in enumerate((True, True, False)):
        x = cx - 110 + k * 110
        d.rounded_rectangle([x - 40, cy - 70, x + 40, cy + 10], radius=18,
                            fill=GOLD if filled else None, outline=GOLD_L, width=8)
        d.rounded_rectangle([x - 48, cy + 20, x + 48, cy + 50], radius=10,
                            fill=GOLD if filled else None, outline=GOLD_L, width=8)
    d.line([cx + 60, cy + 78, cx + 160, cy + 78], fill=CRIM, width=10)


def icon_compass(d, cx, cy):  # 新手指南: compass
    d.ellipse([cx - 105, cy - 105, cx + 105, cy + 105], outline=GOLD, width=10)
    d.polygon([(cx, cy - 80), (cx + 26, cy), (cx, cy + 80), (cx - 26, cy)], outline=GOLD_L, width=6)
    d.polygon([(cx, cy - 80), (cx + 26, cy), (cx - 26, cy)], fill=CRIM)
    d.ellipse([cx - 10, cy - 10, cx + 10, cy + 10], fill=GOLD_L)


def icon_medal(d, cx, cy):  # 我是老玩家: medal with a star
    d.polygon([(cx - 70, cy - 120), (cx - 25, cy - 120), (cx + 15, cy - 30), (cx - 30, cy - 30)], fill=CRIM)
    d.polygon([(cx + 70, cy - 120), (cx + 25, cy - 120), (cx - 15, cy - 30), (cx + 30, cy - 30)], fill=(110, 20, 20))
    d.ellipse([cx - 85, cy - 45, cx + 85, cy + 125], outline=GOLD, width=10)
    star(d, cx, cy + 40, 52, GOLD_L)


def icon_quill(d, cx, cy):  # 玩本記錄: scroll and quill
    d.rounded_rectangle([cx - 110, cy - 90, cx + 70, cy + 100], radius=14, outline=GOLD, width=10)
    for k in range(4):
        d.line([cx - 80, cy - 50 + k * 40, cx + 30 - (k == 3) * 50, cy - 50 + k * 40], fill=GOLD_D, width=8)
    d.polygon([(cx + 140, cy - 130), (cx + 40, cy + 60), (cx + 60, cy + 70), (cx + 150, cy - 110)], fill=GOLD_L)
    d.line([cx + 40, cy + 60, cx + 28, cy + 92], fill=GOLD_L, width=8)


def icon_card(d, cx, cy):  # 會員卡・兌換: member card
    d.rounded_rectangle([cx - 130, cy - 80, cx + 130, cy + 90], radius=22, outline=GOLD, width=10)
    d.rectangle([cx - 130, cy - 40, cx + 130, cy - 12], fill=GOLD_D)
    d.ellipse([cx - 100, cy + 10, cx - 40, cy + 70], outline=GOLD_L, width=7)
    d.line([cx - 15, cy + 25, cx + 95, cy + 25], fill=GOLD_L, width=10)
    d.line([cx - 15, cy + 58, cx + 60, cy + 58], fill=GOLD_L, width=10)


def icon_trophy(d, cx, cy):  # 榮譽牆: trophy
    d.pieslice([cx - 85, cy - 150, cx + 85, cy + 30], 0, 180, fill=GOLD)
    d.rectangle([cx - 85, cy - 110, cx + 85, cy - 60], fill=GOLD)
    d.arc([cx - 135, cy - 105, cx - 55, cy - 15], 90, 270, fill=GOLD_L, width=10)
    d.arc([cx + 55, cy - 105, cx + 135, cy - 15], 270, 90, fill=GOLD_L, width=10)
    d.rectangle([cx - 14, cy + 25, cx + 14, cy + 70], fill=GOLD)
    d.rounded_rectangle([cx - 70, cy + 70, cx + 70, cy + 100], radius=8, fill=GOLD_L)
    star(d, cx, cy - 70, 30, HOLE)


def star(d, cx, cy, r, color):
    import math
    pts = []
    for k in range(10):
        a = -math.pi / 2 + k * math.pi / 5
        rr = r if k % 2 == 0 else r * 0.45
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=color)


MENUS = {
    'new': [(icon_host, '認識海星', '主持人介紹'), (icon_book, '劇本介紹', '劇本總覽與故事'),
            (icon_calendar, '劇本預約', '開團・我的揪團'), (icon_seats, '缺人場次', '還有空位的公開團'),
            (icon_compass, '新手指南', '第一次怎麼玩'), (icon_medal, '我是老玩家', '綁定以前的紀錄')],
    'member': [(icon_calendar, '劇本預約', '開團・我的揪團'), (icon_seats, '缺人場次', '還有空位的公開團'),
               (icon_quill, '玩本記錄', '紀錄與心得'), (icon_card, '會員卡・兌換', '點數與獎勵'),
               (icon_book, '劇本介紹', '劇本總覽與故事'), (icon_trophy, '榮譽牆', '玩家排行與徽章')],
}


def background(emblem_img):
    img = Image.new('RGB', (W, H), BLACK)
    grad = Image.linear_gradient('L').resize((W, H))  # 0 at top → 255 at bottom
    img = Image.composite(Image.new('RGB', (W, H), BLACK), Image.new('RGB', (W, H), DARK), grad)
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for row in range(2):
        for col in range(3):
            cx, cy = int(CELL_W * col + CELL_W / 2), int(CELL_H * row + CELL_H / 2)
            gd.ellipse([cx - 330, cy - 300, cx + 330, cy + 360], fill=(70, 14, 10))
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    img = Image.blend(img, Image.composite(glow, img, Image.new('L', (W, H), 150)), 0.6)
    size = 1100
    emblem = emblem_img.resize((size, size), Image.LANCZOS)
    mask = Image.new('L', emblem.size, 0)
    ImageDraw.Draw(mask).ellipse([60, 60, size - 60, size - 60], fill=30)
    mask = mask.filter(ImageFilter.GaussianBlur(60))
    img.paste(emblem, (W // 2 - size // 2, H // 2 - size // 2), mask)
    return img


def draw_menu(kind, emblem_img):
    img = background(emblem_img)
    d = ImageDraw.Draw(img)
    d.rectangle([24, 24, W - 25, H - 25], outline=GOLD_D, width=3)
    d.rectangle([38, 38, W - 39, H - 39], outline=(60, 46, 24), width=2)
    for i in (1, 2):  # column dividers with diamond ornaments
        x = int(CELL_W * i)
        for row in range(2):
            top, bottom = int(CELL_H * row) + 110, int(CELL_H * (row + 1)) - 110
            mid = (top + bottom) // 2
            d.line([x, top, x, bottom], fill=GOLD_D, width=3)
            d.polygon([(x, mid - 22), (x + 14, mid), (x, mid + 22), (x - 14, mid)], fill=GOLD)
    y = int(CELL_H)  # row divider, broken at the column joints
    for col in range(3):
        d.line([int(CELL_W * col) + 110, y, int(CELL_W * (col + 1)) - 110, y], fill=GOLD_D, width=3)
    title_f, sub_f = serif(112), sans(48)
    for i, (icon, title, sub) in enumerate(MENUS[kind]):
        col, row = i % 3, i // 3
        cx, top = int(CELL_W * col + CELL_W / 2), int(CELL_H * row)
        icon(d, cx, top + 270)
        for dy, color in ((4, (0, 0, 0)), (0, GOLD_L)):  # soft shadow, then gold title
            d.text((cx, top + 530 + dy), title, font=title_f, fill=color, anchor='mm')
        d.text((cx, top + 645), sub, font=sub_f, fill=TEXT_D, anchor='mm')
    out = OUT_DIR / f'richmenu-{kind}.jpg'
    img.save(out, 'JPEG', quality=88, optimize=True, progressive=True)
    print(out, out.stat().st_size, 'bytes')


emblem_img = Image.open(EMBLEM).convert('RGB')
for kind in MENUS:
    draw_menu(kind, emblem_img)
