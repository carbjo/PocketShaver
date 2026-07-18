/*
 *	clip_ios.mm - Clipboard handling, UIKit (UIPasteboard) implementation for iOS and Mac Catalyst
 *
 *	(C) 2012 Jean-Pierre Stierlin
 *	(C) 2012 Alexei Svitkine
 *	(C) 2012 Charles Srstka
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *	This program is free software; you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation; either version 2 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program; if not, write to the Free Software
 *	Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "sysdeps.h"
#define _UINT64
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <os/lock.h>

#include "clip.h"
#include "main.h"
#include "cpu_emulation.h"
#include "emul_op.h"
#include "autorelease.h"
#include "pict.h"

#define DEBUG 0
#include "debug.h"

// Clipboard diagnostics (ship-default off); view in Console.app filtered on "CLIP-DIAG"
#define CLIP_DIAG 0
#if CLIP_DIAG
#import <os/log.h>
static os_log_t ClipLog(void)
{
	static os_log_t log;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ log = os_log_create("com.carbjo.pocketshaver", "clip"); });
	return log;
}
#define CLIP_LOG(fmt, ...) os_log(ClipLog(), "[CLIP-DIAG] " fmt, ##__VA_ARGS__)

static NSString *FourCCString(uint32_t type)
{
	char c[5] = {
		(char)((type >> 24) & 0xff), (char)((type >> 16) & 0xff),
		(char)((type >> 8) & 0xff), (char)(type & 0xff), 0
	};
	for (int i = 0; i < 4; i++)
		if (c[i] < 0x20 || c[i] > 0x7e)
			c[i] = '.';
	return [NSString stringWithUTF8String:c];
}
#else
#define CLIP_LOG(fmt, ...)
#endif

#ifndef FOURCC
#define FOURCC(a,b,c,d) (((uint32)(a) << 24) | ((uint32)(b) << 16) | ((uint32)(c) << 8) | (uint32)(d))
#endif

#define TYPE_PICT FOURCC('P','I','C','T')
#define TYPE_TEXT FOURCC('T','E','X','T')
#define TYPE_STYL FOURCC('s','t','y','l')
#define TYPE_UTXT FOURCC('u','t','x','t')
#define TYPE_UT16 FOURCC('u','t','1','6')
#define TYPE_USTL FOURCC('u','s','t','l')
#define TYPE_MOOV FOURCC('m','o','o','v')
#define TYPE_SND  FOURCC('s','n','d',' ')
#define TYPE_ICNS FOURCC('i','c','n','s')

// font face types

enum {
	FONT_FACE_PLAIN = 0,
	FONT_FACE_BOLD = 1,
	FONT_FACE_ITALIC = 2,
	FONT_FACE_UNDERLINE = 4,
	FONT_FACE_OUTLINE = 8,
	FONT_FACE_SHADOW = 16,
	FONT_FACE_CONDENSED = 32,
	FONT_FACE_EXTENDED = 64
};

// Script Manager constants

#define smMacSysScript		18

static NSString * const kPasteboardTypeRTF = @"public.rtf";
static NSString * const kPasteboardTypeFlatRTFD = @"com.apple.flat-rtfd";
static NSString * const kPasteboardTypeHTML = @"public.html";
static NSString * const kPasteboardTypeUTF8 = @"public.utf8-plain-text";
static NSString * const kPasteboardTypePICT = @"com.apple.pict";
static NSString * const kPasteboardTypePNG = @"public.png";
// Private marker identifying content we published ourselves; UIPasteboard's
// changeCount is unreliable on Catalyst, so self-writes are detected by value
static NSString * const kPasteboardTypeMarker = @"com.carbjo.pocketshaver.scrap-id";

// Flag for PutScrap(): the data was put by GetScrap(), don't bounce it back to the host side.
// Only touched on the emulator thread (EMUL_OP context).
static bool we_put_this_data = false;

// Set by ZeroScrap(); the guest scrap snapshot is cleared on the next real PutScrap().
// Deferred so that ZeroScrap() during startup (and our own injections) don't wipe it.
// Emulator thread only.
static bool should_clear = false;

// Flavors the guest has put on its scrap since the last ZeroScrap(). Emulator thread only.
static NSMutableDictionary<NSNumber *, NSData *> *g_guest_scrap = nil;

// Host pasteboard content waiting to be injected into the guest scrap.
// Written on the main thread, consumed on the emulator thread.
static os_unfair_lock g_pending_lock = OS_UNFAIR_LOCK_INIT;
static NSAttributedString *g_pending_host_attr = nil;					// preferred, from RTF
static NSString *g_pending_host_text = nil;								// fallback, plain text
static NSData *g_pending_host_pict = nil;								// raw PICT from the host, if any
static UIImage *g_pending_host_image = nil;								// host image to convert to PICT
static NSDictionary<NSNumber *, NSData *> *g_pending_host_flavors = nil;	// other flavors, keyed by FourCC

// UIPasteboard change count at our last read or write. Main thread only.
// Advisory only: unreliable on Catalyst, so it never gates correctness there.
static NSInteger g_host_change_count = 0;

// UUID of the item we last published, and a signature of the host content we
// last stashed for injection. Main thread only.
static NSString *g_last_published_uuid = nil;
static NSString *g_last_stash_signature = nil;

static id g_pasteboard_observers[3] = { nil, nil, nil };

/*
 *  Big-endian field access for packed 'styl' records
 */

static inline uint16_t ReadBE16(const uint8_t *p)
{
	uint16_t v;
	memcpy(&v, p, sizeof(v));
	return CFSwapInt16BigToHost(v);
}

static inline uint32_t ReadBE32(const uint8_t *p)
{
	uint32_t v;
	memcpy(&v, p, sizeof(v));
	return CFSwapInt32BigToHost(v);
}

/*
 *  Map classic Mac scrap flavors to pasteboard type strings and back.
 *  The kUTTagClassOSType conversion APIs don't exist on iOS, so known flavors
 *  are mapped by table and everything else uses the same legacy
 *  "CorePasteboardFlavorType 0x%08X" form that macOS uses for unmapped flavors.
 */

static NSString *UTIForFlavor(uint32_t type)
{
	switch (type) {
		case TYPE_PICT:
			return kPasteboardTypePICT;
		case TYPE_MOOV:
			return @"com.apple.quicktime-movie";
		case TYPE_SND:
			return @"public.audio";
		case TYPE_ICNS:
			return @"com.apple.icns";
		default:
			return [NSString stringWithFormat:@"CorePasteboardFlavorType 0x%08X", type];
	}
}

static uint32_t FlavorForUTI(NSString *uti)
{
	if ([uti isEqualToString:kPasteboardTypePICT])
		return TYPE_PICT;
	if ([uti isEqualToString:@"com.apple.quicktime-movie"])
		return TYPE_MOOV;
	if ([uti isEqualToString:@"public.audio"])
		return TYPE_SND;
	if ([uti isEqualToString:@"com.apple.icns"])
		return TYPE_ICNS;

	unsigned int type = 0;
	if (sscanf([uti UTF8String], "CorePasteboardFlavorType 0x%8x", &type) == 1)
		return type;

	return 0;
}

/*
 *	Get current system script encoding on Mac
 */

static int GetMacScriptManagerVariable(uint16_t varID)
{
	int ret = -1;
	M68kRegisters r;
	static uint8_t proc[] = {
		0x59, 0x4f,							// subq.w	 #4,sp
		0x3f, 0x3c, 0x00, 0x00,				// move.w	 #varID,-(sp)
		0x2f, 0x3c, 0x84, 0x02, 0x00, 0x08, // move.l	 #-2080243704,-(sp)
		0xa8, 0xb5,							// ScriptUtil()
		0x20, 0x1f,							// move.l	 (a7)+,d0
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 4, varID);
		Execute68k(proc_area, &r);
		ret = r.d[0];
		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
	return ret;
}

static ScriptCode ScriptNumberForFontID(int16_t fontID)
{
	ScriptCode ret = -1;
	M68kRegisters r;
	static uint8_t proc[] = {
		0x55, 0x4f,							// subq.w	#2,sp
		0x3f, 0x3c, 0x00, 0x00,				// move.w	#fontID,-(sp)
		0x2f, 0x3c, 0x82, 0x02, 0x00, 0x06, // move.l	#-2113798138,-(sp)
		0xa8, 0xb5,							// ScriptUtil()
		0x30, 0x1f,							// move.w	(sp)+,d0
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 4, fontID);
		Execute68k(proc_area, &r);
		ret = r.d[0];
		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
	return ret;
}

/*
 *	Text encoding for a guest script code. Classic Mac script codes up to 32
 *	are numerically identical to the corresponding kCFStringEncodingMac* constants.
 */

static CFStringEncoding EncodingForScript(int script)
{
	if (script < 0 || script > 32 || !CFStringIsEncodingAvailable((CFStringEncoding)script))
		return kCFStringEncodingMacRoman;
	return (CFStringEncoding)script;
}

/*
 *	Text encoding of the guest system script.
 *	Must be called from the emulator thread (uses Execute68k).
 */

static CFStringEncoding GuestTextEncoding(void)
{
	return EncodingForScript(GetMacScriptManagerVariable(smMacSysScript));
}

/*
 *  Classic Mac fonts largely don't exist on iOS, and modern host families don't
 *  exist in the guest; map the common ones to a reasonable counterpart instead
 *  of letting everything collapse to the default font.
 */

static NSString *HostFontNameForGuestFont(NSString *guestName)
{
	if (!guestName)
		return nil;

	static NSDictionary<NSString *, NSString *> *map = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		map = @{
			@"Geneva":    @"Verdana",
			@"New York":  @"Georgia",
			@"Monaco":    @"Menlo",
			@"Courier":   @"Courier New",
			@"Times":     @"Times New Roman",
			@"Chicago":   @"Verdana",
			@"Charcoal":  @"Verdana",
		};
	});
	return [map objectForKey:guestName];
}

static NSString *GuestFontNameForHostFamily(NSString *family)
{
	if (!family)
		return nil;

	static NSDictionary<NSString *, NSString *> *map = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		map = @{
			@"Verdana":          @"Geneva",
			@"Georgia":          @"New York",
			@"Menlo":            @"Monaco",
			@"Courier New":      @"Courier",
			@"Times New Roman":  @"Times",
			@"Helvetica Neue":   @"Helvetica",
			@"Arial":            @"Helvetica",
		};
	});
	return [map objectForKey:family];
}

/*
 *  Convert Mac font ID to font name
 */

static NSString *FontNameFromFontID(int16_t fontID)
{
	M68kRegisters r;
	r.d[0] = 256;					// Str255: 255 characters + length byte
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t name_area = r.a[0];

	if (!name_area)
		return nil;

	uint8_t proc[] = {
		0x3f, 0x3c, 0, 0,	// move.w	#fontID,-(sp)
		0x2f, 0x0a,			// move.l	A2,-(sp)
		0xa8, 0xff,			// GetFontName()
		M68K_RTS >> 8, M68K_RTS & 0xff
	};

	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 2, fontID);
		r.a[2] = name_area;
		Execute68k(proc_area, &r);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}

	uint8_t * const namePtr = Mac2HostAddr(name_area);

	NSString *name = (__bridge_transfer NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, namePtr, kCFStringEncodingMacRoman);

	r.a[0] = name_area;
	Execute68kTrap(0xa01f, &r);			// DisposePtr

	return name;
}

/*
 *  Convert font name to Mac font ID
 */

static int16_t FontIDFromFontName(NSString *fontName)
{
	if (!fontName)
		return 0;

	M68kRegisters r;
	r.d[0] = 256;					// Str255: 255 characters + length byte
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t name_area = r.a[0];

	if (!name_area)
		return 0;

	uint8_t * const namePtr = Mac2HostAddr(name_area);

	CFStringGetPascalString((__bridge CFStringRef)fontName, namePtr, 256, kCFStringEncodingMacRoman);

	uint8_t proc[] = {
		0x2f, 0x0a,			// move.l	A2,-(sp)
		0x2f, 0x0b,			// move.l	A3,-(sp)
		0xa9, 0x00,			// GetFNum()
		M68K_RTS >> 8, M68K_RTS & 0xff,
		0, 0
	};

	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	int16_t fontID = 0;

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		r.a[2] = name_area;
		r.a[3] = proc_area + 8;

		Execute68k(proc_area, &r);

		fontID = ReadMacInt16(proc_area + 8);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}

	r.a[0] = name_area;
	Execute68kTrap(0xa01f, &r);			// DisposePtr

	return fontID;
}

/*
 *  Zero Mac clipboard
 */

static void ZeroMacClipboard()
{
	D(bug("Zeroing Mac clipboard\n"));
	M68kRegisters r;
	static uint8_t proc[] = {
		0x59, 0x8f,					// subq.l	#4,sp
		0xa9, 0xfc,					// ZeroScrap()
		0x58, 0x8f,					// addq.l	#4,sp
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		Execute68k(proc_area, &r);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
}

/*
 *  Write data to Mac clipboard
 */

static void WriteDataToMacClipboard(NSData *pbData, uint32_t type)
{
	D(bug("Writing data %s to Mac clipboard with type '%c%c%c%c'\n", [[pbData description] UTF8String],
		  (type >> 24) & 0xff, (type >> 16) & 0xff, (type >> 8) & 0xff, type & 0xff));

	if ([pbData length] == 0)
		return;

	// Allocate space for new scrap in MacOS side
	M68kRegisters r;
	r.d[0] = (uint32)[pbData length];
	Execute68kTrap(0xa71e, &r);				// NewPtrSysClear()
	uint32_t scrap_area = r.a[0];

	// Get the native clipboard data
	if (scrap_area) {
		uint8_t * const data = Mac2HostAddr(scrap_area);

		memcpy(data, [pbData bytes], [pbData length]);

		// Add new data to clipboard
		static uint8_t proc[] = {
			0x59, 0x8f,					// subq.l	#4,sp
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#length,-(sp)
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#type,-(sp)
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#outbuf,-(sp)
			0xa9, 0xfe,					// PutScrap()
			0x58, 0x8f,					// addq.l	#4,sp
			M68K_RTS >> 8, M68K_RTS & 0xff
		};
		r.d[0] = sizeof(proc);
		Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
		uint32_t proc_area = r.a[0];

		if (proc_area) {
			Host2Mac_memcpy(proc_area, proc, sizeof(proc));
			WriteMacInt32(proc_area + 4, (uint32)[pbData length]);
			WriteMacInt32(proc_area + 10, type);
			WriteMacInt32(proc_area + 16, scrap_area);
			we_put_this_data = true;
			Execute68k(proc_area, &r);

			r.a[0] = proc_area;
			Execute68kTrap(0xa01f, &r); // DisposePtr
		}

		r.a[0] = scrap_area;
		Execute68kTrap(0xa01f, &r);			// DisposePtr
	}
}

/*
 *  Convert Mac TEXT/styl to attributed string.
 *  Must be called from the emulator thread (font/script lookups use Execute68k).
 */

static NSAttributedString *AttributedStringFromMacTEXTAndStyl(NSData *textData, NSData *stylData)
{
	const uint8_t *bytes = (const uint8_t *)[stylData bytes];
	NSUInteger length = [stylData length];
	NSUInteger textLength = [textData length];
	const uint8_t *textBytes = (const uint8_t *)[textData bytes];

	if (length < 2)
		return nil;

	uint16_t elements = ReadBE16(bytes);
	const NSUInteger elementSize = 20;

	if (length < 2 + elements * elementSize)
		return nil;

	NSMutableAttributedString *aStr = [[NSMutableAttributedString alloc] init];
	NSUInteger cursor = 2;

	for (NSUInteger i = 0; i < elements; i++) AUTORELEASE_POOL {
		uint32_t startChar = ReadBE32(bytes + cursor); cursor += 4;
		cursor += 2;	// height (unused)
		cursor += 2;	// ascent (unused)
		int16_t fontID = (int16_t)ReadBE16(bytes + cursor); cursor += 2;
		uint8_t face = bytes[cursor]; cursor += 2;
		int16_t size = (int16_t)ReadBE16(bytes + cursor); cursor += 2;
		uint16_t red = ReadBE16(bytes + cursor); cursor += 2;
		uint16_t green = ReadBE16(bytes + cursor); cursor += 2;
		uint16_t blue = ReadBE16(bytes + cursor); cursor += 2;

		uint32_t nextChar;

		if (i + 1 == elements)
			nextChar = (uint32_t)textLength;
		else
			nextChar = ReadBE32(bytes + cursor);

		if (startChar > textLength || nextChar > textLength || startChar > nextChar)
			return nil;

		CGFloat fontSize = (size <= 0) ? [UIFont systemFontSize] : (CGFloat)size;
		UIFont *font = nil;

		if (fontID != 0 && fontID != 1) {	// 0 = system font, 1 = application font
			NSString *fontName = FontNameFromFontID(fontID);
			font = [UIFont fontWithName:fontName size:fontSize];

			if (font == nil && fontName != nil) {
				NSString *substitute = HostFontNameForGuestFont(fontName);
				if (substitute) {
					UIFontDescriptor *desc = [UIFontDescriptor fontDescriptorWithFontAttributes:@{UIFontDescriptorFamilyAttribute: substitute}];
					font = [UIFont fontWithDescriptor:desc size:fontSize];
				}
			}

			if (font == nil && fontName != nil) {
				// Convert localized variants of fonts; e.g. "Helvetica CE" to "Helvetica"
				NSRange wsRange = [fontName rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet] options:NSBackwardsSearch];

				if (wsRange.length) {
					fontName = [fontName substringToIndex:wsRange.location];
					font = [UIFont fontWithName:fontName size:fontSize];
				}
			}
		}

		if (font == nil)
			font = [UIFont systemFontOfSize:fontSize];

		UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits;

		if (face & FONT_FACE_BOLD)
			traits |= UIFontDescriptorTraitBold;
		if (face & FONT_FACE_ITALIC)
			traits |= UIFontDescriptorTraitItalic;
		if (face & FONT_FACE_CONDENSED)
			traits |= UIFontDescriptorTraitCondensed;
		if (face & FONT_FACE_EXTENDED)
			traits |= UIFontDescriptorTraitExpanded;

		if (traits != font.fontDescriptor.symbolicTraits) {
			UIFontDescriptor *desc = [font.fontDescriptor fontDescriptorWithSymbolicTraits:traits];
			if (desc)
				font = [UIFont fontWithDescriptor:desc size:fontSize];
		}

		NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
		UIColor *color = [UIColor colorWithRed:(CGFloat)red / 65535.0 green:(CGFloat)green / 65535.0 blue:(CGFloat)blue / 65535.0 alpha:1.0];

		[attrs setObject:font forKey:NSFontAttributeName];
		[attrs setObject:color forKey:NSForegroundColorAttributeName];

		if (face & FONT_FACE_UNDERLINE)
			[attrs setObject:@(NSUnderlineStyleSingle) forKey:NSUnderlineStyleAttributeName];

		if (face & FONT_FACE_OUTLINE) {
			[attrs setObject:color forKey:NSStrokeColorAttributeName];
			[attrs setObject:@3 forKey:NSStrokeWidthAttributeName];
		}

		if (face & FONT_FACE_SHADOW) {
			NSShadow *shadow = [[NSShadow alloc] init];
			shadow.shadowColor = [color colorWithAlphaComponent:0.5];
			shadow.shadowOffset = CGSizeMake(2.0, 2.0);
			[attrs setObject:shadow forKey:NSShadowAttributeName];
		}

		// Decode this run's bytes with the encoding of its font's script
		CFStringEncoding encoding = EncodingForScript(ScriptNumberForFontID(fontID));
		NSString *partialString = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, textBytes + startChar, nextChar - startChar, encoding, false);

		if (!partialString && encoding != kCFStringEncodingMacRoman)
			partialString = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, textBytes + startChar, nextChar - startChar, kCFStringEncodingMacRoman, false);

		if (partialString) {
			NSAttributedString *partial = [[NSAttributedString alloc] initWithString:partialString attributes:attrs];
			[aStr appendAttributedString:partial];
		}
	}

	if ([aStr length] == 0)
		return nil;

	return aStr;
}

/*
 *  Append one 'styl' record (minus the offset field) for a run's attributes
 */

static void AppendStylRunData(NSMutableData *stylData, NSDictionary *attrs)
{
	UIFont *font = [attrs objectForKey:NSFontAttributeName];
	if (!font)
		font = [UIFont systemFontOfSize:[UIFont systemFontSize]];

	UIColor *color = [attrs objectForKey:NSForegroundColorAttributeName];
	NSNumber *underlineStyle = [attrs objectForKey:NSUnderlineStyleAttributeName];
	NSNumber *strokeWidth = [attrs objectForKey:NSStrokeWidthAttributeName];
	NSShadow *shadow = [attrs objectForKey:NSShadowAttributeName];

	UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits;

	int16_t hostFontID = FontIDFromFontName([font familyName]);

	if (hostFontID == 0) {
		NSString *guestName = GuestFontNameForHostFamily([font familyName]);
		if (guestName)
			hostFontID = FontIDFromFontName(guestName);
	}

	if (hostFontID == 0) {
		hostFontID = (traits & UIFontDescriptorTraitMonoSpace) ? 4 /* Monaco */ : 1 /* Application font */;
	}

	CGFloat r = 0.0, g = 0.0, b = 0.0, a = 1.0;
	if (color && ![color getRed:&r green:&g blue:&b alpha:&a]) {
		CGFloat white = 0.0;
		if ([color getWhite:&white alpha:&a])
			r = g = b = white;
	}

	int16_t height = CFSwapInt16HostToBig((int16_t)rint(font.lineHeight));
	int16_t ascent = CFSwapInt16HostToBig((int16_t)rint(font.ascender));
	int16_t fontID = CFSwapInt16HostToBig(hostFontID);
	uint8_t face = 0;
	int16_t size = CFSwapInt16HostToBig((int16_t)rint(font.pointSize));
	uint16_t red = CFSwapInt16HostToBig((uint16_t)rint(r * 65535.0));
	uint16_t green = CFSwapInt16HostToBig((uint16_t)rint(g * 65535.0));
	uint16_t blue = CFSwapInt16HostToBig((uint16_t)rint(b * 65535.0));

	if (traits & UIFontDescriptorTraitBold)
		face |= FONT_FACE_BOLD;
	if (traits & UIFontDescriptorTraitItalic)
		face |= FONT_FACE_ITALIC;
	if (traits & UIFontDescriptorTraitCondensed)
		face |= FONT_FACE_CONDENSED;
	if (traits & UIFontDescriptorTraitExpanded)
		face |= FONT_FACE_EXTENDED;

	if (underlineStyle && [underlineStyle integerValue] != NSUnderlineStyleNone)
		face |= FONT_FACE_UNDERLINE;

	if (strokeWidth && [strokeWidth doubleValue] > 0.0)
		face |= FONT_FACE_OUTLINE;

	if (shadow)
		face |= FONT_FACE_SHADOW;

	[stylData appendBytes:&height length:2];
	[stylData appendBytes:&ascent length:2];
	[stylData appendBytes:&fontID length:2];
	[stylData appendBytes:&face length:1];
	[stylData increaseLengthBy:1];
	[stylData appendBytes:&size length:2];
	[stylData appendBytes:&red length:2];
	[stylData appendBytes:&green length:2];
	[stylData appendBytes:&blue length:2];
}

/*
 *  Convert attributed string to TEXT/styl. Style offsets are byte offsets into
 *  the returned TEXT data, so each attribute run is encoded separately.
 *  Must be called from the emulator thread (font/script lookups use Execute68k).
 */

static NSData *ConvertToMacTEXTAndStyl(NSAttributedString *aStr, NSData **outStylData)
{
	// Limitations imposed by the Mac TextEdit system: 32767 bytes of TEXT and
	// 1601 style runs. Stay a little under the byte limit for safety.
	const NSUInteger charLimit = 32 * 1024;
	const NSUInteger byteLimit = 32000;
	const NSUInteger elementLimit = 1601;

	if ([aStr length] > charLimit)
		aStr = [aStr attributedSubstringFromRange:NSMakeRange(0, charLimit)];

	CFStringEncoding encoding = GuestTextEncoding();
	NSString *string = [aStr string];

	NSMutableData *textData = [NSMutableData data];
	NSMutableData *stylData = [NSMutableData dataWithLength:2]; // number of styles to be filled in at the end
	__block NSUInteger elements = 0;

	[aStr enumerateAttributesInRange:NSMakeRange(0, [aStr length])
							 options:0
						  usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
		NSUInteger oldLength = [textData length];
		CFIndex capacity = byteLimit - oldLength;

		if (capacity <= 0) {
			*stop = YES;
			return;
		}

		// CFStringGetBytes converts the longest prefix of the run that fits
		CFRange cfRange = CFRangeMake(range.location, range.length);
		CFIndex bufLen = 0;
		CFIndex converted = CFStringGetBytes((__bridge CFStringRef)string, cfRange, encoding, '?', false, NULL, 0, &bufLen);
		if (converted <= 0 || bufLen <= 0)
			return;

		if (bufLen > capacity)
			bufLen = capacity;

		uint32_t startChar = CFSwapInt32HostToBig((uint32_t)oldLength);

		[textData increaseLengthBy:bufLen];
		converted = CFStringGetBytes((__bridge CFStringRef)string, cfRange, encoding, '?', false, (UInt8 *)[textData mutableBytes] + oldLength, bufLen, &bufLen);
		[textData setLength:oldLength + bufLen];

		if (converted <= 0 || bufLen <= 0) {
			[textData setLength:oldLength];
			return;
		}

		if (converted < (CFIndex)range.length)
			*stop = YES;	// ran out of room mid-run; keep what fit

		if (elements < elementLimit) {
			[stylData appendBytes:&startChar length:4];
			AppendStylRunData(stylData, attrs);
			elements++;
		}
	}];

	// Safety net: if run-by-run encoding produced nothing, fall back to encoding
	// the whole string unstyled rather than injecting nothing at all
	if (![textData length] && [string length]) {
		elements = 0;
		[stylData setLength:2];

		NSMutableData *fallback = [NSMutableData dataWithLength:byteLimit];
		CFIndex used = 0;
		CFIndex converted = CFStringGetBytes((__bridge CFStringRef)string, CFRangeMake(0, [string length]), encoding, '?', false,
											 (UInt8 *)[fallback mutableBytes], byteLimit, &used);
		if (converted > 0 && used > 0) {
			[fallback setLength:used];
			textData = fallback;
		}
	}

	uint16_t bigEndianElements = CFSwapInt16HostToBig((uint16_t)elements);
	[stylData replaceBytesInRange:NSMakeRange(0, 2) withBytes:&bigEndianElements length:2];

	if (outStylData)
		*outStylData = stylData;

	return textData;
}

/*
 *  Convert a host image to PICT via its RGBA pixels
 */

static NSData *PICTDataFromImage(UIImage *image)
{
	// Pixel dimensions as displayed (accounts for EXIF orientation)
	double displayWidth = image.size.width * image.scale;
	double displayHeight = image.size.height * image.scale;

	if (displayWidth < 1.0 || displayHeight < 1.0)
		return nil;

	// Scale huge images down: 32-bit PICT RLE barely compresses photos, so a
	// full-size photo would exceed what the guest's system heap can allocate,
	// and the RGBA staging buffer could exhaust memory on iOS.
	const double maxDimension = 2048;
	if (displayWidth > maxDimension || displayHeight > maxDimension) {
		double scale = maxDimension / (displayWidth > displayHeight ? displayWidth : displayHeight);
		displayWidth = floor(displayWidth * scale);
		displayHeight = floor(displayHeight * scale);
	}

	size_t width = (size_t)displayWidth;
	size_t height = (size_t)displayHeight;

	if (width == 0 || height == 0)
		return nil;

	NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
	if (!rgba)
		return nil;

	CGImageRef cgImage = [image CGImage];
	if (!cgImage)
		return nil;

	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate([rgba mutableBytes], width, height, 8, width * 4, colorSpace,
												 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(colorSpace);

	if (!context)
		return nil;

	// Classic QuickDraw has no alpha channel; composite transparency onto white
	// so it doesn't come out black in the guest
	CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
	CGContextFillRect(context, CGRectMake(0, 0, width, height));

	// image.CGImage is the unrotated bitmap; apply the EXIF orientation
	// ourselves. Pure CoreGraphics so it is safe on the emulator thread.
	CGAffineTransform transform = CGAffineTransformIdentity;
	UIImageOrientation orientation = image.imageOrientation;

	switch (orientation) {
		case UIImageOrientationDown:
		case UIImageOrientationDownMirrored:
			transform = CGAffineTransformTranslate(transform, width, height);
			transform = CGAffineTransformRotate(transform, M_PI);
			break;
		case UIImageOrientationLeft:
		case UIImageOrientationLeftMirrored:
			transform = CGAffineTransformTranslate(transform, width, 0);
			transform = CGAffineTransformRotate(transform, M_PI_2);
			break;
		case UIImageOrientationRight:
		case UIImageOrientationRightMirrored:
			transform = CGAffineTransformTranslate(transform, 0, height);
			transform = CGAffineTransformRotate(transform, -M_PI_2);
			break;
		default:
			break;
	}

	switch (orientation) {
		case UIImageOrientationUpMirrored:
		case UIImageOrientationDownMirrored:
			transform = CGAffineTransformTranslate(transform, width, 0);
			transform = CGAffineTransformScale(transform, -1.0, 1.0);
			break;
		case UIImageOrientationLeftMirrored:
		case UIImageOrientationRightMirrored:
			transform = CGAffineTransformTranslate(transform, height, 0);
			transform = CGAffineTransformScale(transform, -1.0, 1.0);
			break;
		default:
			break;
	}

	CGContextConcatCTM(context, transform);

	switch (orientation) {
		case UIImageOrientationLeft:
		case UIImageOrientationLeftMirrored:
		case UIImageOrientationRight:
		case UIImageOrientationRightMirrored:
			// Rotated 90°: the draw rect is in pre-rotation coordinates
			CGContextDrawImage(context, CGRectMake(0, 0, height, width), cgImage);
			break;
		default:
			CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
			break;
	}

	CGContextRelease(context);

	ssize_t bufSize = ConvertRGBAToPICT(NULL, 0, (uint8_t *)[rgba mutableBytes], (uint16_t)width, (uint16_t)height);
	if (bufSize <= 0)
		return nil;

	NSMutableData *pictData = [NSMutableData dataWithLength:bufSize];
	if (!pictData)
		return nil;

	ssize_t pictSize = ConvertRGBAToPICT((uint8_t *)[pictData mutableBytes], bufSize, (uint8_t *)[rgba mutableBytes], (uint16_t)width, (uint16_t)height);
	if (pictSize <= 0)
		return nil;

	[pictData setLength:pictSize];
	return pictData;
}

/*
 *  Minimal PICT v2 decoder: handles the bitmap opcodes classic apps put on the
 *  clipboard (PackBitsRect/PackBitsRgn for indexed pixmaps, DirectBitsRect/
 *  DirectBitsRgn for 16/24/32-bit), skipping vector content by opcode size.
 *  Produces PNG so modern host apps can paste guest images.
 */

typedef struct {
	const uint8_t *bytes;
	size_t length;
	size_t cursor;
	bool failed;
} PICTReader;

static bool PICTNeed(PICTReader *r, size_t n)
{
	if (r->failed || r->cursor + n > r->length) {
		r->failed = true;
		return false;
	}
	return true;
}

static uint8_t PICTRead8(PICTReader *r)
{
	if (!PICTNeed(r, 1))
		return 0;
	return r->bytes[r->cursor++];
}

static uint16_t PICTRead16(PICTReader *r)
{
	if (!PICTNeed(r, 2))
		return 0;
	uint16_t v = ((uint16_t)r->bytes[r->cursor] << 8) | r->bytes[r->cursor + 1];
	r->cursor += 2;
	return v;
}

static uint32_t PICTRead32(PICTReader *r)
{
	uint32_t hi = PICTRead16(r);
	return (hi << 16) | PICTRead16(r);
}

static void PICTSkip(PICTReader *r, size_t n)
{
	PICTNeed(r, n);
	if (!r->failed)
		r->cursor += n;
}

static void PICTAlign(PICTReader *r)
{
	if ((r->cursor & 1) && !r->failed)
		r->cursor++;
}

typedef struct {
	int16_t top, left, bottom, right;
} PICTRect;

static PICTRect PICTReadRect(PICTReader *r)
{
	PICTRect rect;
	rect.top = (int16_t)PICTRead16(r);
	rect.left = (int16_t)PICTRead16(r);
	rect.bottom = (int16_t)PICTRead16(r);
	rect.right = (int16_t)PICTRead16(r);
	return rect;
}

static void PICTSkipRegion(PICTReader *r)
{
	uint16_t size = PICTRead16(r);
	if (size < 2) {
		r->failed = true;
		return;
	}
	PICTSkip(r, size - 2);
}

// Unpack one PackBits-compressed run into dst (element size 1 or 2 bytes)
static bool PICTUnpackBits(PICTReader *r, size_t packedLength, uint8_t *dst, size_t dstLength, int elementSize)
{
	if (!PICTNeed(r, packedLength))
		return false;

	const uint8_t *src = r->bytes + r->cursor;
	size_t srcPos = 0, dstPos = 0;

	while (srcPos < packedLength && dstPos < dstLength) {
		uint8_t flag = src[srcPos++];

		if (flag == 0x80)
			continue;

		if (flag > 0x80) {
			// repeat next element (257 - flag) times
			size_t count = 257 - flag;
			if (srcPos + elementSize > packedLength)
				return false;
			for (size_t i = 0; i < count && dstPos + elementSize <= dstLength; i++)
				for (int e = 0; e < elementSize; e++)
					dst[dstPos++] = src[srcPos + e];
			srcPos += elementSize;
		} else {
			// copy (flag + 1) literal elements
			size_t count = (size_t)(flag + 1) * elementSize;
			if (srcPos + count > packedLength)
				return false;
			for (size_t i = 0; i < count && dstPos < dstLength; i++)
				dst[dstPos++] = src[srcPos + i];
			srcPos += count;
		}
	}

	r->cursor += packedLength;
	return true;
}

// Decode one PackBits/DirectBits opcode into the RGBA canvas; returns false on parse failure
static bool PICTDecodeBitsOp(PICTReader *r, uint16_t op, uint8_t *canvas, size_t canvasWidth, size_t canvasHeight, PICTRect frame)
{
	bool direct = (op == 0x009A || op == 0x009B);
	bool hasRegion = (op == 0x0099 || op == 0x009B);

	if (direct)
		PICTSkip(r, 4);		// baseAddr

	uint16_t rowBytesRaw = PICTRead16(r);
	bool isPixMap = (rowBytesRaw & 0x8000) != 0;
	uint16_t rowBytes = rowBytesRaw & 0x3fff;

	PICTRect bounds = PICTReadRect(r);
	int boundsWidth = bounds.right - bounds.left;
	int boundsHeight = bounds.bottom - bounds.top;

	if (boundsWidth <= 0 || boundsHeight <= 0 || rowBytes == 0)
		return false;

	uint16_t packType = 0;
	uint16_t pixelSize = 1;
	uint16_t cmpCount = 1;

	if (isPixMap) {
		PICTSkip(r, 2);					// pmVersion
		packType = PICTRead16(r);
		PICTSkip(r, 12);				// packSize, hRes, vRes
		PICTSkip(r, 2);					// pixelType
		pixelSize = PICTRead16(r);
		cmpCount = PICTRead16(r);
		PICTSkip(r, 2);					// cmpSize
		PICTSkip(r, 12);				// planeBytes, pmTable, pmReserved
	}

	// Color table follows the pixmap for indexed (non-direct) data
	uint32_t paletteCount = 0;
	uint8_t palette[256][3];

	if (!direct && isPixMap) {
		PICTSkip(r, 4);					// ctSeed
		PICTSkip(r, 2);					// ctFlags
		uint16_t ctSize = PICTRead16(r);
		paletteCount = (uint32_t)ctSize + 1;
		if (paletteCount > 256)
			return false;

		for (uint32_t i = 0; i < paletteCount; i++) {
			PICTSkip(r, 2);				// value
			palette[i][0] = PICTRead16(r) >> 8;
			palette[i][1] = PICTRead16(r) >> 8;
			palette[i][2] = PICTRead16(r) >> 8;
		}
	}

	PICTRect srcRect = PICTReadRect(r);
	PICTRect dstRect = PICTReadRect(r);
	PICTSkip(r, 2);						// transfer mode

	if (hasRegion)
		PICTSkipRegion(r);

	if (r->failed)
		return false;

	if (!direct && !isPixMap) {
		// old-style 1-bit BitMap: black and white
		pixelSize = 1;
		paletteCount = 2;
		palette[0][0] = palette[0][1] = palette[0][2] = 0xff;
		palette[1][0] = palette[1][1] = palette[1][2] = 0x00;
	} else if (!direct) {
		if (paletteCount == 0)
			return false;
	}

	// Decode all rows of the source pixmap into an RGBA staging buffer
	size_t stagingSize = (size_t)boundsWidth * boundsHeight * 4;
	if (stagingSize == 0 || stagingSize > 256 * 1024 * 1024)
		return false;

	uint8_t *staging = (uint8_t *)calloc(1, stagingSize);
	if (!staging)
		return false;

	size_t rowBufSize = (size_t)rowBytes + 16;
	uint8_t *rowBuf = (uint8_t *)malloc(rowBufSize);
	if (!rowBuf) {
		free(staging);
		return false;
	}

	bool ok = true;

	for (int y = 0; y < boundsHeight && ok; y++) {
		size_t rowDataLen = rowBytes;

		memset(rowBuf, 0, rowBufSize);

		if (rowBytes < 8 || packType == 1) {
			// unpacked
			if (!PICTNeed(r, rowBytes)) { ok = false; break; }
			memcpy(rowBuf, r->bytes + r->cursor, rowBytes);
			r->cursor += rowBytes;
		} else if (packType == 2) {
			// unpacked, pad byte dropped: 3 bytes per pixel
			rowDataLen = (size_t)boundsWidth * 3;
			if (rowDataLen > rowBufSize) { ok = false; break; }
			if (!PICTNeed(r, rowDataLen)) { ok = false; break; }
			memcpy(rowBuf, r->bytes + r->cursor, rowDataLen);
			r->cursor += rowDataLen;
		} else {
			// PackBits-compressed row with a byte-count prefix
			size_t packedLength = (rowBytes > 250) ? PICTRead16(r) : PICTRead8(r);
			if (r->failed) { ok = false; break; }

			int elementSize = (packType == 3) ? 2 : 1;
			if (!PICTUnpackBits(r, packedLength, rowBuf, rowBufSize, elementSize)) { ok = false; break; }
		}

		// Convert the row to RGBA
		uint8_t *outRow = staging + (size_t)y * boundsWidth * 4;

		if (direct) {
			if (pixelSize == 16) {
				for (int x = 0; x < boundsWidth; x++) {
					uint16_t px = ((uint16_t)rowBuf[x * 2] << 8) | rowBuf[x * 2 + 1];
					uint8_t rv = (px >> 10) & 0x1f, gv = (px >> 5) & 0x1f, bv = px & 0x1f;
					outRow[x * 4]     = (rv << 3) | (rv >> 2);
					outRow[x * 4 + 1] = (gv << 3) | (gv >> 2);
					outRow[x * 4 + 2] = (bv << 3) | (bv >> 2);
					outRow[x * 4 + 3] = 0xff;
				}
			} else if (pixelSize == 32 && packType == 4) {
				// component-planar row: (cmpCount) planes of width bytes
				int rgbOffset = (cmpCount == 4) ? 1 : 0;	// skip alpha plane
				for (int x = 0; x < boundsWidth; x++) {
					outRow[x * 4]     = rowBuf[(rgbOffset + 0) * boundsWidth + x];
					outRow[x * 4 + 1] = rowBuf[(rgbOffset + 1) * boundsWidth + x];
					outRow[x * 4 + 2] = rowBuf[(rgbOffset + 2) * boundsWidth + x];
					outRow[x * 4 + 3] = 0xff;
				}
			} else if (pixelSize == 32 || pixelSize == 24) {
				// chunky xRGB / RGB
				int bpp = (pixelSize == 32 && packType != 2) ? 4 : 3;
				int skip = (bpp == 4) ? 1 : 0;
				for (int x = 0; x < boundsWidth; x++) {
					outRow[x * 4]     = rowBuf[x * bpp + skip];
					outRow[x * 4 + 1] = rowBuf[x * bpp + skip + 1];
					outRow[x * 4 + 2] = rowBuf[x * bpp + skip + 2];
					outRow[x * 4 + 3] = 0xff;
				}
			} else {
				ok = false;
			}
		} else {
			// indexed: 1, 2, 4 or 8 bits per pixel
			if (pixelSize != 1 && pixelSize != 2 && pixelSize != 4 && pixelSize != 8) {
				ok = false;
			} else {
				int pixelsPerByte = 8 / pixelSize;
				uint8_t mask = (1 << pixelSize) - 1;
				for (int x = 0; x < boundsWidth; x++) {
					size_t byteIndex = x / pixelsPerByte;
					if (byteIndex >= rowBufSize)
						break;
					int shift = (pixelsPerByte - 1 - (x % pixelsPerByte)) * pixelSize;
					uint8_t index = (rowBuf[byteIndex] >> shift) & mask;
					if (index >= paletteCount)
						index = 0;
					outRow[x * 4]     = palette[index][0];
					outRow[x * 4 + 1] = palette[index][1];
					outRow[x * 4 + 2] = palette[index][2];
					outRow[x * 4 + 3] = 0xff;
				}
			}
		}
	}

	// Blit staging into the canvas: map dstRect (frame-relative) pixels back to srcRect
	if (ok) {
		int srcX = srcRect.left - bounds.left, srcY = srcRect.top - bounds.top;
		int srcW = srcRect.right - srcRect.left, srcH = srcRect.bottom - srcRect.top;
		int dstX = dstRect.left - frame.left, dstY = dstRect.top - frame.top;
		int dstW = dstRect.right - dstRect.left, dstH = dstRect.bottom - dstRect.top;

		if (srcW > 0 && srcH > 0 && dstW > 0 && dstH > 0) {
			for (int y = 0; y < dstH; y++) {
				int cy = dstY + y;
				if (cy < 0 || cy >= (int)canvasHeight)
					continue;
				int sy = srcY + (int)(((int64_t)y * srcH) / dstH);
				if (sy < 0 || sy >= boundsHeight)
					continue;
				for (int x = 0; x < dstW; x++) {
					int cx = dstX + x;
					if (cx < 0 || cx >= (int)canvasWidth)
						continue;
					int sx = srcX + (int)(((int64_t)x * srcW) / dstW);
					if (sx < 0 || sx >= boundsWidth)
						continue;
					memcpy(canvas + ((size_t)cy * canvasWidth + cx) * 4,
						   staging + ((size_t)sy * boundsWidth + sx) * 4, 4);
				}
			}
		}
	}

	free(rowBuf);
	free(staging);
	return ok && !r->failed;
}

// Decode a CompressedQuickTime opcode (0x8200): Photoshop and other QuickTime
// clients put JPEG-in-PICT on the clipboard. ImageIO decodes the embedded JPEG.
// Always consumes the payload so parsing can continue (these pictures often
// carry an uncompressed fallback bitmap after the QT opcode).
static bool PICTDecodeQuickTimeOp(PICTReader *r, uint8_t *canvas, size_t canvasWidth, size_t canvasHeight, PICTRect frame)
{
	uint32_t payloadLength = PICTRead32(r);
	if (!PICTNeed(r, payloadLength))
		return false;

	const uint8_t *payload = r->bytes + r->cursor;
	r->cursor += payloadLength;
	PICTAlign(r);

	// CompressedQuickTime payload: version(2) matrix(36) matteSize(4)
	// matteRect(8) mode(2) srcRect(8) accuracy(4) maskSize(4) ...
	PICTRect dst = frame;
	if (payloadLength >= 60) {
		dst.top = (int16_t)((payload[52] << 8) | payload[53]);
		dst.left = (int16_t)((payload[54] << 8) | payload[55]);
		dst.bottom = (int16_t)((payload[56] << 8) | payload[57]);
		dst.right = (int16_t)((payload[58] << 8) | payload[59]);
	}

	// Find the embedded JPEG; ImageIO tolerates trailing data
	size_t jpegOffset = SIZE_MAX;
	for (size_t i = 0; i + 3 < payloadLength; i++) {
		if (payload[i] == 0xFF && payload[i + 1] == 0xD8 && payload[i + 2] == 0xFF) {
			jpegOffset = i;
			break;
		}
	}

	if (jpegOffset == SIZE_MAX)
		return false;

	NSData *jpegData = [NSData dataWithBytes:payload + jpegOffset length:payloadLength - jpegOffset];
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
	if (!source)
		return false;

	CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
	CFRelease(source);
	if (!image)
		return false;

	bool decoded = false;

	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate(canvas, canvasWidth, canvasHeight, 8, canvasWidth * 4, colorSpace,
												 (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(colorSpace);

	if (context) {
		int dx = dst.left - frame.left, dy = dst.top - frame.top;
		int dw = dst.right - dst.left, dh = dst.bottom - dst.top;

		if (dw <= 0 || dh <= 0) {
			dx = 0; dy = 0;
			dw = (int)canvasWidth; dh = (int)canvasHeight;
		}

		// canvas row 0 is the top; CG rects have their origin at the bottom left
		CGContextDrawImage(context, CGRectMake(dx, (CGFloat)canvasHeight - dy - dh, dw, dh), image);
		CGContextRelease(context);
		decoded = true;
	}

	CGImageRelease(image);
	return decoded;
}

// Skip an opcode we don't decode, using the standard v2 data-size rules
static bool PICTSkipOp(PICTReader *r, uint16_t op)
{
	// zero-data opcodes: NOP, HiliteMode, DefHilite, the "same shape" families,
	// reserved 0x00B0-0x00CF and 0x8000-0x80FF
	if (op == 0x0000 || op == 0x001C || op == 0x001E ||
		(op >= 0x0038 && op <= 0x003F) || (op >= 0x0048 && op <= 0x004F) ||
		(op >= 0x0058 && op <= 0x005F) || (op >= 0x0078 && op <= 0x007F) ||
		(op >= 0x0088 && op <= 0x008F) ||
		(op >= 0x00B0 && op <= 0x00CF) || (op >= 0x8000 && op <= 0x80FF)) {
		return true;
	}

	// size-prefixed region and polygon payloads
	if (op == 0x0001 || (op >= 0x0080 && op <= 0x0087) || (op >= 0x0070 && op <= 0x0077)) {
		PICTSkipRegion(r);
		return !r->failed;
	}

	switch (op) {
		case 0x0003: case 0x0005: case 0x0008: case 0x000D:
		case 0x0015: case 0x0016: case 0x0023: case 0x00A0:
			PICTSkip(r, 2); break;
		case 0x0004:
			PICTSkip(r, 1); PICTAlign(r); break;
		case 0x0006: case 0x0007: case 0x000B: case 0x000C:
		case 0x000E: case 0x000F: case 0x0021:
			PICTSkip(r, 4); break;
		case 0x001A: case 0x001B: case 0x001D: case 0x001F:
			PICTSkip(r, 6); break;
		case 0x0002: case 0x0009: case 0x000A: case 0x0010:
		case 0x0020:
			PICTSkip(r, 8); break;
		case 0x0022:
			PICTSkip(r, 6); break;
		case 0x0011:
			PICTSkip(r, 2); break;
		case 0x0028:
			PICTSkip(r, 4); PICTSkip(r, PICTRead8(r)); PICTAlign(r); break;
		case 0x0029: case 0x002A:
			PICTSkip(r, 1); PICTSkip(r, PICTRead8(r)); PICTAlign(r); break;
		case 0x002B:
			PICTSkip(r, 2); PICTSkip(r, PICTRead8(r)); PICTAlign(r); break;
		case 0x002C: case 0x002D: case 0x002E: case 0x002F:
		case 0x0024: case 0x0025: case 0x0026: case 0x0027:
		case 0x0092: case 0x0093: case 0x0094: case 0x0095:
		case 0x0096: case 0x0097: case 0x009C: case 0x009D:
		case 0x009E: case 0x009F:
			PICTSkip(r, PICTRead16(r)); PICTAlign(r); break;
		case 0x00A1:
			PICTSkip(r, 2); PICTSkip(r, PICTRead16(r)); PICTAlign(r); break;
		case 0x0C00:
			PICTSkip(r, 24); break;
		default:
			if (op >= 0x0030 && op <= 0x0037) { PICTSkip(r, 8); break; }
			if (op >= 0x0040 && op <= 0x0047) { PICTSkip(r, 8); break; }
			if (op >= 0x0050 && op <= 0x0057) { PICTSkip(r, 8); break; }
			if (op >= 0x0058 && op <= 0x005F) { break; }
			if (op >= 0x0060 && op <= 0x0067) { PICTSkip(r, 12); break; }
			if (op >= 0x0068 && op <= 0x006F) { PICTSkip(r, 4); break; }
			if (op >= 0x0078 && op <= 0x007F) { break; }
			if (op >= 0x0088 && op <= 0x008F) { break; }
			if (op >= 0x00A2 && op <= 0x00AF) { PICTSkip(r, PICTRead16(r)); PICTAlign(r); break; }
			if (op >= 0x00D0 && op <= 0x00FE) { PICTSkip(r, PICTRead32(r)); PICTAlign(r); break; }
			if (op >= 0x0100 && op <= 0x7FFF) { PICTSkip(r, (size_t)(op >> 8) * 2); break; }
			if (op >= 0x8100) { PICTSkip(r, PICTRead32(r)); PICTAlign(r); break; }
			// 0x0090/0x0091 (old BitsRect) and anything unknown: give up
			return false;
	}

	return !r->failed;
}

static NSData *PNGDataFromPICT(NSData *pictData)
{
	const uint8_t *bytes = (const uint8_t *)[pictData bytes];
	size_t length = [pictData length];

	// Clipboard PICTs normally have no 512-byte file header, but accept one
	size_t offsets[2] = { 0, 512 };
	PICTReader reader = { NULL, 0, 0, false };
	PICTRect frame = { 0, 0, 0, 0 };
	bool found = false;

	for (int i = 0; i < 2 && !found; i++) {
		if (offsets[i] + 12 > length)
			continue;

		PICTReader r = { bytes, length, offsets[i], false };
		PICTSkip(&r, 2);	// picSize (meaningless for >64K pictures)
		PICTRect f = PICTReadRect(&r);

		if (f.right <= f.left || f.bottom <= f.top)
			continue;

		// require the v2 signature (possibly after NOPs)
		for (int n = 0; n < 4; n++) {
			uint16_t op = PICTRead16(&r);
			if (op == 0x0000)
				continue;
			if (op == 0x0011 && PICTRead16(&r) == 0x02ff) {
				reader = r;
				frame = f;
				found = true;
			}
			break;
		}
	}

	if (!found || reader.failed)
		return nil;

	size_t canvasWidth = (size_t)(frame.right - frame.left);
	size_t canvasHeight = (size_t)(frame.bottom - frame.top);

	if (canvasWidth == 0 || canvasHeight == 0 || canvasWidth > 8192 || canvasHeight > 8192)
		return nil;

	NSMutableData *canvasData = [NSMutableData dataWithLength:canvasWidth * canvasHeight * 4];
	if (!canvasData)
		return nil;

	uint8_t *canvas = (uint8_t *)[canvasData mutableBytes];

	// White background, like a fresh QuickDraw port
	memset(canvas, 0xff, canvasWidth * canvasHeight * 4);

	bool decodedSomething = false;

	uint16_t lastOp = 0;

	while (!reader.failed) {
		PICTAlign(&reader);
		if (reader.cursor + 2 > reader.length)
			break;

		uint16_t op = PICTRead16(&reader);
		lastOp = op;

		if (op == 0x00FF)
			break;

		if (op == 0x0098 || op == 0x0099 || op == 0x009A || op == 0x009B) {
			if (!PICTDecodeBitsOp(&reader, op, canvas, canvasWidth, canvasHeight, frame)) {
				CLIP_LOG("PICT decode: bits op 0x%04X failed at offset %lu", op, (unsigned long)reader.cursor);
				break;
			}
			decodedSomething = true;
			continue;
		}

		if (op == 0x8200) {
			// QuickTime-compressed (usually JPEG); keep parsing either way
			if (PICTDecodeQuickTimeOp(&reader, canvas, canvasWidth, canvasHeight, frame))
				decodedSomething = true;
			else
				CLIP_LOG("PICT decode: QuickTime op had no decodable JPEG");
			continue;
		}

		if (!PICTSkipOp(&reader, op)) {
			CLIP_LOG("PICT decode: stopped at unknown op 0x%04X offset %lu", op, (unsigned long)reader.cursor);
			break;
		}
	}

	if (!decodedSomething) {
		CLIP_LOG("PICT decode: no bitmap decoded (last op 0x%04X, len=%lu)", lastOp, (unsigned long)length);
		return nil;
	}

	// Encode the canvas as PNG via ImageIO
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)canvasData);
	CGImageRef cgImage = CGImageCreate(canvasWidth, canvasHeight, 8, 32, canvasWidth * 4, colorSpace,
									   (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big,
									   provider, NULL, false, kCGRenderingIntentDefault);
	CGDataProviderRelease(provider);
	CGColorSpaceRelease(colorSpace);

	if (!cgImage)
		return nil;

	NSMutableData *pngData = [NSMutableData data];
	CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)pngData, CFSTR("public.png"), 1, NULL);

	bool wrote = false;
	if (dest) {
		CGImageDestinationAddImage(dest, cgImage, NULL);
		wrote = CGImageDestinationFinalize(dest);
		CFRelease(dest);
	}

	CGImageRelease(cgImage);

	return (wrote && [pngData length]) ? pngData : nil;
}

/*
 *  Convert the guest scrap flavors collected so far to host pasteboard content.
 *  Called on the emulator thread; the pasteboard write happens on the main thread.
 */

static void WriteGuestScrapToHostPasteboard(void)
{
	NSMutableDictionary<NSString *, id> *item = [NSMutableDictionary dictionary];

	// TEXT (+ styl) become plain text and RTF
	NSData *textData = [g_guest_scrap objectForKey:@(TYPE_TEXT)];

	if (textData) {
		NSData *stylData = [g_guest_scrap objectForKey:@(TYPE_STYL)];

		NSMutableAttributedString *aStr = nil;
		if (stylData)
			aStr = [AttributedStringFromMacTEXTAndStyl(textData, stylData) mutableCopy];

		NSString *plain = nil;
		NSData *rtfData = nil;

		if (aStr) {
			// fix line endings
			[[aStr mutableString] replaceOccurrencesOfString:@"\r" withString:@"\n" options:NSLiteralSearch range:NSMakeRange(0, [aStr length])];

			rtfData = [aStr dataFromRange:NSMakeRange(0, [aStr length])
					   documentAttributes:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType}
									error:nil];
			plain = [[aStr string] copy];
		} else {
			CFStringEncoding encoding = GuestTextEncoding();
			NSString *str = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)[textData bytes], [textData length], encoding, false);
			if (!str && encoding != kCFStringEncodingMacRoman)
				str = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)[textData bytes], [textData length], kCFStringEncodingMacRoman, false);

			if ([str length]) {
				NSMutableString *s = [str mutableCopy];
				[s replaceOccurrencesOfString:@"\r" withString:@"\n" options:NSLiteralSearch range:NSMakeRange(0, [s length])];
				plain = [s copy];
			}
		}

		if ([plain length]) {
			[item setObject:plain forKey:kPasteboardTypeUTF8];
			if (rtfData)
				[item setObject:rtfData forKey:kPasteboardTypeRTF];
		}
	}

	// Decode guest PICT to PNG so modern host apps can paste it; the raw PICT
	// still passes through below for lossless guest-to-guest round trips
	NSData *guestPict = [g_guest_scrap objectForKey:@(TYPE_PICT)];
	if (guestPict) {
		NSData *pngData = nil;
		@try {
			pngData = PNGDataFromPICT(guestPict);
		} @catch (NSException *exception) {
			pngData = nil;
		}
		if (pngData)
			[item setObject:pngData forKey:kPasteboardTypePNG];
	}

	// Everything else (PICT included) passes through under a mapped type string.
	// utxt/ustl pass through together so Unicode-savvy guest apps keep styles
	// on guest-to-guest round trips.
	for (NSNumber *key in g_guest_scrap) {
		uint32_t type = [key unsignedIntValue];

		// TEXT/styl are covered by the RTF conversion above
		if (type == TYPE_TEXT || type == TYPE_STYL)
			continue;

		[item setObject:[g_guest_scrap objectForKey:key] forKey:UTIForFlavor(type)];
	}

	if (![item count]) {
		CLIP_LOG("publish: nothing to publish yet (guest flavors: %{public}@)", [[g_guest_scrap allKeys] description]);
		return;
	}

	NSString *publishUUID = [[NSUUID UUID] UUIDString];
	[item setObject:publishUUID forKey:kPasteboardTypeMarker];

	CLIP_LOG("publish -> host: %{public}@", [[item allKeys] componentsJoinedByString:@", "]);

	// The guest's copy supersedes any host content still waiting to be injected
	os_unfair_lock_lock(&g_pending_lock);
	g_pending_host_attr = nil;
	g_pending_host_text = nil;
	g_pending_host_pict = nil;
	g_pending_host_image = nil;
	g_pending_host_flavors = nil;
	os_unfair_lock_unlock(&g_pending_lock);

	dispatch_async(dispatch_get_main_queue(), ^{
		UIPasteboard *pb = [UIPasteboard generalPasteboard];

		// The marker (not changeCount, which is unreliable on Catalyst) is what
		// keeps this write from being bounced back into the guest
		g_last_published_uuid = publishUUID;
		g_last_stash_signature = nil;

		[pb setItems:@[item] options:@{}];

		g_host_change_count = [pb changeCount];
		os_unfair_lock_lock(&g_pending_lock);
		g_pending_host_attr = nil;
		g_pending_host_text = nil;
		g_pending_host_pict = nil;
		g_pending_host_image = nil;
		g_pending_host_flavors = nil;
		os_unfair_lock_unlock(&g_pending_lock);
	});
}

/*
 *  Check whether the host pasteboard has changed since our last look; if it has,
 *  stash its content for injection into the guest on the next GetScrap().
 *  Main thread only.
 */

static void SyncHostPasteboardToPending(void)
{
	UIPasteboard *pb = [UIPasteboard generalPasteboard];

#if !TARGET_OS_MACCATALYST
	// changeCount is only trustworthy on iOS; on Catalyst it changes between
	// reads, so there the marker and content signature below do the gating
	if ([pb changeCount] == g_host_change_count)
		return;
#endif
	g_host_change_count = [pb changeCount];

	NSArray<NSString *> *types = [pb pasteboardTypes];

	// Our own published content must not bounce back into the guest
	if ([types containsObject:kPasteboardTypeMarker]) {
		id marker = [pb valueForPasteboardType:kPasteboardTypeMarker];
		NSString *markerString = nil;
		if ([marker isKindOfClass:[NSString class]])
			markerString = marker;
		else if ([marker isKindOfClass:[NSData class]])
			markerString = [[NSString alloc] initWithData:marker encoding:NSUTF8StringEncoding];

		if (markerString && [markerString isEqualToString:g_last_published_uuid]) {
			CLIP_LOG("sync: own content (marker match), skipping");
			return;
		}
	}

	// Text: prefer RTF, then flat RTFD, then HTML, falling back to plain string.
	// The HTML importer is main-thread-only, which is fine here.
	NSAttributedString *aStr = nil;
	NSString *str = nil;

	NSDictionary<NSString *, NSString *> *richTextTypes = @{
		kPasteboardTypeRTF: NSRTFTextDocumentType,
		kPasteboardTypeFlatRTFD: NSRTFDTextDocumentType,
		kPasteboardTypeHTML: NSHTMLTextDocumentType,
	};

	for (NSString *richType in @[kPasteboardTypeRTF, kPasteboardTypeFlatRTFD, kPasteboardTypeHTML]) {
		if (![types containsObject:richType])
			continue;

		NSData *richData = [pb dataForPasteboardType:richType];
		if (!richData)
			continue;

		// The HTML importer spins up WebKit; don't feed it huge documents
		if ([richType isEqualToString:kPasteboardTypeHTML] && [richData length] > 512 * 1024)
			continue;

		@try {
			aStr = [[NSAttributedString alloc] initWithData:richData
													options:@{NSDocumentTypeDocumentAttribute: [richTextTypes objectForKey:richType]}
										 documentAttributes:nil
													  error:nil];
		} @catch (NSException *exception) {
			aStr = nil;
		}
		if ([aStr length])
			break;
		aStr = nil;
	}

	if (!aStr && [pb hasStrings]) {
		str = [pb string];
		if (![str length])
			str = nil;
	}

	// Images: prefer raw PICT data, fall back to converting whatever image is there
	NSData *pictData = nil;
	UIImage *image = nil;

	if ([types containsObject:kPasteboardTypePICT])
		pictData = [pb dataForPasteboardType:kPasteboardTypePICT];

	NSUInteger imageBytes = 0;

	if (![pictData length]) {
		pictData = nil;
		if ([pb hasImages]) {
			image = [pb image];
			for (NSString *typeString in types) {
				UTType *utType = [UTType typeWithIdentifier:typeString];
				if (utType && [utType conformsToType:UTTypeImage]) {
					imageBytes = [[pb dataForPasteboardType:typeString] length];
					break;
				}
			}
		}
	}

	// Any other flavors we can map back to a FourCC
	NSMutableDictionary<NSNumber *, NSData *> *flavors = [NSMutableDictionary dictionary];

	for (NSString *typeString in types) {
		if ([typeString isEqualToString:kPasteboardTypePICT])
			continue;

		// text and image types are already handled
		UTType *utType = [UTType typeWithIdentifier:typeString];
		if (utType && ([utType conformsToType:UTTypeText] || [utType conformsToType:UTTypeImage]))
			continue;

		uint32_t type = FlavorForUTI(typeString);

		// TEXT/styl are rebuilt from the rich text conversion; utxt/ustl pass through
		if (!type || type == TYPE_TEXT || type == TYPE_STYL || type == TYPE_PICT)
			continue;

		if ([flavors objectForKey:@(type)])
			continue;

		NSData *data = [pb dataForPasteboardType:typeString];
		if ([data length])
			[flavors setObject:data forKey:@(type)];
	}

	// Identical content must not be stashed (and later injected) repeatedly
	NSMutableString *signature = [NSMutableString stringWithFormat:@"a%lu|s%lu|p%lu|i%lu@%dx%d",
								  (unsigned long)[[aStr string] hash], (unsigned long)[str hash],
								  (unsigned long)[pictData length], (unsigned long)imageBytes,
								  (int)(image.size.width * image.scale), (int)(image.size.height * image.scale)];
	for (NSNumber *key in [[flavors allKeys] sortedArrayUsingSelector:@selector(compare:)])
		[signature appendFormat:@"|%@:%lu", key, (unsigned long)[[flavors objectForKey:key] length]];

	if ([signature isEqualToString:g_last_stash_signature]) {
		CLIP_LOG("sync: unchanged content (signature match), skipping");
		return;
	}
	g_last_stash_signature = [signature copy];

	CLIP_LOG("sync cc=%ld types=[%{public}@] -> attr=%d text=%d pict=%d image=%d flavors=%lu",
			 (long)g_host_change_count, [types componentsJoinedByString:@", "],
			 aStr != nil, str != nil, pictData != nil, image != nil, (unsigned long)[flavors count]);

	os_unfair_lock_lock(&g_pending_lock);
	g_pending_host_attr = aStr;
	g_pending_host_text = [str copy];
	g_pending_host_pict = pictData;
	g_pending_host_image = image;
	g_pending_host_flavors = ([flavors count] ? [flavors copy] : nil);
	os_unfair_lock_unlock(&g_pending_lock);
}

/*
 *	Initialization
 */

static void RequestHostPasteboardSync(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		@try {
			SyncHostPasteboardToPending();
		} @catch (NSException *exception) {
			CLIP_LOG("Pasteboard sync raised: %{public}@", exception);
		}
	});
}

void ClipInit(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		void (^sync)(NSNotification *) = ^(NSNotification *notification) {
			RequestHostPasteboardSync();
		};
		g_pasteboard_observers[0] = [nc addObserverForName:UIApplicationDidBecomeActiveNotification
													object:nil
													 queue:[NSOperationQueue mainQueue]
												usingBlock:sync];
		g_pasteboard_observers[1] = [nc addObserverForName:UIPasteboardChangedNotification
													object:nil
													 queue:[NSOperationQueue mainQueue]
												usingBlock:sync];
		// App-level activation can be unreliable on Catalyst; scenes fire too
		g_pasteboard_observers[2] = [nc addObserverForName:UISceneDidActivateNotification
													object:nil
													 queue:[NSOperationQueue mainQueue]
												usingBlock:sync];
		RequestHostPasteboardSync();
	});
}

/*
 *	Deinitialization
 */

void ClipExit(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		for (int i = 0; i < 3; i++) {
			if (g_pasteboard_observers[i]) {
				[nc removeObserver:g_pasteboard_observers[i]];
				g_pasteboard_observers[i] = nil;
			}
		}
	});

	g_guest_scrap = nil;

	os_unfair_lock_lock(&g_pending_lock);
	g_pending_host_attr = nil;
	g_pending_host_text = nil;
	g_pending_host_pict = nil;
	g_pending_host_image = nil;
	g_pending_host_flavors = nil;
	os_unfair_lock_unlock(&g_pending_lock);
}

/*
 *	Mac application reads clipboard
 */

void GetScrap(void **handle, uint32 type, int32 offset)
{
	D(bug("GetScrap handle %p, type %4.4s, offset %d\n", handle, (char *)&type, offset));

	os_unfair_lock_lock(&g_pending_lock);
	NSAttributedString *attr = g_pending_host_attr;
	NSString *text = g_pending_host_text;
	NSData *pictData = g_pending_host_pict;
	UIImage *image = g_pending_host_image;
	NSDictionary<NSNumber *, NSData *> *flavors = g_pending_host_flavors;
	g_pending_host_attr = nil;
	g_pending_host_text = nil;
	g_pending_host_pict = nil;
	g_pending_host_image = nil;
	g_pending_host_flavors = nil;
	os_unfair_lock_unlock(&g_pending_lock);

	if (!attr && !text && !pictData && !image && ![flavors count]) {
		// Fallback for missed activation notifications: refresh the pending
		// slots so the next GetScrap sees current host content
		static double last_refresh = 0;		// emulator thread only
		double now = CFAbsoluteTimeGetCurrent();
		if (now - last_refresh > 0.5) {
			last_refresh = now;
			RequestHostPasteboardSync();
		}
		return;
	}

	AUTORELEASE_POOL {
		NSData *textData = nil;
		NSData *stylData = nil;

		// Never let a conversion failure raise through the EMUL_OP into the emulator
		@try {
			if (attr) {
				NSMutableAttributedString *aStr = [attr mutableCopy];
				NSMutableString *ms = [aStr mutableString];
				[ms replaceOccurrencesOfString:@"\r\n" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [ms length])];
				[ms replaceOccurrencesOfString:@"\n" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [ms length])];
				[ms replaceOccurrencesOfString:@"\u2028" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [ms length])];
				[ms replaceOccurrencesOfString:@"\u2029" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [ms length])];

				textData = ConvertToMacTEXTAndStyl(aStr, &stylData);
			} else if (text) {
				NSMutableString *s = [text mutableCopy];
				[s replaceOccurrencesOfString:@"\r\n" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [s length])];
				[s replaceOccurrencesOfString:@"\n" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [s length])];
				[s replaceOccurrencesOfString:@"\u2028" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [s length])];
				[s replaceOccurrencesOfString:@"\u2029" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [s length])];

				CFStringEncoding encoding = GuestTextEncoding();
				CFRange range = CFRangeMake(0, [s length]);
				CFIndex bufLen = 0;
				CFStringGetBytes((__bridge CFStringRef)s, range, encoding, '?', false, NULL, 0, &bufLen);
				if (bufLen > 0) {
					NSMutableData *data = [NSMutableData dataWithLength:bufLen];
					CFStringGetBytes((__bridge CFStringRef)s, range, encoding, '?', false, (UInt8 *)[data mutableBytes], bufLen, &bufLen);
					[data setLength:bufLen];
					textData = data;
				}
			}

			if (!pictData && image)
				pictData = PICTDataFromImage(image);
		} @catch (NSException *exception) {
			CLIP_LOG("GetScrap conversion raised: %{public}@", exception);
			textData = nil;
			stylData = nil;
			pictData = nil;
		}

		if (![textData length] && ![pictData length] && ![flavors count]) {
			CLIP_LOG("inject: conversions produced nothing (attr=%d text=%d image=%d)", attr != nil, text != nil, image != nil);
			return;
		}

		CLIP_LOG("inject -> guest: text=%lu styl=%lu pict=%lu flavors=%lu",
				 (unsigned long)[textData length], (unsigned long)[stylData length],
				 (unsigned long)[pictData length], (unsigned long)[flavors count]);

		ZeroMacClipboard();

		if ([stylData length] > 2)
			WriteDataToMacClipboard(stylData, TYPE_STYL);

		if ([textData length])
			WriteDataToMacClipboard(textData, TYPE_TEXT);

		if ([pictData length])
			WriteDataToMacClipboard(pictData, TYPE_PICT);

		for (NSNumber *key in flavors) {
			uint32_t flavorType = [key unsignedIntValue];

			if (flavorType == TYPE_TEXT || flavorType == TYPE_STYL || flavorType == TYPE_PICT)
				continue;

			WriteDataToMacClipboard([flavors objectForKey:key], flavorType);
		}
	}
}

/*
 *  ZeroScrap() is called before a Mac application writes to the clipboard
 */

void ZeroScrap()
{
	D(bug("ZeroScrap\n"));

	CLIP_LOG("ZeroScrap");

	we_put_this_data = false;

	// Defer clearing the guest scrap snapshot until the Mac puts something on it.
	// This prevents clearing when ZeroScrap() is called during startup.
	should_clear = true;
}

/*
 *	Mac application wrote to clipboard
 */

void PutScrap(uint32 type, void *scrap, int32 length)
{
	D(bug("PutScrap type %4.4s, data %p, length %ld\n", (char *)&type, scrap, (long)length));

	CLIP_LOG("PutScrap '%{public}@' len=%d%{public}s", FourCCString(type), (int)length, we_put_this_data ? " (bounce)" : "");

	if (we_put_this_data) {
		we_put_this_data = false;
		return;
	}

	if (length <= 0)
		return;

	AUTORELEASE_POOL {
		if (should_clear) {
			[g_guest_scrap removeAllObjects];
			should_clear = false;
		}

		if (!g_guest_scrap)
			g_guest_scrap = [NSMutableDictionary dictionary];

		NSNumber *key = @(type);

		if ([g_guest_scrap objectForKey:key]) {
			// the classic Mac OS can't have more than one object of the same type on the clipboard
			return;
		}

		[g_guest_scrap setObject:[NSData dataWithBytes:scrap length:length] forKey:key];

		// Never let a conversion failure raise through the EMUL_OP into the emulator
		@try {
			WriteGuestScrapToHostPasteboard();
		} @catch (NSException *exception) {
			CLIP_LOG("PutScrap conversion raised: %{public}@", exception);
		}
	}
}
