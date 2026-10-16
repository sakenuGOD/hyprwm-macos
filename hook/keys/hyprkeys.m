// Горячие клавиши для нашего тайлинга — штатный системный механизм (RegisterEventHotKey).
// Нажатие -> строка команды в сокет демона hyprwm. Сочетания берутся из /tmp/hyprkeys.json, который собирает keys/binds.py из дотфайлов Hyprland.
// Публичный API, разрешения «Универсального доступа» не нужны; чужие процессы не трогаем.
// Сборка: clang -fobjc-arc -framework Carbon -framework AppKit -o hyprkeys hyprkeys.m
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <sys/socket.h>
#import <sys/un.h>

static NSArray *gBinds;      // [{keycode, mods, cmd:[args...], desc}]
#define CTL "/tmp/hyprwm.ctl"   // сокет демона hook/hyprwm.py

static dispatch_queue_t gQ;           // одна последовательная очередь: команды уходят строго по порядку
static dispatch_source_t gRepeat;     // автоповтор зажатого бинда (repeating в дотфайле)
#define REPEAT_DELAY 0.280            // input.lua: repeat_delay 280
#define REPEAT_RATE 40.0              //            repeat_rate 40

static void sendLine(NSDictionary *b) {
    NSString *line = [[b[@"cmd"] componentsJoinedByString:@" "] stringByAppendingString:@"\n"];
    dispatch_async(gQ, ^{
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        strlcpy(a.sun_path, CTL, sizeof a.sun_path);
        char reply[512] = "Cannot connect to the HyprWM daemon.";
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            write(fd, line.UTF8String, strlen(line.UTF8String));
            ssize_t n = read(fd, reply, sizeof reply - 1);
            reply[n > 0 ? n : 0] = 0;
        }
        close(fd);
        NSLog(@"[hyprkeys] %@ -> %@: %s", b[@"desc"], line, reply);
    });
}

static OSStatus onHotKey(EventHandlerCallRef call, EventRef ev, void *ctx) {
    EventHotKeyID hk;
    GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    if (hk.id >= gBinds.count) return noErr;
    NSDictionary *b = gBinds[hk.id];
    if (GetEventKind(ev) == kEventHotKeyReleased) {
        if (gRepeat) { dispatch_source_cancel(gRepeat); gRepeat = nil; }
        return noErr;
    }
    sendLine(b);
    if ([b[@"repeat"] boolValue]) {
        if (gRepeat) dispatch_source_cancel(gRepeat);
        gRepeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gRepeat, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REPEAT_DELAY * NSEC_PER_SEC)),
                                  (uint64_t)(NSEC_PER_SEC / REPEAT_RATE), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gRepeat, ^{ sendLine(b); });
        dispatch_resume(gRepeat);
    }
    return noErr;
}

int main(void) {
    @autoreleasepool {
        NSData *d = [NSData dataWithContentsOfFile:@"/tmp/hyprkeys.json"];
        if (!d) { NSLog(@"[hyprkeys] Missing /tmp/hyprkeys.json; generate the hotkey configuration first."); return 1; }
        gBinds = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];

        gQ = dispatch_queue_create("hyprkeys.send", DISPATCH_QUEUE_SERIAL);
        EventTypeSpec spec[2] = { { kEventClassKeyboard, kEventHotKeyPressed },
                                  { kEventClassKeyboard, kEventHotKeyReleased } };
        InstallApplicationEventHandler(&onHotKey, 2, spec, NULL, NULL);

        int ok = 0;
        for (NSUInteger i = 0; i < gBinds.count; i++) {
            NSDictionary *b = gBinds[i];
            EventHotKeyID hid = { .signature = 'hypr', .id = (UInt32)i };
            EventHotKeyRef ref = NULL;
            OSStatus st = RegisterEventHotKey([b[@"keycode"] unsignedIntValue],
                                              [b[@"mods"] unsignedIntValue], hid,
                                              GetApplicationEventTarget(), 0, &ref);
            if (st == noErr) { ok++; NSLog(@"[hyprkeys] + %@", b[@"desc"]); }
            else NSLog(@"[hyprkeys] ЗАНЯТО системой или другим приложением: %@ (код %d)", b[@"desc"], (int)st);
        }
        NSLog(@"[hyprkeys] готово: %d из %lu сочетаний -> %s", ok, (unsigned long)gBinds.count, CTL);
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;   // без иконки в Dock
        [NSApp run];
    }
    return 0;
}
