/* clang-format off */
#[modes]
mode_default =

#[specializations]

USE_MULTIVIEW = false
USE_SSAO_ABYSS = false
USE_SSAO_LOW = false
USE_SSAO_MED = false
USE_SSAO_HIGH = false
USE_SSAO_MEGA = false

#[vertex]
layout(location = 0) in vec2 vertex_attrib;

/* clang-format on */

out vec2 uv_interp;

void main() {
	uv_interp = vertex_attrib * 0.5 + 0.5;
	gl_Position = vec4(vertex_attrib, 1.0, 1.0);
}

/* clang-format off */
#[fragment]
/* clang-format on */

// S4AO computed in its own pass. The result is stored in a half-resolution
// RG8 buffer and applied to ambient light only in the scene shader, matching
// the Forward+ renderer behavior.

#if defined(USE_SSAO_ABYSS) || defined(USE_SSAO_LOW) || defined(USE_SSAO_MED) || defined(USE_SSAO_HIGH) || defined(USE_SSAO_MEGA)
#define USE_SOME_SSAO
uniform float ssao_intensity;
uniform float ssao_radius_frac;
uniform vec2 ssao_prn_UV;
// View-space reconstruction parameters (matching the Forward+ SSAO obscurance).
// ssao_view_mul is 1 / proj[0][0], 1 / proj[1][1]; the rest as named below.
uniform vec2 ssao_view_mul;
uniform float ssao_view_near;
uniform float ssao_world_radius;
uniform vec2 ssao_pixel_size;
uniform float ssao_flip_y;
// Forward+ occlusion shaping: power curve and detail accumulation.
uniform float ssao_power;
uniform float ssao_detail_intensity;
uniform float ssao_horizon;
// Full-resolution depth buffer size (the SSAO pass runs at half resolution).
uniform vec2 ssao_view_size;
#ifdef USE_MULTIVIEW
uniform float view;
uniform sampler2DArray depth_buffer_array; // texunit:0
#else
uniform sampler2D depth_buffer; // texunit:0
#endif

float ssao_depth_fetch(vec2 p_uv) {
#ifdef USE_MULTIVIEW
	return texture(depth_buffer_array, vec3(p_uv, view)).r;
#else
	return texture(depth_buffer, p_uv).r;
#endif
}

// Integer texel-based fetches: the normal and edge neighborhood must always be
// a consistent 3x3 texel block, otherwise odd canvas sizes make the half-res
// grid land between full-res texels and produce row-banded artifacts.
ivec2 ssao_texel_coord(vec2 p_uv) {
	ivec2 size = ivec2(ssao_view_size);
	return min(max(ivec2(floor(p_uv * ssao_view_size)), ivec2(0)), size - ivec2(1));
}

vec2 ssao_texel_uv(ivec2 p_coord) {
	return (vec2(p_coord) + vec2(0.5)) / ssao_view_size;
}

float ssao_texel_fetch(ivec2 p_coord) {
	ivec2 size = ivec2(ssao_view_size);
	p_coord = min(max(p_coord, ivec2(0)), size - ivec2(1));
#ifdef USE_MULTIVIEW
	return texelFetch(depth_buffer_array, ivec3(p_coord, int(view)), 0).r;
#else
	return texelFetch(depth_buffer, p_coord, 0).r;
#endif
}

// Reconstruct the view-space position of a pixel from its reverse-Z depth.
vec3 ssao_view_position(vec2 p_uv, float p_depth) {
	// Reverse-Z: depth ~= z_near / view_distance.
	float view_z = ssao_view_near / max(p_depth, 1e-4);
	vec2 ndc = (p_uv * 2.0 - 1.0);
	return vec3(ndc * ssao_view_mul * vec2(view_z, view_z * ssao_flip_y), -view_z);
}

// Reconstruct the view-space normal from the depth neighborhood (pointing
// away from the camera, so occluders inside cavities produce a positive NdotD).
vec3 ssao_view_normal(ivec2 p_center) {
	float d_left = ssao_texel_fetch(p_center + ivec2(-1, 0));
	float d_right = ssao_texel_fetch(p_center + ivec2(1, 0));
	float d_down = ssao_texel_fetch(p_center + ivec2(0, -1));
	float d_up = ssao_texel_fetch(p_center + ivec2(0, 1));
	vec3 p_left = ssao_view_position(ssao_texel_uv(p_center + ivec2(-1, 0)), d_left);
	vec3 p_right = ssao_view_position(ssao_texel_uv(p_center + ivec2(1, 0)), d_right);
	vec3 p_down = ssao_view_position(ssao_texel_uv(p_center + ivec2(0, -1)), d_down);
	vec3 p_up = ssao_view_position(ssao_texel_uv(p_center + ivec2(0, 1)), d_up);
	return -normalize(cross(p_right - p_left, p_up - p_down));
}

// ASSAO-style slope-sensitive depth edges (0..1 per side, L R T B order).
vec4 ssao_calculate_edges(ivec2 p_center, float p_depth) {
	vec4 neighbor_depth;
	neighbor_depth.x = ssao_texel_fetch(p_center + ivec2(-1, 0));
	neighbor_depth.y = ssao_texel_fetch(p_center + ivec2(1, 0));
	neighbor_depth.z = ssao_texel_fetch(p_center + ivec2(0, -1));
	neighbor_depth.w = ssao_texel_fetch(p_center + ivec2(0, 1));
	float center_z = ssao_view_near / max(p_depth, 1e-4);
	vec4 neighbor_z = ssao_view_near / max(neighbor_depth, 1e-4);
	vec4 edges = neighbor_z - center_z;
	vec4 slope_adjusted = edges + edges.yxwz;
	edges = min(abs(edges), abs(slope_adjusted));
	return clamp(1.3 - edges / (center_z * 0.04), 0.0, 1.0);
}

// ASSAO-style detail accumulation: the obscurance of the four neighboring
// pixels with a tighter falloff, weighted by the depth edges (like Forward+),
// so deep crevices keep accumulating darkness.
float ssao_detail_obscurance(ivec2 p_center, vec3 p_view_normal, vec3 p_center_pos) {
	vec4 additional_obscurance = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		ivec2 offset = ivec2(0);
		if (i == 0) {
			offset = ivec2(-1, 0);
		} else if (i == 1) {
			offset = ivec2(1, 0);
		} else if (i == 2) {
			offset = ivec2(0, -1);
		} else {
			offset = ivec2(0, 1);
		}
		ivec2 neighbor = p_center + offset;
		vec3 sample_pos = ssao_view_position(ssao_texel_uv(neighbor), ssao_texel_fetch(neighbor));
		vec3 delta = sample_pos - p_center_pos;
		float dist_sq = dot(delta, delta);
		// Range reduction of 4.0 (like Forward+), so the detail stays local.
		float falloff = max(0.0, 1.0 - 4.0 * dist_sq / (ssao_world_radius * ssao_world_radius));
		if (falloff <= 0.0) {
			continue;
		}
		float n_dot_d = dot(p_view_normal, delta) / max(sqrt(dist_sq), 1e-4);
		float obscurance = max(n_dot_d - ssao_horizon, 0.0) * falloff;
		if (i == 0) {
			additional_obscurance.x = obscurance;
		} else if (i == 1) {
			additional_obscurance.y = obscurance;
		} else if (i == 2) {
			additional_obscurance.z = obscurance;
		} else {
			additional_obscurance.w = obscurance;
		}
	}
	vec4 edges = ssao_calculate_edges(p_center, ssao_texel_fetch(p_center));
	return ssao_detail_intensity * dot(additional_obscurance, edges);
}

// The same edges packed 2 bits per side into the buffer's green channel
// (mirroring the Forward+ gather output), so the blur can preserve dark
// creases across depth edges.
float ssao_pack_edges(ivec2 p_center, float p_depth) {
	vec4 edges = round(clamp(ssao_calculate_edges(p_center, p_depth), 0.0, 1.0) * 3.05);
	return dot(edges, vec4(64.0 / 255.0, 16.0 / 255.0, 4.0 / 255.0, 1.0 / 255.0));
}

#if defined(USE_SSAO_ABYSS)
// Use the tiny 3-tap version, no halo reduction.
const int ssao_num_taps = 3;
#elif defined(USE_SSAO_LOW)
// Use the 5-tap version with halo reduction.
const int ssao_num_taps = 5;
#else
// Use the 12-tap version with halo reduction.
const int ssao_num_taps = 12;
#endif

// ASSAO-style tap gather (ported from the Forward+ SSAO shader). The nested
// include files were merged into this single-level include because the GLES3
// shader preprocessor does not handle nested includes reliably, and consts are
// used instead of macros because it does not substitute #define textually.
#include "../s4ao_disk_inc.glsl"

#endif

in vec2 uv_interp;

layout(location = 0) out vec4 frag_color;

void main() {
#if defined(USE_SOME_SSAO)
	// The red channel stores the occlusion, the green channel the packed depth
	// edges for the edge-aware blur (like Forward+).
	vec2 result = s4ao(uv_interp);
	frag_color = vec4(result.x, result.y, 0.0, 1.0);
#else
	frag_color = vec4(1.0, 0.0, 0.0, 1.0);
#endif
}
