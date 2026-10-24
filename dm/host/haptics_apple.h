// Shared Core Haptics output for the Mac and iOS front ends. Configure routes before guest boot.
#pragma once
#import <GameController/GameController.h>
#include "hle_haptics.h"
void dm_haptics_apple_init(void);
void dm_haptics_apple_controller(int player, GCController *controller);
// A front end's own output for one player instead of Core Haptics (the Mac's Switch Pro Controller HD rumble): called on the haptics queue with both motors' current values; NULL = Core Haptics again
void dm_haptics_apple_raw(int player, void (*out)(int player, const dm_vibration motor[2]));
void dm_haptics_apple_shutdown(void);
