/*
 *  gl_thunks.cpp - OpenGL PPC-to-native thunk allocation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Allocates PPC-callable TVECTs in SheepMem for all GL/AGL/GLU/GLUT
 *  functions (~643 total). Each TVECT writes a sub-opcode to a scratch
 *  word then executes NATIVE_OPENGL_DISPATCH to reach the native handler.
 *
 *  Pattern is identical to rave_thunks.cpp. Each TVECT is a proper PPC
 *  transition vector: 8-byte header (code_ptr, TOC) followed by thunk code.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "gl_engine.h"

// Storage for TVECT addresses and scratch words
uint32_t gl_method_tvects[GL_MAX_SUBOPCODE];
uint32_t gl_scratch_addr = 0;

// Dispatch-table TVECTs (called when game accesses context's internal dispatch table).
// These shift R3-R10 left by one position because the game passes the context
// index in R3 and real GL args start at R4.
uint32_t gl_dt_method_tvects[GL_MAX_SUBOPCODE];
uint32_t gl_dt_flag_addr = 0;  // scratch word: 1 = dispatch-table call, 0 = stub call
// gl_logging_enabled is defined in gl_dispatch.cpp (single definition)

/*
 *  Function signature table -- maps sub-opcode to argument type info.
 *
 *  float_mask: bit N = 1 means arg N is a float/double (from FPR).
 *  Only the most commonly used functions have explicit signatures.
 *  Functions not in this table default to {0, 0} (all-integer/pointer args).
 *
 *  PPC ABI: floats/doubles are passed in FPR1-FPR13.
 *  Integer/pointer args go in GPR3-GPR10.
 *  The generic dispatch handler uses this table to extract FPR values.
 */
static const GLFuncSignature gl_func_sigs_init[GL_MAX_SUBOPCODE] = {
    // Most entries are zero-initialized (all-integer args).
    // Non-trivial entries are set explicitly below in GLThunksInit
    // via a mutable copy, but we define common ones statically here.
};

// Mutable copy that gets populated at init time
GLFuncSignature gl_func_signatures[GL_MAX_SUBOPCODE];
// gl_func_signatures is the extern array declared in gl_engine.h
// It's non-const here because we populate it at init time, but declared
// as const extern for read-only access from dispatch code

/*
 *  Allocate a single GL TVECT thunk in SheepMem
 *
 *  Layout is identical to AllocateRaveTVECT (32 bytes):
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (= 0)
 *    +8:  lis   r11, scratch_hi16
 *   +12:  ori   r11, r11, scratch_lo16
 *   +16:  li    r12, method_id
 *   +20:  stw   r12, 0(r11)
 *   +24:  <gl_opcode>    -- NATIVE_OPENGL_DISPATCH
 *   +28:  blr
 */
static uint32 AllocateGLTVECT(int method_id, uint32 gl_opcode)
{
	uint32 scratch_hi = (gl_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = gl_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

	// TVECT header
	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	// lis r11, scratch_hi16
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));
	// ori r11, r11, scratch_lo16
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF));
	// li r12, method_id
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));
	// stw r12, 0(r11)
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16));
	// NATIVE_OPENGL_DISPATCH opcode
	WriteMacInt32(code + 16, gl_opcode);
	// blr
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

/*
 *  AllocateGLDispatchTableTVECT - thunk for dispatch-table calls
 *
 *  Same as AllocateGLTVECT but also writes 1 to gl_dt_flag_addr so the
 *  native dispatch handler knows to shift GPR args left by one (the game
 *  passes the context index in R3, real GL args start at R4).
 *
 *  Layout (48 bytes):
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (= 0)
 *    +8:  lis   r11, flag_hi16
 *   +12:  ori   r11, r11, flag_lo16
 *   +16:  li    r12, 1
 *   +20:  stw   r12, 0(r11)          -- set flag = 1
 *   +24:  lis   r11, scratch_hi16
 *   +28:  ori   r11, r11, scratch_lo16
 *   +32:  li    r12, method_id
 *   +36:  stw   r12, 0(r11)          -- write sub-opcode
 *   +40:  <gl_opcode>                -- NATIVE_OPENGL_DISPATCH
 *   +44:  blr
 */
static uint32 AllocateGLDispatchTableTVECT(int method_id, uint32 gl_opcode)
{
	uint32 flag_hi = (gl_dt_flag_addr >> 16) & 0xFFFF;
	uint32 flag_lo = gl_dt_flag_addr & 0xFFFF;
	uint32 scratch_hi = (gl_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = gl_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(48);
	uint32 code = base + 8;

	// TVECT header
	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	// Set dispatch-table flag = 1
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (flag_hi & 0xFFFF));       // lis r11, flag_hi
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (flag_lo & 0xFFFF)); // ori r11, r11, flag_lo
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | 1);                        // li r12, 1
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16));             // stw r12, 0(r11)

	// Write sub-opcode to scratch (same as normal thunk)
	WriteMacInt32(code + 16, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));   // lis r11, scratch_hi
	WriteMacInt32(code + 20, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF)); // ori r11, r11, scratch_lo
	WriteMacInt32(code + 24, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));    // li r12, method_id
	WriteMacInt32(code + 28, 0x90000000 | (r12 << 21) | (r11 << 16));             // stw r12, 0(r11)

	// NATIVE_OPENGL_DISPATCH opcode
	WriteMacInt32(code + 32, gl_opcode);
	// blr
	WriteMacInt32(code + 36, 0x4E800020);

	return base;
}

/*
 *  Populate function signature table for known GL functions.
 *
 *  This tells the dispatch handler which arguments are floats (FPR)
 *  vs integers/pointers (GPR). Only functions with float args need entries.
 */
static void InitFuncSignatures()
{
	memset(gl_func_signatures, 0, sizeof(gl_func_signatures));

	// Helper macro: set signature for a sub-opcode
	#define SIG(sub, nargs, fmask) \
		gl_func_signatures[sub] = { (uint8_t)(nargs), (uint8_t)(fmask) }

	// Core GL functions with float arguments:
	// Note: the "ctx" pointer is arg0 in the dispatch table but is NOT
	// passed through the thunk -- it's the GLContext looked up by the handler.
	// So num_args here is the PPC-visible arg count (r3 onwards).

	// accum(op, value) -- op=int, value=float
	SIG(GL_SUB_ACCUM, 2, 0x02);
	// alpha_func(func, ref) -- func=int, ref=float
	SIG(GL_SUB_ALPHA_FUNC, 2, 0x02);
	// clear_accum(r, g, b, a) -- 4 floats
	SIG(GL_SUB_CLEAR_ACCUM, 4, 0x0F);
	// clear_color(r, g, b, a) -- 4 floats
	SIG(GL_SUB_CLEAR_COLOR, 4, 0x0F);
	// clear_depth(depth) -- 1 double (1 FPR slot)
	SIG(GL_SUB_CLEAR_DEPTH, 1, 0x01);
	// clear_index(c) -- 1 float
	SIG(GL_SUB_CLEAR_INDEX, 1, 0x01);
	// color3f(r, g, b)
	SIG(GL_SUB_COLOR3F, 3, 0x07);
	// color3d(r, g, b)
	SIG(GL_SUB_COLOR3D, 3, 0x07);
	// color4f(r, g, b, a)
	SIG(GL_SUB_COLOR4F, 4, 0x0F);
	// color4d(r, g, b, a)
	SIG(GL_SUB_COLOR4D, 4, 0x0F);
	// depth_range(near, far) -- 2 doubles
	SIG(GL_SUB_DEPTH_RANGE, 2, 0x03);
	// fogf(pname, param) -- pname=int, param=float
	SIG(GL_SUB_FOGF, 2, 0x02);
	// frustum(l, r, b, t, n, f) -- 6 doubles
	SIG(GL_SUB_FRUSTUM, 6, 0x3F);
	// indexd(c) -- 1 double
	SIG(GL_SUB_INDEXD, 1, 0x01);
	// indexf(c) -- 1 float
	SIG(GL_SUB_INDEXF, 1, 0x01);
	// lightf(light, pname, param) -- light=int, pname=int, param=float
	SIG(GL_SUB_LIGHTF, 3, 0x04);
	// light_modelf(pname, param) -- pname=int, param=float
	SIG(GL_SUB_LIGHT_MODELF, 2, 0x02);
	// line_width(width) -- 1 float
	SIG(GL_SUB_LINE_WIDTH, 1, 0x01);
	// materialf(face, pname, param)
	SIG(GL_SUB_MATERIALF, 3, 0x04);
	// normal3f(x, y, z) -- 3 floats
	SIG(GL_SUB_NORMAL3F, 3, 0x07);
	// normal3d(x, y, z)
	SIG(GL_SUB_NORMAL3D, 3, 0x07);
	// ortho(l, r, b, t, n, f) -- 6 doubles
	SIG(GL_SUB_ORTHO, 6, 0x3F);
	// pass_through(token) -- 1 float
	SIG(GL_SUB_PASS_THROUGH, 1, 0x01);
	// pixel_storef(pname, param) -- pname=int, param=float
	SIG(GL_SUB_PIXEL_STOREF, 2, 0x02);
	// pixel_transferf(pname, param)
	SIG(GL_SUB_PIXEL_TRANSFERF, 2, 0x02);
	// pixel_zoom(xfactor, yfactor) -- 2 floats
	SIG(GL_SUB_PIXEL_ZOOM, 2, 0x03);
	// point_size(size) -- 1 float
	SIG(GL_SUB_POINT_SIZE, 1, 0x01);
	// polygon_offset(factor, units) -- 2 floats
	SIG(GL_SUB_POLYGON_OFFSET, 2, 0x03);
	// rotatef(angle, x, y, z) -- 4 floats
	SIG(GL_SUB_ROTATEF, 4, 0x0F);
	// rotated(angle, x, y, z) -- 4 doubles
	SIG(GL_SUB_ROTATED, 4, 0x0F);
	// scalef(x, y, z) -- 3 floats
	SIG(GL_SUB_SCALEF, 3, 0x07);
	// scaled(x, y, z)
	SIG(GL_SUB_SCALED, 3, 0x07);
	// tex_coord1f(s)
	SIG(GL_SUB_TEX_COORD1F, 1, 0x01);
	// tex_coord1d(s)
	SIG(GL_SUB_TEX_COORD1D, 1, 0x01);
	// tex_coord2f(s, t)
	SIG(GL_SUB_TEX_COORD2F, 2, 0x03);
	// tex_coord2d(s, t)
	SIG(GL_SUB_TEX_COORD2D, 2, 0x03);
	// tex_coord3f(s, t, r)
	SIG(GL_SUB_TEX_COORD3F, 3, 0x07);
	// tex_coord3d(s, t, r)
	SIG(GL_SUB_TEX_COORD3D, 3, 0x07);
	// tex_coord4f(s, t, r, q)
	SIG(GL_SUB_TEX_COORD4F, 4, 0x0F);
	// tex_coord4d(s, t, r, q)
	SIG(GL_SUB_TEX_COORD4D, 4, 0x0F);
	// tex_envf(target, pname, param) -- target=int, pname=int, param=float
	SIG(GL_SUB_TEX_ENVF, 3, 0x04);
	// tex_gend(coord, pname, param)
	SIG(GL_SUB_TEX_GEND, 3, 0x04);
	// tex_genf(coord, pname, param)
	SIG(GL_SUB_TEX_GENF, 3, 0x04);
	// tex_parameterf(target, pname, param)
	SIG(GL_SUB_TEX_PARAMETERF, 3, 0x04);
	// translatef(x, y, z) -- 3 floats
	SIG(GL_SUB_TRANSLATEF, 3, 0x07);
	// translated(x, y, z)
	SIG(GL_SUB_TRANSLATED, 3, 0x07);
	// vertex2f(x, y)
	SIG(GL_SUB_VERTEX2F, 2, 0x03);
	// vertex2d(x, y)
	SIG(GL_SUB_VERTEX2D, 2, 0x03);
	// vertex3f(x, y, z)
	SIG(GL_SUB_VERTEX3F, 3, 0x07);
	// vertex3d(x, y, z)
	SIG(GL_SUB_VERTEX3D, 3, 0x07);
	// vertex4f(x, y, z, w)
	SIG(GL_SUB_VERTEX4F, 4, 0x0F);
	// vertex4d(x, y, z, w)
	SIG(GL_SUB_VERTEX4D, 4, 0x0F);
	// rectf(x1, y1, x2, y2)
	SIG(GL_SUB_RECTF, 4, 0x0F);
	// rectd(x1, y1, x2, y2)
	SIG(GL_SUB_RECTD, 4, 0x0F);
	// eval_coord1f(u)
	SIG(GL_SUB_EVAL_COORD1F, 1, 0x01);
	// eval_coord1d(u)
	SIG(GL_SUB_EVAL_COORD1D, 1, 0x01);
	// eval_coord2f(u, v)
	SIG(GL_SUB_EVAL_COORD2F, 2, 0x03);
	// eval_coord2d(u, v)
	SIG(GL_SUB_EVAL_COORD2D, 2, 0x03);
	// bitmap(w, h, xorig, yorig, xmove, ymove, bitmap)
	//   w=int, h=int, xorig=float, yorig=float, xmove=float, ymove=float, ptr=int
	SIG(GL_SUB_BITMAP, 7, 0x3C);
	// raster_pos2f(x, y)
	SIG(GL_SUB_RASTER_POS2F, 2, 0x03);
	// raster_pos2d(x, y)
	SIG(GL_SUB_RASTER_POS2D, 2, 0x03);
	// raster_pos3f(x, y, z)
	SIG(GL_SUB_RASTER_POS3F, 3, 0x07);
	// raster_pos3d(x, y, z)
	SIG(GL_SUB_RASTER_POS3D, 3, 0x07);
	// raster_pos4f(x, y, z, w)
	SIG(GL_SUB_RASTER_POS4F, 4, 0x0F);
	// raster_pos4d(x, y, z, w)
	SIG(GL_SUB_RASTER_POS4D, 4, 0x0F);
	// convolution_parameterf(target, pname, params) -- target=int, pname=int, params=float
	SIG(GL_SUB_CONVOLUTION_PARAMETERF, 3, 0x04);

	// Extension functions with floats:
	// blend_color_EXT(r, g, b, a) -- 4 floats
	SIG(GL_SUB_BLEND_COLOR_EXT, 4, 0x0F);
	// blend_color (GL 1.2)(r, g, b, a)
	SIG(GL_SUB_BLEND_COLOR_1_2, 4, 0x0F);
	// secondary_color3f_EXT(r, g, b)
	SIG(GL_SUB_SECONDARY_COLOR3F_EXT, 3, 0x07);
	// secondary_color3d_EXT(r, g, b)
	SIG(GL_SUB_SECONDARYCOLOR3D_EXT, 3, 0x07);
	// multi_tex_coord1f_ARB(target, s) -- target=int, s=float
	SIG(GL_SUB_MULTI_TEX_COORD1F_ARB, 2, 0x02);
	// multi_tex_coord2f_ARB(target, s, t)
	SIG(GL_SUB_MULTI_TEX_COORD2F_ARB, 3, 0x06);
	// multi_tex_coord3f_ARB(target, s, t, r)
	SIG(GL_SUB_MULTI_TEX_COORD3F_ARB, 4, 0x0E);
	// multi_tex_coord4f_ARB(target, s, t, r, q)
	SIG(GL_SUB_MULTI_TEX_COORD4F_ARB, 5, 0x1E);
	// multi_tex_coord*d_ARB doubles (target=int, rest=double)
	SIG(GL_SUB_MULTI_TEX_COORD1D_ARB, 2, 0x02);
	SIG(GL_SUB_MULTI_TEX_COORD2D_ARB, 3, 0x06);
	SIG(GL_SUB_MULTI_TEX_COORD3D_ARB, 4, 0x0E);
	SIG(GL_SUB_MULTI_TEX_COORD4D_ARB, 5, 0x1E);

	// GLU functions with floats:
	// gluPerspective(fovy, aspect, zNear, zFar) -- 4 doubles
	SIG(GL_SUB_GLU_PERSPECTIVE, 4, 0x0F);
	// gluLookAt(eyeX..upZ) -- 9 doubles
	SIG(GL_SUB_GLU_LOOKAT, 9, 0xFF);  // only 8 bits available, first 8 tracked
	// gluOrtho2D(left, right, bottom, top) -- 4 doubles
	SIG(GL_SUB_GLU_ORTHO2D, 4, 0x0F);
	// gluSphere(quad, radius, slices, stacks)
	SIG(GL_SUB_GLU_SPHERE, 4, 0x02);  // quad=ptr, radius=double, slices=int, stacks=int
	// gluCylinder(quad, base, top, height, slices, stacks)
	SIG(GL_SUB_GLU_CYLINDER, 6, 0x0E);  // quad=ptr, base=dbl, top=dbl, height=dbl, slices=int, stacks=int
	// gluDisk(quad, inner, outer, slices, loops)
	SIG(GL_SUB_GLU_DISK, 5, 0x06);  // quad=ptr, inner=dbl, outer=dbl, slices=int, loops=int
	// gluPickMatrix(x, y, delX, delY, viewport) -- 4 doubles + ptr
	SIG(GL_SUB_GLU_PICKMATRIX, 5, 0x0F);

	// GLUT functions with floats/doubles:
	// glutWireSphere(radius, slices, stacks) -- radius=double
	SIG(GL_SUB_GLUT_WIRESPHERE, 3, 0x01);
	// glutSolidSphere(radius, slices, stacks)
	SIG(GL_SUB_GLUT_SOLIDSPHERE, 3, 0x01);
	// glutWireCone(base, height, slices, stacks) -- 2 doubles
	SIG(GL_SUB_GLUT_WIRECONE, 4, 0x03);
	// glutSolidCone(base, height, slices, stacks)
	SIG(GL_SUB_GLUT_SOLIDCONE, 4, 0x03);
	// glutWireCube(size) -- 1 double
	SIG(GL_SUB_GLUT_WIRECUBE, 1, 0x01);
	// glutSolidCube(size)
	SIG(GL_SUB_GLUT_SOLIDCUBE, 1, 0x01);
	// glutWireTorus(innerRadius, outerRadius, sides, rings) -- 2 doubles
	SIG(GL_SUB_GLUT_WIRETORUS, 4, 0x03);
	// glutSolidTorus
	SIG(GL_SUB_GLUT_SOLIDTORUS, 4, 0x03);
	// glutWireTeapot(size) -- 1 double
	SIG(GL_SUB_GLUT_WIRETEAPOT, 1, 0x01);
	// glutSolidTeapot
	SIG(GL_SUB_GLUT_SOLIDTEAPOT, 1, 0x01);
	// glutSetColor(ndx, r, g, b) -- ndx=int, r/g/b=float
	SIG(GL_SUB_GLUT_SETCOLOR, 4, 0x0E);

	// Map functions with float/double args:
	// map1f(target, u1, u2, stride, order, points)
	SIG(GL_SUB_MAP1F, 6, 0x06);  // target=int, u1=float, u2=float, stride=int, order=int, points=ptr
	// map1d(target, u1, u2, stride, order, points)
	SIG(GL_SUB_MAP1D, 6, 0x06);
	// map2f(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	SIG(GL_SUB_MAP2F, 10, 0x66);  // floats at positions 1,2,5,6 = 0x66
	// map2d(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	SIG(GL_SUB_MAP2D, 10, 0x66);
	// map_grid1f(un, u1, u2) -- un=int, u1=float, u2=float
	SIG(GL_SUB_MAP_GRID1F, 3, 0x06);
	// map_grid1d(un, u1, u2)
	SIG(GL_SUB_MAP_GRID1D, 3, 0x06);
	// map_grid2f(un, u1, u2, vn, v1, v2) -- un=int, u1=float, u2=float, vn=int, v1=float, v2=float
	SIG(GL_SUB_MAP_GRID2F, 6, 0x36);  // float_mask: bits 1,2,4,5 = 0x36
	// map_grid2d(un, u1, u2, vn, v1, v2) -- same pattern with doubles
	SIG(GL_SUB_MAP_GRID2D, 6, 0x36);

	// GLU functions with float/double args (previously missing):
	// gluProject(objX, objY, objZ, model, proj, viewport, winX, winY, winZ)
	SIG(GL_SUB_GLU_PROJECT, 9, 0x07);  // doubles at positions 0,1,2
	// gluUnProject(winX, winY, winZ, model, proj, viewport, objX, objY, objZ)
	SIG(GL_SUB_GLU_UNPROJECT, 9, 0x07);
	// gluPartialDisk(quad, inner, outer, slices, loops, startAngle, sweepAngle)
	SIG(GL_SUB_GLU_PARTIALDISK, 7, 0x66);  // doubles at positions 1,2,5,6
	// gluTessProperty(tess, which, data)
	SIG(GL_SUB_GLU_TESSPROPERTY, 3, 0x04);  // double at position 2
	// gluTessNormal(tess, x, y, z)
	SIG(GL_SUB_GLU_TESSNORMAL, 4, 0x0E);  // doubles at positions 1,2,3
	// gluNurbsProperty(nurb, property, value)
	SIG(GL_SUB_GLU_NURBSPROPERTY, 3, 0x04);  // float at position 2

	#undef SIG
}

/*
 *  Initialize all GL TVECTs
 */
bool GLThunksInit(void)
{
	// Allocate scratch word
	gl_scratch_addr = SheepMem::Reserve(4);
	WriteMacInt32(gl_scratch_addr, 0);

	// Allocate dispatch-table flag word
	gl_dt_flag_addr = SheepMem::Reserve(4);
	WriteMacInt32(gl_dt_flag_addr, 0);

	// Get the native opcode for GL dispatch
	uint32 gl_opcode = NativeOpcode(NATIVE_OPENGL_DISPATCH);

	// Clear the tvects arrays
	memset(gl_method_tvects, 0, sizeof(gl_method_tvects));
	memset(gl_dt_method_tvects, 0, sizeof(gl_dt_method_tvects));

	int tvect_count = 0;

	// Core GL (0-335): 336 TVECTs (stub-patching + dispatch-table variants)
	for (int i = GL_CORE_FIRST; i <= GL_CORE_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		gl_dt_method_tvects[i] = AllocateGLDispatchTableTVECT(i, gl_opcode);
		tvect_count++;
	}

	// Extensions (400-503): 104 TVECTs
	for (int i = GL_EXT_FIRST; i <= GL_EXT_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// AGL (600-632): 33 TVECTs
	for (int i = GL_AGL_FIRST; i <= GL_AGL_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// GLU (700-753): 54 TVECTs
	for (int i = GL_GLU_FIRST; i <= GL_GLU_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// GLUT (800-915): 116 TVECTs
	for (int i = GL_GLUT_FIRST; i <= GL_GLUT_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// Initialize function signature table
	InitFuncSignatures();

	if (gl_logging_enabled) {
		printf("GLThunksInit: allocated %d TVECTs (%d bytes), scratch at 0x%08x\n",
		       tvect_count, tvect_count * 32, gl_scratch_addr);
		printf("  Core GL:    %d (sub %d-%d)\n", GL_CORE_LAST - GL_CORE_FIRST + 1, GL_CORE_FIRST, GL_CORE_LAST);
		printf("  Extensions: %d (sub %d-%d)\n", GL_EXT_LAST - GL_EXT_FIRST + 1, GL_EXT_FIRST, GL_EXT_LAST);
		printf("  AGL:        %d (sub %d-%d)\n", GL_AGL_LAST - GL_AGL_FIRST + 1, GL_AGL_FIRST, GL_AGL_LAST);
		printf("  GLU:        %d (sub %d-%d)\n", GL_GLU_LAST - GL_GLU_FIRST + 1, GL_GLU_FIRST, GL_GLU_LAST);
		printf("  GLUT:       %d (sub %d-%d)\n", GL_GLUT_LAST - GL_GLUT_FIRST + 1, GL_GLUT_FIRST, GL_GLUT_LAST);
	}

	return true;
}
