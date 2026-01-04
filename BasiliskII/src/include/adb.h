/*
 *  adb.h - ADB emulation (mouse/keyboard)
 *
 *  Basilisk II (C) 1997-2008 Christian Bauer
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "HoverOffsetMode.h"

#ifndef ADB_H
#define ADB_H

#ifdef __cplusplus
extern "C"
#endif
struct BeginAnimationState {
    int x;
    int y;

    int offset_x;
    int offset_y;

    BeginAnimationState(int, int, int, int);
};

extern void ADBInit(void);
extern void ADBExit(void);

extern void ADBOp(uint8 op, uint8 *data);

extern void ADBMouseMoved(int x, int y);
extern void ADBMouseDown(int button);
extern void ADBMouseUp(int button);

extern void ADBKeyDown(int code);
extern void ADBKeyUp(int code);

extern void ADBWriteMouseDown(int button);
extern void ADBWriteMouseUp(int button);
extern void ADBMouseClick(int button);

extern void ADBInterrupt(void);

extern void ADBConfigure(int new_screen_middle_x, int new_double_click_mouse_move_tolerance, int new_hover_offset_mode_x, int new_hover_offset_mode_y);
extern void ADBSetRelMouseMode(bool relative);
extern void ADBSetTouchInput(bool is_on);
extern void ADBSetHoverOffsetMode(HoverOffsetMode mode);
extern bool ADBHoversOnMouseDown();
extern bool ADBHoverGestureStartWasLeftSide();

extern BeginAnimationState ADBStartAnimation();
extern void ADBAnimateMove(int x, int y);
extern void ADBEndAnimation();

#endif
