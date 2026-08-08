# SheepShaver target (included from root CMakeLists.txt, or standalone)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
	cmake_minimum_required(VERSION 3.16)
	project(SheepShaver VERSION 2.3 LANGUAGES C CXX)
	set(CMAKE_CXX_STANDARD 20)
	set(CMAKE_CXX_STANDARD_REQUIRED ON)
	set(CMAKE_C_STANDARD 99)
	option(ENABLE_JIT "Legacy default for the PPC JIT" OFF)
	option(ENABLE_SHEEPSHAVER_JIT "Enable PPC JIT (precompiled dyngen)" ${ENABLE_JIT})
	option(ENABLE_GTK "GTK prefs UI (Unix)" OFF)
	option(ENABLE_BINCUE "BIN/CUE support" ON)
	option(ENABLE_VOSF "Video on SEGV" OFF)
	option(ENABLE_QD3D_INIT_LOGGING
	"Compile focused QuickDraw 3D/RAVE initialization diagnostics" OFF)
	option(ENABLE_QD3D_GRAPHICS_LOGGING
	"Compile high-volume QD3D graphics diagnostics" OFF)
	option(ENABLE_QD3D_AUDIO_LOGGING
	"Compile sound component and SDL audio diagnostics" OFF)
	option(ENABLE_QD3D_MEDIA_LOGGING
	"Compile CD/media I/O diagnostics" OFF)
	option(ENABLE_QD3D_WAIT_LOGGING
	"Compile high-volume timing/wait diagnostics" OFF)
	option(USE_SDL3 "Use SDL3" OFF)
	set(MACEMU_CMAKE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
	list(APPEND CMAKE_MODULE_PATH "${MACEMU_CMAKE_DIR}")
	include(MacEmuCommon)
	set(B2_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../BasiliskII/src")
	set(SS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src")
	macemu_detect_host()
	macemu_find_sdl()
endif()

if(NOT DEFINED SS_SRC)
	set(SS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src")
endif()
if(NOT DEFINED B2_SRC)
	set(B2_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../BasiliskII/src")
endif()

if(NOT EXISTS "${B2_SRC}/main.cpp")
	message(FATAL_ERROR "Basilisk II sources not found at ${B2_SRC}")
endif()

set(KPX "${SS_SRC}/kpx_cpu")

if(ENABLE_SHEEPSHAVER_JIT)
	set(ENABLE_DYNGEN 1)
endif()


if(WIN32)
	set(SS_SYSDEPS "${SS_SRC}/Windows")
elseif(${CMAKE_SYSTEM_NAME} MATCHES "Darwin|OSX")
	set(SS_SYSDEPS "${SS_SRC}/MacOSX")
else()
	set(SS_SYSDEPS "${SS_SRC}/Unix")
endif()
macemu_write_config(
	"${SS_SYSDEPS}"
	"SheepShaver" "SheepShaver" "2.3" "")
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
	target_include_directories(SheepShaver PRIVATE "${SS_SYSDEPS}")
endif()




# ---------------------------------------------------------------------------
# Sources shared with Basilisk II are named by their real path in the
# BasiliskII tree, never through the matching symlink in SheepShaver/src.
# "make links" puts those symlinks there for the autoconf build, which
# compiles bare file names, but a symlink carries its own timestamp and Ninja
# reads that rather than the file it points at, so a build driven through one
# never notices an edit. Include precedence still comes from the order of
# target_include_directories below, SS paths before B2 paths, so SheepShaver
# headers win over their Basilisk II twins.
# ---------------------------------------------------------------------------
set(SS_SHARED
	"${B2_SRC}/adb.cpp"
	"${B2_SRC}/audio.cpp"
	"${B2_SRC}/cdrom.cpp"
	"${B2_SRC}/disk.cpp"
	"${B2_SRC}/extfs.cpp"
	"${B2_SRC}/prefs.cpp"
	"${B2_SRC}/scsi.cpp"
	"${B2_SRC}/sony.cpp"
	"${B2_SRC}/timer.cpp"
	"${B2_SRC}/xpram.cpp"
)
if(ENABLE_BINCUE)
	list(APPEND SS_SHARED "${B2_SRC}/bincue.cpp")
endif()

macemu_slirp_sources("${B2_SRC}" SS_SLIRP)
macemu_sdl_sources("${B2_SRC}" SS_SDL)
set(SS_XPLAT
	"${B2_SRC}/CrossPlatform/vm_alloc.cpp"
	"${B2_SRC}/CrossPlatform/sigsegv.cpp"
	"${B2_SRC}/CrossPlatform/video_blit.cpp"
)

set(SS_CORE
	"${SS_SRC}/main.cpp"
	"${SS_SRC}/prefs_items.cpp"
	"${SS_SRC}/rom_patches.cpp"
	"${SS_SRC}/rsrc_patches.cpp"
	"${SS_SRC}/emul_op.cpp"
	"${B2_SRC}/joymanager.cpp"
	"${SS_SRC}/name_registry.cpp"
	"${SS_SRC}/macos_util.cpp"
	"${SS_SRC}/gfxaccel.cpp"
	"${SS_SRC}/video.cpp"
	"${SS_SRC}/ether.cpp"
	"${SS_SRC}/thunks.cpp"
	"${SS_SRC}/serial.cpp"
	"${SS_SRC}/user_strings.cpp"
	${SS_SHARED}
	${SS_XPLAT}
	${SS_SDL}
	${SS_SLIRP}
)

# PowerPC emulator
set(SS_CPU
	"${KPX}/src/mathlib/ieeefp.cpp"
	"${KPX}/src/mathlib/mathlib.cpp"
	"${KPX}/src/cpu/ppc/ppc-cpu.cpp"
	"${KPX}/src/cpu/ppc/ppc-decode.cpp"
	"${KPX}/src/cpu/ppc/ppc-execute.cpp"
	"${KPX}/src/cpu/ppc/ppc-translate.cpp"
	"${KPX}/src/utils/utils-cpuinfo.cpp"
	"${KPX}/sheepshaver_glue.cpp"
	"${KPX}/ppc-dis.c"
)

# ppc-execute.cpp does #include "ppc-execute-impl.cpp" and the JIT does
# #include "*-dyngen-ops.hpp". These live in the dyngen_precompiled dir; we add
# that dir to the include paths (no staging) so the #include resolves in place.
# OBJECT_DEPENDS on the including TUs makes an edit to those files recompile.
set(SS_DYNGEN_INC)
set(PRE_PPC_IMPL "${SS_SRC}/Unix/dyngen_precompiled/ppc-execute-impl.cpp")
if(NOT EXISTS "${PRE_PPC_IMPL}")
	message(FATAL_ERROR "Missing ${PRE_PPC_IMPL}")
endif()
list(APPEND SS_DYNGEN_INC "${SS_SRC}/Unix/dyngen_precompiled")
set_source_files_properties(
	"${KPX}/src/cpu/ppc/ppc-execute.cpp"
	PROPERTIES OBJECT_DEPENDS "${PRE_PPC_IMPL}")

if(ENABLE_SHEEPSHAVER_JIT)
	list(APPEND SS_CPU
		"${KPX}/src/cpu/jit/jit-cache.cpp"
		"${KPX}/src/cpu/jit/basic-dyngen.cpp"
		"${KPX}/src/cpu/ppc/ppc-dyngen.cpp"
		"${KPX}/src/cpu/ppc/ppc-jit.cpp")
	if(WIN32 AND EXISTS "${SS_SRC}/Windows/cygwin_precompiled_dyngen/basic-dyngen-ops.hpp")
	set(_ops "${SS_SRC}/Windows/cygwin_precompiled_dyngen")
	else()
	set(_ops "${SS_SRC}/Unix/dyngen_precompiled")
	endif()
	list(APPEND SS_DYNGEN_INC "${_ops}")
	set_source_files_properties(
		"${KPX}/src/cpu/jit/basic-dyngen.cpp"
		"${KPX}/src/cpu/ppc/ppc-dyngen.cpp"
		PROPERTIES OBJECT_DEPENDS "${_ops}/basic-dyngen-ops.hpp;${_ops}/ppc-dyngen-ops.hpp")
endif()

if(WIN32)
	macemu_windows_net_sources("${B2_SRC}" SS_NET)

	# Windows sources SheepShaver owns outright.
	set(SS_PLATFORM
		"${SS_SRC}/Windows/main_windows.cpp"
		"${SS_SRC}/Windows/prefs_windows.cpp"
		"${SS_SRC}/Windows/user_strings_windows.cpp"
		"${SS_SRC}/Windows/about_window_windows.cpp"
		"${SS_SRC}/dummy/prefs_dummy.cpp"
	)

	# Windows sources shared with Basilisk II, compiled from the BasiliskII
	# tree. Each one includes "sysdeps.h" and MSVC looks in the file's own
	# directory first, which there holds Basilisk II's copy, so force-include
	# SheepShaver's ahead of it. Both use the SYSDEPS_H guard, so the include
	# in the file itself then does nothing.
	set(SS_SHARED_PLATFORM
		"${B2_SRC}/Windows/sys_windows.cpp"
		"${B2_SRC}/Windows/xpram_windows.cpp"
		"${B2_SRC}/Windows/timer_windows.cpp"
		"${B2_SRC}/Windows/serial_windows.cpp"
		"${B2_SRC}/Windows/ether_windows.cpp"
		"${B2_SRC}/Windows/clip_windows.cpp"
		"${B2_SRC}/Windows/extfs_windows.cpp"
		"${B2_SRC}/Windows/util_windows.cpp"
		"${B2_SRC}/Windows/posix_emu.cpp"
		"${B2_SRC}/dummy/scsi_dummy.cpp"
		"${B2_SRC}/dummy/prefs_editor_dummy.cpp"
	)
	set(_ss_sysdeps_fi "${SS_SRC}/Windows/sysdeps.h")
	if(MSVC)
		set_source_files_properties(${SS_SHARED_PLATFORM} PROPERTIES
			COMPILE_OPTIONS "/FI${_ss_sysdeps_fi}")
	else()
		set_source_files_properties(${SS_SHARED_PLATFORM} PROPERTIES
			COMPILE_OPTIONS "-include;${_ss_sysdeps_fi}")
	endif()
	set_source_files_properties(${SS_SHARED_PLATFORM} PROPERTIES
		OBJECT_DEPENDS "${_ss_sysdeps_fi}")
	list(APPEND SS_PLATFORM ${SS_SHARED_PLATFORM})
	list(APPEND SS_PLATFORM ${SS_NET})

	if(EXISTS "${SS_SRC}/Windows/SheepShaver.rc")
	file(SIZE "${SS_SRC}/Windows/SheepShaver.rc" _rcsz)
	if(_rcsz GREATER 100)
		list(APPEND SS_PLATFORM "${SS_SRC}/Windows/SheepShaver.rc")
	endif()
	endif()

	set(SS_PLATFORM_INC
	"${SS_SRC}/Windows"
	"${B2_SRC}/Windows"
	"${B2_SRC}/Windows/router"
	"${B2_SRC}/Windows/b2ether")
else()
	# Unix sources SheepShaver owns outright, then the ones shared with
	# Basilisk II named by their real path there. clip_dummy.cpp used to be
	# added inside the loop below, so it went in once per shared source.
	set(SS_PLATFORM
	"${SS_SRC}/Unix/main_unix.cpp"
	"${SS_SRC}/Unix/about_window_unix.cpp"
	"${SS_SRC}/Unix/prefs_unix.cpp"
	"${SS_SRC}/Unix/user_strings_unix.cpp"
	"${B2_SRC}/Unix/sys_unix.cpp"
	"${B2_SRC}/Unix/xpram_unix.cpp"
	"${B2_SRC}/Unix/timer_unix.cpp"
	"${B2_SRC}/Unix/serial_unix.cpp"
	"${B2_SRC}/Unix/ether_unix.cpp"
	"${B2_SRC}/Unix/extfs_unix.cpp"
	"${B2_SRC}/Unix/rpc_unix.cpp"
	"${B2_SRC}/Unix/sshpty.c"
	"${B2_SRC}/Unix/strlcpy.c"
	"${B2_SRC}/Unix/tinyxml2.cpp"
	"${B2_SRC}/Unix/disk_sparsebundle.cpp"
	"${B2_SRC}/Unix/posix_sem.cpp"
	"${B2_SRC}/dummy/clip_dummy.cpp"
	"${B2_SRC}/dummy/prefs_dummy.cpp"
	)
	if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
		list(APPEND SS_PLATFORM "${B2_SRC}/Unix/Linux/scsi_linux.cpp")
	else()
		list(APPEND SS_PLATFORM "${B2_SRC}/dummy/scsi_dummy.cpp")
	endif()
	if(ENABLE_GTK)
	find_package(PkgConfig REQUIRED)
	pkg_check_modules(GTK3 REQUIRED gtk+-3.0)
	list(APPEND SS_PLATFORM "${B2_SRC}/Unix/prefs_editor_gtk3.cpp")
	else()
	list(APPEND SS_PLATFORM "${B2_SRC}/dummy/prefs_editor_dummy.cpp")
	endif()
	set(SS_PLATFORM_INC "${SS_SRC}/Unix")
endif()

# ---------------------------------------------------------------------------
# Graphics acceleration (PocketShaver engines: NQD / RAVE / GL / DSp)
# ---------------------------------------------------------------------------
if(NOT DEFINED ENABLE_GFXACCEL)
	option(ENABLE_GFXACCEL "SheepShaver graphics accel (NQD/RAVE/GL/DSp)" ON)
endif()
if(NOT DEFINED GFXACCEL_BACKEND)
	set(GFXACCEL_BACKEND "auto" CACHE STRING "gfxaccel GPU backend (auto|opengl|metal)")
endif()

set(SS_GFXACCEL)
set(SS_GFXACCEL_INC)
set(SS_GFXACCEL_LIBS)
set(SS_GFXACCEL_DEFS)

if(ENABLE_GFXACCEL)
	set(GA "${SS_SRC}/gfxaccel")
	set(SS_GFXACCEL_INC "${GA}" "${GA}/include" "${GA}/gl")

	# Portable engine / policy / dispatch sources
	list(APPEND SS_GFXACCEL
	"${GA}/display_mode_controller.cpp"
	"${GA}/dsp_alt_buffer.cpp"
	"${GA}/dsp_clut_gamma.cpp"
	"${GA}/dsp_dispatch.cpp"
	"${GA}/dsp_draw_context.cpp"
	"${GA}/dsp_engine.cpp"
	"${GA}/dsp_flatten_restore.cpp"
	"${GA}/dsp_install_hooks.cpp"
	"${GA}/dsp_mode_enumerate.cpp"
	"${GA}/dsp_thunks.cpp"
	"${GA}/gfxaccel_resources.cpp"
	"${GA}/gfxaccel_resources_heap.cpp"
	"${GA}/gl_defer.cpp"
	"${GA}/gl_dispatch.cpp"
	"${GA}/gl_engine.cpp"
	"${GA}/gl_state.cpp"
	"${GA}/gl_thunks.cpp"
	"${GA}/rave_dispatch.cpp"
	"${GA}/rave_draw_context.cpp"
	"${GA}/rave_engine.cpp"
	"${GA}/rave_thunks.cpp"
	"${GA}/glide_dispatch.cpp"
	"${GA}/glide_engine.cpp"
	"${GA}/glide_state.cpp"
	"${GA}/glide_pef_register.cpp"
	)

	if(ENABLE_NATIVE_CINEPAK_PATCH)
		list(APPEND SS_GFXACCEL
		"${GA}/cinepak_decoder.cpp"
		"${GA}/cinepak_hooks.cpp"
		)
	endif()
	# Resolve backend
	set(_gfx_backend "${GFXACCEL_BACKEND}")
	if(_gfx_backend STREQUAL "auto")
	if(APPLE)
		set(_gfx_backend "metal")
	else()
		set(_gfx_backend "opengl")
	endif()
	endif()

	if(_gfx_backend STREQUAL "metal")
	if(NOT APPLE)
		message(FATAL_ERROR "GFXACCEL_BACKEND=metal requires Apple platforms")
	endif()
	list(APPEND SS_GFXACCEL_DEFS ENABLE_GFXACCEL=1 GFXACCEL_USE_METAL=1)
	enable_language(OBJCXX)
	list(APPEND SS_GFXACCEL
		"${GA}/metal_device_shared.mm"
		"${GA}/metal_compositor.mm"
		"${GA}/metal_compositor_submitframe.mm"
		"${GA}/nqd_metal_renderer.mm"
		"${GA}/rave_metal_renderer.mm"
		"${GA}/gl_metal_renderer.mm"
		"${GA}/dsp_metal_renderer.mm"
		"${GA}/dsp_host_bridge.mm"
		"${GA}/gfxaccel_resources.mm"
		"${GA}/gfxaccel_resources_heap.mm"
		"${GA}/gfxaccel_arc_shim.mm"
		"${GA}/vbl_source.mm"
		"${GA}/pso_archive.mm"
	)
	find_library(METAL_LIB Metal)
	find_library(QUARTZCORE_LIB QuartzCore)
	find_library(FOUNDATION_LIB Foundation)
	list(APPEND SS_GFXACCEL_LIBS ${METAL_LIB} ${QUARTZCORE_LIB} ${FOUNDATION_LIB})
	else()
	# OpenGL + SDL backend (default on Windows/Linux)
	list(APPEND SS_GFXACCEL_DEFS ENABLE_GFXACCEL=1 GFXACCEL_USE_OPENGL=1)
	list(APPEND SS_GFXACCEL
		"${GA}/gl/gl_compositor.cpp"
		"${GA}/gl/vbl_source_sdl.cpp"
		"${GA}/gl/gfxaccel_resources_gl.cpp"
		"${GA}/gl/gfxaccel_resources_heap_gl.cpp"
		"${GA}/gl/gfxaccel_arc_shim.cpp"
		"${GA}/gl/pso_archive_gl.cpp"
		"${GA}/gl/nqd_gl_renderer.cpp"
		"${GA}/gl/rave_gl_renderer.cpp"
		"${GA}/gl/gl_ffp_renderer.cpp"
		"${GA}/gl/dsp_gl_renderer.cpp"
		"${GA}/gl/glide_gl_renderer.cpp"
	)
	if(WIN32)
		list(APPEND SS_GFXACCEL_LIBS opengl32)
	elseif(APPLE)
		find_library(OPENGL_LIB OpenGL)
		list(APPEND SS_GFXACCEL_LIBS ${OPENGL_LIB})
	else()
		find_package(OpenGL REQUIRED)
		list(APPEND SS_GFXACCEL_LIBS OpenGL::GL)
	endif()
	endif()

	message(STATUS "SheepShaver gfxaccel: backend=${_gfx_backend}")
endif()

# ---------------------------------------------------------------------------
# Executable
# ---------------------------------------------------------------------------
# ppc-execute-impl.cpp is #included by ppc-execute.cpp (not a separate TU)
add_executable(SheepShaver
	${SS_CORE} ${SS_CPU} ${SS_PLATFORM} ${SS_GFXACCEL})
if(WIN32)
elseif(${CMAKE_SYSTEM_NAME} MATCHES "Darwin|OSX")
else()
	find_package(X11 REQUIRED)
	target_link_libraries(SheepShaver PRIVATE X11::X11 X11::Xext)
endif()

# Force staging before any compile/link (required for VS/CMake IDE + Ninja).
# Without this, staged headers can lag source edits forever after configure.
# NOTE: Do not use cmake -E echo with ">" in the message under cmd.exe -
# the shell treats it as a redirect and can overwrite the .exe (we hit this).

target_include_directories(SheepShaver PRIVATE
	# Platform sysdeps (Windows/ or Unix/) must come before shared includes
	${SS_PLATFORM_INC}
	# SS-specific headers (override B2 twins); stubs are filtered out above
	"${SS_SRC}/include"
	# dyngen_precompiled dir so #include "ppc-execute-impl.cpp" and the
	# *-dyngen-ops.hpp resolve directly from source (no staging)
	${SS_DYNGEN_INC}
	# Shared headers from Basilisk II
	"${B2_SRC}/include"
	"${B2_SRC}/CrossPlatform"
	"${B2_SRC}/slirp"
	"${KPX}/include"
	"${KPX}/src"
	${SS_GFXACCEL_INC}
)

target_compile_definitions(SheepShaver PRIVATE
	SHEEPSHAVER=1
	POWERPC_ROM=1
	EMULATED_PPC=1
	${SS_GFXACCEL_DEFS}
)
if(NOT WIN32) # conflicts with win32 headers
	target_compile_definitions(SheepShaver PRIVATE
		DATADIR="${CMAKE_INSTALL_FULL_DATADIR}/SheepShaver")
endif()
if(WIN32)
	target_compile_definitions(SheepShaver PRIVATE CONFIG_WIN32=1 NATMEM_OFFSET=0x11000000)
	# PocketShaver MEM_BULK parity: back the whole guest address space lazily
	# on first touch, so stray guest stores land in real zero-filled memory
	# and read back later instead of being skipped by ignoresegv. OFF restores
	# the plain skip-instruction behavior.
	option(ENABLE_MEM_BULK_LAZY "Lazily back entire guest address space on fault (MEM_BULK parity)" ON)
	if(ENABLE_MEM_BULK_LAZY)
		target_compile_definitions(SheepShaver PRIVATE MEM_BULK_LAZY=1)
	endif()
endif()
if(MSVC AND ENABLE_GFXACCEL)
	# M_PI and other math macros from <cmath>
	target_compile_definitions(SheepShaver PRIVATE _USE_MATH_DEFINES=1)
endif()
if(ENABLE_SHEEPSHAVER_JIT)
	target_compile_definitions(SheepShaver PRIVATE USE_JIT ENABLE_DYNGEN)
endif()
if(ENABLE_QD3D_INIT_LOGGING)
	target_compile_definitions(SheepShaver PRIVATE QD3D_INIT_LOGGING_ENABLED=1)
endif()
if(ENABLE_QD3D_GRAPHICS_LOGGING)
	target_compile_definitions(SheepShaver PRIVATE QD3D_GRAPHICS_LOGGING_ENABLED=1)
endif()
if(ENABLE_QD3D_AUDIO_LOGGING)
	target_compile_definitions(SheepShaver PRIVATE QD3D_AUDIO_LOGGING_ENABLED=1)
endif()
if(ENABLE_QD3D_MEDIA_LOGGING)
	target_compile_definitions(SheepShaver PRIVATE QD3D_MEDIA_LOGGING_ENABLED=1)
endif()
if(ENABLE_QD3D_WAIT_LOGGING)
	target_compile_definitions(SheepShaver PRIVATE QD3D_WAIT_LOGGING_ENABLED=1)
endif()
if(ENABLE_NATIVE_CINEPAK_PATCH)
	target_compile_definitions(SheepShaver PRIVATE
		ENABLE_NATIVE_CINEPAK_PATCH=1)
endif()

macemu_apply_common(SheepShaver)

if(SS_GFXACCEL_LIBS)
	target_link_libraries(SheepShaver PRIVATE ${SS_GFXACCEL_LIBS})
endif()

if(ENABLE_GTK AND NOT WIN32)
	target_include_directories(SheepShaver PRIVATE ${GTK3_INCLUDE_DIRS})
	target_link_libraries(SheepShaver PRIVATE ${GTK3_LIBRARIES})
endif()

install(TARGETS SheepShaver RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

message(STATUS "SheepShaver: JIT=${ENABLE_SHEEPSHAVER_JIT}")
message(STATUS "SheepShaver: QD3D init logging=${ENABLE_QD3D_INIT_LOGGING}")
message(STATUS "SheepShaver: QD3D graphics logging=${ENABLE_QD3D_GRAPHICS_LOGGING}")
message(STATUS "SheepShaver: QD3D audio logging=${ENABLE_QD3D_AUDIO_LOGGING}")
message(STATUS "SheepShaver: QD3D media logging=${ENABLE_QD3D_MEDIA_LOGGING}")
message(STATUS "SheepShaver: QD3D wait logging=${ENABLE_QD3D_WAIT_LOGGING}")
