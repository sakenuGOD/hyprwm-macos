# Convert the linker's sole local personality rebase into an explicit zero
# runtime cell. Merge its adjacent page into TEXT; qualify the resulting FULL
# Mach-O with the unchanged gate. No external bind/import is accepted.
import struct,sys
if sys.flags.optimize:
    raise RuntimeError('Native normalization requires Python optimization disabled')
from pathlib import Path
p=Path(sys.argv[1]);b=bytearray(p.read_bytes());u=lambda off:struct.unpack_from('<I',b,off)[0]
commands=[];off=32;text=None;data=None;fixup=None;symbol_table=None
for _ in range(u(16)):
 cmd,size=u(off),u(off+4);raw=bytearray(b[off:off+size]);commands.append((cmd,raw));
 if cmd==0x19:
  name=bytes(raw[8:24]).split(b'\0')[0];vm,vs,fo,fs=struct.unpack_from('<4Q',raw,24)
  if name==b'__TEXT':assert text is None;text=raw
  elif name==b'__DATA_CONST':assert data is None;data=raw
  else:assert name==b'__LINKEDIT' or vs==fs==0
 if cmd==0x80000034:assert fixup is None;fixup=struct.unpack_from('<II',raw,8)
 if cmd==2:symbol_table=struct.unpack_from('<4I',raw,8)
 off+=size
assert text is not None and data is not None and fixup and symbol_table
assert struct.unpack_from('<Q',text,24)[0]==struct.unpack_from('<Q',text,40)[0]==0
assert struct.unpack_from('<I',data,64)[0]==1 and len(data)==152
vm,vs,fo,fs=struct.unpack_from('<4Q',data,24);assert vm==fo and vs==fs==16384
assert vm==struct.unpack_from('<Q',text,32)[0]==struct.unpack_from('<Q',text,48)[0]
sec=bytearray(data[72:152]);assert bytes(sec[:16]).split(b'\0')[0]==b'__auth_got'
addr,length=struct.unpack_from('<QQ',sec,32);file=struct.unpack_from('<I',sec,48)[0]
assert length==8 and file==addr and addr>=vm and addr+8<=vm+vs and struct.unpack_from('<I',sec,60)[0]==0
symoff,nsyms,stroff,strsize=symbol_table;matches=[]
for i in range(nsyms):
 st,kind,section,desc,value=struct.unpack_from('<IBBHQ',b,symoff+16*i)
 if st and bytes(b[stroff+st:b.index(0,stroff+st)])==b'_rgba_normal_personality':matches.append(value)
assert len(matches)==1;target=matches[0]
base,total=fixup;version,starts,imports,symbols,nimports,iformat,sformat=struct.unpack_from('<7I',b,base)
assert version==0 and nimports==0
start=base+starts;count=u(start);locations=[]
for i in range(count):
 rel=u(start+4+4*i)
 if not rel:continue
 info=start+rel;sz,page,fmt,segoff,maxvalid,npages=struct.unpack_from('<IHHQIH',b,info)
 assert fmt==12 and segoff==vm and page==16384
 for j in range(npages):
  pageoff=info+22+2*j;offset=struct.unpack_from('<H',b,pageoff)[0]
  if offset==0xffff:continue
  assert not offset&0x8000 and segoff+j*page+offset==addr
  value=struct.unpack_from('<Q',b,file)[0]
  assert value==((1<<63)|(1<<48)|target),('unexpected personality auth metadata',hex(value),hex(target))
  locations.append(addr)
assert locations==[addr]
# Chained metadata remains structurally present, with no actual rebases/binds.
struct.pack_into('<I',b,start,count-1)
for i in range(count):struct.pack_into('<I',b,start+4+4*i,0)
struct.pack_into('<Q',b,file,0)
sec[:16]=b'__normal_got'+bytes(4);sec[16:32]=b'__TEXT'+bytes(10)
struct.pack_into('<4I',sec,64,0,0,0,0)
struct.pack_into('<Q',text,32,vm+vs);struct.pack_into('<Q',text,48,fo+fs)
struct.pack_into('<I',text,64,struct.unpack_from('<I',text,64)[0]+1)
text.extend(sec);struct.pack_into('<I',text,4,len(text))
new_commands=b''.join(raw for cmd,raw in commands if raw is not data)
old_size=u(20);assert len(new_commands)<=old_size
b[32:32+old_size]=new_commands+bytes(old_size-len(new_commands))
struct.pack_into('<II',b,16,len(commands)-1,len(new_commands));p.write_bytes(b)
print('EXPLICIT_PERSONALITY_RUNTIME_SLOT',addr,'target',target)
