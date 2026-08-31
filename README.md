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

## The overlay

The add-on registers its own window in the ReShade overlay, under the add-on list. It shows how many
rules and inject uniforms it picked up, how many shaders it has replaced, and every hash group with
its size, so you can see at a glance whether a rule is switched off because its group is empty.

Under **Which settings are reaching the game** it lists every rule with the number of times it has
changed bytes on their way to the GPU. Green is writing, grey is sitting at its default, red never
saw a buffer of that size at that register on this build and is the one to go fix. Amber, **shared**,
means the buffer it writes to is also claimed at another register, so its uploads carry two layouts
and the rule is firing on both; see below.

The settings that live in the ini are editable there and saved back to the file when you change one:
shader replacement, the injection register and group, and the HDR switches. Rules themselves stay in
the effect panel, where ReShade already draws a widget for every uniform and saves the values into
your preset.

## Requirements

The add-on build of ReShade 6.6.0 or newer, which is every release since September 2025.

ReShade refuses an add-on built against a newer API than its own, but goes on serving the older
APIs it has always supported, so the pin belongs at the floor rather than at the version you happen
to run. `sdk/` holds the 6.6.2 headers (API 18) and `imgui/` the matching ImGui 19222 from the
docking branch, which every later runtime still answers. Both are exact: ReShade's own header stops
the build if the ImGui version beside it is not the one that SDK expects.

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

`bv_when_offset` and `bv_when` gate a rule on the contents of the buffer it is about to write. The
rule applies only when the float at `bv_when_offset` falls inside the range held by the `float2`
uniform `bv_when` names. GTA V uploads its light constants once per light, so a tint on the light
colour would otherwise hit street lights, head lights and coronas alike. Gate it on the light radius
and the range becomes a slider that picks which lights you meant:

```hlsl
uniform float2 LightRadiusRange < ui_type = "slider"; ui_min = 0.0; ui_max = 80.0; > = float2(10.0, 80.0);
uniform float3 LightColour < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 12; bv_op = "mul";
    bv_when_offset = 17; bv_when = "LightRadiusRange"; ui_type = "color"; > = float3(1.0, 0.72, 0.42);
```

`bv_when2_offset` and `bv_when2` add a second such gate, ANDed with the first, for a buffer that one
float cannot tell apart.

### When one buffer carries two different things

A register decides which rules claim a buffer. It cannot decide what an upload is for, because the
upload happens before the draw that consumes it. GTA V's `lighting_locals` is the sun pass at `b11`
and every artificial light at `b12`, and if both are the same 336 byte resource then nothing at the
moment those bytes are written says which of the two layouts they are. Rules on both registers then
fire on both kinds of upload, and because the gate is being asked about a float that means something
else in the other layout, whether it passes moves with the scene: brightness that shifts as the
camera turns.

The add-on writes that collision to `ReShade.log` the first time it sees it, naming the buffer, its
size and the rule, and marks the rules involved **shared** in the table. The gates are what resolves
it: find a float only the layout you meant holds, and gate on it.

`examples/BlancoVision_Control.fx` is a worked panel with about ninety five rules on it: the postfx
composite, the FXAA pass, the timecycle lighting globals, every artificial light, the sun pass,
cascade shadow bias, the shadow blur kernel, AO darkness and reach, puddles and rain ripples, the
reflection mip count and fog intensity. Every offset in it came out of the game's own shaders
rather than a wiki, so it is MIT like the rest of the repo.

Finding your own offsets does not need the dump switch either. `D3DDisassemble` prints an RDEF
block naming every cbuffer variable with its byte offset and marking the unused ones, and the
instruction stream tells you what each one does.

A rule costs one bit in a 128 bit mask, so 128 of them can be live at once.

Two warnings from doing that across forty containers. Several registers carry more than one buffer,
so `bv_size` is not optional. Worse, the same named buffer is not the same layout everywhere:
GTA V's `misc_globals` is 352 bytes in the deferred passes and 336 in the world ones, with three
floats missing from the middle, so an offset lifted from the wrong container points four bytes off
and the rule silently does nothing. Take the size and the offset from a container whose shaders you
actually want to reach, and check that something in it reads the variable.

Use the custom `bv` annotation, not ReShade's `source`. A uniform with a `source` annotation is
special to ReShade and gets no widget drawn, which hides your whole panel.

Switching the effect off switches the rules off. A technique the user has unticked, or ReShade's
effects toggle key, stops every patch and unbinds the injection buffer, and the add-on window says
so. That has to be asked for rather than inferred: ReShade keeps the uniforms of a switched off
effect readable, so their values alone never say the panel is off.

Rules sitting at a neutral value do not claim the buffer they target, and neither does a buffer whose
size is not the `bv_size` asked for. This matters if another add-on
patches the same constants: only a slider you have actually moved makes this one intercept, and
moving it back hands the buffer over again.

## The ini

`BlancoVision.addon.ini` lives next to `ReShade.ini`.

`[Groups]` holds named lists of shader hashes, CRC32 of the shader's DXBC bytecode. A rule
with no group matches every pixel shader. A group that exists but is empty matches nothing, which is
how you keep an unfinished rule switched off.

`[Inject]` sets `Slot`, the pixel stage register the injection buffer binds to, and `Group`, the
shaders it binds for. D3D11 constant buffer binding is sticky, so pick a register nothing else uses.
An empty `Group` turns injection off.

`[Replace]` and `[HDR]` switch shader replacement and an experimental HDR presentation path. The HDR
switches are read when the swap chain is created, long before any effect exists, so they only take
effect on the next launch. You can edit all of these in the overlay instead of the file.

## Build

```
python build.py
```

Needs the VS 2022 Build Tools C++ workload. Output is `BlancoVision.addon` in the repo root. A
prebuilt one is committed if you would rather not.

## Where the numbers come from

Every register, size and offset in the example panel was read out of GTA V's own shader containers
with `D3DDisassemble`, and each one was checked to have shaders that actually read it before it got
a slider. That matters for the licence: those are facts about Rockstar's shaders, discovered here,
so the code around them is ours to give away.

The rule the panel follows, if you extend it: another mod can tell you *what* is possible, and a
feature list is not protectable, but the mechanism has to come from the game's own files rather
than from someone's binary. Note where each fact came from as you go. A number with no recorded
source is a number you cannot defend.

Worth knowing before you go hunting: a lot of what looks like it must be a shader constant is
plain data. GTA V's `visualsettings.dat` carries over a thousand keys, including reflection boosts,
light cutoff distances and rim lighting, and several of them are the same value the panel patches
live. Tune it on a slider, then write it into the file.

## Licence

MIT, see `LICENSE`. The ReShade add-on SDK headers in `sdk/` are Copyright (C) Patrick Mours under
BSD-3-Clause OR MIT. `imgui/` holds two headers from Dear ImGui v1.92.5 docking, Copyright (C) Omar
Cornut, MIT. Both carry their own notices.
