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
```

- `game_ui`: ruins scene with HUD, skill cooldowns, grid inventory and pause menu.
  Args: `hud` / `modal` / `scaled` / `scroll` switch the initial state, `font <path.ttf>` picks a font,
  `cli` opens the stdin debug console (`help`, `quit`).
- `ui_gallery`: settings page, scrolling inventory and modal confirm; the basic widget acceptance page.
  Args: `modal` / `scaled` / `scroll` / `msdf` / `sdf`, `font <path.ttf>`.
  `sdf` bakes the UI font at runtime as a distance field; `msdf` adds the ring shader probe.
- Add `shot` to either one to render a frame, write a PNG to this directory and exit
  (used for screenshot regression of `kit/ui`, see olib `kit/ui/README.md`).
