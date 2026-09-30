"""生成 App 图标。

设计：蓝色渐变圆角方块 + 白色日历卡片 + 橙色顶栏 + 蓝色对勾。
配色和 App 主题一致（主色 #4A90D9，强调色 #FF8C42）。

同时生成两套：
  - ic_launcher.png            传统图标，自带圆角背景
  - ic_launcher_foreground.png 自适应图标的前景层（安卓 8+），只画内容不留背景

自适应图标会被系统按各家厂商的形状裁切（圆形、方形、水滴形……），
所以前景内容必须缩在中间的安全区内，否则边角会被切掉。
"""

from PIL import Image, ImageDraw

# 与 App 主题一致的配色
BLUE_TOP = (107, 176, 240)
BLUE_BOTTOM = (62, 127, 212)
ORANGE = (255, 140, 66)
WHITE = (255, 255, 255)
CHECK = (74, 144, 217)

# 超采样倍数：先按 4 倍画再缩回去，边缘才不会有锯齿
SS = 4


def rounded_gradient(size: int, radius_ratio: float) -> Image.Image:
    """画一个带垂直渐变的圆角方块。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # 先画渐变
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            tuple(int(BLUE_TOP[i] + (BLUE_BOTTOM[i] - BLUE_TOP[i]) * t) for i in range(3)),
        )
    gradient = gradient.resize((size, size))

    # 再用圆角矩形当遮罩切出来
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=int(size * radius_ratio),
        fill=255,
    )
    img.paste(gradient, (0, 0), mask)
    return img


def draw_calendar(
    canvas: Image.Image,
    cx: float,
    cy: float,
    card_w: float,
    corner_ratio: float = 0.16,
) -> None:
    """在 canvas 上以 (cx, cy) 为中心画一个日历卡片。

    card_w 是卡片宽度占画布的比例，其余尺寸按比例推导，
    这样同一套代码能画出不同大小的图标。
    """
    size = canvas.width
    w = card_w * size
    h = w * 0.92  # 日历略扁，看起来更像卡片

    left = cx * size - w / 2
    top = cy * size - h / 2
    right = left + w
    bottom = top + h
    radius = w * corner_ratio

    d = ImageDraw.Draw(canvas)

    # 卡片投影：往下偏移一点点，让它有浮起来的感觉
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [left, top + h * 0.055, right, bottom + h * 0.055],
        radius=radius,
        fill=(20, 50, 90, 70),
    )
    canvas.alpha_composite(shadow)

    # 白色卡片
    d.rounded_rectangle([left, top, right, bottom], radius=radius, fill=WHITE)

    # 顶部橙色横条：只让上两个角是圆的
    bar_h = h * 0.27
    d.rounded_rectangle(
        [left, top, right, top + bar_h],
        radius=radius,
        fill=ORANGE,
        corners=(True, True, False, False),
    )

    # 橙色条和白色区域之间的分界线，避免缩放后出现白色缝隙
    d.rectangle([left, top + bar_h - 1, right, top + bar_h], fill=ORANGE)

    # 顶部两个装订环
    ring_w = w * 0.075
    ring_h = h * 0.16
    for ratio in (0.30, 0.70):
        rx = left + w * ratio
        d.rounded_rectangle(
            [rx - ring_w / 2, top - ring_h * 0.42, rx + ring_w / 2, top + ring_h * 0.5],
            radius=ring_w / 2,
            fill=WHITE,
        )

    # 对勾：用粗线加圆角接点画，比多边形简单且边缘更好看
    body_top = top + bar_h
    body_h = bottom - body_top
    lw = w * 0.115
    pts = [
        (left + w * 0.27, body_top + body_h * 0.52),
        (left + w * 0.44, body_top + body_h * 0.70),
        (left + w * 0.75, body_top + body_h * 0.30),
    ]
    d.line(pts, fill=CHECK, width=int(lw), joint="curve")
    # 两端补上圆头，否则线头是方的
    for p in (pts[0], pts[-1]):
        d.ellipse([p[0] - lw / 2, p[1] - lw / 2, p[0] + lw / 2, p[1] + lw / 2], fill=CHECK)


def make_legacy(size: int, ss: int = SS) -> Image.Image:
    """传统图标：圆角方块背景 + 居中日历。"""
    big = size * ss
    img = rounded_gradient(big, radius_ratio=0.22)
    draw_calendar(img, cx=0.5, cy=0.53, card_w=0.62)
    return img.resize((size, size), Image.LANCZOS)


def make_foreground(size: int) -> Image.Image:
    """自适应图标的前景层：只有日历，没有背景。

    内容压在中间 60% 以内 —— 系统会按厂商形状裁切，
    超出安全区的部分会被切掉。
    """
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw_calendar(img, cx=0.5, cy=0.5, card_w=0.56)
    return img.resize((size, size), Image.LANCZOS)


def make_background(size: int) -> Image.Image:
    """自适应图标背景层：铺满整个画布的渐变（不切圆角，交给系统裁）。"""
    img = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    big = size * SS
    gradient = Image.new("RGB", (1, big))
    for y in range(big):
        t = y / max(big - 1, 1)
        gradient.putpixel(
            (0, y),
            tuple(int(BLUE_TOP[i] + (BLUE_BOTTOM[i] - BLUE_TOP[i]) * t) for i in range(3)),
        )
    img.paste(gradient.resize((big, big)), (0, 0))
    return img.resize((size, size), Image.LANCZOS)


# 安卓各密度对应的像素尺寸
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# 自适应图标的前景/背景层用的是 108dp 画布，比传统图标的 48dp 大得多
ADAPTIVE = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}


def main() -> None:
    import os

    base = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "interview_calendar", "android", "app", "src", "main", "res",
    )
    if not os.path.isdir(base):
        raise SystemExit(f"找不到 res 目录：{base}")

    for density, px in DENSITIES.items():
        folder = os.path.join(base, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        make_legacy(px).save(os.path.join(folder, "ic_launcher.png"))
        print(f"  mipmap-{density}/ic_launcher.png  {px}x{px}")

    for density, px in ADAPTIVE.items():
        folder = os.path.join(base, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        make_foreground(px).save(os.path.join(folder, "ic_launcher_foreground.png"))
        make_background(px).save(os.path.join(folder, "ic_launcher_background.png"))
        print(f"  mipmap-{density}/ic_launcher_foreground+background.png  {px}x{px}")

    # 存一份预览图。这里用较低的采样倍数：4 倍超采样在 1024 尺寸下
    # 需要一张 4096×4096 的中间画布，内存吃紧的机器上会 MemoryError。
    preview = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon_preview.png")
    make_legacy(512, ss=2).save(preview)
    print(f"\n预览图：{preview}")


if __name__ == "__main__":
    main()
