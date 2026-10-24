// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN starts it that way. ⌘Q quits; the left mouse button is the touchscreen.
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−, Space=shake the controller.
// Controllers: face buttons by the letter the system reports for them (macOS names a Switch Pro Controller's buttons by their printed letters: its buttonA is the right one), otherwise
// by position as on the iPhone (right A, bottom B, top X, left Y); shoulders L R, triggers ZL ZR, Menu + Options −, both sticks and their presses.
// Motion and rumble: a Switch Pro Controller's IMU and HD rumble go through raw HID (pro_imu_*, hd_*), other controllers' motion through GameController (motion_attach) and their rumble
// through Core Haptics (haptics_apple.m). DM_PAD_LOG=1 logs motion samples and HD rumble.
// Each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h);
// DM_PAD_MERGE=1 merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the controllers from player 2 on.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include <signal.h>
#include <math.h>
#include <os/lock.h>
#include <IOKit/hid/IOHIDManager.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}
static void push(void) {
    int32_t lx = (g_d - g_a) * 32767, ly = (g_w - g_s) * 32767;
    dm_input_set(g_btn, lx, ly, 0, 0);
}
static int key_bit(unsigned short code) {
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 48: return 11;                                          // Return Tab → + −
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void on_key(NSEvent *e, int down) {
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    uint64_t m = b >= 0 ? 1ull << b : c == 49 ? DM_BTN_SHAKE : 0;   // Space: shaken while held
    g_btn = down ? (g_btn | m) : (g_btn & ~m);
    push();
}

// Physical controllers (GameController) go to dm_pad_set_player, mapped as the iPhone's (DmGamepad.m read_pad, same layout); player 1's is ORed with the keyboard, a stick takes
// whichever is deflected more (hle_hid.c). DM_KEYS uses player 1's path, so player 1's controller touched during a script takes it over.
// Players: every controller with an extended gamepad profile holds a slot (pad_slots.h: player 1 first, a reconnected controller gets its player back), and hle_hid.c reports
// player n on its own npad while the slot is held (dm_pad_players). A one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c).
// With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins; when the last one goes away its buttons and sticks are released)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_kbd_own;
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX); }
static uint64_t face_bit(GCControllerButtonInput *b, uint64_t by_pos) {   // the letter in the button's symbol ("a.circle" …), else the position mapping
    NSString *s = b.sfSymbolsName; unichar c = s.length >= 2 && [s characterAtIndex:1] == '.' ? [s characterAtIndex:0] : 0;
    return c == 'a' ? DM_BTN_A : c == 'b' ? DM_BTN_B : c == 'x' ? DM_BTN_X : c == 'y' ? DM_BTN_Y : by_pos;
}
static int is_pro(GCController *c) { return c.productCategory && [c.productCategory rangeOfString:@"Pro Controller" options:NSCaseInsensitiveSearch].location != NSNotFound; }
static int pad_log(void) { static int pl = -1; if (pl < 0) pl = getenv("DM_PAD_LOG") != NULL; return pl; }
// Switch Pro Controller: macOS lights the ring around its HOME button for as long as it is connected (on the Switch it stays dark except for notifications). GameController has no control for it,
// so the controller's own "set HOME light" subcommand (0x38, all-zero arguments = off) goes to it as HID output report 0x01 (packet counter, neutral rumble, subcommand). Only the LED changes; reconnecting restores
// macOS's behaviour. Sent a second after each connect so it lands after the system driver's own setup. DM_PAD_HOME_LED=1 leaves the light alone
static void pro_home_led_off(void) {
    if (getenv("DM_PAD_HOME_LED")) return;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *match = @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009};
    IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef)match); IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    NSSet *devs = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m); int sent = 0;
    for (id o in devs) {
        IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)o;
        uint8_t r[49] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x38};
        if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) == kIOReturnSuccess) { if (IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x01, r, sizeof r) == kIOReturnSuccess) sent++; IOHIDDeviceClose(d, kIOHIDOptionsTypeNone); }
    }
    LOG("Pro Controller HOME light: off (%d)", sent);
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone); CFRelease(m);
}
// Motion → dm_motion_set, in nn::hid's frame. DM_PAD_MOTION=<three of x y z, each optionally negated>, e.g. "x,-y,z", remaps both vectors afterwards.
// A Switch Pro Controller: GameController reports motion for it but every value stays 0 (gravity a fixed (0, 0, -1)), although the controller streams its IMU in every standard input report
// (0x30, about 67 a second, three samples each: acceleration and gyro as int16, ±8 G = 4096 LSB/G, ±2000 °/s = 16.4 LSB/(°/s)). Those reports are read directly (IOHIDDevice, opened alongside
// the system driver). Raw axes, measured with the controller flat, standing on its shoulder edge and on its right grip: x forward (towards the shoulder buttons), y left, z up, acceleration
// as the reaction to gravity (+1 G up at rest). nn::hid gets acceleration (y, -x, -z) (along gravity: flat = (0, 0, -1)) and gyro (-y, x, z), in G and revolutions per second, as yuzu's
// native Pro Controller driver hands them over (its report fields 1 / 0 / 2 and 4 / 3 / 5, then gyro x, accel y and z negated). The orientation games read is fused from both in hle_hid.c.
// The gyro's resting offset (about 1 °/s) is learned while the controller lies still. Other controllers keep GameController's motion (motion_attach). One Pro Controller at a time goes through raw HID
static int g_mmap[3][2] = {{0, 1}, {1, 1}, {2, 1}};
static void motion_map_init(void) {
    const char *e = getenv("DM_PAD_MOTION"); if (!e) return;
    int k = 0; for (const char *q = e; *q && k < 3; q++) { int sg = 1; if (*q == '-') { sg = -1; q++; } if (*q >= 'x' && *q <= 'z') { g_mmap[k][0] = *q - 'x'; g_mmap[k][1] = sg; k++; } }
    LOG("controller motion axes: %s", e);
}
static void motion_out(int player, const double acc[3], const double gyro_rps[3]) {
    float a[3], g[3];
    for (int i = 0; i < 3; i++) { a[i] = (float)(g_mmap[i][1] * acc[g_mmap[i][0]]); g[i] = (float)(g_mmap[i][1] * gyro_rps[g_mmap[i][0]]); }
    dm_motion_set(player, a, g);
    static int n; if (pad_log() && n++ % 15 == 0) LOG("MOTLOG p%d acc %.2f %.2f %.2f  gyro %.3f %.3f %.3f rev/s", player + 1, a[0], a[1], a[2], g[0], g[1], g[2]);   // every 15th sample (about 4 a second)
}
static void motion_attach(GCController *c, int player) {
    GCMotion *m = c.motion; if (!m) return;
    if (m.sensorsRequireManualActivation) m.sensorsActive = YES;
    m.valueChangedHandler = ^(GCMotion *mm) {
        GCAcceleration a = mm.hasGravityAndUserAcceleration ? (GCAcceleration){mm.gravity.x + mm.userAcceleration.x, mm.gravity.y + mm.userAcceleration.y, mm.gravity.z + mm.userAcceleration.z} : mm.acceleration;
        if (a.x == 0 && a.y == 0 && a.z == 0) return;   // no real data (see above)
        GCRotationRate r = mm.rotationRate;
        double av[3] = {a.x, a.y, a.z}, rv[3] = {r.x / (2 * M_PI), r.y / (2 * M_PI), r.z / (2 * M_PI)};   // GameController reports gravity's direction, as nn::hid does
        motion_out(player, av, rv);
    };
    LOG("controller motion (GameController), player %d: %s", player + 1, m.sensorsActive ? "on" : "off");
}
static void motion_detach(GCController *c, int player) { c.motion.valueChangedHandler = nil; dm_motion_clear(player); }
static dispatch_queue_t g_hd_q; static void hd_start(int player); static void hd_stop(void);   // HD rumble (below)
static IOHIDManagerRef g_imu_mgr; static IOHIDDeviceRef g_imu_dev; static uint8_t g_imu_buf[512]; static int g_imu_player = -1;
static GCController *__weak g_imu_ctrl;
static double g_gbias[3]; static int g_gstill;
static void pro_imu_report(void *ctx, IOReturn r, void *sender, IOHIDReportType t, uint32_t id, uint8_t *rep, CFIndex len) {
    (void)ctx; (void)r; (void)sender; (void)t; (void)id;
    if (len < 49 || rep[0] != 0x30 || g_imu_player < 0) return;
    double ra[3] = {0}, rg[3] = {0};
    for (int f = 0; f < 3; f++) { const uint8_t *v = rep + 13 + 12 * f; for (int i = 0; i < 3; i++) { ra[i] += (int16_t)(v[2 * i] | v[2 * i + 1] << 8) / 3.0; rg[i] += (int16_t)(v[6 + 2 * i] | v[7 + 2 * i] << 8) / 3.0; } }
    double acc[3] = {ra[1] / 4096, -ra[0] / 4096, -ra[2] / 4096}, dps[3] = {-rg[1] / 16.384, rg[0] / 16.384, rg[2] / 16.384};
    // resting offset: while the rate stays within 3 °/s of the current offset and the acceleration is about 1 G for a second, the offset follows the average slowly
    double an = sqrt(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]), dev = 0;
    for (int i = 0; i < 3; i++) dev = fmax(dev, fabs(dps[i] - g_gbias[i]));
    if (dev < 3 && fabs(an - 1) < 0.05) { if (g_gstill < 1000) g_gstill++; } else g_gstill = 0;
    if (g_gstill > 60) for (int i = 0; i < 3; i++) g_gbias[i] += (dps[i] - g_gbias[i]) * 0.02;
    else if (g_gstill > 20 && !g_gbias[0] && !g_gbias[1] && !g_gbias[2]) for (int i = 0; i < 3; i++) g_gbias[i] = dps[i];   // first estimate
    double rps[3]; for (int i = 0; i < 3; i++) rps[i] = (dps[i] - g_gbias[i]) / 360;
    motion_out(g_imu_player, acc, rps);
}
static void pro_imu_stop(void) {   // main thread
    if (g_imu_player >= 0) { hd_stop(); dm_motion_clear(g_imu_player); LOG("Pro Controller motion and HD rumble: player %d stopped", g_imu_player + 1); }
    g_imu_player = -1; g_imu_ctrl = nil;
    if (g_imu_dev) { IOHIDDeviceRegisterInputReportCallback(g_imu_dev, g_imu_buf, sizeof g_imu_buf, NULL, NULL); IOHIDDeviceUnscheduleFromRunLoop(g_imu_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode); IOHIDDeviceClose(g_imu_dev, kIOHIDOptionsTypeNone); CFRelease(g_imu_dev); g_imu_dev = NULL; }
    if (g_imu_mgr) { IOHIDManagerClose(g_imu_mgr, kIOHIDOptionsTypeNone); CFRelease(g_imu_mgr); g_imu_mgr = NULL; }
}
static void pro_imu_start(GCController *c, int player) {   // main thread
    if (g_imu_dev) return;
    g_imu_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *match = @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009};
    IOHIDManagerSetDeviceMatching(g_imu_mgr, (__bridge CFDictionaryRef)match); IOHIDManagerOpen(g_imu_mgr, kIOHIDOptionsTypeNone);
    NSSet *devs = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(g_imu_mgr); IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)devs.anyObject;
    if (!d || IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) { LOG("[RED] Pro Controller motion: the HID device cannot be opened"); pro_imu_stop(); motion_attach(c, player); return; }
    g_imu_dev = (IOHIDDeviceRef)CFRetain(d); g_imu_player = player; g_imu_ctrl = c;
    IOHIDDeviceScheduleWithRunLoop(g_imu_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(g_imu_dev, g_imu_buf, sizeof g_imu_buf, pro_imu_report, NULL);
    uint8_t r[49] = {0x01, 0x05, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01};   // subcommand 0x40 (IMU on): already on under macOS, sent in case a controller has it off
    IOHIDDeviceSetReport(g_imu_dev, kIOHIDReportTypeOutput, 0x01, r, sizeof r);
    memset(g_gbias, 0, sizeof g_gbias); g_gstill = 0;
    LOG("Pro Controller motion: player %d, from the IMU in HID input report 0x30", player + 1);
    hd_start(player);
}
// Switch Pro Controller: the game's values go to the controller as HD rumble, as the Switch sends them (HID output report 0x10: packet counter, then 4 bytes per motor, left then right, each a
// high band and a low band with its own frequency and amplitude; encoding from dekuNukem's rumble data table / CTCaer's jc_toolkit). Core Haptics cannot express it: its intensity and sharpness
// turned Breath of the Wild's low-band rumble (≈160 Hz, amplitude up to about 0.13) into nothing one could feel. Its player's vibration comes here instead of Core Haptics (dm_haptics_apple_raw).
// Sent every 15 ms while a motor runs or a value changed. Each packet carries the strongest amplitude of its 15 ms window (the game sends about 120 values a second per motor; the newest alone
// missed short peaks), raised by a curve a' = (a + a^e) / 2 (e = 0.5 by default: 0.125 → 0.24, 1 → 1), as yuzu does for its rumble: the raw values felt weaker than on the Switch.
// DM_PAD_RUMBLE=<e>, 1 = the game's values as they are
static os_unfair_lock g_hd_lk = OS_UNFAIR_LOCK_INIT;
static float g_hd_peak[2][4], g_hd_v[2][4]; static float g_hd_exp = -1; static int g_hd_dirty, g_hd_keep; static uint8_t g_hd_cnt; static dispatch_source_t g_hd_timer;
static float g_hd_max[2][2]; static int g_hd_sent; static double g_hd_t0;   // DM_PAD_LOG=1: a summary every 5 s while the game vibrates
static float hd_curve(float a) { if (g_hd_exp < 0) { const char *e = getenv("DM_PAD_RUMBLE"); g_hd_exp = e && atof(e) > 0 ? (float)atof(e) : 0.5f; } return a <= 0 ? 0 : fminf(1.f, (a + powf(a, g_hd_exp)) * 0.5f); }
static int hd_amp(float a) { if (a <= 0) return 0; int e = (int)lrintf(a > 0.23f ? log2f(a * 8.7f) * 32 : log2f(a * 17.f) * 16); return e < 1 ? 1 : e > 100 ? 100 : e; }
static void hd_motor(uint8_t *o, const float *v) {   // v = {amplitude low, frequency low, amplitude high, frequency high}
    int la = hd_amp(v[0]), ha = hd_amp(v[2]);
    if (!la && !ha) { o[0] = 0x00; o[1] = 0x01; o[2] = 0x40; o[3] = 0x40; return; }
    int lf = (int)lrintf(log2f(fmaxf(41.f, fminf(626.f, v[1] ?: 160.f)) / 10.f) * 32) - 0x40, hf = ((int)lrintf(log2f(fmaxf(82.f, fminf(1252.f, v[3] ?: 320.f)) / 10.f) * 32) - 0x60) * 4;
    lf = lf < 0 ? 0 : lf > 0x7f ? 0x7f : lf; hf = hf < 0 ? 0 : hf > 0x1fc ? 0x1fc : hf;
    o[0] = hf & 0xff; o[1] = (uint8_t)((ha << 1) | ((hf >> 8) & 1)); o[2] = (uint8_t)(lf | ((la & 1) << 7)); o[3] = (uint8_t)(0x40 + (la >> 1));
}
static void hd_tick(void) {   // on g_hd_q
    float v[2][4]; os_unfair_lock_lock(&g_hd_lk); memcpy(v, g_hd_peak, sizeof v); memcpy(g_hd_peak, g_hd_v, sizeof g_hd_peak); int dirty = g_hd_dirty; g_hd_dirty = 0; os_unfair_lock_unlock(&g_hd_lk);
    for (int s = 0; s < 2; s++) { v[s][0] = hd_curve(v[s][0]); v[s][2] = hd_curve(v[s][2]); }
    int on = v[0][0] > 0 || v[0][2] > 0 || v[1][0] > 0 || v[1][2] > 0;
    if (!dirty && !on && g_hd_keep <= 0) return;
    g_hd_keep = on ? 4 : g_hd_keep - 1;   // after the last change to zero, a few more neutral packets
    uint8_t r[10] = {0x10, (uint8_t)(g_hd_cnt++ & 0xf)}; hd_motor(r + 2, v[0]); hd_motor(r + 6, v[1]);
    IOHIDDeviceRef d = g_imu_dev; if (d) IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x10, r, sizeof r);
    if (on) { g_hd_sent++; for (int s = 0; s < 2; s++) { g_hd_max[s][0] = fmaxf(g_hd_max[s][0], v[s][0]); g_hd_max[s][1] = fmaxf(g_hd_max[s][1], v[s][2]); } }
    double t = CACurrentMediaTime(); if (!g_hd_t0) g_hd_t0 = t;
    if (t - g_hd_t0 >= 5) { if (g_hd_sent && pad_log()) LOG("Pro Controller HD rumble, 5 s: max left low %.3f high %.3f, right low %.3f high %.3f; %d packets", g_hd_max[0][0], g_hd_max[0][1], g_hd_max[1][0], g_hd_max[1][1], g_hd_sent);
                            memset(g_hd_max, 0, sizeof g_hd_max); g_hd_sent = 0; g_hd_t0 = t; }
}
static void hd_out(int player, const dm_vibration motor[2]) {   // haptics_apple.m's queue: the player's current values for both motors; the window's peak per band keeps the frequency it came with
    if (player != g_imu_player) return;
    os_unfair_lock_lock(&g_hd_lk);
    for (int s = 0; s < 2; s++) {
        const float v[4] = {motor[s].amplitude_low, motor[s].frequency_low, motor[s].amplitude_high, motor[s].frequency_high};
        memcpy(g_hd_v[s], v, sizeof v);
        if (v[0] >= g_hd_peak[s][0]) { g_hd_peak[s][0] = v[0]; g_hd_peak[s][1] = v[1]; }
        if (v[2] >= g_hd_peak[s][2]) { g_hd_peak[s][2] = v[2]; g_hd_peak[s][3] = v[3]; }
    }
    g_hd_dirty = 1; os_unfair_lock_unlock(&g_hd_lk);
}
static void hd_start(int player) {   // main thread, once the Pro Controller's HID device is open
    if (!g_hd_q) g_hd_q = dispatch_queue_create("dm.hd_rumble", DISPATCH_QUEUE_SERIAL);
    if (!g_hd_timer) { g_hd_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_hd_q);
                       dispatch_source_set_timer(g_hd_timer, DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC); dispatch_source_set_event_handler(g_hd_timer, ^{ hd_tick(); }); dispatch_resume(g_hd_timer); }
    dm_haptics_apple_raw(player, hd_out);
    LOG("Pro Controller rumble: player %d, HD rumble (HID output report 0x10)", player + 1);
}
static void hd_stop(void) {   // main thread
    if (g_imu_player >= 0) dm_haptics_apple_raw(g_imu_player, NULL);
    os_unfair_lock_lock(&g_hd_lk); memset(g_hd_v, 0, sizeof g_hd_v); memset(g_hd_peak, 0, sizeof g_hd_peak); g_hd_dirty = 1; os_unfair_lock_unlock(&g_hd_lk);
    if (g_hd_q) dispatch_sync(g_hd_q, ^{ hd_tick(); });   // a neutral packet, and no send in flight when the device goes
}
// A controller taking or leaving a player: motion and, for a Pro Controller, raw HID (a second after the connect, after the system driver's own setup)
static void pad_attach(GCController *c, int player) {
    if (is_pro(c) && !g_imu_dev) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ pro_home_led_off(); if ([GCController.controllers containsObject:c]) pro_imu_start(c, player); });
    } else motion_attach(c, player);
}
static void pad_detach(GCController *c, int player) {
    if (c && c == g_imu_ctrl) pro_imu_stop(); else if (c) motion_detach(c, player);
}
static void pad_read(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    K(g.buttonB, face_bit(g.buttonB, DM_BTN_A)); K(g.buttonA, face_bit(g.buttonA, DM_BTN_B)); K(g.buttonY, face_bit(g.buttonY, DM_BTN_X)); K(g.buttonX, face_bit(g.buttonX, DM_BTN_Y));   // by letter, else by position
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set_player(p, m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    if (g_merge) {
        int any = 0;
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && c != gone) {
            if (!c.extendedGamepad.valueChangedHandler) pad_attach(c, 0);
            any = 1; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
            pad_read(c.extendedGamepad);
        }
        if (gone) pad_detach(gone, 0);
        if (!any) { dm_pad_set(0, 0, 0, 0, 0); dm_haptics_apple_controller(0, nil); }
        return;
    }
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        pad_detach(g_held[p], p);
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)", pad_name(c), p + 1, nb);
        pad_attach(c, p);
        pad_read(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
}
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_KBD_PLAYER"); g_kbd_own = !g_merge && e && !strcmp(e, "own");
    static const char kbd = 0;
    if (g_kbd_own) pad_slot_take(&g_slots, &kbd, "keyboard");   // holds player 1 for good
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : g_kbd_own ? "the keyboard is player 1, each controller a player of its own from player 2 on (DM_KBD_PLAYER=own)"
                                                                           : "each controller is a player of its own, the keyboard plays with player 1");
    pads_changed(nil);
}

// Mouse as a single-point touchscreen (front.h dm_touch_set): left button down / drag = finger 0, release = lifted. The content view takes the clicks,
// not a window-wide event monitor, so clicks on the title bar, the window buttons and the resize edges still reach AppKit.
@interface DmGameView : NSView @end
@implementation DmGameView
- (void)mouseDown:(NSEvent *)e { [self mouseDragged:e]; }
- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the centered 16:9 picture the present fits into the view, as on the iPhone (DmGamepad.m)
    double x0 = (b.width - w) / 2, y0 = (b.height - h) / 2;
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1);
}
- (void)mouseUp:(NSEvent *)e { (void)e; dm_touch_set(NULL, 0); }
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self fitDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void hud_env(void) { if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) setenv("MTL_HUD_ENABLED", "1", 0); }
void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        NSView *v = win.contentView = [[DmGameView alloc] initWithFrame:r];
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
        v.layer = g_layer; [(DmGameView *)v fitDrawable];
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        // Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
        [app addItemWithTitle:@"Quit " DM_GAME_NAME action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""] setSubmenu:wm];
        [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"].keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        NSApp.mainMenu = bar;
        if (getenv("DM_FULLSCREEN")) dispatch_async(dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });   // start in fullscreen
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); }];
        dm_haptics_apple_init();
        motion_map_init();
        pads_start();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;   // hle_swkbd.c: this input's minimum length from ShowKeyboardArg; the applet keeps OK disabled until the text is long enough
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The box takes the keyboard and the mouse, so the game window never sees the key-up of the button or the touch-up of the click that opened it: nothing may stay pressed
        // while it is up, or the game reads the stuck button / touch the moment the box closes (Stardew Valley's character creation re-opened the keyboard endlessly)
        g_btn = 0; g_w = g_a = g_s = g_d = 0; push();
        dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input";
            a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn;
            text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            // On hardware the applet would not have accepted the shorter text (OK stayed disabled); a game that rejects it re-opens the keyboard for ever, so the box comes back with the rule instead
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
