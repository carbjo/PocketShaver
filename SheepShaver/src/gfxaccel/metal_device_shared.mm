/*
 *  metal_device_shared.mm - Shared Metal device singleton implementation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Process-wide Metal device and command queue, shared by NQD, RAVE,
 *  GL and the compositor so resources can be shared without copies.
 */

#import <Metal/Metal.h>
#include "metal_device_shared.h"

static id<MTLDevice>        s_device = nil;
static id<MTLCommandQueue>  s_queue  = nil;

static dispatch_once_t s_device_token;
static dispatch_once_t s_queue_token;

void *SharedMetalDevice(void)
{
    dispatch_once(&s_device_token, ^{
        s_device = MTLCreateSystemDefaultDevice();
        if (s_device) {
            printf("SharedMetalDevice: created device=%p (%s)\n",
                   (__bridge void *)s_device,
                   [[s_device name] UTF8String]);
        } else {
            printf("SharedMetalDevice: MTLCreateSystemDefaultDevice failed\n");
        }
    });
    return (__bridge void *)s_device;
}

// Debug builds assert on command buffer errors.
#ifdef DEBUG
static void MetalValidation_CheckCommandBufferError(id<MTLCommandBuffer> cmdBuf)
{
    if (cmdBuf.error != nil) {
        NSCAssert(NO, @"[Metal Validation] Command buffer error: %@\n"
                       "Status: %lu\nDevice: %@",
                  cmdBuf.error.localizedDescription,
                  (unsigned long)cmdBuf.status,
                  [cmdBuf.device name]);
    }
}

extern "C" void MetalValidation_InstallErrorHandler(void *cmdBufPtr)
{
    id<MTLCommandBuffer> cmdBuf = (__bridge id<MTLCommandBuffer>)cmdBufPtr;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull completed) {
        MetalValidation_CheckCommandBufferError(completed);
    }];
}
#else
extern "C" void MetalValidation_InstallErrorHandler(void *cmdBufPtr)
{
    (void)cmdBufPtr; // no-op in release
}
#endif

void *SharedMetalCommandQueue(void)
{
    SharedMetalDevice();

    dispatch_once(&s_queue_token, ^{
        if (s_device) {
            s_queue = [s_device newCommandQueue];
            if (s_queue) {
                printf("SharedMetalCommandQueue: created queue=%p\n",
                       (__bridge void *)s_queue);
            } else {
                printf("SharedMetalCommandQueue: newCommandQueue failed\n");
            }
        }
    });
    return (__bridge void *)s_queue;
}
