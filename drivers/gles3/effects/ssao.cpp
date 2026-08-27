/**************************************************************************/
/*  ssao.cpp                                                              */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "ssao.h"

#ifdef GLES3_ENABLED

#include "drivers/gles3/storage/texture_storage.h"

using namespace GLES3;

SSao *SSao::singleton = nullptr;

SSao *SSao::get_singleton() {
	return singleton;
}

SSao::SSao() {
	singleton = this;

	ssao.shader.initialize();
	ssao.shader_version = ssao.shader.version_create();

	blur_shader.shader.initialize();
	blur_shader.shader_version = blur_shader.shader.version_create();

	{ // Screen Triangle.
		glGenBuffers(1, &screen_triangle);
		glBindBuffer(GL_ARRAY_BUFFER, screen_triangle);

		const float qv[6] = {
			-1.0f,
			-1.0f,
			3.0f,
			-1.0f,
			-1.0f,
			3.0f,
		};

		glBufferData(GL_ARRAY_BUFFER, sizeof(float) * 6, qv, GL_STATIC_DRAW);
		glBindBuffer(GL_ARRAY_BUFFER, 0); //unbind

		glGenVertexArrays(1, &screen_triangle_array);
		glBindVertexArray(screen_triangle_array);
		glBindBuffer(GL_ARRAY_BUFFER, screen_triangle);
		glVertexAttribPointer(RSE::ARRAY_VERTEX, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 2, nullptr);
		glEnableVertexAttribArray(RSE::ARRAY_VERTEX);
		glBindVertexArray(0);
		glBindBuffer(GL_ARRAY_BUFFER, 0); //unbind
	}
}

SSao::~SSao() {
	glDeleteBuffers(1, &screen_triangle);
	glDeleteVertexArrays(1, &screen_triangle_array);

	ssao.shader.version_free(ssao.shader_version);
	blur_shader.shader.version_free(blur_shader.shader_version);

	singleton = nullptr;
}

void SSao::_draw_screen_triangle() {
	glBindVertexArray(screen_triangle_array);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glBindVertexArray(0);
}

void SSao::generate_ssao(GLuint p_source_depth, GLuint p_dest_framebuffer, Size2i p_size, int p_quality_level, float p_strength, float p_radius, Size2i p_source_size, float p_view_mul_x, float p_view_mul_y, float p_view_near, float p_world_radius, float p_flip_y, float p_power, float p_detail, float p_horizon, uint32_t p_view, bool p_use_multiview) {
	ERR_FAIL_COND(p_source_depth == 0);
	ERR_FAIL_COND(p_dest_framebuffer == 0);

	glDisable(GL_DEPTH_TEST);
	glDepthMask(GL_FALSE);
	glDisable(GL_BLEND);

	glBindFramebuffer(GL_FRAMEBUFFER, p_dest_framebuffer);
	glViewport(0, 0, p_size.x, p_size.y);

	uint64_t specialization = p_use_multiview ? SsaoShaderGLES3::USE_MULTIVIEW : 0;
	if (p_quality_level == RSE::ENV_SSAO_QUALITY_VERY_LOW) {
		specialization |= SsaoShaderGLES3::USE_SSAO_ABYSS;
	} else if (p_quality_level == RSE::ENV_SSAO_QUALITY_LOW) {
		specialization |= SsaoShaderGLES3::USE_SSAO_LOW;
	} else if (p_quality_level == RSE::ENV_SSAO_QUALITY_HIGH) {
		specialization |= SsaoShaderGLES3::USE_SSAO_HIGH;
	} else if (p_quality_level == RSE::ENV_SSAO_QUALITY_ULTRA) {
		specialization |= SsaoShaderGLES3::USE_SSAO_MEGA;
	} else {
		specialization |= SsaoShaderGLES3::USE_SSAO_MED;
	}

	bool success = ssao.shader.version_bind_shader(ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	if (!success) {
		static bool logged_ssao_shader_fail = false;
		if (!logged_ssao_shader_fail) {
			logged_ssao_shader_fail = true;
			print_line(vformat("SSAO PASS: SHADER BIND FAILED view=%d multiview=%d", p_view, (int)p_use_multiview));
		}
		glEnable(GL_DEPTH_TEST);
		glDepthMask(GL_TRUE);
		glBindFramebuffer(GL_FRAMEBUFFER, GLES3::TextureStorage::system_fbo);
		return;
	}

	static bool logged_ssao_pass = false;
	if (!logged_ssao_pass) {
		logged_ssao_pass = true;
		print_line(vformat("SSAO PASS: view=%d multiview=%d size=%dx%d quality=%d strength=%f radius=%f", p_view, (int)p_use_multiview, p_size.x, p_size.y, p_quality_level, p_strength, p_radius));
	}

	GLenum texture_target = p_use_multiview ? GL_TEXTURE_2D_ARRAY : GL_TEXTURE_2D;
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(texture_target, p_source_depth);
	// Depth textures only support GL_NEAREST filtering (GL_LINEAR makes WebGL2
	// read zeros, killing the AO entirely).
	glTexParameteri(texture_target, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(texture_target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);

	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_INTENSITY, p_strength, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_RADIUS_FRAC, p_radius, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_PRN_UV, // This converts the UV coordinate into a pseudo-random number.
			p_source_size.x * 1.087f * ((1.0f + sqrt(5.0f)) / 2.0f),
			p_source_size.y * 1.087f * ((9.0f + sqrt(221.0f)) / 10.0f),
			ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_VIEW_MUL, p_view_mul_x, p_view_mul_y, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_VIEW_NEAR, p_view_near, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_WORLD_RADIUS, p_world_radius, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_PIXEL_SIZE, 1.0f / p_source_size.x, 1.0f / p_source_size.y, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_VIEW_SIZE, float(p_source_size.x), float(p_source_size.y), ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_FLIP_Y, p_flip_y, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_POWER, p_power, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_DETAIL_INTENSITY, p_detail, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	ssao.shader.version_set_uniform(SsaoShaderGLES3::SSAO_HORIZON, p_horizon, ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	if (p_use_multiview) {
		ssao.shader.version_set_uniform(SsaoShaderGLES3::VIEW, float(p_view), ssao.shader_version, SsaoShaderGLES3::MODE_DEFAULT, specialization);
	}

	_draw_screen_triangle();

	static bool logged_ssao_out = false;
	if (!logged_ssao_out) {
		logged_ssao_out = true;
		GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		uint8_t ao_samples[5] = { 0, 0, 0, 0, 0 };
		glReadPixels(p_size.x / 2, p_size.y / 2, 1, 1, GL_RG, GL_UNSIGNED_BYTE, &ao_samples[0]);
		glReadPixels(p_size.x / 4, p_size.y / 2, 1, 1, GL_RG, GL_UNSIGNED_BYTE, &ao_samples[1]);
		glReadPixels(p_size.x * 3 / 4, p_size.y / 2, 1, 1, GL_RG, GL_UNSIGNED_BYTE, &ao_samples[2]);
		glReadPixels(p_size.x / 2, p_size.y / 4, 1, 1, GL_RG, GL_UNSIGNED_BYTE, &ao_samples[3]);
		glReadPixels(p_size.x / 2, p_size.y * 3 / 4, 1, 1, GL_RG, GL_UNSIGNED_BYTE, &ao_samples[4]);
		print_line(vformat("SSAO OUT: fbo_status=0x%04x center=%d q25=%d q75=%d lower=%d upper=%d", fbo_status, ao_samples[0], ao_samples[1], ao_samples[2], ao_samples[3], ao_samples[4]));
	}

	glActiveTexture(GL_TEXTURE0);
	glBindTexture(texture_target, 0);

	glEnable(GL_DEPTH_TEST);
	glDepthMask(GL_TRUE);
	glUseProgram(0);
	glBindFramebuffer(GL_FRAMEBUFFER, GLES3::TextureStorage::system_fbo);
}

void SSao::blur(GLuint p_source, GLuint p_dest_framebuffer, Size2i p_size, float p_sharpness, uint32_t p_view, bool p_use_multiview) {
	ERR_FAIL_COND(p_source == 0);
	ERR_FAIL_COND(p_dest_framebuffer == 0);

	glDisable(GL_DEPTH_TEST);
	glDepthMask(GL_FALSE);
	glDisable(GL_BLEND);

	glBindFramebuffer(GL_FRAMEBUFFER, p_dest_framebuffer);
	glViewport(0, 0, p_size.x, p_size.y);

	uint64_t specialization = p_use_multiview ? SsaoBlurShaderGLES3::USE_MULTIVIEW : 0;
	SsaoBlurShaderGLES3::ShaderVariant mode = SsaoBlurShaderGLES3::MODE_DEFAULT;

	bool success = blur_shader.shader.version_bind_shader(blur_shader.shader_version, mode, specialization);
	if (!success) {
		static bool logged_ssao_blur_fail = false;
		if (!logged_ssao_blur_fail) {
			logged_ssao_blur_fail = true;
			print_line("SSAO BLUR: SHADER BIND FAILED");
		}
		glEnable(GL_DEPTH_TEST);
		glDepthMask(GL_TRUE);
		glBindFramebuffer(GL_FRAMEBUFFER, GLES3::TextureStorage::system_fbo);
		return;
	}

	GLenum texture_target = p_use_multiview ? GL_TEXTURE_2D_ARRAY : GL_TEXTURE_2D;
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(texture_target, p_source);
	glTexParameteri(texture_target, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(texture_target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);

	blur_shader.shader.version_set_uniform(SsaoBlurShaderGLES3::EDGE_SHARPNESS, 1.0f - p_sharpness, blur_shader.shader_version, mode, specialization);
	if (p_use_multiview) {
		blur_shader.shader.version_set_uniform(SsaoBlurShaderGLES3::VIEW, float(p_view), blur_shader.shader_version, mode, specialization);
	}

	_draw_screen_triangle();

	glActiveTexture(GL_TEXTURE0);
	glBindTexture(texture_target, 0);

	glEnable(GL_DEPTH_TEST);
	glDepthMask(GL_TRUE);
	glUseProgram(0);
	glBindFramebuffer(GL_FRAMEBUFFER, GLES3::TextureStorage::system_fbo);
}

#endif // GLES3_ENABLED
