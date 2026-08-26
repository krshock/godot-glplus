# WEBGLPLUS — Linear HDR shading in the Compatibility (GLES3 / WebGL2) renderer

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

## Goal

Make Godot's Compatibility renderer (the one used by the WebGL2 export) shade in
**linear HDR** and tonemap **once at the end**, the way the Vulkan/Forward+
renderer and Unity's WebGL pipeline do. This fixes the washed-out/desaturated
colors and clipped highlights the old pipeline produced.

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
- Glow is computed and blended in **linear HDR** space (real `>1.0` thresholds).
- `tonemap_inc.glsl` now uses the **exact** piecewise sRGB transfer functions.

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
- `drivers/gles3/storage/render_scene_buffers_gles3.{h,cpp}` — HDR intermediate buffer (`RGBA16F` + `GL_HALF_FLOAT`), force internal buffer, remove dead plumbing
- `drivers/gles3/rasterizer_scene_gles3.{h,cpp}` — remove inline tonemap flag/0.25 hack/clear-color linearization
- `drivers/gles3/shaders/scene.glsl` — output linear only; IBL/reflection/ambient sampled linear (no `srgb_to_linear` on radiance/probe maps)
- `drivers/gles3/shaders/sky.glsl` — output linear only
- `drivers/gles3/shaders/effects/post.glsl` — single exposure+tonemap+sRGB pass
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
2. **Temporary diagnostics:** the one-shot `print_line` logs added for debugging
   (`config.cpp`, `render_scene_buffers_gles3.cpp`, `rasterizer_scene_gles3.cpp`)
   should be removed once work is done.

## Verification

Working correctly on **Linux desktop GL** and **WebGL2 (Chrome)**. The earlier
"web overexposed vs Linux" report was a stale-build comparison: the Linux player
was stock (`bfae01d184`) while the web build had the HDR changes (`05102de5fb`).
With both built from the same commit the output matches.

## Usage note

HDR + a **Linear** tonemapper (`tonemapper=0`, the default) clips any value
`>1.0` to white — that's what looks "overexposed/desaturated" on bright scenes.
This is correct HDR behavior (Forward+ does the same); to compress highlights,
set the WorldEnvironment tonemapper to **ACES**, **Filmic**, or **AgX**.
