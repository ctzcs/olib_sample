# OFoster Samples

Runnable examples for [olib](https://github.com/ctzcs/olib): the Foster port (`olib:foster`)
and the extension layer (`olib:kit/*`).

## Requirements

- Odin nightly
- olib checked out next to this project as `olib` (`run.bat` uses `-collection:olib=..\olib`)
- SDL3 runtime available from the Odin distribution

## Run an example

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

kit/ui:

```bat
run.bat game_ui
run.bat ui_gallery
run.bat book_ui
```

- `game_ui`: ruins scene with HUD, skill cooldowns, grid inventory and pause menu.
  Args: `hud` / `modal` / `scaled` / `scroll` switch the initial state, `font <path.ttf>` picks a font,
  `cli` opens the stdin debug console (`help`, `quit`).
- `ui_gallery`: settings page, scrolling inventory and modal confirm; the basic widget acceptance page.
  Args: `modal` / `scaled` / `scroll` / `msdf` / `sdf`, `font <path.ttf>`.
  `sdf` bakes the UI font at runtime as a distance field; `msdf` adds the ring shader probe.
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
- The 3D shader supports Vulkan and D3D12. Precompiled SPIR-V/DXIL files are included;
  normal builds need no shader compiler. After editing `src/book_ui/shaders/Book.hlsl`,
  run `powershell -File src/book_ui/shaders/build.ps1` with Vulkan SDK `dxc` on PATH.

In Zed, use **task: spawn** and select **Book UI: Run** from `.zed/tasks.json`.

kit/rendering3d reference renderer:

```bat
run.bat forward3d
run.bat forward3d shot
```

- `forward3d`: a Standard PBR forward renderer (directional, point and spot lights,
  sorted alpha blending, debug grid) built on the mechanism-only `kit/rendering3d`
  (mesh upload, generic render queue, shader bytecode selection, std140 packing,
  DebugDraw3D). Lighting, materials and shaders live in this sample, not in olib:
  copy `src/forward3d` into a game and change them to fit its look.
- `shot` renders a fixed-time frame, writes `forward3d.png` to this directory and exits.
  Set `SDL_GPU_DRIVER=vulkan` or `SDL_GPU_DRIVER=direct3d12` to pick the backend.
- Shaders are precompiled to SPIR-V/DXIL/MSL. After editing `src/forward3d/shaders/*.hlsl`, run
  `odin run ../olib/tools/shaders -- -dir:src/forward3d/shaders` (needs SDL_shadercross on PATH).
- `forward3d_test.odin` checks the cbuffer layouts against the shader and the mesh winding;
  olib's `odin run tools/check` runs it.
