#!/usr/bin/env python3
"""Builds plans/mascot/index.html (self-contained) from the SVGs + name research.
Run after build.py:  python3 plans/mascot/build.py && python3 plans/mascot/build_html.py
"""
import re
from html import escape
from pathlib import Path

from build import CHARS, POSES

HERE = Path(__file__).parent
ORDER = ["lemon-v4", "avocado", "egg", "tangerine"]  # round 3: new lemon first; egg = baseline
OVERVIEW = ["lemon-v4", "lemon-v2", "lemon-v1", "avocado", "egg"]
ARCHIVE = ["lemon-v3", "peach", "blob"]  # round 1, dropped

BLURB = {
    "egg": ("Baseline from round 1. A fried egg: squishy white body, yolk face. The white jiggles, the yolk can swell with mic level.",
            "Unique silhouette. The shape is wide, so the face is smallish at 120 px."),
    "avocado": ("v2: the belly is now a full round bottom and the pit is bigger and rounder (it has an inner shade and a highlight). The pit is the voice element: when listening it grows and gets a level ring that can pulse with mic level.",
                "Most readable silhouette at 18 px: an outline pear with a solid round pit. Avocado mascots are common in stickers and food apps, so the name has to do the distinguishing."),
    "tangerine": ("Tangerine with peel dots, a stem and twin leaves.",
                  "Menu-bar fix: the old glyph was round with one tilted leaf, which looked like the Apple logo. The new one is squat, with symmetric twin leaves, a bigger knocked-out face and little legs, so it reads as a character, not an apple."),
    "lemon-v4": ("Round 5 (\u201cZesty\u201d): v2's vertical body, unchanged, but both pointy ends are now soft, rounded, slightly bulbous bumps, like a cartoon lemon's tips. The stem and leaf sit on the top bump.",
                 "Glyph: the same tall oval as v2 with a rounded bump at each end, an upright stem and one side leaf, legs and a knocked-out face. It isn't the tangerine (taller than wide, bumps at both ends, a single leaf, yellow) and it isn't the Apple logo (no bite, attached stem, legs, face)."),
    "lemon-v3": ("Round 4 (\u201cZesty\u201d): a plump, chubby, almost-round lemon, only about 1.1:1 taller than wide. Both ends are fully rounded, with a tiny soft nub under the stem and another at the bottom. One stem and one leaf on top. It keeps our flat style, face, cheeks, little hands and legs.",
              "Glyph: a near-round body with a tiny nub top and bottom, one upright stem and one leaf off to the side, legs and a knocked-out face. Why it isn't the tangerine: the body is slightly taller than wide (the tangerine is squat), it has nubs at both ends (the tangerine has none), and it has a single side leaf on a stem (the tangerine has twin symmetric leaves). In colour it's yellow, not orange. It isn't the Apple logo because there's no bite, the stem is attached and upright, and it has legs and a face."),
    "lemon-v2": ("Round 3 lemon: vertical, taller than wide, soft ends, a bottom nub.",
              "The glyph is a tall oval, stem and leaf on top, nub and legs at the bottom, and a knocked-out face. The stem and leaf separate it from an egg or plain oval. The attached upright stem, the legs and the face (and no bite) separate it from the Apple logo."),
    "lemon-v1": ("Round 2 lemon: a horizontal oval with pointed tips.",
              "The pointed-tip oval is the most distinctive outline at 18 px after the egg, and it can't be mistaken for an apple. The wide shape means the hands sit under the tips."),
    "peach": ("A round peach with a cleft and a leaf.", "Dropped in round 2: it read as the Apple logo at 18 px."),
    "blob": ("An original lavender gumdrop with a sprout.", "Dropped in round 2: no free name."),
}

# name, character, MAS, GitHub, domains, trademarks/products, verdict class, verdict text
NAMES = [
    ("Yolk", "egg",
     'Nothing named exactly "Yolk" on MAS; no dictation/notes app found (<a href="https://apps.apple.com/app/id975001906">Digital YolkFan</a> unrelated)',
     '<a href="https://github.com/garbles/yolk">garbles/yolk</a> 921★ UI lib, <a href="https://github.com/elkowar/yolk">elkowar/yolk</a> 449★ dotfiles, <a href="https://github.com/pterodactyl/yolks">pterodactyl/yolks</a> 195★. None in speech',
     'yolk.com taken (1995). yolk.app taken (DNSimple, no site). getyolk.app taken. yolkapp.com taken (2026-03). hiyolk.com registered 2026-10-26 (yours?). useyolk.app: no DNS, possibly free',
     'USPTO <a href="https://tsdr.uspto.gov/#caseNumber=90128781&caseType=SERIAL_NO&searchType=statusSearch">YOLK. 90128781</a> cl. 9/42 (via <a href="https://markinton.com/trademark/yolk-90128781">aggregator</a>, unverified), <a href="https://trademarks.justia.com/978/15/yolk-97815521.html">YOLK LABS</a> cl. 42, <a href="https://www.g2.com/sellers/yolkai">YolkAI</a> consulting',
     "ok", "Crowded but OK. No voice/notes Mac app. Check TSDR status of 90128781"),
    ("Sunny", "egg",
     "No exact MAS app",
     '<a href="https://github.com/yhuse/SunnyUI">SunnyUI</a> 2.6k★, <a href="https://github.com/sunnypilot/sunnypilot">sunnypilot</a> 2.2k★',
     ".app parked for sale; .com taken (1998)",
     '<a href="https://sunn-ai-five.vercel.app">SunnAI</a> (Mac speech-to-text), "Sunnyy" Mac voice assistant (waitlist), NewDays "Sunny" AI voice companion',
     "bad", "Conflict. Two near-identical Mac voice products"),
    ("Avo", "avocado",
     "No MAS app",
     '<a href="https://github.com/mmcloughlin/avo">mmcloughlin/avo</a> 3k★, <a href="https://github.com/avo-hq/avo">avo-hq/avo</a> 1.8k★',
     '<a href="https://www.avo.app">avo.app</a> is a live funded data company; .com taken (CSC)',
     'Avo (data governance), <a href="https://www.elion.health/vendors/avomd">AvoMD</a> AI clinical scribe/notes',
     "bad", "Conflict. Established software brand + AI-notes scribe"),
    ("Guac", "avocado",
     '<a href="https://apps.apple.com/mx/app/guac-inventory-ordering/id6453681945">Guac – Inventory ordering</a> (iOS); <a href="https://appshunter.io/ios/app/guac-diet-pet-and-food-scanner/id6782239000">Guac: Diet Pet</a> (avocado mascot!)',
     '<a href="https://github.com/guacsec/guac">guacsec/guac</a> 1.5k★ (OpenSSF), Apache Guacamole',
     ".app parked (Afternic); .com = YC AI startup",
     '<a href="https://guac.com">Guac</a> (YC, AI grocery forecasting)',
     "ok", "Crowded but OK. No voice clash; noisy SEO; avocado-mascot app exists"),
    ("Peachy", "peach",
     '<a href="https://apps.apple.com/us/app/id1390423469">Peachy AI photo editor</a>, <a href="https://apps.apple.com/app/id6756173572">Peachy Timer</a> (Mac menu-bar pomodoro), <a href="https://apps.apple.com/us/app/peachy/id6450934747">Peachy.</a>',
     '<a href="https://github.com/itsmeichigo/peachy">itsmeichigo/peachy</a> (Mac menu-bar kaomoji), small others',
     ".app parked (Afternic); .com taken (1997)",
     "Peachy Technologies (PeachyTalks), Peachy Day. Nothing in voice",
     "ok", "Crowded but OK. Several Mac menu-bar 'Peachy' apps, none dictation"),
    ("Momo", "peach",
     "No dictation app",
     '<a href="https://github.com/momozi1996/momo-code">momo-code</a> 1.1k★ AI agent, <a href="https://github.com/shiguredo/momo">shiguredo/momo</a> 879★',
     ".app parked; .com = car parts brand",
     '<a href="https://bizhub.vietnamnews.vn/momo-remains-most-popular-e-wallet-in-viet-nam-post352821.html">MoMo</a> (Vietnam e-wallet, going "AI assistant"), momo.ai scheduling',
     "bad", "Conflict-ish. Big brands own it; unwinnable SEO"),
    ("Mikan", "tangerine",
     '<a href="https://apps.apple.com/us/app/-/id6455634416">Mikan Voice Chat</a> (iPhone AI voice chat), <a href="https://mwm.ai/apps/mikan/920856839">mikan</a> JP vocab app',
     '<a href="https://github.com/iota9star/mikan_flutter">mikan_flutter</a> 1.4k★, <a href="https://github.com/uchan-nos/mikanos">MikanOS</a> 761★. Nothing in speech',
     ".app taken (likely for sale, unverified); .com = mikan vocab app",
     "mikan Co. English-learning app (~10M downloads, JP)",
     "ok", "Crowded but OK. Big JP edu brand; voice-chat iPhone app is adjacent"),
    ("Clementine", "tangerine",
     "No MAS app found",
     '<a href="https://github.com/clementine-player/Clementine">Clementine music player</a> 4.3k★',
     ".app taken; .com taken (1999)",
     '<a href="https://techcrunch.com/2026/09/09/instacart-launches-an-ai-grocery-shopping-assistant-called-clementine">Instacart "Clementine"</a> AI assistant (Sep 2026)',
     "ok", "Crowded but OK. Long name; Instacart AI is a recent, loud use"),
    ("Mochi", "blob",
     '<a href="https://apps.apple.com/us/app/-/id1507775056">Mochi – Flashcards and notes</a> (Mac notes app w/ AI)',
     '<a href="https://github.com/MochiDiffusion/MochiDiffusion">MochiDiffusion</a> 8k★ Mac AI app, <a href="https://github.com/genmoai/mochi">genmoai/mochi</a> 3.8k★',
     "mochi.app live (AI cooking); .com taken (1996)",
     '<a href="https://mochi.cards/">mochi.cards</a> notes app',
     "bad", "Conflict. Established Mac notes app + Mac AI apps"),
    ("Hum", "blob",
     '<a href="https://apps.apple.com/us/app/hum/id796154884">Hum</a> (Mac songwriting/voice memo app)',
     'Swamped by "humanizer" repos',
     ".app + .com corporate (CSC)",
     '<a href="https://hum.bluehive.com/download">BlueHive HUM</a> Mac calls/meetings app; Humla meeting recorder',
     "bad", "Conflict. Same-name Mac voice-recording app + Mac meetings app"),
    ("Pip", "blob",
     'No exact MAS app; <a href="https://www.stork.ai/en/pip">Pip</a> Mac voice AI assistant (2026); <a href="https://alternativeto.net/software/pipit/about">Pipit</a> local Mac dictation',
     "pypa/pip owns the term",
     ".app live (AI coach); .com taken (1996)",
     "Python pip, Pip AI coach, Pip voice assistant, Pipit",
     "bad", "Conflict. Python pip + two Mac voice products"),
]

R2_SHOW = {"Yolk", "Mikan", "Clementine"}  # extended below

# ---- round 2 names (2026-11-04)
NAMES += [
    ("Zesty", "lemon-v4",
     'No voice/dictation/notes app named Zesty (web search). Big one: DoorDash\'s <a href="https://apps.apple.com/us/app/-/id6743326355">Zesty – Local Food Discovery</a> (iOS AI restaurant app, <a href="https://techcrunch.com/2025/12/16/doordash-rolls-out-zesty-an-ai-social-app-for-discovering-new-restaurants">launched Dec 2025</a>). Also <a href="https://apps.apple.com/app/id6739545596">Zesty – Photo Calories</a>, <a href="https://apps.apple.com/cn/app/id1440056601">ZestyClip</a> (Mac clipboard). "Zesty Dictation": nothing found',
     '<a href="https://github.com/stpnwf/ZestyTheme">ZestyTheme</a> 527★ (Jellyfin), <a href="https://github.com/zesty-io">zesty-io</a> org (CMS). "zesty voice/dictation": only a tiny empty repo',
     'zesty.com = DoorDash Zesty (MarkMonitor, 1996). zesty.app for sale (Dan.com). getzesty.app taken (live "Zesty" JS app). usezesty.app, tryzesty.app, heyzesty.app, zestyapp.app: no DNS (possibly free). zesty.so = ADHD med tracker',
     'DoorDash Zesty (AI, consumer, owns .com); Zesty.io CMS; <a href="https://wellfound.com/company/zesty-ai/people">ZestyAI</a> (insurance AI); Zesty catering (<a href="https://squareup.com/us/en/press/square-acquires-zesty-to-expand-caviar-s-corporate-catering-business">bought by Square 2018</a>, now Caviar). USPTO not checked; DoorDash likely holds/filed ZESTY for apps (unverified)',
     "ok", "Crowded but usable. No voice/notes/Mac-AI clash; DoorDash's AI app is the big shadow"),
    ("Pucker", "lemon-v4",
     'Nothing (closest "Puckerz!" game)',
     "Tiny repos only",
     '.com 1998. <a href="https://pucker.app">pucker.app</a> live (creator monetisation)',
     "DeKuyper Pucker schnapps (unverified)",
     "bad", "Avoid. Live .app + kiss/sour-face connotation"),
    ("Lemmy", "lemon-v4",
     "No exact app; many Lemmy (fediverse) clients",
     '<a href="https://github.com/LemmyNet/lemmy">LemmyNet/lemmy</a> 14.6k★ fediverse, <a href="https://github.com/badlogic/lemmy">badlogic/lemmy</a> 1.6k★ LLM agent tool',
     ".com 2004. lemmy.app: no DNS (possibly free)",
     "Lemmy fediverse platform; Lemmy Kilmister",
     "bad", "Avoid. Fediverse owns the term + an AI tool"),
    ("Tangy", "tangerine",
     'No exact app. <a href="https://apps.apple.com/us/app/-/id6744395998">Tangy Chef</a> (food), <a href="https://apps.apple.com/app/id1582115614">Tangy Pandies</a> stickers',
     "Nothing relevant",
     ".com 2000. tangy.app for sale (Afternic). gettangy.app: no DNS (possibly free)",
     "Nothing in software; Tang drink (Kraft) nearby",
     "ok", "OK. No software clash; buy .app or use gettangy.app"),
    ("Tangie", "tangerine",
     "None found", "Nothing (Tangier noise)",
     '.com 2000. <a href="https://tangie.app">tangie.app</a> live (meal prep)',
     "Well-known cannabis strain",
     "bad", "Avoid. Live .app + cannabis association"),
    ("Clem", "tangerine",
     'No exact app. <a href="https://apps.apple.com/uz/app/cleft-notes/id6479458038">Cleft Notes</a> (AI voice notes, sound-alike)',
     '<a href="https://github.com/clementine-player/Clementine">Clementine player</a> 4.3k★',
     ".com 1995. clem.app parked",
     "Clem Delangue (Hugging Face CEO) is the AI-world association",
     "ok", "Crowded but OK. Hugging Face CEO association"),
    ("Satsu", "tangerine",
     "None found (near: Aisatsu)",
     "Only weak 'satsuma' matches (≤45★)",
     '.com 2001. <a href="https://satsu.app">satsu.app</a> live (small bitcoin-alert app). getsatsu.app: no DNS (possibly free)',
     "Nothing major",
     "ok", "OK. Clearest tangerine name; small live .app"),
    ("Mandy", "tangerine",
     '<a href="https://apps.apple.com/app/id6747137269">The Mandy Network</a> (Backstage jobs)',
     "Nothing relevant",
     ".com = Mandy.com (Backstage). .app registered",
     "Mandy.com / Backstage LLC",
     "bad", "Avoid. Established brand owns it"),
]
R2_SHOW |= {"Zesty", "Pucker", "Lemmy", "Tangy", "Tangie", "Clem", "Satsu", "Mandy"}

NAMES += [
    ("Cado", "avocado",
     '<a href="https://apps.apple.com/ca/app/cado/id6446417058">Cado</a> (store/reservation ops, runs on Mac), <a href="https://apps.apple.com/de/app/isi-cado/id1491490340">isi:Cado</a> vouchers. No voice apps',
     '<a href="https://github.com/cado-nfs/cado-nfs">cado-nfs</a> 68★, <a href="https://github.com/rd235/cado">rd235/cado</a> 46★. No speech',
     ".com 1997. cado.app registered (Namecheap). getcado.app: no DNS (possibly free)",
     '<a href="https://cadosecurity.com/news-and-events/darktrace-announces-proposed-acquisition-of-cado-security">Cado Security</a> (Darktrace) markets "Cado AI Investigator"',
     "ok", "Crowded but OK. Security-AI overlap, not voice"),
    ("Avie", "avocado",
     '<a href="https://apps.apple.com/app/id1661614734">Avie: AI Chatbot Companion</a> (iOS). No Mac/voice app',
     "Nothing notable",
     ".com 1997. avie.app registered (Cloudflare, broken site). getavie.app: no DNS (possibly free)",
     '<a href="https://www.capterra.com/software/1107060/Avie">Avie</a> AI receptionist for clinics; Avie Records (unverified)',
     "ok", "Crowded but OK. Small AI-assistant overlap"),
    ("Hass", "avocado",
     '<a href="https://apps.apple.com/mx/app/hassapp/id1543748657">HassApp</a> (avocado harvesting)',
     'Home Assistant owns "hass" (<a href="https://github.com/home-assistant/home-assistant.io">home-assistant.io</a> 10k★ + many hass-* repos)',
     ".com 1996. hass.app registered",
     "Hass avocado brand, Home Assistant",
     "bad", "Avoid. Home Assistant owns the term in tech"),
    ("Pitpat", "avocado",
     '<a href="https://apps.apple.com/ky/app/pitpat/id1054695579">PitPat</a> (UK dog tracker, active)',
     "Only PitPat treadmill integrations",
     '.com = <a href="https://www.pitpat.com/app/">PitPat</a> (live). pitpat.app parked. trypitpat.app: no DNS',
     "PitPat Ltd (pets), PitPat walking pads",
     "ok", "Crowded but OK. Consumer brand owns .com; not software"),
    ("Ripe", "avocado",
     '<a href="https://apps.apple.com/app/ripe-app/id1608587712">Ripe App</a> (cooking), ripeness checkers. No voice',
     'Swamped by <a href="https://github.com/RIPE-NCC/whois">RIPE NCC</a>, <a href="https://github.com/mortbopet/Ripes">Ripes</a> 3.4k★',
     '.com 1995. <a href="https://www.godaddy.com/forsale/ripe.app">ripe.app for sale</a>. getripe.app taken',
     "RIPE NCC, Ripe (VC-backed B2B sales AI)",
     "ok", "Crowded but OK (borderline). Unsearchable"),
    ("Zest", "lemon-v4",
     'Many: <a href="https://apps.apple.com/app/id1542670628">Zest</a>, <a href="https://apps.apple.com/ee/app/zest-habit/id6478664385">Zest Habit</a>, <a href="https://apps.apple.com/ca/app/zest-client/id6447696283">ZEST Client</a> (Mac)',
     '<a href="https://github.com/darkmoonight/Zest">darkmoonight/Zest</a> 488★ tasks, JQF+Zest 746★',
     ".com live. zest.app registered. getzest.app taken",
     '<a href="https://fortune.com/2024/12/13/exclusive-zest-ai-snags-200-million-growth-investment-from-insight-partners">Zest AI</a> (fintech, $200M raise)',
     "bad", "Avoid. Very crowded; 'Zest AI' is established"),
    ("Lemi", "lemon-v4",
     '<a href="https://apps.apple.com/ly/app/lemi-app/id1616674381">Lemi App</a> (small-business tool, iPad/Mac), <a href="https://apps.apple.com/us/app/id6758993240">Lemi live</a> (social). No voice',
     'Nothing notable (<a href="https://github.com/UnicomAI/LeMiCa">LeMiCa</a> 123★ research)',
     ".com 1997. lemi.app parked at Afternic (likely for sale). getlemi.app: no DNS (possibly free)",
     '<a href="https://www.startuphub.ai/startups/lemni">Lemni</a> (voice-AI agents) is a near spelling',
     "ok", "OK. Least crowded; .app maybe buyable"),
]
R2_SHOW |= {"Cado", "Avie", "Hass", "Pitpat", "Ripe", "Zest", "Lemi"}

RECOMMENDATION = """
<p><strong>Round 5 (lemon v4):</strong> v2's vertical body is kept exactly. Only the two tips changed, from pointed to soft, rounded, slightly bulbous bumps, with the stem and leaf on the top bump. At 18 to 22 px the glyph still reads as a lemon, not a tangerine or an Apple logo. (v3, the plump one, misread the request and was dropped.)</p>
<p><strong>Round 3 (lemon + Zesty):</strong> the stem, leaf and nubs make the lemon glyph read as a lemon, and the upright attached stem, legs and face keep it away from the Apple logo. <strong>Zesty</strong> is usable for a free, open-source app you give to friends: no voice, notes or Mac AI app uses it. But DoorDash owns zesty.com and ships an AI app called Zesty, and ZestyAI and Zesty.io are funded companies. Expect noisy search, and check TSDR before any public launch. Domain: usezesty.app or tryzesty.app (no DNS). <strong>Zesty vs Zest:</strong> Zesty avoids the direct "Zest AI" (fintech) collision, so it's better than Zest. It still has its own AI-brand crowd (DoorDash Zesty, ZestyAI). The verdict moves from "avoid" (Zest) to "crowded but usable" (Zesty).</p>
<p><strong>Round 2 recommendation (unchanged):</strong></p>
<p><strong>Among the round-2 three, I recommend the avocado, with the app/character named Cado (Avie is the alternative).</strong> You make the final pick. Yolk stays the baseline.</p>
<ul>
<li><strong>Animatable:</strong> the round pit is a built-in voice element. It swells and gets a level ring while listening, so the mic level drives one part, like the yolk does for the egg. The rotund belly also suits a squash-and-stretch hop on "done".</li>
<li><strong>Small sizes:</strong> its glyph (an outline pear with a solid round pit) is the most legible of the three at 18 to 22 px. It also can't be mistaken for an apple or for a system icon.</li>
<li><strong>Distinctive:</strong> no competitor ships a mascot. Avocado characters are common in stickers and food apps, so the name has to carry the distinction.</li>
<li><strong>Name:</strong> Cado has no voice, notes or AI Mac app, though Cado Security does market a "Cado AI Investigator". getcado.app showed no DNS. Avie overlaps a little with small AI-assistant products, and getavie.app also showed no DNS.</li>
</ul>
<p><strong>Lemon (Lemi)</strong> is the close second. It has the cleanest name of the round: lemi.app is parked and probably for sale, and getlemi.app showed no DNS. Its pointed-oval outline is distinctive at 18 px. The cost is that it's a wide shape, so the face is smaller. <strong>Tangerine (Tangy or Satsu)</strong> is third. The new glyph (twin leaves, legs, knocked-out face) fixes the Apple-logo problem, but a round fruit is still the most generic silhouette. Both names are OK: gettangy.app and getsatsu.app showed no DNS.</p>
<p><strong>vs Yolk:</strong> Yolk is still the strongest single name in the voice category, and the egg is still the most unique silhouette. If you'd rather have the avocado character, Cado or Avie is about as clean as Yolk. Neither is a blocker.</p>
<p><strong>Avoid:</strong> Hass, Zest, Pucker, Lemmy, Tangie and Mandy, plus round 1's Sunny, Avo, Momo, Mochi, Hum and Pip.</p>
"""


def inline(svg, prefix, glyph=False):
    svg = re.sub(r'<title>.*?</title>', "", svg)
    svg = re.sub(r'id="([^"]+)"', lambda m: f'id="{prefix}-{m.group(1)}" data-part="{m.group(1)}"', svg)
    svg = re.sub(r'url\(#([^)]+)\)', lambda m: f'url(#{prefix}-{m.group(1)})', svg)
    svg = re.sub(r'(<svg[^>]*?) width="\d+" height="\d+"', r"\1", svg, count=1)  # root size only
    if glyph:  # recolour silhouette (not the mask) to currentColor
        head, sep, tail = svg.partition("</defs>")
        if not sep:
            head, tail = "", svg
        tail = tail.replace('"#000"', '"currentColor"')
        svg = head + sep + tail
    return svg.replace("<svg ", '<svg aria-hidden="true" ', 1).strip()


def read(key, pose):
    return (HERE / f"{key}-{pose}.svg").read_text()


COMPARE = {"lemon-v4": ["lemon-v1", "lemon-v2"], "avocado": ["avocado-v1"], "tangerine": ["tangerine-v1"]}


def overview():
    cols = ""
    for k in OVERVIEW:
        c = CHARS[k]
        g = read(k, "menubar")

        def mb(theme, k=k, g=g):
            gl = "".join(f'<span class="mini s{z} glyph">{inline(g, f"{k}-ov{z}{theme}", True)}</span>' for z in (22, 18))
            col = f'<span class="mini s22">{inline(read(k, "idle"), f"{k}-ovc22{theme}")}</span>'
            return f'<div class="menubar mb-{theme}">{gl}{col}</div>'
        base = {"egg": " (baseline)", "lemon-v4": " v4 (new)", "lemon-v2": " v2 (round 3)", "lemon-v1": " v1 (round 2)"}.get(k, "")
        cols += (f'<div class="ov"><h3>{escape(c["species"].split(" (")[0])}{base}</h3>'
                 f'<div class="ovpair"><div class="pose light">{inline(read(k, "idle"), f"{k}-ov-l")}</div>'
                 f'<div class="pose dark">{inline(read(k, "listening"), f"{k}-ov-d")}</div></div>'
                 f'{mb("light")}{mb("dark")}</div>')
    return (f'<section class="panel" id="overview"><h2>Side by side</h2><p class="note">Idle on light, listening on dark, then the template glyph at 22 and 18 px and the colour idle at 22 px, '
            f'in light and dark menu bars.</p><div class="ovgrid">{cols}</div></section>')


def archive():
    cells = "".join(f'<figure><div class="pose">{inline(read(k, "idle"), f"{k}-ar")}</div><figcaption>{escape(CHARS[k]["species"].split(" (")[0])}: {escape(BLURB[k][1])}</figcaption></figure>' for k in ARCHIVE)
    return f'<details class="panel"><summary><h2 style="display:inline">Dropped (round 1 + lemon v3)</h2></summary><div class="row light" style="grid-template-columns:repeat(2,1fr)">{cells}</div></details>'


def candidate(key):
    c = CHARS[key]
    names = [n for n in NAMES if n[1] == key]
    chips = " ".join(f'<span class="chip {n[6]}">{escape(n[0])}</span>' for n in names)
    poses_light = "".join(f'<figure><div class="pose">{inline(read(key, p), f"{key}-{p}-l")}</div><figcaption>{p}</figcaption></figure>' for p in POSES)
    poses_dark = "".join(f'<figure><div class="pose">{inline(read(key, p), f"{key}-{p}-d")}</div><figcaption>{p}</figcaption></figure>' for p in POSES)
    tiny = "".join(f'<span class="mini s22" title="{p} 22px">{inline(read(key, p), f"{key}-{p}-m22")}</span>' for p in POSES)
    tiny18 = "".join(f'<span class="mini s18" title="{p} 18px">{inline(read(key, p), f"{key}-{p}-m18")}</span>' for p in POSES)
    g = read(key, "menubar")
    old = COMPARE.get(key, [])

    def lab(o):
        return o.split("-")[-1]

    def glyphs(k, theme):
        gg = read(k, "menubar")
        return (f'<span class="mini s22 glyph">{inline(gg, f"{k}-g22{theme}", True)}</span>'
                f'<span class="mini s18 glyph">{inline(gg, f"{k}-g18{theme}", True)}</span>')

    def bar(theme):
        oldg = "".join(f'<span class="tag">{lab(o)}</span>{glyphs(o, theme + o)}' for o in old) + ('<span class="tag">new</span>' if old else "")
        return (f'<div class="menubar {theme}"><span class="clock">Tue 4 Nov</span>{oldg}'
                f'{glyphs(key, theme)}'
                f'<span class="sep"></span>{tiny}{tiny18 if len(old) < 2 else ""}</div>')

    v1 = ""
    for o in old:
        if (HERE / f"{o}-idle.svg").exists():
            v1 += (f'<h3>Old: {lab(o)}</h3><div class="row light old">'
                   + "".join(f'<figure><div class="pose">{inline(read(o, p), f"{o}-{p}-l")}</div><figcaption>{lab(o)} {p}</figcaption></figure>' for p in POSES)
                   + "</div>")
    if v1:
        v1 += "<h3>New</h3>"

    swatches = "".join(f'<span class="sw" style="background:{col}"></span>' for col in c["colors"])
    what, note = BLURB[key]
    return f"""
<section class="cand" id="{key}">
  <header><h2>{escape(c['species'])}</h2><div class="chips">{chips}</div><div class="swatches">{swatches}</div></header>
  <p class="what">{escape(what)}</p><p class="note">{escape(note)}</p>
  {v1}<div class="row light">{poses_light}</div>
  <div class="row dark">{poses_dark}</div>
  <div class="bars"><div><h3>Menu bar, light</h3>{bar('mb-light')}</div><div><h3>Menu bar, dark</h3>{bar('mb-dark')}</div></div>
  <p class="files">Files: {", ".join(f"<code>{key}-{p}.svg</code>" for p in POSES + ["menubar"])}</p>
</section>"""


def table(names):
    rows = "".join(
        f'<tr><th scope="row">{escape(n)}</th><td>{escape(CHARS[k]["species"].split(" (")[0])}</td><td>{mas}</td><td>{gh}</td><td>{dom}</td><td>{tm}</td>'
        f'<td><span class="chip {cls}">{"OK" if cls == "ok" else "Avoid"}</span> {escape(v)}</td></tr>'
        for n, k, mas, gh, dom, tm, cls, v in names)
    return f"""<div class="tablewrap"><table><thead><tr><th>Name</th><th>Character</th><th>Mac App Store</th><th>GitHub</th>
<th>Domains (.com / .app)</th><th>Trademarks / products</th><th>Verdict</th></tr></thead><tbody>{rows}</tbody></table></div>"""


CSS = """
:root{--bg:#fbf6ef;--card:#fffdf9;--ink:#3b2a22;--muted:#7a6a60;--line:#eadfd3;--ok:#2f8f5b;--okbg:#e2f4e9;--bad:#b4442f;--badbg:#fbe5df;--link:#b05a1e}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#1d1916;--card:#26211d;--ink:#f3e9df;--muted:#b3a497;--line:#3a322c;--okbg:#1f3a2b;--ok:#7fd3a2;--badbg:#45231c;--bad:#ff9b85;--link:#ffb27a}}
:root[data-theme="dark"]{--bg:#1d1916;--card:#26211d;--ink:#f3e9df;--muted:#b3a497;--line:#3a322c;--okbg:#1f3a2b;--ok:#7fd3a2;--badbg:#45231c;--bad:#ff9b85;--link:#ffb27a}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 ui-rounded,"SF Pro Rounded",-apple-system,system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:34px;margin:0 0 4px;letter-spacing:-.01em}h2{font-size:20px;margin:0}h3{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 6px}
a{color:var(--link)}
.lede{color:var(--muted);max-width:70ch}
nav{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0 28px}nav a{padding:4px 12px;border:1px solid var(--line);border-radius:99px;text-decoration:none;background:var(--card)}
.cand,.panel{background:var(--card);border:1px solid var(--line);border-radius:20px;padding:20px;margin:0 0 24px}
.cand header{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.chips{display:flex;gap:6px;flex-wrap:wrap}.chip{font-size:12px;font-weight:600;padding:2px 9px;border-radius:99px}
.chip.ok{background:var(--okbg);color:var(--ok)}.chip.bad{background:var(--badbg);color:var(--bad)}
.swatches{margin-left:auto;display:flex;gap:4px}.sw{width:16px;height:16px;border-radius:50%;border:1px solid rgba(0,0,0,.15)}
.what{margin:10px 0 2px}.note{margin:0 0 14px;color:var(--muted)}
.row{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;border-radius:14px;padding:12px;margin-bottom:8px}
.row.light{background:#f6efe6}.row.dark{background:#211d1b}
.row.dark figcaption{color:#b9aca1}
figure{margin:0;text-align:center}figcaption{font-size:12px;color:#7a6a60;text-transform:uppercase;letter-spacing:.06em}
.ovgrid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}.ov h3{margin-bottom:6px}
.ovpair{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:6px}.ovpair .pose{border-radius:12px;padding:6px}
.pose.light{background:#f6efe6}.pose.dark{background:#211d1b}.ov .menubar{margin-top:6px;gap:12px}
.ovpair svg{width:100%;height:auto}
.tag{font-size:10px;text-transform:uppercase;letter-spacing:.06em;opacity:.6}
.row.old{opacity:.85}
summary{cursor:pointer}
@media (max-width:900px){.ovgrid{grid-template-columns:repeat(2,1fr)}}
.pose svg{width:120px;height:120px;max-width:100%;display:block;margin:0 auto}
.bars{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:12px;margin-top:6px}.bars>div{min-width:0}
.menubar{display:flex;align-items:center;gap:10px;height:30px;padding:0 12px;border-radius:8px;flex-wrap:nowrap;overflow:hidden}
.mb-light{background:rgba(246,246,246,.95);color:#000;box-shadow:inset 0 -1px 0 rgba(0,0,0,.08)}
.mb-dark{background:#2b2b2e;color:#fff}
.clock{font:13px -apple-system,system-ui;opacity:.85;order:9;margin-left:auto;white-space:nowrap}
.sep{width:1px;height:16px;background:currentColor;opacity:.25}
.mini{display:inline-flex}.mini svg{display:block}.s22 svg{width:22px;height:22px}.s18 svg{width:18px;height:18px}
.files{font-size:12px;color:var(--muted);margin:10px 0 0}code{font-size:12px}
.tablewrap{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13px;min-width:900px}
th,td{border-top:1px solid var(--line);padding:8px;text-align:left;vertical-align:top}thead th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
tbody th{font-size:15px}
.legend{font-size:13px;color:var(--muted)}
@media (max-width:720px){.row{grid-template-columns:repeat(2,1fr)}.bars{grid-template-columns:1fr}.swatches{margin-left:0}}
/* rig demo: every pose shares named parts, so one stylesheet animates all candidates */
@media (prefers-reduced-motion:no-preference){
 .row [data-part=pulse] circle{transform-box:fill-box;transform-origin:center;animation:ring 1.4s ease-out infinite}
 .row [data-part=pulse] .ring2{animation-delay:.35s}
 .row [data-part=dots] circle{animation:blink 1.2s infinite}
 .row [data-part=dots] .dot2{animation-delay:.2s}.row [data-part=dots] .dot3{animation-delay:.4s}
 .row [data-part=sparkles] path{transform-box:fill-box;transform-origin:center;animation:twinkle 1.6s ease-in-out infinite}
 .row [data-part=sparkles] path:nth-child(2){animation-delay:.5s}.row [data-part=sparkles] path:nth-child(3){animation-delay:.9s}
 .row [data-part=sweat]{animation:drip 2s ease-in infinite}
 .row [data-part=eyes]{transform-box:fill-box;transform-origin:center;animation:blinkeye 4s infinite}
}
@keyframes ring{0%{transform:scale(.85);opacity:.7}100%{transform:scale(1.08);opacity:0}}
@keyframes blink{0%,100%{opacity:.25}50%{opacity:1}}
@keyframes twinkle{0%,100%{transform:scale(.6) rotate(0)}50%{transform:scale(1.1) rotate(20deg)}}
@keyframes drip{0%,60%{transform:translateY(0);opacity:1}100%{transform:translateY(6px);opacity:0}}
@keyframes blinkeye{0%,94%,100%{transform:scaleY(1)}97%{transform:scaleY(.1)}}
"""


def main():
    nav = "".join(f'<a href="#{k}">{escape(CHARS[k]["species"].split(" (")[0])}</a>' for k in ORDER)
    r2 = sorted((n for n in NAMES if n[0] in R2_SHOW), key=lambda n: (ORDER.index(n[1]), n[6] != "ok"))
    r1 = [n for n in NAMES if n[0] not in R2_SHOW]
    html = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mascot Exploration</title><style>{CSS}</style></head><body><main>
<h1>Mascot + name exploration <small style="font-size:16px;color:var(--muted)">round 5</small></h1>
<p class="lede">Issue #16, round 5. Lemon v4 ("Zesty") comes first, right next to v2: same body, with only the ends changed to rounded bumps. Then come v1, the avocado and the egg (Yolk, the baseline). The plump v3 is under "dropped". The avocado and tangerine are from round 2. Every character uses one shared rig: <code>pulse › legs › body › face(cheeks, eyes, brows, mouth) › hands › fx</code>. Each has four states: idle, listening (recording), thinking (transcribing) and done (pasted), shown at 120 px on light and dark. Menu bars show the monochrome template glyph at 22 and 18 px, then the colour poses at 22 and 18 px. These are concept sketches, not final art.</p>
<nav><a href="#overview">Side by side</a>{nav}<a href="#names">Names</a><a href="#rec">Recommendation</a></nav>
<section class="panel" id="rec"><h2>Recommendation</h2>{RECOMMENDATION}</section>
{overview()}
{''.join(candidate(k) for k in ORDER)}
<section class="panel" id="names"><h2>Name collision check</h2>
<p class="legend">Checked 2026-11-04 with web search, <code>gh search repos</code>, whois/DNS (.app checked through DNS NS records), and trademark aggregators. App Store results come from web search, not a native MAS query. Trademarks weren't checked directly on USPTO, so treat them as unverified.</p>
{table(r2)}
<details><summary>Round 1 names (Sunny, Avo, Guac, Peachy, Momo, Mochi, Hum, Pip)</summary>{table(r1)}</details></section>
{archive()}
</main></body></html>
"""
    (HERE / "index.html").write_text(html)
    print("wrote index.html", len(html) // 1024, "KB")


if __name__ == "__main__":
    main()
