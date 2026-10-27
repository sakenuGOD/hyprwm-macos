import hashlib,json,struct,sys
if sys.flags.optimize:
    raise RuntimeError('Native extraction requires Python optimization disabled')
from qualify_native import qualify
from pathlib import Path
p=Path(sys.argv[1]).resolve()
qualification=qualify(p/'probe-eh.dylib');assert qualification['accepted'] and not qualification['trusted_baseline_waivers'],qualification
b=(p/'probe-eh.dylib').read_bytes()
u32=lambda off:struct.unpack_from('<I',b,off)[0]
off=32; sections={};symbols={}
for _ in range(u32(16)):
    cmd,size=struct.unpack_from('<II',b,off)
    if cmd==0x19:
        name=b[off+8:off+24].split(b'\0')[0].decode()
        vm,vs,fo,fs=struct.unpack_from('<QQQQ',b,off+24)
        if name=='__TEXT':
            assert vm==fo==0
            text=b[:fs]
            for j in range(u32(off+64)):
                s=off+72+j*80;sn=b[s:s+16].split(b'\0')[0].decode()
                sections[sn]=struct.unpack_from('<QQ',b,s+32)
    if cmd==2: symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',b,off+8)
    off+=size
for j in range(nsyms):
    st,ty,se,de,val=struct.unpack_from('<IBBHQ',b,symoff+16*j)
    if st:
        name=b[stroff+st:b.index(0,stroff+st)].decode()
        symbols[name]=val
assert symbols['_display_native_clone_end']-symbols['_display_native_clone']==156
eh,ehsize=sections['__eh_frame']; pos=eh; records=[]
while pos<eh+ehsize:
    size=u32(pos)
    if size==0: break
    assert size!=0xffffffff and pos+4+size<=eh+ehsize
    ident=u32(pos+4)
    record={'offset':pos,'size':size+4,'cie':None if not ident else pos+4-ident}
    if ident:
        # Current Apple emitter uses pcrel signed8 (0x10) for initial location.
        cie=record['cie']; assert eh<=cie<pos and u32(cie+4)==0
        record['bytes']=b[pos:pos+4+size].hex()
    records.append(record);pos+=size+4
meta={'sha256':hashlib.sha256(text).hexdigest(),'size':len(text),'sections':sections,'symbols':symbols,'eh_records':records}
(p/'probe-eh.bin').write_bytes(text)
(p/'probe-eh-meta.json').write_text(json.dumps(meta,indent=2)+'\n')
wanted=['_anim_rgba_display_entry','_anim_display_probe_entry','_display_native_clone','_display_native_clone_end','_display_native_clone_slots','_display_unwind_check']
header='\n'.join('#define '+name[1:].upper()+'_OFFSET '+str(symbols[name])+'ULL' for name in wanted)
header+=f'\n#define IMAGE_SIZE {len(text)}ULL\n#define EH_OFFSET {eh}ULL\n#define EH_SIZE {ehsize}ULL\n'
(p/'probe-eh-layout.h').write_text(header)
print(json.dumps({'sha256':meta['sha256'],'size':len(text),'eh_size':ehsize,'fdes':sum(x['cie'] is not None for x in records),'symbols':{k:symbols[k] for k in wanted}}))

(p/'candidate-anim4.bin').write_bytes(text)
(p/'candidate-anim4.syms').write_text(json.dumps({'size':len(text),'vmsize':len(text),'syms':{k[1:]:v for k,v in symbols.items() if k.startswith('_')}},indent=2)+'\n')
