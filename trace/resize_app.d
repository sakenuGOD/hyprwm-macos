/* сторона приложения: что AppKit получает при родном resize от WindowManager */
objc$target:NSWMWindowCoordinator::entry { printf("%d APP %s %s\n", timestamp/1000000, probemod, probefunc); }
objc$target:NSWindow:-_resizeFromWindowManager*:entry { printf("%d APP NSWindow %s\n", timestamp/1000000, probefunc); ustack(25); }
objc$target:NSWindow:-_setFrameCommon*:entry { printf("%d APP NSWindow %s\n", timestamp/1000000, probefunc); }
objc$target:NSWindow:-setFrame*:entry { printf("%d APP NSWindow %s\n", timestamp/1000000, probefunc); }
tick-25s { exit(0); }
