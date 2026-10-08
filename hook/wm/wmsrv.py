# Сторона lldb постоянного моста к WindowManager.app (см. wmbridge.py).
# Процесс WindowManager работает свободно; на запрос мост делает interrupt -> do() -> continue.
# do() печатает одну строку "@@R <json>" — по ней мост понимает, что ответ готов.
import base64
import json
import os
import re
import time

import lldb

STATE = "/Users/fsociety/Developer/re-tools/hook/wm.state"
MGR_NAME = '"WindowManagerAgent.AppKitApplicationConnectionManager"'
# поля Swift-классов WindowManagerAgent (class_copyIvarList, macOS 26.7.1)
MGR_ACTIVE, CONN_BS, CONN_PID, CONN_WINS = 0x18, 0x8, 0x30, 0x50

mgr = None
err = lldb.SBError()


def _t():
    return lldb.debugger.GetSelectedTarget()


def _opts():
    o = lldb.SBExpressionOptions()
    o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    o.SetUnwindOnError(True)
    o.SetIgnoreBreakpoints(True)
    o.SetTimeoutInMicroSeconds(3000000)
    return o


def ev(e):
    return _t().EvaluateExpression(e, _opts())


def u(e):
    return ev(e).GetValueAsUnsigned()


def r64(a):
    return int.from_bytes(_t().GetProcess().ReadMemory(a, 8, err), "little") & 0x0000ffffffffffff


def r32(a):
    return int.from_bytes(_t().GetProcess().ReadMemory(a, 4, err), "little")


def sel(n):
    return '((SEL(*)(const char*))sel_registerName)("%s")' % n


def is_mgr(a):
    return bool(a) and ev('(char*)object_getClassName((id)0x%x)' % a).GetSummary() == MGR_NAME


def find_mgr():
    """Адрес менеджера подключений: кэш по pid, иначе поиск ссылок на его класс в куче."""
    global mgr
    pid = _t().GetProcess().GetProcessID()
    if os.path.exists(STATE):
        s = open(STATE).read().split()
        if len(s) == 2 and int(s[0]) == pid and is_mgr(int(s[1], 16)):
            mgr = int(s[1], 16)
            return mgr
    ci = lldb.debugger.GetCommandInterpreter()
    r = lldb.SBCommandReturnObject()
    ci.HandleCommand("command script import lldb.macosx.heap", r)
    cls = u('(unsigned long)objc_getClass("_TtC18WindowManagerAgent34AppKitApplicationConnectionManager")')
    r = lldb.SBCommandReturnObject()
    ci.HandleCommand("ptr_refs --max-matches 64 0x%x" % cls, r)
    for base in re.findall(r"-> (0x[0-9a-f]+) \+ 0\b", r.GetOutput() or ""):
        if is_mgr(int(base, 16)):
            mgr = int(base, 16)
            open(STATE, "w").write("%d %x\n" % (pid, mgr))
            return mgr
    raise RuntimeError("менеджер подключений WindowManager не найден")


def op_map(req):
    """pid -> {conn, cobj, windows:{wid:{uuid,type,tags,style}}} для запрошенных pid.
    Ускорение: req.cobj {pid: адрес AppKitApplicationConnection} — без перебора всех подключений;
    req.skip [uuid] — уже известные окна не разбираются (их description — самое дорогое)."""
    want = set(req.get("pids") or [])
    hints = {int(k): int(v, 16) for k, v in (req.get("cobj") or {}).items()}
    skip = set(req.get("skip") or [])
    conns = []
    for pid, c in hints.items():
        if pid in want and r32(c + CONN_PID) == pid:
            conns.append(c)
            want.discard(pid)
    if want or not req.get("pids"):
        allc = u('(unsigned long)[(id)0x%x allValues]' % r64(mgr + MGR_ACTIVE))
        for i in range(u('(unsigned long)[(id)0x%x count]' % allc)):
            c = u('(unsigned long)[(id)0x%x objectAtIndex:%d]' % (allc, i))
            if not req.get("pids") or r32(c + CONN_PID) in want:
                conns.append(c)
    out = {}
    for c in conns:
        pid = r32(c + CONN_PID)
        ent = {"conn": "0x%x" % r64(c + CONN_BS), "cobj": "0x%x" % c, "windows": {}}
        wd = r64(c + CONN_WINS)
        allk = ev('(id)[[(id)0x%x allKeys] componentsJoinedByString:@","]' % wd).GetObjectDescription() or ""
        for key in [k for k in allk.split(",") if k]:          # одно выражение на все ключи
            if key in skip:
                continue
            desc = ev('(id)[(id)[(id)0x%x objectForKey:@"%s"] description]' % (wd, key)).GetObjectDescription() or ""
            m = re.search(r"snapshot: <WMWindowPropertySnapshot: (0x[0-9a-f]+)>", desc)
            if not m:
                continue
            cg = u('(unsigned int)[(id)%s cgWindowID]' % m.group(1))
            style = u('(unsigned long)[(id)%s styleMask]' % m.group(1))
            typ = (re.search(r"modelWindowType: Optional\((\w+)\)", desc) or [None, None])[1]
            tags = (re.search(r"modelTags: \[([^\]]*)\]", desc) or [None, ""])[1]
            ent["windows"][str(cg)] = {"uuid": key, "type": typ, "style": style,
                                       "tags": [x.strip() for x in tags.split(",") if x.strip()]}
        out[str(pid)] = ent
    return {"ok": True, "map": out}


def op_resize(req):
    """Отдельное выражение на каждый шаг: составное (локальные id + objc_msgSend) падает на PAC (0xd63f091f)."""
    errs = []
    for j in req["jobs"]:
        M, K, D, EPS = j.get("spring", [1.0, 210.0, 24.0, 0.001])
        try:
            geo = u('struct R_ { double a, b, c, d; }; R_ r = {%r, %r, %r, %r};'
                    '(void*)((id(*)(id,SEL,R_,long long))objc_msgSend)((id)NSClassFromString(@"_WMResizeTargetGeometry"), %s, r, %dLL)'
                    % (float(j["x"]), float(j["y"]), float(j["w"]), float(j["h"]),
                       sel("targetGeometryWithFrame:contentsGravity:"), int(j.get("gravity", 2))))
            sp = u('(void*)((id(*)(id,SEL,double,double,double,double))objc_msgSend)((id)[(id)NSClassFromString(@"_WMSpringAnimationSettings") alloc], %s, %r, %r, %r, %r)'
                   % (sel("initWithMass:stiffness:damping:epsilon:"), float(M), float(K), float(D), float(EPS)))
            rid = u('(void*)[[(id)NSClassFromString(@"NSUUID") UUID] UUIDString]')
            wid = u('(void*)[(id)NSClassFromString(@"NSString") stringWithUTF8String:"%s"]' % j["uuid"])
            if not (geo and sp and rid and wid):
                raise RuntimeError("не собрались части запроса")
            rq = u('(void*)((id(*)(id,SEL,id,id,id,id,BOOL))objc_msgSend)((id)[(id)NSClassFromString(@"_WMClientResizeWindowRequest") alloc], %s, (id)0x%x, (id)0x%x, (id)0x%x, (id)0x%x, (BOOL)0)'
                   % (sel("initWithRequestID:windowID:targetGeometry:springSettings:requiresResponse:"), rid, wid, geo, sp))
            rt = u('(void*)[(id)%s remoteTarget]' % j["conn"])
            if not (rq and rt):
                raise RuntimeError("нет запроса или remoteTarget")
            r = ev('((void(*)(id,SEL,id))objc_msgSend)((id)0x%x, %s, (id)0x%x); (int)1' % (rt, sel("performResizeWindowRequest:"), rq))
            if r.GetValueAsUnsigned() != 1:
                raise RuntimeError(r.GetError().GetCString())
        except Exception as e:
            errs.append({"wid": j.get("wid"), "error": str(e)[:200]})
    return {"ok": not errs, "errors": errs}


def op_order(req):
    """Убрать окно с экрана (mode 0) / вернуть поверх (mode 1) соединением WindowManager:
    у него com.apple.private.skylight.windowmanager — сервер разрешает трогать чужие окна."""
    cid = u('(unsigned long)((int(*)(void))SLSMainConnectionID)()')
    r = ev('(int)((int(*)(int,unsigned int,int,unsigned int))SLSOrderWindow)(%d, %d, %d, 0)'
           % (cid, int(req["wid"]), int(req["mode"])))
    if r.GetError().Fail():
        return {"ok": False, "error": r.GetError().GetCString()}
    return {"ok": r.GetValueAsSigned() == 0, "err": r.GetValueAsSigned()}


def op_key(req):
    """Нажатие клавиши в конкретное приложение (у WindowManager есть kTCCServicePostEvent)."""
    for down in (1, 0):
        e = u('(unsigned long)((void*(*)(void*,unsigned short,bool))CGEventCreateKeyboardEvent)(0, %d, %d)'
              % (int(req["keycode"]), down))
        if not e:
            return {"ok": False, "error": "событие не создалось"}
        ev('((void(*)(void*,unsigned long long))CGEventSetFlags)((void*)0x%x, %dULL)' % (e, int(req.get("flags", 0))))
        ev('((void(*)(int,void*))CGEventPostToPid)(%d, (void*)0x%x)' % (int(req["pid"]), e))
        ev('((void(*)(void*))CFRelease)((void*)0x%x)' % e)
    return {"ok": True}


def _wait_stopped():
    p = _t().GetProcess()
    end = time.time() + 2
    while p.GetState() != lldb.eStateStopped and time.time() < end:
        time.sleep(0.003)
    return p.GetState() == lldb.eStateStopped


def do(b64):
    try:
        req = json.loads(base64.b64decode(b64))
        if not _wait_stopped():
            resp = {"ok": False, "error": "WindowManager не остановился"}
        elif req["op"] == "setup":
            resp = {"ok": True, "mgr": "0x%x" % find_mgr(), "pid": _t().GetProcess().GetProcessID()}
        elif mgr is None:
            resp = {"ok": False, "error": "нет менеджера (setup)"}
        elif req["op"] == "map":
            resp = op_map(req)
        elif req["op"] == "resize":
            resp = op_resize(req)
        elif req["op"] == "order":
            resp = op_order(req)
        elif req["op"] == "key":
            resp = op_key(req)
        else:
            resp = {"ok": False, "error": "неизвестная операция"}
    except Exception as ex:  # ответ должен прийти всегда, иначе мост ждёт до таймаута
        resp = {"ok": False, "error": "%s: %s" % (type(ex).__name__, ex)}
    print("@@R " + json.dumps(resp, ensure_ascii=False))
