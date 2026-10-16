#!/usr/bin/env python3
"""Generate the Earshot "arcs" Icon Composer document and the flat marks.

Geometry: a cyan dot (the speaker) at C, one or two concentric lavender arcs
radiating right, and an outer white arc on the same centre whose lower end
turns into the short arm of a check mark. The outer arc is the check's long arm.

Every stroke is written as a filled outline (no stroked paths), so Icon
Composer, Chrome and any SVG consumer render the same shape.

Usage: gen.py [out=<dir>] [key=value ...]
  out defaults to the parent folder of this script (the final/ folder).
  Any key in P can be overridden; radii is a comma list, e.g. radii=168,312.
Writes: <out>/AppIcon.icon/{icon.json,Assets/*.svg}, <out>/mark-on-dark.svg,
<out>/mark-on-light.svg, <out>/mark-template.svg, <out>/mark-white.svg, <out>/mark-ink.svg, <out>/work/flat.svg
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Final values (variant B). Running gen.py with no args reproduces the shipped icon.
P = dict(
    dot_r=66,
    radii="178",        # inner arc radii (comma list): one inner arc (variant B)
    arc_stroke=84,      # inner arc stroke width
    arc_col="#CBC8FB",  # inner arc: lavender, one value step below the check
    r3=338,             # outer arc radius (the check's long arm)
    stroke=96,          # check stroke width
    inner_from=-40, inner_to=36,   # inner arc span, degrees (0 = right, + = down)
    outer_from=-40, outer_to=65,   # outer arc span; outer_to is the check vertex
    arm_len=185, arm_angle=225,    # short arm: length and direction from the vertex
    rot=5,              # whole-glyph rotation, degrees counter-clockwise
    target_cx=500, target_cy=498,  # where the glyph's bounding-box centre lands
    top="#604DF0",      # background gradient top: #5B4BEF pushed 10% toward violet
    bottom="#1E1B4B",   # background gradient bottom (deep indigo)
    arcs_translucency=0.18,
    arcs_dark="#D6D3FC",           # arcs fill in dark appearance (stays a second tone)
    tint_dot=0.85, tint_arcs=0.85,  # grey values in tinted/clear: check 1 > arcs = dot (dot stays visible)
    out=os.path.dirname(HERE),
)
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    P[k] = v if (k in ("radii", "out") or v.startswith("#")) else float(v)

# scale (optional) multiplies every length, so a variant can be specified at one
# size and fitted to the canvas without retyping each value.
K = float(P.get("scale", 1))
for key in ("dot_r", "arc_stroke", "r3", "stroke", "arm_len"):
    P[key] = float(P[key]) * K
RADII = [float(r) * K for r in str(P["radii"]).split(",") if r]
CHECK = "#F7F7FB"
DOT = "#22D3EE"
INK = "#0F0E1A"
# Full-colour mark for light surfaces: the on-dark colours vanish on white and
# #22D3EE fails contrast there, so use indigo / violet / dark cyan.
LIGHT_CHECK, LIGHT_ARCS, LIGHT_DOT = "#4F46E5", "#8B5CF6", "#0891B2"


def ang(deg):
    """Apply the whole-glyph rotation (counter-clockwise on screen = smaller angle)."""
    return deg - P["rot"]


def pt(c, r, deg):
    a = math.radians(ang(deg))
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


def check_pts(c):
    e = pt(c, P["r3"], P["outer_to"])
    a = math.radians(ang(P["arm_angle"]))
    tip = (e[0] + P["arm_len"] * math.cos(a), e[1] + P["arm_len"] * math.sin(a))
    return e, tip


def outline_points(c):
    """Points on every shape's outer boundary, used for the bounding box."""
    pts = []
    h = P["stroke"] / 2
    for i in range(0, 361):
        t = P["outer_from"] + (P["outer_to"] - P["outer_from"]) * i / 360
        x, y = pt(c, P["r3"], t)
        pts += [(x + h * math.cos(math.radians(k)), y + h * math.sin(math.radians(k))) for k in range(0, 360, 15)]
    e, tip = check_pts(c)
    pts += [(tip[0] + h * math.cos(math.radians(k)), tip[1] + h * math.sin(math.radians(k))) for k in range(0, 360, 5)]
    ha = P["arc_stroke"] / 2
    for r in RADII:
        for t in (P["inner_from"], P["inner_to"]):
            x, y = pt(c, r, t)
            pts += [(x + ha * math.cos(math.radians(k)), y + ha * math.sin(math.radians(k))) for k in range(0, 360, 5)]
    for k in range(0, 360, 5):
        pts.append((c[0] + P["dot_r"] * math.cos(math.radians(k)), c[1] + P["dot_r"] * math.sin(math.radians(k))))
    return pts


def bbox(c):
    pts = outline_points(c)
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def centre():
    x0, y0, x1, y1 = bbox((0.0, 0.0))
    return (P["target_cx"] - (x0 + x1) / 2, P["target_cy"] - (y0 + y1) / 2)


def seg_dist(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def report(c):
    e, tip = check_pts(c)
    x0, y0, x1, y1 = bbox(c)
    hc, ha = P["stroke"] / 2, P["arc_stroke"] / 2
    clear = min(seg_dist(pt(c, r, P["inner_from"] + (P["inner_to"] - P["inner_from"]) * i / 200), e, tip)
                for r in RADII for i in range(201)) - hc - ha
    dot_clear = seg_dist(c, e, tip) - hc - P["dot_r"]
    edges = [P["dot_r"]]
    for r in RADII:
        edges += [r - ha, r + ha]
    edges += [P["r3"] - hc]
    gaps = [round(edges[i + 1] - edges[i]) for i in range(0, len(edges) - 1, 2)]
    long_len = math.radians(P["outer_to"] - P["outer_from"]) * P["r3"]
    tangent = 180 - abs(180 - (P["arm_angle"] - (P["outer_to"] - 90)) % 360)
    s0 = pt(c, P["r3"], P["outer_from"])
    a1 = math.atan2(s0[1] - e[1], s0[0] - e[0])
    a2 = math.atan2(tip[1] - e[1], tip[0] - e[0])
    chord = abs(math.degrees(a1 - a2)) % 360
    chord = min(chord, 360 - chord)
    return {
        "centre": [round(v, 1) for v in c],
        "bbox": [round(v) for v in (x0, y0, x1, y1)],
        "size": [round(x1 - x0), round(y1 - y0)],
        "box_centre": [round((x0 + x1) / 2, 1), round((y0 + y1) / 2, 1)],
        "gaps": gaps,
        "arm_tip_clearance": round(clear, 1),
        "arm_dot_clearance": round(dot_clear, 1),
        "arm_ratio": f"1 : {long_len / P['arm_len']:.2f} (chord {math.dist(pt(c, P['r3'], P['outer_from']), e) / P['arm_len']:.2f})",
        "corner_deg_tangent": round(tangent, 1), "corner_deg_chord": round(chord, 1),
    }


def svg(body, vb="0 0 1024 1024", w=1024, h=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" '
            f'width="{w}" height="{h}">' + body + "</svg>\n")


def f(v):
    return f"{v:.1f}"


def band(c, r, a, b, h):
    """Filled outline of a round-capped arc stroke, traversed clockwise."""
    large = 1 if (b - a) > 180 else 0
    o0, o1 = pt(c, r + h, a), pt(c, r + h, b)
    i0, i1 = pt(c, r - h, a), pt(c, r - h, b)
    return (f"M{f(o0[0])} {f(o0[1])} A{f(r + h)} {f(r + h)} 0 {large} 1 {f(o1[0])} {f(o1[1])} "
            f"A{f(h)} {f(h)} 0 0 1 {f(i1[0])} {f(i1[1])} "
            f"A{f(r - h)} {f(r - h)} 0 {large} 0 {f(i0[0])} {f(i0[1])} "
            f"A{f(h)} {f(h)} 0 0 1 {f(o0[0])} {f(o0[1])} Z")


def capsule(v, e, h):
    """Filled outline of a round-capped straight stroke from v to e, clockwise."""
    dx, dy = e[0] - v[0], e[1] - v[1]
    n = math.hypot(dx, dy)
    nx, ny = -dy / n * h, dx / n * h
    pts = [(v[0] + nx, v[1] + ny), (e[0] + nx, e[1] + ny), (e[0] - nx, e[1] - ny), (v[0] - nx, v[1] - ny)]
    area = sum(pts[i][0] * pts[(i + 1) % 4][1] - pts[(i + 1) % 4][0] * pts[i][1] for i in range(4))
    if area < 0:
        pts = [(v[0] - nx, v[1] - ny), (e[0] - nx, e[1] - ny), (e[0] + nx, e[1] + ny), (v[0] + nx, v[1] + ny)]
    a, b, c2, d = pts
    return (f"M{f(a[0])} {f(a[1])} L{f(b[0])} {f(b[1])} A{f(h)} {f(h)} 0 0 1 {f(c2[0])} {f(c2[1])} "
            f"L{f(d[0])} {f(d[1])} A{f(h)} {f(h)} 0 0 1 {f(a[0])} {f(a[1])} Z")


def shapes(c):
    e, tip = check_pts(c)
    h = P["stroke"] / 2
    check = [band(c, P["r3"], P["outer_from"], P["outer_to"], h), capsule(e, tip, h)]
    arcs = [band(c, r, P["inner_from"], P["inner_to"], P["arc_stroke"] / 2) for r in RADII]
    return check, arcs


def paths(ds, fill):
    return "".join(f'<path fill="{fill}" d="{d}"/>' for d in ds)


def srgb(hexcol):
    v = [int(hexcol[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return "srgb:" + ",".join(f"{x:.5f}" for x in v) + ",1.00000"


def icon_json():
    def group(name, layer, shadow, transl):
        return {"name": name, "layers": [layer], "shadow": {"kind": shadow, "opacity": 0.5},
                "translucency": {"enabled": True, "value": transl}, "specular": True}
    def tint(v):
        return {"appearance": "tinted", "value": {"solid": f"srgb:{v:.5f},{v:.5f},{v:.5f},1.00000"}}
    dot = {"name": "dot", "image-name": "dot.svg", "glass": True,
           "fill-specializations": [tint(P["tint_dot"])]}
    check = {"name": "check", "image-name": "check.svg", "glass": True,
             "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(CHECK)}}]}
    arcs = {"name": "arcs", "image-name": "arcs.svg", "glass": True,
            "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(P["arcs_dark"])}},
                                     tint(P["tint_arcs"])]}
    return {
        "fill": {"linear-gradient": [srgb(P["top"]), srgb(P["bottom"])],
                 "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}},
        "groups": [group("dot", dot, "layer-color", 0.2),
                   group("check", check, "neutral", 0.2),
                   group("arcs", arcs, "neutral", P["arcs_translucency"])],
        "supported-platforms": {"squares": ["macOS"]},
    }


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def main():
    out = P["out"]
    c = centre()
    check, arcs = shapes(c)
    dot = f'<circle cx="{f(c[0])}" cy="{f(c[1])}" r="{f(P["dot_r"])}"'
    assets = os.path.join(out, "AppIcon.icon", "Assets")
    write(os.path.join(assets, "check.svg"), svg(paths(check, CHECK)))
    write(os.path.join(assets, "arcs.svg"), svg(paths(arcs, P["arc_col"])))
    write(os.path.join(assets, "dot.svg"), svg(dot + f' fill="{DOT}"/>'))
    write(os.path.join(out, "AppIcon.icon", "icon.json"), json.dumps(icon_json(), indent=2) + "\n")

    # Foreground-only marks, cropped to the glyph with a small even pad.
    x0, y0, x1, y1 = bbox(c)
    pad = 24
    side = max(x1 - x0, y1 - y0) + 2 * pad
    mx, my = (x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2
    vb = f"{f(mx)} {f(my)} {f(side)} {f(side)}"
    colour = paths(arcs, P["arc_col"]) + paths(check, CHECK) + dot + f' fill="{DOT}"/>'
    # The full-colour mark is light-on-transparent: dark surfaces only.
    write(os.path.join(out, "mark-on-dark.svg"), svg(colour, vb, 512, 512))
    light = paths(arcs, LIGHT_ARCS) + paths(check, LIGHT_CHECK) + dot + f' fill="{LIGHT_DOT}"/>'
    write(os.path.join(out, "mark-on-light.svg"), svg(light, vb, 512, 512))
    for name, col in (("mark-template.svg", "#000000"), ("mark-white.svg", "#FFFFFF"), ("mark-ink.svg", INK)):
        mono = f'<g fill="{col}">' + "".join(f'<path d="{d}"/>' for d in arcs + check) + dot + "/></g>"
        write(os.path.join(out, name), svg(mono, vb, 512, 512))
    flat = (f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{P["top"]}"/>'
            f'<stop offset="1" stop-color="{P["bottom"]}"/></linearGradient></defs>'
            '<rect width="1024" height="1024" rx="230" fill="url(#bg)"/>' + colour)
    write(os.path.join(out, "work", "flat.svg"), svg(flat))
    print(json.dumps(report(c)))


if __name__ == "__main__":
    main()
