#!/usr/bin/env python3
"""Bounded Mach-O gate for the C-only, raw __TEXT loader; never loads code."""
import argparse,hashlib,json,struct
from pathlib import Path

def qualify(path):
 b=Path(path).read_bytes();errors=[];segments=[];chains=[];waivers=[]
 digest=hashlib.sha256(b).hexdigest()
 known_baseline=digest=='1a0244ced286b54ef12501e8cb6e6e42a25c24889ea8a743d2d2115682473ef6'
 def need(off,n):
  if not 0<=off<=len(b) or not 0<=n<=len(b)-off:raise ValueError('metadata/file range outside input')
 def unpack(fmt,off):need(off,struct.calcsize(fmt));return struct.unpack_from(fmt,b,off)
 def name(x):return x.split(b'\0')[0].decode('ascii')
 if unpack('<I',0)[0]!=0xfeedfacf:raise ValueError('requires thin little-endian Mach-O64')
 _,cpu,sub,filetype,ncmds,cmdsize,flags,reserved=unpack('<8I',0)
 if cpu!=0x100000c:errors.append('not arm64')
 need(32,cmdsize);off=32;fixups=[];dyldinfos=[]
 for _ in range(ncmds):
  cmd,size=unpack('<II',off)
  if size<8 or off+size>32+cmdsize:raise ValueError('invalid load command')
  if cmd==0x19:
   if size<72:raise ValueError('short segment command')
   sn=name(unpack('<16s',off+8)[0]);vm,vs,fo,fs,maxp,initp,ns,sflags=unpack('<QQQQIIII',off+24)
   if 72+ns*80>size:raise ValueError('short section list')
   sections=[]
   for i in range(ns):
    sec=off+72+i*80;secname,segname=unpack('<16s16s',sec)
    addr,length,offset,align,reloff,nreloc,secflags,r1,r2,r3=unpack('<QQ8I',sec+32)
    sections.append({'name':name(secname),'segment':name(segname),'address':addr,'size':length,'relocations':nreloc})
    if nreloc:errors.append('unhandled section relocations '+sn+','+name(secname))
    if sn=='__TEXT' and (addr<vm or length>vs or addr-vm>vs-length):errors.append('TEXT section outside copied segment')
    if name(secname) in ('__stubs','__auth_stubs','__got','__auth_got','__data','__bss','__common') and length:
     errors.append('unsupported section '+sn+','+name(secname))
   row={'name':sn,'vmaddr':vm,'vmsize':vs,'fileoff':fo,'filesize':fs,'sections':sections};segments.append(row)
   if sn not in ('__TEXT','__LINKEDIT') and (vs or fs):errors.append('non-TEXT allocated segment '+sn)
   if sn=='__TEXT':
    if vm!=0 or fo!=0 or not fs or fs>vs:errors.append('TEXT is not zero-based contiguous raw image')
    need(fo,fs)
  elif cmd==0x80000034:
   if size!=16:raise ValueError('bad chained command')
   fixups.append(unpack('<II',off+8))
  elif cmd in (0x22,0x80000022):
   if size!=48:raise ValueError('bad dyld info command')
   dyldinfos.append(unpack('<10I',off+8))
  off+=size
 if off!=32+cmdsize:raise ValueError('load command size mismatch')
 text=[s for s in segments if s['name']=='__TEXT']
 if len(text)!=1:errors.append('requires exactly one TEXT segment')
 for dataoff,datasize in fixups:
  if not datasize:continue
  if dataoff+datasize>len(b):
   if known_baseline and len(text)==1 and dataoff>=text[0]['filesize'] and not errors:
    waivers.append('Exact accepted5ce SHA: historical rawTEXT lacks LINKEDIT; empty-fixup metadata is not re-proven. Not permitted for any new image.')
    continue
   raise ValueError('chained fixups payload absent: qualify complete linked Mach-O before extraction')
  need(dataoff,datasize)
  if datasize<28:raise ValueError('short chained fixups header')
  version,starts,imports,symbols,nimports,iformat,sformat=unpack('<7I',dataoff)
  if version!=0:errors.append('unsupported chained fixups version')
  if nimports:errors.append('nonempty chained imports')
  if not 0<=starts<=datasize-4:raise ValueError('chained starts outside payload')
  base=dataoff+starts;count=unpack('<I',base)[0]
  if count>len(segments) or 4+count*4>datasize-starts:raise ValueError('invalid chained segment count')
  for i in range(count):
   rel=unpack('<I',base+4+i*4)[0]
   if not rel:continue
   a=base+rel
   if a<dataoff or a+22>dataoff+datasize:raise ValueError('chained starts segment outside payload')
   sz,page,fmt,segmentoff,maxvalid,pages=unpack('<IHHQIH',a)
   if sz<22+2*pages or a+sz>dataoff+datasize:raise ValueError('chained pages outside payload')
   startslist=unpack('<%dH'%pages,a+22) if pages else ()
   actual=[j for j,x in enumerate(startslist) if x!=0xffff]
   chains.append({'segment_index':i,'pointer_format':fmt,'segment_offset':segmentoff,'pages_with_fixups':actual})
   if actual:errors.append('actual chained rebases/binds in segment '+str(i))
 # Any legacy opcode stream with rebases/binds is unsupported. Empty streams
 # are accepted; nonempty streams conservatively require a separate relocator.
 for fields in dyldinfos:
  for label,(a,n) in zip(('rebase','bind','weak_bind','lazy_bind'),zip(fields[0:8:2],fields[1:8:2])):
   if not n:continue
   need(a,n)
   if any(b[a:a+n]):errors.append('nonempty legacy '+label+' opcodes')
 return {'path':str(path),'sha256':hashlib.sha256(b).hexdigest(),'accepted':not errors,
         'errors':errors,'segments':segments,'chained_fixups':chains,'trusted_baseline_waivers':waivers,
         'scope':'raw TEXT structural qualification only; no behavior or instruction-custody claim'}

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('image');parser.add_argument('--output');args=parser.parse_args()
 try:r=qualify(args.image)
 except (ValueError,struct.error,UnicodeError,OSError) as e:r={'path':args.image,'accepted':False,'errors':[type(e).__name__+': '+str(e)]}
 text=json.dumps(r,indent=2)+'\n'
 if args.output:Path(args.output).write_text(text)
 print(text,end='')
 raise SystemExit(0 if r['accepted'] else 1)
