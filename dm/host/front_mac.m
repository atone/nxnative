// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−.
// Physical controllers (GameController, e.g. a Switch Pro Controller over Bluetooth) work alongside the keyboard. Face buttons map by the letter the system reports for them
// (macOS names a Switch Pro Controller's buttons by their printed letters: buttonA is the right one), by position (right A, bottom B, top X, left Y, as in DmGamepad.m) when it reports none.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "dm.h"
#include "dm_input.h"
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
}
static void pads_changed(void) {
    int any = 0;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        GCExtendedGamepad *e = c.extendedGamepad;
        if (!e.valueChangedHandler) LOG("手柄已连接：%s（%s），面键符号 buttonA=%s buttonB=%s buttonX=%s buttonY=%s", c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?",
                                        e.buttonA.sfSymbolsName.UTF8String ?: "-", e.buttonB.sfSymbolsName.UTF8String ?: "-", e.buttonX.sfSymbolsName.UTF8String ?: "-", e.buttonY.sfSymbolsName.UTF8String ?: "-");
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
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        NSView *v = win.contentView;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        v.layer = g_layer;
        [win center];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSNotificationCenter *pc = NSNotificationCenter.defaultCenter;
        [pc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
        [pc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; LOG("手柄已断开"); pads_changed(); }];
        pads_changed();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        // Mouse as a single-point touchscreen (for testing touch on the local machine, front.h dm_touch_set): left button down / drag = finger 0 at the normalized coordinates, release = lifted
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return nil; }
            NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSSize sz = v.bounds.size;
            if (sz.width <= 0 || sz.height <= 0) return e;
            dm_touch t = {0, (float)(p.x / sz.width), (float)(1.0 - p.y / sz.height)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
            dm_touch_set(&t, 1); return nil;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
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
