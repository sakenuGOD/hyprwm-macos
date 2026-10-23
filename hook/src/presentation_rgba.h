// Geometry for a private offscreen render of one qualified native composition.
// The caller owns its renderer/Update/texture. No shared renderer or source
// Update is changed here. All entry points remain dormant in ordinary anim_tick.
struct rgba_matrix { double v[16]; };
struct rgba_affine { double a,b,c,d,tx,ty; };
struct rgba_geometry_api {
    struct rgba_matrix (*invert)(const struct rgba_matrix *);
    struct rgba_matrix (*affine)(const struct rgba_affine *);
    rect (*apply_rect)(const struct rgba_matrix *,rect);
    void *(*transform_region)(const struct rgba_matrix *,void *,int);
    void *(*combined_shape)(void *,void *);
    void *(*adopt_shape)(void *);
    void *(*intersection)(void *,void *);
    void *(*region_union)(void *,void *);
    int (*region_empty)(void *);
    void *(*retain_cf)(void *);
    void (*release_cf)(void *);
    void *(*display_rgb)(void);
    void *const *native_display_rgb;
    void (*substitute)(void *,float,float,float,float);
    void (*features)(void *,u32);
    void (*colorspace)(void *,void *);
    void (*update_region)(void *,void *);
    void (*added_contexts)(void *);
    void (*invalidate_backdrops)(void *,void *);
    void (*clip_backdrops)(void *,void *);
    void (*scale)(void *,double);
    void (*accelerator)(void *,u32);
    void (*hdr)(void *,float);
    void (*bit_depth)(void *,u32);
    void (*offset)(void *,int,int);
    void (*display)(void *,void *);
};
struct rgba_geometry {
    struct rgba_matrix update,backdrop,clip;
    void *region; // One caller-owned CF reference through the render.
    double scale;
    int offset_x,offset_y;
    u32 features;
};

static double rgba_floor(double value) {
    double out;__asm__("frintm %d0, %d1":"=w"(out):"w"(value));return out;
}
static int rgba_s32f(float value) {
    int out;__asm__("fcvtzs %w0, %s1":"=r"(out):"w"(value));return out;
}
static int rgba_s32d(double value) {
    int out;__asm__("fcvtzs %w0, %d1":"=r"(out):"w"(value));return out;
}
static u32 rgba_u32f(float value) {
    u32 out;__asm__("fcvtzu %w0, %s1":"=r"(out):"w"(value));return out;
}
static int rgba_neg32(int value) {
    int out;__asm__("neg %w0, %w1":"=r"(out):"r"(value));return out;
}
static float rgba_f32(double value) {
    float out;__asm__("fcvt %s0, %d1":"=w"(out):"w"(value));return out;
}
static double rgba_fmsub(double a,double b,double c) {
    double out;__asm__("fmsub %d0, %d1, %d2, %d3":"=w"(out):"w"(a),"w"(b),"w"(c));return out;
}
static int rgba_geometry_api_ready(const struct rgba_geometry_api *a) {
    return a && a->invert && a->affine && a->apply_rect && a->transform_region &&
        a->combined_shape && a->adopt_shape && a->intersection && a->region_union &&
        a->region_empty && a->retain_cf && a->release_cf && a->display_rgb &&
        a->native_display_rgb && a->substitute && a->features && a->colorspace &&
        a->update_region && a->added_contexts && a->invalidate_backdrops &&
        a->clip_backdrops && a->scale && a->accelerator && a->hdr && a->bit_depth &&
        a->offset && a->display;
}

// S must already belong to the ONE fresh prepared +8 source chain, with an OWN
// destination descriptor. Parent frame code verifies that graph's membership;
// the bindings below additionally reject a stale or foreign descriptor.
static int rgba_geometry_source(struct pc_capture *p,const char *s,const char *q) {
    char *win=pc_source(p);
    if(!win || !s || !q || *(u32 *)(s+0x180)!=10 || *(u32 *)(s+0x268)!=p->wid ||
       *(const char **)(s+0x48)!=q || *(u64 *)q!=p->source ||
       *(u64 *)(q+0x10)!=p->update || *(u64 *)(s+0x28)!=p->update ||
       *(u64 *)(s+0x30)!=p->update || *(void **)(q+8))return 0;
    char *cwc=*(char **)(win+0x18);
    return cwc && *(u32 *)(q+0x28)==*(u32 *)(cwc+0x40);
}

static void rgba_geometry_release(const struct rgba_geometry_api *a,struct rgba_geometry *g) {
    if(g->region){a->release_cf(g->region);g->region=0;}
}

// The private owner must create renderer/update and retain them through GPU
// completion. In particular, own_update MUST have Isolated/HostedContexts set
// before add_context. It must not be the selected normal Update.
static int rgba_geometry_setup_region_domain_owned(struct pc_capture *p,const struct rgba_geometry_api *a,
                              void *renderer,void *shared_renderer,void *own_update,
                              const char *s,const char *q,const char *d,struct rgba_geometry *out,
                              void *full_region,const rect *client_domain,
                              int (*normal_owner)(struct pc_capture *,const void *),const void *scope) {
    if(!pc_main(p) || (normal_owner?!normal_owner(p,scope):!pc_normal_frame(p)) || !rgba_geometry_api_ready(a) || !out || out->region ||
       !renderer || renderer==shared_renderer || !own_update || (u64)own_update==p->update ||
       !d || *(void **)(d+0xa0) ||
       ((*(unsigned short *)(d+0x52)&0x240) && *(u32 *)(d+0x50)!=0x10440000 &&
        *(u32 *)(d+0x50)!=0x14440000) ||
       !rgba_geometry_source(p,s,q))return 0;
    double device_scale=*(float *)(d+0x68);
    if(device_scale==0)device_scale=1;
    float divisor=*(float *)(s+0x18c);
    // The OWN client Update already contains client_mapping. The native WS
    // wrapper matrix/divisor belongs only to rendering that wrapper source.
    if(!client_domain && divisor!=0)device_scale/=divisor;
    // Explicit OWN client-domain override; original native source descriptors,
    // source identity and pc.capture_rect stay unchanged.
    if(client_domain && !full_region)return 0;
    rect source_rect=client_domain?*client_domain:*(const rect *)(s+0xc8);
    if(!__builtin_isfinite(device_scale) || device_scale<=0 ||
       !__builtin_isfinite(source_rect.w) || !__builtin_isfinite(source_rect.h) ||
       source_rect.w<=0 || source_rect.h<=0)return 0;

    void *main_region=0,*extra_region=0;
    void *shape_a=*(void **)(s+0x248),*shape_b=*(void **)(s+0x250);
    void *source_clip=*(void **)(s+0x1a0);
    if(full_region) {
        // A fresh client raster covers the exact capture rectangle, independent
        // of the wrapper's rounded/dirty/opaque source shapes. Its domain is the
        // same redraw rectangle consumed by native generate_layers_for_window.
        main_region=a->retain_cf(full_region);
    } else if(!shape_a && !shape_b) {
        main_region=source_clip;if(main_region)a->retain_cf(main_region);
    } else {
        void *region=a->adopt_shape(a->combined_shape(shape_a,shape_b));
        if(source_clip) {
            main_region=a->intersection(source_clip,region);
            if(region)a->release_cf(region);
        } else main_region=region;
    }
    if(!full_region && *(void **)(s+0x1b0))extra_region=a->region_union(main_region,*(void **)(s+0x1b0));
    void *all_region=extra_region?extra_region:main_region;
    u32 qflags=*(u32 *)(q+0x18);int flip=(qflags&1)!=0;
    struct rgba_matrix matrix=client_domain ?
        (struct rgba_matrix){.v={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}} :
        *(const struct rgba_matrix *)(s+0xf0);
    struct rgba_matrix inverse=a->invert(&matrix);
    float rx=rgba_f32(rgba_floor(inverse.v[12]+0x1p-8));
    float ry=rgba_f32(rgba_floor(inverse.v[13]+0x1p-8));
    int ix=rgba_s32f(rx),iy=rgba_s32f(ry);
    double tx=(double)rgba_neg32(ix);
    int height_y=rgba_s32d(source_rect.h+(double)iy);
    double sign_y=flip?1.0:-1.0,ty=flip?(double)rgba_neg32(height_y):(double)height_y;
    struct rgba_affine aa={1,0,0,sign_y,tx,ty};
    struct rgba_affine ab={device_scale,0,0,sign_y*device_scale,device_scale*tx,device_scale*ty};
    struct rgba_matrix A=a->affine(&aa),B=a->affine(&ab);
    rect untransformed=a->apply_rect(&inverse,source_rect);
    int other_y=rgba_s32d(untransformed.h+(double)iy);if(flip)other_y=rgba_neg32(other_y);
    struct rgba_affine ac={1,0,0,sign_y,tx,(double)other_y};
    struct rgba_matrix C=a->affine(&ac);

    u32 features=((*(u32 *)(d+0x50)>>27)&1)^qflags^1;
    features|=0x00800000; // OWN backdrop substitute branch, premultiplied RGBA0.
    a->substitute(renderer,0,0,0,0);a->features(renderer,features);
    void *owned_color=0,*color=0;
    if(d[0x53]&4)color=*(void **)(d+0x60);
    if(!color) {
        color=*a->native_display_rgb;
        if(!color){owned_color=a->display_rgb();color=owned_color;}
    }
    if(color)a->colorspace(renderer,color);
    if(owned_color)a->release_cf(owned_color);
    u32 filters=*(u32 *)(s+0x218);int empty=a->region_empty(main_region);
    void *backdrop_clip=0;
    if(!full_region && (!main_region || (filters&2)))a->update_region(renderer,0);
    else if(!full_region && (filters&0x200) && (empty&1))a->update_region(renderer,main_region);
    else {
        void *update_region=a->transform_region(&B,main_region,1);
        void *invalid_region=a->transform_region(&C,all_region,1);
        backdrop_clip=a->transform_region(&A,all_region,1);
        a->invalidate_backdrops(own_update,invalid_region);a->update_region(renderer,update_region);
        if(invalid_region)a->release_cf(invalid_region);
        if(update_region)a->release_cf(update_region);
    }
    a->added_contexts(own_update);a->clip_backdrops(own_update,backdrop_clip);
    if(backdrop_clip)a->release_cf(backdrop_clip);
    a->scale(renderer,device_scale);a->accelerator(renderer,*(u32 *)(d+0x70));
    a->hdr(renderer,*(float *)(d+0x78));a->bit_depth(renderer,(unsigned char)d[0x54]);
    if(extra_region)a->release_cf(extra_region);

    float offset_scale=*(float *)(d+0x68);if(offset_scale==0)offset_scale=1;
    inverse=a->invert(&matrix);
    float offset_rx=rgba_f32(rgba_floor(inverse.v[12]+0x1p-8));
    float offset_ry=rgba_f32(rgba_floor(inverse.v[13]+0x1p-8));
    float height_ry=rgba_f32(source_rect.h+(double)offset_ry);
    double origin_x=(double)*(int *)(d+0x2c),origin_y=(double)*(int *)(d+0x30);
    u32 pixel_height=rgba_u32f(*(float *)(d+0x4c));
    float offset_x=rgba_f32(((double)offset_rx-origin_x)*(double)offset_scale);
    float offset_y=rgba_f32(rgba_fmsub((double)offset_scale,(double)height_ry-origin_y,(double)pixel_height));
    int ox=rgba_s32f(offset_x),oy=rgba_s32f(offset_y);
    a->offset(renderer,ox,oy);a->display(renderer,0);
    out->update=B;out->backdrop=C;out->clip=A;out->region=main_region;
    out->scale=device_scale;out->offset_x=ox;out->offset_y=oy;out->features=features;
    return 1;
}
static int rgba_geometry_setup_region_domain(struct pc_capture *p,const struct rgba_geometry_api *a,
                              void *renderer,void *shared_renderer,void *own_update,
                              const char *s,const char *q,const char *d,struct rgba_geometry *out,
                              void *full_region,const rect *client_domain) {
    return rgba_geometry_setup_region_domain_owned(p,a,renderer,shared_renderer,own_update,
        s,q,d,out,full_region,client_domain,0,0);
}
static int rgba_geometry_setup_region(struct pc_capture *p,const struct rgba_geometry_api *a,
                              void *renderer,void *shared_renderer,void *own_update,
                              const char *s,const char *q,const char *d,struct rgba_geometry *out,
                              void *full_region) {
    return rgba_geometry_setup_region_domain(p,a,renderer,shared_renderer,own_update,
        s,q,d,out,full_region,0);
}
static int rgba_geometry_setup(struct pc_capture *p,const struct rgba_geometry_api *a,
                              void *renderer,void *shared_renderer,void *own_update,
                              const char *s,const char *q,const char *d,struct rgba_geometry *out) {
    return rgba_geometry_setup_region(p,a,renderer,shared_renderer,own_update,s,q,d,out,0);
}
