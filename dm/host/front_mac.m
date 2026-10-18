// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−.
// Physical controllers (GameController, e.g. a Switch Pro Controller over Bluetooth) work alongside the keyboard. Face buttons map by the letter the system reports for them
// (macOS names a Switch Pro Controller's buttons by their printed letters: buttonA is the right one), by position (right A, bottom B, top X, left Y, as in DmGamepad.m) when it reports none.
// A controller's motion sensors feed nn::hid's six-axis sensor and the game's vibration drives its motors: a Switch Pro Controller through raw HID (pro_imu_*, hd_*), others through
// GameController (motion_attach, rumble_*). DM_PAD_LOG=1 logs the right stick, motion samples and rumble.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <os/lock.h>
#include <IOKit/hid/IOHIDManager.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "dm.h"
#include "dm_input.h"
#include "dm_padmap.h"
#include "dm_uiscreen.h"
void mtl_set_ui_rect_fn(void (*fn)(double *y, double *h));
static void ui_rect_frac(double *fy, double *fh) { int x, y, w, h, rw = 0, rh = 0; dm_ui_rect(&x, &y, &w, &h); if (dm_screen_real(&rw, &rh) && rh > 0) { *fy = (double)y / rh; *fh = (double)h / rh; } }   // Same as front_ios.m: vertical position and height of the UI rectangle (as fractions of the frame height)
__attribute__((constructor)) static void ui_shift_reg(void) { mtl_set_ui_rect_fn(ui_rect_frac); }   // Must also take effect when running without a window (screenshots / gate checks), so it is not placed where the layer is created
#include "front.h"
#include "hle.h"
#include <signal.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
// The original game's 16:9 constants, behavior unchanged; DM_GAME_RES=<width>x<height> (docked mode; handheld scaled by 720/900) is only for side-by-side comparison with iOS widescreen
uint64_t front_game_res(int docked) {
    unsigned w, h; const char *e = getenv("DM_GAME_RES");
    if (e && sscanf(e, "%ux%u", &w, &h) == 2) return docked ? (uint64_t)h << 32 | w : (uint64_t)(h * 4 / 5) << 32 | (w * 4 / 5 + 3) / 4 * 4;
    return docked ? 900ull << 32 | 1600 : 720ull << 32 | 1280;
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
// Physical controllers -> dm_pad_set (ORed with the keyboard in hle_hid.c). Same reading as DmGamepad.m's read_pad; the last controller that changed wins
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX); }
static uint64_t face_bit(GCControllerButtonInput *b, uint64_t by_pos) {   // the letter in the button's symbol ("a.circle" …), else the position mapping
    NSString *s = b.sfSymbolsName; unichar c = s.length >= 2 && [s characterAtIndex:1] == '.' ? [s characterAtIndex:0] : 0;
    return c == 'a' ? DM_BTN_A : c == 'b' ? DM_BTN_B : c == 'x' ? DM_BTN_X : c == 'y' ? DM_BTN_Y : by_pos;
}
static void read_pad(GCExtendedGamepad *g) {
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    K(g.buttonA, face_bit(g.buttonA, DM_BTN_B)); K(g.buttonB, face_bit(g.buttonB, DM_BTN_A)); K(g.buttonX, face_bit(g.buttonX, DM_BTN_Y)); K(g.buttonY, face_bit(g.buttonY, DM_BTN_X));
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); if (g.buttonOptions) K(g.buttonOptions, DM_BTN_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, DM_BTN_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, DM_BTN_RS);
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set(m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
    // DM_PAD_LOG=1: every right-stick change with a millisecond timestamp (to see how long a flick stays tilted)
    static int pl = -1; if (pl < 0) pl = getenv("DM_PAD_LOG") != NULL;
    if (pl) { static float px, py; float x = g.rightThumbstick.xAxis.value, y = g.rightThumbstick.yAxis.value;
              if (x != px || y != py) { px = x; py = y; LOG("PADLOG %.1f ms R %.3f %.3f btn %#llx", CACurrentMediaTime() * 1000, x, y, (unsigned long long)m); } }
}
// Switch Pro Controller: macOS lights the ring around its HOME button for as long as it is connected (on the Switch it stays dark except for notifications). GameController has no control for it,
// so the controller's own "set HOME light" subcommand (0x38, all-zero arguments = off) goes to it as HID output report 0x01 (packet counter, neutral rumble, subcommand). Only the LED changes; reconnecting restores
// macOS's behaviour. Sent a second after each connect so it lands after the system driver's own setup. DM_PAD_HOME_LED=1 leaves the light alone
static void pro_home_led_off(void) {
    if (getenv("DM_PAD_HOME_LED")) return;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = 0x057E, pid = 0x2009;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid), p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *k[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)}, *val[] = {v, p};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, val, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(m, match); IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(m); int sent = 0;
    if (set) {
        CFIndex n = CFSetGetCount(set); const void **devs = calloc((size_t)n, sizeof *devs); CFSetGetValues(set, devs);
        for (CFIndex i = 0; i < n; i++) {
            IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
            uint8_t r[49] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x38};
            if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) == kIOReturnSuccess) { if (IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x01, r, sizeof r) == kIOReturnSuccess) sent++; IOHIDDeviceClose(d, kIOHIDOptionsTypeNone); }
        }
        free(devs); CFRelease(set);
    }
    LOG("Pro 手柄 HOME 键灯：关（%d 个）", sent);
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone); CFRelease(m); CFRelease(match); CFRelease(v); CFRelease(p);
}
// Motion → dm_motion_set, in nn::hid's frame: x right, y forward (away from the player), z up; acceleration in G pointing along gravity (lying flat, face up: (0, 0, -1)), angular velocity in
// revolutions per second (right-handed). DM_PAD_MOTION=<three of x y z, each optionally negated>, e.g. "x,-y,z", remaps both vectors afterwards.
// A Switch Pro Controller: GameController reports motion for it but every value stays 0 (gravity a fixed (0, 0, -1)), although the controller streams its IMU in every standard input report
// (0x30, about 67 a second, three samples each: acceleration and gyro as int16, ±8 G = 4096 LSB/G, ±2000 °/s = 16.4 LSB/(°/s)). Those reports are read directly (IOHIDDevice, opened alongside
// the system driver). Raw axes: x left, y forward, z up, acceleration as the reaction to gravity (+1 G up at rest); so hid = (−x, y, z) for the gyro and (x, −y, −z) for acceleration (as yuzu's
// Pro Controller driver maps them). The gyro's resting offset (about 1 °/s) is learned while the controller lies still. Other controllers keep GameController's motion (motion_attach)
static int g_mmap[3][2] = {{0, 1}, {1, 1}, {2, 1}};
static void motion_map_init(void) {
    const char *e = getenv("DM_PAD_MOTION"); if (!e) return;
    int k = 0; for (const char *q = e; *q && k < 3; q++) { int sg = 1; if (*q == '-') { sg = -1; q++; } if (*q >= 'x' && *q <= 'z') { g_mmap[k][0] = *q - 'x'; g_mmap[k][1] = sg; k++; } }
    LOG("手柄体感轴映射：%s", e);
}
static void motion_out(const double acc[3], const double gyro_rps[3]) {
    float a[3], g[3];
    for (int i = 0; i < 3; i++) { a[i] = (float)(g_mmap[i][1] * acc[g_mmap[i][0]]); g[i] = (float)(g_mmap[i][1] * gyro_rps[g_mmap[i][0]]); }
    dm_motion_set(a, g);
    static int pl = -1, n; if (pl < 0) pl = getenv("DM_PAD_LOG") != NULL;   // DM_PAD_LOG=1: every 15th sample (about 4 a second)
    if (pl && n++ % 15 == 0) LOG("MOTLOG acc %.2f %.2f %.2f  gyro %.3f %.3f %.3f rev/s", a[0], a[1], a[2], g[0], g[1], g[2]);
}
static void motion_attach(GCController *c) {
    GCMotion *m = c.motion; if (!m) return;
    if (m.sensorsRequireManualActivation) m.sensorsActive = YES;
    m.valueChangedHandler = ^(GCMotion *mm) {
        GCAcceleration a = mm.hasGravityAndUserAcceleration ? (GCAcceleration){mm.gravity.x + mm.userAcceleration.x, mm.gravity.y + mm.userAcceleration.y, mm.gravity.z + mm.userAcceleration.z} : mm.acceleration;
        if (a.x == 0 && a.y == 0 && a.z == 0) return;   // no real data (see above)
        GCRotationRate r = mm.rotationRate;
        double av[3] = {a.x, a.y, a.z}, rv[3] = {r.x / (2 * M_PI), r.y / (2 * M_PI), r.z / (2 * M_PI)};
        motion_out(av, rv);
    };
    LOG("手柄体感（GameController）：%s", m.sensorsActive ? "已开" : "没开");
}
static dispatch_queue_t g_rum_q; static void hd_start(void);   // the rumble queue and HD rumble (below)
static IOHIDManagerRef g_imu_mgr; static IOHIDDeviceRef g_imu_dev; static uint8_t g_imu_buf[512];
static double g_gbias[3]; static int g_gstill;
static void pro_imu_report(void *ctx, IOReturn r, void *sender, IOHIDReportType t, uint32_t id, uint8_t *rep, CFIndex len) {
    (void)ctx; (void)r; (void)sender; (void)t; (void)id;
    if (len < 49 || rep[0] != 0x30) return;
    double ra[3] = {0}, rg[3] = {0};
    for (int f = 0; f < 3; f++) { const uint8_t *v = rep + 13 + 12 * f; for (int i = 0; i < 3; i++) { ra[i] += (int16_t)(v[2 * i] | v[2 * i + 1] << 8) / 3.0; rg[i] += (int16_t)(v[6 + 2 * i] | v[7 + 2 * i] << 8) / 3.0; } }
    double acc[3] = {ra[0] / 4096, -ra[1] / 4096, -ra[2] / 4096}, dps[3] = {-rg[0] / 16.384, rg[1] / 16.384, rg[2] / 16.384};
    // resting offset: while the rate stays within 3 °/s of the current offset and the acceleration is about 1 G for a second, the offset follows the average slowly
    double an = sqrt(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]), dev = 0;
    for (int i = 0; i < 3; i++) dev = fmax(dev, fabs(dps[i] - g_gbias[i]));
    if (dev < 3 && fabs(an - 1) < 0.05) { if (g_gstill < 1000) g_gstill++; } else g_gstill = 0;
    if (g_gstill > 60) for (int i = 0; i < 3; i++) g_gbias[i] += (dps[i] - g_gbias[i]) * 0.02;
    else if (g_gstill > 20 && !g_gbias[0] && !g_gbias[1] && !g_gbias[2]) for (int i = 0; i < 3; i++) g_gbias[i] = dps[i];   // first estimate
    double rps[3]; for (int i = 0; i < 3; i++) rps[i] = (dps[i] - g_gbias[i]) / 360;
    motion_out(acc, rps);
}
static void pro_imu_stop(void) {
    if (g_rum_q) dispatch_sync(g_rum_q, ^{});   // let a send in flight finish before the device goes
    if (g_imu_dev) { IOHIDDeviceRegisterInputReportCallback(g_imu_dev, g_imu_buf, sizeof g_imu_buf, NULL, NULL); IOHIDDeviceUnscheduleFromRunLoop(g_imu_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode); IOHIDDeviceClose(g_imu_dev, kIOHIDOptionsTypeNone); CFRelease(g_imu_dev); g_imu_dev = NULL; }
    if (g_imu_mgr) { IOHIDManagerClose(g_imu_mgr, kIOHIDOptionsTypeNone); CFRelease(g_imu_mgr); g_imu_mgr = NULL; }
}
static void pro_imu_start(void) {   // main thread
    if (g_imu_dev) return;
    g_imu_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *match = @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009};
    IOHIDManagerSetDeviceMatching(g_imu_mgr, (__bridge CFDictionaryRef)match); IOHIDManagerOpen(g_imu_mgr, kIOHIDOptionsTypeNone);
    NSSet *devs = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(g_imu_mgr); IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)devs.anyObject;
    if (!d || IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) { LOG("【红】Pro 手柄体感：HID 设备打不开"); pro_imu_stop(); return; }
    g_imu_dev = (IOHIDDeviceRef)CFRetain(d);
    IOHIDDeviceScheduleWithRunLoop(g_imu_dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(g_imu_dev, g_imu_buf, sizeof g_imu_buf, pro_imu_report, NULL);
    uint8_t r[49] = {0x01, 0x05, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01};   // subcommand 0x40 (IMU on): already on under macOS, sent in case a controller has it off
    IOHIDDeviceSetReport(g_imu_dev, kIOHIDReportTypeOutput, 0x01, r, sizeof r);
    memset(g_gbias, 0, sizeof g_gbias); g_gstill = 0;
    LOG("Pro 手柄体感：读 HID 输入报告 0x30 的 IMU");
    hd_start();
}
// Vibration: one CoreHaptics engine per motor (the left / right handle localities a Switch Pro Controller reports, else the default one for both). GameController's engines take plain pattern
// players only (an advanced player fails: "Couldn't communicate with a helper application"), so each change plays a new endless continuous event with the new intensity and sharpness and stops the
// previous one, as SDL does. Intensity = the stronger of the two bands' amplitudes; sharpness leans towards the high band (≈320 Hz) when it dominates, towards dull for the low one (≈160 Hz).
// front_vibrate is called from guest threads up to every few milliseconds; the latest value per motor is applied on a serial queue, quantized so small changes do not restart the motor
static GCController *__weak g_rum_ctrl; static CHHapticEngine *g_rum_eng[2]; static id<CHHapticPatternPlayer> g_rum_pl[2];
static dispatch_queue_t g_rum_q; static os_unfair_lock g_rum_lk = OS_UNFAIR_LOCK_INIT; static float g_rum_v[2][2]; static int g_rum_applied[2][2], g_rum_pending;
static void rumble_teardown(void) {
    for (int s = 0; s < 2; s++) { [g_rum_pl[s] stopAtTime:CHHapticTimeImmediate error:nil]; g_rum_pl[s] = nil; if (g_rum_eng[s] && (s == 0 || g_rum_eng[s] != g_rum_eng[0])) [g_rum_eng[s] stopWithCompletionHandler:nil]; g_rum_eng[s] = nil; g_rum_applied[s][0] = g_rum_applied[s][1] = 0; }
    g_rum_ctrl = nil;
}
static void rumble_setup(GCController *c) {
    GCDeviceHaptics *h = c.haptics; if (!h) return;
    if (!g_rum_q) g_rum_q = dispatch_queue_create("dm.rumble", DISPATCH_QUEUE_SERIAL);
    NSSet<GCHapticsLocality> *loc = h.supportedLocalities;
    int split = [loc containsObject:GCHapticsLocalityLeftHandle] && [loc containsObject:GCHapticsLocalityRightHandle];
    for (int s = 0; s < (split ? 2 : 1); s++) {
        CHHapticEngine *e = [h createEngineWithLocality:split ? (s ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle) : GCHapticsLocalityDefault];
        if (!e) { LOG("【红】手柄震动：引擎建不出"); rumble_teardown(); return; }
        e.playsHapticsOnly = YES; e.autoShutdownEnabled = NO;
        int side = s;
        e.resetHandler = ^{ dispatch_async(g_rum_q, ^{ g_rum_pl[side] = nil; g_rum_applied[side][0] = g_rum_applied[side][1] = 0; [g_rum_eng[side] startAndReturnError:nil]; }); };
        NSError *err = nil; if (![e startAndReturnError:&err]) { LOG("【红】手柄震动：引擎起不来：%s", err.localizedDescription.UTF8String); rumble_teardown(); return; }
        g_rum_eng[s] = e;
    }
    if (!split) g_rum_eng[1] = g_rum_eng[0];
    g_rum_ctrl = c;
    LOG("手柄震动：%s", split ? "左右两个马达分开" : "一个引擎（左右合并）");
}
static float g_rum_max[2][2]; static int g_rum_starts, g_rum_fails; static double g_rum_t0;   // DM_PAD_LOG=1: a summary every 5 s while the game vibrates (rumble_apply, hd_tick)
static int pad_log(void) { static int pl = -1; if (pl < 0) pl = getenv("DM_PAD_LOG") != NULL; return pl; }
static void rumble_play(int s, int qi, int qs) {   // on g_rum_q; qi = intensity in 1/50, qs = sharpness in 1/10
    NSError *err = nil; id<CHHapticPatternPlayer> pl = nil;
    if (qi > 0) {
        CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:qi / 50.f],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:qs / 10.f]] relativeTime:0 duration:GCHapticDurationInfinite];
        CHHapticPattern *p = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
        pl = p ? [g_rum_eng[s] createPlayerWithPattern:p error:&err] : nil;
        if (!pl || ![pl startAtTime:CHHapticTimeImmediate error:&err]) { static int n; if (n++ < 3) LOG("【红】手柄震动：播放失败：%s", err.localizedDescription.UTF8String); pl = nil; }
    }
    [g_rum_pl[s] stopAtTime:CHHapticTimeImmediate error:nil];
    g_rum_pl[s] = pl;
    if (qi > 0) { if (pl) g_rum_starts++; else g_rum_fails++; }
    if (pad_log()) LOG("RUMLOG 马达 %d 强度 %.2f 锐度 %.1f%s", s, qi / 50.f, qs / 10.f, qi > 0 && !pl ? "（失败）" : "");
}
static void rumble_apply(void) {   // on g_rum_q
    float v[2][2]; os_unfair_lock_lock(&g_rum_lk); memcpy(v, g_rum_v, sizeof v); g_rum_pending = 0; os_unfair_lock_unlock(&g_rum_lk);
    for (int s = 0; s < 2; s++) for (int b = 0; b < 2; b++) g_rum_max[s][b] = fmaxf(g_rum_max[s][b], v[s][b]);
    { double t = CACurrentMediaTime(); if (!g_rum_t0) g_rum_t0 = t;
      if (t - g_rum_t0 >= 5) { if (pad_log() && g_rum_max[0][0] + g_rum_max[0][1] + g_rum_max[1][0] + g_rum_max[1][1] > 0)
                                 LOG("手柄震动 5 秒：最大 左 低 %.3f 高 %.3f 右 低 %.3f 高 %.3f，马达启动 %d 次、失败 %d 次", g_rum_max[0][0], g_rum_max[0][1], g_rum_max[1][0], g_rum_max[1][1], g_rum_starts, g_rum_fails);
                               memset(g_rum_max, 0, sizeof g_rum_max); g_rum_starts = g_rum_fails = 0; g_rum_t0 = t; } }
    int shared = g_rum_eng[1] == g_rum_eng[0];
    if (shared) { v[0][0] = fmaxf(v[0][0], v[1][0]); v[0][1] = fmaxf(v[0][1], v[1][1]); }   // one engine: the stronger side
    for (int s = 0; s < (shared ? 1 : 2); s++) {
        if (!g_rum_eng[s]) continue;
        float lo = v[s][0], hi = v[s][1];
        int qi = (int)lrintf(fminf(1.f, fmaxf(lo, hi)) * 50), qs = lo + hi > 0.001f ? (int)lrintf(5 + 5 * (hi - lo) / (hi + lo)) : 5;
        if (qi == g_rum_applied[s][0] && (qi == 0 || qs == g_rum_applied[s][1])) continue;
        g_rum_applied[s][0] = qi; g_rum_applied[s][1] = qs;
        rumble_play(s, qi, qs);
    }
}
static void rumble_post(void) {
    if (!g_rum_q) return;
    os_unfair_lock_lock(&g_rum_lk); int go = !g_rum_pending; g_rum_pending = 1; os_unfair_lock_unlock(&g_rum_lk);
    if (go) dispatch_async(g_rum_q, ^{ rumble_apply(); });
}
// Switch Pro Controller: the game's values go to the controller as HD rumble, as the Switch sends them (HID output report 0x10: packet counter, then 4 bytes per motor, left then right, each a
// high band and a low band with its own frequency and amplitude; encoding from dekuNukem's rumble data table / CTCaer's jc_toolkit). CoreHaptics cannot express it: its intensity and sharpness
// turned Breath of the Wild's low-band rumble (≈160 Hz, amplitude up to about 0.13) into nothing one could feel. Sent every 15 ms while a motor runs or a value changed.
// Each packet carries the strongest amplitude of its 15 ms window (the game sends about 120 values a second per motor; the newest alone missed short peaks), raised by a curve
// a' = (a + a^e) / 2 (e = 0.5 by default: 0.125 → 0.24, 1 → 1), as yuzu does for its rumble: the raw values felt weaker than on the Switch. DM_PAD_RUMBLE=<e>, 1 = the game's values as they are
static float g_hd_peak[2][4]; static float g_hd_exp = -1;
static float hd_curve(float a) { if (g_hd_exp < 0) { const char *e = getenv("DM_PAD_RUMBLE"); g_hd_exp = e && atof(e) > 0 ? (float)atof(e) : 0.5f; } return a <= 0 ? 0 : fminf(1.f, (a + powf(a, g_hd_exp)) * 0.5f); }
static float g_hd_v[2][4]; static int g_hd_dirty, g_hd_keep; static uint8_t g_hd_cnt; static dispatch_source_t g_hd_timer;
static int hd_amp(float a) { if (a <= 0) return 0; int e = (int)lrintf(a > 0.23f ? log2f(a * 8.7f) * 32 : log2f(a * 17.f) * 16); return e < 1 ? 1 : e > 100 ? 100 : e; }
static void hd_motor(uint8_t *o, const float *v) {   // v = {amplitude low, frequency low, amplitude high, frequency high}
    int la = hd_amp(v[0]), ha = hd_amp(v[2]);
    if (!la && !ha) { o[0] = 0x00; o[1] = 0x01; o[2] = 0x40; o[3] = 0x40; return; }
    int lf = (int)lrintf(log2f(fmaxf(41.f, fminf(626.f, v[1] ?: 160.f)) / 10.f) * 32) - 0x40, hf = ((int)lrintf(log2f(fmaxf(82.f, fminf(1252.f, v[3] ?: 320.f)) / 10.f) * 32) - 0x60) * 4;
    lf = lf < 0 ? 0 : lf > 0x7f ? 0x7f : lf; hf = hf < 0 ? 0 : hf > 0x1fc ? 0x1fc : hf;
    o[0] = hf & 0xff; o[1] = (uint8_t)((ha << 1) | ((hf >> 8) & 1)); o[2] = (uint8_t)(lf | ((la & 1) << 7)); o[3] = (uint8_t)(0x40 + (la >> 1));
}
static void hd_tick(void) {   // on g_rum_q
    float v[2][4]; os_unfair_lock_lock(&g_rum_lk); memcpy(v, g_hd_peak, sizeof v); memcpy(g_hd_peak, g_hd_v, sizeof g_hd_peak); int dirty = g_hd_dirty; g_hd_dirty = 0; os_unfair_lock_unlock(&g_rum_lk);
    for (int s = 0; s < 2; s++) { v[s][0] = hd_curve(v[s][0]); v[s][2] = hd_curve(v[s][2]); }
    int on = v[0][0] > 0 || v[0][2] > 0 || v[1][0] > 0 || v[1][2] > 0;
    if (!dirty && !on && g_hd_keep <= 0) return;
    g_hd_keep = on ? 4 : g_hd_keep - 1;   // after the last change to zero, a few more neutral packets
    uint8_t r[10] = {0x10, (uint8_t)(g_hd_cnt++ & 0xf)}; hd_motor(r + 2, v[0]); hd_motor(r + 6, v[1]);
    IOHIDDeviceRef d = g_imu_dev; if (d) IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x10, r, sizeof r);
    if (on) for (int s = 0; s < 2; s++) { g_rum_max[s][0] = fmaxf(g_rum_max[s][0], v[s][0]); g_rum_max[s][1] = fmaxf(g_rum_max[s][1], v[s][2]); }
    if (on) g_rum_starts++;
    double t = CACurrentMediaTime(); if (!g_rum_t0) g_rum_t0 = t;
    if (t - g_rum_t0 >= 5) { if (g_rum_starts && pad_log()) LOG("手柄 HD 震动 5 秒：最大 左 低 %.3f 高 %.3f 右 低 %.3f 高 %.3f，发包 %d 个", g_rum_max[0][0], g_rum_max[0][1], g_rum_max[1][0], g_rum_max[1][1], g_rum_starts);
                             memset(g_rum_max, 0, sizeof g_rum_max); g_rum_starts = 0; g_rum_t0 = t; }
}
static void hd_start(void) {   // main thread, once the Pro Controller's HID device is open
    if (!g_rum_q) g_rum_q = dispatch_queue_create("dm.rumble", DISPATCH_QUEUE_SERIAL);
    if (!g_hd_timer) { g_hd_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_rum_q);
                       dispatch_source_set_timer(g_hd_timer, DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC); dispatch_source_set_event_handler(g_hd_timer, ^{ hd_tick(); }); dispatch_resume(g_hd_timer); }
    LOG("Pro 手柄震动：HD 震动（HID 输出报告 0x10）");
}
void front_vibrate(int side, const float v[4]) {   // nn::hid::VibrationValue {amplitude low, frequency low, amplitude high, frequency high}
    if (side < 0 || side > 1) return;
    if (g_imu_dev) {   // Pro Controller: HD rumble; the window's peak per band keeps the frequency it came with
        os_unfair_lock_lock(&g_rum_lk); memcpy(g_hd_v[side], v, 16);
        if (v[0] >= g_hd_peak[side][0]) { g_hd_peak[side][0] = v[0]; g_hd_peak[side][1] = v[1]; } if (v[2] >= g_hd_peak[side][2]) { g_hd_peak[side][2] = v[2]; g_hd_peak[side][3] = v[3]; }
        g_hd_dirty = 1; os_unfair_lock_unlock(&g_rum_lk); return; }
    os_unfair_lock_lock(&g_rum_lk); g_rum_v[side][0] = v[0]; g_rum_v[side][1] = v[2]; os_unfair_lock_unlock(&g_rum_lk);
    static int logged; if (!logged && (v[0] > 0 || v[2] > 0)) { logged = 1; LOG("手柄震动：游戏首次送非零震动（低频 %.2f@%.0fHz 高频 %.2f@%.0fHz）%s", v[0], v[1], v[2], v[3], g_rum_q ? "" : "，但没有能震动的手柄"); }
    if (pad_log()) { static float last[2][2]; if (fabsf(v[0] - last[side][0]) > 0.02f || fabsf(v[2] - last[side][1]) > 0.02f) { last[side][0] = v[0]; last[side][1] = v[2]; LOG("VIBLOG %d 低 %.2f@%.0f 高 %.2f@%.0f", side, v[0], v[1], v[2], v[3]); } }
    rumble_post();
}
void front_vibration_stop(void) { os_unfair_lock_lock(&g_rum_lk); memset(g_rum_v, 0, sizeof g_rum_v); os_unfair_lock_unlock(&g_rum_lk); rumble_post(); }
static void pads_changed(void) {
    if (g_rum_eng[0] && ![GCController.controllers containsObject:g_rum_ctrl]) { dispatch_sync(g_rum_q, ^{ rumble_teardown(); }); LOG("手柄震动：手柄断开，停"); }
    { int pro = 0; for (GCController *c in GCController.controllers) pro |= dm_padmap_has(c.productCategory.UTF8String, "pro controller"); if (!pro && g_imu_dev) { pro_imu_stop(); LOG("Pro 手柄体感：手柄断开，停"); } }
    int any = 0;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        GCExtendedGamepad *e = c.extendedGamepad;
        if (!e.valueChangedHandler && dm_padmap_has(c.productCategory.UTF8String, "pro controller")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ pro_home_led_off(); });
        if (!e.valueChangedHandler) LOG("手柄已连接：%s（%s），面键符号 buttonA=%s buttonB=%s buttonX=%s buttonY=%s", c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?",
                                        e.buttonA.sfSymbolsName.UTF8String ?: "-", e.buttonB.sfSymbolsName.UTF8String ?: "-", e.buttonX.sfSymbolsName.UTF8String ?: "-", e.buttonY.sfSymbolsName.UTF8String ?: "-");
        int pro = dm_padmap_has(c.productCategory.UTF8String, "pro controller");
        if (!e.valueChangedHandler && pro) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ pro_imu_start(); });
        if (!e.valueChangedHandler) { if (!pro) motion_attach(c); if (!pro && !g_rum_eng[0]) dispatch_sync(g_rum_q ?: (g_rum_q = dispatch_queue_create("dm.rumble", DISPATCH_QUEUE_SERIAL)), ^{ rumble_setup(c); }); }
        any = 1; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        read_pad(c.extendedGamepad);
    }
    if (!any) dm_pad_set(0, 0, 0, 0, 0);   // last one removed: release everything it held
}

static void on_key(NSEvent *e, int down) {
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    if (b >= 0) g_btn = down ? (g_btn | 1ull << b) : (g_btn & ~(1ull << b));
    push();
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("客体线程结束"); exit(0);
}

void front_run(void (*guest)(void)) {
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        win.contentAspectRatio = NSMakeSize(16, 9); win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        // Menu bar: Quit (Cmd+Q) and the window commands. Without a main menu Cmd+Q did nothing
        { NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
          NSMenuItem *ai = [NSMenuItem new], *wi = [NSMenuItem new]; ai.submenu = app; wi.submenu = wm; [bar addItem:ai]; [bar addItem:wi];
          [app addItemWithTitle:[@"Quit " stringByAppendingString:@DM_GAME_NAME] action:@selector(terminate:) keyEquivalent:@"q"];
          [wm addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
          [wm addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
          NSMenuItem *fs = [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]; fs.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
          NSApp.mainMenu = bar; NSApp.windowsMenu = wm; }
        NSView *v = win.contentView;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        g_layer.contentsGravity = kCAGravityResizeAspect; g_layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);   // full screen on a non-16:9 display: letterboxed
        v.layer = g_layer;
        // The drawable follows the window (it stayed at the first size and was stretched when the window grew): the largest 16:9 size in pixels
        void (^fit)(void) = ^{ NSSize b = v.bounds.size; CGFloat sc = win.backingScaleFactor, w = b.width * sc, h = b.height * sc;
            if (w <= 0 || h <= 0) return; if (w * 9 > h * 16) w = h * 16 / 9; else h = w * 9 / 16;
            g_layer.contentsScale = sc; g_layer.drawableSize = CGSizeMake(floor(w), floor(h)); };
        fit();
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; fit(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeBackingPropertiesNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; fit(); }];
        [win center];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSNotificationCenter *pc = NSNotificationCenter.defaultCenter;
        [pc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
        [pc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; LOG("手柄已断开"); pads_changed(); }];
        motion_map_init(); pads_changed();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.modifierFlags & NSEventModifierFlagCommand) return e;   // Cmd shortcuts go to the menu (Quit, Minimize, Full Screen)
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        // Mouse as a single-point touchscreen (for testing touch on the local machine, front.h dm_touch_set): left button down / drag = finger 0 at the normalized coordinates, release = lifted.
        // Only clicks on the picture count, and every event still goes on to AppKit: swallowing them (as before) also took the title bar buttons and the click that makes the window active again,
        // so the window stayed inactive (the game "in the background") and could not be zoomed
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return e; }
            NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSSize sz = v.bounds.size;
            if (sz.width <= 0 || sz.height <= 0 || !NSPointInRect(p, v.bounds)) return e;
            dm_touch t = {0, (float)(p.x / sz.width), (float)(1.0 - p.y / sz.height)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
            dm_touch_set(&t, 1); return e;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_btn = 0; g_w = g_a = g_s = g_d = 0; push(); if (!win.miniaturized) dm_focus_set(2); }];   // keys held while switching away get no key-up here
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
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = title && *title ? @(title) : @"输入";
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        a.informativeText = info;
        [a addButtonWithTitle:@"确定"]; [a addButtonWithTitle:@"取消"];
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        f.stringValue = initial ? @(initial) : @"";
        if (guide && *guide) f.placeholderString = @(guide);
        a.accessoryView = f; a.window.initialFirstResponder = f;
        r = [a runModal] == NSAlertFirstButtonReturn;
        text = f.stringValue;
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
