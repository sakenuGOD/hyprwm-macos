// Native edge compositor for SkyLight 25G241. No client configure, screen capture,
// retained foreign layer, external relocation, or implicit global state.
// API pointers are validated/signed by the installer. State owns every resource.
#ifndef HYPR_LIVE_EDGE_H
#define HYPR_LIVE_EDGE_H
#include "edge_geometry.h"
typedef unsigned long long edge_u64;
struct edge_point { double x,y; };
struct edge_transform { double m[16]; };
struct edge_api {
    void *msg;
    void *(*sel)(const char*);
    void *(*cls)(const char*);
    void (*begin)(void*,unsigned);
    void (*add)(void*,void*);
    void (*end)(void*);
    void *(*byid)(unsigned);
    void *(*create)(void*,int,void*,unsigned);
    void *(*region)(struct edge_rect);
    void *(*empty)(void);
    void (*release)(void*);
    void (*bind)(void*,unsigned);
    void (*event_shape)(void*,void*);
    void (*no_shadow)(void*);
    void (*depth)(void*,int);
    void (*has_alpha)(void*,_Bool);
    double (*resolution)(void*);
    void (*set_resolution)(void*,double);
    int (*level)(void*);
    void (*set_level)(void*,void*,int,short); // C++ this, connection, level, sublevel
    void (*title)(void*,void*);
    void (*order)(void*,unsigned,int,unsigned);
    void (*destroy)(void*);
    unsigned (*wid)(void*);
    void (*transform)(void*,unsigned*,unsigned*,double*);
    void (*alpha)(void*,void*,float,float);
    void *(*primary_space)(void*); // PKGSpace*, NOT the numeric public Space ID
    void *(*space_for_id)(edge_u64);
    void *(*window_list)(void*,const unsigned*,unsigned);
    void (*space_move)(void*,void*,void*);
    void (*free_node)(void*);
    void (*damage)(void*,void*);
};
struct edge_state {
    void *window,*context,*root;
    void *clip[3],*host[3];
    void *source_window;
    struct edge_rect base;
    unsigned wid,source_id,context_id,client_id;
    edge_u64 space;
    unsigned ordered,owned;
    void *surface,*main_clip,*main_host,*source_root;
    float source_opacity;
    unsigned source_hidden;
    void *gradient,*gradient_mask,*shadow,*shadow_mask;
    double padding;
};
// Positive1..3 remain the actual number of rendered edge patches.
enum { EDGE_INVALID=0, EDGE_NO_PATCH=4, EDGE_FAILED=-1 };
static void *edge_o0(struct edge_api *a,void *o,const char *s) {
    return ((void*(*)(void*,void*))a->msg)(o,a->sel(s));
}
static void edge_o1(struct edge_api *a,void *o,const char *s,void *p) {
    ((void(*)(void*,void*,void*))a->msg)(o,a->sel(s),p);
}
static void edge_bool(struct edge_api *a,void *o,const char *s,int b) {
    ((void(*)(void*,void*,_Bool))a->msg)(o,a->sel(s),b!=0);
}
static void edge_point(struct edge_api *a,void *o,const char *s,double x,double y) {
    ((void(*)(void*,void*,struct edge_point))a->msg)(o,a->sel(s),(struct edge_point){x,y});
}
static void edge_rect(struct edge_api *a,void *o,const char *s,struct edge_rect r) {
    ((void(*)(void*,void*,struct edge_rect))a->msg)(o,a->sel(s),r);
}
static void *edge_string(struct edge_api *a,const char *s) {
    return ((void*(*)(void*,void*,const char*))a->msg)(a->cls("NSString"),a->sel("stringWithUTF8String:"),s);
}
static void *edge_layer(struct edge_api *a,const char *cls,const char *name) {
    void *p=edge_o0(a,edge_o0(a,a->cls(cls),"alloc"),"init");
    if(p) { edge_o1(a,p,"setName:",edge_string(a,name));edge_point(a,p,"setAnchorPoint:",0,0); }
    return p;
}
static int edge_additive_clip(struct edge_api *a,void *layer) {
    // Complementary mask coverage must add: source-over turns .5 + .5 into .75.
    // Apply only to owned edge patches, never the application's layer tree.
    // CIFilter addition brightens colors but leaves CALayerHost clip alpha at
    // source-over coverage. Native plusL adds premultiplied color AND alpha.
    void *cls=a->cls("CAFilter");if(!cls)return 0;
    if(!((unsigned char(*)(void*,void*,void*))a->msg)(cls,a->sel("respondsToSelector:"),a->sel("filterWithType:")))return 0;
    void *filter=((void*(*)(void*,void*,void*))a->msg)(cls,a->sel("filterWithType:"),
        edge_string(a,"plusL"));
    if(!filter)return 0;
    edge_o1(a,layer,"setCompositingFilter:",filter);
    return 1;
}
static void edge_begin(struct edge_api *a,struct edge_state *s,edge_u64 tx[4]) {
    a->begin(tx,1);a->add(tx,s->context);
    void *cwc=s->window?*(void**)((char*)s->window+0x18):0;
    if(cwc) a->add(tx,*(void**)((char*)cwc+0x38));
    void *source=a->byid(s->source_id);
    if(source && source==s->source_window) {
        void *sc=*(void**)((char*)source+0x18);
        if(sc)a->add(tx,*(void**)((char*)sc+0x38));
    }
}
static void edge_commit(struct edge_api *a,edge_u64 tx[4]) {
    a->end(tx);edge_o0(a,a->cls("CATransaction"),"flush");
}
static int edge_remove(struct edge_api *a,struct edge_state *s) {
    if (s->window && (a->byid(s->wid)!=s->window || !s->owned ||
                     *(void**)((char*)s->window+0x30))) return -1;
    if(s->window) a->order(0,s->wid,0,0);
    if(s->context) {
        edge_u64 tx[4]={0};edge_begin(a,s,tx);
        void *source=a->byid(s->source_id);
        void *sc=source && source==s->source_window?*(void**)((char*)source+0x18):0;
        void *root=sc?*(void**)((char*)sc+0x80):0;
        if(s->source_hidden && root && root==s->source_root &&
           ((float(*)(void*,void*))a->msg)(root,a->sel("opacity"))==0)
            ((void(*)(void*,void*,float))a->msg)(root,a->sel("setOpacity:"),s->source_opacity);
        if(s->main_host) {
            ((void(*)(void*,void*,unsigned))a->msg)(s->main_host,a->sel("setContextId:"),0);
            edge_o0(a,s->main_host,"removeFromSuperlayer");
        }
        for(int i=0;i<3;i++) if(s->host[i]) {
            ((void(*)(void*,void*,unsigned))a->msg)(s->host[i],a->sel("setContextId:"),0);
            edge_o0(a,s->host[i],"removeFromSuperlayer");
        }
        edge_commit(a,tx);
    }
    if(s->window) { a->destroy(s->window);s->window=0;if(a->byid(s->wid))return -2; }
    if(s->context) { edge_o1(a,s->context,"setLayer:",0);edge_o0(a,s->context,"invalidate"); }
    for(int i=0;i<3;i++) {
        if(s->host[i])edge_o0(a,s->host[i],"release");
        if(s->clip[i])edge_o0(a,s->clip[i],"release");
    }
    if(s->main_host)edge_o0(a,s->main_host,"release");
    if(s->main_clip)edge_o0(a,s->main_clip,"release");
    if(s->surface)edge_o0(a,s->surface,"release");
    if(s->gradient)edge_o0(a,s->gradient,"release");
    if(s->gradient_mask)edge_o0(a,s->gradient_mask,"release");
    if(s->shadow)edge_o0(a,s->shadow,"release");
    if(s->shadow_mask)edge_o0(a,s->shadow_mask,"release");
    if(s->root)edge_o0(a,s->root,"release");
    if(s->context)edge_o0(a,s->context,"release");
    volatile unsigned char *p=(volatile unsigned char*)s;
    for(unsigned i=0;i<sizeof(*s);i++)p[i]=0;
    return 1;
}
static int edge_create(struct edge_api *a,struct edge_state *s,void *source,unsigned source_id,struct edge_rect b,int full) {
    if(s->window||s->context||!source||a->byid(source_id)!=source)return 0;
    s->padding=full?64:0;
    b.x-=s->padding;b.y-=s->padding;b.w+=2*s->padding;b.h+=2*s->padding;
    s->source_window=source;s->source_id=source_id;s->base=b;
    void *options=edge_o0(a,a->cls("NSDictionary"),"dictionary");
    s->context=((void*(*)(void*,void*,void*))a->msg)(a->cls("CAContext"),a->sel("localContextWithOptions:"),options);
    if(!s->context)return 0;
    edge_o0(a,s->context,"retain");
    s->context_id=((unsigned(*)(void*,void*))a->msg)(s->context,a->sel("contextId"));
    s->root=edge_layer(a,"CALayer","hyprwm.live-edge.root");if(!s->root)goto fail;
    edge_rect(a,s->root,"setBounds:",(struct edge_rect){0,0,b.w,b.h});
    edge_point(a,s->root,"setPosition:",0,0);edge_bool(a,s->root,"setMasksToBounds:",1);
    edge_o1(a,s->context,"setLayer:",s->root);
    s->surface=edge_layer(a,"CALayer","hyprwm.live-edge.surface");if(!s->surface)goto fail;
    edge_point(a,s->surface,"setPosition:",0,0);edge_bool(a,s->surface,"setMasksToBounds:",1);
    edge_o1(a,s->root,"addSublayer:",s->surface);
    s->main_clip=edge_layer(a,"CALayer","hyprwm.live-edge.content-clip");
    s->main_host=edge_layer(a,"CALayerHost","hyprwm.live-edge.content");
    if(!s->main_clip||!s->main_host)goto fail;
    edge_bool(a,s->main_clip,"setMasksToBounds:",1);edge_bool(a,s->main_clip,"setHidden:",1);
    edge_o1(a,s->main_clip,"addSublayer:",s->main_host);edge_o1(a,s->surface,"addSublayer:",s->main_clip);
    for(int i=0;i<3;i++) {
        s->clip[i]=edge_layer(a,"CALayer","hyprwm.live-edge.clip");
        s->host[i]=edge_layer(a,"CALayerHost","hyprwm.live-edge.host");
        if(!s->clip[i]||!s->host[i]||!edge_additive_clip(a,s->clip[i]))goto fail;
        edge_bool(a,s->clip[i],"setMasksToBounds:",1);
        edge_o1(a,s->clip[i],"addSublayer:",s->host[i]);edge_o1(a,s->surface,"addSublayer:",s->clip[i]);
    }
    void *r=a->region(b);if(!r)goto fail;
    s->window=a->create(0,5,r,0x3800);a->release(r);if(!s->window)goto fail;
    s->wid=a->wid(s->window);
    if(!s->wid||a->byid(s->wid)!=s->window||s->window==source||*(void**)((char*)s->window+0x30))return -1;
    // This mark is restricted to the allocation just returned by WSWindowCreate.
    *(edge_u64*)((char*)s->window+0x928)|=(edge_u64)1<<54;s->owned=1;
    a->title(s->window,edge_string(a,"hyprwm.owned.live-edge"));
    a->has_alpha(s->window,1);a->depth(s->window,4);a->no_shadow(s->window);
    a->set_resolution(s->window,a->resolution(source));
    r=a->empty();if(!r)goto fail;a->event_shape(s->window,r);a->release(r);
    a->bind(s->window,s->context_id);
    void *own=*(void**)((char*)s->window+0x18);
    if(!own||*(unsigned*)((char*)own+0x50)!=s->context_id)goto fail;
    a->set_level(s->window,0,a->level(source),0);
    return 1;
fail:
    edge_remove(a,s);return 0;
}
// Uses the existing stable native helper shape and its compositor transform.
// Neither the application nor the helper receives a per-frame native resize.
static int edge_update(struct edge_api *a,struct edge_state *s,unsigned source_id,
                       double aw,double ah,struct edge_rect b,double alpha,unsigned transform_key,
                       int full,double radius) {
    void *source=a->byid(source_id);
    struct edge_patch patches[3];
    int n=edge_layout_aligned(aw,ah,b,source?a->resolution(source):1,patches);
    if(n<0||alpha<=0||alpha-alpha!=0||b.x!=b.x||b.y!=b.y||b.x>100000||b.x< -100000||
       b.y>100000||b.y< -100000||!source|| (s->source_window&&s->source_window!=source) ||
       !(*(edge_u64*)((char*)source+0x928)&((edge_u64)1<<44))) {
        edge_remove(a,s);return 0;
    }
    void *cwc=*(void**)((char*)source+0x18), *source_host=cwc?*(void**)((char*)cwc+0x60):0;
    if(!source_host) { edge_remove(a,s);return 0; }
    if(!((unsigned char(*)(void*,void*,void*))a->msg)(source_host,a->sel("respondsToSelector:"),a->sel("contextId"))) {
        edge_remove(a,s);return 0;
    }
    unsigned client=((unsigned(*)(void*,void*))a->msg)(source_host,a->sel("contextId"));
    if(!client) { edge_remove(a,s);return 0; }
    void *source_root=*(void**)((char*)cwc+0x80);
    if(full&&!source_root) { edge_remove(a,s);return 0; }
    if(s->client_id && s->client_id!=client) { edge_remove(a,s);return EDGE_INVALID; }
    // No extension is different from a rejected source/helper. The caller may
    // retain its original grant only after rechecking that exact lease/source.
    // edge_remove deliberately clears visual state, including source_window.
    if(n==0) return edge_remove(a,s)==1 ? EDGE_NO_PATCH : EDGE_FAILED;
    if(s->window && s->padding!=(full?64:0))edge_remove(a,s);
    if(!s->window && edge_create(a,s,source,source_id,b,full)!=1)return -1;
    if(a->primary_space && a->space_for_id && a->window_list && a->space_move && a->free_node) {
        void *sp=a->primary_space(source);
        edge_u64 space=sp?*(edge_u64*)sp:0;
        if(space && space!=s->space) {
            if(a->space_for_id(space)!=sp) { edge_remove(a,s);return 0; }
            void *managed=*(void**)((char*)sp+0x18);
            if(!managed) { edge_remove(a,s);return 0; }
            void *list=a->window_list(0,&s->wid,1);a->space_move(0,list,managed);
            while(list) { void *next=*(void**)((char*)list+8);a->free_node(list);list=next; }
            s->space=space;
        }
    }
    double pad=s->padding,kx=s->base.w/(b.w+2*pad),ky=s->base.h/(b.h+2*pad);
    float source_opacity=source_root?((float(*)(void*,void*))a->msg)(source_root,a->sel("opacity")):1;
    int hide_source=full && source_root &&
        (!s->source_hidden || s->source_root!=source_root || source_opacity!=0);
    if(hide_source) {
        s->source_root=source_root;
        s->source_opacity=source_opacity;
    }
    edge_u64 tx[4]={0};edge_begin(a,s,tx);
    // Server root already carries native window alpha. The helper applies that
    // alpha once through WS; preserve only any additional source paint factor.
    double paint=full?s->source_opacity/alpha:1;
    if(paint>1)paint=1;if(paint<0)paint=0;
    ((void(*)(void*,void*,float))a->msg)(s->root,a->sel("setOpacity:"),(float)paint);
    edge_rect(a,s->surface,"setBounds:",(struct edge_rect){0,0,b.w,b.h});
    edge_point(a,s->surface,"setPosition:",pad,pad);
    struct edge_transform scale={{kx,0,0,0,0,ky,0,0,0,0,1,0,0,0,0,1}};
    ((void(*)(void*,void*,struct edge_transform))a->msg)(s->root,a->sel("setSublayerTransform:"),scale);
    ((void(*)(void*,void*,double))a->msg)(s->surface,a->sel("setCornerRadius:"),radius>0?radius:0);
    if(full && source_root) {
        double cw=patches[0].clip.w>0?patches[0].clip.x:edge_min(aw,b.w);
        double ch=patches[1].clip.h>0?patches[1].clip.y:edge_min(ah,b.h);
        edge_bool(a,s->main_clip,"setHidden:",0);
        edge_rect(a,s->main_clip,"setBounds:",(struct edge_rect){0,0,cw,ch});
        edge_point(a,s->main_clip,"setPosition:",0,b.h-ch);
        edge_rect(a,s->main_host,"setBounds:",(struct edge_rect){0,0,aw,ah});
        ((void(*)(void*,void*,unsigned))a->msg)(s->main_host,a->sel("setContextId:"),client);
        edge_point(a,s->main_host,"setPosition:",0,ch-ah);
    }
    for(int i=0;i<3;i++) {
        struct edge_rect r=patches[i].clip,q=patches[i].sample;
        int on=r.w>0&&r.h>0;edge_bool(a,s->clip[i],"setHidden:",!on);if(!on)continue;
        edge_rect(a,s->clip[i],"setBounds:",(struct edge_rect){0,0,r.w,r.h});
        edge_point(a,s->clip[i],"setPosition:",r.x,b.h-r.y-r.h);
        edge_rect(a,s->host[i],"setBounds:",(struct edge_rect){0,0,aw,ah});
        ((void(*)(void*,void*,unsigned))a->msg)(s->host[i],a->sel("setContextId:"),client);
        double sx=r.w/q.w,sy=r.h/q.h;
        struct edge_transform t={{sx,0,0,0,0,sy,0,0,0,0,1,0,0,0,0,1}};
        ((void(*)(void*,void*,struct edge_transform))a->msg)(s->host[i],a->sel("setTransform:"),t);
        edge_point(a,s->host[i],"setPosition:",-q.x*sx,-(ah-q.y-q.h)*sy);
    }
    s->client_id=client;edge_commit(a,tx);
    double m[16]={kx,0,0,0,0,ky,0,0,0,0,1,0,(s->base.x-b.x+pad)*kx,(s->base.y-b.y+pad)*ky,0,1};
    a->transform(0,&s->wid,&transform_key,m);
    a->alpha(0,s->window,(float)(alpha>1?1:alpha),0);
    a->order(0,s->wid,-1,source_id);s->ordered=1;
    if(hide_source) {
        // Hide only server-side paint. Native window alpha, key status, input
        // region and the client's live CA context stay untouched.
        edge_u64 stx[4]={0};edge_begin(a,s,stx);
        ((void(*)(void*,void*,float))a->msg)(source_root,a->sel("setOpacity:"),0);
        s->source_hidden=1;edge_commit(a,stx);
        if(a->damage)a->damage(0,source);
    }
    if(a->damage)a->damage(0,s->window);
    return n;
}
static void edge_copy_double(struct edge_api *a,void *dst,void *src,const char *get,const char *set) {
    double v=((double(*)(void*,void*))a->msg)(src,a->sel(get));
    ((void(*)(void*,void*,double))a->msg)(dst,a->sel(set),v);
}
static void edge_copy_float(struct edge_api *a,void *dst,void *src,const char *get,const char *set) {
    float v=((float(*)(void*,void*))a->msg)(src,a->sel(get));
    ((void(*)(void*,void*,float))a->msg)(dst,a->sel(set),v);
}
static void edge_copy_point(struct edge_api *a,void *dst,void *src,const char *get,const char *set) {
    struct edge_point v=((struct edge_point(*)(void*,void*))a->msg)(src,a->sel(get));
    edge_point(a,dst,set,v.x,v.y);
}
static void edge_copy_ring(struct edge_api *a,void *dst,void *src,struct edge_rect frame) {
    edge_rect(a,dst,"setFrame:",frame);
    edge_copy_double(a,dst,src,"borderWidth","setBorderWidth:");
    edge_copy_double(a,dst,src,"cornerRadius","setCornerRadius:");
    edge_o1(a,dst,"setCornerCurve:",edge_o0(a,src,"cornerCurve"));
    edge_o1(a,dst,"setBorderColor:",edge_o0(a,src,"borderColor"));
}
// Mirror the accepted decoration's current presentation, using our own layers
// and masks. Never share/move a source mask or replace its animation settings.
static void edge_decorate(struct edge_api *a,struct edge_state *s,void *ring,void *shadow,
                          double bw,double bh,double outset) {
    if(!s->window||!s->source_hidden)return;
    if(!ring) {
        if(!s->gradient&&!s->shadow)return;
        edge_u64 tx[4]={0};edge_begin(a,s,tx);
        if(s->gradient)edge_bool(a,s->gradient,"setHidden:",1);
        if(s->shadow)edge_bool(a,s->shadow,"setHidden:",1);
        edge_commit(a,tx);if(a->damage)a->damage(0,s->window);
        return;
    }
    edge_u64 tx[4]={0};edge_begin(a,s,tx);
    if(!s->gradient) {
        s->gradient=edge_layer(a,"CAGradientLayer","hyprwm.live-edge.border");
        s->gradient_mask=edge_layer(a,"CALayer","hyprwm.live-edge.border-mask");
        edge_o1(a,s->gradient,"setMask:",s->gradient_mask);edge_o1(a,s->root,"addSublayer:",s->gradient);
    }
    edge_bool(a,s->gradient,"setHidden:",0);
    struct edge_rect fr={s->padding-outset,s->padding-outset,bw+2*outset,bh+2*outset};
    edge_rect(a,s->gradient,"setFrame:",fr);
    void *mask=edge_o0(a,ring,"mask"),*p=edge_o0(a,ring,"presentationLayer");
    if(mask) {
        edge_copy_ring(a,s->gradient_mask,mask,(struct edge_rect){0,0,fr.w,fr.h});
        edge_o1(a,s->surface,"setCornerCurve:",edge_o0(a,mask,"cornerCurve"));
    }
    edge_o1(a,s->gradient,"setColors:",edge_o0(a,p?p:ring,"colors"));
    edge_copy_point(a,s->gradient,ring,"startPoint","setStartPoint:");
    edge_copy_point(a,s->gradient,ring,"endPoint","setEndPoint:");
    if(shadow) {
        if(!s->shadow) {
            s->shadow=edge_layer(a,"CALayer","hyprwm.live-edge.shadow");
            s->shadow_mask=edge_layer(a,"CALayer","hyprwm.live-edge.shadow-mask");
            edge_o1(a,s->shadow,"setMask:",s->shadow_mask);
            ((void(*)(void*,void*,void*,unsigned))a->msg)(s->root,a->sel("insertSublayer:atIndex:"),s->shadow,0);
        }
        edge_bool(a,s->shadow,"setHidden:",0);
        edge_rect(a,s->shadow,"setFrame:",fr);
        edge_o1(a,s->shadow,"setShadowPath:",edge_o0(a,shadow,"shadowPath"));
        edge_o1(a,s->shadow,"setShadowColor:",edge_o0(a,shadow,"shadowColor"));
        edge_copy_double(a,s->shadow,shadow,"shadowRadius","setShadowRadius:");
        edge_copy_point(a,s->shadow,shadow,"shadowOffset","setShadowOffset:");
        p=edge_o0(a,shadow,"presentationLayer");edge_copy_float(a,s->shadow,p?p:shadow,"shadowOpacity","setShadowOpacity:");
        mask=edge_o0(a,shadow,"mask");
        if(mask)edge_copy_ring(a,s->shadow_mask,mask,(struct edge_rect){-64,-64,fr.w+128,fr.h+128});
    } else if(s->shadow)edge_bool(a,s->shadow,"setHidden:",1);
    edge_commit(a,tx);if(a->damage)a->damage(0,s->window);
}
#endif
