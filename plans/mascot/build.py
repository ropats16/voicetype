#!/usr/bin/env python3
"""Generates mascot concept SVGs (+ index.html via build_html.py data).

Every pose SVG shares one rig so all candidates animate the same way:
  #pulse (behind) > #legs > #body > #face{#cheeks,#eyes,#brows,#mouth} > #hands > #fx
Coordinates are in a 120-unit body space; the viewBox adds margin for fx.
Run: python3 plans/mascot/build.py
"""
from pathlib import Path

HERE = Path(__file__).parent
OUT = "#3b2a22"      # shared outline / feature colour
CHEEK = "#ff8fa3"
TONGUE = "#ff7b8a"
PULSE = "#ff6f61"
SPARK = "#ffd34d"
SWEAT = "#8fd3ff"
SW = 3               # body outline width
VB = "-14 -12 148 148"
POSES = ["idle", "listening", "thinking", "done"]


def f(n):
    return f"{n:.1f}".rstrip("0").rstrip(".")


# ---------------------------------------------------------------- bodies
def body_yolk(pose=None):
    white = ("M30,44 C44,30 70,33 84,38 C101,44 111,58 105,74 C100,90 84,98 64,97 "
             "C44,100 22,96 16,80 C10,66 17,52 30,44 Z")
    return (f'<path id="white" d="{white}" fill="#fffaf0" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<circle id="yolk" cx="60" cy="64" r="25" fill="#ffc531" stroke="{OUT}" stroke-width="{SW}"/>'
            '<path d="M44,56 Q48,46 58,44" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".75"/>')


def body_avo_v1(pose=None):
    skin = ("M60,14 C76,14 82,30 86,46 C92,62 98,74 96,87 C94,101 80,107 60,107 "
            "C40,107 26,101 24,87 C22,74 28,62 34,46 C38,30 44,14 60,14 Z")
    flesh = ("M60,22 C72,22 77,35 80,49 C85,64 90,75 88,87 C86,97 76,100 60,100 "
             "C44,100 34,97 32,87 C30,75 35,64 40,49 C43,35 48,22 60,22 Z")
    return (f'<path id="skin" d="{skin}" fill="#4f8a3c" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<path id="flesh" d="{flesh}" fill="#d8eb9b"/>'
            f'<circle id="pit" cx="60" cy="82" r="12.5" fill="#a8673a" stroke="{OUT}" stroke-width="{SW}"/>'
            '<path d="M53,78 Q55,73 60,72" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" opacity=".6"/>')


def body_avo(pose=None):
    """v2: rounder, rotund belly; bigger round pit that doubles as the voice/level element."""
    skin = ("M60,16 C74,16 80,28 83,40 C86,51 100,60 100,80 C100,98 83,109 60,109 "
            "C37,109 20,98 20,80 C20,60 34,51 37,40 C40,28 46,16 60,16 Z")
    flesh = ("M60,24 C70,24 74,33 76,43 C79,54 92,63 92,80 C92,94 78,101 60,101 "
             "C42,101 28,94 28,80 C28,63 41,54 44,43 C46,33 50,24 60,24 Z")
    r = 15.5 if pose == "listening" else 14
    level = (f'<circle id="pit-level" cx="60" cy="85" r="{r + 4.5}" fill="none" stroke="{PULSE}" stroke-width="3" opacity=".9"/>'
             if pose == "listening" else "")
    return (f'<path id="skin" d="{skin}" fill="#4f8a3c" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<path id="flesh" d="{flesh}" fill="#d8eb9b"/>'
            f'<g id="pit">{level}<circle cx="60" cy="85" r="{r}" fill="#a8673a" stroke="{OUT}" stroke-width="{SW}"/>'
            f'<circle cx="62" cy="87" r="{r - 5}" fill="#95582f"/>'
            f'<path d="M{60 - r * .62:.1f},{85 - r * .1:.1f} Q{60 - r * .5:.1f},{85 - r * .62:.1f} {60:.1f},{85 - r * .66:.1f}" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" opacity=".65"/></g>')


def body_lemon_v4(pose=None):
    """v4: v2's vertical body, but both tips are soft, rounded, slightly bulbous bumps; stem + leaf on the top bump."""
    p = ("M54.5,21.5 C52.5,15 67.5,15 65.5,21.5 C82,23.5 94,40 94,61 C94,83 82,99 65.5,102.5 "
         "C67.5,109.5 52.5,109.5 54.5,102.5 C38,99 26,83 26,61 C26,40 38,23.5 54.5,21.5 Z")
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#fff3a6"/>'
                   for x, y in [(40, 40), (82, 44), (86, 74), (34, 76), (70, 94), (48, 92)])
    return (f'<path id="stem" d="M60,18 C60,14 61,11 63,8" fill="none" stroke="{OUT}" stroke-width="3.4" stroke-linecap="round"/>'
            f'<path id="leaf" d="M62,9 C65,0 75,-4 85,-1 C82,8 72,12 62,9 Z" fill="#7cc36b" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path d="M64,8 Q73,4 81,1" fill="none" stroke="#5aa24c" stroke-width="1.6" stroke-linecap="round"/>'
            f'<path id="skin" d="{p}" fill="#ffe14d" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<g id="peel">{dots}</g>'
            '<path d="M34,52 Q37,36 50,28" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".7"/>')


def body_lemon(pose=None):
    """v3: plump, almost round (~1.1:1), both ends fully rounded with tiny soft nubs; one stem + one leaf."""
    p = ("M57,21 C58,18.8 62,18.8 63,21 C83,23 98,40 98,62 C98,85 82,101 63,103 "
         "C62,105.6 58,105.6 57,103 C38,101 22,85 22,62 C22,40 37,23 57,21 Z")
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#fff3a6"/>'
                   for x, y in [(38, 40), (84, 42), (90, 72), (30, 76), (72, 94), (46, 94)])
    return (f'<path id="stem" d="M60,21 C60,17 61,14 63,11" fill="none" stroke="{OUT}" stroke-width="3.4" stroke-linecap="round"/>'
            f'<path id="leaf" d="M62,12 C65,3 75,-1 85,2 C82,11 72,15 62,12 Z" fill="#7cc36b" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path d="M64,11 Q73,7 81,4" fill="none" stroke="#5aa24c" stroke-width="1.6" stroke-linecap="round"/>'
            f'<path id="skin" d="{p}" fill="#ffe14d" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<g id="peel">{dots}</g>'
            '<path d="M31,52 Q34,36 48,28" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".7"/>')


def body_lemon_v2(pose=None):
    """v2: vertical, soft rounded ends, gentle nub at the bottom, one stem + one leaf on top."""
    p = ("M60,20 C81,20 94,39 94,61 C94,83 82,99 65,103 C63,104 62,107 60,107 C58,107 57,104 55,103 "
         "C38,99 26,83 26,61 C26,39 39,20 60,20 Z")
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#fff3a6"/>'
                   for x, y in [(40, 40), (82, 44), (86, 74), (34, 76), (70, 94), (48, 92)])
    return (f'<path id="stem" d="M60,22 C60,18 61,15 63,12" fill="none" stroke="{OUT}" stroke-width="3.4" stroke-linecap="round"/>'
            f'<path id="leaf" d="M62,13 C65,4 75,0 85,3 C82,12 72,16 62,13 Z" fill="#7cc36b" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path d="M64,12 Q73,8 81,5" fill="none" stroke="#5aa24c" stroke-width="1.6" stroke-linecap="round"/>'
            f'<path id="skin" d="{p}" fill="#ffe14d" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<g id="peel">{dots}</g>'
            '<path d="M34,52 Q37,36 50,28" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".7"/>')


def body_lemon_v1(pose=None):
    p = ("M9,63 C13,61.5 16.5,58.5 19.5,54 C29,37 45,30 60,30 C75,30 91,37 100.5,54 "
         "C103.5,58.5 107,61.5 111,63 C107,64.5 103.5,67.5 100.5,72 C91,89 75,96 60,96 "
         "C45,96 29,89 19.5,72 C16.5,67.5 13,64.5 9,63 Z")
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#fff3a6"/>'
                   for x, y in [(34, 48), (86, 46), (92, 72), (30, 76), (72, 88), (46, 88)])
    return (f'<path id="leaf" d="M62,31 C64,20 74,15 84,17 C81,27 72,31 62,31 Z" fill="#7cc36b" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path id="skin" d="{p}" fill="#ffe14d" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<g id="peel">{dots}</g>'
            '<path d="M28,56 Q36,42 50,37" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".7"/>')


def body_peach(pose=None):
    p = ("M60,30 C66,22 80,20 90,30 C102,42 104,62 98,78 C92,94 78,103 60,103 "
         "C42,103 28,94 22,78 C16,62 18,42 30,30 C40,20 54,22 60,30 Z")
    return (f'<path id="leaf" d="M60,29 C61,17 71,10 83,12 C81,23 71,29 60,29 Z" fill="#7cc36b" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path id="skin" d="{p}" fill="#ffb38a" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            '<path id="cleft" d="M60,31 C55,38 54,46 57,53" fill="none" stroke="#ef8a66" stroke-width="2.6" stroke-linecap="round"/>'
            '<path d="M30,52 Q32,40 42,34" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".6"/>')


def body_mikan(pose=None):
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="1.3" fill="#ffc06a"/>'
                   for x, y in [(36, 50), (84, 46), (88, 76), (32, 80), (74, 92), (46, 92), (92, 60)])
    return (f'<ellipse id="skin" cx="60" cy="65" rx="40" ry="37" fill="#ff9f2e" stroke="{OUT}" stroke-width="{SW}"/>'
            f'<g id="peel">{dots}</g>'
            f'<path id="stem" d="M60,29 L60,22" stroke="{OUT}" stroke-width="3.4" stroke-linecap="round"/>'
            f'<g id="leaf"><path d="M58,26 C52,17 42,17 37,21 C42,28 52,29 58,26 Z" fill="#6fbf5a" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'
            f'<path d="M62,26 C68,17 78,17 83,21 C78,28 68,29 62,26 Z" fill="#6fbf5a" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/></g>'
            '<path d="M30,56 Q33,42 46,35" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".55"/>')


def body_hum(pose=None):
    d = ("M60,24 C86,24 100,46 100,72 C100,94 86,103 60,103 C34,103 20,94 20,72 "
         "C20,46 34,24 60,24 Z")
    return (f'<path id="sprout" d="M60,25 C58,15 62,8 70,9 C76,10 77,17 72,19" fill="none" stroke="{OUT}" stroke-width="3" stroke-linecap="round"/>'
            f'<path id="skin" d="{d}" fill="#c9b6ff" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            '<ellipse id="belly" cx="60" cy="86" rx="22" ry="12" fill="#e4dbff"/>'
            '<path d="M30,60 Q33,44 46,36" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".6"/>')


# face=(x,y) eye-centre line, ex=half eye spacing, md=mouth offset,
# arms=anchors (L,R), hand=hand fill, legs=x's, lt=leg top y, tl/tr=head corners for fx,
# pc/pr=pulse ring centre + radii
CHARS = {
    "egg": dict(title="Yolk", species="Sunny-side-up egg", body=body_yolk,
                 face=(60, 61), ex=9, md=10, arms=((17, 72), (103, 70)), hand="#fffaf0",
                 legs=(49, 71), lt=94, tl=(24, 40), tr=(96, 40), pc=(60, 68), pr=(53, 62),
                 colors=["#ffc531", "#fffaf0", "#3b2a22", "#ff8fa3"]),
    "avocado": dict(title="Avocado", species="Avocado (v2, rotund)", body=body_avo,
                    face=(60, 53), ex=8.5, md=8.5, arms=((22, 76), (98, 76)), hand="#4f8a3c",
                    legs=(49, 71), lt=106, tl=(40, 26), tr=(80, 26), pc=(60, 66), pr=(55, 64),
                    colors=["#4f8a3c", "#d8eb9b", "#a8673a", "#ff8fa3"]),
    "avocado-v1": dict(title="Avocado v1", species="Avocado (v1)", body=body_avo_v1,
                       face=(60, 50), ex=8.5, md=9.5, arms=((27, 72), (93, 72)), hand="#4f8a3c",
                       legs=(50, 70), lt=104, tl=(38, 22), tr=(82, 22), pc=(60, 62), pr=(52, 61),
                       colors=["#4f8a3c", "#d8eb9b", "#a8673a", "#ff8fa3"]),
    "lemon-v3": dict(title="Zesty v3", species="Lemon (v3, plump)", body=body_lemon,
                  face=(60, 60), ex=10, md=10, arms=((24, 72), (96, 72)), hand="#ffe14d",
                  legs=(49, 71), lt=101, tl=(28, 30), tr=(94, 30), pc=(60, 62), pr=(54, 63),
                  colors=["#ffe14d", "#fff3a6", "#7cc36b", "#ff8fa3"]),
    "lemon-v4": dict(title="Zesty", species="Lemon (v4, rounded tips)", body=body_lemon_v4,
                     face=(60, 60), ex=10, md=10, arms=((28, 72), (92, 72)), hand="#ffe14d",
                     legs=(49, 71), lt=101, tl=(30, 30), tr=(92, 28), pc=(60, 62), pr=(53, 62),
                     colors=["#ffe14d", "#fff3a6", "#7cc36b", "#ff8fa3"]),
    "lemon-v2": dict(title="Zesty v2", species="Lemon (v2, vertical)", body=body_lemon_v2,
                  face=(60, 60), ex=10, md=10, arms=((28, 72), (92, 72)), hand="#ffe14d",
                  legs=(49, 71), lt=101, tl=(30, 32), tr=(92, 32), pc=(60, 62), pr=(53, 62),
                  colors=["#ffe14d", "#fff3a6", "#7cc36b", "#ff8fa3"]),
    "lemon-v1": dict(title="Lemon v1", species="Lemon (v1, pointed)", body=body_lemon_v1,
                  face=(60, 61), ex=10, md=10, arms=((26, 79), (94, 79)), hand="#ffe14d",
                  legs=(49, 71), lt=93, tl=(26, 40), tr=(96, 40), pc=(60, 63), pr=(57, 65),
                  colors=["#ffe14d", "#fff3a6", "#7cc36b", "#ff8fa3"]),
    "peach": dict(title="Peachy", species="Peach", body=body_peach,
                  face=(60, 64), ex=10, md=10, arms=((21, 74), (99, 74)), hand="#ffb38a",
                  legs=(49, 71), lt=99, tl=(24, 34), tr=(100, 38), pc=(60, 64), pr=(50, 59),
                  colors=["#ffb38a", "#ef8a66", "#7cc36b", "#ff8fa3"]),
    "tangerine": dict(title="Tangerine", species="Tangerine", body=body_mikan,
                  face=(60, 64), ex=10, md=10, arms=((21, 70), (99, 70)), hand="#ff9f2e",
                  legs=(49, 71), lt=98, tl=(22, 38), tr=(96, 36), pc=(60, 65), pr=(50, 59),
                  colors=["#ff9f2e", "#ffc06a", "#6fbf5a", "#ff8fa3"]),
    "blob": dict(title="Blob", species="Original blob (lavender gumdrop w/ sprout)", body=body_hum,
                face=(60, 63), ex=10, md=10, arms=((21, 76), (99, 76)), hand="#c9b6ff",
                legs=(49, 71), lt=99, tl=(26, 34), tr=(94, 34), pc=(60, 64), pr=(50, 59),
                colors=["#c9b6ff", "#e4dbff", "#3b2a22", "#ff8fa3"]),
}


# ---------------------------------------------------------------- parts
def eye_dot(x, y, rx=3.4, ry=4.4, big=False):
    s = f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="{rx}" ry="{ry}" fill="{OUT}"/>'
    s += f'<circle cx="{f(x - rx * .32)}" cy="{f(y - ry * .38)}" r="{f(rx * .4)}" fill="#fff"/>'
    if big:
        s += f'<circle cx="{f(x + rx * .35)}" cy="{f(y + ry * .35)}" r="{f(rx * .2)}" fill="#fff"/>'
    return s


def eyes(c, pose):
    fx, fy = c["face"]
    ex = c["ex"]
    L, R = fx - ex, fx + ex
    if pose == "idle":
        return f'<g id="eye-l">{eye_dot(L, fy)}</g><g id="eye-r">{eye_dot(R, fy)}</g>'
    if pose == "listening":
        return (f'<g id="eye-l">{eye_dot(L, fy - .5, 4.2, 5.4, True)}</g>'
                f'<g id="eye-r">{eye_dot(R, fy - .5, 4.2, 5.4, True)}</g>')
    if pose == "thinking":  # pupils look up-right
        return (f'<g id="eye-l">{eye_dot(L + 1.4, fy - 1.6, 3.2, 4.2)}</g>'
                f'<g id="eye-r">{eye_dot(R + 1.4, fy - 1.6, 3.2, 4.2)}</g>')
    # done: wink left, open right
    return (f'<g id="eye-l"><path d="M{f(L - 4)},{f(fy + 1)} Q{f(L)},{f(fy - 4.5)} {f(L + 4)},{f(fy + 1)}" '
            f'fill="none" stroke="{OUT}" stroke-width="2.8" stroke-linecap="round"/></g>'
            f'<g id="eye-r">{eye_dot(R, fy)}</g>')


def brows(c, pose):
    if pose != "thinking":
        return ""
    fx, fy = c["face"]
    ex = c["ex"]
    y = fy - 9
    return (f'<g id="brows"><path d="M{f(fx - ex - 4)},{f(y + 1)} Q{f(fx - ex)},{f(y - 2)} {f(fx - ex + 4)},{f(y)}" fill="none" stroke="{OUT}" stroke-width="2.2" stroke-linecap="round"/>'
            f'<path d="M{f(fx + ex - 4)},{f(y - 1)} Q{f(fx + ex)},{f(y - 3.5)} {f(fx + ex + 4)},{f(y - 1.5)}" fill="none" stroke="{OUT}" stroke-width="2.2" stroke-linecap="round"/></g>')


def mouth(c, pose):
    fx, fy = c["face"]
    my = fy + c["md"]
    if pose == "idle":
        return f'<path d="M{f(fx - 5)},{f(my)} Q{f(fx)},{f(my + 5)} {f(fx + 5)},{f(my)}" fill="none" stroke="{OUT}" stroke-width="2.6" stroke-linecap="round"/>'
    if pose == "listening":
        return (f'<ellipse cx="{f(fx)}" cy="{f(my + 2)}" rx="4.2" ry="5" fill="{OUT}"/>'
                f'<ellipse cx="{f(fx)}" cy="{f(my + 4.6)}" rx="2.6" ry="1.6" fill="{TONGUE}"/>')
    if pose == "thinking":
        x = fx + 2
        return (f'<path d="M{f(x - 4)},{f(my + 2)} Q{f(x - 2)},{f(my)} {f(x)},{f(my + 2)} Q{f(x + 2)},{f(my + 4)} {f(x + 4)},{f(my + 2)}" '
                f'fill="none" stroke="{OUT}" stroke-width="2.4" stroke-linecap="round"/>')
    return (f'<path d="M{f(fx - 7)},{f(my)} Q{f(fx)},{f(my + 12)} {f(fx + 7)},{f(my)} Z" fill="{OUT}" stroke="{OUT}" stroke-width="2" stroke-linejoin="round"/>'
            f'<ellipse cx="{f(fx)}" cy="{f(my + 4.2)}" rx="2.8" ry="1.5" fill="{TONGUE}"/>')


def cheeks(c):
    fx, fy = c["face"]
    d = c["ex"] + 7
    return "".join(f'<ellipse cx="{f(fx + s * d)}" cy="{f(fy + 5)}" rx="4.6" ry="2.8" fill="{CHEEK}" opacity=".8"/>'
                   for s in (-1, 1))


def arm(anchor, end, hand, side, thumb=False):
    ax, ay = anchor
    ex_, ey = end
    cx, cy = ax + (ex_ - ax) * .9, ay + (ey - ay) * .15
    s = (f'<path d="M{f(ax)},{f(ay)} Q{f(cx)},{f(cy)} {f(ex_)},{f(ey)}" fill="none" stroke="{OUT}" '
         f'stroke-width="3.2" stroke-linecap="round"/>')
    if thumb:
        s += f'<ellipse cx="{f(ex_)}" cy="{f(ey - 6)}" rx="2.5" ry="4.3" fill="{hand}" stroke="{OUT}" stroke-width="2"/>'
    s += f'<circle cx="{f(ex_)}" cy="{f(ey)}" r="4.3" fill="{hand}" stroke="{OUT}" stroke-width="2.4"/>'
    return f'<g id="hand-{side}">{s}</g>'


def hands(c, pose):
    (lx, ly), (rx, ry) = c["arms"]
    h = c["hand"]
    fx, fy = c["face"]
    down_l, down_r = (lx - 8, ly + 14), (rx + 8, ry + 14)
    if pose == "idle":
        return arm((lx, ly), down_l, h, "l") + arm((rx, ry), down_r, h, "r")
    if pose == "listening":
        return arm((lx, ly), (lx - 9, ly - 21), h, "l") + arm((rx, ry), (rx + 9, ry - 21), h, "r")
    if pose == "thinking":
        chin = (fx + c["ex"] + 7, fy + c["md"] + 6)
        return arm((lx, ly), down_l, h, "l") + arm((rx, ry), chin, h, "r")
    return arm((lx, ly), down_l, h, "l") + arm((rx, ry), (rx + 12, ry - 19), h, "r", thumb=True)


def legs(c, pose):
    x1, x2 = c["legs"]
    t = c["lt"]
    out = []
    for side, x, s in (("l", x1, -1), ("r", x2, 1)):
        if pose == "done" and side == "r":  # little kick
            fx_, fy_ = x + 8, t + 8
            out.append(f'<g id="leg-{side}"><path d="M{f(x)},{f(t)} L{f(fx_ - 2)},{f(fy_)}" stroke="{OUT}" stroke-width="4" stroke-linecap="round"/>'
                       f'<ellipse cx="{f(fx_ + 1)}" cy="{f(fy_)}" rx="5.4" ry="3.1" transform="rotate(-25 {f(fx_ + 1)} {f(fy_)})" fill="{OUT}"/></g>')
            continue
        out.append(f'<g id="leg-{side}"><path d="M{f(x)},{f(t)} L{f(x + s)},{f(t + 9)}" stroke="{OUT}" stroke-width="4" stroke-linecap="round"/>'
                   f'<ellipse cx="{f(x + s * 3)}" cy="{f(t + 10.5)}" rx="5.6" ry="3.2" fill="{OUT}"/></g>')
    return "".join(out)


def sparkle(x, y, r):
    i = r * .3
    d = (f"M{f(x)},{f(y - r)} Q{f(x + i)},{f(y - i)} {f(x + r)},{f(y)} Q{f(x + i)},{f(y + i)} {f(x)},{f(y + r)} "
         f"Q{f(x - i)},{f(y + i)} {f(x - r)},{f(y)} Q{f(x - i)},{f(y - i)} {f(x)},{f(y - r)} Z")
    return f'<path d="{d}" fill="{SPARK}" stroke="{OUT}" stroke-width="1.8" stroke-linejoin="round"/>'


def pulse(c, pose):
    if pose != "listening":
        return ""
    (x, y), (r1, r2) = c["pc"], c["pr"]
    return (f'<g id="pulse"><circle class="ring1" cx="{x}" cy="{y}" r="{r1}" fill="none" stroke="{PULSE}" stroke-width="3" opacity=".55"/>'
            f'<circle class="ring2" cx="{x}" cy="{y}" r="{r2}" fill="none" stroke="{PULSE}" stroke-width="2.5" opacity=".25"/></g>')


def fx(c, pose):
    (tlx, tly), (trx, try_) = c["tl"], c["tr"]
    if pose == "thinking":
        drop = (f'<path d="M{f(tlx)},{f(tly - 9)} C{f(tlx + 5)},{f(tly - 2)} {f(tlx + 5)},{f(tly + 3)} {f(tlx)},{f(tly + 3)} '
                f'C{f(tlx - 5)},{f(tly + 3)} {f(tlx - 5)},{f(tly - 2)} {f(tlx)},{f(tly - 9)} Z" fill="{SWEAT}" stroke="{OUT}" stroke-width="2" stroke-linejoin="round"/>')
        dots = "".join(f'<circle class="dot{i + 1}" cx="{f(trx + dx)}" cy="{f(try_ + dy)}" r="{r}" fill="{OUT}"/>'
                       for i, (dx, dy, r) in enumerate([(2, -2, 2.2), (9, -7, 2.8), (17, -13, 3.4)]))
        return f'<g id="sweat">{drop}</g><g id="dots">{dots}</g>'
    if pose == "done":
        return (f'<g id="sparkles">{sparkle(trx + 8, try_ - 6, 7)}{sparkle(tlx - 4, tly - 4, 5)}'
                f'{sparkle(tlx - 10, tly + 20, 4)}</g>')
    return ""


def pose_svg(key, pose):
    c = CHARS[key]
    parts = [
        pulse(c, pose),
        f'<g id="legs">{legs(c, pose)}</g>',
        f'<g id="body">{c["body"](pose)}</g>',
        f'<g id="face"><g id="cheeks">{cheeks(c)}</g><g id="eyes">{eyes(c, pose)}</g>{brows(c, pose)}<g id="mouth">{mouth(c, pose)}</g></g>',
        f'<g id="hands">{hands(c, pose)}</g>',
        f'<g id="fx">{fx(c, pose)}</g>',
    ]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{VB}" width="120" height="120">'
            f'<title>{c["title"]} — {pose}</title>' + "".join(p for p in parts if p) + "</svg>\n")


# ---------------------------------------------------------------- menu-bar template glyphs
# 22x22, pure black on transparent (macOS template image: alpha only).
# Face features are knocked out with a mask so they stay transparent.
def circ(cx, cy, r):
    return f"M{f(cx - r)},{f(cy)} a{f(r)},{f(r)} 0 1,0 {f(2 * r)},0 a{f(r)},{f(r)} 0 1,0 {f(-2 * r)},0 Z"


def face_cut(cx, cy, dx, r=1.0, smile=1.9):
    return (f'<path d="{circ(cx - dx, cy, r)} {circ(cx + dx, cy, r)}" fill="#000"/>'
            f'<path d="M{f(cx - 1.2)},{f(cy + smile)} Q{f(cx)},{f(cy + smile + 1.1)} {f(cx + 1.2)},{f(cy + smile)}" '
            'fill="none" stroke="#000" stroke-width="1" stroke-linecap="round"/>')


# key -> (solid silhouette, knock-outs)
MENUBAR = {
    "egg": (
        '<path d="M5.4,5.8 C8,3.3 13,3.8 15.6,4.7 C19,5.9 21,8.5 19.9,11.7 C19,14.7 16,16.3 12.2,16.1 '
        'C8.4,16.7 4.2,15.9 3,12.9 C1.9,10.3 3,7.3 5.4,5.8 Z"/>'
        '<path d="M8.2,16 v3 M14.2,16 v3" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        '<circle cx="11.2" cy="10.4" r="5.1" fill="none" stroke="#000" stroke-width="1.2"/>'
        + face_cut(11.2, 9.8, 1.8, .95, 1.7)),
    "avocado": (
        '<path fill-rule="evenodd" d="M11,2 C13.6,2 14.6,4.2 15.1,6.4 C15.6,8.4 18.6,10 18.6,13.8 C18.6,17.6 15.4,20 11,20 '
        'C6.6,20 3.4,17.6 3.4,13.8 C3.4,10 6.4,8.4 6.9,6.4 C7.4,4.2 8.4,2 11,2 Z '
        'M11,3.6 C12.6,3.6 13.2,5.1 13.6,6.9 C14.1,9 17,10.6 17,13.8 C17,16.6 14.6,18.4 11,18.4 '
        'C7.4,18.4 5,16.6 5,13.8 C5,10.6 7.9,9 8.4,6.9 C8.8,5.1 9.4,3.6 11,3.6 Z"/>'
        f'<path d="{circ(11, 14.9, 2.9)} {circ(9.5, 9.1, .9)} {circ(12.5, 9.1, .9)}"/>'
        '<path d="M10,10.8 Q11,11.6 12,10.8" fill="none" stroke="#000" stroke-width=".9" stroke-linecap="round"/>',
        ""),
    "avocado-v1": (
        '<path fill-rule="evenodd" d="M11,1.6 C14,1.6 15.1,4.6 15.9,7.6 C17,10.8 18.2,13 17.8,15.4 C17.4,18.2 14.8,19.6 11,19.6 '
        'C7.2,19.6 4.6,18.2 4.2,15.4 C3.8,13 5,10.8 6.1,7.6 C6.9,4.6 8,1.6 11,1.6 Z '
        'M11,3.3 C13,3.3 13.7,5.6 14.3,8 C15.2,10.9 16.2,12.9 15.9,15.1 C15.6,17.2 13.8,17.9 11,17.9 '
        'C8.2,17.9 6.4,17.2 6.1,15.1 C5.8,12.9 6.8,10.9 7.7,8 C8.3,5.6 9,3.3 11,3.3 Z"/>'
        f'<path d="{circ(11, 14.5, 2.5)} {circ(9.3, 8.6, .95)} {circ(12.7, 8.6, .95)}"/>'
        '<path d="M9.9,10.6 Q11,11.6 12.1,10.6" fill="none" stroke="#000" stroke-width="1" stroke-linecap="round"/>',
        ""),
    "peach": (
        '<path d="M11.4,4.2 C11.8,2.2 13.6,1.1 15.8,1.4 C15.4,3.4 13.6,4.4 11.4,4.2 Z"/>'
        '<path d="M11,5.6 C12.2,4.2 14.8,3.8 16.6,5.6 C18.8,7.8 19.2,11.4 18.1,14.4 '
        'C17,17.4 14.4,19.1 11,19.1 C7.6,19.1 5,17.4 3.9,14.4 C2.8,11.4 3.2,7.8 5.4,5.6 C7.2,3.8 9.8,4.2 11,5.6 Z"/>',
        '<path d="M11,5.6 C10.1,6.8 10,8 10.4,9" fill="none" stroke="#000" stroke-width="1" stroke-linecap="round"/>'
        + face_cut(11, 11.8, 2.1)),
    "lemon-v4": (
        '<path d="M11,3.8 C11,2.9 11.3,2.3 11.8,1.8" fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round"/>'
        '<path d="M11.5,2.3 C12.3,0.5 14.6,0 16.9,0.5 C16.1,2.5 13.9,3.1 11.5,2.3 Z"/>'
        '<path d="M9.9,4.6 C9.4,3.2 12.6,3.2 12.1,4.6 C15.3,5 17.4,8 17.4,11.4 C17.4,15 15.3,17.4 12.1,18 '
        'C12.6,19.5 9.4,19.5 9.9,18 C6.7,17.4 4.6,15 4.6,11.4 C4.6,8 6.7,5 9.9,4.6 Z"/>'
        '<path d="M7.9,17.2 v3.1 M14.1,17.2 v3.1" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        face_cut(11, 10.6, 2.3, 1.05, 1.9)),
    "lemon-v3": (
        '<path d="M11,4.3 C11,3.2 11.3,2.5 11.9,1.9" fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round"/>'
        '<path d="M11.6,2.5 C12.4,0.5 14.8,-0.2 17.1,0.5 C16.3,2.6 14,3.3 11.6,2.5 Z"/>'
        '<path d="M10.3,4.5 C10.5,3.9 11.5,3.9 11.7,4.5 C15.3,4.9 17.8,7.9 17.8,11.6 C17.8,15.3 15.2,17.8 11.7,18.2 '
        'C11.5,18.9 10.5,18.9 10.3,18.2 C6.8,17.8 4.2,15.3 4.2,11.6 C4.2,7.9 6.7,4.9 10.3,4.5 Z"/>'
        '<path d="M8.3,17.4 v3 M13.7,17.4 v3" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        face_cut(11, 10.8, 2.4, 1.05, 1.9)),
    "lemon-v2": (
        '<path d="M11,4.6 C11,3.4 11.3,2.6 11.9,1.9" fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round"/>'
        '<path d="M11.6,2.5 C12.4,0.5 14.8,-0.2 17.1,0.5 C16.3,2.6 14,3.3 11.6,2.5 Z"/>'
        '<path d="M11,4.3 C15,4.3 17.4,7.7 17.4,11.4 C17.4,15 15.3,17.5 12.2,18.1 C11.9,18.3 11.6,18.9 11,18.9 '
        'C10.4,18.9 10.1,18.3 9.8,18.1 C6.7,17.5 4.6,15 4.6,11.4 C4.6,7.7 7,4.3 11,4.3 Z"/>'
        '<path d="M8.4,17.4 v3 M13.6,17.4 v3" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        face_cut(11, 10.6, 2.3, 1.05, 1.9)),
    "lemon-v1": (
        '<path d="M11.6,4.4 C12.2,2.4 14,1.5 16,1.8 C15.4,3.6 13.6,4.5 11.6,4.4 Z"/>'
        '<path d="M1.4,10.6 C2.2,10.2 2.9,9.6 3.5,8.8 C5.3,5.7 8.1,4.5 11,4.5 C13.9,4.5 16.7,5.7 18.5,8.8 '
        'C19.1,9.6 19.8,10.2 20.6,10.6 C19.8,11 19.1,11.6 18.5,12.4 C16.7,15.5 13.9,16.7 11,16.7 '
        'C8.1,16.7 5.3,15.5 3.5,12.4 C2.9,11.6 2.2,11 1.4,10.6 Z"/>'
        '<path d="M8.4,16.2 v3 M13.6,16.2 v3" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        face_cut(11, 10.1, 2.3, 1.05, 1.8)),
    "tangerine": (
        '<path d="M10.4,3.7 C9,1.8 6.8,1.8 5.4,2.8 C6.7,4.3 9,4.5 10.4,3.7 Z"/>'
        '<path d="M11.6,3.7 C13,1.8 15.2,1.8 16.6,2.8 C15.3,4.3 13,4.5 11.6,3.7 Z"/>'
        '<path d="M11,4.6 V2.6" stroke="#000" stroke-width="1.3" stroke-linecap="round"/>'
        '<ellipse cx="11" cy="10.9" rx="8.4" ry="6.6"/>'
        '<path d="M8.2,17 v2.6 M13.8,17 v2.6" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
        face_cut(11, 10.3, 2.5, 1.15, 1.9)),
    "tangerine-v1": (
        '<path d="M10.6,4.2 C9.4,2 7.2,1.8 6,2.6 C7,4.4 9.2,4.8 10.6,4.2 Z"/>'
        '<path d="M11.2,4.8 V2.6" stroke="#000" stroke-width="1.4" stroke-linecap="round"/>'
        '<ellipse cx="11" cy="12" rx="7.8" ry="7.2"/>',
        face_cut(11, 11.4, 2.2)),
    "blob": (
        '<path d="M11,5 C10.6,3 11.4,1.6 13,1.8 C14.2,2 14.4,3.4 13.4,3.8" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="round"/>'
        '<path d="M11,4.6 C16,4.6 18.6,8.8 18.6,13.4 C18.6,17.4 16,19.2 11,19.2 '
        'C6,19.2 3.4,17.4 3.4,13.4 C3.4,8.8 6,4.6 11,4.6 Z"/>',
        face_cut(11, 11.8, 2.2)),
}


def menubar_svg(key):
    solid, cut = MENUBAR[key]
    title = f'<title>{CHARS[key]["title"] if key in CHARS else key} menu-bar template</title>'
    if not cut:
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 22" width="22" height="22">{title}'
                f'<g id="glyph" fill="#000">{solid}</g></svg>\n')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 22" width="22" height="22">{title}'
            f'<defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="22" height="22">'
            f'<rect width="22" height="22" fill="#fff"/>{cut}</mask></defs>'
            f'<g id="glyph" fill="#000" mask="url(#cut)">{solid}</g></svg>\n')


def main():
    for key in CHARS:
        for pose in POSES:
            (HERE / f"{key}-{pose}.svg").write_text(pose_svg(key, pose))
    for key in MENUBAR:
        (HERE / f"{key}-menubar.svg").write_text(menubar_svg(key))
    print("wrote", len(CHARS) * 4 + len(MENUBAR), "svgs")


if __name__ == "__main__":
    main()
