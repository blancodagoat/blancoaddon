// BlancoVision_Control.fx: control panel for BlancoVision.addon. No image math, the one pass
// discards every pixel; the add-on reads these uniforms and patches the game constant buffers.
// Needs BlancoVision.addon and BlancoVision.addon.ini next to ReShade.ini, and the addon build
// of ReShade. Offsets are float indices from the shader RDEF: packoffset cN.x = N * 4, .y = N * 4 + 1.
// Live tuning only. Anything kept must still land in the timecycle or the pack, with a capture.

#include "ReShade.fxh"

uniform bool Enable < bv = "enable"; ui_label = "Apply everything on this panel"; ui_category = "Add-on"; > = true;
uniform bool DumpConstants < bv = "dump"; ui_label = "Write shader constants to the log (for finding new settings)";
    ui_tooltip = "Per (pixel shader hash, register): buffer size and its first 256 floats. Turn on, look at the scene, turn off, read ReShade.log. Each turn-on logs a fresh snapshot, so one tick per game state (clear noon, rain, interior, dusk) can be diffed."; ui_category = "Add-on"; > = false;

// The two swap chain switches moved to the BlancoVision window in the ReShade overlay: they are
// read when the swap chain is created, long before this effect exists, so they need the ini.

// ---- postfx_fxaa, register b6 (32 bytes), the FXAA pass ----------------------------------------
// Live HDR controls. The patched FXAA in mod/hdr/fxaa_hdr.hlsl reads paper white out of
// ConsoleEdgeSharpness, a field the shader itself never uses, so this slider retunes the HDR
// output every frame with no restart and no shader rebuild. Needs the replacement shader loaded;
// with stock FXAA it does nothing.
uniform float PaperWhite < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 1; bv_op = "set";
    ui_type = "slider"; ui_min = 40.0; ui_max = 400.0; ui_step = 1.0; ui_label = "HDR paper white";
    ui_tooltip = "Where SDR white lands in the HDR image. scRGB treats 1.0 as 80 nits, so this scales the whole picture. 203 is the spec default; lower it if bright surfaces like water glare."; ui_category = "HDR output"; > = 203.0;
uniform bool OverrideHDR < ui_label = "Apply the HDR controls"; ui_tooltip = "Needs the patched FXAA from mod/hdr/ installed. Off on a stock install."; ui_category = "HDR output"; > = false;
uniform float ContentGamma < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 0; bv_op = "set";
    ui_type = "slider"; ui_min = 1.8; ui_max = 2.6; ui_step = 0.05; ui_label = "HDR content gamma";
    ui_tooltip = "The curve the game's output is decoded with. 2.2 is right for almost all PC content. Piecewise sRGB (roughly 2.0 here) lifts shadows and looks hazy with grey blacks; 2.4 is the TV/BT.1886 curve and gives deeper blacks."; ui_category = "HDR output"; > = 2.2;
uniform float PeakNits < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 2; bv_op = "set";
    ui_type = "slider"; ui_min = 200.0; ui_max = 2000.0; ui_step = 10.0; ui_label = "HDR peak brightness";
    ui_tooltip = "How far highlights above the knee are pushed. Set it to the panel's real peak brightness. This expands a clamped SDR image rather than recovering data, so past a point it only makes highlights brighter, not more detailed."; ui_category = "HDR output"; > = 800.0;
uniform float HighlightKnee < bv = "patch"; bv_switch = "OverrideHDR"; bv_slot = 6; bv_size = 32; bv_offset = 3; bv_op = "set";
    ui_type = "slider"; ui_min = 0.3; ui_max = 0.95; ui_step = 0.01; ui_label = "HDR highlight knee";
    ui_tooltip = "Luminance where expansion starts. Lower pushes more of the image into the highlight range and looks glowier; higher keeps expansion to the brightest specular only."; ui_category = "HDR output"; > = 0.55;
// The game's own FXAA parameters, same buffer. These three the shader really does read, so they
// work on stock FXAA as well as on the replacement. With in game MSAA off, this pass is the only
// AA in the frame, and the stock settings are tuned for consoles rather than for a 1440p desktop.
uniform bool OverrideAA < ui_label = "Take over the game edge smoothing"; ui_category = "Edge smoothing"; > = false;
uniform float AASubpix < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 4; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Smooth thin details";
    ui_tooltip = "How much subpixel aliasing (shimmer on thin detail) is removed. Higher is softer. 0.75 is the usual quality value, the game ships lower."; ui_category = "Edge smoothing"; > = 0.75;
uniform float AAEdgeThreshold < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 5; bv_op = "set";
    ui_type = "slider"; ui_min = 0.03; ui_max = 0.5; ui_step = 0.005; ui_label = "How obvious an edge must be";
    ui_tooltip = "Minimum local contrast treated as an edge. Lower catches more edges (better AA, softer image), higher only hard edges. 0.125 is quality, 0.166 to 0.25 is faster."; ui_category = "Edge smoothing"; > = 0.125;
uniform float AAEdgeThresholdMin < bv = "patch"; bv_switch = "OverrideAA"; bv_slot = 6; bv_size = 32; bv_offset = 6; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0312; ui_max = 0.0833; ui_step = 0.0021; ui_label = "Ignore edges darker than";
    ui_tooltip = "Below this luminance, edges are left alone, which stops the filter chewing on dark noise. 0.0625 suits most content, 0.0312 for very dark scenes."; ui_category = "Edge smoothing"; > = 0.0625;


// ---- postfx_cbuffer, register b5 (1488 bytes), the composite passes (group "composite") --------
uniform bool OverrideDesaturate < ui_label = "Override colour strength"; ui_category = "Colour and tone"; > = false;
uniform float Desaturate < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 268; bv_op = "set"; bv_switch = "OverrideDesaturate";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Colour strength"; ui_category = "Colour and tone"; > = 1.0;
uniform bool OverrideGamma < ui_label = "Override brightness curve"; ui_category = "Colour and tone"; > = false;
uniform float Gamma < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 269; bv_op = "set"; bv_switch = "OverrideGamma";
    ui_type = "slider"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.01; ui_label = "Brightness curve"; ui_category = "Colour and tone"; > = 1.0;
uniform float VignetteIntensity < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 230; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Corner darkening"; ui_category = "Colour and tone"; > = 1.0;
uniform float BloomScale < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 29; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Game bloom"; ui_category = "Colour and tone"; > = 1.0;
uniform float GrainScale < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 62; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Game grain"; ui_category = "Colour and tone"; > = 1.0;
uniform float3 HighlightTint < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 260; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Highlight tint"; ui_category = "Colour and tone"; > = float3(1.0, 1.0, 1.0);
uniform float3 ShadowTint < bv = "patch"; bv_group = "composite"; bv_slot = 5; bv_size = 1488; bv_offset = 264; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; ui_label = "Shadow tint"; ui_category = "Colour and tone"; > = float3(1.0, 1.0, 1.0);
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
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Brick and decal depth";
    ui_tooltip = "Multiplies the global height scale that feeds every parallax material. Only affects surfaces the artists gave a height map, mostly brick and detailed decals. 1.0 is vanilla."; ui_category = "Roads and surfaces"; > = 1.0;
uniform float AOStrength < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 6; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.05; ui_label = "Corner shadow contrast (needs the patched passes)";
    ui_tooltip = "Scales the AO term around 1.0 before the game's fourth power curve. 1.0 is vanilla, 0 removes AO entirely, above 1 deepens contact shadows. Affects ambient and image based reflection only, never the direct sun term."; ui_category = "Corner shadows"; > = 1.0;
uniform float AOFloor < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 7; bv_op = "set";
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.6; ui_step = 0.01; ui_label = "Stop corner shadows going black";
    ui_tooltip = "Smallest value the AO term may take, so fully occluded ambient never reaches pure black. The ENB's ShadowAmount 0.75 is the same idea. Vanilla is 0."; ui_category = "Corner shadows"; > = 0.0;

// ---- misc_globals, register b2 (352 bytes), every shader ---------------------------------------
uniform float HDRScale < bv = "patch"; bv_slot = 2; bv_size = 352; bv_offset = 59; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.25; ui_max = 4.0; ui_step = 0.01; ui_label = "Overall brightness before tonemap"; ui_category = "Sunlight and ambient"; > = 1.0;

// ---- lighting_globals, register b3 (960 bytes), every lit shader: the timecycle's lighting -----
uniform float3 SunColour < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 4; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Sunlight colour"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 NaturalAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 172; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Daylight ambient (sky lit)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 NaturalAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 176; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Daylight ambient (shaded)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialIntAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 180; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Indoor light ambient (lit)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialIntAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 184; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Indoor light ambient (shaded)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialExtAmbient0 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 188; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Street light ambient (lit)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 ArtificialExtAmbient1 < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 192; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Street light ambient (shaded)"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 DirectionalAmbient < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 196; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Ambient bounce from the sun"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float3 FogColour < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 220; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01; ui_label = "Fog colour"; ui_category = "Sunlight and ambient"; > = float3(1.0, 1.0, 1.0);
uniform float4 SunDirectionView < bv = "read"; bv_slot = 3; bv_size = 960; bv_offset = 0;
    ui_type = "drag"; noedit = true; ui_label = "Sun direction (read from the game)"; ui_category = "Sunlight and ambient"; > = float4(0, 0, 0, 0);

// ---- lighting_locals, 336 bytes, deferredLightParams. The sun pass binds it at b11 and the
// artificial light pass at b12, so the register alone separates them and no hash group is needed
// (tools/disasm.py on the vanilla containers; b11 also carries a 96 byte buffer, hence bv_size).
uniform bool OverrideShadowFloor < ui_label = "Override how dark shadows go"; ui_category = "Sunlight and shadows"; > = false;
uniform float ShadowFloor < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 39; bv_op = "set"; bv_switch = "OverrideShadowFloor";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "How dark sun shadows go"; ui_category = "Sunlight and shadows"; > = 0.75;
uniform float ShadowSoftness < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 37; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.01; ui_label = "Sun shadow softness"; ui_category = "Sunlight and shadows"; > = 1.0;
uniform float ShadowBias < bv = "patch"; bv_slot = 11; bv_size = 336; bv_offset = 40; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.01; ui_label = "Sun shadow softness bias"; ui_category = "Sunlight and shadows"; > = 1.0;

// ---- Deferred lights, lighting_locals at b12: every artificial light in the scene ---------------
// deferredLightParams[0] position, [1] direction, [2] tangent, [3] colour rgb and intensity w,
// [4].y radius. The buffer is uploaded once per light, so the radius gate is what separates street
// lights from head lights and coronas. Widen it to the full range to tint everything.
uniform float2 LightRadiusRange < ui_type = "slider"; ui_min = 0.0; ui_max = 80.0; ui_step = 0.5;
    ui_label = "Which lights this section affects (size range)";
    ui_tooltip = "Street lights are the wide ones, roughly 10 m and up. Head lights, coronas and interior lamps sit well below that. Raise the low end to leave vehicles alone."; ui_category = "Street lights and lamps"; > = float2(0.0, 80.0);
uniform float3 LightColour < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 12; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "color"; ui_label = "Street light colour";
    ui_tooltip = "Multiplies the light's own colour, so it tints rather than replaces. Warm sodium is roughly 1.0, 0.72, 0.42; cold LED roughly 0.85, 0.92, 1.0."; ui_category = "Street lights and lamps"; > = float3(1.0, 1.0, 1.0);
uniform float LightIntensity < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 15; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Street light brightness";
    ui_tooltip = "Brightness of the same lights. Under 1 dims them without touching their reach."; ui_category = "Street lights and lamps"; > = 1.0;
uniform float LightRadius < bv = "patch"; bv_slot = 12; bv_size = 336; bv_offset = 17; bv_op = "mul"; bv_when_offset = 17; bv_when = "LightRadiusRange";
    ui_type = "slider"; ui_min = 0.25; ui_max = 3.0; ui_step = 0.05; ui_label = "Street light reach";
    ui_tooltip = "How far the light carries. The gate reads the value before this rule writes it, so widening a light cannot pull it into or out of its own range."; ui_category = "Street lights and lamps"; > = 1.0;

// ---- deferred_lighting_locals, register b11, 96 bytes: peds ------------------------------------
uniform float3 SkinColourTweak < bv = "patch"; bv_slot = 11; bv_size = 96; bv_offset = 0; bv_op = "mul";
    ui_type = "color"; ui_label = "Skin tone";
    ui_tooltip = "Subsurface tint on peds. The 96 byte size is what tells this buffer apart from the sun's, which shares register b11."; ui_category = "People"; > = float3(1.0, 1.0, 1.0);
uniform float3 RimLightColour < bv = "patch"; bv_slot = 11; bv_size = 96; bv_offset = 12; bv_op = "mul";
    ui_type = "color"; ui_label = "Rim light on people";
    ui_tooltip = "Marked unused in the shaders shipped with this build, so it may do nothing."; ui_category = "People"; > = float3(1.0, 1.0, 1.0);


// ---- Ambient occlusion generation, ssao_locals at b12, 352 bytes --------------------------------
// The application curve is a dead end (docs/13-shader-levers.md): the occlusion is generated at a
// ten centimetre radius, so darkening it further reads as nothing. These are the generation side,
// the same numbers hbaosettings.xml feeds, except live instead of needing a restart.
uniform float SSAOStrength < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 16; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow darkness";
    ui_tooltip = "g_SSAOStrength, read by 14 of the AO passes. Multiplies how dark the occlusion gets, not how far it reaches."; ui_category = "Corner shadows"; > = 1.0;
uniform float4 SSAOFalloffKernel < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 28; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.1; ui_max = 8.0; ui_step = 0.05; ui_label = "Corner shadow reach";
    ui_tooltip = "FallOffAndKernelParam, the reach side. Raising the kernel components is the closest the game gets to a ReShade AO radius. Watch a corner while dragging; the components are not individually named in the shader."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 AmbientOcclusionEffect < bv = "patch"; bv_slot = 5; bv_size = 128; bv_offset = 8; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow effect on ambient light";
    ui_tooltip = "gAmbientOcclusionEffect in more_stuff. How much the AO term is allowed to darken the ambient and the reflection."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);

// ---- Shadows -----------------------------------------------------------------------------------
// soft_shadow_locals b10 (64 bytes) is the shadow blur; b10 also carries puddle_locals at 48, so
// the size matters. csmshader b6 (784) is the cascade setup, and b6 also holds the 32 byte FXAA
// buffer that the postfx section above patches.
uniform float4 ShadowKernel < bv = "patch"; bv_slot = 10; bv_size = 64; bv_offset = 8; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.25; ui_max = 6.0; ui_step = 0.05; ui_label = "Shadow edge softness";
    ui_tooltip = "kernelParam, the filter the soft shadow pass samples with. Widening it softens shadow edges without touching resolution. This is where softness comes from, never a post blur."; ui_category = "Sunlight and shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 CSMDepthBias < bv = "patch"; bv_slot = 6; bv_size = 784; bv_offset = 48; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Shadow contact offset";
    ui_tooltip = "gCSMDepthBias, one value per cascade. Lower pulls contact shadows back onto their object; too low and surfaces shadow themselves in stripes."; ui_category = "Sunlight and shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 CSMSlopeBias < bv = "patch"; bv_slot = 6; bv_size = 784; bv_offset = 52; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Shadow offset on slopes";
    ui_tooltip = "gCSMDepthSlopeBias, the same per cascade but scaled by the surface angle. This is the one that fixes shadow acne on sloped ground."; ui_category = "Sunlight and shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 CSMShadowParams < bv = "patch"; bv_slot = 6; bv_size = 784; bv_offset = 60; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Shadow tuning";
    ui_tooltip = "gCSMShadowParams, read by 56 shaders. Unnamed components, so drag one at a time and watch."; ui_category = "Sunlight and shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 ParticleShadowParams < bv = "patch"; bv_slot = 12; bv_size = 32; bv_offset = 4; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Shadows on smoke and rain";
    ui_tooltip = "particleShadowsParams in cascadeshadows_recieving_locals. How hard smoke and rain take shadow."; ui_category = "Sunlight and shadows"; > = float4(1.0, 1.0, 1.0, 1.0);

// ---- Roads and wet surfaces, puddle_locals b10 (48) and ripple_locals b9 (32) -------------------
uniform float4 PuddleScaleRange < bv = "patch"; bv_slot = 10; bv_size = 48; bv_offset = 0; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Puddle size and spread";
    ui_tooltip = "g_Puddle_ScaleXY_Range. How big the puddle mask tiles and how far it reaches."; ui_category = "Puddles and rain"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 PuddleParams < bv = "patch"; bv_slot = 10; bv_size = 48; bv_offset = 4; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Puddle depth and edge";
    ui_tooltip = "g_PuddleParams. Wet road reflections are the strongest single thing a night scene has, so this is worth a pass at 0.5 and at 2."; ui_category = "Puddles and rain"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float3 RippleData < bv = "patch"; bv_slot = 9; bv_size = 32; bv_offset = 0; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Rain ripples";
    ui_tooltip = "RippleData, the rings rain punches into standing water."; ui_category = "Puddles and rain"; > = float3(1.0, 1.0, 1.0);

// ---- Reflections and fog, more_stuff b5 (128) and misc_globals b2 -------------------------------
// b5 is postfx_cbuffer at 1488 bytes in the composite passes and more_stuff at 128 everywhere else.
uniform float ReflectionMipCount < bv = "patch"; bv_slot = 5; bv_size = 128; bv_offset = 26; bv_op = "set"; bv_switch = "OverrideReflectionMip";
    ui_type = "slider"; ui_min = 1.0; ui_max = 9.0; ui_step = 1.0; ui_label = "Building reflection sharpness";
    ui_tooltip = "gReflectionMipCount. Fewer mips keeps the cube map sharp on rough surfaces, more blurs it. This changes how a reflection looks; what it contains is the timecycle range in docs/13-shader-levers.md, which is a pack change rather than a slider."; ui_category = "Reflections and fog"; > = 9.0;
uniform bool OverrideReflectionMip < ui_label = "Override reflection sharpness"; ui_category = "Reflections and fog"; > = false;
uniform float GlobalFogIntensity < bv = "patch"; bv_slot = 2; bv_size = 336; bv_offset = 73; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.02; ui_label = "Fog thickness";
    ui_tooltip = "gGlobalFogIntensity. The world build of misc_globals is 336 bytes and drops three floats the deferred one has, so every offset after them shifts: this is float 73 there and 77 in the 352 byte variant, which no shader reads."; ui_category = "Reflections and fog"; > = 1.0;
uniform float4 ReflectionTweaks < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 236; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Lit window reflections";
    ui_tooltip = "gReflectionTweaks. Read only by the emissive glass shaders, so this is the reflection on lit windows at night and nothing else. Narrower than the name suggests, and worth having anyway because lit glass is most of what a city skyline is after dark."; ui_category = "Reflections and fog"; > = float4(1.0, 1.0, 1.0, 1.0);


// ---- Water, water_globals b4 (272 bytes) and water_locals b11 (64) ------------------------------
// docs/13-shader-levers.md names water as where the game looks most dated and where the shader owns
// reflection, normals and depth at once. These are the globals behind it, and unlike most of this
// panel they have plenty of readers: the counts below are from tools/cbmap.py on water.fxc.
uniform float4 WaterAmbientColour < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 12; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.02; ui_label = "Water colour";
    ui_tooltip = "gWaterAmbientColor, read by 9 of the water shaders. The colour water takes from the sky rather than from the sun, so this is what makes it read as blue, green or grey."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 WaterDirectionalColour < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 16; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.02; ui_label = "Sun glint on water";
    ui_tooltip = "gWaterDirectionalColor. The sun's contribution, which is the specular glint off the surface."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 OceanParams0 < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 24; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Wave shape (set 1)";
    ui_tooltip = "gOceanParams0, read by 8 shaders. Wave shape and surface normal strength live here. Drag one component at a time while looking at open water."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 OceanParams1 < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 28; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Wave shape (set 2)";
    ui_tooltip = "gOceanParams1, read by 6."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 WaterFogParams < bv = "patch"; bv_slot = 11; bv_size = 64; bv_offset = 4; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Water clarity with depth";
    ui_tooltip = "FogParams in water_locals, read by 8. How fast the water fogs out with depth. Lower is clearer and shows the bottom, higher is murkier. Register b11 also carries the sun pass at 336 bytes and ped skin at 96, so the 64 is what keeps this off them."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);

// ---- The rest of ssao_locals (b12, 352): hbaosettings.xml, live -------------------------------
// hbaosettings.xml carries 13 numbers and needs a restart to change one. They arrive here, so the
// whole file is tunable live. Components are not named in the shader, so the honest way to use this
// is one drag at a time against a fixed shot, then write what wins back into the xml.
uniform float4 SSAONormalOffset < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 4; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow surface offset";
    ui_tooltip = "gNormalOffset. How far the sample point is pushed off the surface before tracing, which is the usual cure for a surface occluding itself."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOOffsetScale0 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 8; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow spread (set 1)";
    ui_tooltip = "gOffsetScale0, the sampling pattern. Scaling it up widens the search and is the other half of the radius, next to the kernel."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOOffsetScale1 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 12; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow spread (set 2)";
    ui_tooltip = "gOffsetScale1, the second pattern."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOMixFade < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 20; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow blend with distance";
    ui_tooltip = "g_CPQSMix_QSFadeIn. The blend between the two AO methods and where the cheaper one fades in. CPRelativeStrength and the blend distances in hbaosettings.xml land around here."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOExtra0 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 40; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow tuning A";
    ui_tooltip = "gExtraParams0, read by 4 shaders."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOExtra1 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 44; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow tuning B";
    ui_tooltip = "gExtraParams1."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOExtra2 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 48; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow tuning C";
    ui_tooltip = "gExtraParams2, the most read of the five at 6 shaders."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOExtra3 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 52; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow tuning D";
    ui_tooltip = "gExtraParams3."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 SSAOExtra4 < bv = "patch"; bv_slot = 12; bv_size = 352; bv_offset = 56; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Corner shadow tuning E";
    ui_tooltip = "gExtraParams4. FoliageStrength, MaxPixels and CutoffPixels are somewhere in these five."; ui_category = "Corner shadows"; > = float4(1.0, 1.0, 1.0, 1.0);

// ---- Surfaces, megashader_locals at b12, 48 bytes ----------------------------------------------
// Not a glass buffer. The 48 byte layout is shared by roads, walls, terrain, grass, foliage and
// decals: normal_spec and its whole family, grass_fur, normal_spec_decal. Per material and uploaded
// per draw, so one slider moves every surface in the frame that uses this layout.
//
//   0 specularFresnel   1 specularFalloffMult   2 specularIntensityMult
//   4 to 6 specMapIntMask   7 bumpiness   8 varies, see the wetness slider
uniform float SurfaceBumpiness < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 7; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Road and wall detail";
    ui_tooltip = "Normal map strength on roads, walls, dirt and foliage alike. This is the one that makes tarmac read as tarmac instead of a flat grey plane. Nothing is added, the normal maps are already there and this decides how much of them survives."; ui_category = "Roads and surfaces"; > = 1.0;
uniform float SurfaceSpecular < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 2; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Surface shine";
    ui_tooltip = "specularIntensityMult. How bright the highlight is. Pairs with bumpiness: the bumps decide where the highlight lands, this decides how much of it you see."; ui_category = "Roads and surfaces"; > = 1.0;
uniform float SurfaceSpecularFalloff < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 1; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.1; ui_max = 4.0; ui_step = 0.05; ui_label = "Shine tightness";
    ui_tooltip = "specularFalloffMult. Tightens the highlight to a hard glint or spreads it into a broad sheen, which is the difference between polished and matte at the same brightness."; ui_category = "Roads and surfaces"; > = 1.0;
uniform float SurfaceFresnel < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 0; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.1; ui_max = 4.0; ui_step = 0.05; ui_label = "Shine at head on angles";
    ui_tooltip = "specularFresnel. How much the highlight depends on viewing angle. Lower makes a road shine when you look straight down at it, not only at a grazing angle."; ui_category = "Roads and surfaces"; > = 1.0;
uniform float3 SpecMapMask < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 4; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Shine map channels";
    ui_tooltip = "specMapIntMask. Which channels of the material's specular map are read and how hard. Read by every shader in the family."; ui_category = "Roads and surfaces"; > = float3(1.0, 1.0, 1.0);
uniform float SurfaceWetness < bv = "patch"; bv_slot = 12; bv_size = 48; bv_offset = 8; bv_op = "mul";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Road wetness";
    ui_tooltip = "Float 8 is wetnessMultiplier on nearly every family in this layout, which is why a reflectivity slider here did nothing visible: only normal_spec_cubemap_reflect calls that float reflectivePower. On normal_spec_decal_detail it is useTessellation instead, and multiplying a flag that is already 0 or 1 leaves it alone, so this is safe to drag."; ui_category = "Roads and surfaces"; > = 1.0;

// ---- Fog, lighting_globals b3 and more_stuff b5 -------------------------------------------------
// globalFogParams and the three extra fog colours have 16 readers each in normal_spec, so unlike
// gGlobalFogIntensity they reach the shaders that draw the world.
uniform float4 FogDistanceCurve < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 200; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.02; ui_label = "Fog distance curve";
    ui_tooltip = "The first four of the twenty floats behind the fog falloff: where fog starts, how fast it thickens, and how high it climbs. Drag one at a time."; ui_category = "Reflections and fog"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float3 FogColourEast < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 224; bv_op = "mul";
    ui_type = "color"; ui_label = "Fog colour away from the sun";
    ui_tooltip = "The game blends three fog colours by which way you face. This is the one opposite the sun, so it sets the colour of haze in the shade."; ui_category = "Reflections and fog"; > = float3(1.0, 1.0, 1.0);
uniform float3 FogColourNorth < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 228; bv_op = "mul";
    ui_type = "color"; ui_label = "Fog colour across the sun";
    ui_tooltip = "The sideways fog colour, between the sun facing and away facing ones."; ui_category = "Reflections and fog"; > = float3(1.0, 1.0, 1.0);
uniform float3 FogColourMoon < bv = "patch"; bv_slot = 3; bv_size = 960; bv_offset = 232; bv_op = "mul";
    ui_type = "color"; ui_label = "Night fog colour";
    ui_tooltip = "The moonlit fog colour. This is the one that decides whether night haze reads blue or grey."; ui_category = "Reflections and fog"; > = float3(1.0, 1.0, 1.0);
uniform float4 GlobalWetness < bv = "patch"; bv_slot = 5; bv_size = 128; bv_offset = 12; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Global wetness and baked light";
    ui_tooltip = "gDynamicBakesAndWetness, read by the world shaders. This is the wetness the weather drives, above the per material one in the roads section."; ui_category = "Roads and surfaces"; > = float4(1.0, 1.0, 1.0, 1.0);

// ---- More water, water_globals b4 --------------------------------------------------------------
uniform float4 WaterFlow < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 8; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Water flow";
    ui_tooltip = "gFlowParams2, read by 5 water shaders. How the surface drifts, which reads as current on rivers and swell on the sea."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);
uniform float4 WaterSpeed < bv = "patch"; bv_slot = 4; bv_size = 272; bv_offset = 20; bv_op = "mul";
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05; ui_label = "Water animation speed";
    ui_tooltip = "gScaledTime, the clock the water animation runs on, read by 6 shaders. Below 1 slows the whole surface down."; ui_category = "Water"; > = float4(1.0, 1.0, 1.0, 1.0);

float4 PS_Nop(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target { if (pos.x >= 0.0) discard; return 0.0; }

technique BlancoVision_Control
<
    ui_label = "BlancoVision addon control";
    ui_tooltip = "Sliders read by BlancoVision.addon. Draws nothing.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Nop; }
}
