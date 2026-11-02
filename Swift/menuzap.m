#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// Injected into sdl-freerdp via DYLD_INSERT_LIBRARIES. Behaviors are opt-in by env:
//   RDPCONNECT_MENUZAP=1     disable menu key equivalents so Cmd shortcuts reach the session
//   RDPCONNECT_HIDE_FS_UI=1  keep the menu bar and Dock hidden (no edge reveal) in fullscreen

static BOOL menuzap_performKeyEquivalent(id self, SEL _cmd, NSEvent *event) {
    return NO;
}

static const NSApplicationPresentationOptions kHiddenFullscreen =
    NSApplicationPresentationFullScreen | NSApplicationPresentationHideDock |
    NSApplicationPresentationHideMenuBar;

static NSApplicationPresentationOptions menuzap_fullScreenOptions(
    id self, SEL _cmd, NSWindow *window, NSApplicationPresentationOptions proposed) {
    return kHiddenFullscreen;
}

static void menuzap_patchDelegate(NSWindow *window) {
    id delegate = window.delegate;
    if (!delegate) return;
    SEL sel = @selector(window:willUseFullScreenPresentationOptions:);
    Class cls = [delegate class];
    if (![delegate respondsToSelector:sel])
        class_addMethod(cls, sel, (IMP)menuzap_fullScreenOptions, "Q@:@Q");
}

static void menuzap_hideFullscreenUI(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // Patch the window delegate before the transition so AppKit asks it for options.
    for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification,
                                       NSWindowDidBecomeMainNotification,
                                       NSWindowWillEnterFullScreenNotification ]) {
        [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
            menuzap_patchDelegate(n.object);
        }];
    }
    // Fallback if the delegate hook was too late: apply the options directly.
    [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        @try { NSApp.presentationOptions = kHiddenFullscreen; } @catch (NSException *e) {}
    }];
}

__attribute__((constructor))
static void menuzap_init(void) {
    const char *zap = getenv("RDPCONNECT_MENUZAP");
    if (zap && *zap == '1') {
        Class cls = objc_getClass("NSMenu");
        Method m = cls ? class_getInstanceMethod(cls, @selector(performKeyEquivalent:)) : NULL;
        if (m) method_setImplementation(m, (IMP)menuzap_performKeyEquivalent);
    }
    const char *hide = getenv("RDPCONNECT_HIDE_FS_UI");
    if (hide && *hide == '1') menuzap_hideFullscreenUI();
}
