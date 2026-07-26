/*
 * OpenGL FFP Renderer for gfx gl backend.
 *
 * (C) 2026 RandoOnSteam (battlemageloveryt@gmail.com)
 */
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "gl_engine.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "gfxaccel_resources.h"
#include "display_mode_controller.h"
#include "gl_ext.h"
#include "gfxaccel_backend.h"
#include "gl_metal_draw_state.h"
#include <SDL_opengl.h>
#include "gl_ext.h"
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <limits>
#ifndef GL_RGB8
#define GL_RGB8 0x8051
#endif

static GLuint s_ov[2]={0,0}; static GLuint s_cur=0; static uint32_t s_ow=0,s_oh=0,s_wr=0;
static int32_t s_dl=0,s_dt=0,s_dw=0,s_dh=0;
static GLuint s_fbo=0,s_depth=0;
static bool s_frame_active=false;
static bool s_frame_committed=false;

/* Cache of the host GL state apply_host_ffp_state() last pushed, so a run of
 * same-state immediate-mode draws (Diablo II's OpenGL menu emits ~150
 * glBegin/glEnd sprite quads per frame, nearly all sharing blend/depth/alpha/
 * texenv state) skips the ~20 redundant glEnable/glFunc/glBind calls each
 * flush. The cache is invalidated at the start of every GL frame
 * (mark_ffp_state_dirty) because the shared compatibility context can be
 * mutated by the compositor present or another engine between our frames. */
struct FFPStateCache {
  bool valid;
  GLuint tex0; bool tex0_enabled; GLint tex0_env;
  /* NOTE: sampler state (filter/wrap) is deliberately NOT cached here. It is
   * per texture OBJECT, so a single global slot gets it wrong the moment the
   * guest alternates between two textures with different filters. It lives on
   * GLTextureObject::applied_* instead. */
  bool blend; GLenum blend_src, blend_dst;
  bool depth_test; GLenum depth_func; bool depth_mask;
  float depth_range_near, depth_range_far;
  bool color_mask[4];
  bool stencil_test; GLenum stencil_func; GLint stencil_ref;
  GLuint stencil_value_mask, stencil_write_mask;
  GLenum stencil_sfail, stencil_dpfail, stencil_dppass;
  bool cull; GLenum cull_mode, front_face;
  bool alpha_test; GLenum alpha_func; float alpha_ref;
  bool scissor; GLint scissor_box[4];
  bool lighting;
};
static FFPStateCache s_ffp_cache = {};
static void mark_ffp_state_dirty(void){ s_ffp_cache.valid = false; }

/* glClear obeys the color/depth/stencil write masks and the scissor test.
 * Those guest states are deferred until a draw in the normal FFP path, so a
 * state setter immediately followed by glClear must push this subset first.
 * Keep the same helpers in the draw path as well: write masks are independent
 * of whether their corresponding tests are enabled. */
static void apply_host_write_masks(GLContext *ctx, bool cache_ok)
{
  FFPStateCache &C = s_ffp_cache;
  const bool r = ctx->color_mask[0];
  const bool g = ctx->color_mask[1];
  const bool b = ctx->color_mask[2];
  const bool a = ctx->color_mask[3];
  const bool dm = ctx->depth_mask != 0;
  const GLuint sm = (GLuint)ctx->stencil.write_mask;

  if (!cache_ok || C.color_mask[0] != r || C.color_mask[1] != g ||
	  C.color_mask[2] != b || C.color_mask[3] != a)
	glColorMask(r ? GL_TRUE : GL_FALSE, g ? GL_TRUE : GL_FALSE,
				b ? GL_TRUE : GL_FALSE, a ? GL_TRUE : GL_FALSE);
  if (!cache_ok || C.depth_mask != dm)
	glDepthMask(dm ? GL_TRUE : GL_FALSE);
  if (!cache_ok || C.stencil_write_mask != sm)
	glStencilMask(sm);

  C.color_mask[0] = r; C.color_mask[1] = g;
  C.color_mask[2] = b; C.color_mask[3] = a;
  C.depth_mask = dm;
  C.stencil_write_mask = sm;
}

static void apply_host_scissor_state(GLContext *ctx, bool cache_ok)
{
  FFPStateCache &C = s_ffp_cache;
  if (ctx->scissor_test) {
	const bool box_same = cache_ok && C.scissor &&
	  C.scissor_box[0] == ctx->scissor_box[0] &&
	  C.scissor_box[1] == ctx->scissor_box[1] &&
	  C.scissor_box[2] == ctx->scissor_box[2] &&
	  C.scissor_box[3] == ctx->scissor_box[3];
	if (!cache_ok || !C.scissor) glEnable(GL_SCISSOR_TEST);
	if (!box_same)
	  glScissor(ctx->scissor_box[0], ctx->scissor_box[1],
				ctx->scissor_box[2], ctx->scissor_box[3]);
	C.scissor = true;
	C.scissor_box[0] = ctx->scissor_box[0];
	C.scissor_box[1] = ctx->scissor_box[1];
	C.scissor_box[2] = ctx->scissor_box[2];
	C.scissor_box[3] = ctx->scissor_box[3];
  } else {
	if (!cache_ok || C.scissor) glDisable(GL_SCISSOR_TEST);
	C.scissor = false;
  }
}

/* Guest -> host sampler-state mapping, shared by the uploader and the
 * per-draw state apply so the two can never disagree.
 *
 * Classic GL_CLAMP becomes GL_CLAMP_TO_EDGE: desktop GL_CLAMP blends in the
 * texture border colour at the edge, which is not what QuickDraw/AGL titles
 * expect and shows up as a dark fringe. Mip min-filters collapse to their base
 * because a single-level texture with a mip filter is INCOMPLETE on desktop GL
 * and samples as black. An explicit GL_NEAREST is honoured; the untouched
 * creation default (GL_NEAREST_MIPMAP_LINEAR) maps to GL_LINEAR so textures the
 * guest never configured keep their previous look. */
static GLint gl_map_guest_wrap(uint32_t w)
{
  return (w == 0x2900 /*GL_CLAMP*/ || w == GL_CLAMP_TO_EDGE)
		 ? GL_CLAMP_TO_EDGE : GL_REPEAT;
}

static GLint gl_map_guest_mag(uint32_t f)
{
  return (f == GL_NEAREST) ? GL_NEAREST : GL_LINEAR;
}

static GLint gl_map_guest_min(uint32_t f)
{
  switch (f) {
  case GL_NEAREST:
  case 0x2700 /*GL_NEAREST_MIPMAP_NEAREST*/:
	return GL_NEAREST;
  default:
	return GL_LINEAR;
  }
}

/* Invalidate only the cached unit-0 texture binding.
 *
 * Several paths in this file bind GL_TEXTURE_2D directly, outside
 * apply_host_ffp_state(): the uploaders (GLMetalUploadTexture /
 * GLMetalUploadSubTexture) bind the texture they are about to fill, and
 * GLMetalDestroyTexture deletes a name. After any of those the real GL binding
 * no longer matches C.tex0, and - because glDeleteTextures frees the name for
 * immediate reuse by the next glGenTextures - a *new* texture can even be
 * handed the id the cache still believes is bound. Either way the next
 * apply_host_ffp_state() would skip the rebind and sample the wrong texture
 * (Diablo II churns 794 glGenTextures / 407 glDeleteTextures with one texture
 * per glyph, which showed up as menu glyphs drawn with another glyph's image).
 * Dropping just the binding keeps the rest of the cache (blend/depth/alpha/...)
 * useful, since an upload does not disturb those. */
static void mark_ffp_texture_binding_dirty(void){
  s_ffp_cache.tex0 = (GLuint)~0u;
}

/* The AGL renderer and the SDL compositor share one compatibility-profile
 * context.  A VBL-driven compositor pass must not rebind framebuffer 0 or
 * replace the matrices/viewport while the guest is between its first draw
 * and aglSwapBuffers. */
extern "C" int GLFFPRenderPassActive(void)
{
  return s_frame_active ? 1 : 0;
}

static void release_overlay_textures(bool clear_drawable)
{
  auto&e=gfx_gl_ext();
  if(s_frame_active&&e.fbo)e.BindFramebuffer(GL_FRAMEBUFFER,0);
  for(int i=0;i<2;i++){
	if(s_ov[i]){
	  gfxaccel_resources_release_overlay_texture(kGfxEngineGL,(void*)(uintptr_t)s_ov[i]);
	  s_ov[i]=0;
	}
  }
  s_cur=0;s_ow=s_oh=0;s_frame_active=false;s_frame_committed=false;
  if(clear_drawable){s_dl=s_dt=s_dw=s_dh=0;}
}

extern "C" void gl_overlay_bind(int32_t left,int32_t top,int32_t width,int32_t height){
  s_dl=left;s_dt=top;s_dw=width;s_dh=height;
  if(width<=0||height<=0)return;
  uint32_t w=(uint32_t)width,h=(uint32_t)height;
  if((s_ov[0]||s_ov[1])&&(s_ow!=w||s_oh!=h)){
	release_overlay_textures(false);
  }
  if(!s_ov[0]){
	void*a=gfxaccel_resources_vend_overlay_texture_indexed(kGfxEngineGL,0,w,h,MTLPixelFormatBGRA8Unorm);
	void*b=gfxaccel_resources_vend_overlay_texture_indexed(kGfxEngineGL,1,w,h,MTLPixelFormatBGRA8Unorm);
	if(!a||!b){
	  if(a)gfxaccel_resources_release_overlay_texture(kGfxEngineGL,a);
	  if(b)gfxaccel_resources_release_overlay_texture(kGfxEngineGL,b);
	  return;
	}
	s_ov[0]=(GLuint)(uintptr_t)a;s_ov[1]=(GLuint)(uintptr_t)b;s_ow=w;s_oh=h;
  }
  s_cur=s_ov[s_wr];
  s_frame_committed=false;
}
extern "C" void gl_overlay_unbind(void){
  release_overlay_textures(true);
}
extern "C" void gl_overlay_present(void){
  if(!s_cur||!s_frame_committed)return;
  if(dmc_set_active_owner(kDMCOwnerGL)!=kDMCNoErr)return;
  if(!s_cur||!s_frame_committed)return;
  CompositeLayer L={}; L.source=(void*)(uintptr_t)s_cur; L.src_size_w=s_ow;L.src_size_h=s_oh;
  L.dst_origin_x=(float)s_dl;L.dst_origin_y=(float)s_dt;
  L.dst_size_w=(float)(s_dw>0?s_dw:(int)s_ow); L.dst_size_h=(float)(s_dh>0?s_dh:(int)s_oh);
  /*
   * An onscreen AGL drawable is an opaque window surface. Its alpha channel is
   * guest framebuffer data; classic OpenGL never uses it as window coverage.
   * The guest has already applied all texture/vertex alpha and blend factors
   * to RGB before aglSwapBuffers. Blending that completed RGB with QuickDraw
   * a second time makes framebuffer alpha reinterpret the image as a layer:
   * Quake 3's UI becomes solid atlas rectangles, while straight-alpha
   * presentation double-darkens Tomb Raider's shadow. Copy the drawable
   * opaquely, matching how an AGL back buffer reaches the screen.
   */
  L.slot=kLayerSlotOverlay; L.blend=kBlendOpaque; L.alpha=1.f;
  FrameDescriptor d={}; d.layers=&L; d.layer_count=1;
  const DMCModeSnapshot*snap=dmc_current_snapshot(); d.generation=snap?snap->generation:0;
  const int32_t rc=MetalCompositorSubmitFrame(&d);
  if(rc==kGfxAccelNoErr){s_wr^=1;s_cur=s_ov[s_wr];s_frame_committed=false;}
}
extern "C" int gl_has_active_overlay(void){return s_dw>0&&s_dh>0;}
extern "C" int gl_get_overlay_dims(uint32_t*w,uint32_t*h){if(w)*w=s_ow?s_ow:(uint32_t)s_dw;if(h)*h=s_oh?s_oh:(uint32_t)s_dh;return gl_has_active_overlay();}
extern "C" void gl_release_overlay_for_detach(void){release_overlay_textures(false);}
static void bind_ov_fbo(){
  auto&e=gfx_gl_ext(); if(!e.fbo||!s_cur)return;
  if(!s_fbo){e.GenFramebuffers(1,&s_fbo);e.GenRenderbuffers(1,&s_depth);}
  e.BindFramebuffer(GL_FRAMEBUFFER,s_fbo);
  e.FramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,s_cur,0);
  e.BindRenderbuffer(GL_RENDERBUFFER,s_depth);
  e.RenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH_COMPONENT24,(GLsizei)s_ow,(GLsizei)s_oh);
  e.FramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,s_depth);
  glViewport(0,0,(GLsizei)s_ow,(GLsizei)s_oh);
}
void GLMetalInit(GLContext*ctx){
  if(!ctx)return;
  /* Host GL draws accumulate in im_vertices and flush on glEnd. */
}
static void load_ctx_matrices(GLContext*ctx){
  if(!ctx)return;
  const float *mv=ctx->modelview_stack[ctx->modelview_depth];
  const float *proj=ctx->projection_stack[ctx->projection_depth];
  glMatrixMode(GL_PROJECTION); glLoadMatrixf(proj);
  glMatrixMode(GL_MODELVIEW); glLoadMatrixf(mv);
}
void GLMetalBeginFrame(GLContext*ctx){
  if(!ctx||!SharedMetalDevice())return;
  const DMCModeSnapshot*snap=dmc_current_snapshot();
  if(!snap||snap->active_owner!=(uint32_t)kDMCOwnerGL){
	if(dmc_set_active_owner(kDMCOwnerGL)!=kDMCNoErr)return;
  }
  /* The DMC transition releases outgoing engine textures.  A bound AGL
   * drawable remains valid across that transition, so reacquire its pair
   * before attaching the GL framebuffer. */
  if(!s_cur&&s_dw>0&&s_dh>0)gl_overlay_bind(s_dl,s_dt,s_dw,s_dh);
  if(!s_cur)return;
  if(!s_frame_active){
	bind_ov_fbo();
	s_frame_active=true;
	/* New frame on the shared context: whatever the compositor/other engine
	 * left in GL state is unknown, so the FFP state cache is stale. */
	mark_ffp_state_dirty();
  }
  load_ctx_matrices(ctx);
  if(ctx->viewport[2]>0&&ctx->viewport[3]>0)
	glViewport(ctx->viewport[0],ctx->viewport[1],ctx->viewport[2],ctx->viewport[3]);
}
void GLMetalClear(GLContext*ctx,uint32_t mask){
  if(!ctx||!SharedMetalDevice())return;
  GLMetalBeginFrame(ctx);
  if(!s_frame_active)return;
  /*
   * Keep the guest color buffer exact. Presentation opacity is a property of
   * the onscreen drawable, not a reason to premultiply or rewrite its stored
   * RGBA values. Offscreen readback and onscreen glReadPixels therefore see
   * the same OpenGL clear result.
   */
  glClearColor(ctx->clear_color[0],ctx->clear_color[1],
			   ctx->clear_color[2],ctx->clear_color[3]);
  glClearDepth(ctx->clear_depth);
  glClearStencil(ctx->clear_stencil);
  /* OpenGL clears are masked operations. In particular, Tomb Raider restores
   * glDepthMask(GL_TRUE) immediately before its depth-only clear. Without
   * synchronizing here, the host can retain GL_FALSE from the previous draw
   * and silently leave stale depth triangles in the next frame. */
  const bool cache_ok = s_ffp_cache.valid;
  apply_host_write_masks(ctx, cache_ok);
  apply_host_scissor_state(ctx, cache_ok);
  GLbitfield m=0;
  if(mask&0x4000)m|=GL_COLOR_BUFFER_BIT;
  if(mask&0x0100)m|=GL_DEPTH_BUFFER_BIT;
  if(mask&0x0400)m|=GL_STENCIL_BUFFER_BIT;
  if(!m)m=GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT;
  glClear(m);
}
void GLMetalEndFrame(GLContext*ctx){
  (void)ctx;
  if(!SharedMetalDevice()||!s_frame_active)return;
  glFlush();
  auto&e=gfx_gl_ext();
  if(e.fbo)e.BindFramebuffer(GL_FRAMEBUFFER,0);
  s_frame_active=false;
  s_frame_committed=true;
}
/* Expand GL_QUADS / fans / strips to triangle lists for host GL.
 *
 * `unit1_live` says whether texture unit 1 is actually enabled and bound for
 * this flush. When it is not (the common single-texture case - Diablo II never
 * calls glActiveTexture at all), emitting unit-1 coords is both wasted work at
 * one call per vertex and a source of stale data, since PushVertex snapshots
 * BOTH units' coords while glTexCoord2f/3f/4f only ever update unit 0. */
static void emit_gl_vertex(const GLVertex &v,bool force_opaque,bool unit1_live){
  if(force_opaque){
	const GLfloat color[4]={v.color[0],v.color[1],v.color[2],1.f};
	glColor4fv(color);
  }else{
	glColor4fv(v.color);
  }
  glNormal3fv(v.normal);
  auto &ext = gfx_gl_ext();
  if (ext.multitex && ext.MultiTexCoord4f) {
	/* Perspective-capable multitex: q=1 for FFP current coords */
	ext.MultiTexCoord4f(GL_TEXTURE0, v.texcoord[0][0], v.texcoord[0][1], v.texcoord[0][2], v.texcoord[0][3] != 0.f ? v.texcoord[0][3] : 1.f);
	if (unit1_live)
	  ext.MultiTexCoord4f(GL_TEXTURE1, v.texcoord[1][0], v.texcoord[1][1], v.texcoord[1][2], v.texcoord[1][3] != 0.f ? v.texcoord[1][3] : 1.f);
  } else if (ext.multitex && ext.MultiTexCoord2f) {
	ext.MultiTexCoord2f(GL_TEXTURE0, v.texcoord[0][0], v.texcoord[0][1]);
	if (unit1_live)
	  ext.MultiTexCoord2f(GL_TEXTURE1, v.texcoord[1][0], v.texcoord[1][1]);
  } else {
	glTexCoord4f(v.texcoord[0][0], v.texcoord[0][1], v.texcoord[0][2],
				 v.texcoord[0][3] != 0.f ? v.texcoord[0][3] : 1.f);
  }
  glVertex4fv(v.position);
}
static void flush_im_triangles(const std::vector<GLVertex> &tris,
							   bool force_opaque,bool unit1_live){
  if(tris.empty())return;
  glBegin(GL_TRIANGLES);
  for(const auto &v: tris) emit_gl_vertex(v,force_opaque,unit1_live);
  glEnd();
}
/* ---------------------------------------------------------------------------
 * [drawdump] - one complete snapshot of everything that decides a draw's colour.
 *
 * Emitted from GLMetalFlushImmediateMode, i.e. for a REAL draw with the exact
 * state that draw will use. Deliberately exhaustive: guest-side state, what we
 * resolved it to, what we actually pushed to host GL, the host's own readback,
 * and the first few post-transform vertices with their colours and texcoords.
 * Everything needed to localise a "geometry right, colour wrong" bug without
 * another round trip.
 *
 * Capped at 40 dumps, and only for draws that have texturing enabled, so the
 * log stays usable.
 * ------------------------------------------------------------------------- */
static void dump_draw_state(GLContext *ctx, const char *tag,
                            uint32_t mode, size_t nverts,
                            bool force_opaque, bool unit1_live)
{
  if (!ctx) return;

  const int u0tex = (int)ctx->tex_units[0].bound_texture_2d;
  const int u1tex = (int)ctx->tex_units[1].bound_texture_2d;
  auto it0 = ctx->texture_objects.find(ctx->tex_units[0].bound_texture_2d);
  const bool have0 = (it0 != ctx->texture_objects.end());

  /* Dump on CHANGE, not "first N draws".
   *
   * A flat first-N cap spends the whole budget on the intro screens and never
   * reaches the screen actually under investigation (Quake 3's quit menu is
   * thousands of draws in). Keying on the state that decides a draw's colour -
   * bound texture, texenv, blend, alpha test - gives one dump per distinct
   * configuration for the entire run, including late ones, while consecutive
   * identical glyph draws collapse to a single line.
   *
   * The per-signature cap stops a state that oscillates every frame from
   * flooding, and the global cap is a backstop. */
  const uint64_t sig =
      ((uint64_t)(uint32_t)u0tex << 32) ^
      ((uint64_t)(uint32_t)ctx->tex_units[0].env_mode << 20) ^
      ((uint64_t)(ctx->blend ? 1u : 0u) << 19) ^
      ((uint64_t)(uint32_t)(ctx->blend_src & 0xffff) << 3) ^
      ((uint64_t)(uint32_t)(ctx->blend_dst & 0xffff) << 1) ^
      (uint64_t)(ctx->alpha_test ? 1u : 0u);
  static uint64_t s_lastSig = ~0ull;
  static int s_repeat = 0;
  static int s_dumpCount = 0;
  if (sig == s_lastSig) {
    if (++s_repeat > 2) return;   /* a couple per state, then quiet */
  } else {
    s_lastSig = sig;
    s_repeat = 0;
  }
  if (s_dumpCount >= 600) return;
  s_dumpCount++;

  GL_LOG("[drawdump #%d %s] mode=0x%x nverts=%d forceOpaque=%d unit1Live=%d",
         s_dumpCount, tag, mode, (int)nverts, force_opaque ? 1 : 0,
         unit1_live ? 1 : 0);

  /* ---- guest texture-unit state ---- */
  GL_LOG("  unit0: enabled2d=%d bound=%d envMode=0x%04x hostTex=%u | "
         "unit1: enabled2d=%d bound=%d envMode=0x%04x",
         ctx->tex_units[0].enabled_2d ? 1 : 0, u0tex,
         ctx->tex_units[0].env_mode,
         have0 ? (unsigned)(uintptr_t)it0->second.metal_texture : 0u,
         ctx->tex_units[1].enabled_2d ? 1 : 0, u1tex,
         ctx->tex_units[1].env_mode);
  if (have0) {
    const GLTextureObject &T = it0->second;
    GL_LOG("  unit0 texobj: %dx%d srcFmt=0x%04x srcType=0x%04x mips=%d "
           "opaqueIfmt=%d min=0x%04x mag=0x%04x wrapS=0x%04x wrapT=0x%04x "
           "samplerApplied=%d appliedMin=0x%04x appliedMag=0x%04x "
           "appliedWrapS=0x%04x appliedWrapT=0x%04x",
           T.width, T.height, T.source_format, T.source_type,
           T.has_mipmaps ? 1 : 0, T.internal_format_opaque ? 1 : 0,
           T.min_filter, T.mag_filter, T.wrap_s, T.wrap_t,
           T.sampler_applied ? 1 : 0, T.applied_min, T.applied_mag,
           T.applied_wrap_s, T.applied_wrap_t);
  } else {
    GL_LOG("  unit0 texobj: <no texture object for name %d>", u0tex);
  }

  /* ---- guest fragment state ---- */
  GL_LOG("  guest: blend=%d src=0x%04x dst=0x%04x | alphaTest=%d func=0x%04x "
         "ref=%.3f | depthTest=%d func=0x%04x mask=%d | cull=%d mode=0x%04x "
         "front=0x%04x | lighting=%d | scissor=%d",
         ctx->blend ? 1 : 0, ctx->blend_src, ctx->blend_dst,
         ctx->alpha_test ? 1 : 0, ctx->alpha_func, ctx->alpha_ref,
         ctx->depth_test ? 1 : 0, ctx->depth_func, ctx->depth_mask ? 1 : 0,
         ctx->cull_face_enabled ? 1 : 0, ctx->cull_face_mode, ctx->front_face,
         ctx->lighting_enabled ? 1 : 0, ctx->scissor_test ? 1 : 0);
  GL_LOG("  guest currentColor=(%.3f,%.3f,%.3f,%.3f)",
         ctx->current_color[0], ctx->current_color[1],
         ctx->current_color[2], ctx->current_color[3]);

  /* ---- client array state (Quake 3 draws exclusively through these) ---- */
  GL_LOG("  arrays: vert{en=%d sz=%d ty=0x%04x st=%d ptr=0x%08x} "
         "color{en=%d sz=%d ty=0x%04x st=%d ptr=0x%08x} "
         "tc0{en=%d sz=%d ty=0x%04x st=%d ptr=0x%08x} "
         "tc1{en=%d sz=%d ty=0x%04x st=%d ptr=0x%08x}",
         ctx->vertex_array.enabled ? 1 : 0, ctx->vertex_array.size,
         ctx->vertex_array.type, ctx->vertex_array.stride,
         ctx->vertex_array.pointer,
         ctx->color_array.enabled ? 1 : 0, ctx->color_array.size,
         ctx->color_array.type, ctx->color_array.stride,
         ctx->color_array.pointer,
         ctx->texcoord_array[0].enabled ? 1 : 0, ctx->texcoord_array[0].size,
         ctx->texcoord_array[0].type, ctx->texcoord_array[0].stride,
         ctx->texcoord_array[0].pointer,
         ctx->texcoord_array[1].enabled ? 1 : 0, ctx->texcoord_array[1].size,
         ctx->texcoord_array[1].type, ctx->texcoord_array[1].stride,
         ctx->texcoord_array[1].pointer);

  /* ---- what host GL actually holds right now ---- */
  if (SharedMetalDevice()) {
    GLint hEnabled2D = 0, hBoundTex = 0, hEnvMode = 0;
    GLint hBlend = 0, hSrc = 0, hDst = 0, hAlphaTest = 0, hAlphaFunc = 0;
    GLint hDepthTest = 0, hMinF = 0, hMagF = 0, hWrapS = 0, hWrapT = 0;
    GLfloat hAlphaRef = 0.f, hColor[4] = {0,0,0,0};
    hEnabled2D = glIsEnabled(GL_TEXTURE_2D);
    hBlend     = glIsEnabled(GL_BLEND);
    hAlphaTest = glIsEnabled(GL_ALPHA_TEST);
    hDepthTest = glIsEnabled(GL_DEPTH_TEST);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &hBoundTex);
    glGetTexEnviv(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, &hEnvMode);
    glGetIntegerv(GL_BLEND_SRC, &hSrc);
    glGetIntegerv(GL_BLEND_DST, &hDst);
    glGetIntegerv(GL_ALPHA_TEST_FUNC, &hAlphaFunc);
    glGetFloatv(GL_ALPHA_TEST_REF, &hAlphaRef);
    glGetFloatv(GL_CURRENT_COLOR, hColor);
    if (hBoundTex) {
      glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &hMinF);
      glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &hMagF);
      glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, &hWrapS);
      glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, &hWrapT);
    }
    GL_LOG("  HOST: tex2d=%d bound=%d env=0x%04x min=0x%04x mag=0x%04x "
           "wrapS=0x%04x wrapT=0x%04x | blend=%d src=0x%04x dst=0x%04x | "
           "alphaTest=%d func=0x%04x ref=%.3f | depthTest=%d | "
           "curColor=(%.3f,%.3f,%.3f,%.3f) glErr=0x%04x",
           hEnabled2D, hBoundTex, hEnvMode, hMinF, hMagF, hWrapS, hWrapT,
           hBlend, hSrc, hDst, hAlphaTest, hAlphaFunc, hAlphaRef, hDepthTest,
           hColor[0], hColor[1], hColor[2], hColor[3], glGetError());
    /* Host-side confirmation that the bound level-0 image really has alpha,
     * i.e. that the transparency survived all the way into the GL object. */
    if (hBoundTex) {
      GLint iw = 0, ih = 0, ifmt = 0, asize = 0;
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &iw);
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &ih);
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &ifmt);
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_ALPHA_SIZE, &asize);
      GL_LOG("  HOST level0: %dx%d internalFormat=0x%04x alphaBits=%d",
             iw, ih, ifmt, asize);
    }
  }

  /* ---- the vertices we are about to emit ---- */
  const size_t show = ctx->im_vertices.size() < 4 ? ctx->im_vertices.size() : 4;
  for (size_t i = 0; i < show; i++) {
    const GLVertex &v = ctx->im_vertices[i];
    GL_LOG("  v[%d] pos=(%.2f,%.2f,%.2f,%.2f) col=(%.3f,%.3f,%.3f,%.3f) "
           "tc0=(%.4f,%.4f,%.4f,%.4f) tc1=(%.4f,%.4f,%.4f,%.4f)",
           (int)i, v.position[0], v.position[1], v.position[2], v.position[3],
           v.color[0], v.color[1], v.color[2], v.color[3],
           v.texcoord[0][0], v.texcoord[0][1], v.texcoord[0][2], v.texcoord[0][3],
           v.texcoord[1][0], v.texcoord[1][1], v.texcoord[1][2], v.texcoord[1][3]);
  }
}

static void apply_host_ffp_state(GLContext *ctx)
{
  if (!ctx) return;
  load_ctx_matrices(ctx);

  FFPStateCache &C = s_ffp_cache;
  const bool cache_ok = C.valid;

  /* Texture unit 0 */
  auto it = ctx->texture_objects.find(ctx->tex_units[0].bound_texture_2d);
  if (ctx->tex_units[0].enabled_2d && it != ctx->texture_objects.end() && it->second.metal_texture) {
	const GLuint tex = (GLuint)(uintptr_t)it->second.metal_texture;
	GLint env = GL_MODULATE;
	switch (ctx->tex_units[0].env_mode) {
	case 0x1E01: env = GL_REPLACE; break;
	case 0x2100: env = GL_MODULATE; break;
	case 0x2101: env = GL_DECAL; break;
	case 0x0BE2: env = GL_BLEND; break;
	default: break;
	}
	if (!cache_ok || !C.tex0_enabled) glEnable(GL_TEXTURE_2D);

	const bool rebound = (!cache_ok || C.tex0 != tex);
	if (rebound) glBindTexture(GL_TEXTURE_2D, tex);

	/* Apply the guest's per-texture filter/wrap. These were stored on the
	 * texture object by glTexParameteri/f but never pushed to the host GL
	 * texture, so every texture rendered with the hard-coded LINEAR set at
	 * upload plus the default REPEAT. Map the classic GL_CLAMP to
	 * GL_CLAMP_TO_EDGE (desktop GL_CLAMP samples the border colour, which is
	 * not what QuickDraw/AGL titles expect) and collapse mipmap min-filters to
	 * their base so a single-level texture is not left incomplete (which
	 * desktop GL renders as black).
	 *
	 * This is re-evaluated on every flush, not only on a rebind: the guest can
	 * retune parameters on an already-bound texture, and GLMetalUploadTexture
	 * unconditionally resets both filters to GL_LINEAR when it refills a
	 * texture. Comparing against the last-pushed values keeps it to zero GL
	 * calls in the common steady state. */
	const GLint magf = gl_map_guest_mag(it->second.mag_filter);
	const GLint minf = gl_map_guest_min(it->second.min_filter);
	const GLint ws   = gl_map_guest_wrap(it->second.wrap_s);
	const GLint wt   = gl_map_guest_wrap(it->second.wrap_t);

	/* Sampler state is PER TEXTURE OBJECT, so it cannot be cached in a single
	 * global slot the way the other FFP state can: after binding texture B and
	 * pushing its filters, binding A again would compare against B's values and
	 * skip the push, leaving A sampled with B's filters. Track the values on
	 * the texture object itself (applied_* mirror what we last pushed to that
	 * object) and re-push whenever the desired state differs from that
	 * object's own last-applied state. Still zero GL calls in the steady state,
	 * but correct across texture switches - which Diablo II does constantly,
	 * one texture per glyph. */
	GLTextureObject &TO = it->second;
	if (!TO.sampler_applied || TO.applied_mag != (uint32_t)magf) {
	  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magf);
	  TO.applied_mag = (uint32_t)magf;
	}
	if (!TO.sampler_applied || TO.applied_min != (uint32_t)minf) {
	  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minf);
	  TO.applied_min = (uint32_t)minf;
	}
	if (!TO.sampler_applied || TO.applied_wrap_s != (uint32_t)ws) {
	  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, ws);
	  TO.applied_wrap_s = (uint32_t)ws;
	}
	if (!TO.sampler_applied || TO.applied_wrap_t != (uint32_t)wt) {
	  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wt);
	  TO.applied_wrap_t = (uint32_t)wt;
	}
	TO.sampler_applied = true;

	if (!cache_ok || C.tex0_env != env)
	  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, env);
	C.tex0_enabled = true; C.tex0 = tex; C.tex0_env = env;
  } else {
	if (!cache_ok || C.tex0_enabled) glDisable(GL_TEXTURE_2D);
	C.tex0_enabled = false;
  }

  /* Texture unit 1 (ARB multitexture) when present */
  auto &ext = gfx_gl_ext();
  if (ext.multitex && ext.ActiveTexture) {
	ext.ActiveTexture(GL_TEXTURE1);
	auto it1 = ctx->texture_objects.find(ctx->tex_units[1].bound_texture_2d);
	if (ctx->tex_units[1].enabled_2d && it1 != ctx->texture_objects.end() && it1->second.metal_texture) {
	  glEnable(GL_TEXTURE_2D);
	  glBindTexture(GL_TEXTURE_2D, (GLuint)(uintptr_t)it1->second.metal_texture);
	  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
	} else {
	  glDisable(GL_TEXTURE_2D);
	}
	ext.ActiveTexture(GL_TEXTURE0);
  }

  if (ctx->blend) {
	/* Pass the guest's factors through verbatim.
	 *
	 * These used to be `ctx->blend_src ? ctx->blend_src : GL_SRC_ALPHA`, but
	 * GL_ZERO IS 0 - so a perfectly valid glBlendFunc(GL_ZERO, ...) was read as
	 * "unset" and silently replaced with GL_SRC_ALPHA. Diablo II's menu text
	 * uses glBlendFunc(GL_ZERO, GL_SRC_ALPHA) (372 of its 649 blend calls in a
	 * menu capture): a destination-masking blend that multiplies what is
	 * already in the framebuffer by the glyph's alpha. Substituting
	 * GL_SRC_ALPHA turned that into an additive-style blend, so each glyph
	 * brightened its neighbours instead of masking them - and because the
	 * glyph quads are 64px wide but advance only 6-10px (~85% overlap), every
	 * letter smeared across the next one. That is the "extra strokes through
	 * the middle" artifact (O -> +, G -> G-with-bar, M -> ffl).
	 *
	 * No fallback is needed: GLContext is initialised with the GL defaults
	 * (blend_src = GL_ONE, blend_dst = GL_ZERO), so these are always valid. */
	const GLenum bs = (GLenum)ctx->blend_src;
	const GLenum bd = (GLenum)ctx->blend_dst;
	if (!cache_ok || !C.blend) glEnable(GL_BLEND);
	if (!cache_ok || C.blend_src != bs || C.blend_dst != bd)
	  glBlendFunc(bs, bd);
	C.blend = true; C.blend_src = bs; C.blend_dst = bd;
  } else {
	if (!cache_ok || C.blend) glDisable(GL_BLEND);
	C.blend = false;
  }
  apply_host_write_masks(ctx, cache_ok);
  if (!cache_ok || C.depth_range_near != ctx->depth_range_near ||
	  C.depth_range_far != ctx->depth_range_far) {
	glDepthRange((GLclampd)ctx->depth_range_near,
				 (GLclampd)ctx->depth_range_far);
	C.depth_range_near = ctx->depth_range_near;
	C.depth_range_far = ctx->depth_range_far;
  }
  if (ctx->depth_test) {
	const GLenum df = ctx->depth_func ? ctx->depth_func : GL_LESS;
	if (!cache_ok || !C.depth_test) glEnable(GL_DEPTH_TEST);
	if (!cache_ok || C.depth_func != df) glDepthFunc(df);
	C.depth_test = true; C.depth_func = df;
  } else {
	if (!cache_ok || C.depth_test) glDisable(GL_DEPTH_TEST);
	C.depth_test = false;
  }
  if (ctx->stencil_test) {
	const GLenum sf = (GLenum)ctx->stencil.func;
	const GLint sr = (GLint)ctx->stencil.ref;
	const GLuint svm = (GLuint)ctx->stencil.value_mask;
	const GLenum fail = (GLenum)ctx->stencil.sfail;
	const GLenum zfail = (GLenum)ctx->stencil.dpfail;
	const GLenum zpass = (GLenum)ctx->stencil.dppass;
	if (!cache_ok || !C.stencil_test) glEnable(GL_STENCIL_TEST);
	if (!cache_ok || C.stencil_func != sf || C.stencil_ref != sr ||
		C.stencil_value_mask != svm)
	  glStencilFunc(sf, sr, svm);
	if (!cache_ok || C.stencil_sfail != fail ||
		C.stencil_dpfail != zfail || C.stencil_dppass != zpass)
	  glStencilOp(fail, zfail, zpass);
	C.stencil_test = true;
	C.stencil_func = sf; C.stencil_ref = sr; C.stencil_value_mask = svm;
	C.stencil_sfail = fail; C.stencil_dpfail = zfail;
	C.stencil_dppass = zpass;
  } else {
	if (!cache_ok || C.stencil_test) glDisable(GL_STENCIL_TEST);
	C.stencil_test = false;
  }
  if (ctx->cull_face_enabled) {
	const GLenum cm = ctx->cull_face_mode ? ctx->cull_face_mode : GL_BACK;
	const GLenum ff = ctx->front_face ? ctx->front_face : GL_CCW;
	if (!cache_ok || !C.cull) glEnable(GL_CULL_FACE);
	if (!cache_ok || C.cull_mode != cm) glCullFace(cm);
	if (!cache_ok || C.front_face != ff) glFrontFace(ff);
	C.cull = true; C.cull_mode = cm; C.front_face = ff;
  } else {
	if (!cache_ok || C.cull) glDisable(GL_CULL_FACE);
	C.cull = false;
  }
  if (ctx->alpha_test) {
	const GLenum af = ctx->alpha_func ? ctx->alpha_func : GL_ALWAYS;
	if (!cache_ok || !C.alpha_test) glEnable(GL_ALPHA_TEST);
	if (!cache_ok || C.alpha_func != af || C.alpha_ref != ctx->alpha_ref)
	  glAlphaFunc(af, ctx->alpha_ref);
	C.alpha_test = true; C.alpha_func = af; C.alpha_ref = ctx->alpha_ref;
  } else {
	if (!cache_ok || C.alpha_test) glDisable(GL_ALPHA_TEST);
	C.alpha_test = false;
  }
  apply_host_scissor_state(ctx, cache_ok);
  if (ctx->fog_enabled) {
	glEnable(GL_FOG);
	glFogi(GL_FOG_MODE, (GLint)(ctx->fog_mode ? ctx->fog_mode : GL_LINEAR));
	glFogfv(GL_FOG_COLOR, ctx->fog_color);
	glFogf(GL_FOG_DENSITY, ctx->fog_density);
	glFogf(GL_FOG_START, ctx->fog_start);
	glFogf(GL_FOG_END, ctx->fog_end);
  } else {
	glDisable(GL_FOG);
  }
  if (ctx->normalize) glEnable(GL_NORMALIZE); else glDisable(GL_NORMALIZE);

  /* Fixed-function lighting mirrored to host GL. The common 2D-UI case has
   * lighting disabled every flush; cache that so we skip the redundant
   * glDisable(GL_LIGHTING) on a run of unlit sprite draws. When lighting IS
   * on, always re-push the full light/material state (uncached). */
  if (!ctx->lighting_enabled) {
	if (!cache_ok || C.lighting) glDisable(GL_LIGHTING);
	C.lighting = false;
	C.valid = true;
	return;
  }
  C.lighting = true;
  C.valid = true;
  {
	glEnable(GL_LIGHTING);
	glLightModelfv(GL_LIGHT_MODEL_AMBIENT, ctx->light_model_ambient);
	glLightModeli(GL_LIGHT_MODEL_TWO_SIDE, ctx->light_model_two_side ? 1 : 0);
	glLightModeli(GL_LIGHT_MODEL_LOCAL_VIEWER, ctx->light_model_local_viewer ? 1 : 0);
	for (int i = 0; i < 8; i++) {
	  GLenum L = GL_LIGHT0 + i;
	  if (ctx->lights[i].enabled) {
		glEnable(L);
		glLightfv(L, GL_AMBIENT, ctx->lights[i].ambient);
		glLightfv(L, GL_DIFFUSE, ctx->lights[i].diffuse);
		glLightfv(L, GL_SPECULAR, ctx->lights[i].specular);
		glLightfv(L, GL_POSITION, ctx->lights[i].position);
		glLightfv(L, GL_SPOT_DIRECTION, ctx->lights[i].spot_direction);
		glLightf(L, GL_SPOT_EXPONENT, ctx->lights[i].spot_exponent);
		glLightf(L, GL_SPOT_CUTOFF, ctx->lights[i].spot_cutoff);
		glLightf(L, GL_CONSTANT_ATTENUATION, ctx->lights[i].constant_attenuation);
		glLightf(L, GL_LINEAR_ATTENUATION, ctx->lights[i].linear_attenuation);
		glLightf(L, GL_QUADRATIC_ATTENUATION, ctx->lights[i].quadratic_attenuation);
	  } else {
		glDisable(L);
	  }
	}
	glMaterialfv(GL_FRONT_AND_BACK, GL_AMBIENT, ctx->materials[0].ambient);
	glMaterialfv(GL_FRONT_AND_BACK, GL_DIFFUSE, ctx->materials[0].diffuse);
	glMaterialfv(GL_FRONT_AND_BACK, GL_SPECULAR, ctx->materials[0].specular);
	glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, ctx->materials[0].emission);
	glMaterialf(GL_FRONT_AND_BACK, GL_SHININESS, ctx->materials[0].shininess);
	if (ctx->color_material_enabled) {
	  glEnable(GL_COLOR_MATERIAL);
	  glColorMaterial(ctx->color_material_face ? ctx->color_material_face : GL_FRONT_AND_BACK,
					  ctx->color_material_mode ? ctx->color_material_mode : GL_AMBIENT_AND_DIFFUSE);
	} else {
	  glDisable(GL_COLOR_MATERIAL);
	}
  }
}

void GLMetalFlushImmediateMode(GLContext*ctx){
  if(!ctx||!SharedMetalDevice()||ctx->im_vertices.empty())return;
  GLMetalBeginFrame(ctx);
  if(!s_frame_active)return;
  apply_host_ffp_state(ctx);
  /*
   * Preserve guest vertex alpha even for unblended draws. The onscreen
   * drawable is made opaque only when submitted to the compositor; modifying
   * fragment alpha here corrupts glReadPixels and later guest blending.
   */
  const bool force_opaque=false;
  /* Mirror the unit-1 test apply_host_ffp_state() uses to decide whether it
   * enables and binds texture unit 1; when that is false the unit is disabled,
   * so per-vertex unit-1 coords are dead weight. */
  const auto it1=ctx->texture_objects.find(ctx->tex_units[1].bound_texture_2d);
  const bool unit1_live=
	gfx_gl_ext().multitex && ctx->tex_units[1].enabled_2d &&
	it1!=ctx->texture_objects.end() && it1->second.metal_texture!=nullptr;

  const auto &in=ctx->im_vertices;
  const uint32_t mode=ctx->im_mode;

  /* Full state snapshot for this draw - see dump_draw_state. Runs AFTER
   * apply_host_ffp_state so the host readback reflects what this draw will
   * really use. Only textured draws are interesting for the colour bugs. */
  if (ctx->tex_units[0].enabled_2d)
    dump_draw_state(ctx, "flush", mode, in.size(), force_opaque, unit1_live);

  std::vector<GLVertex> out;
  if(mode==0x0007 /*GL_QUADS*/ && in.size()>=4){
	for(size_t i=0;i+3<in.size();i+=4){
	  out.push_back(in[i]); out.push_back(in[i+1]); out.push_back(in[i+2]);
	  out.push_back(in[i]); out.push_back(in[i+2]); out.push_back(in[i+3]);
	}
	flush_im_triangles(out,force_opaque,unit1_live);
  } else if(mode==0x0006 /*GL_TRIANGLE_FAN*/ && in.size()>=3){
	for(size_t i=1;i+1<in.size();i++){
	  out.push_back(in[0]); out.push_back(in[i]); out.push_back(in[i+1]);
	}
	flush_im_triangles(out,force_opaque,unit1_live);
  } else if(mode==0x0005 /*GL_TRIANGLE_STRIP*/ && in.size()>=3){
	for(size_t i=0;i+2<in.size();i++){
	  if(i&1){ out.push_back(in[i+1]); out.push_back(in[i]); out.push_back(in[i+2]); }
	  else { out.push_back(in[i]); out.push_back(in[i+1]); out.push_back(in[i+2]); }
	}
	flush_im_triangles(out,force_opaque,unit1_live);
  } else if(mode==0x0001 /*GL_LINES*/ || mode==0x0003 /*GL_LINE_STRIP*/ || mode==0x0002 /*GL_LINE_LOOP*/){
	GLenum m = (mode==0x0001)?GL_LINES:(mode==0x0002)?GL_LINE_LOOP:GL_LINE_STRIP;
	glBegin(m); for(const auto&v:in) emit_gl_vertex(v,force_opaque,unit1_live); glEnd();
  } else if(mode==0x0000 /*GL_POINTS*/){
	glBegin(GL_POINTS); for(const auto&v:in) emit_gl_vertex(v,force_opaque,unit1_live); glEnd();
  } else {
	/* GL_TRIANGLES and default */
	flush_im_triangles(in,force_opaque,unit1_live);
  }
  ctx->im_vertices.clear();
}
void GLMetalRelease(GLContext*ctx){(void)ctx;}
void GLMetalUploadTexture(GLContext*ctx,GLTextureObject*texObj,int level,int width,int height,const uint8_t*pixels,int data_len){
  (void)ctx;(void)data_len; if(!texObj||!SharedMetalDevice())return;
  GLuint id=(GLuint)(uintptr_t)texObj->metal_texture; if(!id){ glGenTextures(1,&id); texObj->metal_texture=(void*)(uintptr_t)id; }

  glBindTexture(GL_TEXTURE_2D,id);
  /* Apply the guest's OWN sampler state, not a hard-coded GL_LINEAR.
   *
   * This used to force MIN/MAG = GL_LINEAR on every upload. Diablo II asks for
   * GL_NEAREST + GL_CLAMP on its menu-font glyphs, and it re-uploads those
   * textures constantly, so the forced LINEAR kept winning: each glyph is drawn
   * as a 64px quad advancing only 6-10px (letters overlap ~85%), and linear
   * filtering samples beyond the glyph's few ink columns into the neighbouring
   * letter's footprint - the "extra strokes through the middle" artifact
   * (O -> +, G -> G-with-bar). The texture data itself is fine: the padding
   * around every glyph measures alpha 0x00.
   *
   * Mapping matches apply_host_ffp_state(): classic GL_CLAMP -> CLAMP_TO_EDGE
   * (desktop GL_CLAMP samples the border colour), and mip min-filters collapse
   * to their base so a single-level texture is not incomplete (-> black). */
  {
	const GLint minf = gl_map_guest_min(texObj->min_filter);
	const GLint magf = gl_map_guest_mag(texObj->mag_filter);
	const GLint ws   = gl_map_guest_wrap(texObj->wrap_s);
	const GLint wt   = gl_map_guest_wrap(texObj->wrap_t);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,minf);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,magf);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,ws);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,wt);
	/* Record what the host object now holds so the per-draw apply agrees. */
	texObj->applied_min=(uint32_t)minf; texObj->applied_mag=(uint32_t)magf;
	texObj->applied_wrap_s=(uint32_t)ws; texObj->applied_wrap_t=(uint32_t)wt;
	texObj->sampler_applied=true;
  }
  /* Honour the guest's requested internal format instead of always allocating
   * RGBA8. When the guest asked for an alpha-less format (GL_RGB / the legacy
   * component count 3), allocating RGBA8 means the texture HAS an alpha
   * channel, and whatever alpha the supplied pixels carried becomes live -
   * GL guarantees such a texture samples alpha = 1.0. Asking the driver for
   * GL_RGB8 makes that guarantee structural (host alphaBits = 0) rather than
   * relying on the upload buffer having been scrubbed. */
  if(pixels) glTexImage2D(GL_TEXTURE_2D,level,
                          texObj->internal_format_opaque ? GL_RGB8 : GL_RGBA8,
                          width,height,0,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
  mark_ffp_texture_binding_dirty();
}
void GLMetalUploadTexture(GLContext*ctx,GLTextureObject*texObj,int level,int width,int height,int format,int type,const void*pixels){
  (void)format;(void)type; GLMetalUploadTexture(ctx,texObj,level,width,height,(const uint8_t*)pixels,0);
}
void GLMetalUploadSubTexture(GLContext*ctx,GLTextureObject*texObj,int level,int xoff,int yoff,int width,int height,const uint8_t*pixels,int data_len){
  (void)ctx;(void)data_len; if(!texObj||!texObj->metal_texture||!pixels||!SharedMetalDevice())return;
  glBindTexture(GL_TEXTURE_2D,(GLuint)(uintptr_t)texObj->metal_texture);
  glTexSubImage2D(GL_TEXTURE_2D,level,xoff,yoff,width,height,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
  mark_ffp_texture_binding_dirty();
}
#ifndef GL_TEXTURE_3D
#define GL_TEXTURE_3D 0x806F
#endif
void GLMetalUpload3DTexture(GLContext*ctx,GLTextureObject*texObj,int level,int width,int height,int depth,const uint8_t*pixels,int data_len){
  (void)ctx;(void)data_len;
  if(!texObj||!SharedMetalDevice())return;
  GLuint id=(GLuint)(uintptr_t)texObj->metal_texture;
  if(!id){ glGenTextures(1,&id); texObj->metal_texture=(void*)(uintptr_t)id; }
  glBindTexture(GL_TEXTURE_3D,id);
  glTexParameteri(GL_TEXTURE_3D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
  glTexParameteri(GL_TEXTURE_3D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
  typedef void (APIENTRY *PFNGLTEXIMAGE3DPROC)(GLenum,GLint,GLint,GLsizei,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*);
  static PFNGLTEXIMAGE3DPROC pTexImage3D=nullptr; static bool tried=false;
  if(!tried){ tried=true; pTexImage3D=(PFNGLTEXIMAGE3DPROC)SDL_GL_GetProcAddress("glTexImage3D");
	if(!pTexImage3D) pTexImage3D=(PFNGLTEXIMAGE3DPROC)SDL_GL_GetProcAddress("glTexImage3DEXT"); }
  if(pTexImage3D && pixels)
	pTexImage3D(GL_TEXTURE_3D,level,GL_RGBA8,width,height,depth,0,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
  texObj->width=width; texObj->height=height;
}
void GLMetalUploadSubTexture3D(GLContext*ctx,GLTextureObject*texObj,int level,int xoff,int yoff,int zoff,int width,int height,int depth,const uint8_t*pixels,int data_len,int){
  (void)ctx;(void)data_len;
  if(!texObj||!texObj->metal_texture||!pixels||!SharedMetalDevice())return;
  typedef void (APIENTRY *PFNGLTEXSUBIMAGE3DPROC)(GLenum,GLint,GLint,GLint,GLint,GLsizei,GLsizei,GLsizei,GLenum,GLenum,const void*);
  static PFNGLTEXSUBIMAGE3DPROC pSub=nullptr; static bool tried=false;
  if(!tried){ tried=true; pSub=(PFNGLTEXSUBIMAGE3DPROC)SDL_GL_GetProcAddress("glTexSubImage3D");
	if(!pSub) pSub=(PFNGLTEXSUBIMAGE3DPROC)SDL_GL_GetProcAddress("glTexSubImage3DEXT"); }
  if(!pSub)return;
  glBindTexture(GL_TEXTURE_3D,(GLuint)(uintptr_t)texObj->metal_texture);
  pSub(GL_TEXTURE_3D,level,xoff,yoff,zoff,width,height,depth,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
}
void GLMetalDestroyTexture(GLTextureObject*texObj){
  if(!texObj||!texObj->metal_texture||!SharedMetalDevice())return;
  GLuint id=(GLuint)(uintptr_t)texObj->metal_texture;
  glDeleteTextures(1,&id); texObj->metal_texture=nullptr;
  /* The name is now free for reuse by the next glGenTextures, so a later
   * texture can be handed this same id. Drop the cached binding or the rebind
   * for that new texture would be skipped as a no-op. */
  mark_ffp_texture_binding_dirty();
}
void GLMetalDrawPixels(GLContext*ctx,int width,int height,const uint8_t*pixels,int data_len){
  (void)data_len; if(!ctx||!pixels||!SharedMetalDevice())return;
  GLMetalBeginFrame(ctx);
  if(!s_frame_active)return;
  apply_host_ffp_state(ctx);
  glRasterPos2i(0,0);
  glDrawPixels(width,height,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
}
void GLMetalBitmap(GLContext*ctx,int width,int height,const uint8_t*bits,int data_len){
  (void)data_len; if(!ctx||!bits||!SharedMetalDevice())return;
  GLMetalBeginFrame(ctx);
  if(!s_frame_active)return;
  apply_host_ffp_state(ctx);
  glRasterPos2i(0,0);
  glBitmap(width,height,0,0,0,0,bits);
}
uint8_t* GLMetalReadFramebufferRect(GLContext*ctx,int x,int y,int w,int h,int*out_len){
  if(out_len)*out_len=0;
  if(!ctx||x<0||y<0||w<=0||h<=0)return nullptr;
  const int fbw=s_ow?(int)s_ow:ctx->viewport[2];
  const int fbh=s_oh?(int)s_oh:ctx->viewport[3];
  if(fbw<=0||fbh<=0||x>fbw-w||y>fbh-h)return nullptr;
  const size_t sw=(size_t)w, sh=(size_t)h;
  if(sw>std::numeric_limits<size_t>::max()/4/sh)return nullptr;
  const size_t bytes=sw*sh*4;
  if(bytes>(size_t)std::numeric_limits<int>::max())return nullptr;
  if(!SharedMetalDevice())return nullptr;
  uint8_t*p=(uint8_t*)std::malloc(bytes);
  if(!p)return nullptr;
  glReadPixels(x,y,w,h,GL_BGRA,GL_UNSIGNED_BYTE,p);
  if(out_len)*out_len=(int)bytes;
  return p;
}

/* Latest offscreen readback cache for NQD/GL bridge */
struct GLOffscreenLatest {
  bool valid=false;
  uint32_t baseaddr=0, rowbytes=0, width=0, height=0, bpp=4;
  std::vector<uint8_t> pixels; /* tightly packed BGRA host copy */
};
static GLOffscreenLatest s_off_latest;

static void gl_capture_offscreen_to_cache(void)
{
  if(!s_cur||!s_ow||!s_oh||!SharedMetalDevice())return;
  auto&e=gfx_gl_ext();
  if(e.fbo&&s_fbo) e.BindFramebuffer(GL_FRAMEBUFFER,s_fbo);
  s_off_latest.pixels.resize((size_t)s_ow*s_oh*4);
  glReadPixels(0,0,(GLsizei)s_ow,(GLsizei)s_oh,GL_BGRA,GL_UNSIGNED_BYTE,s_off_latest.pixels.data());
  if(e.fbo) e.BindFramebuffer(GL_FRAMEBUFFER,0);
  s_off_latest.valid=true;
  s_off_latest.width=s_ow; s_off_latest.height=s_oh; s_off_latest.bpp=4;
  s_off_latest.rowbytes=s_ow*4;
}

static uint64_t gl_composite_offscreen_to_guest(uint32_t dstBase, uint32_t dstRowBytes, uint32_t dstDepthBits,
												int32_t dx, int32_t dy, int32_t dw, int32_t dh)
{
  if(!s_off_latest.valid || s_off_latest.pixels.empty() || !dstBase || !dstRowBytes) return 0;
  uint8_t *dst = Mac2HostAddr(dstBase);
  if(!dst) return 0;
  int bpp = (dstDepthBits<=8)?1:(dstDepthBits<=16)?2:4;
  int32_t sw=(int32_t)s_off_latest.width, sh=(int32_t)s_off_latest.height;
  if(dw<=0) dw=sw; if(dh<=0) dh=sh;
  if(dx<0){ dw+=dx; dx=0; } if(dy<0){ dh+=dy; dy=0; }
  if(dx>=sw||dy>=sh||dw<=0||dh<=0) return 0;
  if(dx+dw>sw) dw=sw-dx; if(dy+dh>sh) dh=sh-dy;
  if((uint64_t)(dx+dw)*(uint64_t)bpp>(uint64_t)dstRowBytes) return 0;
  const uint64_t guestBegin=(uint64_t)dstBase+(uint64_t)dy*dstRowBytes+(uint64_t)dx*bpp;
  const uint64_t guestSpan=(uint64_t)(dh-1)*dstRowBytes+(uint64_t)dw*bpp;
  const uint64_t ramBegin=(uint64_t)RAMBase, ramEnd=ramBegin+(uint64_t)RAMSize;
  if(guestBegin<ramBegin||guestBegin>=ramEnd||guestSpan>ramEnd-guestBegin)return 0;
  uint64_t written=0;
  for(int32_t y=0;y<dh;y++){
	const uint8_t *srow = s_off_latest.pixels.data() + (size_t)(dy+y)*s_off_latest.rowbytes + (size_t)dx*4;
	uint8_t *drow = dst + (size_t)(dy+y)*(size_t)dstRowBytes + (size_t)dx*(size_t)bpp;
	for(int32_t x=0;x<dw;x++){
	  uint8_t B=srow[x*4+0], G=srow[x*4+1], R=srow[x*4+2], A=srow[x*4+3];
	  if(A==0) continue; /* transparent: leave guest pixel */
	  if(bpp==4){
		/* Guest BE ARGB */
		drow[x*4+0]=A; drow[x*4+1]=R; drow[x*4+2]=G; drow[x*4+3]=B;
	  } else if(bpp==2){
		uint16_t p=(uint16_t)(0x8000|((R>>3)<<10)|((G>>3)<<5)|(B>>3));
		drow[x*2]=(uint8_t)(p>>8); drow[x*2+1]=(uint8_t)p;
	  } else {
		drow[x]=(uint8_t)((R*30+G*59+B*11)/100);
	  }
	  written++;
	}
  }
  return written;
}

extern "C" uint64_t GLCompositeLatestOffscreenToGuestSurfaceUsingLatestExtentDirtyRect(
  uint32_t dstBase, uint32_t dstRowBytes, uint32_t dstDepthBits,
  int32_t dirtyX, int32_t dirtyY, int32_t dirtyW, int32_t dirtyH)
{
  gl_capture_offscreen_to_cache();
  return gl_composite_offscreen_to_guest(dstBase,dstRowBytes,dstDepthBits,dirtyX,dirtyY,dirtyW,dirtyH);
}
extern "C" uint64_t GLCompositeLatestOffscreenToGuestSurfaceUsingLatestExtentIfNotSuppressed(
  uint32_t dstBase, uint32_t dstRowBytes, uint32_t dstDepthBits)
{
  gl_capture_offscreen_to_cache();
  return gl_composite_offscreen_to_guest(dstBase,dstRowBytes,dstDepthBits,0,0,(int32_t)s_off_latest.width,(int32_t)s_off_latest.height);
}
extern "C" bool NQDReadMainDevicePixMapForGLBridge(uint32_t *base, int32_t *rb, int32_t *l, int32_t *t, int32_t *r, uint32_t *ps)
{
  /* MainDevice gdPMap chain - same lowmem as NQD OpColor path */
  uint32 gdevH = ReadMacInt32(0x8A4);
  if(!gdevH) return false;
  uint32 gdev = ReadMacInt32(gdevH);
  if(!gdev) return false;
  uint32 pmH = ReadMacInt32(gdev + 0x16);
  if(!pmH) return false;
  uint32 pm = ReadMacInt32(pmH);
  if(!pm) return false;
  if(base) *base = ReadMacInt32(pm + 0);
  if(rb) *rb = (int32_t)(ReadMacInt16(pm + 4) & 0x7FFF);
  if(t) *t = (int16)ReadMacInt16(pm + 6);
  if(l) *l = (int16)ReadMacInt16(pm + 8);
  if(r) *r = (int16)ReadMacInt16(pm + 12);
  if(ps) *ps = (uint32_t)ReadMacInt16(pm + 32); /* real PixMap pixelSize */
  return base && *base != 0;
}
/* Vertex/color IM helpers unique to metal renderer */
static void PushVertex(GLContext*ctx,float x,float y,float z,float w){
  if(!ctx||!ctx->in_begin)return;
  GLVertex v={}; v.position[0]=x;v.position[1]=y;v.position[2]=z;v.position[3]=w;
  memcpy(v.color,ctx->current_color,sizeof(v.color));
  memcpy(v.normal,ctx->current_normal,sizeof(v.normal));
  memcpy(v.texcoord,ctx->current_texcoord,sizeof(v.texcoord));
  ctx->im_vertices.push_back(v);
}
void NativeGLBegin(GLContext*ctx,uint32_t mode){
  if(!ctx)return;
  ctx->in_begin=true; ctx->im_mode=mode; ctx->im_vertices.clear();
}
void NativeGLEnd(GLContext*ctx){
  if(!ctx)return;
  ctx->in_begin=false;
  GLMetalFlushImmediateMode(ctx);
}
void NativeGLFinish(GLContext*ctx){(void)ctx; if(SharedMetalDevice()) glFinish();}
void NativeGLFlush(GLContext*ctx){(void)ctx; if(SharedMetalDevice()) glFlush();}
void NativeGLAccum(GLContext*c,uint32_t op,float val){
  (void)c; if(!SharedMetalDevice())return;
  glAccum((GLenum)op,val);
}
/* ---- Client vertex arrays (DrawArrays / DrawElements / ArrayElement) ---- */
#ifndef GL_FLOAT
#define GL_BYTE 0x1400
#define GL_UNSIGNED_BYTE 0x1401
#define GL_SHORT 0x1402
#define GL_UNSIGNED_SHORT 0x1403
#define GL_INT 0x1404
#define GL_UNSIGNED_INT 0x1405
#define GL_FLOAT 0x1406
#define GL_DOUBLE 0x140A
#endif

static int gl_type_size(uint32_t type){
  switch(type){
  case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
  case GL_SHORT: case GL_UNSIGNED_SHORT: return 2;
  case GL_INT: case GL_UNSIGNED_INT: case GL_FLOAT: return 4;
  case GL_DOUBLE: return 8;
  default: return 4;
  }
}
static float gl_read_f32(uint32_t mac){
  uint32_t bits=ReadMacInt32(mac); float f; std::memcpy(&f,&bits,4); return f;
}
static double gl_read_f64(uint32_t mac){
  uint32_t hi=ReadMacInt32(mac), lo=ReadMacInt32(mac+4);
  uint64_t bits=((uint64_t)hi<<32)|lo; double d; std::memcpy(&d,&bits,8); return d;
}
static int8_t gl_read_i8(uint32_t mac){return (int8_t)ReadMacInt8(mac);}
static uint8_t gl_read_u8(uint32_t mac){return (uint8_t)ReadMacInt8(mac);}
static int16_t gl_read_i16(uint32_t mac){return (int16_t)ReadMacInt16(mac);}
static uint16_t gl_read_u16(uint32_t mac){return (uint16_t)ReadMacInt16(mac);}
static int32_t gl_read_i32(uint32_t mac){return (int32_t)ReadMacInt32(mac);}
static uint32_t gl_read_u32(uint32_t mac){return ReadMacInt32(mac);}
static float gl_read_comp(uint32_t mac, uint32_t type){
  switch(type){
  case GL_FLOAT: return gl_read_f32(mac);
  case GL_DOUBLE: return (float)gl_read_f64(mac);
  case GL_BYTE: return (float)(int8_t)ReadMacInt8(mac)/127.f;
  case GL_UNSIGNED_BYTE: return (float)ReadMacInt8(mac)/255.f;
  case GL_SHORT: return (float)(int16_t)ReadMacInt16(mac)/32767.f;
  case GL_UNSIGNED_SHORT: return (float)ReadMacInt16(mac)/65535.f;
  case GL_INT: return (float)(int32_t)ReadMacInt32(mac)/2147483647.f;
  case GL_UNSIGNED_INT: return (float)ReadMacInt32(mac)/4294967295.f;
  default: return 0.f;
  }
}
static float gl_read_raw(uint32_t mac, uint32_t type){
  switch(type){
  case GL_FLOAT: return gl_read_f32(mac);
  case GL_DOUBLE: return (float)gl_read_f64(mac);
  case GL_BYTE: return (float)(int8_t)ReadMacInt8(mac);
  case GL_UNSIGNED_BYTE: return (float)ReadMacInt8(mac);
  case GL_SHORT: return (float)(int16_t)ReadMacInt16(mac);
  case GL_UNSIGNED_SHORT: return (float)ReadMacInt16(mac);
  case GL_INT: return (float)(int32_t)ReadMacInt32(mac);
  case GL_UNSIGNED_INT: return (float)ReadMacInt32(mac);
  default: return 0.f;
  }
}
static uint32_t gl_array_stride(const GLVertexArrayPointer &a){
  if(a.stride>0) return (uint32_t)a.stride;
  return (uint32_t)(a.size * gl_type_size(a.type));
}
static void gl_fetch_vertex(GLContext *ctx, int32_t index, GLVertex &out)
{
  std::memset(&out,0,sizeof(out));
  out.position[3]=1.f;
  out.color[0]=ctx->current_color[0]; out.color[1]=ctx->current_color[1];
  out.color[2]=ctx->current_color[2]; out.color[3]=ctx->current_color[3];
  out.normal[0]=ctx->current_normal[0]; out.normal[1]=ctx->current_normal[1]; out.normal[2]=ctx->current_normal[2];
  std::memcpy(out.texcoord, ctx->current_texcoord, sizeof(out.texcoord));

  if(ctx->vertex_array.enabled && ctx->vertex_array.pointer){
	uint32_t str=gl_array_stride(ctx->vertex_array);
	uint32_t base=ctx->vertex_array.pointer + (uint32_t)index*str;
	int n=ctx->vertex_array.size; if(n<1)n=1; if(n>4)n=4;
	int ts=gl_type_size(ctx->vertex_array.type);
	for(int i=0;i<n;i++) out.position[i]=gl_read_raw(base+(uint32_t)(i*ts), ctx->vertex_array.type);
	/* glVertexPointer(2, ...) means z=0, per the GL defaults. `out` is
	 * memset to 0 at entry so z is already 0 here, but spell it out so the
	 * rule survives any future change to that seeding. */
	for(int i=n;i<3;i++) out.position[i]=0.f;
	if(n<4) out.position[3]=1.f;
  }
  if(ctx->normal_array.enabled && ctx->normal_array.pointer){
	uint32_t str=gl_array_stride(ctx->normal_array);
	uint32_t base=ctx->normal_array.pointer + (uint32_t)index*str;
	int ts=gl_type_size(ctx->normal_array.type);
	out.normal[0]=gl_read_comp(base, ctx->normal_array.type);
	out.normal[1]=gl_read_comp(base+ts, ctx->normal_array.type);
	out.normal[2]=gl_read_comp(base+2*ts, ctx->normal_array.type);
  }
  if(ctx->color_array.enabled && ctx->color_array.pointer){
	uint32_t str=gl_array_stride(ctx->color_array);
	uint32_t base=ctx->color_array.pointer + (uint32_t)index*str;
	int n=ctx->color_array.size; if(n<3)n=3; if(n>4)n=4;
	int ts=gl_type_size(ctx->color_array.type);
	for(int i=0;i<n;i++) out.color[i]=gl_read_comp(base+(uint32_t)(i*ts), ctx->color_array.type);
	if(n<4) out.color[3]=1.f;
  }
  for(int u=0;u<4;u++){
	if(!ctx->texcoord_array[u].enabled || !ctx->texcoord_array[u].pointer) continue;
	uint32_t str=gl_array_stride(ctx->texcoord_array[u]);
	uint32_t base=ctx->texcoord_array[u].pointer + (uint32_t)index*str;
	int n=ctx->texcoord_array[u].size; if(n<1)n=1; if(n>4)n=4;
	int ts=gl_type_size(ctx->texcoord_array[u].type);
	for(int i=0;i<n;i++) out.texcoord[u][i]=gl_read_raw(base+(uint32_t)(i*ts), ctx->texcoord_array[u].type);
	for(int i=n;i<3;i++) out.texcoord[u][i]=0.f;
	if(n<4) out.texcoord[u][3]=1.f;
  }
}
static void gl_draw_vertex_list(GLContext *ctx, uint32_t mode, const std::vector<GLVertex> &verts)
{
  if(verts.empty())return;
  ctx->im_mode=mode;
  ctx->im_vertices=verts;
  GLMetalFlushImmediateMode(ctx);
}

void NativeGLArrayElement(GLContext*ctx,int32_t i){
  if(!ctx||!ctx->in_begin)return;
  GLVertex v; gl_fetch_vertex(ctx,i,v);
  ctx->im_vertices.push_back(v);
}
void NativeGLVertex2f(GLContext*c,float x,float y){PushVertex(c,x,y,0,1);}
void NativeGLVertex3f(GLContext*c,float x,float y,float z){PushVertex(c,x,y,z,1);}
void NativeGLVertex4f(GLContext*c,float x,float y,float z,float w){PushVertex(c,x,y,z,w);}
void NativeGLVertex2d(GLContext*c,double x,double y){PushVertex(c,(float)x,(float)y,0,1);}
void NativeGLVertex3d(GLContext*c,double x,double y,double z){PushVertex(c,(float)x,(float)y,(float)z,1);}
void NativeGLVertex4d(GLContext*c,double x,double y,double z,double w){PushVertex(c,(float)x,(float)y,(float)z,(float)w);}
void NativeGLVertex2i(GLContext*c,int32_t x,int32_t y){PushVertex(c,(float)x,(float)y,0,1);}
void NativeGLVertex3i(GLContext*c,int32_t x,int32_t y,int32_t z){PushVertex(c,(float)x,(float)y,(float)z,1);}
void NativeGLVertex4i(GLContext*c,int32_t x,int32_t y,int32_t z,int32_t w){PushVertex(c,(float)x,(float)y,(float)z,(float)w);}
void NativeGLVertex2s(GLContext*c,int16_t x,int16_t y){PushVertex(c,(float)x,(float)y,0,1);}
void NativeGLVertex3s(GLContext*c,int16_t x,int16_t y,int16_t z){PushVertex(c,(float)x,(float)y,(float)z,1);}
void NativeGLVertex4s(GLContext*c,int16_t x,int16_t y,int16_t z,int16_t w){PushVertex(c,(float)x,(float)y,(float)z,(float)w);}
void NativeGLColor4f(GLContext*c,float r,float g,float b,float a){ if(!c)return; c->current_color[0]=r;c->current_color[1]=g;c->current_color[2]=b;c->current_color[3]=a; if(SharedMetalDevice()) glColor4f(r,g,b,a);}
void NativeGLColor3f(GLContext*c,float r,float g,float b){NativeGLColor4f(c,r,g,b,1);}
void NativeGLColor3d(GLContext*c,double r,double g,double b){NativeGLColor4f(c,(float)r,(float)g,(float)b,1);}
void NativeGLColor4d(GLContext*c,double r,double g,double b,double a){NativeGLColor4f(c,(float)r,(float)g,(float)b,(float)a);}
void NativeGLColor3b(GLContext*c,int8_t r,int8_t g,int8_t b){NativeGLColor4f(c,r/127.f,g/127.f,b/127.f,1);}
void NativeGLColor4b(GLContext*c,int8_t r,int8_t g,int8_t b,int8_t a){NativeGLColor4f(c,r/127.f,g/127.f,b/127.f,a/127.f);}
void NativeGLColor3ub(GLContext*c,uint8_t r,uint8_t g,uint8_t b){NativeGLColor4f(c,r/255.f,g/255.f,b/255.f,1);}
void NativeGLColor4ub(GLContext*c,uint8_t r,uint8_t g,uint8_t b,uint8_t a){NativeGLColor4f(c,r/255.f,g/255.f,b/255.f,a/255.f);}
void NativeGLColor3i(GLContext*c,int32_t r,int32_t g,int32_t b){NativeGLColor4f(c,r/2147483647.f,g/2147483647.f,b/2147483647.f,1);}
void NativeGLColor4i(GLContext*c,int32_t r,int32_t g,int32_t b,int32_t a){NativeGLColor4f(c,r/2147483647.f,g/2147483647.f,b/2147483647.f,a/2147483647.f);}
void NativeGLColor3s(GLContext*c,int16_t r,int16_t g,int16_t b){NativeGLColor4f(c,r/32767.f,g/32767.f,b/32767.f,1);}
void NativeGLColor4s(GLContext*c,int16_t r,int16_t g,int16_t b,int16_t a){NativeGLColor4f(c,r/32767.f,g/32767.f,b/32767.f,a/32767.f);}
void NativeGLColor3ui(GLContext*c,uint32_t r,uint32_t g,uint32_t b){NativeGLColor4f(c,r/4294967295.f,g/4294967295.f,b/4294967295.f,1);}
void NativeGLColor4ui(GLContext*c,uint32_t r,uint32_t g,uint32_t b,uint32_t a){NativeGLColor4f(c,r/4294967295.f,g/4294967295.f,b/4294967295.f,a/4294967295.f);}
void NativeGLColor3us(GLContext*c,uint16_t r,uint16_t g,uint16_t b){NativeGLColor4f(c,r/65535.f,g/65535.f,b/65535.f,1);}
void NativeGLColor4us(GLContext*c,uint16_t r,uint16_t g,uint16_t b,uint16_t a){NativeGLColor4f(c,r/65535.f,g/65535.f,b/65535.f,a/65535.f);}
/* Vector forms point into big-endian PowerPC memory. Directly casting the
 * guest address to host float/int pointers byte-swaps every multi-byte value. */
#define GL_GUEST_VEC2(name, scalar, read, step) \
  void name(GLContext*c,uint32_t p){if(c&&p)scalar(c,read(p),read(p+(step)));}
#define GL_GUEST_VEC3(name, scalar, read, step) \
  void name(GLContext*c,uint32_t p){if(c&&p)scalar(c,read(p),read(p+(step)),read(p+2*(step)));}
#define GL_GUEST_VEC4(name, scalar, read, step) \
  void name(GLContext*c,uint32_t p){if(c&&p)scalar(c,read(p),read(p+(step)),read(p+2*(step)),read(p+3*(step)));}
GL_GUEST_VEC3(NativeGLColor3fv, NativeGLColor3f, gl_read_f32, 4)
GL_GUEST_VEC4(NativeGLColor4fv, NativeGLColor4f, gl_read_f32, 4)
GL_GUEST_VEC3(NativeGLColor3bv, NativeGLColor3b, gl_read_i8, 1)
GL_GUEST_VEC4(NativeGLColor4bv, NativeGLColor4b, gl_read_i8, 1)
GL_GUEST_VEC3(NativeGLColor3ubv, NativeGLColor3ub, gl_read_u8, 1)
GL_GUEST_VEC4(NativeGLColor4ubv, NativeGLColor4ub, gl_read_u8, 1)
GL_GUEST_VEC3(NativeGLColor3dv, NativeGLColor3d, gl_read_f64, 8)
GL_GUEST_VEC4(NativeGLColor4dv, NativeGLColor4d, gl_read_f64, 8)
GL_GUEST_VEC3(NativeGLColor3iv, NativeGLColor3i, gl_read_i32, 4)
GL_GUEST_VEC4(NativeGLColor4iv, NativeGLColor4i, gl_read_i32, 4)
GL_GUEST_VEC3(NativeGLColor3sv, NativeGLColor3s, gl_read_i16, 2)
GL_GUEST_VEC4(NativeGLColor4sv, NativeGLColor4s, gl_read_i16, 2)
GL_GUEST_VEC3(NativeGLColor3uiv, NativeGLColor3ui, gl_read_u32, 4)
GL_GUEST_VEC4(NativeGLColor4uiv, NativeGLColor4ui, gl_read_u32, 4)
GL_GUEST_VEC3(NativeGLColor3usv, NativeGLColor3us, gl_read_u16, 2)
GL_GUEST_VEC4(NativeGLColor4usv, NativeGLColor4us, gl_read_u16, 2)
GL_GUEST_VEC2(NativeGLVertex2fv, NativeGLVertex2f, gl_read_f32, 4)
GL_GUEST_VEC3(NativeGLVertex3fv, NativeGLVertex3f, gl_read_f32, 4)
GL_GUEST_VEC4(NativeGLVertex4fv, NativeGLVertex4f, gl_read_f32, 4)
GL_GUEST_VEC2(NativeGLVertex2dv, NativeGLVertex2d, gl_read_f64, 8)
GL_GUEST_VEC3(NativeGLVertex3dv, NativeGLVertex3d, gl_read_f64, 8)
GL_GUEST_VEC4(NativeGLVertex4dv, NativeGLVertex4d, gl_read_f64, 8)
GL_GUEST_VEC2(NativeGLVertex2iv, NativeGLVertex2i, gl_read_i32, 4)
GL_GUEST_VEC3(NativeGLVertex3iv, NativeGLVertex3i, gl_read_i32, 4)
GL_GUEST_VEC4(NativeGLVertex4iv, NativeGLVertex4i, gl_read_i32, 4)
GL_GUEST_VEC2(NativeGLVertex2sv, NativeGLVertex2s, gl_read_i16, 2)
GL_GUEST_VEC3(NativeGLVertex3sv, NativeGLVertex3s, gl_read_i16, 2)
GL_GUEST_VEC4(NativeGLVertex4sv, NativeGLVertex4s, gl_read_i16, 2)
void NativeGLNormal3f(GLContext*c,float x,float y,float z){ if(c){c->current_normal[0]=x;c->current_normal[1]=y;c->current_normal[2]=z;} if(SharedMetalDevice()) glNormal3f(x,y,z);}
void NativeGLNormal3d(GLContext*c,double x,double y,double z){NativeGLNormal3f(c,(float)x,(float)y,(float)z);}
void NativeGLNormal3b(GLContext*c,int8_t x,int8_t y,int8_t z){NativeGLNormal3f(c,x/127.f,y/127.f,z/127.f);}
void NativeGLNormal3i(GLContext*c,int32_t x,int32_t y,int32_t z){
  const float nx=(x==-2147483647-1)?-1.f:x/2147483647.f;
  const float ny=(y==-2147483647-1)?-1.f:y/2147483647.f;
  const float nz=(z==-2147483647-1)?-1.f:z/2147483647.f;
  NativeGLNormal3f(c,nx,ny,nz);
}
void NativeGLNormal3s(GLContext*c,int16_t x,int16_t y,int16_t z){NativeGLNormal3f(c,x/32767.f,y/32767.f,z/32767.f);}
GL_GUEST_VEC3(NativeGLNormal3fv, NativeGLNormal3f, gl_read_f32, 4)
GL_GUEST_VEC3(NativeGLNormal3dv, NativeGLNormal3d, gl_read_f64, 8)
GL_GUEST_VEC3(NativeGLNormal3bv, NativeGLNormal3b, gl_read_i8, 1)
GL_GUEST_VEC3(NativeGLNormal3iv, NativeGLNormal3i, gl_read_i32, 4)
GL_GUEST_VEC3(NativeGLNormal3sv, NativeGLNormal3s, gl_read_i16, 2)
void NativeGLTexCoord2f(GLContext*c,float s,float t){
  /* GL spec: glTexCoord2f(s,t) is defined as (s, t, 0, 1) - r MUST be reset.
   * Leaving current_texcoord[0][2] alone let an r from an earlier
   * glTexCoord3f/4f persist into every subsequent 2f vertex, which
   * emit_gl_vertex then feeds to glTexCoord4f/MultiTexCoord4f. Harmless for a
   * plain 2D lookup, but wrong the moment a texture matrix is active. */
  if(c){c->current_texcoord[0][0]=s;c->current_texcoord[0][1]=t;
		c->current_texcoord[0][2]=0.f;c->current_texcoord[0][3]=1.f;}
  if(SharedMetalDevice()) glTexCoord2f(s,t);
}
void NativeGLTexCoord1f(GLContext*c,float s){NativeGLTexCoord2f(c,s,0);}
void NativeGLTexCoord4f(GLContext*c,float s,float t,float r,float q){
  if(c){ c->current_texcoord[0][0]=s; c->current_texcoord[0][1]=t;
		 c->current_texcoord[0][2]=r; c->current_texcoord[0][3]=q; }
  if(SharedMetalDevice()) glTexCoord4f(s,t,r,q);
}
void NativeGLTexCoord3f(GLContext*c,float s,float t,float r){NativeGLTexCoord4f(c,s,t,r,1.f);}

void NativeGLDrawArrays(GLContext *ctx, uint32_t mode, int32_t first, int32_t count) {
  if(!ctx||count<=0)return;
  std::vector<GLVertex> verts((size_t)count);
  for(int32_t i=0;i<count;i++) gl_fetch_vertex(ctx, first+i, verts[(size_t)i]);
  gl_draw_vertex_list(ctx, mode, verts);
}
void NativeGLDrawElements(GLContext *ctx, uint32_t mode, int32_t count, uint32_t type, uint32_t indices_ptr) {
  if(!ctx||count<=0||!indices_ptr)return;
  std::vector<GLVertex> verts; verts.reserve((size_t)count);
  for(int32_t i=0;i<count;i++){
	uint32_t idx=0;
	if(type==GL_UNSIGNED_BYTE) idx=ReadMacInt8(indices_ptr+(uint32_t)i);
	else if(type==GL_UNSIGNED_SHORT) idx=ReadMacInt16(indices_ptr+(uint32_t)i*2);
	else idx=ReadMacInt32(indices_ptr+(uint32_t)i*4);
	GLVertex v; gl_fetch_vertex(ctx,(int32_t)idx,v); verts.push_back(v);
  }
  gl_draw_vertex_list(ctx, mode, verts);
}
void NativeGLDrawRangeElements(GLContext *ctx, uint32_t mode, uint32_t /*start*/, uint32_t /*end*/, int32_t count, uint32_t type, uint32_t indices_ptr) {
  NativeGLDrawElements(ctx,mode,count,type,indices_ptr);
}
void NativeGLInterleavedArrays(GLContext *ctx, uint32_t format, int32_t stride, uint32_t pointer) {
  if(!ctx||!pointer)return;
  /* Common formats: GL_V3F=0x2A21, GL_C4F_N3F_V3F=0x2A2C, GL_T2F_V3F=0x2A27, GL_T2F_C4F_N3F_V3F=0x2A2C-ish */
  int fstride=stride;
  ctx->vertex_array.enabled=true;
  ctx->vertex_array.pointer=pointer;
  ctx->vertex_array.type=GL_FLOAT;
  ctx->vertex_array.size=3;
  ctx->color_array.enabled=false;
  ctx->normal_array.enabled=false;
  for(int u=0;u<4;u++) ctx->texcoord_array[u].enabled=false;
  switch(format){
  case 0x2A21: /* GL_V3F */ if(fstride<=0)fstride=12; ctx->vertex_array.stride=fstride; ctx->vertex_array.pointer=pointer; break;
  case 0x2A22: /* GL_C4UB_V2F */ if(fstride<=0)fstride=12;
	ctx->color_array={pointer,4,(int)fstride,GL_UNSIGNED_BYTE,true};
	ctx->vertex_array={pointer+4,2,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A23: /* GL_C4UB_V3F */ if(fstride<=0)fstride=16;
	ctx->color_array={pointer,4,(int)fstride,GL_UNSIGNED_BYTE,true};
	ctx->vertex_array={pointer+4,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A24: /* GL_C3F_V3F */ if(fstride<=0)fstride=24;
	ctx->color_array={pointer,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+12,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A25: /* GL_N3F_V3F */ if(fstride<=0)fstride=24;
	ctx->normal_array={pointer,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+12,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A26: /* GL_C4F_N3F_V3F */ if(fstride<=0)fstride=40;
	ctx->color_array={pointer,4,(int)fstride,GL_FLOAT,true};
	ctx->normal_array={pointer+16,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+28,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A27: /* GL_T2F_V3F */ if(fstride<=0)fstride=20;
	ctx->texcoord_array[0]={pointer,2,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+8,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A28: /* GL_T4F_V4F */ if(fstride<=0)fstride=32;
	ctx->texcoord_array[0]={pointer,4,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+16,4,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A29: /* GL_T2F_C4UB_V3F */ if(fstride<=0)fstride=24;
	ctx->texcoord_array[0]={pointer,2,(int)fstride,GL_FLOAT,true};
	ctx->color_array={pointer+8,4,(int)fstride,GL_UNSIGNED_BYTE,true};
	ctx->vertex_array={pointer+12,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A2A: /* GL_T2F_C3F_V3F */ if(fstride<=0)fstride=32;
	ctx->texcoord_array[0]={pointer,2,(int)fstride,GL_FLOAT,true};
	ctx->color_array={pointer+8,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+20,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A2B: /* GL_T2F_N3F_V3F */ if(fstride<=0)fstride=32;
	ctx->texcoord_array[0]={pointer,2,(int)fstride,GL_FLOAT,true};
	ctx->normal_array={pointer+8,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+20,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A2C: /* GL_T2F_C4F_N3F_V3F */ if(fstride<=0)fstride=48;
	ctx->texcoord_array[0]={pointer,2,(int)fstride,GL_FLOAT,true};
	ctx->color_array={pointer+8,4,(int)fstride,GL_FLOAT,true};
	ctx->normal_array={pointer+24,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+36,3,(int)fstride,GL_FLOAT,true}; break;
  case 0x2A2D: /* GL_T4F_C4F_N3F_V4F */ if(fstride<=0)fstride=60;
	ctx->texcoord_array[0]={pointer,4,(int)fstride,GL_FLOAT,true};
	ctx->color_array={pointer+16,4,(int)fstride,GL_FLOAT,true};
	ctx->normal_array={pointer+32,3,(int)fstride,GL_FLOAT,true};
	ctx->vertex_array={pointer+44,4,(int)fstride,GL_FLOAT,true}; break;
  default:
	if(fstride<=0)fstride=12;
	ctx->vertex_array.stride=fstride;
	break;
  }
}
void NativeGLReadPixels(GLContext*ctx,int32_t x,int32_t y,int32_t w,int32_t h,uint32_t format,uint32_t type,uint32_t pixels){
  if(!ctx||!pixels||w<=0||h<=0||!SharedMetalDevice())return;
  int bpp=4;
  if(format==0x1907 /*RGB*/ ) bpp=3;
  else if(format==0x1909 /*LUMINANCE*/) bpp=1;
  std::vector<uint8_t> host((size_t)w*h*bpp);
  GLenum glfmt=GL_BGRA, gltype=GL_UNSIGNED_BYTE;
  if(format==0x80E1||format==0x8000) glfmt=GL_BGRA;
  else if(format==0x1908) glfmt=GL_RGBA;
  else if(format==0x1907) glfmt=GL_RGB;
  glReadPixels(x,y,w,h,glfmt,gltype,host.data());
  /* Pack into guest memory big-endian friendly byte stream */
  for(int i=0;i<(int)host.size();i++) WriteMacInt8(pixels+(uint32_t)i, host[(size_t)i]);
}
void NativeGLTexCoord1d(GLContext *ctx, double s) {NativeGLTexCoord1f(ctx,(float)s);}
void NativeGLTexCoord1dv(GLContext *ctx, uint32_t p) {if(ctx&&p)NativeGLTexCoord1d(ctx,gl_read_f64(p));}
void NativeGLTexCoord1fv(GLContext *ctx, uint32_t p) {if(ctx&&p)NativeGLTexCoord1f(ctx,gl_read_f32(p));}
void NativeGLTexCoord1i(GLContext *ctx, int32_t s) {NativeGLTexCoord1f(ctx,(float)s);}
void NativeGLTexCoord1iv(GLContext *ctx, uint32_t p) {if(ctx&&p)NativeGLTexCoord1i(ctx,gl_read_i32(p));}
void NativeGLTexCoord1s(GLContext *ctx, int16_t s) {NativeGLTexCoord1f(ctx,(float)s);}
void NativeGLTexCoord1sv(GLContext *ctx, uint32_t p) {if(ctx&&p)NativeGLTexCoord1s(ctx,gl_read_i16(p));}
void NativeGLTexCoord2d(GLContext *ctx, double s, double t) {NativeGLTexCoord2f(ctx,(float)s,(float)t);}
GL_GUEST_VEC2(NativeGLTexCoord2dv, NativeGLTexCoord2d, gl_read_f64, 8)
GL_GUEST_VEC2(NativeGLTexCoord2fv, NativeGLTexCoord2f, gl_read_f32, 4)
void NativeGLTexCoord2i(GLContext *ctx, int32_t s, int32_t t) {NativeGLTexCoord2f(ctx,(float)s,(float)t);}
GL_GUEST_VEC2(NativeGLTexCoord2iv, NativeGLTexCoord2i, gl_read_i32, 4)
void NativeGLTexCoord2s(GLContext *ctx, int16_t s, int16_t t) {NativeGLTexCoord2f(ctx,(float)s,(float)t);}
GL_GUEST_VEC2(NativeGLTexCoord2sv, NativeGLTexCoord2s, gl_read_i16, 2)
void NativeGLTexCoord3d(GLContext *ctx, double s, double t, double r) {NativeGLTexCoord3f(ctx,(float)s,(float)t,(float)r);}
GL_GUEST_VEC3(NativeGLTexCoord3dv, NativeGLTexCoord3d, gl_read_f64, 8)
GL_GUEST_VEC3(NativeGLTexCoord3fv, NativeGLTexCoord3f, gl_read_f32, 4)
void NativeGLTexCoord3i(GLContext *ctx, int32_t s, int32_t t, int32_t r) {NativeGLTexCoord3f(ctx,(float)s,(float)t,(float)r);}
GL_GUEST_VEC3(NativeGLTexCoord3iv, NativeGLTexCoord3i, gl_read_i32, 4)
void NativeGLTexCoord3s(GLContext *ctx, int16_t s, int16_t t, int16_t r) {NativeGLTexCoord3f(ctx,(float)s,(float)t,(float)r);}
GL_GUEST_VEC3(NativeGLTexCoord3sv, NativeGLTexCoord3s, gl_read_i16, 2)
void NativeGLTexCoord4d(GLContext *ctx, double s, double t, double r, double q) {NativeGLTexCoord4f(ctx,(float)s,(float)t,(float)r,(float)q);}
GL_GUEST_VEC4(NativeGLTexCoord4dv, NativeGLTexCoord4d, gl_read_f64, 8)
GL_GUEST_VEC4(NativeGLTexCoord4fv, NativeGLTexCoord4f, gl_read_f32, 4)
void NativeGLTexCoord4i(GLContext *ctx, int32_t s, int32_t t, int32_t r, int32_t q) {NativeGLTexCoord4f(ctx,(float)s,(float)t,(float)r,(float)q);}
GL_GUEST_VEC4(NativeGLTexCoord4iv, NativeGLTexCoord4i, gl_read_i32, 4)
void NativeGLTexCoord4s(GLContext *ctx, int16_t s, int16_t t, int16_t r, int16_t q) {NativeGLTexCoord4f(ctx,(float)s,(float)t,(float)r,(float)q);}
GL_GUEST_VEC4(NativeGLTexCoord4sv, NativeGLTexCoord4s, gl_read_i16, 2)
#undef GL_GUEST_VEC2
#undef GL_GUEST_VEC3
#undef GL_GUEST_VEC4
