/*
 *  pso_archive.h - PSO binary archive module.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  MTLBinaryArchive of stock compositor and NQD pipelines, loaded from the
 *  bundle so first launch needs no runtime shader compiles (iOS 14+). RAVE
 *  and GL pipelines are not archived. PSOs are returned as void*.
 */

#ifndef PSO_ARCHIVE_H
#define PSO_ARCHIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Continues the -4000 gfxaccel error block. */
enum GfxAccelPSOArchiveError {
	kGfxAccelErrPSOArchiveLoadFailed   = -4012,
	kGfxAccelErrPSOArchiveNotAvailable = -4013  /* iOS < 14 */
};

/* --- Lifecycle --- */

/*
 * Loads stock_pipelines.metalarchive. Call after SharedMetalDevice() is up.
 * Returns 0 on success, including when the bundle has no archive (everything
 * compiles at runtime), kGfxAccelErrPSOArchiveLoadFailed on a Metal error, or
 * kGfxAccelErrPSOArchiveNotAvailable (non-fatal) before iOS 14.
 */
int32_t pso_archive_init(void);

/* Releases the archive. Idempotent. */
void pso_archive_shutdown(void);

/* --- Lookup --- */

/*
 * descriptor is an MTLRenderPipelineDescriptor. Returns the archived
 * id<MTLRenderPipelineState>, or NULL on a miss (binaryArchives is cleared
 * and the caller compiles at runtime), with no archive, or a NULL descriptor.
 */
void *pso_archive_lookup_render(void *descriptor);

/* Compute-pipeline counterpart of pso_archive_lookup_render. */
void *pso_archive_lookup_compute(void *descriptor);

/* 1 if an archive is loaded. */
uint32_t pso_archive_is_available(void);

/*
 * Sets binaryArchives on an MTLRenderPipelineDescriptor when an archive is
 * loaded, so Metal checks it before compiling. Call before
 * newRenderPipelineStateWithDescriptor:.
 */
void pso_archive_set_on_descriptor(void *descriptor);

#ifdef __cplusplus
}
#endif

#endif /* PSO_ARCHIVE_H */
