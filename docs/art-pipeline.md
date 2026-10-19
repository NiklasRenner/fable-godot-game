# Art pipeline

Almost everything is a **Meshy model**: the player's body and its armour skins, the camp NPCs
(the same body in outfit skins), the creatures (boar, wolf, the Mossback trolls and Gorrak), the
weapons and pauldrons, the world (terrain textures, grass and flower sprites, trees, rocks and
camp props) and the ability icons. Each is generated once, imported with `tools/import_meshy.py`
(plain Python, numpy, PIL; scipy for `regions`), and recorded in `meshy/hero.json`,
`meshy/world.json` or `meshy/creatures.json` (task ids, sources, the exact import command).

Sources stay in `meshy/`: Godot ignores the folder (`meshy/.gdignore`) and git keeps only its
`*.json` records; the game only loads `assets/`.

## The body

1. **Concept image.** Run Meshy text-to-image (nano-banana-2) on the base body: A-pose, plain
   underwear, no hair on the face, Classic proportions. Ask for a few and pick one by eye.
   Going through an image is what makes the 3D follow the design and come out in a clean pose.
2. **Image to 3D.** Use smart topology (meshy-t2.5), about 3000 triangles, `a-pose`. Text-to-3D
   with smart topology ignores `pose_mode`; an A-pose image rigs fine.
3. **Rig** at 1.8 m. **Animate** with preset ids for idle, run-in-place, attack, cast, sit and
   jump (`meshy/hero.json` lists them).
4. **Fetch.** `assets.meshy.ai` can't be reached from the agent sandboxes. The Meshy MCP's
   `meshy_download_model` with `save_to` writes a model or image straight onto the dev machine;
   for links only (animation results) run `tools/preview/fetch.tscn` with `fetch.request`
   (pairs of lines: URL, destination).
5. **Import:**
   ```
   python tools/import_meshy.py model   meshy/base_a_anim.glb assets/hero.glb
   python tools/import_meshy.py regions assets/hero.glb      assets/hero_regions.png
   ```
   `model` renames the clips to the ones the game plays, drops Meshy's helper node, shrinks and
   brightens the texture (Meshy bakes dark; Classic is bright and flat) and adds the fist blend
   shapes. It also prints the `fist` entry to paste into `GameData.MODELS`.
6. **Check** with `tools/preview/model_preview.tscn`, which renders every clip in the engine as
   a contact sheet. `preview.request` takes: line 1 the model key (`hero@res://x.glb` renders
   another file with the hero's profile, e.g. candidate clips), line 2 the output, line 3
   optionally `<clip|*> <frames> [side]` (`side`: every frame from the side, for leans and
   strides). Then take an in-game look with `screenshot.request` (see the README).
7. **Extra clips** (`tools/build_extra_clips.py`, run once): later library picks animated on the
   same rig (one animate call takes up to 10 action ids, 3 credits each, into
   `meshy/anim2/*_cand.glb`), pose-edited with `import_meshy.py tweak` and copied into the model
   with `clips`. `tweak` makes an edited copy of a clip: `amp` scales the motion around its
   average pose (a harder-driving run, livelier breathing), `rot` adds a fixed bone rotation
   (bones' own axes; on Meshy rigs x bends arms, spine and knees forward and z swings sideways),
   `blend` moves bones part of the way to another clip (a crouch's legs with an idle's arms).
   `wave` adds a slow looping sine sway (breathing, weight shift, a look around), so a library idle
   that holds still doesn't freeze. Re-running prunes the replaced clips' data, so the models
   don't grow.
   Clips the game looks for beyond the basic ones: `idle_calm` (NPCs at rest; the restless
   `idle` plays now and then) and `combat_idle` (standing still while in combat; monsters while
   they have a target). Missing ones fall back to `idle`.
8. **Profile** in `GameData.MODELS`:
   - `yaw`: Meshy models face +Z; this turns them to Godot's -Z.
   - `run_speed`
   - `jump_clip`: the jump preset includes its own crouch and landing, so only this in-air
     segment plays, stretched over the airtime.
   - `fist`, `skins`, `shoulders`

## Armour: skins on one body texture (the Classic way)

- A **skin** is a Meshy retexture of the rigged body with `enable_original_uv`. The vertex order
  and UVs stay identical, so its texture is a drop-in replacement for the body's. Prompt it as
  the outfit: tunic, trousers, boots.
  ```
  python tools/import_meshy.py skin meshy/armor_chain.glb assets/hero_skin_chain.png --brighten 1.35
  ```
  An item names it with `"skin": "chain"`. The game copies only that item's slot regions from the
  skin over the base texture (`Outfit.dress`); composites are cached per gear combination.
- **Regions** (`hero_regions.png`, red channel = index: 0 head, 1 chest, 2 legs, 3 feet, 4 hands)
  are cut with straight planes anchored to the joints: collar (above the Head joint), waist
  (midway Hips to spine), boot tops (just below the knees), wrists (square to the forearm). Each
  texel is classed by its own bind-pose position. Gutters take the nearest island's region, so
  filtering never bleeds the wrong skin across a seam. All skins of a body share the map, so
  design skins whose belt and boot tops sit near those cuts.
- **Bare skin in a skin**: a retexture paints its own flesh where the outfit leaves the body
  bare (a robe's neckline, toes in sandals), and that flesh never matches the base body. Run
  `fleshmask` once on every new skin: it finds skin-coloured texels (an HSV band) and writes them
  as transparent, so `Outfit.dress` lets the base body show through there.
  ```
  python tools/import_meshy.py fleshmask assets/hero_skin_cloth.png assets/hero_regions.png
  ```
  If it eats into a leather or tan fabric, the band is in `flesh_amount()`.
- **Rigid pieces** (weapons, shoulders) are separate Meshy models:
  ```
  python tools/import_meshy.py rigid meshy/longsword.glb assets/weapon_longsword.glb --kind weapon
  python tools/import_meshy.py rigid meshy/pauldron.glb  assets/shoulder_pauldron.glb --kind shoulder --size 0.3
  ```
  - **Weapon convention:** grip at the origin, blade along -Z, edges ±Y.
  - **Hafted weapons** (axes, clubs, staves, wands) have no guard to find the grip by: pass
    `--grip <fraction>` (how far up the haft from the butt the hand goes, e.g. 0.12 for a club,
    0.4 for a staff). The head is taken to be the wider end.
  - **Every rigid import is made matte** (no metalness, roughness 1 for props, 0.85 for weapons):
    Meshy's default ~0.55 roughness reads as shiny plastic in the sun. `matte <glb> [roughness]`
    re-mattes an existing asset (`model` does it for characters too).
  - **Props lose their base cap** (`nobase`, run by `rigid --kind prop`): Meshy materials are
    double-sided, so a model's underside shows from above and z-fights with the ground it stands
    on (the tent floor flickered); a flat floor such as a groundsheet is lifted 3 cm instead.
    Grass and flowers also skip the ground under props (`Scenery._under_prop`).
  - **Shoulders:** upright, centred at the origin, authored for the +X side; the game mirrors
    the left one.

- **NPCs** wear one skin whole (`GameData.NPCS[*].outfit`: skin, weapon, shoulders, or `armor`:
  a whole modelled set), through the same `Outfit.dress` as players, so every NPC outfit is also
  an item skin waiting to be used: leather, cloth, marshal, provisioner, prospector
  (`meshy/creatures.json`).

## Armour: modelled pieces

The Classic way: helm, pauldrons, gauntlets and boots are 3D pieces; a set's chest and legs are
a skin (above). Pieces only ever meet the body, so sets mix piece by piece. Each piece is its own
Meshy model (a model of the hero wearing the whole set can't be cut into pieces: image-to-3d fuses
helm, neck guard and breastplate into one sheet). A new set, `<set>`, files in `meshy/armor/`:

1. **Base layer** `base_<x>.png`: image-to-image (nano-banana-2, aspect 3:4) with `meshy/base_a.png`
   as the person ("keep his exact face, hair, body, pose, framing") and the design in words or as a
   second reference: the set's chest and leg armour only, bare head, hands and feet, and nothing the
   boots cover (no knee or shin plates; leggings go on to the ankle, or legs without boots are
   shorts). A few candidates; pick one.
2. **Concept** `concept_<x>.png`: the base layer with the helm, pauldrons, gauntlets and boots
   added. Adding only covers, so nothing else drifts (an edit that removes a helm invents a face).
3. **Piece images** `pieces/<set>_<kind>.png`, from the concept: "product shot of ONLY the closed
   great helm from this armour set, alone, nothing else ..."; exactly one of each, shown once: a
   helm, a LEFT pauldron (from the outside, upright), a RIGHT gauntlet (open, fingers straight, from
   the back of the hand), a RIGHT boot.
4. **Piece models** `pieces/<set>_<kind>.glb`: image-to-3d, meshy-t2.5 smart topology, 1500-2000
   triangles. Look at each from all sides: one image leaves the back to guess (a closed helm can
   come out open at the cheeks, a gauntlet with an invented palm). Then a multi-view image of that
   piece (image-to-image with `generate_multi_view`, saying what the hidden sides are) and
   `meshy_multi_image_to_3d`, remeshed to 2000 triangles.
5. **Fit model** `<set>_rig.glb`: image-to-3d of the concept (smart topology, 8000 triangles,
   a-pose), rigged at 1.83 m. Only says where each piece sits and how big it is.
6. **Skin** `pieces/<set>_skin.glb`: Meshy retexture of the hero model (`hero_model_task` in
   `armor.json`, original UVs) with the BASE LAYER as the style image. What it paints as skin
   shows the hero's own body. (Styled on the full concept, it paints bits of the pieces onto the
   body, half a pauldron, bracer bands, that the slot regions then cut off.)
7. **Import**, one command:

       python tools/import_armor.py <set> --helm meshy/armor/pieces/<set>_helm.glb \
           --shoulder .. --glove .. --boot .. --fit meshy/armor/<set>_rig.glb \
           --skin meshy/armor/pieces/<set>_skin.glb --match meshy/armor/concept_<x>.png

   writes `assets/armor_<set>.glb`, `assets/armor_<set>_cover.png` and `assets/hero_skin_<set>.png`.
   Each piece is fitted onto its slot of the fit model (every 90-degree turn tried, then turn,
   size and offset; a pauldron stays upright as in its image), then gloves and boots are snugged
   onto the hero's own hand and lower leg, pauldrons rested on the shoulder, and pauldron, glove
   and boot mirrored. `--match` gives every piece the concept's steel tone; `--match-mid yes` also
   its overall darkness (for a set that is one metal all over, black_k; not one whose concept is
   mostly mail or cloth). The cover map says which body texels each worn piece hides (`Outfit`
   cuts them out, alpha scissor, per piece and its own set, so mixed sets work): a helm only what
   sticks out through it, gauntlets the whole hand, boots the leg that can't be seen inside them.
   The boots carry the skin too, so a look into a boot top finds armour, not a gap.
8. **Items**: helm, shoulder, hand and feet items `"mesh": "<set>"` (boots also `"skin": "<set>"`);
   chest and leg items `"skin": "<set>"`; an NPC outfit's `"armor": "<set>"` wears all of it.
9. **Check** with the model previewer, line 4 `armor <set> [weapon] [-slot] [slot=set]`, line 5
   `<camera height> <view size>` for a close-up. `THORNHILL_ARMOR_TINT=1` colours each piece,
   `THORNHILL_ARMOR_BODY_ONLY=1` shows only the body (what the pieces hide).

`meshy/armor/armor.json` records every task and the import command of each set. About 125 credits a
set (base layer and concept 6 each, piece images 4 x 6, piece models 4 x 15, fit model 20, skin
10), more when a piece needs a multi-view redo (36).

## Creatures

- **Humanoid monsters** (trolls, Gorrak) go through the body recipe: concept, image-to-3d, Meshy
  rig and animate (idle, a walk, an attack), then `import_meshy.py model`. Their profile in
  `GameData.MODELS` gives `run_speed` (the ground speed the walk clip matches at 1x, before the
  monster's scale) and the `fist` grip for an armed one (`MONSTERS.*.weapon`). Mitten and claw
  hands have no separate fingers, so the importer writes the grip frame only, no fist shape.
- **Quadrupeds** (boar, wolf): Meshy's auto-rig is humanoid only, so
  `import_meshy.py quadruped <src> <dst> --size <length m>` rigs a static model itself. It finds
  the four legs (the separate columns under the belly), weights body, head, tail and two-bone legs,
  and writes idle, a diagonal trot and a lunge attack procedurally.
- **Voices** are synthesised per monster kind in `tools/build_audio.py` (`assets/audio/<kind>.ogg`).

## Holding a weapon

Meshy's rig has no finger bones. The importer bends each finger onto an arc around a
handle-sized axis and stores the result as blend shapes `fist_R` / `fist_L`. An equipped weapon
closes the hand, and its grip sits on the fist's frame, written in bind-pose mesh space
(`MODELS.hero.fist`):

- blade out of the thumb side
- edge towards the knuckles

The game maps that frame through the hand's rest × bind transform, the same transform the
skinning applies to the hand's vertices.

## The world

- **Terrain**: four tiling painted layers (grass, dry grass, dirt road, rock) in
  `assets/terrain/`, blended by `terrain.gdshader`. `Terrain` bakes each vertex's weights into
  its colour from height, slope and road distance, so the layout code never touches art. The
  layers sample world space (rock triplanar), a slow noise breaks up the repeat, and borders follow
  the textures' light and dark so they look painted. The cave mesh uses the same material in cave
  mode (`cave.tres`), reading its baked grass/rock paint. Generate a layer as "seamless tileable
  ... viewed straight from above, flat lighting"; such images still don't tile, so
  `import_meshy.py texture` trims any frame and blends the edges with a half-shifted copy.
  Compare candidate sets in-game: the screenshot hook and the same framing for each.
- **Ground clutter**: grass tufts and flowers are cut-out sprites (text-to-image with
  `remove_background`, `import_meshy.py sprite` trims the painted soil) on two crossed quads,
  thousands per MultiMesh (`Scenery._build_scatter`). `assets/fx/clutter.gdshader` sways the
  tips, lights both faces like the ground (back faces would get a flipped normal and go black)
  and dissolves them with distance.
- **Props**: concept image per prop (shown as one sheet to pick from) → image-to-3d with smart
  topology at a few hundred to ~2000 triangles → `import_meshy.py rigid --kind prop --size <m>`
  (stands on the origin, scaled to its height, or `--along x` to its length; matte). The size
  and command for each are in `meshy/world.json`.
- **Fire**: `assets/fx/flame.gdshader` on three crossed quads (`Flame.make`), additive and
  noise-torn; the campfire and every torch use it, with soft billboard embers and smoke
  (`Flame.puff_material`).
- **Spell and combat effects** (`Vfx`, built from `FxKit`): each effect is a few layers, a
  bright core (glints, glows), a body that tears apart as it fades, motion (ribbon trails, swing
  arcs, expanding rings and walls) and the aftermath (scorch / frost decals, embers, smoke), plus
  a light flash and, for big hits, a small camera shake (`camera_rig.shake`).
  - **Textured, eroding particles** (`fx_add` / `fx_mix`, `fx_particle.gdshaderinc`): each
    particle shows a greyscale shape from `assets/fx/tex/` and the colour ramp's alpha is spent as
    *erosion* (thin parts vanish first) rather than a flat fade. Dense parts burn brighter, thin
    edges darken. The fire, smoke and wisp shapes and the slash streak are **painted** (Meshy
    text-to-image, greyscale on black: `meshy/fx/*_src.png`, cut into atlas cells by
    `tools/build_fx_textures.py`); noise, glint, spark, swirl, shards and the trail streak are
    procedural (same script). Fire is alpha-blended, not additive: additive fire stacks to white.
  - **Ribbons** (`fx_ribbon.gdshader`): `FxTrail` follows a node and draws its recent path
    (rebuilt in `frame_pre_draw` so it doesn't lag a fast bolt); rings, walls and the level-up
    helix are meshes from `FxKit` aged by `progress`.
  - **Decals** only touch meshes on `FxKit.GROUND_LAYER` (terrain and cave), so units never wear
    them; a decal's glow texture is premultiplied, because emission ignores the albedo's alpha.
  - Additive shaders need `fog_disabled`: fog is added to every pixel of the quad and shows the
    quad's square.
  - **Test bench:** `tools/preview/fx_preview.tscn` plays effects on a caster and a target dummy and
    saves frames (`fx_preview.request`: `<png> <effect> <seconds> [orbit distance height]`); or in
    the game, `goto boar 12 fx fireball wait 0.3` in the screenshot hook.
  Health bars over heads are one quad each (`plate.gdshader`: frame, fill, gloss and the damage
  chunk that drains after it).
- **Set dressing** is a scene: `scenes/map/thornhill.tscn` (camp, palisade, graveyard, the sites,
  the forest, NPC spots, level pads), built from the prop scenes in `scenes/props/` (model +
  collider + `MapProp`, which keeps them on the ground). Edit it in the Godot editor (README,
  "Editing the map"). Only the grass, flowers and pebbles stay procedural (`Scenery`). A new prop:
  copy a `scenes/props/*.tscn`, point it at the new `.glb` and size its collider. Light props
  (torches, lanterns, the cook pot) carry an `OmniLight3D` (`light_specular` 0.3, so wet-looking
  highlights don't creep back) and a `Flame` node (`torch_flame.gd`: `size` for an open flame,
  `glow` for a halo behind glass).
- **Mood**: warm sun, a pale hazy horizon and a little distance fog (`scenes/world.tscn`) do as
  much for the Classic look as the textures.
- **Forest layout** (baked into the map scene once; edit it there): pines on high hills, along the map edge and in the
  wolves' wood north of camp; the open middle is broadleaf, the two oaks in loose clumps.

## The UI

- **Ability icons**: text-to-image per ability ("square icon, painted, dark frame"), then
  `import_meshy.py icon <src> assets/ui/icons/<ability>.png --box x0,y0,x1,y1` crops the painted
  tile inside its frame to 128 px (the game draws its own slot). Boxes in `meshy/creatures.json`.
- **Frames, buttons, slots, bars and parchment** are drawn in code (`UITheme`): small 9-slice
  images built at startup, so the look is diffable and needs no art files. Headers and names use
  an OS serif (`UITheme.serif`: Palatino, Book Antiqua or Georgia on Windows).

## Godot gotchas

- A new `class_name` script is only known to other scripts once the editor has scanned it
  (`.godot/global_script_class_cache.cfg`). Launch the editor after adding one, or every script
  that names it fails to parse ("Could not resolve class").

- Godot only re-imports a changed `.glb` when the editor scans; launch the editor after replacing
  one.
- Keep textures embedded (`project.godot` `[importer_defaults]`:
  `gltf/embedded_image_handling=3`). Godot's default extracts the texture on the first import and
  keeps applying that stale file to every re-import, which made a new model look "distorted". An
  old `.glb.import` made before the default was set still says `=1`: fix it or delete it.
- The auto-rigged skeleton is in centimetres under a 0.01 node scale. Do attachment maths in
  model space (`Outfit._attach` converts into the bone's space).
- Leaf bones (hands) have arbitrary axes. Don't orient anything by them; use rest × bind as
  above.
- `CharacterBody3D` capsules: put the capsule's bottom exactly at the model's soles, or the feet
  sink.
