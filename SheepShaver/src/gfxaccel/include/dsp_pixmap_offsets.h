/*
 *  dsp_pixmap_offsets.h - PixMap field offsets and Mac OS lowmem globals.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  DSP_PIXMAP_OFF_* is the compact PixMap subset used by DSp's alt-buffer
 *  shim. DSP_MAINDEVICE_PIXMAP_OFF_* is the real QuickDraw PixMap layout used
 *  by MainDevice and real DSp CGrafPorts.
 */
#ifndef DSP_PIXMAP_OFFSETS_H
#define DSP_PIXMAP_OFFSETS_H

/* Compact synthetic PixMap field offsets (bytes from shim PixMap base). */
#define DSP_PIXMAP_OFF_BASEADDR     0    /* 4 bytes */
#define DSP_PIXMAP_OFF_ROWBYTES     4    /* 2 bytes from here on */
#define DSP_PIXMAP_OFF_BOUNDS_TOP   6
#define DSP_PIXMAP_OFF_BOUNDS_LEFT  8
#define DSP_PIXMAP_OFF_BOUNDS_BOT  10
#define DSP_PIXMAP_OFF_BOUNDS_RIGHT 12
#define DSP_PIXMAP_OFF_PIXELTYPE   14
#define DSP_PIXMAP_OFF_PIXELSIZE   16
#define DSP_PIXMAP_OFF_CMPCOUNT    18
#define DSP_PIXMAP_OFF_CMPSIZE     20

/* Real QuickDraw PixMap offsets for MainDevice.gdPMap. */
#define DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR     0
#define DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES     4
#define DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP   6
#define DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT  8
#define DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT  10
#define DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT 12
#define DSP_MAINDEVICE_PIXMAP_OFF_PMVERSION   14
#define DSP_MAINDEVICE_PIXMAP_OFF_PACKTYPE    16
#define DSP_MAINDEVICE_PIXMAP_OFF_PACKSIZE    18
#define DSP_MAINDEVICE_PIXMAP_OFF_HRES        22
#define DSP_MAINDEVICE_PIXMAP_OFF_VRES        26
#define DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE   30
#define DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE   32
#define DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT    34
#define DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE     36
#define DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES  38
#define DSP_MAINDEVICE_PIXMAP_OFF_PMTABLE     42
#define DSP_MAINDEVICE_PIXMAP_OFF_PMRESERVED  46
#define DSP_MAINDEVICE_PIXMAP_SIZE            50

/* Lowmem MainDevice holds a GDeviceHandle; dereference it twice and add
 * GDEVICE_OFF_PMAP to reach the PixMapHandle (IM: Imaging With QuickDraw
 * ch.4). gdFlags at 0x14 is only 2 bytes, so gdPMap is at 0x16, not 0x14. */
#define LMADDR_MAIN_DEVICE  0x8A4   /* GDeviceHandle */
#define GDEVICE_OFF_PMAP    0x16    /* GDevice.gdPMap (PixMapHandle) */

/* gdRect follows gdPMap, gdRefCon and gdNextGD. Apps center on it as the
 * display's global bounds, so a DSp mode switch must rewrite it along with
 * the PixMap bounds (Diablo II mis-centers against a stale gdRect). */
#define GDEVICE_OFF_GDRECT  0x22    /* GDevice.gdRect (Rect, 8 bytes) */

#endif /* include guard */
