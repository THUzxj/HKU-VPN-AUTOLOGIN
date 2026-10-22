"""Render our font-free, line-path SVG into Windows icons. Requires Pillow.

Run from any directory: python tools/Build-Icons.py
Only our SVG's rect and M/L paths are supported; unsupported shapes fail closed.
"""
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / "assets" / "hkuvpn.svg"
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def render(size):
    scale = size * 4 / 256
    canvas = Image.new("RGBA", (size * 4, size * 4))
    draw = ImageDraw.Draw(canvas)

    def visit(element, inherited):
        style = {**inherited, **element.attrib}
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "rect":
            draw.rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1),
                                   radius=float(style["rx"]) * scale, fill=style["fill"])
        elif tag == "path":
            if re.search(r"[A-KN-Za-kn-z]", style["d"]):
                raise ValueError("Only absolute M/L paths are supported")
            width = float(style["stroke-width"]) * scale
            for segment in style["d"].split("M")[1:]:
                values = list(map(float, re.findall(r"-?\d+(?:\.\d+)?", segment)))
                points = [(values[i] * scale, values[i + 1] * scale) for i in range(0, len(values), 2)]
                draw.line(points, fill=style["stroke"], width=round(width), joint="curve")
                for x, y in points:
                    radius = width / 2
                    draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=style["stroke"])
        elif tag not in {"svg", "g", "title", "desc"}:
            raise ValueError("Unsupported SVG element: " + tag)
        for child in element:
            visit(child, style)

    visit(ET.parse(SVG).getroot(), {})
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    render(512).save(ROOT / "assets" / "hkuvpn.png")
    frames = [render(size) for size in SIZES]
    frames[-1].save(ROOT / "assets" / "hkuvpn.ico", sizes=[(s, s) for s in SIZES], append_images=frames[:-1])
    print("Generated HKUVPN PNG and multi-resolution Windows ICO from vector source.")
