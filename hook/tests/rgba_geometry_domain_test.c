// CPU contract tests only: native cohort/process/GPU custody are separate live
// qualifiers. Callback stubs record calls into the OWN renderer and Update.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;typedef uint32_t u32;
typedef struct {double x,y,w,h;} rect;
struct pc_capture {u64 source,update;u32 wid;int valid;};
static int pc_main(struct pc_capture *p){return p && p->valid;}
static int pc_normal_frame(struct pc_capture *p){return p && p->valid;}
static char *pc_source(struct pc_capture *p){return p && p->valid?(char *)(uintptr_t)p->source:0;}
#include "../src/presentation_rgba.h"
struct region {int refs;};
static struct region regions[64];static int used,calls,transforms,contexts,invalidations;
static int normal_update,own_update,renderer,shared_renderer,offset_x,offset_y;
static double render_scale;static u32 render_features;
static struct rgba_matrix transformed[3];
static void *new_region(void){assert(used<64);regions[used].refs=1;return &regions[used++];}
static void *retain_cf(void *r){assert(r);assert(((struct region *)r)->refs>0);((struct region *)r)->refs++;return r;}
static void release_cf(void *r){assert(r);assert(((struct region *)r)->refs>0);((struct region *)r)->refs--;}
static struct rgba_matrix invert(const struct rgba_matrix *m){
 struct rgba_matrix r={.v={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}};
 assert(m->v[0]!=0 && m->v[5]!=0);r.v[0]=1/m->v[0];r.v[5]=1/m->v[5];
 r.v[12]=-m->v[12]/m->v[0];r.v[13]=-m->v[13]/m->v[5];return r;
}
static struct rgba_matrix affine(const struct rgba_affine *a){
 struct rgba_matrix r={.v={a->a,a->b,0,0,a->c,a->d,0,0,0,0,1,0,a->tx,a->ty,0,1}};return r;
}
static rect apply_rect(const struct rgba_matrix *m,rect r){
 return (rect){r.x*m->v[0]+m->v[12],r.y*m->v[5]+m->v[13],r.w*m->v[0],r.h*m->v[5]};
}
static void *transform(const struct rgba_matrix *m,void *r,int rounding){
 assert(r && rounding==1 && transforms<3);transformed[transforms++]=*m;return new_region();
}
static void *combined(void *a,void *b){assert(a || b);return a?a:b;}
static void *adopt(void *s){assert(s);return new_region();}
static void *intersection(void *a,void *b){assert(a && b);return new_region();}
static void *region_union(void *a,void *b){assert(a && b);return retain_cf(a);}
static int empty(void *r){return r?0:1;}
static void *display_rgb(void){return new_region();}
static void target(void *r){assert(r==&renderer);calls++;}
static void substitute(void *r,float red,float green,float blue,float alpha){target(r);assert(red==0 && green==0 && blue==0 && alpha==0);}
static void features(void *r,u32 f){target(r);render_features=f;}
static void colorspace(void *r,void *color){target(r);assert(color);}
static void update_region(void *r,void *region){target(r);(void)region;}
static void added(void *u){assert(u==&own_update);contexts++;}
static void invalidate(void *u,void *r){assert(u==&own_update && r);invalidations++;}
static void clip(void *u,void *r){assert(u==&own_update);(void)r;}
static void scale(void *r,double s){target(r);render_scale=s;}
static void u32_setter(void *r,u32 value){target(r);(void)value;}
static void hdr(void *r,float value){target(r);(void)value;}
static void offset(void *r,int x,int y){target(r);offset_x=x;offset_y=y;}
static void display(void *r,void *d){target(r);assert(d==0);}
static void *cached_color;
static const struct rgba_geometry_api api={invert,affine,apply_rect,transform,combined,adopt,intersection,region_union,empty,retain_cf,release_cf,display_rgb,&cached_color,substitute,features,colorspace,update_region,added,invalidate,clip,scale,u32_setter,hdr,u32_setter,offset,display};
static _Alignas(16) char win[128],cwc[128],s[0x2d0],q[0x38],d[0xb0];
static struct pc_capture p;
static void fixture(int flip){
 memset(regions,0,sizeof(regions));used=calls=transforms=contexts=invalidations=0;
 memset(win,0,sizeof(win));memset(cwc,0,sizeof(cwc));memset(s,0,sizeof(s));memset(q,0,sizeof(q));memset(d,0,sizeof(d));
 *(void **)(win+0x18)=cwc;*(u32 *)(cwc+0x40)=91;
 p=(struct pc_capture){(u64)(uintptr_t)win,(u64)(uintptr_t)&normal_update,77,1};
 *(u32 *)(s+0x180)=10;*(u32 *)(s+0x268)=77;*(void **)(s+0x48)=q;
 *(u64 *)q=p.source;*(u64 *)(q+0x10)=p.update;*(u32 *)(q+0x18)=flip;*(u32 *)(q+0x28)=91;
 *(u64 *)(s+0x28)=*(u64 *)(s+0x30)=p.update;
 *(rect *)(s+0xc8)=(rect){0,0,400,300};*(float *)(s+0x18c)=4;
 struct rgba_matrix m={.v={.5,0,0,0,0,.5,0,0,0,0,1,0,-6.375,-10.0625,0,1}};
 *(struct rgba_matrix *)(s+0xf0)=m;
 *(int *)(d+0x2c)=5;*(int *)(d+0x30)=7;*(float *)(d+0x4c)=600;*(float *)(d+0x68)=2;
 *(void **)(s+0x1a0)=new_region();*(void **)(s+0x1b0)=new_region();cached_color=new_region();
}
static void vector(int flip){
 fixture(flip);struct rgba_geometry g={0};char source_before[sizeof(s)];memcpy(source_before,s,sizeof(s));
 assert(rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g));
 assert(!memcmp(source_before,s,sizeof(s)));assert(g.scale==.5 && render_scale==.5);
 assert(g.offset_x==14 && g.offset_y==-26 && offset_x==14 && offset_y==-26);
 assert(g.clip.v[12]==-12 && g.clip.v[13]==(flip?-320:320));
 assert(g.update.v[0]==.5 && g.update.v[5]==(flip?.5:-.5));
 assert(g.update.v[12]==-6 && g.update.v[13]==(flip?-160:160));
 assert(g.backdrop.v[13]==(flip?-620:620));
 assert(transforms==3 && contexts==1 && invalidations==1);
 assert(transformed[0].v[13]==g.update.v[13] && transformed[1].v[13]==g.backdrop.v[13] && transformed[2].v[13]==g.clip.v[13]);
 assert(render_features==(flip?0x800000u:0x800001u));
 rgba_geometry_release(&api,&g);assert(!g.region);
 for(int n=3;n<used;n++)assert(regions[n].refs==0);assert(regions[0].refs==1 && regions[1].refs==1 && regions[2].refs==1);
}
// Independently derived from the native instructions by the readonly reviewer.
// In particular -10.5 must truncate toward zero, and the divisor belongs to the
// drawing scale rather than the destination-offset scale.
static void independent_vector(void){
 fixture(1);struct rgba_geometry g={0};
 struct rgba_matrix m={.v={1.25,0,0,0,0,2,0,0,0,0,1,0,12.503662109375,-41.0009765625,0,1}};
 *(struct rgba_matrix *)(s+0xf0)=m;*(rect *)(s+0xc8)=(rect){100,200,80.25,100.75};
 *(float *)(s+0x18c)=.5;*(u32 *)(q+0x18)=0x41;
 *(void **)(s+0x1b0)=0;*(int *)(d+0x2c)=-3;*(int *)(d+0x30)=7;
 *(float *)(d+0x4c)=300.875;*(float *)(d+0x68)=1.5;*(u32 *)(d+0x50)=0x08000000;
 assert(rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g));
 assert(g.clip.v[0]==1 && g.clip.v[5]==1 && g.clip.v[12]==10 && g.clip.v[13]==-120);
 assert(g.update.v[0]==3 && g.update.v[5]==3 && g.update.v[12]==30 && g.update.v[13]==-360);
 assert(g.backdrop.v[0]==1 && g.backdrop.v[5]==1 && g.backdrop.v[12]==10 && g.backdrop.v[13]==-70);
 assert(g.scale==3 && g.offset_x==-10 && g.offset_y==129 && g.features==0x00800041);
 rgba_geometry_release(&api,&g);for(int n=3;n<used;n++)assert(regions[n].refs==0);
}
static void native_capture_modes(void){
 for(unsigned i=0;i<2;i++) {
  fixture(0);struct rgba_geometry g={0};*(u32 *)(d+0x50)=i?0x14440000:0x10440000;
  if(i)*(void **)(d+0x60)=cached_color;
  assert(rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g));
  assert(g.scale==.5 && g.offset_x==14 && g.offset_y==-26);rgba_geometry_release(&api,&g);
 }
}
static void full_client_viewport(void){
 fixture(0);struct rgba_geometry g={0};void *full=new_region();
 // Poison wrapper-only paths. Fresh client coverage must not consume any of
 // these masks, damage unions, or damage-only renderer branches.
 *(void **)(s+0x248)=(void *)1;*(void **)(s+0x250)=(void *)2;
 *(void **)(s+0x1b0)=(void *)3;*(u32 *)(s+0x218)=0x202;
 assert(rgba_geometry_setup_region(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,full));
 assert(g.region==full && ((struct region *)full)->refs==2);
 assert(transforms==3 && contexts==1 && invalidations==1);
 assert(g.scale==.5 && g.offset_x==14 && g.offset_y==-26);
 rgba_geometry_release(&api,&g);assert(((struct region *)full)->refs==1);
 release_cf(full);assert(((struct region *)full)->refs==0);
 assert(regions[0].refs==1 && regions[1].refs==1 && regions[2].refs==1);
 for(int n=4;n<used;n++)assert(regions[n].refs==0);
}
static void independent_client_domain(void){
 fixture(0);struct rgba_geometry g={0};void *full=new_region();rect domain={0,0,800,600};
 char source_before[sizeof(s)],dest_before[sizeof(d)];memcpy(source_before,s,sizeof(s));memcpy(dest_before,d,sizeof(d));
 assert(rgba_geometry_setup_region_domain(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,full,&domain));
 assert(!memcmp(source_before,s,sizeof(s))&&!memcmp(dest_before,d,sizeof(d)));
 assert(g.clip.v[13]==600&&g.update.v[13]==1200&&g.offset_x==-10&&g.offset_y==-586);
 rgba_geometry_release(&api,&g);release_cf(full);
 fixture(0);memset(&g,0,sizeof(g));assert(!rgba_geometry_setup_region_domain(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,0,&domain));
}
static void client_viewport_translated_source(int flip){
 fixture(flip);struct rgba_geometry g={0};void *full=new_region();rect domain={0,0,720,448};
 // Match observed native source(12,44), but OLD full client domain is720x448.
 *(struct rgba_matrix *)(s+0xf0)=(struct rgba_matrix){.v={1,0,0,0,0,1,0,0,0,0,1,0,-12,-44,0,1}};
 *(rect *)(s+0xc8)=(rect){12,44,400,300};*(float *)(s+0x18c)=4;
 *(int *)(d+0x2c)=*(int *)(d+0x30)=0;*(float *)(d+0x4c)=896;*(float *)(d+0x68)=2;
 char before[sizeof(s)];memcpy(before,s,sizeof(s));
 assert(rgba_geometry_setup_region_domain(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,full,&domain));
 assert(!memcmp(before,s,sizeof(s))&&g.scale==2&&g.offset_x==0&&g.offset_y==0);
 assert(g.clip.v[12]==0&&g.update.v[12]==0&&g.backdrop.v[12]==0);
 struct rgba_geometry expected=g;rgba_geometry_release(&api,&g);release_cf(full);
 // Moving or scaling ONLY the excluded wrapper cannot change client raster geometry.
 fixture(flip);full=new_region();memset(&g,0,sizeof(g));
 *(struct rgba_matrix *)(s+0xf0)=(struct rgba_matrix){.v={3,0,0,0,0,2,0,0,0,0,1,0,333,-777,0,1}};
 *(float *)(s+0x18c)=.25;*(int *)(d+0x2c)=*(int *)(d+0x30)=0;*(float *)(d+0x4c)=896;*(float *)(d+0x68)=2;
 assert(rgba_geometry_setup_region_domain(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,full,&domain));
 assert(!memcmp(&expected.update,&g.update,sizeof(g.update))&&!memcmp(&expected.backdrop,&g.backdrop,sizeof(g.backdrop)));
 assert(!memcmp(&expected.clip,&g.clip,sizeof(g.clip))&&g.scale==2&&g.offset_x==0&&g.offset_y==0);
 rgba_geometry_release(&api,&g);release_cf(full);
}
static void mapped_client_domain(void){
 fixture(0);struct rgba_geometry g={0};void *full=new_region();rect domain={100,40,720,448};
 *(int *)(d+0x2c)=100;*(int *)(d+0x30)=40;*(float *)(d+0x4c)=896;*(float *)(d+0x68)=2;
 assert(rgba_geometry_setup_region_domain(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g,full,&domain));
 assert(g.scale==2&&g.offset_x==-200&&g.offset_y==80);
 // OWN context already maps client domain to(100,40). Destination offset
 // removes that domain origin exactly once. Both corners cover full1440x896.
 rect pixels=apply_rect(&g.update,domain);
 assert(pixels.x+g.offset_x==0&&pixels.y+g.offset_y==896);
 assert(pixels.w==1440&&pixels.h==-896);
 assert(pixels.x+pixels.w+g.offset_x==1440&&pixels.y+pixels.h+g.offset_y==0);
 rgba_geometry_release(&api,&g);release_cf(full);
}
int main(void){
 client_viewport_translated_source(0);client_viewport_translated_source(1);mapped_client_domain();
 independent_client_domain();
 vector(0);vector(1);independent_vector();native_capture_modes();full_client_viewport();
 fixture(0);struct rgba_geometry g={0};*(void **)(d+0xa0)=&renderer;
 assert(!rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g) && calls==0);
 *(void **)(d+0xa0)=0;*(u32 *)(d+0x50)=0x00400000;
 assert(!rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g) && calls==0);
 *(u32 *)(d+0x50)=0;*(u32 *)(q+0x28)=92;
 assert(!rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&own_update,s,q,d,&g) && calls==0);
 *(u32 *)(q+0x28)=91;
 assert(!rgba_geometry_setup(&p,&api,&shared_renderer,&shared_renderer,&own_update,s,q,d,&g) && calls==0);
 assert(!rgba_geometry_setup(&p,&api,&renderer,&shared_renderer,&normal_update,s,q,d,&g) && calls==0);
 puts("RGBA geometry CPU vectors/region custody/refusal PASS");return 0;
}
