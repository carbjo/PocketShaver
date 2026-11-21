/*
 *  metal_device_shared.h - Shared Metal device singleton interface
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Shared Metal device and queue, returned as void* so plain .cpp files can
 *  include this header.
 */

#ifndef METAL_DEVICE_SHARED_H
#define METAL_DEVICE_SHARED_H

#ifdef __cplusplus
extern "C" {
#endif

/* Shared id<MTLDevice>, or NULL if no Metal GPU. Thread-safe. */
void *SharedMetalDevice(void);

/* Shared id<MTLCommandQueue>; creates the device if needed. Thread-safe. */
void *SharedMetalCommandQueue(void);

/* DEBUG only: adds a completedHandler to the id<MTLCommandBuffer> that
 * asserts on error. No-op in release. */
void MetalValidation_InstallErrorHandler(void *cmdBufPtr);


#ifdef __cplusplus
}
#endif

#endif /* METAL_DEVICE_SHARED_H */
