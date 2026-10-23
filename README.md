# olib_sample

Runnable examples for [olib](https://github.com/ctzcs/olib): the Foster port (`olib:foster`)
and the extension layer (`olib:kit/*`).

## Requirements

- Odin nightly
- olib checked out next to this project as `olib` (`run.bat` uses `-collection:olib=..\olib`)
- SDL3 runtime available from the Odin distribution

## Run an example

Model materials: `run.bat material3d` shows two independent instances of the Shader Lab
body + outline effect. Space toggles the outline; R reloads the left model's material JSON.
See [Shader Lab → model material workflow](src/material3d/README.md) for exporting parameters,
loading textures and rebuilding release shaders without depending on the editor.

From this directory: `run.bat [sample] [args...]` (extra args are passed to the program).

Foster basics:

```bat
run.bat
run.bat feature
run.bat batcher
run.bat spatial
run.bat calc
run.bat backend
run.bat app_composition
```

The default `basic` example keeps its update/render loop running until the
window is closed.

`app_composition` keeps game state in a heap-allocated `World` (separate from `App`),
attaches it with `foster.AppSetUserData`, reads it back in callbacks with
`foster.AppGetUserDataAs(app, World)`, runs 60 frames and exits.

kit/gizmo:

```bat
run.bat gizmo2d
run.bat gizmo2d shot
run.bat gizmo2d shot scaled
run.bat gizmo2d shot narrow vulkan
```

`gizmo2d` shows three independent Camera2D viewports for translation, rotation and local scaling.
Drag the center square to move freely or scale uniformly. Arrow keys pan the cameras,
Q/E rotate, Z/X zoom, R resets all objects in one undoable edit. Ctrl+Z/Y undo/redo;
Escape cancels an active operation, otherwise exits. It uses a system font on Windows/macOS/Linux.
`shot` exercises real pointer input, checks resulting transforms, resizes the window and saves
native-resolution captures to `build/gizmo2d-<width>x<height>.png`.
The App owns a session in `src/gizmo2d/editor`, with one document and transaction shared by the three viewports.
Each gesture creates one history entry; focus loss, camera/viewport changes and Escape restore its starting values.
Capture remains with the originating tool until release. Reset and undo/redo use the same document update path.
The fixed objects cannot be added, removed or reordered. This is an in-memory example: it offers no file save/load,
play simulation or release-game entry, and closing the window discards its contents.
See [editor guidelines](../olib/prompts/editor-guidelines.md) for the shared project integration contract.
`odin test src/gizmo2d -collection:olib=../olib -vet` verifies transactions, atomic rejection, capture and release-frame updates;
these tests are also discovered by olib's `tools/check`.

Mesh inspection (core/meshutil + kit/gizmo wireframe):

```bat
run.bat meshview
run.bat meshview path\to\model.dasset
run.bat meshview shot
```

`meshview` draws a model with `gizmo.wireframe_draw` on top and shows `meshutil.stats`:
triangles, used vertices vs. unique positions, and seam (blue), border/hole (orange) and
non-manifold (red) edge counts. Without an argument it shows a built-in bumpy UV sphere with a
deliberate hole. S / Right simplifies one more level (half the triangles each time, from the original
mesh, stopping at 5% error); A / Left goes back. W toggles the wireframe, M the model, X shows hidden
edges at full strength. All primitives of a `.dasset` are merged; skinned models show their bind pose.
`shot` saves `library/screenshots/meshview.png` and `meshview-simplified.png` (level 3) and exits.
The surface shader is `src/meshview/shaders/MeshView.oshader`; after editing it run
`odin run ../olib/tools/shaders -- -dir:src/meshview/shaders`.

kit/ui:

```bat
run.bat ui_motion
run.bat ui_motion shot
run.bat ui_motion shot scaled narrow
```

`ui_motion` is a drag-and-drop card study inspired by the requested Shogun Showdown feel,
with original procedural icons. Drag cards from the wooden tray into the three action slots:
the card follows the pointer 1:1, tilts with its horizontal velocity, lifts with a shadow, and the
slot under it lights up. Hovering over the tray opens a gap at the insertion point and the neighbours
slide apart; dropping there reorders the hand (also works for cards coming back from a slot).
Dropping on an occupied slot swaps cards; dropping elsewhere flies the card
home on a critically damped spring and lands with a squash. Clicking (or Tab + Enter) toggles a card
between hand and the first empty slot; Esc cancels a drag. GO plays the queue in slot order, and the
GATE card opens a modal entrance/exit afterwards. Drag/drop rules and spring physics live in
`src/ui_motion/cards.odin`; tweened poses live in `src/ui_motion/motion.odin`.
The sample uses `UnlockedStep` so VSync paces frames — Foster's default fixed 60 Hz step sleeps
between updates and stutters on high-refresh displays.
`shot`/`smoke` drags, clicks, swaps, executes the queue, closes the modal, resizes to 960×800 and saves seven
native-resolution PNGs under `build/ui-motion-*.png`. `scaled narrow` starts at 760×760
with 125% UI scale; cards shrink to fit and fonts and icons render directly at the final output resolution.
The UI font atlas includes all Chinese labels. No game assets are copied.

```bat
run.bat game_ui
run.bat ui_gallery
run.bat book_ui
```

- `game_ui`: ruins scene with HUD, skill cooldowns, grid inventory and pause menu.
  Args: `hud` / `modal` / `scaled` / `scroll` switch the initial state, `font <atlas-prefix>` loads an offline MSDF PNG/JSON pair,
  `cli` opens the stdin debug console (`help`, `quit`).
- `ui_gallery`: settings page, scrolling inventory and modal confirm; the basic widget acceptance page.
  Args: `modal` / `scaled` / `scroll` / `msdf` / `narrow`, `font <atlas-prefix>`.
  All text uses offline MSDF; `msdf` opens a dedicated Latin/Chinese glyph comparison at 14/18/36/72px.
- Add `shot` to `game_ui` or `ui_gallery` to render a frame, write a PNG to this directory and exit
  (used for screenshot regression of `kit/ui`, see olib `kit/ui/README.md`).

Book page mesh + interactive page UI:

```bat
run.bat book_ui
run.bat book_ui shot
run.bat book_ui shot turn
run.bat book_ui shot turn late
run.bat book_ui shot turn back
run.bat book_ui shot rotated
run.bat book_ui shot underside
run.bat book_ui test
```

- `book_ui`: a six-page field grimoire with a curved, double-sided turning leaf,
  leather binding and paper stacks. Spell buttons, bookmarks, inventory actions,
  audio toggle/slider and a quest button are live `kit/ui` widgets on the paper.
- Click **Previous / Next** or press **Left / Right** to turn one leaf. **Space** or
  **Pause / Resume** pauses the animation; the bottom slider controls turn duration.
  **Tab / Shift+Tab / Enter** navigates the last clicked page; **Escape** exits.
- **Right-drag** rotates the whole book freely. **Shift + right-drag** rolls it
  around the screen axis. **Middle-drag** moves it across the view, and **wheel**
  moves it nearer/farther in 3D. **R** or **Reset view** restores the initial pose.
  Left-click remains reserved for page UI. Rotation uses normalized quaternions
  and can continue through 360 degrees while a leaf is turning or paused.
- Page contents are composed into offscreen targets, then mapped onto a subdivided
  3D sheet rendered with a perspective camera and a color/depth target. The leather
  cover and paper blocks are solid meshes. GPU depth testing handles occlusion;
  the paper shader selects the front/back page with perspective-correct UVs.
  Mouse rays are transformed into book space and hit the nearest surface to recover
  Clay UI coordinates. Covers block clicks from behind. Page input locks during
  a turn or book drag and resumes afterward. Widget state persists.
- `shot` captures a settled spread; `turn` freezes a forward turn, `late` shows its
  reverse face, `back` starts at spread two and turns backward. `scaled` uses a larger
  window; `rotated` starts with a rotated/moved pose, `underside` shows the back cover.
  `font <path.ttf>` overrides the default Windows font. Screenshots are saved as
  `book_ui*.png` in this directory.
- `test` runs perspective ray/UV round trips and deterministic pointer interactions
  after rotating, rolling, moving and changing book depth. It checks both turn
  directions, cover occlusion, input isolation and persistence. Run `test scaled`
  and `test rotated` to verify another viewport and a different starting pose.
- The 3D shader supports Vulkan and D3D12. Precompiled shaders are included;
  normal builds need no shader compiler. After editing `src/book_ui/shaders/Book.hlsl`, run
  `odin run ../olib/tools/shaders -- -dir:src/book_ui/shaders` (needs SDL_shadercross on PATH).

In Zed, use **task: spawn** and select **Book UI: Run** from `.zed/tasks.json`.

kit/rendering/3d reference renderer:

```bat
run.bat forward3d
run.bat forward3d shot
```

- `forward3d`: a Standard PBR forward renderer (directional, point and spot lights,
  sorted alpha blending, debug grid) built on the mechanism-only `kit/rendering/3d`
  (mesh upload, generic render queue, shader bytecode selection, std140 packing,
  Render3D debug lines). Lighting, materials and shaders live in this sample, not in olib:
  copy `src/forward3d` into a game and change them to fit its look.
- `shot` renders a fixed-time frame, writes `forward3d.png` to this directory and exits.
  Set `SDL_GPU_DRIVER=vulkan` or `SDL_GPU_DRIVER=direct3d12` to pick the backend.
- Shaders are precompiled to SPIR-V/DXIL/MSL. After editing `src/forward3d/shaders/*.hlsl`, run
  `odin run ../olib/tools/shaders -- -dir:src/forward3d/shaders` (needs SDL_shadercross on PATH).
- `forward3d_test.odin` checks the cbuffer layouts against the shader and the mesh winding;
  olib's `odin run tools/check` runs it.

```bat
run.bat stylized3d
run.bat stylized3d shot
```

- `stylized3d`: a Celeste64-style frame on Render3D — per-view `View.globals` (sun, fog, billboard
  camera axes), a `ZTest Greater` silhouette for the hero behind a wall, and ambient-occlusion / depth-edge post effects
  that sample the scene depth attachment through `material_set_texture`. See
  [src/stylized3d/README.md](src/stylized3d/README.md).
- `shot` writes the final composite to `library/screenshots/stylized3d.png`; `shot flat` disables the edge pass.
  Ambient occlusion is enabled by default; press O to toggle it or use `shot noao` for a comparison capture.
- Move with WASD / arrows, hold Shift to run, Space to jump. Right-drag orbits the follow camera;
  wheel zooms, R resets, P pauses, E toggles edges. Collision supports walls, steps and platform landings.
  `shot follow` captures the playable view; `smoke` exercises movement, jumping, camera orbit and resizing.
- The meadow uses six resident GPU instance batches for grass, flowers, trees and props, with warm dirt paths,
  faceted crowns and a filtered sun shadow map (L toggles shadows). Occasional travelling gusts bend vegetation
  in the vertex shader; color and shadow passes share the deformation. `shot follow calm` / `shot follow gust`
  produce fixed-time wind comparisons without re-uploading static instances.
- A rippling pond beside the path reflects trees, props, the player and coins through a mirrored camera,
  reusing those instance buffers. `shot water` captures the pond; add `noreflection` for a comparison.

## Hot reload: the smallest example

```bat
run.bat hotreload
```

`hotreload` is the minimal wiring: a persistent window (`main.odin`, about 90 lines including window boilerplate) and a game DLL
(`game/game.odin`, about 70 lines) that moves a square with a trail using WASD/arrows. While it runs, change `SPEED`,
`SIZE` or `COLOR` in `game/game.odin` and save: the next build replaces the game and the square keeps
its position and trail. A failed build keeps the previous version and prints the compiler output; fix and save to recover.
See [the walkthrough](src/hotreload/README.md). For a real project start from `tools/new-game`.

## Shader Lab: live 2D / 3D shader development

```bat
run.bat shader_lab
run.bat shader_lab vulkan
run.bat shader_lab d3d12
run.bat shader_lab smoke vulkan
run.bat shader_lab smoke d3d12 scaled
run.bat shader_lab shot narrow
run.bat shader_lab features d3d12
run.bat shader_lab multipass d3d12
run.bat shader_lab hierarchy d3d12
run.bat shader_lab targets d3d12
run.bat shader_lab colors d3d12
```

Requires `odin` and `shadercross` on PATH. Edit and save `.oshader` files under
`src/shader_lab/shaders/`. Each file contains Properties, defaults, passes and HLSL;
shared functions can still live in HLSLI includes. There is no separate Odin parameter package.
Candidate layouts and programs are applied together after compilation and GPU validation.
Each Pass keeps its own parameter values. See [syntax and publishing](../olib/kit/rendering/shader/lang/README.md).
Zed / ZedG highlighting is available through [the local extension](../olib/tools/zed-shader/README.md).

The reusable tool lives in `olib:kit/tools/shader_lab`; this sample keeps only application
startup wiring (Dear ImGui, a dock layout, native dialogs and drops) and project assets. The tool
draws its control and preview windows into the host's ImGui frame through
`init / update / draw / cancel / dispose`; the host owns the ImGui context, font and input.
The whole frame is drawn to an offscreen target first, so screenshots include the UI.
See [embedding and ownership](../olib/kit/tools/shader_lab/README.md). Optional screenshot and
fault-injection helpers live in `tools/shader_lab_checks`, outside the runtime tool package.

Sliders, vector controls, color swatches and texture selection are generated from the fields.
The dark ImGui style, Noto Sans CJK font (GB2312 subset, glyphs rasterized on demand) and icons
come from olib's ImGui backend; labels outside that subset produce a diagnostic.
Texture controls show the currently bound image as an aspect-preserving thumbnail; click the
card to browse native files, choose from the texture directory, or clear back to the checker.
Drop an image onto the card to bind it; changed image files reload automatically and failures
retain the previous image. Properties of type `2D` store image paths. Native dialog/drop wiring
is in `shared/shader_lab_files`; the reusable tool only exchanges file requests and paths.
Click a color swatch (such as Tint) to open the palette (SV square, hue and opacity bars, presets).
Colors preview immediately; Apply keeps the color, while Cancel, Escape or focus loss restores it.
Existing values survive field reordering by stable ID; new fields use defaults.
Add images to `src/shader_lab/shaders/textures/` to select them in the texture control.
Changing slider values or textures needs no shader compilation. Save/Load stores parameter
snapshots for the selected shader group, including relative image paths. The tool writes the
preset JSON for you. Reset all restores Properties defaults; R restores one field. These snapshots
do not edit Properties defaults or host material documents; document undo/redo belongs to the host.
Dock, resize or undock the Shader Lab and preview windows freely; Pass targets follow the preview
area's pixel size. Hosts can supply `Preview_Hooks` to record their own sprites or models for material shaders.

Select the 2D or 3D workspace, then **二维拖尾** or **三维拖尾** for a multi-pass example: scene rendering,
half-resolution horizontal/vertical blur, then previous-frame feedback. The declarations live
in `src/shader_lab/shaders/Trail2D.oshader` and `Trail3D.oshader`.
Click a Pass to edit its parameters; use the preview toolbar to choose final or intermediate output.
Each `.oshader` file is one Shader; Input and Value refer to stable field IDs.
Pause freezes feedback; Step advances once; Reset history clears it. Only the selected Shader owns
RenderTextures; switching releases them and recreates them on return, resetting feedback history.
Floating-point targets and MSAA are supported; the UI stays outside
the pass chain. See the [Pass syntax](../olib/kit/rendering/shader/lang/README.md#pass-与目标).

Choose fullscreen/sprite for 2D, sphere/cube for 3D; the control window separates Shader, Pass and parameter groups.
Pause freezes time; right-drag on the preview orbits the camera and wheel zooms.
`source <directory>` selects a custom source root.
Use the sample vertex/engine-input interfaces when adding shaders. Properties automatically
supply fragment parameter declarations; there are no generated-header includes to maintain.

`smoke` edits isolated copies and checks HLSL and Properties failure recovery, generated layout
migration, parameter preservation, textures, multi-shader discovery, UI input and resize.
`shot` writes all four previews to `library/screenshots/shader-lab-*.png`.
`features` runs the focused preset/texture/custom-preview/new-shader/preview-size checks using isolated sources.
`hierarchy`, `targets` and `colors` cover Pass/folder interaction, RenderTexture lifetime and the palette.
Checks accept only injected input and locate widgets through `lab.widget_rect`.
`multipass` checks graph generation, target formats/sizes, 2D/3D feedback, pause/step/reset/resize
and atomic rollback/recovery using isolated sources, without running the other smoke suites.
The reusable `olib:kit/rendering/shader/dev` package is independent of scene dimension;
`olib:kit/rendering/material` has no editor dependency.
See [declaration syntax, integration and limits](../olib/kit/rendering/shader/dev/README.md).
