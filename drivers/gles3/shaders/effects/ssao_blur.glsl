/* clang-format off */
#[modes]

mode_default =

#[specializations]

USE_MULTIVIEW = false

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

// Edge-aware cross blur for the half-resolution SSAO buffer. This is a port of
// the Forward+ ASSAO blur (MODE_SMART) using explicit texel fetches so it runs
// on ES 3.0 / WebGL2. The occlusion is stored in the red channel and the packed
// depth edges in the green channel; neighbor samples are weighted by those
// edges so dark creases are preserved instead of bleeding.

#ifdef USE_MULTIVIEW
uniform sampler2DArray source_color; // texunit:0
#else
uniform sampler2D source_color; // texunit:0
#endif // USE_MULTIVIEW
uniform float view;
uniform float edge_sharpness;

in vec2 uv_interp;

layout(location = 0) out vec4 frag_color;

vec4 unpack_edges(float p_packed_val) {
	uint packed_val = uint(p_packed_val * 255.5);
	vec4 edges_lrtb;
	edges_lrtb.x = float((packed_val >> 6u) & 0x03u) / 3.0;
	edges_lrtb.y = float((packed_val >> 4u) & 0x03u) / 3.0;
	edges_lrtb.z = float((packed_val >> 2u) & 0x03u) / 3.0;
	edges_lrtb.w = float((packed_val >> 0u) & 0x03u) / 3.0;
	return clamp(edges_lrtb + edge_sharpness, 0.0, 1.0);
}

vec2 fetch_ao(ivec2 p_pos) {
#ifdef USE_MULTIVIEW
	return texelFetch(source_color, ivec3(p_pos, int(view)), 0).xy;
#else
	return texelFetch(source_color, p_pos, 0).xy;
#endif // USE_MULTIVIEW
}

void main() {
	ivec2 pos = ivec2(gl_FragCoord.xy);
	vec2 center = fetch_ao(pos);
	vec4 edges = unpack_edges(center.y);

	// The neighbor's own edge facing back at us must also be open (like Forward+).
	edges.x *= unpack_edges(fetch_ao(pos + ivec2(-1, 0)).y).y;
	edges.y *= unpack_edges(fetch_ao(pos + ivec2(1, 0)).y).x;
	edges.z *= unpack_edges(fetch_ao(pos + ivec2(0, -1)).y).w;
	edges.w *= unpack_edges(fetch_ao(pos + ivec2(0, 1)).y).z;

	float sum_weight = 0.5;
	float sum = center.x * sum_weight;
	sum += fetch_ao(pos + ivec2(-1, 0)).x * edges.x;
	sum_weight += edges.x;
	sum += fetch_ao(pos + ivec2(1, 0)).x * edges.y;
	sum_weight += edges.y;
	sum += fetch_ao(pos + ivec2(0, -1)).x * edges.z;
	sum_weight += edges.z;
	sum += fetch_ao(pos + ivec2(0, 1)).x * edges.w;
	sum_weight += edges.w;

	frag_color = vec4(sum / max(sum_weight, 0.0001), center.y, 0.0, 1.0);
}
