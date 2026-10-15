"""Starfish dark-theme add-friend QR for the player OA @825gdzws: poster (1080x1350) and square (1200x1200).

Usage: python scripts/line_qr_image.py docs/assets <starfishlarp>/pwa/icon-512.png
Writes line-oa-qr-poster.png and line-oa-qr-square.png. Colors and fonts follow scripts/richmenu_image.py.
The QR sits on a light panel with error correction H so the centre emblem stays scannable; if zxing-cpp is
installed (pip install zxing-cpp) each output is decoded at 100% / 50% / 30% and must match URL.
"""
import sys
from pathlib import Path
import qrcode
from PIL import Image, ImageDraw, ImageFilter, ImageFont

URL = 'https://line.me/R/ti/p/@825gdzws'
OUT_DIR = Path(sys.argv[1])
EMBLEM = Path(sys.argv[2])
BLACK, DARK = (8, 6, 3), (16, 12, 7)
GOLD, GOLD_L, GOLD_D = (200, 160, 86), (236, 208, 138), (122, 94, 44)
CRIM = (139, 26, 26)
TEXT_D = (154, 138, 108)
PAPER = (244, 234, 210)  # light parchment behind the QR keeps contrast high for scanning
INK = (28, 18, 10)       # dark brown modules
SS = 3                   # supersampling


def font(name, size, weight):
    f = ImageFont.truetype(f'C:/Windows/Fonts/{name}', size)
    try: f.set_variation_by_axes([weight])
    except Exception: pass
    return f


def qr_tile(px):
    """Rounded-dot QR on a parchment rounded square, px wide, with the emblem in the centre."""
    q = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H, border=0)
    q.add_data(URL)
    q.make(fit=True)
    m = q.get_matrix()
    n = len(m)
    quiet = 4
    S = px * SS
    cell = S / (n + quiet * 2)
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(cell * 2.2), fill=PAPER)
    off = quiet * cell

    def in_finder(r, c):
        return any(r0 <= r < r0 + 7 and c0 <= c < c0 + 7 for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)))

    hole = int(n * 0.24) | 1  # centre clearing for the emblem, well inside level H's 30% budget
    h0 = (n - hole) // 2
    for r in range(n):
        for c in range(n):
            if not m[r][c] or in_finder(r, c):
                continue
            if h0 - 1 <= r < h0 + hole + 1 and h0 - 1 <= c < h0 + hole + 1:
                continue
            x, y, pad = off + c * cell, off + r * cell, cell * 0.08
            d.rounded_rectangle([x + pad, y + pad, x + cell - pad, y + cell - pad], radius=cell * 0.38, fill=INK)

    for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
        x, y = off + c0 * cell, off + r0 * cell
        d.rounded_rectangle([x, y, x + 7 * cell, y + 7 * cell], radius=cell * 2, fill=INK)
        d.rounded_rectangle([x + cell, y + cell, x + 6 * cell, y + 6 * cell], radius=cell * 1.4, fill=PAPER)
        d.rounded_rectangle([x + 2 * cell, y + 2 * cell, x + 5 * cell, y + 5 * cell], radius=cell * 0.9, fill=CRIM)

    c = S / 2
    er = hole * cell / 2
    d.ellipse([c - er, c - er, c + er, c + er], fill=INK, outline=GOLD, width=int(cell * 0.35))
    inner = int(er * 2 * 0.86)
    em = Image.open(EMBLEM).convert('RGB').resize((inner, inner), Image.LANCZOS)
    mask = Image.new('L', (inner, inner), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, inner - 1, inner - 1], fill=255)
    img.paste(em, (int(c - inner / 2), int(c - inner / 2)), mask)
    return img.resize((px, px), Image.LANCZOS)


def background(W, H):
    grad = Image.linear_gradient('L').resize((W, H))
    img = Image.composite(Image.new('RGB', (W, H), BLACK), Image.new('RGB', (W, H), DARK), grad)
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.05, H * 0.2, W * 0.95, H * 0.85], fill=(80, 16, 12))
    glow = glow.filter(ImageFilter.GaussianBlur(int(W * 0.15)))
    return Image.blend(img, glow, 0.45)


def frame(d, W, H, m=28):
    d.rectangle([m, m, W - m, H - m], outline=GOLD_D, width=2)
    d.rectangle([m + 12, m + 12, W - m - 12, H - m - 12], outline=(70, 54, 26), width=1)
    for x, y in ((m, m), (W - m, m), (m, H - m), (W - m, H - m)):
        d.polygon([(x, y - 9), (x + 9, y), (x, y + 9), (x - 9, y)], fill=GOLD)


def ornament(d, cx, y, half):
    d.line([cx - half, y, cx - 18, y], fill=GOLD_D, width=2)
    d.line([cx + 18, y, cx + half, y], fill=GOLD_D, width=2)
    d.polygon([(cx, y - 9), (cx + 9, y), (cx, y + 9), (cx - 9, y)], fill=GOLD)


def ctext(d, cx, y, s, f, fill, spacing=0):
    if not spacing:
        d.text((cx, y), s, font=f, fill=fill, anchor='mt')
        return
    widths = [d.textlength(ch, font=f) for ch in s]
    x = cx - (sum(widths) + spacing * (len(s) - 1)) / 2
    for ch, w in zip(s, widths):
        d.text((x, y), ch, font=f, fill=fill)
        x += w + spacing


def paste_qr(img, d, q, qx, qy, radius):
    d.rounded_rectangle([qx - 14, qy - 14, qx + q + 14, qy + q + 14], radius=radius, outline=GOLD, width=3)
    tile = qr_tile(q)
    img.paste(tile, (qx, qy), tile)


def save(img, name):
    path = OUT_DIR / name
    img.save(path, optimize=True)
    try:
        import zxingcpp
    except ImportError:
        print(f'{path} (zxing-cpp not installed, scan check skipped)')
        return
    for scale in (1, 0.5, 0.3):
        small = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
        texts = [r.text for r in zxingcpp.read_barcodes(small)]
        if texts != [URL]:
            sys.exit(f'{path}: scan at {scale:.0%} gave {texts}')
    print(f'{path} (scan OK at 100/50/30%)')


def poster():
    W, H = 1080, 1350
    img = background(W, H)
    d = ImageDraw.Draw(img)
    frame(d, W, H)
    cx = W // 2
    ctext(d, cx, 92, 'STARFISH MYSTERY', font('NotoSerifTC-VF.ttf', 26, 600), GOLD, spacing=8)
    ctext(d, cx, 138, '海星劇本殺', font('NotoSerifTC-VF.ttf', 92, 900), GOLD_L, spacing=10)
    ornament(d, cx, 268, 220)
    ctext(d, cx, 292, '加入 LINE 好友・線上預約劇本', font('NotoSansTC-VF.ttf', 34, 500), TEXT_D)
    q, qy = 640, 370
    paste_qr(img, d, q, cx - q // 2, qy, 40)
    ctext(d, cx, qy + q + 50, '掃描 QR Code 加入好友', font('NotoSerifTC-VF.ttf', 44, 800), GOLD_L)
    ornament(d, cx, qy + q + 130, 160)
    ctext(d, cx, qy + q + 158, 'LINE ID  @825gdzws', font('NotoSansTC-VF.ttf', 36, 500), GOLD)
    save(img, 'line-oa-qr-poster.png')


def square():
    W = H = 1200
    img = background(W, H)
    d = ImageDraw.Draw(img)
    frame(d, W, H, m=24)
    q, qy = 900, 110
    paste_qr(img, d, q, (W - q) // 2, qy, 48)
    ctext(d, W // 2, qy + q + 52, '海星劇本殺 ・ LINE @825gdzws', font('NotoSerifTC-VF.ttf', 46, 800), GOLD_L)
    save(img, 'line-oa-qr-square.png')


OUT_DIR.mkdir(parents=True, exist_ok=True)
poster()
square()
