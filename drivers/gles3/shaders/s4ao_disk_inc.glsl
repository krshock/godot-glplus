// ASSAO-style tap gather, ported from the Forward+ SSAO shader (sample pattern,
// per-tap weights, halo reduction). The caller must define ssao_num_taps
// (const int) before including this file; halo reduction is enabled for every
// quality above VERY_LOW.
// No arrays are used because WebGL2 restricts const-array indexing and ANGLE
// rejects brace initializers.

vec4 ssao_pattern(int p_index) {
	if (p_index == 0) {
		return vec4(0.78488064, 0.56661671, 1.500000, -0.126083);
	} else if (p_index == 1) {
		return vec4(0.26022232, -0.29575172, 1.500000, -1.064030);
	} else if (p_index == 2) {
		return vec4(0.10459357, 0.08372527, 1.110000, -2.730563);
	} else if (p_index == 3) {
		return vec4(-0.68286800, 0.04963045, 1.090000, -0.498827);
	} else if (p_index == 4) {
		return vec4(-0.13570161, -0.64190155, 1.250000, -0.532765);
	} else if (p_index == 5) {
		return vec4(-0.26193795, -0.08205118, 0.670000, -1.783245);
	} else if (p_index == 6) {
		return vec4(-0.61177456, 0.66664219, 0.710000, -0.044234);
	} else if (p_index == 7) {
		return vec4(0.43675563, 0.25119025, 0.610000, -1.167283);
	} else if (p_index == 8) {
		return vec4(0.07884444, 0.86618668, 0.640000, -0.459002);
	} else if (p_index == 9) {
		return vec4(-0.12790935, -0.29869005, 0.600000, -1.729424);
	} else if (p_index == 10) {
		return vec4(-0.04031125, 0.02413622, 0.600000, -4.792042);
	} else if (p_index == 11) {
		return vec4(0.16201244, -0.52851415, 0.790000, -1.067055);
	}
	return vec4(0.0);
}

// Perform the SSAO. Returns occlusion in x and the packed depth edges in y.
vec2 s4ao(vec2 UV) {
	ivec2 center_texel = ssao_texel_coord(UV);
	float depth = ssao_texel_fetch(center_texel);
	vec3 center_pos = ssao_view_position(ssao_texel_uv(center_texel), depth);
	vec3 view_normal = ssao_view_normal(center_texel);
	// The sampling disk uses 85% of the radius (like Forward+'s lookup radius),
	// while the falloff below still uses the full world radius.
	float radius = max(1e-4f, depth * ssao_radius_frac * 0.85f);

	// Random rotation per pixel (equivalent to ASSAO's rotation matrices).
	float r01 = fract(dot(UV, ssao_prn_UV));
	vec2 rcos = vec2(r01 - 0.5f, 2.0f * (r01 - r01 * r01)) * radius; // 180 degrees.
	vec2 rsin = rcos.yx * vec2(-1.0f, 1.0f); // Perpendicular to the random cosine vector.

	float occlusion_sum = 0.0f;
	float weight_sum = 0.0f;

	for (int i = 0; i < ssao_num_taps; i++) {
		vec4 pattern = ssao_pattern(i);
		float weight = pattern.z;
		for (int m = 0; m < 2; m++) {
			vec2 duv = (m == 0) ? (pattern.x * rcos + pattern.y * rsin) : (-pattern.x * rcos - pattern.y * rsin);
			vec3 sample_pos = ssao_view_position(UV + duv, ssao_depth_fetch(UV + duv));
			vec3 delta = sample_pos - center_pos;
			float dist_sq = dot(delta, delta);
			float falloff = max(0.0f, 1.0f - dist_sq / (ssao_world_radius * ssao_world_radius));
			float tap_weight = weight;
#if !defined(USE_SSAO_ABYSS)
			// Halo reduction: reduce the weight of samples behind the surface.
			float reduce = clamp(2.0f - max(0.0f, -delta.z) / max(ssao_world_radius, 1e-4f), 0.0f, 1.0f);
			tap_weight *= 0.6f * reduce + 0.4f;
#endif
			weight_sum += tap_weight;
			if (falloff > 0.0f) {
				float n_dot_d = dot(view_normal, delta) / max(sqrt(dist_sq), 1e-4f);
				occlusion_sum += max(n_dot_d - ssao_horizon, 0.0f) * falloff * tap_weight;
			}
		}
	}

	// ASSAO-style detail accumulation: crevices keep gathering darkness.
	occlusion_sum += ssao_detail_obscurance(center_texel, view_normal, center_pos);

	// Normalize by the weight sum (like Forward+) and apply the occlusion shaping.
	float occlusion = weight_sum > 0.0f ? occlusion_sum / weight_sum : 0.0f;
	occlusion = min(occlusion * ssao_intensity, 0.98f);
	return vec2(pow(clamp(1.0f - occlusion, 0.0f, 1.0f), ssao_power), ssao_pack_edges(center_texel, depth));
}
