# Mascot + name exploration (#16), round 5

Visual page: [index.html](index.html). It's self-contained. Round 2 covers the avocado (rounder), the tangerine (new menu-bar glyph) and the lemon (new), with the egg/Yolk kept as the baseline. The page shows all four side by side, the old and new avocado together, and menu bars in light and dark at 22 and 18 px.

These are concept sketches, not final art. The user makes the final pick.

## Round 5: lemon v4, rounded tips (current)

- **Lemon v4** (`lemon-v4-*.svg`). It's v2's vertical body exactly. The only change is the two ends: the pointy tips are now soft, rounded, slightly bulbous bumps. The stem and leaf sit on the top bump. It has all 4 poses and a menu-bar glyph.
- **Glyph** (`lemon-v4-menubar.svg`). It's v2's tall oval with a rounded bump at each end, plus the stem, one leaf, legs and a knocked-out face. At 22/18 px on light and dark bars it still reads as a lemon. It isn't the tangerine: it's taller than wide, has bumps at both ends, a single leaf, and is yellow. It isn't the Apple logo: no bite, an attached stem, legs and a face.
- **index.html** shows v4 first, with v2 right next to it so the only visible difference is the ends, then v1, the avocado and the egg.
- **v3 (round 4, plump) misread the request.** Its files were renamed from `lemon-*` to `lemon-v3-*` and it moved to the collapsed "Dropped" section. The plain `lemon-*` files no longer exist; versions are now v1 to v4.

## Round 4: plump "Zesty" lemon (v3, dropped)

- **Lemon v3** (now `lemon-v3-*.svg`, dropped). Plump and almost round, only about 1.1:1 taller than wide. Both ends are fully rounded, with a tiny soft nub under the stem and a tiny one at the bottom. One stem and one leaf on top. The user's stock-image reference was used for overall shape only: no gloves, sneakers, rubber-hose limbs or running pose. It keeps our flat style, face, cheeks, little hands and legs, and the 4 poses.
- **Old versions kept:** round 3 is now `lemon-v2-*` and round 2 stays `lemon-v1-*`. index.html shows v3 first, then v2 and v1, then the avocado and the egg.
- **Glyph** (`lemon-menubar.svg`), checked at 22/18 px on light and dark bars. It reads as a lemon, not the tangerine, because:
  - it's slightly taller than wide, where the tangerine glyph is squat (wider than tall);
  - it has tiny nubs at both ends, where the tangerine has none;
  - it has a single side leaf on an upright stem, where the tangerine has twin symmetric leaves;
  - in colour it's yellow, not orange.
- It isn't the Apple logo: no bite, an attached upright stem, legs, and a face.

## Round 3: vertical lemon + "Zesty"

- **Lemon v2** (now `lemon-v2-*.svg`). It's vertical (taller than wide) with soft rounded ends, a gentle nub at the bottom, and one stem and one leaf on top. The face, cheeks, hands, legs and all 4 poses are kept. The round 2 lemon is now `lemon-v1-*.svg`.
- **Glyph** (`lemon-menubar.svg`). It's a tall oval with an upright stem and a leaf, a bottom nub, legs, and a knocked-out face. Rendered at 22/18 px on light and dark bars, it reads as a lemon. The stem and leaf separate it from an egg or plain oval. The attached stem, the legs and the face (with no bite) separate it from the Apple logo.
- **index.html** now features lemon v2 first, next to lemon v1, the avocado and the egg.

### "Zesty" collision check (2026-11-04)

| Check | Finding |
|---|---|
| Mac App Store | No voice, dictation, notes or AI Mac app named Zesty. The biggest same-name app is DoorDash's [Zesty – Local Food Discovery](https://apps.apple.com/us/app/-/id6743326355), an iOS AI restaurant app ([launched Dec 2025](https://techcrunch.com/2025/12/16/doordash-rolls-out-zesty-an-ai-social-app-for-discovering-new-restaurants)). Others: [Zesty – Photo Calories](https://apps.apple.com/app/id6739545596) and [ZestyClip](https://apps.apple.com/cn/app/id1440056601) (a Mac clipboard app). No "Zesty Dictation" found. |
| GitHub | [ZestyTheme](https://github.com/stpnwf/ZestyTheme) 527★ (Jellyfin) and the [zesty-io](https://github.com/zesty-io) org (CMS). For voice/dictation, only a tiny empty repo. |
| Domains | zesty.com belongs to DoorDash Zesty (MarkMonitor, reg. 1996). zesty.app is for sale on Dan.com. getzesty.app is taken (a live "Zesty" JS app). zesty.so is an ADHD medication tracker. **usezesty.app, tryzesty.app, heyzesty.app and zestyapp.app have no DNS, so they're possibly free.** |
| Brands / trademarks | DoorDash Zesty (consumer AI). Zesty.io (CMS). [ZestyAI](https://wellfound.com/company/zesty-ai/people) (insurance AI). Zesty catering ([bought by Square in 2018](https://squareup.com/us/en/press/square-acquires-zesty-to-expand-caviar-s-corporate-catering-business), now Caviar). USPTO wasn't checked; DoorDash probably holds or has filed ZESTY for apps (unverified). |

**Verdict: crowded but usable** for a free, MIT app handed to friends. Nothing in voice, notes or Mac AI uses the name. The big shadow is DoorDash's AI app, which owns zesty.com. Expect noisy search, and check TSDR before any public launch. **Zesty vs Zest:** Zesty avoids the direct "Zest AI" (fintech, $200M) collision, so it moves from "avoid" (Zest) to "crowded but usable" (Zesty). Suggested domain: usezesty.app or tryzesty.app.

## Round 2 changes

- **Avocado v2** (`avocado-*.svg`). The bottom is now a full round belly. The pit is bigger and rounder, with an inner shade and a highlight. The pit is the **voice element**: when listening it grows and gets a level ring (`#pit-level`) that can pulse with mic level. The glyph is rounder too. v1 is kept as `avocado-v1-*.svg` for comparison.
- **Lemon** (`lemon-*.svg`, new). An oval with pointed tips, plus a leaf and peel dots. The glyph is the pointed-tip oval with legs and a knocked-out face, which can't be read as a circle or an apple at 18 px.
- **Tangerine** (`tangerine-*.svg`, formerly `orange-*`). Twin symmetric leaves replace the single tilted leaf in both the art and the glyph. The glyph is also squat, has little legs and a bigger knocked-out face, so it no longer reads as the Apple logo. The old glyph is kept as `tangerine-v1-menubar.svg`.
- Peach and blob were dropped. Their files remain, and they're shown under "Round 1, dropped" in index.html.

## Rig (shared by all candidates)

The named groups are: `#pulse` › `#legs` › `#body` › `#face` (`#cheeks`, `#eyes` [`#eye-l`/`#eye-r`], `#brows`, `#mouth`) › `#hands` (`#hand-l`/`#hand-r`) › `#fx` (`#sweat`, `#dots`, `#sparkles`).

| Pose | Meaning | Face | Hands | FX |
|---|---|---|---|---|
| idle | resting | dot eyes, small smile | down | none |
| listening | recording | big sparkly eyes, open "o" mouth | both up | pulse rings (avocado: the pit also swells and gets a level ring) |
| thinking | transcribing | eyes up-right, brows, squiggle mouth | hand on chin | sweat drop, 3 dots |
| done | pasted | wink, open grin | thumbs up | sparkles, little kick |

Each `*-menubar.svg` is a 22×22 macOS template glyph: pure black on transparent, with the face knocked out by a mask.

Sources: `build.py` generates the SVGs and `build_html.py` generates index.html. To regenerate, run `python3 plans/mascot/build.py && python3 plans/mascot/build_html.py`.

## Name collision check (2026-11-04)

Method: web search for the Mac App Store, `gh search repos`, whois for .com, and DNS NS records for .app (no NS means the domain is possibly unregistered; that's not confirmed with a registrar). Trademarks come from web search only, so they're unverified. **Every base .com is registered.** The full table with links is in index.html.

| Name | Char | Verdict | Key collisions / domain |
|---|---|---|---|
| **Cado** | avocado | OK (crowded) | Mac app "Cado" (store ops). Cado Security (Darktrace) markets a "Cado AI Investigator". No voice apps. getcado.app has no DNS. |
| **Avie** | avocado | OK (crowded) | Avie AI chatbot (iOS) and Avie AI receptionist. getavie.app has no DNS. |
| Pitpat | avocado | OK (crowded) | PitPat dog tracker owns the .com. |
| Ripe | avocado | OK (borderline) | Can't search past RIPE NCC. ripe.app is for sale. |
| Hass | avocado | Avoid | Home Assistant owns "hass" in tech. |
| **Lemi** | lemon | OK, cleanest | Small Lemi business app on MAS. Lemni is a voice-AI startup with a near spelling. lemi.app is parked at Afternic. getlemi.app has no DNS. |
| **Zesty** | lemon | OK (crowded) | See round 3 above. DoorDash's Zesty AI app owns zesty.com. No voice apps. usezesty.app has no DNS. |
| Zest | lemon | Avoid | Zest AI (fintech, $200M raise) and many apps named Zest. |
| Pucker | lemon | Avoid | pucker.app is live. Schnapps brand. |
| Lemmy | lemon | Avoid | Lemmy is a fediverse platform (14.6k★), and badlogic/lemmy is an LLM tool. |
| **Tangy** | tangerine | OK | Nothing in software (Tang the drink is close). tangy.app is for sale. gettangy.app has no DNS. |
| **Satsu** | tangerine | OK | satsu.app is a small live bitcoin-alert app. getsatsu.app has no DNS. |
| Clem | tangerine | OK (crowded) | Strongly associated with the Hugging Face CEO. clem.app is parked. |
| Mikan / Clementine | tangerine | OK (crowded) | Round 1 results: a big JP edu brand and Instacart's AI assistant, respectively. |
| Tangie | tangerine | Avoid | tangie.app is live. Cannabis strain. |
| Mandy | tangerine | Avoid | Mandy.com is owned by Backstage. |
| Yolk (baseline) | egg | OK (crowded) | No voice, notes or AI Mac app. yolk.com and yolk.app are taken. USPTO 90128781 (class 9/42) is unverified. useyolk.app has no DNS. |

Round 1 also rejected Sunny, Avo, Momo, Mochi, Hum and Pip. Guac and Peachy were crowded but OK.

## Recommendation

**Among the round 2 candidates, the avocado is my pick, named Cado (Avie is the alternative).**

- **Animation:** the round pit doubles as the voice and level element.
- **Small sizes:** the outline pear with a solid pit is the most legible glyph at 18 to 22 px, and nothing about it looks like Apple.
- **Name:** the closest overlap is security AI, not voice.

**Lemon / Lemi** is a close second: it has the cleanest name and a distinctive outline, but it's wide, so the face is smaller. **Tangerine / Tangy** comes third: the glyph is fixed, but it's still the most generic shape.

Compared with the Yolk baseline: Yolk is still the strongest name in the voice category, and the egg is the most unique silhouette. Cado or Avie is about as clean as Yolk, so neither choice is blocked by its name.

## Unresolved questions

- Pick: lemon v4 / Zesty, avocado (Cado/Avie), tangerine (Tangy/Satsu), or stay with Yolk?
- Zesty: OK with DoorDash owning zesty.com? Domain: usezesty.app or tryzesty.app?
- Should the app name match the character name?
- Domain: try buying the base .app, or use a get-prefixed one (get<name>.app)?
- Run a TSDR check on the chosen name now?
