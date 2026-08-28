# GLPLUS — (Reasonably) match 3D output between the gl_compatibility and Forward+ renderers

> **LLM assistance disclosure:** this project was developed with the assistance
> of an LLM (DeepSeek V4 Pro). All changes have been reviewed and tested by the
> fork creator.

## Project description

- A Godot 4.7.2-stable fork
- It aims **to close the visual gap of 3D rendering output** between
  gl_compatibility and Forward+ (including tonemapping)
- Tested targets: web export, native player and editor (Linux)
- **Full binary compatibility:** you can edit your 3D project in the stock
  4.7.2-stable editor and it will look the same, e.g. when using the web export
  for testing/debugging
- It uses GL extensions supported by ~98% of browsers
  (source: https://web3dsurvey.com/webgl)
- Compatibility SSAO reasonably matches Forward+ SSAO and honors most of the
  full SSAO properties
- No new GL features or node support: it only matches the shading features
  shared between GL and Forward+
- **Experimental:** more shading feature tests are needed to verify correctness

## Why?

The Compatibility (gl_compatibility) renderer uses low dynamic range (LDR)
buffers and non-linear math for shading, making both renderers look very
different depending on which shading features are used in the materials and
environment setup — making some features worse, such as tonemapping.

## What was modified?
- **HDR intermediate buffer** — the 3D scene renders to `GL_RGBA16F` (or
  `RGB10_A2`/`RGBA8` fallback) instead of an 8-bit sRGB buffer; values above 1.0
  survive until tonemapping.
- **Linear lighting end-to-end** — the scene shader lights in linear space and
  writes raw linear color; exposure + tonemap + sRGB conversion happen **once**,
  in `post.glsl`.
- **Correct sky color space** — sky-material `source_color` uniforms are
  converted sRGB→linear at upload (like Forward+), so sky, sky ambient, and
  reflections match Forward+ for any `energy_multiplier` value.
- **HDR sky radiance / reflection probes** — radiance cubemaps are stored as
  `RGBA16F` (when supported) and sampled as linear; `IBL_exposure_normalization`
  is applied like Forward+.
- **Linear glow** — glow is computed and blended in linear HDR with real `>1.0`
  thresholds (no `luminance_multiplier` hack).
- **Forward+-style SSAO** — an ASSAO-style gather runs in its own half-resolution
  pass after the depth prepass, with view-space obscurance (normals reconstructed
  from depth), a packed depth-edge channel and an edge-aware blur. The AO is
  applied to **ambient light only** in the scene shader (direct lights and the
  sky are not darkened), and `ssao_light_affect`, `ssao_ao_channel_affect`,
  `ssao_power` and `ssao_sharpness` work like Forward+.
- **Exact sRGB curves** — `tonemap_inc.glsl` uses the exact piecewise sRGB
  transfer functions instead of approximations.

## WebGL extensions used (compatibility / device support)

These are the extra WebGL2 extensions this change relies on for the HDR path.
On devices that lack them, the renderer automatically falls back to an LDR
(`RGB10_A2`/`RGBA8`) buffer with the same linear pipeline.

| Extension | Purpose | Browser / device support |
|-----------|---------|--------------------------|
| `EXT_color_buffer_half_float` | Render to `RGBA16F` (half-float) color buffers | Chrome/Edge, Firefox, Safari 15+, most mobile GPUs |
| `EXT_color_buffer_float` | Render to `RGBA32F`/`RGBA16F`/`R11G11B10F` buffers | Chrome/Edge, Firefox (newer), Safari (newer) |
| `EXT_float_blend` | Blending on float render targets (transparents, additive lights, glow) | Chrome/Edge, Firefox, Safari 15+ |

All three are enabled in `platform/web/display_server_web.cpp` and detected in
`drivers/gles3/storage/config.cpp`; `hdr_render_supported` requires
`(color_buffer_float OR color_buffer_half_float) AND float_blend`.

## How it worked before

The whole color pipeline was non-linear and clamped to `[0,1]`:

```
sample texture -> srgb_to_linear -> light (linear)
-> *exposure -> tonemap -> linear_to_srgb -> write to RGB10_A2/RGBA8  ([0,1] clamp)
-> (glow/SSAO/BCS on) post.glsl: srgb_to_linear -> tonemap -> linear_to_srgb  (2nd round-trip)
```

Problems:

1. **Tonemap + sRGB happened inline in the material pass**, before the `[0,1]`
   UNORM buffer clamp. Any energy above 1.0 was lost before the tonemapper could
   compress it -> flat, clipped highlights.
2. **Two color-space round-trips** (linear -> sRGB -> linear -> tonemap -> sRGB)
   when post effects were enabled, shifting the tonemap curve's operating point.
3. **`luminance_multiplier = 0.25` "fake HDR" hack** (only with glow + 10-bit
   buffer) squeezed `[0,4]` into `[0,1]`, further reducing contrast.
4. **Cheap sRGB approximations** in `tonemap_inc.glsl` instead of the exact curve.

## How it works now

```
sample texture -> srgb_to_linear -> light (linear)
-> write LINEAR to RGBA16F intermediate buffer  (unbounded, no tonemap, no clamp)
-> glow/SSAO (linear HDR)
-> ONE post pass: *exposure -> tonemap -> linear_to_srgb -> LDR viewport target
-> blit to screen (unchanged)
```

- The scene and sky shaders output **raw linear** color (no exposure/tonemap/sRGB).
- The 3D scene always renders through an **intermediate buffer** that is
  `GL_RGBA16F` when the device supports it, otherwise `RGB10_A2`/`RGBA8` (the
  *same* linear pipeline, only the buffer precision differs).
- `post.glsl` is the **single** place that applies exposure, tonemapping, and
  linear->sRGB conversion.

## SSAO pipeline

The stock Compatibility SSAO (a depth-only S4AO computed inside the post pass)
was replaced by a Forward+-style pipeline:

```
depth prepass (forced when SSAO is on)
  -> half-res RG8 gather:  R = occlusion, G = packed depth edges
  -> edge-aware cross blur (ASS AO MODE_SMART port)
  -> scene shader: ao = min(material_ao, ssao); ambient *= ao
     (direct light only when ssao_light_affect > 0; sky never darkened)
```

Gather details (matching Forward+ semantics):

- View position and normal are reconstructed from the depth buffer (integer
  texel neighborhood, phase-consistent on any canvas size).
- Obscurance = `max(NdotD - ssao_horizon, 0)` weighted by a quadratic world
  falloff, per-tap weights from the ASS AO pattern and halo reduction.
- Tap counts: VERY_LOW 3, LOW 5, MED/HIGH/ULTRA 12 (mirrored ×2); the adaptive
  quality level is not ported.
- ASS AO detail term (4 neighbor obscurances, edge-weighted) for crevices.
- Shaping: `occlusion = pow(1 - min(intensity * avg, 0.98), ssao_power)`.
- The radius uses Forward+'s world-unit semantics (converted to screen space
  per pixel); the sampling disk uses the 85% lookup-radius factor.
- `ssao_detail` and `ssao_horizon` are honored but stay hidden in the GL
  inspector; `ssao_power` and `ssao_sharpness` are visible.

### SSAO performance cost vs the original GL SSAO

| (MED quality, 1080p) | **Original GL SSAO** (post-pass S4AO) | **New SSAO** |
|---|---|---|
| Where AO runs | Inside the post pass, applied to the whole framebuffer | Own half-res passes **before** shading, applied in the scene shader to **ambient only** |
| Extra fullscreen passes | 0 (inside post) | **+2** (gather + edge-aware blur, both half-res) |
| Depth taps per AO pixel | 12 — at **full resolution** | 24 + ~16 normal/edge/detail fetches — at **half resolution** (¼ pixels) |
| Total depth fetches per frame | ≈ 12 × full-res pixels | ≈ 10 × full-res pixels |
| Geometry draw calls | +0 | +0 with the default depth prepass; **+1 depth-only draw per opaque object** if a project disabled it |
| RAM | 0 extra | **~3 MB** at 1080p (3 half-res RG8 buffers + 3 FBOs; ~1.8 MB/buffer at 1440p, ~4.2 MB/buffer at 4K → ~12.5 MB total) |
| MSAA 3D | none | +1 depth resolve blit before the gather |
| What it darkens | whole image (direct, reflections, sky) | ambient only (Forward+ semantics) |
| Output quality | raw, binary-ish contact halos | edge-aware blurred, graded falloff |

Takeaways: the sampling math is roughly the same or slightly cheaper in fetch
bandwidth (half-res); the cost is 2 extra half-res passes, a forced depth
prepass and ~3 MB of buffers. Scene draw calls only grow in prepass-disabled
projects. The structure is the same cost class as Forward+.

## Capability detection (auto HDR + fallback)

In `drivers/gles3/storage/config.cpp`:

- `EXT_color_buffer_half_float` -> `half_float_render_target_supported`
- `EXT_color_buffer_float`     -> `float_texture_supported` (already existed)
- `EXT_float_blend`            -> `float_blend_supported`
- `hdr_render_supported = (float_texture_supported || half_float_render_target_supported) && float_blend_supported`

Web builds enable the extensions in `platform/web/display_server_web.cpp`.
On desktop GLES the flags are forced true.

The fallback is **not a legacy path** — it is the same shader pipeline; only the
intermediate buffer format changes:

| Mode     | Intermediate buffer | Behavior |
|----------|--------------------|----------|
| HDR      | `GL_RGBA16F`        | full linear range |
| Fallback | `RGB10_A2`/`RGBA8`  | identical pipeline, values >1.0 clamp |

### Gotcha: `RGBA16F` must use `GL_HALF_FLOAT`

The intermediate buffer is created with `GL_RGBA16F` + `GL_HALF_FLOAT` type.
Desktop GL drivers are lenient and silently convert, but WebGL2/ANGLE strictly
validates the `format`/`type` pair — `(GL_RGBA, GL_FLOAT)` only maps to
`RGBA32F`, so `RGBA16F` + `GL_FLOAT` fails the framebuffer check and the renderer
silently falls back to LDR (clipped -> overexposed/desaturated). Fixed in
`render_scene_buffers_gles3.cpp`.

## Files changed

- `drivers/gles3/storage/config.{h,cpp}` — capability flags
- `drivers/gles3/storage/render_scene_buffers_gles3.{h,cpp}` — HDR intermediate buffer (`RGBA16F` + `GL_HALF_FLOAT`), force internal buffer, remove dead plumbing; half-res RG8 SSAO gather buffer + blur ping-pong buffers
- `drivers/gles3/rasterizer_scene_gles3.{h,cpp}` — remove inline tonemap flag/0.25 hack/clear-color linearization; fog sky shader `clear_color : source_color`; SSAO pass after the depth prepass (prepass forced when SSAO is on, MSAA depth resolved first); `use_ssao`/`ssao_light_affect`/`ssao_ao_channel_affect` scene UBO fields; world-unit radius conversion and the `SS_AO_STRENGTH_CALIBRATION` factor
- `drivers/gles3/storage/material_storage.{h,cpp}` — sky-material `source_color` uniforms converted sRGB→linear at upload (matches Forward+)
- `drivers/gles3/shaders/scene.glsl` — output linear only; IBL/reflection/ambient sampled linear (no `srgb_to_linear` on radiance/probe maps); `IBL_exposure_normalization` applied to radiance/ambient; SSAO sampled from a half-res buffer and applied to ambient only (`ao = min(ao, ssao)`, direct light per `ssao_light_affect`)
- `drivers/gles3/shaders/sky.glsl` — output linear only (no `srgb_to_linear`, colors are already linear at upload)
- `drivers/gles3/shaders/effects/post.glsl` — single exposure+tonemap+sRGB pass (SSAO removed from post)
- `drivers/gles3/shaders/effects/ssao.glsl` — new SSAO gather pass (Forward+-style view-space obscurance, ASSAO tap pattern, detail term, packed depth edges)
- `drivers/gles3/shaders/effects/ssao_blur.glsl` — new edge-aware cross blur for the AO buffer (ASS AO MODE_SMART port)
- `drivers/gles3/shaders/s4ao_disk_inc.glsl` — new shared tap-gather include (replaces the deleted `s4ao_micro_inc.glsl` / `s4ao_inc.glsl` / `s4ao_mega_inc.glsl`)
- `drivers/gles3/effects/ssao.{h,cpp}` — new SSAO effect (gather + blur, screen-triangle passes)
- `drivers/gles3/effects/post_effects.{h,cpp}` — drop SSAO plumbing
- `drivers/gles3/shaders/effects/SCsub` — include dependencies also cover `../*_inc.glsl` (edits to the s4ao includes now regenerate the shader headers)
- `scene/resources/environment.cpp` — editor-only: `ssao_light_affect`/`ssao_ao_channel_affect`/`ssao_power`/`ssao_sharpness` visible in Compatibility (no API change)
- `drivers/gles3/shaders/effects/glow.glsl` — linear HDR glow (drop luminance_multiplier)
- `drivers/gles3/shaders/effects/cubemap_filter.glsl` — radiance/probe filtering in linear space (helpers retained, unused)
- `drivers/gles3/shaders/effects/copy.glsl` — radiance panorama bake reads linear
- `drivers/gles3/shaders/tonemap_inc.glsl` — exact sRGB functions
- `drivers/gles3/rasterizer_scene_gles3.cpp` — sky radiance cubemaps stored `RGBA16F` (HDR) when supported
- `drivers/gles3/storage/light_storage.cpp` — reflection atlas `color`/`radiance` cubemaps stored `RGBA16F` (HDR) when supported
- `drivers/gles3/effects/glow.{h,cpp}`, `post_effects.{h,cpp}` — drop luminance_multiplier plumbing
- `platform/web/display_server_web.cpp` — enable float render target extensions

## Compatibility

Binary/API compatibility with the Godot scripting and extension API is fully
preserved. All changes are internal to `drivers/gles3/`:

- No ClassDB/`_bind_methods`/`GDVIRTUAL`/`BIND_*` changes.
- No public `RenderingServer`/`RenderingDevice` methods touched
  (`viewport_set_use_hdr` etc. and their `texture_storage.cpp` implementation are untouched).
- No virtual overrides removed (only GLES3-specific non-virtual helpers).
- The only external consumers of a gles3 header (OpenXR/WebXR modules, via
  `texture_storage.h`) are unaffected — that file is unchanged.

## Known follow-ups (not yet done)

1. **`ENV_BG_CANVAS`:** the canvas-as-background copy (`copy_screen`/
   `copy_with_exposure`) writes sRGB canvas data into the now-linear internal
   buffer without converting.
2. **SSAO dark-end parity:** the depth-mip chain of the Forward+ gather is not
   ported, so GL still accumulates slightly more occlusion and its darkest
   areas clamp earlier than Forward+'s. A static strength calibration factor
   compensates for this: `SS_AO_STRENGTH_CALIBRATION = 0.5f` in
   `rasterizer_scene_gles3.cpp` (tune against Forward+ color picks). A future
   step can port the depth mips (and the normal buffer, since GL reconstructs
   normals from depth) to remove the factor.
3. **SSAO quality levels:** the adaptive (ULTRA) gather is not ported (ULTRA
   uses the 12-tap preset); `ssao_detail` and `ssao_horizon` are honored but
   hidden in the GL inspector.
4. **Temporary diagnostics:** the one-shot `print_line` logs added for debugging
   (`config.cpp`, `render_scene_buffers_gles3.cpp`, `rasterizer_scene_gles3.cpp`)
   are kept on purpose while this is an experimental branch; remove them before
   upstreaming.

## GLES3 shader gotchas (WebGL2 / ANGLE)

Desktop GL drivers (NVIDIA etc.) are lenient about everything below, but ANGLE
(WebGL2) enforces them. Every GLES3 shader change must be verified on WebGL2:

- **No global-scope `const` arrays** — ANGLE rejects brace initializers and
  WebGL2 restricts dynamic indexing of const arrays. Use a plain function with
  an `if`/`else if` chain per entry instead.
- **No nested `#include`** — the shader preprocessor only inlines an included
  file the first time; later references are dropped silently. Keep includes
  single-level.
- **No textual `#define` reliance** — `#define`s are consumed but not
  substituted into the source. Use `const int` values and `#if defined(...)`
  conditionals instead.
- **Functions must be defined before use** (GLSL ES rule; NVIDIA tolerates
  forward references, ANGLE does not).
- **No trailing comments on `uniform` lines** — the uniform parser scans the
  rest of the line and turns comment words into bogus uniform names.
- **Depth textures are `GL_NEAREST`-only** — setting `GL_LINEAR` filters on a
  depth texture makes WebGL2 read zeros (incomplete texture), killing the AO
  entirely.

## Verification

Every change is validated by comparing **against Forward+ (native Vulkan
player/editor) as ground truth**, on multiple test scenes (sky-only ambient,
sky + glow, sky + SSAO, with and without `ProceduralSkyMaterial.energy_multiplier`)
with a **Linear** tonemapper. The Compatibility renderer now matches Forward+
output on:

- **Linux desktop GL** and **WebGL2 (Chrome)**.
- Sky background colors, sky ambient/reflection IBL on materials, and the
  `energy_multiplier` behavior (sky material colors are linear before the energy
  multiply, exactly like Forward+).
- SSAO: the AO shape and falloff match Forward+ (cavities darken, flat surfaces
  and the sky stay clean), with the strength calibrated through
  `SS_AO_STRENGTH_CALIBRATION` (see Known follow-ups).

An earlier "web overexposed vs Linux" report was a stale-build comparison: the
Linux player was stock (`bfae01d184`) while the web build had the HDR changes
(`05102de5fb`). With both built from the same commit the output matches.

## Usage note

HDR + a **Linear** tonemapper (`tonemapper=0`, the default) clips any value
`>1.0` to white — that's what looks "overexposed/desaturated" on bright scenes.
This is correct HDR behavior (Forward+ does the same); to compress highlights,
set the WorldEnvironment tonemapper to **ACES**, **Filmic**, or **AgX**.
