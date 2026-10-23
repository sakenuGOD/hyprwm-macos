import argparse, ctypes, hashlib, json, socket, subprocess, sys, time, traceback
from pathlib import Path

parser=argparse.ArgumentParser(description='Run disposable native desktop guards; requires a deployed build receipt.')
parser.add_argument('--wm-root',type=Path,default=Path(__file__).resolve().parents[1])
parser.add_argument('--run-root',type=Path,required=True)
parser.add_argument('--screenshot-helper',type=Path,required=True)
parser.add_argument('cases',nargs='*',choices=['G1','G2','G3','G4','G5','G6','G7'])
args=parser.parse_args()
ROOT=args.wm_root.resolve()
OUT=args.run_root.resolve()
BUILD = json.loads((OUT/'evidence/current-build.json').read_text())
run = OUT/'evidence/guards'/f"{BUILD['label']}-{time.time_ns()}"
run.mkdir(parents=True)
rows = {}
trace = []
terminals = []
document = None
ax = ctypes.CDLL(str(ROOT/'hook/build/libax.dylib'))
ax.ax_focus_context.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]

def save(name, value):
    (run/name).write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')

def osa(code):
    r = subprocess.run(['osascript','-e',code],capture_output=True,text=True,timeout=12)
    if r.returncode: raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()

def ctl(command='status'):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3); s.connect('/tmp/hyprwm.ctl');s.sendall((command+'\n').encode())
        data=s.makefile('rb').readline(262145)
    if command=='status': return json.loads(data)
    return data.decode().strip()

def wait(predicate, description, timeout=6):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=predicate()
        if value:return value
        time.sleep(.04)
    raise RuntimeError('timeout: '+description)

def keys(code):
    return osa('tell application "System Events" to '+code)

def term_contents(wid):
    return osa(f'tell application "Terminal" to get contents of selected tab of window id {wid}')

def terminal_focus(wid):
    osa(f'tell application "Terminal"\nset index of window id {wid} to 1\nactivate\nend tell')
    return wait(lambda: native_key()==wid,'native Terminal key '+str(wid))

def native_key():
    pid=int(osa('tell application "System Events" to get unix id of process "Terminal"'))
    wid=ctypes.c_uint();flags=ctypes.c_uint()
    result=ax.ax_focus_context(pid,ctypes.byref(wid),ctypes.byref(flags))
    trace.append({'time':time.monotonic(),'pid':pid,'key':wid.value,'flags':flags.value,'result':result})
    return wid.value

def new_terminal(tag):
    # A shell printf identifies this disposable tab; test input below uses real key events.
    code=f'tell application "Terminal"\nset t to do script "printf \'HYPRWM_{tag}\\n\'"\nactivate\nreturn id of window 1\nend tell'
    wid=int(osa(code));terminals.append(wid)
    wait(lambda:str(wid) in ctl().get('rects',{}),'Terminal admission')
    # do script returns before the shell consumes its startup command.
    wait(lambda:'HYPRWM_'+tag in [line.strip() for line in term_contents(wid).splitlines()],'owned shell printf completed')
    return wid

def shot(name):
    subprocess.run([sys.executable,str(args.screenshot_helper),'--path',str(run/(name+'.png'))],check=True,stdout=subprocess.DEVNULL,timeout=10)

def case(name, fn):
    if args.cases and name not in args.cases:return
    start=time.monotonic()
    try:
        detail=fn();rows[name]={'passed':True,'detail':detail,'elapsed':time.monotonic()-start}
    except Exception as error:
        rows[name]={'passed':False,'error':str(error),'elapsed':time.monotonic()-start}
    save('results.json',{'build':BUILD,'results':rows,'elapsed':time.monotonic()-started})
    print(name,json.dumps(rows[name],ensure_ascii=False),flush=True)

started=time.monotonic()
assert hashlib.sha256(Path(BUILD['actor']['executable']).read_bytes()).hexdigest()==BUILD['binary_sha256']
before=ctl();save('before.json',before)
try:
    def g1():
        a=new_terminal('A');terminal_focus(a);keys('keystroke "1122334455"')
        b=new_terminal('B');terminal_focus(b);keys('keystroke "2233445566"')
        wait(lambda:'1122334455' in term_contents(a) and '2233445566' in term_contents(b),'actual native typed marker')
        rects=ctl()['rects'];ra,rb=rects[str(a)],rects[str(b)]
        overlap=max(0,min(ra[0]+ra[2],rb[0]+rb[2])-max(ra[0],rb[0]))*max(0,min(ra[1]+ra[3],rb[1]+rb[3])-max(ra[1],rb[1]))
        assert overlap<4,'own terminals overlap'
        shot('G1');return {'windows':[a,b],'rects':[ra,rb],'typed':True}
    case('G1',g1)
    def g3():
        assert len(terminals)==2
        for wid,token in zip(terminals,['3344556677','4455667788']):
            r=ctl()['rects'][str(wid)]
            subprocess.run(['cliclick',f'm:{int(r[0]+r[2]/2)},{int(r[1]+r[3]/2)}'],check=True)
            wait(lambda:native_key()==wid,'pointer key ownership')
            keys('key code 32 using control down');keys('keystroke "'+token+'"')
            assert token in term_contents(wid),'hover input marker absent'
        return {'native_and_actual_input':True}
    case('G3',g3)
    def g2():
        a,b=terminals;terminal_focus(b)
        # Close and immediately type without a focus command or click in between.
        osa(f'tell application "Terminal" to close window id {b}\ntell application "System Events" to keystroke "5566778899"')
        terminals.remove(b)
        assert '5566778899' in term_contents(a),'immediate survivor input absent'
        wait(lambda:str(b) not in ctl()['rects'],'closed terminal removed')
        shot('G2');return {'survivor':a,'native_key':native_key(),'typed':True}
    case('G2',g2)
    def g4():
        start=ctl()['space'];trees={str(start):ctl()['tree']}
        keys('key code 124 using control down');dest=wait(lambda:(s:=ctl())['space']!=start and s,'native next Space')['space']
        trees[str(dest)]=ctl()['tree'];keys('key code 123 using control down')
        wait(lambda:ctl()['space']==start,'native return Space')
        assert ctl()['tree']==trees[str(start)],'source membership changed'
        return {'source':start,'destination':dest,'source_tree_preserved':True,'trees':trees}
    case('G4',g4)
    def g5():
        global document
        document=osa('tell application "TextEdit"\nset d to make new document with properties {text:"HYPRWM_G5_20261019"}\nactivate\nreturn name of d\nend tell')
        save('owned-document.json',{'name':document,'marker':'HYPRWM_G5_20261019'})
        # Physical S is independent of the owner's current keyboard layout.
        wait(lambda:osa('tell application "System Events" to get frontmost of process "TextEdit"')=='true','TextEdit frontmost')
        keys('key code 1 using command down')
        wait(lambda:osa('tell application "System Events" to tell process "TextEdit" to get exists sheet 1 of window 1')=='true','native save sheet')
        shot('G5-sheet')
        keys('key code 53')
        wait(lambda:osa('tell application "System Events" to tell process "TextEdit" to get exists sheet 1 of window 1')=='false','save sheet actually gone')
        keys('keystroke "6677889900"')
        text=osa('tell application "TextEdit" to get text of document '+json.dumps(document,ensure_ascii=False))
        assert '6677889900' in text,'input after dismiss absent'
        shot('G5-after');return {'document':document,'sheet_seen':True,'typed':True}
    case('G5',g5)
    def g6():
        data=json.loads((Path.home()/'.cache/hyprwm-native-companion/ui-status.json').read_text())
        shot('G6')
        assert data.get('active_panel_ready') is True,'native bar reports active panel unavailable'
        return {'ui_status':data,'requires_image_review':True}
    case('G6',g6)
    def g7():
        a=terminals[0]
        osa('tell application "TextEdit" to activate');terminal_focus(a)
        keys('key code 13 using option down')
        wait(lambda:a in ctl()['hidden'],'Option+W hidden')
        osa('tell application "TextEdit" to activate');keys('key code 48 using command down')
        # Record native activation before the visibility predicate can time out.
        # Read-only evidence retains the original six-second visibility budget.
        visible_deadline=time.monotonic()+6
        front_pid=int(osa('tell application "System Events" to get unix id of first process whose frontmost is true'))
        terminal_pid=int(osa('tell application "System Events" to get unix id of process "Terminal"'))
        native_key()
        save('G7-after-CmdTab.json',{'time':time.monotonic(),'front_pid':front_pid,'terminal_pid':terminal_pid,'native_key':trace[-1],'wm':ctl(),
             'processes':subprocess.check_output(['ps','-p',str(front_pid)+','+str(terminal_pid),'-o','pid=,lstart=,comm='],text=True)})
        wait(lambda:a not in ctl()['hidden'] and str(a) in ctl()['rects'],'Cmd+Tab visible',max(0,visible_deadline-time.monotonic()))
        assert native_key()==a,'restored terminal lacks key'
        keys('keystroke "7788990011"');assert '7788990011' in term_contents(a),'restored input absent'
        shot('G7');return {'wid':a,'same_window':True,'typed':True}
    case('G7',g7)
finally:
    # Only windows/documents created by this run; owner applications stay running.
    cleanup=[]
    for wid in terminals:
        try:osa(f'tell application "Terminal" to close window id {wid}')
        except Exception as error:cleanup.append(str(error))
    if document:
        try:
            osa('tell application "System Events" to key code 53')
            text=osa('tell application "TextEdit" to get text of document '+json.dumps(document,ensure_ascii=False))
            assert 'HYPRWM_G5_20261019' in text
            osa('tell application "TextEdit" to close document '+json.dumps(document,ensure_ascii=False)+' saving no')
        except Exception as error:cleanup.append(str(error))
    save('native-input-trace.json',trace)
    save('after.json',ctl())
    save('results.json',{'build':BUILD,'results':rows,'cleanup_errors':cleanup,'elapsed':time.monotonic()-started})
    print('EVIDENCE',run,flush=True)
