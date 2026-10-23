from pathlib import Path
import subprocess,re,json,sys,argparse,platform,tempfile
parser=argparse.ArgumentParser(description='Headless controlled private Source exception regression')
parser.add_argument('--build-dir',type=Path);parser.add_argument('--sanitize',action='store_true');args=parser.parse_args()
if platform.system()!='Darwin' or platform.machine() not in ('arm64','arm64e'):
 print('SKIP: Darwin arm64e required');sys.exit(77)
p=Path(__file__).resolve().parent
build=args.build_dir.resolve() if args.build_dir else Path(tempfile.mkdtemp(prefix='private-source-test-'))
if args.build_dir:build.mkdir(parents=True,exist_ok=False)
commands=[]
def run(args):
 commands.append(args);r=subprocess.run(args,cwd=p,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:print(r.stdout);raise SystemExit(r.returncode)
 return r.stdout
# Only the test translation unit gains this separate core-entry shim. Not part of the product image.
cpp=(p.parents[1]/'src/display_unwind.cpp').read_text()+'''\nextern "C" int fixture_core_body(void*,void*,display_private_source*,du_source_original,du64,du64,du_local*);\nextern "C" __attribute__((noinline)) int fixture_core_entry(void*r,void*w,display_private_source*t,du_source_original original,du64 native_fp){\n DisplayInvocation invocation(&t->bridge,DU_SOURCE);\n invocation.local.entry_fp=(du64)__builtin_frame_address(0);invocation.local.native_fp=native_fp;\n int result=fixture_core_body(r,w,t,original,invocation.local.entry_fp,native_fp,&invocation.local);\n invocation.finish();return result;\n}\n'''
(build/'test-entries.cpp').write_text(cpp)
flags=['-arch','arm64e','-O1','-fexceptions','-funwind-tables','-fasynchronous-unwind-tables','-femit-dwarf-unwind=always','-fno-omit-frame-pointer','-fno-optimize-sibling-calls']
if args.sanitize:flags+=['-fsanitize=address,undefined','-fno-sanitize-recover=all']
objects=[]
for name,source,compiler in [('fixture',p/'fixture.c','clang'),('entries',build/'test-entries.cpp','clang++'),('driver',p/'driver.cpp','clang++')]:
 asm=build/(name+'.s');extra=['-I',str(p.parents[1]/'src'),'-I',str(p)]
 if compiler=='clang++':extra+=['-std=c++17']
 run([compiler,*flags,*extra,'-S',str(source),'-o',str(asm)])
 text=asm.read_text();parts=re.split(r'(\t\.cfi_startproc\n.*?\t\.cfi_endproc)',text,flags=re.S)
 for i,part in enumerate(parts):
  if '.cfi_startproc' in part and re.search(r'^\s*pacibsp\s*$',part,re.M):
   parts[i]=part.replace('\t.cfi_startproc\n','\t.cfi_startproc\n\t.cfi_b_key_frame\n',1)
 asm.write_text(''.join(parts));obj=build/(name+'.o');run(['clang',*flags,'-c',str(asm),'-o',str(obj)]);objects.append(str(obj))
for name in ['SourceMirror','UpdateMirror']:
 obj=build/(name+'.o');run(['clang','-arch','arm64e','-femit-dwarf-unwind=always','-c',str(p/(name+'.S')),'-o',str(obj)]);objects.append(str(obj))
exe=build/'OwnPrivateSource';run(['clang++',*flags,*objects,'-Wl,-no_compact_unwind','-o',str(exe)])
r=subprocess.run([str(exe)],cwd=p,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
name='sanitized-result.txt' if args.sanitize else 'result.txt'
(build/name).write_text(r.stdout+f'\nexit={r.returncode}\n');print(r.stdout);print('exit',r.returncode)
(build/('sanitized-build-commands.json' if args.sanitize else 'build-commands.json')).write_text(json.dumps(commands,indent=2)+'\n')
if r.returncode:sys.exit(1)
