#!/usr/bin/env python3
"""Draw the app's icon, for the Android app and the desktop launcher.

    tools/make_artwork.py

Everything is drawn here from shapes -- no game, club, player or publisher
artwork goes in, so none comes out. It replaced the PES 2017 cover art and the MW2 icon
this project once shipped. The palette is the one in res/values/colors.xml.

Writes, over whatever is there:
    android/app/src/main/res/drawable-nodpi/ic_launcher_art.png   adaptive icon art
    android/app/src/main/res/mipmap-*/ic_launcher(_round).png     pre-Oreo icons
    launcher/icon/launcher.ico, launcher.bmp                      desktop icon

The menu's backdrop and wordmark (drawable-nodpi/launcher_players.webp,
launcher_logo.webp) are supplied pictures, not drawn here; they are lossless
WebP (cwebp -lossless -z 9), which Android reads from API 18.
"""
import math, os
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

NAVY, BLUE, RED, GOLD = (10, 27, 69), (0, 77, 152), (220, 0, 20), (237, 187, 0)
SKY, WHITE, LINE = (64, 156, 255), (255, 255, 255), (201, 209, 222)
GRASS_DARK, GRASS_LIGHT = (22, 110, 62), (34, 139, 76)
SS = 4  # drawn this many times larger, then reduced: the reduction is the antialiasing


def gradient(size, top, bottom):
    w, h = size
    column = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((w, h))


def pentagon(cx, cy, r, rotation):
    return [(cx + r * math.cos(rotation + i * 2 * math.pi / 5 - math.pi / 2),
             cy + r * math.sin(rotation + i * 2 * math.pi / 5 - math.pi / 2)) for i in range(5)]


def ball(diameter, spin=0.25):
    """A white ball with the truncated-icosahedron patches, transparent outside."""
    d = diameter
    layer = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    c, r = d / 2, d / 2
    draw.ellipse((0, 0, d - 1, d - 1), fill=WHITE)
    # A little shade toward the lower right so it reads as round.
    shade = Image.new("L", (d, d), 0)
    ImageDraw.Draw(shade).ellipse((-0.15 * d, -0.15 * d, 0.95 * d, 0.95 * d), fill=255)
    shade = ImageChops.invert(shade.filter(ImageFilter.GaussianBlur(d * 0.08)))
    tint = Image.new("RGBA", (d, d), (190, 200, 220, 0))
    tint.putalpha(shade.point(lambda v: v * 0.55))
    layer = Image.alpha_composite(layer, tint)
    draw = ImageDraw.Draw(layer)
    width = max(1, round(d * 0.018))
    centre = pentagon(c, c, r * 0.27, spin)
    for i, (x, y) in enumerate(centre):
        # A seam from each corner of the middle patch out to an outer one.
        angle = spin + i * 2 * math.pi / 5 - math.pi / 2
        ox, oy = c + r * 0.80 * math.cos(angle), c + r * 0.80 * math.sin(angle)
        draw.line((x, y, ox, oy), fill=NAVY, width=width)
        draw.polygon(pentagon(ox, oy, r * 0.25, spin + math.pi), fill=NAVY)
    draw.polygon(centre, fill=NAVY)
    mask = Image.new("L", (d, d), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, d - 1, d - 1), fill=255)
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
    return layer


def icon(size):
    """The launcher icon: a ball struck off a pitch at night, with a red arc."""
    S = size * SS
    art = gradient((S, S), NAVY, BLUE).convert("RGBA")
    draw = ImageDraw.Draw(art)
    # The pitch, cut on a rising diagonal, mown in stripes, edged in sky blue.
    pitch = [(0, S * 0.78), (S, S * 0.52), (S, S), (0, S)]
    draw.polygon(pitch, fill=GRASS_DARK)
    stripes = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stripes)
    for k in range(-2, 8, 2):
        x = k * S * 0.16
        sd.polygon([(x, S), (x + S * 0.16, S), (x + S * 0.46, S * 0.40), (x + S * 0.30, S * 0.40)],
                   fill=GRASS_LIGHT + (255,))
    clip = Image.new("L", (S, S), 0)
    ImageDraw.Draw(clip).polygon(pitch, fill=255)
    stripes.putalpha(ImageChops.multiply(stripes.getchannel("A"), clip))
    art = Image.alpha_composite(art, stripes)
    draw = ImageDraw.Draw(art)
    draw.line([(0, S * 0.78), (S, S * 0.52)], fill=SKY, width=round(S * 0.022))
    # The red arc of its flight, behind the ball.
    d = round(S * 0.46)
    bx, by = round(S * 0.52 - d / 2), round(S * 0.47 - d / 2)
    pad = S * 0.07
    draw.arc((bx - pad, by - pad, bx + d + pad, by + d + pad), 150, 290, fill=RED, width=round(S * 0.045))
    draw.arc((bx - pad * 2.1, by - pad * 2.1, bx + d + pad * 2.1, by + d + pad * 2.1), 175, 255,
             fill=GOLD, width=round(S * 0.022))
    # Its shadow on the grass, then the ball.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse((bx + d * 0.12, by + d * 1.02, bx + d * 0.95, by + d * 1.16),
                                   fill=(0, 0, 0, 110))
    art = Image.alpha_composite(art, shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))
    art.alpha_composite(ball(d), (bx, by))
    return art.resize((size, size), Image.LANCZOS)


def round_icon(square):
    s = square.size[0]
    mask = Image.new("L", (s * SS, s * SS), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, s * SS - 1, s * SS - 1), fill=255)
    out = square.convert("RGBA")
    out.putalpha(mask.resize((s, s), Image.LANCZOS))
    return out


def main():
    nodpi = os.path.join(RES, "drawable-nodpi")
    icon(512).save(os.path.join(nodpi, "ic_launcher_art.png"), optimize=True)
    for density, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        square = icon(px)
        square.convert("RGB").save(os.path.join(RES, f"mipmap-{density}", "ic_launcher.png"), optimize=True)
        round_icon(square).save(os.path.join(RES, f"mipmap-{density}", "ic_launcher_round.png"), optimize=True)
    desktop = icon(256)
    out = os.path.join(ROOT, "launcher", "icon")
    desktop.save(os.path.join(out, "launcher.ico"),
                 sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    desktop.save(os.path.join(out, "launcher.bmp"))
    print("wrote the icons")


if __name__ == "__main__":
    main()
