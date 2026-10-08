// Постоянный модуль внутри WindowManager.app: нативный resize окон без lldb на каждое действие.
// Грузится один раз (hook/wm/install.sh: dlopen через lldb), дальше слушает unix-сокет
// $TMPDIR/hyprwm.sock (своя временная папка WindowManager — песочница пускает только туда). Протокол: одна строка JSON на запрос -> одна строка JSON в ответ.
//   {"op":"ping"}
//   {"op":"mgr","addr":"0x..."}                     адрес AppKitApplicationConnectionManager
//   {"op":"map","pids":[123,...]}                   -> {pid:{wid:{uuid,type,tags}}}
//   {"op":"resize","jobs":[{pid,wid,x,y,w,h,spring:[m,k,d,eps]}]}
//   {"op":"probe","cls":"WMWindowPropertySnapshot"} -> свойства/методы класса (для разбора)
// Сборка: hook/wm/build.sh
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>


static uintptr_t gMgr;   // AppKitApplicationConnectionManager*
static NSMutableDictionary<NSString *, NSDictionary *> *gUuidCache;   // "pid:wid" -> {conn, uuid}

static uintptr_t strip(uintptr_t p) { return p & 0x0000ffffffffffffULL; }

static ptrdiff_t ivarOff(const char *cls, const char *name) {
    Class c = objc_getClass(cls);
    Ivar iv = c ? class_getInstanceVariable(c, name) : NULL;
    return iv ? ivar_getOffset(iv) : -1;
}

static id readObj(uintptr_t base, ptrdiff_t off) {
    if (!base || off < 0) return nil;
    return (__bridge id)(void *)strip(*(uintptr_t *)(base + off));
}

static NSString *grab(NSString *s, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m && m.numberOfRanges > 1 && [m rangeAtIndex:1].location != NSNotFound
        ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}

// Таблица окон для набора pid. Только на главной очереди WindowManager.
static NSDictionary *buildMap(NSSet<NSNumber *> *pids) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!gMgr) return out;
    const char *CONN = "_TtC18WindowManagerAgent27AppKitApplicationConnection";
    ptrdiff_t oActive = ivarOff("_TtC18WindowManagerAgent34AppKitApplicationConnectionManager", "activeConnections");
    ptrdiff_t oBs = ivarOff(CONN, "bsConnection"), oPid = ivarOff(CONN, "pid"), oState = ivarOff(CONN, "mainQueueState");
    if (oActive < 0 || oBs < 0 || oPid < 0 || oState < 0) return @{@"error": @"ivar layout changed"};
    id active = readObj(gMgr, oActive);
    for (id c in [active allValues]) {
        uintptr_t cp = (uintptr_t)(__bridge void *)c;
        int pid = *(int *)(cp + oPid);
        if (pids.count && ![pids containsObject:@(pid)]) continue;
        id bs = readObj(cp, oBs);
        id wins = readObj(cp, oState);
        NSMutableDictionary *wd = [NSMutableDictionary dictionary];
        for (id key in [wins allKeys]) {
            NSString *uuid = [key description];
            NSString *desc = [[wins objectForKey:key] description];
            NSString *snap = grab(desc, @"snapshot: <WMWindowPropertySnapshot: (0x[0-9a-f]+)>");
            if (!snap) continue;
            id so = (__bridge id)(void *)strtoull(snap.UTF8String, NULL, 16);
            unsigned wid = ((unsigned (*)(id, SEL))objc_msgSend)(so, sel_registerName("cgWindowID"));
            NSString *type = grab(desc, @"modelWindowType: Optional\\((\\w+)\\)") ?: @"";
            NSString *tags = grab(desc, @"modelTags: \\[([^\\]]*)\\]") ?: @"";
            NSMutableArray *ta = [NSMutableArray array];
            for (NSString *t in [tags componentsSeparatedByString:@","]) {
                NSString *x = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (x.length) [ta addObject:x];
            }
            wd[[NSString stringWithFormat:@"%u", wid]] = @{@"uuid": uuid, @"type": type, @"tags": ta};
            gUuidCache[[NSString stringWithFormat:@"%d:%u", pid, wid]] =
                @{@"conn": [NSValue valueWithPointer:(__bridge void *)bs], @"uuid": uuid};
        }
        out[[NSString stringWithFormat:@"%d", pid]] = wd;
    }
    return out;
}

static NSString *resizeOne(NSDictionary *j) {
    NSString *k = [NSString stringWithFormat:@"%@:%@", j[@"pid"], j[@"wid"]];
    NSDictionary *e = gUuidCache[k];
    if (!e) { buildMap([NSSet setWithObject:j[@"pid"]]); e = gUuidCache[k]; }
    if (!e) return [NSString stringWithFormat:@"%@: окно не найдено в WindowManager", k];
    id bs = (__bridge id)[e[@"conn"] pointerValue];
    NSArray *sp = j[@"spring"] ?: @[@1.0, @210.0, @24.0, @0.001];
    CGRect r = CGRectMake([j[@"x"] doubleValue], [j[@"y"] doubleValue], [j[@"w"] doubleValue], [j[@"h"] doubleValue]);
    id geo = ((id (*)(id, SEL, CGRect, long long))objc_msgSend)(
        NSClassFromString(@"_WMResizeTargetGeometry"), sel_registerName("targetGeometryWithFrame:contentsGravity:"),
        r, [j[@"gravity"] ?: @2 longLongValue]);
    id spring = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        [NSClassFromString(@"_WMSpringAnimationSettings") alloc], sel_registerName("initWithMass:stiffness:damping:epsilon:"),
        [sp[0] doubleValue], [sp[1] doubleValue], [sp[2] doubleValue], [sp[3] doubleValue]);
    id req = ((id (*)(id, SEL, id, id, id, id, BOOL))objc_msgSend)(
        [NSClassFromString(@"_WMClientResizeWindowRequest") alloc],
        sel_registerName("initWithRequestID:windowID:targetGeometry:springSettings:requiresResponse:"),
        NSUUID.UUID.UUIDString, e[@"uuid"], geo, spring, NO);
    if (!geo || !spring || !req) return [NSString stringWithFormat:@"%@: не собрался запрос", k];
    id rt = ((id (*)(id, SEL))objc_msgSend)(bs, sel_registerName("remoteTarget"));
    if (!rt) { [gUuidCache removeObjectForKey:k]; return [NSString stringWithFormat:@"%@: нет remoteTarget", k]; }
    ((void (*)(id, SEL, id))objc_msgSend)(rt, sel_registerName("performResizeWindowRequest:"), req);
    return nil;
}

static NSDictionary *probe(NSString *cls) {
    Class c = NSClassFromString(cls);
    if (!c) return @{@"error": @"нет класса"};
    NSMutableArray *props = [NSMutableArray array], *meths = [NSMutableArray array];
    unsigned n = 0;
    objc_property_t *pl = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++)
        [props addObject:[NSString stringWithFormat:@"%s %s", property_getName(pl[i]), property_getAttributes(pl[i])]];
    free(pl);
    Method *ml = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++)
        [meths addObject:[NSString stringWithFormat:@"%s %s", sel_getName(method_getName(ml[i])), method_getTypeEncoding(ml[i])]];
    free(ml);
    return @{@"props": props, @"methods": meths};
}

static NSDictionary *handle(NSDictionary *req) {
    NSString *op = req[@"op"];
    if ([op isEqual:@"ping"]) return @{@"ok": @YES, @"pid": @(getpid()), @"mgr": [NSString stringWithFormat:@"0x%lx", gMgr]};
    if ([op isEqual:@"mgr"]) {
        uintptr_t a = strtoull([req[@"addr"] UTF8String], NULL, 16);
        const char *n = a ? object_getClassName((__bridge id)(void *)a) : "";
        if (!strstr(n, "AppKitApplicationConnectionManager")) return @{@"ok": @NO, @"error": @"не менеджер"};
        gMgr = a; [gUuidCache removeAllObjects];
        return @{@"ok": @YES};
    }
    if ([op isEqual:@"map"]) {
        [gUuidCache removeAllObjects];
        return @{@"ok": @YES, @"map": buildMap([NSSet setWithArray:req[@"pids"] ?: @[]])};
    }
    if ([op isEqual:@"resize"]) {
        if (!gMgr) return @{@"ok": @NO, @"error": @"нет менеджера"};
        NSMutableArray *errs = [NSMutableArray array];
        for (NSDictionary *j in req[@"jobs"]) { NSString *e = resizeOne(j); if (e) [errs addObject:e]; }
        return @{@"ok": @(errs.count == 0), @"errors": errs};
    }
    if ([op isEqual:@"probe"]) return probe(req[@"cls"]);
    return @{@"ok": @NO, @"error": @"неизвестная операция"};
}

static void serveClient(int fd) {
    FILE *f = fdopen(fd, "r+");
    char *line = NULL; size_t cap = 0;
    while (getline(&line, &cap, f) > 0) {
        @autoreleasepool {
            NSData *d = [NSData dataWithBytes:line length:strlen(line)];
            NSDictionary *req = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            __block NSDictionary *resp = nil;
            if (![req isKindOfClass:NSDictionary.class]) resp = @{@"ok": @NO, @"error": @"плохой JSON"};
            else dispatch_sync(dispatch_get_main_queue(), ^{
                @try { resp = handle(req); }
                @catch (NSException *ex) { resp = @{@"ok": @NO, @"error": ex.reason ?: @"exception"}; }
            });
            NSData *o = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
            fwrite(o.bytes, 1, o.length, f); fputc('\n', f); fflush(f);
        }
    }
    free(line); fclose(f);
}

__attribute__((constructor)) static void start(void) {
    gUuidCache = [NSMutableDictionary dictionary];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
        snprintf(path, sizeof path, "%shyprwm.sock", getenv("TMPDIR") ?: "/tmp/");
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        strlcpy(a.sun_path, path, sizeof a.sun_path);
        unlink(path);
        if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8)) { NSLog(@"[hyprwm] сокет не поднялся"); return; }
        chmod(path, 0600);
        NSLog(@"[hyprwm] слушаю %s", path);
        for (;;) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ serveClient(c); });
        }
    });
}
