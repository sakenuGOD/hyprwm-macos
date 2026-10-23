// Executes actual new producer selection + real existing GPU terminal gate.
// CPU fakes prove contracts, not native compositor coordinate/pixel parity.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static _Alignas(16) char normal[0x500],cwc[0x7b0],wrapper[0x300],client[0x300];
static _Alignas(16) char wraproot[0xa0],approot[0xa0],nodes[2][0x90],included[2][0x20];
static _Alignas(16) char handles[2][0x30];
static int locks,added,refs,expect_local=1,map_calls;
static struct rgba_capture first,next;
static struct ctx engine;
static void head(char *h){*(void **)h=h;*(void **)(h+8)=h;}
static void insert(char *h,char *n,char *parent,void *layer){
 char *last=*(char **)(h+8);*(void **)n=h;*(void **)(n+8)=last;*(void **)last=n;*(void **)(h+8)=n;
 *(void **)(n+0x58)=parent;*(void **)(n+0x20)=layer;head(n+0x60);
}
static int lock(void *c){assert(c==wrapper||c==client);assert(!locks);locks=1;return 0;}
static int unlock(void *c){assert(c==wrapper||c==client);assert(locks);locks=0;return 0;}
static void *root(void *c){assert(locks);return c==wrapper?wraproot:approot;}
static void *assign(void **cell,void *r){*cell=r;refs+=r?1:-1;return cell;}
static void add(void *u,void *c,void *r,const void *transform){assert(u==(void *)0x1000&&c==client&&r==approot&&transform&&locks);added++;}
static void mapping(void *mapper,void *node,void *unused){assert(!expect_local&&node==nodes[1]&&!unused&&locks);map_calls++;struct rgba_matrix **out=(void *)((char *)mapper+8);**out=(struct rgba_matrix){.v={1,0,0,0,0,1,0,0,0,0,1,0,100,40,0,1}};}
static void transform(void *out,const struct rgba_matrix *m,int affine){assert(locks&&affine&&m->v[12]==(expect_local?0:100));memcpy(out,m,sizeof(*m));}
static rect apply(const struct rgba_matrix *m,rect r){r.x+=m->v[12];r.y+=m->v[13];return r;}
static int main_thread(void){return 1;}
static unsigned releases;static void release_obj(void *o){assert(o);releases++;}
struct cb {u64 status;};static struct cb clearcb,drawcb;
static u64 status(void *o,void *sel){assert(sel==(void *)1);return ((struct cb *)o)->status;}
static void setup(struct rgba_capture *g,unsigned width,unsigned sequence){
 memset(g,0,sizeof(*g));g->magic=RGBA_MAGIC;g->size=sizeof(*g);g->version=RGBA_VERSION;g->content_mode=RGBA_CLIENT_DOMAIN_MODE;
 g->pc.magic=PC_MAGIC;g->pc.size=sizeof(g->pc);g->pc.version=1;g->pc.engine=&engine;g->pc.is_main=main_thread;
 g->pc.context=(u64)wrapper;g->pc.client_context=(u64)client;g->pc.client_id=41;g->pc.client_commit_sequence=sequence;g->pc.client_included=1;
 g->pc.baked_alpha=1;g->pc.scale=2;g->pc.capture_rect=(rect){100,40,400,300};
 g->api.lock_context=lock;g->api.unlock_context=unlock;g->api.root=root;g->api.assign_root=assign;g->api.add_context=add;
 g->api.geometry.apply_rect=apply;g->client_api=(struct rgba_client_api){(void *)0x2000,mapping,transform};
 *(void **)(handles[1]+0x18)=client;*(void **)(handles[1]+0x10)=approot;
 *(u64 *)(client+0x110)=73;*(void **)(client+0x118)=handles[1];
 *(u32 *)(client+0x40)=sequence;*(u32 *)(included[1]+0x18)=sequence;*(rect *)(approot+0x48)=(rect){0,0,width,600};
}
static void encoded(struct rgba_capture *g,u64 status_value){
 g->pc.width=g->domain.pixel_width;g->pc.height=g->domain.pixel_height;g->pc.stage=PC_ENCODED;
 g->pc.capture_witness=1;g->pc.status_selector=(void *)1;g->pc.command_buffer=&drawcb;g->clear_buffer=&clearcb;g->clear_submitted=1;
 g->pc.format=80;g->pc.source_unchanged=g->pc.present_unchanged=g->inclusion=1;
 g->pc.texture_ref=(void *)0x3000;g->pc.release_obj=release_obj;
 clearcb.status=4;drawcb.status=status_value;engine.msg=(void *)status;
}
int main(void){
 head(normal+0xd8);insert(normal+0xd8,nodes[0],0,wraproot);insert(nodes[0]+0x60,nodes[1],nodes[0],approot);
 *(void **)(wraproot+0x98)=&handles[0];*(void **)(approot+0x98)=&handles[1];
 *(void **)(cwc+0x48)=client;*(u32 *)(cwc+0x50)=41;
 *(void **)(normal+0x140)=included[0];*(void **)(included[0]+8)=wrapper;*(void **)included[0]=included[1];
 *(u32 *)(included[0]+0x18)=11;*(void **)(included[1]+8)=client;
 setup(&first,800,101);rect native_source=first.pc.capture_rect;
 assert(rgba_add_client(&first,cwc,normal,(void *)0x1000));
 assert(!memcmp(&first.pc.capture_rect,&native_source,sizeof(native_source)));
 assert(first.domain.bounds.w==800&&first.domain.mapped.w==800&&first.domain.pixel_width==1600&&first.domain.pixel_height==1200);
 assert(first.domain.mapped.x==0&&first.domain.mapped.y==0&&first.domain.commit_sequence==101&&!map_calls);
 assert(!rgba_client_domain_ready(&first));encoded(&first,2);assert(!anim_rgba_poll(&first)&&!rgba_client_domain_ready(&first));
 drawcb.status=4;assert(anim_rgba_poll(&first)==4&&rgba_client_domain_ready(&first));
 struct rgba_capture *good=&first;
 setup(&next,400,102);assert(rgba_add_client(&next,cwc,normal,(void *)0x1000));
 assert(next.domain.pixel_width==800&&first.domain.pixel_width==1600);
 encoded(&next,2);assert(!anim_rgba_poll(&next)&&!rgba_client_domain_ready(&next));assert(good==&first);
 drawcb.status=4;assert(anim_rgba_poll(&next)==4&&rgba_client_domain_ready(&next));good=&next;assert(good->domain.commit_sequence==102);
 assert(!memcmp(&next.pc.capture_rect,&native_source,sizeof(native_source)));
 // Actual typed destroy, no fake stage/domain resets: retained arena must not be ready.
 assert(anim_rgba_destroy(&next));assert(next.destroyed&&next.pc.dead&&releases==3);
 assert(next.pc.stage==PC_GPU_COMPLETE&&next.domain.gpu_complete);
 assert(!next.pc.texture_ref&&!next.pc.command_buffer&&!rgba_client_domain_ready(&next));
 // Native optimizer can eliminate the normal posed client root entirely.
 setup(&next,800,103);*(void **)(nodes[1]+0x20)=0;
 assert(rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.domain.pixel_width==1600&&!map_calls);
 assert(!memcmp(&first.domain.bounds,&next.domain.bounds,sizeof(rect)));
 // Even unreadable normal posed graph is unused in local mode; included list remains authoritative.
 setup(&next,800,103);*(void **)(normal+0xd8)=(void *)1;
 assert(rgba_add_client(&next,cwc,normal,(void *)0x1000)&&!map_calls);
 // Legacy mode1 still refuses that malformed/missing node; do not weaken its guard.
 setup(&next,800,103);next.content_mode=1;expect_local=0;
 // Use well-formed graph missingclient, avoiding actual malformedpointer dereference.
 head(normal+0xd8);insert(normal+0xd8,nodes[0],0,wraproot);insert(nodes[0]+0x60,nodes[1],nodes[0],0);
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==RGBA_CLIENT_NODE_ABSENT);
 setup(&next,800,103);next.content_mode=1;*(void **)(nodes[1]+0x20)=approot;
 assert(rgba_add_client(&next,cwc,normal,(void *)0x1000)&&map_calls==1);expect_local=1;
 setup(&next,800,103);*(void **)(client+0x118)=handles[0];
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==236);
 setup(&next,800,103);*(void **)(handles[1]+0x10)=wraproot;
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==236);
 setup(&next,800,103);*(rect *)(approot+0x48)=(rect){.5,0,800,600};
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==237);
 setup(&next,800,103);*(rect *)(approot+0x48)=(rect){8,-4,800,600};
 assert(rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.domain.mapped.x==8&&next.domain.mapped.y==-4);
 // Reused root with a newer actual commit cannot be confused with included old cohort.
 setup(&next,900,103);*(u32 *)(client+0x40)=104;
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==235&&!next.domain.selected);
 setup(&next,400,105);*(void **)(cwc+0x70)=(void *)1;
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&!next.domain.selected);*(void **)(cwc+0x70)=0;
 setup(&next,400,106);next.pc.baked_alpha=.5;
 assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000)&&next.client_reason==234&&!next.domain.selected);
 setup(&next,400,107);*(rect *)(approot+0x48)=(rect){0,0,0,600};assert(!rgba_add_client(&next,cwc,normal,(void *)0x1000));
 printf("PC=%lu RGBA=%lu domain=%lu version=%u sourceRectunchanged=true old1600x1200/new800x1200 exactCommit staleCommitRefused auxRefused alphaRefused GPU2keepsOld GPU4permitsPromotion localRootPresentOrOptimizedAway legacyNodeGuard rootHandleIdentity integerLocalOrigin PASS\n",sizeof(struct pc_capture),sizeof(struct rgba_capture),sizeof(struct rgba_client_domain),RGBA_VERSION);
 return 0;
}
