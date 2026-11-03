/*
 *  gl_state_query.h - Typed GL state queries shared by every glGet variant.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_STATE_QUERY_H
#define GL_STATE_QUERY_H
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include "gl_engine.h"

struct GLStateQuery {
    double values[16] = {};
    unsigned count = 1;
    bool normalized = false;
    bool unsigned_integer = false;

    template<class T> bool scalar(T value) {
        values[0] = double(value);
        unsigned_integer = std::is_unsigned<T>::value;
        return true;
    }
    template<class T, size_t N> bool vector(const T (&value)[N], bool norm = false) {
        static_assert(N <= 16, "GL query exceeds result storage");
        count = N; normalized = norm;
        for (unsigned i = 0; i < N; ++i) values[i] = double(value[i]);
        return true;
    }
    bool pair(double a, double b, bool norm = false) {
        count = 2; normalized = norm; values[0] = a; values[1] = b;
        return true;
    }
    int32_t integer(unsigned i) const {
        double value = values[i];
        if (std::isnan(value)) return 0;
        if (unsigned_integer && value > INT32_MAX && value <= UINT32_MAX)
            return int32_t(value - 4294967296.0);
        // GL's signed component conversion (Table 4.7), also used for
        // normal coordinates and normalized depth queries.
        if (normalized) value = (4294967295.0 * value - 1.0) / 2.0;
        if (value >= INT32_MAX) return INT32_MAX;
        if (value <= INT32_MIN) return INT32_MIN;
        return int32_t(normalized ? std::floor(value + 0.5) : std::round(value));
    }
};

static inline int GLStateEvaluatorIndex(uint32_t target)
{
    const unsigned indices[] = {3, 2, 4, 5, 6, 7, 8, 0, 1};
    if (target >= 0x0d90 && target <= 0x0d98) return indices[target - 0x0d90];
    if (target >= 0x0db0 && target <= 0x0db8) return indices[target - 0x0db0];
    return -1;
}

static inline bool GLQueryCapability(const GLContext &c, uint32_t cap, bool &value)
{
    switch (cap) {
    case 0x0b71: value = c.depth_test; return true; // GL_DEPTH_TEST
    case 0x0be2: value = c.blend; return true; // GL_BLEND
    case 0x0b50: value = c.lighting_enabled; return true; // GL_LIGHTING
    case 0x0b60: value = c.fog_enabled; return true; // GL_FOG
    case 0x0c11: value = c.scissor_test; return true; // GL_SCISSOR_TEST
    case 0x0b44: value = c.cull_face_enabled; return true; // GL_CULL_FACE
    case 0x0bc0: value = c.alpha_test; return true; // GL_ALPHA_TEST
    case 0x8458: value = c.color_sum; return true; // GL_COLOR_SUM
    case 0x0ba1: value = c.normalize; return true; // GL_NORMALIZE
    case 0x0b57: value = c.color_material_enabled; return true; // GL_COLOR_MATERIAL
    case 0x0b90: value = c.stencil_test; return true; // GL_STENCIL_TEST
    case 0x8037: value = c.polygon_offset_fill; return true; // GL_POLYGON_OFFSET_FILL
    case 0x2a02: value = c.polygon_offset_line; return true; // GL_POLYGON_OFFSET_LINE
    case 0x2a01: value = c.polygon_offset_point; return true; // GL_POLYGON_OFFSET_POINT
    case 0x0b10: value = c.point_smooth; return true; // GL_POINT_SMOOTH
    case 0x0b20: value = c.line_smooth; return true; // GL_LINE_SMOOTH
    case 0x0b41: value = c.polygon_smooth; return true; // GL_POLYGON_SMOOTH
    case 0x0bd0: value = c.dither; return true; // GL_DITHER
    case 0x0bf2: value = c.color_logic_op; return true; // GL_COLOR_LOGIC_OP
    case 0x0bf1: value = c.color_logic_op; return true; // GL_INDEX_LOGIC_OP
    case 0x0d80: value = c.auto_normal; return true; // GL_AUTO_NORMAL
    case 0x809d: value = c.multisample; return true; // GL_MULTISAMPLE_ARB
    case 0x809e: value = c.sample_alpha_to_coverage; return true; // GL_SAMPLE_ALPHA_TO_COVERAGE_ARB
    case 0x809f: value = c.sample_alpha_to_one; return true; // GL_SAMPLE_ALPHA_TO_ONE_ARB
    case 0x80a0: value = c.sample_coverage; return true; // GL_SAMPLE_COVERAGE_ARB
    case 0x0de0: value = c.tex_units[c.active_texture].enabled_1d; return true; // GL_TEXTURE_1D
    case 0x0de1: value = c.tex_units[c.active_texture].enabled_2d; return true; // GL_TEXTURE_2D
    case 0x806f: value = c.tex_units[c.active_texture].enabled_3d; return true; // GL_TEXTURE_3D
    case 0x8074: value = c.vertex_array.enabled; return true; // GL_VERTEX_ARRAY
    case 0x8075: value = c.normal_array.enabled; return true; // GL_NORMAL_ARRAY
    case 0x8076: value = c.color_array.enabled; return true; // GL_COLOR_ARRAY
    case 0x8077: value = c.index_array.enabled; return true; // GL_INDEX_ARRAY
    case 0x8079: value = c.edge_flag_array.enabled; return true; // GL_EDGE_FLAG_ARRAY
    case 0x8078: value = c.texcoord_array[c.client_active_texture].enabled; return true; // GL_TEXTURE_COORD_ARRAY
    case 0x845e: value = c.secondary_color_array.enabled; return true; // GL_SECONDARY_COLOR_ARRAY_EXT
    // Stippling is accepted by Enable/Disable but has no renderer state yet.
    case 0x0b24: value = c.line_stipple_enabled; return true;
    case 0x0b42: value = c.polygon_stipple_enabled; return true;
    case 0x80d0: value = c.color_table_enabled; return true;
    case 0x80d1: value = c.post_convolution_color_table_enabled; return true;
    case 0x80d2: value = c.post_color_matrix_color_table_enabled; return true;
    case 0x8010: value = c.convolution_1d_enabled; return true;
    case 0x8011: value = c.convolution_2d_enabled; return true;
    case 0x8012: value = c.separable_2d_enabled; return true;
    case 0x8024: value = c.histogram_enabled; return true;
    case 0x802e: value = c.minmax_enabled; return true;
    default:
        if (cap >= 0x4000 && cap < 0x4008) value = c.lights[cap - 0x4000].enabled;
        else if (cap >= 0x3000 && cap < 0x3006) value = c.clip_plane_enabled[cap - 0x3000];
        else if (cap >= 0x0c60 && cap <= 0x0c63) {
            const auto &unit = c.tex_units[c.active_texture];
            const bool flags[] = {unit.texgen_s_enabled, unit.texgen_t_enabled,
                                  unit.texgen_r_enabled, unit.texgen_q_enabled};
            value = flags[cap - 0x0c60];
        } else if (cap >= 0x0d90 && cap <= 0x0d98) value = c.eval_map1_enabled[GLStateEvaluatorIndex(cap)];
        else if (cap >= 0x0db0 && cap <= 0x0db8) value = c.eval_map2_enabled[GLStateEvaluatorIndex(cap)];
        else return false;
        return true;
    }
}

static inline bool GLQueryState(const GLContext &c, uint32_t pname, GLStateQuery &q)
{
    bool enabled;
    if (GLQueryCapability(c, pname, enabled)) return q.scalar(enabled);
    switch (pname) {
    case 0x0ba0: return q.scalar(c.matrix_mode); // GL_MATRIX_MODE
    case 0x0d33: return q.scalar(1024); // GL_MAX_TEXTURE_SIZE
    case 0x8073: return q.scalar(1024); // GL_MAX_3D_TEXTURE_SIZE
    case 0x0d31: return q.scalar(8); // GL_MAX_LIGHTS
    case 0x0d36: return q.scalar(32); // GL_MAX_MODELVIEW_STACK_DEPTH
    case 0x0d38: return q.scalar(32); // GL_MAX_PROJECTION_STACK_DEPTH
    case 0x0d39: return q.scalar(32); // GL_MAX_TEXTURE_STACK_DEPTH
    case 0x0d32: return q.scalar(6); // GL_MAX_CLIP_PLANES
    case 0x0d35: return q.scalar(GL_MAX_ATTRIB_STACK_DEPTH); // GL_MAX_ATTRIB_STACK_DEPTH
    case 0x0d3b: return q.scalar(GL_MAX_CLIENT_ATTRIB_STACK_DEPTH); // GL_MAX_CLIENT_ATTRIB_STACK_DEPTH
    case 0x0d37: return q.scalar(64); // GL_MAX_NAME_STACK_DEPTH
    case 0x84e2: return q.scalar(GL_RENDER_TEXTURE_UNITS); // GL_MAX_TEXTURE_UNITS_ARB
    case 0x0b31: return q.scalar(64); // GL_MAX_LIST_NESTING
    case 0x0d34: return q.scalar(256); // GL_MAX_PIXEL_MAP_TABLE
    case 0x0ba3: return q.scalar(c.modelview_depth+1); // GL_MODELVIEW_STACK_DEPTH
    case 0x0ba4: return q.scalar(c.projection_depth+1); // GL_PROJECTION_STACK_DEPTH
    case 0x0ba5: return q.scalar(c.texture_depth[c.active_texture]+1); // GL_TEXTURE_STACK_DEPTH
    case 0x0bb0: return q.scalar(c.attrib_stack_depth); // GL_ATTRIB_STACK_DEPTH
    case 0x0bb1: return q.scalar(c.client_attrib_stack_depth); // GL_CLIENT_ATTRIB_STACK_DEPTH
    case 0x0b74: return q.scalar(c.depth_func); // GL_DEPTH_FUNC
    case 0x0b72: return q.scalar(c.depth_mask); // GL_DEPTH_WRITEMASK
    case 0x0b54: return q.scalar(c.shade_model); // GL_SHADE_MODEL
    case 0x0be1: return q.scalar(c.blend_src); // GL_BLEND_SRC
    case 0x0be0: return q.scalar(c.blend_dst); // GL_BLEND_DST
    case 0x8009: return q.scalar(c.blend_equation); // GL_BLEND_EQUATION_EXT
    case 0x0b92: return q.scalar(c.stencil.func); // GL_STENCIL_FUNC
    case 0x0b93: return q.scalar(c.stencil.value_mask); // GL_STENCIL_VALUE_MASK
    case 0x0b97: return q.scalar(c.stencil.ref); // GL_STENCIL_REF
    case 0x0b94: return q.scalar(c.stencil.sfail); // GL_STENCIL_FAIL
    case 0x0b95: return q.scalar(c.stencil.dpfail); // GL_STENCIL_PASS_DEPTH_FAIL
    case 0x0b96: return q.scalar(c.stencil.dppass); // GL_STENCIL_PASS_DEPTH_PASS
    case 0x0b98: return q.scalar(c.stencil.write_mask); // GL_STENCIL_WRITEMASK
    case 0x0b91: return q.scalar(c.clear_stencil); // GL_STENCIL_CLEAR_VALUE
    case 0x0bc1: return q.scalar(c.alpha_func); // GL_ALPHA_TEST_FUNC
    case 0x0b45: return q.scalar(c.cull_face_mode); // GL_CULL_FACE_MODE
    case 0x0b46: return q.scalar(c.front_face); // GL_FRONT_FACE
    case 0x0bf0: return q.scalar(c.logic_op_mode); // GL_LOGIC_OP_MODE
    case 0x84e0: return q.scalar(0x84c0+c.active_texture); // GL_ACTIVE_TEXTURE_ARB
    case 0x84e1: return q.scalar(0x84c0+c.client_active_texture); // GL_CLIENT_ACTIVE_TEXTURE_ARB
    case 0x8068: return q.scalar(c.tex_units[c.active_texture].bound_texture_1d); // GL_TEXTURE_BINDING_1D
    case 0x8069: return q.scalar(c.tex_units[c.active_texture].bound_texture_2d); // GL_TEXTURE_BINDING_2D
    case 0x806a: return q.scalar(c.tex_units[c.active_texture].bound_texture_3d); // GL_TEXTURE_3D_BINDING_EXT
    case 0x0c40: return q.scalar(c.render_mode); // GL_RENDER_MODE
    case 0x0c01: return q.scalar(c.draw_buffer); // GL_DRAW_BUFFER
    case 0x0c02: return q.scalar(c.read_buffer); // GL_READ_BUFFER
    case 0x0c32: return q.scalar(c.double_buffered); // GL_DOUBLEBUFFER
    case 0x0c31: return q.scalar(true); // GL_RGBA_MODE
    case 0x0c30: return q.scalar(false); // GL_INDEX_MODE
    case 0x0c33: return q.scalar(false); // GL_STEREO
    case 0x0c00: return q.scalar(0); // GL_AUX_BUFFERS
    case 0x0d50: return q.scalar(8); // GL_SUBPIXEL_BITS
    case 0x0d52: return q.scalar(8); // GL_RED_BITS
    case 0x0d53: return q.scalar(8); // GL_GREEN_BITS
    case 0x0d54: return q.scalar(8); // GL_BLUE_BITS
    case 0x0d55: return q.scalar(8); // GL_ALPHA_BITS
    case 0x0d56: return q.scalar(32); // GL_DEPTH_BITS
    case 0x0d57: return q.scalar(8); // GL_STENCIL_BITS
    case 0x0d58: return q.scalar(32); // GL_ACCUM_RED_BITS
    case 0x0d59: return q.scalar(32); // GL_ACCUM_GREEN_BITS
    case 0x0d5a: return q.scalar(32); // GL_ACCUM_BLUE_BITS
    case 0x0d5b: return q.scalar(32); // GL_ACCUM_ALPHA_BITS
    case 0x0d51: return q.scalar(0); // GL_INDEX_BITS
    case 0x0d00: return q.scalar(c.pixel_store.pack_swap_bytes); // GL_PACK_SWAP_BYTES
    case 0x0d01: return q.scalar(c.pixel_store.pack_lsb_first); // GL_PACK_LSB_FIRST
    case 0x0d05: return q.scalar(c.pixel_store.pack_alignment); // GL_PACK_ALIGNMENT
    case 0x0d02: return q.scalar(c.pixel_store.pack_row_length); // GL_PACK_ROW_LENGTH
    case 0x0d04: return q.scalar(c.pixel_store.pack_skip_pixels); // GL_PACK_SKIP_PIXELS
    case 0x0d03: return q.scalar(c.pixel_store.pack_skip_rows); // GL_PACK_SKIP_ROWS
    case 0x0d30: return q.scalar(30); // GL_MAX_EVAL_ORDER
    case 0x806e: return q.scalar(c.pixel_store.unpack_image_height); // GL_UNPACK_IMAGE_HEIGHT
    case 0x806d: return q.scalar(c.pixel_store.unpack_skip_images); // GL_UNPACK_SKIP_IMAGES
    case 0x0cf1: return q.scalar(c.pixel_store.unpack_lsb_first); // GL_UNPACK_LSB_FIRST
    case 0x0cf5: return q.scalar(c.pixel_store.unpack_alignment); // GL_UNPACK_ALIGNMENT
    case 0x0cf2: return q.scalar(c.pixel_store.unpack_row_length); // GL_UNPACK_ROW_LENGTH
    case 0x0cf4: return q.scalar(c.pixel_store.unpack_skip_pixels); // GL_UNPACK_SKIP_PIXELS
    case 0x0cf3: return q.scalar(c.pixel_store.unpack_skip_rows); // GL_UNPACK_SKIP_ROWS
    case 0x0b11: return q.scalar(c.point_size); // GL_POINT_SIZE
    case 0x0b21: return q.scalar(c.line_width); // GL_LINE_WIDTH
    case 0x0b62: return q.scalar(c.fog_density); // GL_FOG_DENSITY
    case 0x0b63: return q.scalar(c.fog_start); // GL_FOG_START
    case 0x0b64: return q.scalar(c.fog_end); // GL_FOG_END
    case 0x0b65: return q.scalar(c.fog_mode); // GL_FOG_MODE
    case 0x8038: return q.scalar(c.polygon_offset_factor); // GL_POLYGON_OFFSET_FACTOR
    case 0x2a00: return q.scalar(c.polygon_offset_units); // GL_POLYGON_OFFSET_UNITS
    case 0x0b55: return q.scalar(c.color_material_face); // GL_COLOR_MATERIAL_FACE
    case 0x0b56: return q.scalar(c.color_material_mode); // GL_COLOR_MATERIAL_PARAMETER
    case 0x0b52: return q.scalar(c.light_model_two_side); // GL_LIGHT_MODEL_TWO_SIDE
    case 0x0b51: return q.scalar(c.light_model_local_viewer); // GL_LIGHT_MODEL_LOCAL_VIEWER
    case 0x0b01: return q.scalar(c.current_index); // GL_CURRENT_INDEX
    case 0x0b43: return q.scalar(c.current_edge_flag); // GL_EDGE_FLAG
    case 0x0b08: return q.scalar(c.raster_pos_valid); // GL_CURRENT_RASTER_POSITION_VALID
    case 0x0c20: return q.scalar(c.clear_index); // GL_INDEX_CLEAR_VALUE
    case 0x0c21: return q.scalar(c.index_write_mask); // GL_INDEX_WRITEMASK
    case 0x0b25: return q.scalar(c.line_stipple_pattern); // GL_LINE_STIPPLE_PATTERN
    case 0x0b26: return q.scalar(c.line_stipple_factor); // GL_LINE_STIPPLE_REPEAT
    case 0x0b32: return q.scalar(c.list_base); // GL_LIST_BASE
    case 0x0b33: return q.scalar(c.in_display_list?c.current_list_name:0); // GL_LIST_INDEX
    case 0x0b30: return q.scalar(c.in_display_list?c.current_list_mode:0); // GL_LIST_MODE
    case 0x0d70: return q.scalar(c.name_stack_depth); // GL_NAME_STACK_DEPTH
    case 0x0df4: return q.scalar(c.selection_buffer_size); // GL_SELECTION_BUFFER_SIZE
    case 0x0df1: return q.scalar(c.feedback_buffer_size); // GL_FEEDBACK_BUFFER_SIZE
    case 0x0df2: return q.scalar(c.feedback_type); // GL_FEEDBACK_BUFFER_TYPE
    case 0x0c50: return q.scalar(c.hint_perspective_correction); // GL_PERSPECTIVE_CORRECTION_HINT
    case 0x0c51: return q.scalar(c.hint_point_smooth); // GL_POINT_SMOOTH_HINT
    case 0x0c52: return q.scalar(c.hint_line_smooth); // GL_LINE_SMOOTH_HINT
    case 0x0c53: return q.scalar(c.hint_polygon_smooth); // GL_POLYGON_SMOOTH_HINT
    case 0x0c54: return q.scalar(c.hint_fog); // GL_FOG_HINT
    case 0x0d16: return q.scalar(c.pixel_zoom_x); // GL_ZOOM_X
    case 0x0d17: return q.scalar(c.pixel_zoom_y); // GL_ZOOM_Y
    case 0x0d14: return q.scalar(c.pixel_transfer_red_scale); // GL_RED_SCALE
    case 0x0d18: return q.scalar(c.pixel_transfer_green_scale); // GL_GREEN_SCALE
    case 0x0d1a: return q.scalar(c.pixel_transfer_blue_scale); // GL_BLUE_SCALE
    case 0x0d1c: return q.scalar(c.pixel_transfer_alpha_scale); // GL_ALPHA_SCALE
    case 0x0d15: return q.scalar(c.pixel_transfer_red_bias); // GL_RED_BIAS
    case 0x0d19: return q.scalar(c.pixel_transfer_green_bias); // GL_GREEN_BIAS
    case 0x0d1b: return q.scalar(c.pixel_transfer_blue_bias); // GL_BLUE_BIAS
    case 0x0d1d: return q.scalar(c.pixel_transfer_alpha_bias); // GL_ALPHA_BIAS
    case 0x0d1e: return q.scalar(c.pixel_transfer_depth_scale); // GL_DEPTH_SCALE
    case 0x0d1f: return q.scalar(c.pixel_transfer_depth_bias); // GL_DEPTH_BIAS
    case 0x0cb2: return q.scalar(c.pixel_map_i_to_r_size); // GL_PIXEL_MAP_I_TO_R_SIZE
    case 0x0cb3: return q.scalar(c.pixel_map_i_to_g_size); // GL_PIXEL_MAP_I_TO_G_SIZE
    case 0x0cb4: return q.scalar(c.pixel_map_i_to_b_size); // GL_PIXEL_MAP_I_TO_B_SIZE
    case 0x0cb5: return q.scalar(c.pixel_map_i_to_a_size); // GL_PIXEL_MAP_I_TO_A_SIZE
    case 0x0cb6: return q.scalar(c.pixel_map_r_to_r_size); // GL_PIXEL_MAP_R_TO_R_SIZE
    case 0x0cb7: return q.scalar(c.pixel_map_g_to_g_size); // GL_PIXEL_MAP_G_TO_G_SIZE
    case 0x0cb8: return q.scalar(c.pixel_map_b_to_b_size); // GL_PIXEL_MAP_B_TO_B_SIZE
    case 0x0cb9: return q.scalar(c.pixel_map_a_to_a_size); // GL_PIXEL_MAP_A_TO_A_SIZE
    case 0x807a: return q.scalar(c.vertex_array.size); // GL_VERTEX_ARRAY_SIZE
    case 0x807b: return q.scalar(c.vertex_array.type); // GL_VERTEX_ARRAY_TYPE
    case 0x807c: return q.scalar(c.vertex_array.stride); // GL_VERTEX_ARRAY_STRIDE
    case 0x807e: return q.scalar(c.normal_array.type); // GL_NORMAL_ARRAY_TYPE
    case 0x807f: return q.scalar(c.normal_array.stride); // GL_NORMAL_ARRAY_STRIDE
    case 0x8081: return q.scalar(c.color_array.size); // GL_COLOR_ARRAY_SIZE
    case 0x8082: return q.scalar(c.color_array.type); // GL_COLOR_ARRAY_TYPE
    case 0x8083: return q.scalar(c.color_array.stride); // GL_COLOR_ARRAY_STRIDE
    case 0x8085: return q.scalar(c.index_array.type); // GL_INDEX_ARRAY_TYPE
    case 0x8086: return q.scalar(c.index_array.stride); // GL_INDEX_ARRAY_STRIDE
    case 0x808c: return q.scalar(c.edge_flag_array.stride); // GL_EDGE_FLAG_ARRAY_STRIDE
    case 0x8088: return q.scalar(c.texcoord_array[c.client_active_texture].size); // GL_TEXTURE_COORD_ARRAY_SIZE
    case 0x8089: return q.scalar(c.texcoord_array[c.client_active_texture].type); // GL_TEXTURE_COORD_ARRAY_TYPE
    case 0x808a: return q.scalar(c.texcoord_array[c.client_active_texture].stride); // GL_TEXTURE_COORD_ARRAY_STRIDE
    case 0x845a: return q.scalar(c.secondary_color_array.size); // GL_SECONDARY_COLOR_ARRAY_SIZE_EXT
    case 0x845b: return q.scalar(c.secondary_color_array.type); // GL_SECONDARY_COLOR_ARRAY_TYPE_EXT
    case 0x845c: return q.scalar(c.secondary_color_array.stride); // GL_SECONDARY_COLOR_ARRAY_STRIDE_EXT
    case 0x81a8: return q.scalar(c.lock_first); // GL_ARRAY_ELEMENT_LOCK_FIRST_EXT
    case 0x81a9: return q.scalar(c.lock_count); // GL_ARRAY_ELEMENT_LOCK_COUNT_EXT
    case 0x0dd1: return q.scalar(c.grid1_un); // GL_MAP1_GRID_SEGMENTS
    case 0x0ba2: return q.vector(c.viewport); // GL_VIEWPORT
    case 0x0c10: return q.vector(c.scissor_box); // GL_SCISSOR_BOX
    case 0x0ba6: return q.vector(c.modelview_stack[c.modelview_depth]); // GL_MODELVIEW_MATRIX
    case 0x0ba7: return q.vector(c.projection_stack[c.projection_depth]); // GL_PROJECTION_MATRIX
    case 0x0ba8: return q.vector(c.texture_stack[c.active_texture][c.texture_depth[c.active_texture]]); // GL_TEXTURE_MATRIX
    case 0x0b03: return q.vector(c.current_texcoord[c.active_texture]); // GL_CURRENT_TEXTURE_COORDS
    case 0x0c23: return q.vector(c.color_mask); // GL_COLOR_WRITEMASK
    case 0x0b07: return q.vector(c.raster_pos); // GL_CURRENT_RASTER_POSITION
    case 0x0b00: return q.vector(c.current_color, true); // GL_CURRENT_COLOR
    case 0x0b02: return q.vector(c.current_normal, true); // GL_CURRENT_NORMAL
    case 0x0b04: return q.vector(c.raster_color, true); // GL_CURRENT_RASTER_COLOR
    case 0x8459: return q.vector(c.current_secondary_color, true); // GL_CURRENT_SECONDARY_COLOR_EXT
    case 0x0c22: return q.vector(c.clear_color, true); // GL_COLOR_CLEAR_VALUE
    case 0x0b80: return q.vector(c.clear_accum, true); // GL_ACCUM_CLEAR_VALUE
    case 0x0b66: return q.vector(c.fog_color, true); // GL_FOG_COLOR
    case 0x8005: return q.vector(c.blend_color, true); // GL_BLEND_COLOR_EXT
    case 0x0b53: return q.vector(c.light_model_ambient, true); // GL_LIGHT_MODEL_AMBIENT
    case 0x0b70: return q.pair(c.depth_range_near, c.depth_range_far, true); // GL_DEPTH_RANGE
    case 0x0b73: q.normalized = true; return q.scalar(c.clear_depth); // GL_DEPTH_CLEAR_VALUE
    case 0x0bc2: q.normalized = true; return q.scalar(c.alpha_ref); // GL_ALPHA_TEST_REF
    case 0x0b40: return q.pair(c.polygon_mode_front, c.polygon_mode_back); // GL_POLYGON_MODE
    case 0x0d3a: return q.pair(16384, 16384); // GL_MAX_VIEWPORT_DIMS
    case 0x0b12: return q.pair(1, 64); // GL_POINT_SIZE_RANGE (shader point size)
    case 0x0b22: return q.pair(1, 1); // GL_LINE_WIDTH_RANGE (Metal lines)
    case 0x0b13: case 0x0b23: return q.scalar(1); // point/line size granularity
    case 0x0dd0: return q.pair(c.grid1_u1, c.grid1_u2); // GL_MAP1_GRID_DOMAIN
    case 0x0dd3: return q.pair(c.grid2_un, c.grid2_vn); // GL_MAP2_GRID_SEGMENTS
    case 0x0dd2: // GL_MAP2_GRID_DOMAIN
        q.count = 4; q.values[0] = c.grid2_u1; q.values[1] = c.grid2_u2;
        q.values[2] = c.grid2_v1; q.values[3] = c.grid2_v2; return true;
    case 0x84e3: case 0x84e4: case 0x84e5: case 0x84e6: { // ARB_transpose_matrix
        if (pname == 0x84e3) q.vector(c.modelview_stack[c.modelview_depth]);
        else if (pname == 0x84e4) q.vector(c.projection_stack[c.projection_depth]);
        else if (pname == 0x84e5) q.vector(c.texture_stack[c.active_texture][c.texture_depth[c.active_texture]]);
        else q.vector(c.color_stack[c.color_depth]);
        for (unsigned row = 0; row < 4; ++row)
            for (unsigned col = row + 1; col < 4; ++col) {
                double value = q.values[row*4+col];
                q.values[row*4+col] = q.values[col*4+row];
                q.values[col*4+row] = value;
            }
        return true;
    }
    default: return false;
    }
}
static inline bool GLGetStateQuery(GLContext *ctx, uint32_t pname, GLStateQuery &query)
{
    if (!ctx) return false;
    const uint32_t error = ctx->in_begin ? 0x0502 :
        GLQueryState(*ctx, pname, query) ? 0 : 0x0500;
    if (!error) return true;
    if (!ctx->last_error) ctx->last_error = error;
    return false;
}
#endif
