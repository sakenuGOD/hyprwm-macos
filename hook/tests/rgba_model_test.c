// Fake typed API: ownership/fault contracts only, not native COW or pixels.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;typedef uint64_t u64;
#include "../src/presentation_model.h"
enum {LAYER,ARRAY,TOKEN};
struct object {void *p,*from;unsigned char *before;size_t size;int type,refs,source,creator,baseline,mods;};
static struct object objects[512];static unsigned object_count;
static int alloc_attempt,array_attempt,alloc_failure,array_failure;
static struct rgba_model_source source;
static void *root_mask,*own_mask,*animation;
static void *field(void *p,size_t off){return *(void **)((char *)p+off);}
static void put(void *p,size_t off,void *value){*(void **)((char *)p+off)=value;}
static struct object *object(void *p){
 for(unsigned i=0;i<object_count;i++)if(objects[i].p==p && objects[i].refs)return &objects[i];
 assert(!"unknown/dead object or duplicate release");return 0;
}
static void *make(size_t size,int type,int original,int creator){
 assert(object_count<512);void *p=calloc(1,size);assert(p);
 objects[object_count++]=(struct object){.p=p,.size=size,.type=type,.refs=1,.source=original,.creator=creator};return p;
}
static void retain(void *p){if(p)object(p)->refs++;}
static void release(void *p){
 if(!p)return;struct object *o=object(p);if(--o->refs)return;
 if(o->type==LAYER) {
  const unsigned offsets[]={0x68,0x70,0x78,0x80,0x88,0x90,0x98};
  for(unsigned i=0;i<7;i++)release(field(p,offsets[i]));
 }else if(o->type==ARRAY) {
  u32 n=*(u32 *)((char *)p+0x10);
  for(u32 i=0;i<n;i++)release(((void **)((char *)p+0x18))[i]);
 }
 free(p);
}
static void owned(void *p){assert(object(p)->type==LAYER && !object(p)->source);}
static void *allocate(u64 size){assert(size==0xa0);if(++alloc_attempt==alloc_failure)return 0;return make(size,LAYER,0,0);}
static void copy_layer(void *p,const void *q){
 owned(p);assert(object((void *)q)->type==LAYER);memcpy(p,q,0xa0);put(p,0x90,0);object(p)->from=(void *)q;
 const unsigned offsets[]={0x68,0x70,0x78,0x80,0x88,0x98};
 for(unsigned i=0;i<6;i++)retain(field(p,offsets[i]));
}
static void *array(u32 n,void *const *items,int original){
 void *a=make(0x18+n*sizeof(void *),ARRAY,original,0);*(u32 *)((char *)a+0x10)=n;
 for(u32 i=0;i<n;i++){assert(items[i]);((void **)((char *)a+0x18))[i]=items[i];retain(items[i]);}
 return a;
}
static void *new_array(u32 n,void *const *items,int refs,u32 flags){
 assert(refs==1&&!flags&&n&&n<=RGBA_MODEL_LIMIT);if(++array_attempt==array_failure)return 0;return array(n,items,0);
}
static void sublayers(void *p,void *a){
 owned(p);retain(a);release(field(p,0x70));put(p,0x70,a);*(u32 *)((char *)p+0xc)&=~(1U<<13);
}
static void animations(void *p,void *a){owned(p);retain(a);release(field(p,0x90));put(p,0x90,a);}
static void modifiers(void *p,void *a){owned(p);assert(!a);object(p)->mods|=1;}
static void remotes(void *p,void *a){owned(p);assert(!a);object(p)->mods|=2;}
static void number(void *p,const u32 *atom,u64 n,int additive,u64 components,const double *v){
 owned(p);assert(n==1&&!additive&&components==1&&(*v==0||*v==1));
 assert(*atom==0x21b||*atom==0xa4||*atom==0x4d||*atom==0x265||*atom==0x284||*atom==0x28a);
 if(*atom==0x21b)((unsigned char *)p)[0x24]=255;
}
static void clear(void *p,void *a){owned(p);assert(!a);}
static void mask(void *p,void *a){owned(p);assert(!a);release(field(p,0x78));put(p,0x78,0);}
static const struct rgba_model_api api={allocate,copy_layer,release,new_array,sublayers,animations,
 modifiers,remotes,number,clear,clear,clear,mask,clear,clear};
static void *layer(void){
 void *p=make(0xa0,LAYER,1,1),*handle=make(32,TOKEN,1,1);put(p,0x98,handle);retain(handle);
 void *ext=make(32,TOKEN,1,1);put(p,0x88,ext);retain(ext);
 *(double *)((char *)p+0x38)=17.375;*(double *)((char *)p+0x48)=-29.125;
 ((unsigned char *)p)[0x24]=123;return p;
}
static void children(void *p,void *const *items,u32 count){
 assert(!field(p,0x70));
 if(count==1){*(u32 *)((char *)p+0xc)|=1U<<13;put(p,0x70,items[0]);retain(items[0]);}
 else if(count)put(p,0x70,array(count,items,1));
}
static void init(void){
 memset(objects,0,sizeof(objects));object_count=0;memset(&source,0,sizeof(source));
 alloc_attempt=array_attempt=alloc_failure=array_failure=0;
 for(unsigned i=0;i<RM_ROLES;i++)source.role[i]=layer();
 source.omit[0]=layer();source.omit[1]=layer();
 root_mask=make(32,TOKEN,1,1);own_mask=make(32,TOKEN,1,1);animation=make(32,TOKEN,1,1);
 source.own_mask=own_mask;put(source.role[RM_ROOT],0x78,root_mask);retain(root_mask);
 put(source.role[RM_CLIP],0x78,own_mask);retain(own_mask);
 put(source.role[RM_BODY],0x90,animation);retain(animation);
 void *root[]={source.role[RM_STYLE]};children(source.role[RM_ROOT],root,1);
 void *style[]={source.role[RM_CLIP],source.omit[0]};children(source.role[RM_STYLE],style,2);
 void *clip[]={source.role[RM_BACKDROP],source.role[RM_NEUTRAL],source.role[RM_PORTAL]};children(source.role[RM_CLIP],clip,3);
 void *neutral[]={source.role[RM_BODY]};children(source.role[RM_NEUTRAL],neutral,1);
 void *body[]={source.role[RM_BELOW],source.role[RM_PRIMARY],source.omit[1],source.role[RM_ABOVE]};children(source.role[RM_BODY],body,4);
}
static void snapshot(void){
 for(unsigned i=0;i<object_count;i++)if(objects[i].source&&objects[i].refs){
  struct object *o=&objects[i];assert(!o->before);o->before=malloc(o->size);assert(o->before);
  memcpy(o->before,o->p,o->size);o->baseline=o->refs;
 }
}
static void unchanged(void){
 for(unsigned i=0;i<object_count;i++){
  struct object *o=&objects[i];
  if(o->source){assert(o->refs==o->baseline);if(o->before)assert(!memcmp(o->p,o->before,o->size));else assert(!o->refs);}
  else assert(!o->refs);
 }
}
static void finish(void){
 for(unsigned i=0;i<object_count;i++)if(objects[i].source&&objects[i].creator)release(objects[i].p);
 for(unsigned i=0;i<object_count;i++){assert(!objects[i].refs);free(objects[i].before);}
}
static void *find(void *root,void *original){
 if(field(root,0x98)==field(original,0x98))return root;
 void *list[RGBA_MODEL_LIMIT];u32 n;assert(rgba_model_children(root,list,&n));
 for(u32 i=0;i<n;i++){void *p=find(list[i],original);if(p)return p;}return 0;
}
static void success(void){
 init();snapshot();struct rgba_model_result out;assert(rgba_model_copy(&api,&source,&out));
 assert(!out.reason&&out.root&&out.root!=source.role[RM_ROOT]&&out.nodes==12&&out.copies==5);
 assert(field(out.root,0x78)==root_mask&&((unsigned char *)out.root)[0x24]==255);
 assert(*(double *)((char *)out.root+0x38)==17.375&&*(double *)((char *)out.root+0x48)==-29.125);
 void *clip=find(out.root,source.role[RM_CLIP]),*body=find(out.root,source.role[RM_BODY]);
 assert(clip&&body&&clip!=source.role[RM_CLIP]&&body!=source.role[RM_BODY]&&!field(clip,0x78));
 assert(field(body,0x90)==animation&&object(body)->mods==0);
 for(unsigned i=0;i<RM_ROLES;i++)if(i==RM_ROOT||i==RM_STYLE||i==RM_CLIP||i==RM_NEUTRAL)
  assert(object(find(out.root,source.role[i]))->mods==3);
 assert(find(out.root,source.role[RM_PRIMARY])==source.role[RM_PRIMARY]);
 assert(!find(out.root,source.role[RM_BACKDROP])&&!find(out.root,source.role[RM_PORTAL]));
 assert(!find(out.root,source.omit[0])&&!find(out.root,source.omit[1]));
 void *list[RGBA_MODEL_LIMIT];u32 n;assert(rgba_model_children(body,list,&n)&&n==3);
 assert(list[0]==source.role[RM_BELOW]&&list[1]==source.role[RM_PRIMARY]&&list[2]==source.role[RM_ABOVE]);
 release(out.root);unchanged();finish();
}
static void allocation_faults(void){
 for(int failure=1;failure<=5;failure++){
  init();snapshot();alloc_failure=failure;struct rgba_model_result out;
  assert(!rgba_model_copy(&api,&source,&out)&&!out.root&&out.reason==RM_ALLOC);unchanged();finish();
 }
 for(int failure=1;failure<=5;failure++){
  init();snapshot();array_failure=failure;struct rgba_model_result out;
  assert(!rgba_model_copy(&api,&source,&out)&&!out.root&&out.reason==RM_ARRAY);unchanged();finish();
 }
}
static void baseline_and_subclass_refusal(void){
 init();void *clip=source.role[RM_CLIP];release(field(clip,0x70));put(clip,0x70,0);
 void *list[]={source.role[RM_BODY],source.role[RM_BACKDROP]};children(clip,list,2);
 source.role[RM_NEUTRAL]=source.role[RM_PORTAL]=0;snapshot();struct rgba_model_result out;
 assert(rgba_model_copy(&api,&source,&out)&&out.copies==4);
 void *body=find(out.root,source.role[RM_BODY]);void *copy=find(out.root,clip);void *items[128];u32 count;
 assert(rgba_model_children(copy,items,&count)&&count==1&&items[0]==body);
 release(out.root);unchanged();finish();
 init();source.omit[2]=layer();void *single[]={source.omit[2]};children(source.role[RM_PRIMARY],single,1);snapshot();
 assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_ROLE&&!out.root);unchanged();finish();
}
static void graph_faults(void){
 init();void *old=field(source.role[RM_ROOT],0x70);put(source.role[RM_ROOT],0x70,source.role[RM_ROOT]);snapshot();
 struct rgba_model_result out;assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_GRAPH&&!alloc_attempt);unchanged();
 put(source.role[RM_ROOT],0x70,old);finish();
 init();source.own_mask=0;snapshot();assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_MASK&&!alloc_attempt);unchanged();finish();
 init();source.omit[2]=layer();snapshot();assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_ROLE&&!alloc_attempt);unchanged();finish();
 init();source.omit[2]=source.omit[0];snapshot();assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_ROLE&&!alloc_attempt);unchanged();finish();
 init();source.role[RM_PRIMARY]=source.role[RM_BODY];snapshot();assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_ROLE&&!alloc_attempt);unchanged();finish();
 init();void *extra=layer(),*style=field(source.role[RM_STYLE],0x70);void **items=(void **)((char *)style+0x18);
 void *next[]={source.role[RM_CLIP]};children(extra,next,1);retain(extra);release(items[0]);items[0]=extra;snapshot();
 assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_ROLE&&!alloc_attempt);unchanged();finish();
 init();void *a=field(source.role[RM_CLIP],0x70);u32 count=*(u32 *)((char *)a+0x10);*(u32 *)((char *)a+0x10)=129;snapshot();
 assert(!rgba_model_copy(&api,&source,&out)&&out.reason==RM_GRAPH&&!alloc_attempt);unchanged();*(u32 *)((char *)a+0x10)=count;finish();
}
int main(void){success();allocation_faults();graph_faults();baseline_and_subclass_refusal();puts("MODEL source immutability/typed custody/both role topologies/subclass-copy refusal/ordered hosts/mask provenance/10 allocation faults PASS (CPU fakes only)");return 0;}
