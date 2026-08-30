# BlancoVision.addon

A ReShade add-on for GTA V Legacy (DX11) that lets a plain `.fx` file reach into the game's own
rendering. It reads the game's constant buffers, writes to them, feeds values to shaders the game
never gave a parameter, and swaps compiled shaders by hash. Everything is configured from uniforms
in an effect file, so the ReShade overlay is the whole interface. There is no separate menu and no
config format to learn.

It was written for BlancoVision, a GTA V lighting mod, but nothing in it is specific to that mod.
If you are building a ReShade preset for GTA V and keep hitting the wall where post-processing
cannot see what the game knows, this is the way through.

## What it does

Four things, each driven by a `< bv = "..." >` annotation on any uniform in any effect.

`read` copies floats out of a game constant buffer into your uniform. One frame's `gDirectionalLight`
gives you the sun direction, and from that a day and night factor that no post-processing shader can
otherwise work out. A `float4x4` uniform takes a whole matrix, so you can project world positions to
screen and put a lens flare where the sun actually is.

`patch` writes the other way, rewriting floats in a game constant buffer before they reach the GPU.
The postfx buffer holds the timecycle-driven tonemap, desaturation, gamma and vignette, so a slider
in the overlay retunes those live, with no restart and no file editing.

`inject` packs your uniform into a constant buffer the add-on owns and binds it for a group of
shaders you name. This is for replacement shaders: if you have patched one of the game's own
shaders, `inject` gives it parameters the original had no float for, instead of forcing you to
repurpose one it already uses.

Shader replacement by hash comes with all of that. The add-on hashes every shader the game creates
and, when `BlancoVision\0x<hash>.cso` exists next to `ReShade.ini`, loads your file instead. On
FiveM this ships a patched shader without touching `update.rpf`.

There is also a dump switch. Point it at a scene, and it writes every constant buffer the matching
shaders bind, with sizes and the first 256 floats, into `ReShade.log`. Toggle it once per game state
and diff the log to find the offset you need. That is how every number in a working setup gets
found, and it is the piece worth installing this for even if you use nothing else.

## Requirements

The add-on build of ReShade, version 6.8.0 or the API 20 equivalent. The SDK version has to match
the runtime or ReShade refuses the add-on with error 1114, and the headers in `sdk/` are pinned to
6.8.0. Older runtimes work if you rebuild against their SDK.

DX11 only. GTA V Enhanced uses a different shader set and is not supported.

## Install

Copy `BlancoVision.addon` and `BlancoVision.addon.ini` next to `ReShade.ini`. On FiveM that is
`FiveM.app\plugins`. Put `examples\BlancoVision_Control.fx` in your `Shaders` folder and enable it
in the overlay. If the log says `Registered add-on "BlancoVision"` you are running.

## Writing rules

A rule is a uniform. This one takes over the game's FXAA subpixel setting:

```hlsl
uniform float AASubpix < bv = "patch"; bv_slot = 6; bv_size = 32; bv_offset = 4; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; > = 0.75;
```

`bv_slot` is the constant buffer register, `bv_offset` a float index into it, so `packoffset c67.y`
is `67 * 4 + 1 = 269`. `bv_op` is `set`, `mul` or `add`. `bv_size` restricts the rule to buffers of
exactly that byte size, which matters when two different buffers share a register. `bv_group` names
a hash group from the ini so a rule only fires for the shaders you mean, and `bv_switch` names a
bool uniform that gates it.

Use the custom `bv` annotation, not ReShade's `source`. A uniform with a `source` annotation is
special to ReShade and gets no widget drawn, which hides your whole panel.

Rules sitting at a neutral value do not claim the buffer they target. This matters if another add-on
patches the same constants: only a slider you have actually moved makes this one intercept, and
moving it back hands the buffer over again.

## The ini

`BlancoVision.addon.ini` lives next to `ReShade.ini`.

`[Groups]` holds named lists of shader hashes, CRC32 of the DXBC, the same hash REST uses. A rule
with no group matches every pixel shader. A group that exists but is empty matches nothing, which is
how you keep an unfinished rule switched off.

`[Inject]` sets `Slot`, the pixel stage register the injection buffer binds to, and `Group`, the
shaders it binds for. D3D11 constant buffer binding is sticky, so pick a register nothing else uses.
An empty `Group` turns injection off.

`[Replace]` and `[HDR]` switch shader replacement and an experimental HDR presentation path. The HDR
switches are read when the swap chain is created, long before any effect exists, so they only take
effect on the next launch.

## Build

```
python build.py
```

Needs the VS 2022 Build Tools C++ workload. Output is `BlancoVision.addon` in the repo root. A
prebuilt one is committed if you would rather not.

## Licence

MIT, see `LICENSE`. The ReShade add-on SDK headers in `sdk/` are Copyright (C) Patrick Mours under
BSD-3-Clause OR MIT and carry their own notices.
