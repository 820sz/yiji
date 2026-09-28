"""生成「忆记」的应用图标。

设计:深灰圆角方块 + 柠檬黄打钩——和 app 里 AI 头像的内置图标同一套形状,
这样桌面图标和聊天页头像是同一个符号。

跑法(在项目根):
    python tool/make_icons.py

生成物直接覆盖 android/app/src/main/res 下各密度的 ic_launcher.png。
这是构建期的一次性工具,不进 app 运行时,所以是 Python 而不是 Dart。
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw

# 与 lib/ui/theme.dart、lib/data/palette.dart 里的一致。
BACKGROUND = (46, 49, 54)
FOREGROUND = (251, 232, 166)

# 各密度下 launcher 图标的边长(px),按 Android 的 mipmap 约定。
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")


def rounded_square(size: int, radius_ratio: float = 0.24) -> Image.Image:
    """画一个圆角方块底。"""
    # 4 倍超采样,圆角和钩子的边缘才不会有锯齿。
    scale = 4
    big = size * scale
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        [(0, 0), (big - 1, big - 1)],
        radius=int(big * radius_ratio),
        fill=BACKGROUND + (255,),
    )
    return image


def draw_check(image: Image.Image, size: int, stroke_ratio: float = 0.13) -> None:
    """在图中画一个打钩。

    钩子的三个点按图标边长的比例取,所以任何尺寸下形状一致。
    """
    scale = image.size[0] // size
    stroke = max(2, int(size * stroke_ratio)) * scale
    points = [
        (0.30, 0.52),
        (0.44, 0.66),
        (0.71, 0.36),
    ]
    coords = [(x * image.size[0], y * image.size[1]) for x, y in points]
    draw = ImageDraw.Draw(image)
    draw.line(coords, fill=FOREGROUND + (255,), width=stroke, joint="curve")
    # 线两端是平头,补两个圆点让端点是圆的。
    for x, y in (coords[0], coords[-1]):
        r = stroke / 2
        draw.ellipse([x - r, y - r, x + r, y + r], fill=FOREGROUND + (255,))


def make_icon(size: int, *, circular: bool = False) -> Image.Image:
    """生成一个图标。[circular] 为真时裁成圆形(给 ic_launcher_round 用)。"""
    image = rounded_square(size)
    draw_check(image, size)
    if circular:
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).ellipse([(0, 0), image.size], fill=255)
        # 圆形版:把圆角方块的底换成实心圆底,避免圆外露白。
        base = Image.new("RGBA", image.size, (0, 0, 0, 0))
        ImageDraw.Draw(base).ellipse([(0, 0), image.size], fill=BACKGROUND + (255,))
        check_only = Image.new("RGBA", image.size, (0, 0, 0, 0))
        draw_check(check_only, size)
        base.alpha_composite(Image.composite(check_only, Image.new("RGBA", image.size, (0, 0, 0, 0)), check_only.split()[3]))
        return base
    return image


def make_adaptive_foreground(size: int = 432) -> Image.Image:
    """自适应图标的前景层:透明底 + 居中缩小的打钩。

    Android 的自适应图标只用中间约 66/108 的区域,外圈会被各家启动器裁掉。
    所以前景里的钩子必须缩到中间,不能按满幅画——否则 vivo 桌面会把钩子切掉。
    """
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # 把钩子画在一张约 46% 大小的画布上,再居中贴上,留足被裁的余量。
    inner_size = max(8, int(size * 0.46))
    mark = Image.new("RGBA", (inner_size, inner_size), (0, 0, 0, 0))
    draw_check(mark, inner_size, stroke_ratio=0.16)
    offset = ((size - inner_size) // 2, (size - inner_size) // 2)
    image.alpha_composite(mark, offset)
    return image


def write_adaptive() -> None:
    """写自适应图标的前景图与描述文件。"""
    foreground_dir = os.path.join(RES, "drawable-nodpi")
    os.makedirs(foreground_dir, exist_ok=True)
    make_adaptive_foreground().save(
        os.path.join(foreground_dir, "ic_launcher_foreground.png"), "PNG"
    )

    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        "    <!-- 主题化图标(Android 13+):用同一个钩子,让系统按壁纸配色 -->\n"
        '    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n"
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w", encoding="utf-8") as handle:
            handle.write(adaptive)

    # 背景色资源。
    values = os.path.join(RES, "values")
    os.makedirs(values, exist_ok=True)
    colors_path = os.path.join(values, "ic_launcher_background.xml")
    with open(colors_path, "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<resources>\n"
            "    <!-- 与主题里的卡片底色一致 -->\n"
            '    <color name="ic_launcher_background">#2E3136</color>\n'
            "</resources>\n"
        )
    print("自适应图标已写入")


def write_all() -> None:
    for density, size in DENSITIES.items():
        target_dir = os.path.join(RES, f"mipmap-{density}")
        os.makedirs(target_dir, exist_ok=True)

        square = make_icon(size).resize((size, size), Image.LANCZOS)
        square.save(os.path.join(target_dir, "ic_launcher.png"), "PNG")

        # 圆形版单独算:先按 4 倍画再缩,圆边才平滑。
        big = make_icon(size * 4, circular=True)
        big.resize((size, size), Image.LANCZOS).save(
            os.path.join(target_dir, "ic_launcher_round.png"), "PNG"
        )
        print(f"{density}: {size}px 已写入")
    write_adaptive()


if __name__ == "__main__":
    write_all()
    print("图标生成完成")
