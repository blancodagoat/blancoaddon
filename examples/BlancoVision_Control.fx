// BlancoVision_Control.fx: control panel for BlancoVision.addon. No image math, the one pass
// discards every pixel; the add-on reads these uniforms and patches the game constant buffers.
// Needs BlancoVision.addon and BlancoVision.addon.ini next to ReShade.ini, and the addon build
// of ReShade. Offsets are float indices from the shader RDEF: packoffset cN.x = N * 4, .y = N * 4 + 1.
// Live tuning only. Anything kept must still land in the timecycle or the pack, with a capture.

#include "ReShade.fxh"

uniform bool Enable < bv = "enable"; ui_label = "Apply patches"; ui_category = "BlancoVision addon"; > = true;
uniform bool DumpConstants < bv = "dump"; ui_label = "Log constant buffers to ReShade.log";
    ui_tooltip = "Per (pixel shader hash, register): buffer size and its first 256 floats. Turn on, look at the scene, turn off, read ReShade.log. Each turn-on logs a fresh snapshot, so one tick per game state (clear noon, rain, interior, dusk) can be diffed."; ui_category = "BlancoVision addon"; > = false;

// The two swap chain switches moved to the BlancoVision window in the ReShade overlay: they are
// read when the swap chain is created, long before this effect exists, so they need the ini.

// ---- postfx_fxaa, register b6 (32 bytes), the FXAA pass ----------------------------------------
// Live HDR controls. The patched FXAA in mod/hdr/fxaa_hdr.hlsl reads paper white out of
// ConsoleEdgeSharpness, a field the shader itself never uses, so this slider retunes the HDR
// output every frame with no restart and no shader rebuild. Needs the replacement shader loaded;
// with stock FXAA it does nothing.
uniform float PaperWhite < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 1; bv_op = "set";
    ui_type = "slider"; ui_min = 40.0; ui_max = 400.0; ui_step = 1.0; ui_label = "Paper white (nits)";
    ui_tooltip = "Where SDR white lands in the HDR image. scRGB treats 1.0 as 80 nits, so this scales the whole picture. 203 is the spec default; lower it if bright surfaces like water glare."; ui_category = "HDR output (live)"; > = 203.0;
uniform bool OverrideHDR < ui_label = "Apply HDR output controls"; ui_tooltip = "Needs the patched FXAA from mod/hdr/ installed. Off on a stock install."; ui_category = "HDR output (live)"; > = false;
uniform float ContentGamma < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 0; bv_op = "set";
    ui_type = "slider"; ui_min = 1.8; ui_max = 2.6; ui_step = 0.05; ui_label = "Content gamma (decode)";
    ui_tooltip = "The curve the game's output is decoded with. 2.2 is right for almost all PC content. Piecewise sRGB (roughly 2.0 here) lifts shadows and looks hazy with grey blacks; 2.4 is the TV/BT.1886 curve and gives deeper blacks."; ui_category = "HDR output (live)"; > = 2.2;
uniform float PeakNits < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 2; bv_op = "set";
    ui_type = "slider"; ui_min = 200.0; ui_max = 2000.0; ui_step = 10.0; ui_label = "Peak nits (highlight expansion)";
    ui_tooltip = "How far highlights above the knee are pushed. Set it to the panel's real peak brightness. This expands a clamped SDR image rather than recovering data, so past a point it only makes highlights brighter, not more detailed."; ui_category = "HDR output (live)"; > = 800.0;
uniform float HighlightKnee < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 3; bv_op = "set";
    ui_type = "slider"; ui_min = 0.3; ui_max = 0.95; ui_step = 0.01; ui_label = "Highlight knee";
    ui_tooltip = "Luminance where expansion starts. Lower pushes more of the image into the highlight range and looks glowier; higher keeps expansion to the brightest specular only."; ui_category = "HDR output (live)"; > = 0.55;
// The game's own FXAA parameters, same buffer. These three the shader really does read, so they
// work on stock FXAA as well as on the replacement. With in game MSAA off, this pass is the only
// AA in the frame, and the stock settings are tuned for consoles rather than for a 1440p desktop.
uniform bool OverrideAA < ui_label = "Take over the game FXAA (tick to use sliders below)"; ui_category = "Edge smoothing (live)"; > = false;
uniform float AASubpix < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 4; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Smoothing: thin details";
    ui_tooltip = "How much subpixel aliasing (shimmer on thin detail) is removed. Higher is softer. 0.75 is the usual quality value, the game ships lower."; ui_category = "Edge smoothing (live)"; > = 0.75;
uniform float AAEdgeThreshold < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 5; bv_op = "set";
    ui_type = "slider"; ui_min = 0.03; ui_max = 0.5; ui_step = 0.005; ui_label = "Smoothing: how obvious an edge must be";
    ui_tooltip = "Minimum local contrast treated as an edge. Lower catches more edges (better AA, softer image), higher only hard edges. 0.125 is quality, 0.166 to 0.25 is faster."; ui_category = "Edge smoothing (live)"; > = 0.125;
uniform float AAEdgeThresholdMin < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 6; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0312; ui_max = 0.0833; ui_step = 0.0021; ui_label = "Smoothing: ignore edges this dark";
    ui_tooltip = "Below this luminance, edges are left alone, which stops the filter chewing on dark noise. 0.0625 suits most content, 0.0312 for very dark scenes."; ui_category = "Edge smoothing (live)"; > = 0.0625;


// ---- postfx_cbuffer, register b5 (1488 bytes), the composite passes (group "composite") --------
uniform bool OverrideDesaturate < ui_label = "Override desaturation"; ui_category = "Postfx composite (b5)"; > = false;
uniform float Desaturate < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 268; bv_op = "set"; bv_switch = "OverrideDesaturate";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Desaturate (postfx_desaturation)"; ui_category = "Postfx composite (b5)"; > = 1.0;
uniform bool OverrideGamma < ui_label = "Override gamma"; ui_category = "Postfx composite (b5)"; > = false;
uniform float Gamma < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 269; bv_op = "set"; bv_switch = "OverrideGamma";
    ui_type = "slider"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.01; ui_label = "Gamma (final pow)"; ui_category = "Postfx composite (b5)"; > = 1.0;
uniform float VignetteIntensity < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 230; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Vignette intensity x (VignettingParams.z)"; ui_category = "Postfx composite (b5)"; > = 1.0;
uniform float BloomScale < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 29; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Game bloom x (BloomParams.y)"; ui_category = "Postfx composite (b5)"; > = 1.0;
uniform float GrainScale < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 62; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Game grain x (NoiseParams.z)"; ui_category = "Postfx composite (b5)"; > = 1.0;
uniform float3 HighlightTint < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 260; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Highlight tint x (ColorCorrectHighLum.rgb)"; ui_category = "Postfx composite (b5)"; > = float3(1.0, 1.0, 1.0);
uniform float3 ShadowTint < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 264; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Shadow tint x (ColorShiftLowLum.rgb)"; ui_category = "Postfx composite (b5)"; > = float3(1.0, 1.0, 1.0);
// Also in this buffer, not exposed: BrightTonemapParams0/1 at 40/44, DarkTonemapParams0/1 at 48/52
// (filmic A..F, W), VignettingColor at 232, TonemapParams at 56.

// ---- Ambient occlusion curve, misc_globals b2 (needs the patched AO shaders from mod/ao/) ------
// GTA V applies AO as a fixed 4*ao^4 curve with no floor: very steep, so AO does almost nothing
// across the mid range and then falls to exactly zero, which is one of the two ways the vanilla
// frame reaches pure black. tools/ao_patch.py rewrites seven passes to scale the AO term and
// floor it, reading both numbers from globalReuseMe00001/00002, which Rockstar left unused.
// At strength 1.0 and floor 0.0 the result is the stock curve, so this is a true A/B.
// Parallax depth on the materials that have a height map (normal_spec_*_pxm and friends).
// POMFlags is dead in the shipped shaders, and heightScale/heightBias are per material, but this
// global multiplies them all. It cannot create parallax where there is no height map.
uniform float HeightScale < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 4; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Surface bumpiness (brick walls only)";
    ui_tooltip = "Multiplies the global height scale that feeds every parallax material. Only affects surfaces the artists gave a height map, mostly brick and detailed decals. 1.0 is vanilla."; ui_category = "Surface bumpiness (live)"; > = 1.0;
uniform float AOStrength < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 6; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.05; ui_label = "Corner shadows: how dark";
    ui_tooltip = "Scales the AO term around 1.0 before the game's fourth power curve. 1.0 is vanilla, 0 removes AO entirely, above 1 deepens contact shadows. Affects ambient and image based reflection only, never the direct sun term."; ui_category = "Corner shadows (live)"; > = 1.0;
uniform float AOFloor < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 7; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.6; ui_step = 0.01; ui_label = "Corner shadows: stop them going black";
    ui_tooltip = "Smallest value the AO term may take, so fully occluded ambient never reaches pure black. The ENB's ShadowAmount 0.75 is the same idea. Vanilla is 0."; ui_category = "Corner shadows (live)"; > = 0.0;

// ---- misc_globals, register b2 (352 bytes), every shader ---------------------------------------
uniform float HDRScale < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 59; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.25; ui_max = 4.0; ui_step = 0.01; ui_label = "HDR pre-scale x (globalScalars3.w)"; ui_category = "Globals (b2, b3)"; > = 1.0;

// ---- lighting_globals, register b3 (960 bytes), every lit shader: the timecycle's lighting -----
uniform float3 SunColour < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 4; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Sun colour x (gDirectionalColour)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 NaturalAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 172; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Natural ambient 0 x (gLightNaturalAmbient0)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 NaturalAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 176; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Natural ambient 1 x (gLightNaturalAmbient1)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialIntAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 180; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Artificial interior ambient 0 x"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialIntAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 184; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Artificial interior ambient 1 x"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialExtAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 188; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Artificial exterior ambient 0 x (streetlight ambient)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialExtAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 192; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Artificial exterior ambient 1 x"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 DirectionalAmbient < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 196; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Directional ambient x (gDirectionalAmbientColour)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float3 FogColour < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 220; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Fog colour x (globalFogColor)"; ui_category = "Globals (b2, b3)"; > = float3(1.0, 1.0, 1.0);
uniform float4 SunDirectionView < bv = "read"; bv_slot = 3; bv_size = 960; bv_offset = 0;
    ui_type = "drag"; noedit = true; ui_label = "gDirectionalLight (read)"; ui_category = "Globals (b2, b3)"; > = float4(0, 0, 0, 0);

// ---- lighting_locals, 336 bytes, deferredLightParams. The sun pass binds it at b11 and the
// artificial light pass at b12, so the register alone separates them and no hash group is needed
// (tools/disasm.py on the vanilla containers; b11 also carries a 96 byte buffer, hence bv_size).
uniform bool OverrideShadowFloor < ui_label = "Override shadow floor"; ui_category = "Sun light (b11)"; > = false;
uniform float ShadowFloor < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 39; bv_op = "set"; bv_switch = "OverrideShadowFloor";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Shadow floor (deferredLightParams[9].w, ENB ShadowAmount)"; ui_category = "Sun light (b11)"; > = 0.75;
uniform float ShadowSoftness < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 37; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.01; ui_label = "Shadow softness x (deferredLightParams[9].y)"; ui_category = "Sun light (b11)"; > = 1.0;
uniform float ShadowBias < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 40; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.01; ui_label = "Shadow softness bias x (deferredLightParams[10].x)"; ui_category = "Sun light (b11)"; > = 1.0;

// ---- Deferred lights, lighting_locals at b12: every artificial light in the scene ---------------
// deferredLightParams[0] position, [1] direction, [2] tangent, [3] colour rgb and intensity w,
// [4].y radius. The buffer is uploaded once per light, so the radius gate is what separates street
// lights from head lights and coronas. Widen it to the full range to tint everything.
uniform float2 LightRadiusRange < ui_type = "slider"; ui_min = 0.0; ui_max = 80.0; ui_step = 0.5;
    ui_label = "Only lights with a radius in this range";
    ui_tooltip = "Street lights are the wide ones, roughly 10 m and up. Head lights, coronas and interior lamps sit well below that. Raise the low end to leave vehicles alone."; ui_category = "Deferred lights (b12)"; > = float2(0.0, 80.0);
uniform float3 LightColour < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 12; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "color"; ui_label = "Light colour tint";
    ui_tooltip = "Multiplies the light's own colour, so it tints rather than replaces. Warm sodium is roughly 1.0, 0.72, 0.42; cold LED roughly 0.85, 0.92, 1.0."; ui_category = "Deferred lights (b12)"; > = float3(1.0, 1.0, 1.0);
uniform float LightIntensity < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 15; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Light intensity";
    ui_tooltip = "Brightness of the same lights. Under 1 dims them without touching their reach."; ui_category = "Deferred lights (b12)"; > = 1.0;
uniform float LightRadius < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 17; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "slider"; ui_min = 0.25; ui_max = 3.0; ui_step = 0.05; ui_label = "Light reach";
    ui_tooltip = "How far the light carries. The gate reads the value before this rule writes it, so widening a light cannot pull it into or out of its own range."; ui_category = "Deferred lights (b12)"; > = 1.0;

// ---- deferred_lighting_locals, register b11, 96 bytes: peds ------------------------------------
uniform float3 SkinColourTweak < bv = "patch"; bv_slot = 11; bv_size = 96; bv_offset = 0; bv_op = "mul";
    ui_type = "color"; ui_label = "Skin colour";
    ui_tooltip = "Subsurface tint on peds. The 96 byte size is what tells this buffer apart from the sun's, which shares register b11."; ui_category = "Peds (b11)"; > = float3(1.0, 1.0, 1.0);
uniform float3 RimLightColour < bv = "patch"; bv_slot = 11; bv_size = 96; bv_offset = 12; bv_op = "mul";
    ui_type = "color"; ui_label = "Rim light colour";
    ui_tooltip = "Marked unused in the shaders shipped with this build, so it may do nothing."; ui_category = "Peds (b11)"; > = float3(1.0, 1.0, 1.0);


float4 PS_Nop(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target { if (pos.x >= 0.0) discard; return 0.0; }

technique BlancoVision_Control
<
    ui_label = "BlancoVision addon control";
    ui_tooltip = "Sliders read by BlancoVision.addon. Draws nothing.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Nop; }
}
