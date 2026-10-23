// A separate renderer/queue/texture for ONE explicitly qualified native source.
// Ordinary cache capture and production presentation never select this path.
// Borrowed source/destination graph pointers never escape the frame callback.
#define RGBA_MAGIC 0x31414247524d5748ULL
#define RGBA_VERSION 5
#define RGBA_CLIENT_DOMAIN_MODE 3
struct rgba_client_domain {
    rect bounds,mapped;
    u64 pixel_width,pixel_height;
    u32 client_id,commit_sequence,selected,gpu_complete;
};
struct rgba_metal_state {void *cb,*encoder;u32 flags,pad;void *callback,*owner;};
_Static_assert(sizeof(struct rgba_metal_state)==0x28,"QC Metal state ABI");
struct rgba_render_api {
    struct rgba_geometry_api geometry;
    void *const *callbacks;
    void *(*new_renderer)(const void *,void *,void *,u32);
    void (*destroy_renderer)(void *);
    void *(*destination)(void *,void *,rect,float,void *,u32);
    void (*release_destination)(void *);
    void *(*prepare_layers)(void *,void *,void *,void **);
    void *(*empty_shape)(void);
    void (*free_shape)(void *,void *);
    void (*textures)(void *,void **,u32,int);
    void (*render_options)(void *,void *,u32);
    void (*get_state)(void *,struct rgba_metal_state *);
    void (*set_state)(void *,struct rgba_metal_state *);
    void (*flush)(void *,int);
    void *(*begin_update)(void *,u64,const void *,double,u32,u32,const rect *,u32);
    void (*finish_update)(void *);
    void (*isolated)(void *,int);
    void (*hosted)(void *,int);
    void (*skip_backdrops)(void *,int);
    void (*use_skylight_attributes)(void *,int);
    void (*attributes_from_state)(void *,const void *);
    void (*attributes)(void *,const void *);
    void (*vbl_time)(void *,double);
    void (*interval)(void *,double);
    void (*displays)(void *,void **,int);
    u64 (*get_protection)(void *);
    void (*protection)(void *,u64);
    u32 (*get_flags)(void *);
    void (*add_flags)(void *,u32);
    double (*get_time)(void *);
    void (*greedy)(void *,int);
    void (*ignore_flatten_cache)(void *,int);
    void (*flatten_backdrops)(void *,int);
    void (*create_flatten_surface)(void *,int);
    int (*lock_context)(void *);
    int (*unlock_context)(void *);
    void *(*root)(void *);
    void *(*assign_root)(void **,void *);
    void (*add_context)(void *,void *,void *,const void *);
};
struct rgba_selectors {
    void *texture_2d,*storage,*usage,*hazards,*new_texture;
    void *command_buffer,*pass_descriptor,*attachments,*attachment_at;
    void *attachment_texture,*load,*store,*clear,*render_encoder,*end,*commit,*device,*read_bytes;
};
struct rgba_capture {
    struct pc_capture pc; // Keep the 720-byte/version1 capture ABI unchanged.
    u64 magic;u32 size,version;
    struct rgba_render_api api;
    struct rgba_selectors sel;
    void *texture_class,*pass_class;
    void *renderer,*metal,*queue,*device,*clear_buffer,*update,*root;
    u64 shared_renderer,shared_metal,shared_queue;
    u32 clear_status,clear_submitted,render_called,sealed;
    u32 normal_wrapper_sequence,own_wrapper_sequence,own_client_sequence,inclusion;
    u32 original_nodes,prepared_nodes,selected_type,destination_flags;
    u32 last_own_status,destroyed,command_buffer_bound,source_flags;
    double encode_us;
    void *readback;
    u64 readback_capacity,readback_bytes,readback_stride;
    u32 readback_count,readback_error;
    struct rgba_client_api client_api;
    u32 content_mode,client_nodes,client_reason,cohort_contexts;
    struct rgba_matrix client_mapping;
    struct rgba_model_control *model;
    struct rgba_client_domain domain;
    void *locked_client;
    u32 quarantined,lock_pad;
};
_Static_assert(__builtin_offsetof(struct rgba_capture,pc)==0,"capture prefix ABI");
_Static_assert(__builtin_offsetof(struct rgba_capture,magic)==720,"capture prefix extent");
_Static_assert(sizeof(struct rgba_capture)<=RGBA_MODEL_OFFSET,"capture/model partition");
_Static_assert(RGBA_MODEL_OFFSET+sizeof(struct rgba_model_control)<=4096,"model/view partition");

static int rgba_valid(struct rgba_capture *g) {
    return g && g->magic==RGBA_MAGIC && g->size==sizeof(*g) && g->version==RGBA_VERSION &&
        g->pc.magic==PC_MAGIC && g->pc.size==sizeof(g->pc) && g->pc.version==1 && g->content_mode<=RGBA_CLIENT_DOMAIN_MODE &&
        (g->content_mode!=2 || g->model==(void *)((char *)g+RGBA_MODEL_OFFSET));
}
static int rgba_api_ready(const struct rgba_render_api *a) {
    return rgba_geometry_api_ready(&a->geometry) && a->callbacks && *a->callbacks &&
        a->new_renderer && a->destroy_renderer && a->destination && a->release_destination &&
        a->prepare_layers && a->empty_shape && a->free_shape && a->textures &&
        a->render_options && a->get_state && a->set_state && a->flush &&
        a->begin_update && a->finish_update && a->isolated && a->hosted &&
        a->skip_backdrops && a->use_skylight_attributes && a->attributes_from_state &&
        a->attributes && a->vbl_time && a->interval && a->displays &&
        a->get_protection && a->protection && a->get_flags && a->add_flags &&
        a->get_time && a->greedy && a->ignore_flatten_cache && a->flatten_backdrops && a->create_flatten_surface &&
        a->lock_context && a->unlock_context && a->root && a->assign_root &&
        a->add_context;
}
static void *rgba_send0(struct rgba_capture *g,void *object,void *sel) {
    return ((void *(*)(void *,void *))g->pc.engine->msg)(object,sel);
}
static void rgba_set_u64(struct rgba_capture *g,void *object,void *sel,u64 value) {
    ((void (*)(void *,void *,u64))g->pc.engine->msg)(object,sel,value);
}
static int rgba_prepare_selectors(struct rgba_capture *g) {
    struct ctx *c=g->pc.engine;
#define RGSEL(field,name) g->sel.field=c->sel(name)
    RGSEL(texture_2d,"texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
    RGSEL(storage,"setStorageMode:");RGSEL(usage,"setUsage:");RGSEL(hazards,"setHazardTrackingMode:");
    RGSEL(new_texture,"newTextureWithDescriptor:");RGSEL(command_buffer,"commandBuffer");
    RGSEL(pass_descriptor,"renderPassDescriptor");RGSEL(attachments,"colorAttachments");
    RGSEL(attachment_at,"objectAtIndexedSubscript:");RGSEL(attachment_texture,"setTexture:");
    RGSEL(load,"setLoadAction:");RGSEL(store,"setStoreAction:");RGSEL(clear,"setClearColor:");
    RGSEL(render_encoder,"renderCommandEncoderWithDescriptor:");RGSEL(end,"endEncoding");RGSEL(commit,"commit");
    RGSEL(device,"device");RGSEL(read_bytes,"getBytes:bytesPerRow:fromRegion:mipmapLevel:");
#undef RGSEL
    g->texture_class=c->cls("MTLTextureDescriptor");g->pass_class=c->cls("MTLRenderPassDescriptor");
    if(!g->texture_class || !g->pass_class){g->pc.reason=201;g->pc.stage=PC_INVALID;return 0;}
    return 1;
}

int anim_rgba_prepare(struct rgba_capture *g) {
    if(!rgba_valid(g) || !rgba_api_ready(&g->api) || g->renderer || g->destroyed ||
       g->content_mode>RGBA_CLIENT_DOMAIN_MODE || (g->content_mode==1 && !rgba_client_api_ready(&g->client_api)) ||
       (g->content_mode==RGBA_CLIENT_DOMAIN_MODE && !g->client_api.transform_set) ||
       (g->content_mode==2 && (!rgba_model_control_valid(g->model) || !rgba_model_api_ready(&g->model->api))) ||
       !anim_cache_prepare(&g->pc))return 0;
    return rgba_prepare_selectors(g);
}

// This native PKGDisplay virtual ABI is pinned together with the source state.
// Keep address-diverse vtable authentication; stripped pointers are never called.
static void *rgba_display_interface(void *display) {
    if(!display)return 0;
    void **vtable=*(void ***)display;
#if __has_feature(ptrauth_calls)
    vtable=__builtin_ptrauth_auth(vtable,2,__builtin_ptrauth_blend_discriminator(display,0xc333));
    void *fn=__builtin_ptrauth_auth_and_resign(vtable[0x5c0/8],0,
        __builtin_ptrauth_blend_discriminator(&vtable[0x5c0/8],0x3c32),0,0);
#else
    void *fn=vtable[0x5c0/8];
#endif
    return ((void *(*)(void *))fn)(display);
}
static int rgba_included(void *update,void *context,u32 *sequence) {
    if(!update || !context || !sequence)return 0;
    char *seen[256],*entry=*(char **)((char *)update+0x140);unsigned count=0,found=0;
    for(;entry && count<256;entry=*(char **)entry) {
        for(unsigned i=0;i<count;i++)if(seen[i]==entry)return 0;
        seen[count++]=entry;
        if(*(void **)(entry+8)==context){*sequence=*(u32 *)(entry+0x18);found++;}
    }
    return !entry && found==1;
}
static int rgba_client_cohort(struct rgba_capture *g) {
    char *entry=*(char **)((char *)g->update+0x140),*seen[256];unsigned count=0;
    for(;entry && count<256;entry=*(char **)entry) {
        for(unsigned i=0;i<count;i++)if(seen[i]==entry)return 0;
        seen[count++]=entry;void *context=*(void **)(entry+8);u32 sequence=0;
        // Every nested hosted producer must belong to the same normal cohort.
        if(!context || !rgba_included((void *)g->pc.update,context,&sequence) ||
           sequence!=*(u32 *)(entry+0x18))return 0;
        for(unsigned i=0;i+1<count;i++)if(*(void **)(seen[i]+8)==context)return 0;
    }
    g->cohort_contexts=count;return !entry && count>0;
}
// Called ONLY under the exact retained client Render::ContextLock, after
// included-commit validation. No borrowed model/node pointer escapes.
static int rgba_client_domain_select(struct rgba_capture *g,const char *root) {
    struct rgba_client_domain d={0};
    if(!g || !root || g->domain.selected || !g->api.geometry.apply_rect ||
       (g->content_mode!=RGBA_CLIENT_DOMAIN_MODE && g->pc.baked_alpha!=1) || !g->pc.client_included ||
       !__builtin_isfinite(g->pc.scale) || g->pc.scale<=0 || g->pc.scale>8)return 0;
    d.bounds=*(const rect *)(root+0x48);
    const struct rgba_matrix *m=&g->client_mapping;
    // This first domain contract admits pixel-preserving planar placement.
    // Rotated/sheared/scaled scenes need an explicit raster-domain policy.
    if((m->v[0]!=1 && m->v[0]!=-1) || (m->v[5]!=1 && m->v[5]!=-1) ||
       m->v[1]!=0 || m->v[4]!=0)return 0;
    if(!__builtin_isfinite(d.bounds.x) || !__builtin_isfinite(d.bounds.y) ||
       !__builtin_isfinite(d.bounds.w) || !__builtin_isfinite(d.bounds.h) ||
       d.bounds.w<=0 || d.bounds.h<=0)return 0;
    d.mapped=g->api.geometry.apply_rect(m,d.bounds);
    if(!__builtin_isfinite(d.mapped.x) || !__builtin_isfinite(d.mapped.y) ||
       !__builtin_isfinite(d.mapped.w) || !__builtin_isfinite(d.mapped.h) ||
       d.mapped.x< -100000 || d.mapped.x>100000 ||
       d.mapped.y< -100000 || d.mapped.y>100000 ||
       d.mapped.w!=d.bounds.w || d.mapped.h!=d.bounds.h)return 0;
    double w=d.mapped.w*g->pc.scale,h=d.mapped.h*g->pc.scale;
    if(w<1 || h<1 || w>16384 || h>16384 || w*h>8388608 ||
       (double)(u64)w!=w || (double)(u64)h!=h)return 0;
    d.pixel_width=(u64)w;d.pixel_height=(u64)h;
    d.client_id=g->pc.client_id;d.commit_sequence=g->pc.client_commit_sequence;
    d.selected=1;g->domain=d;return 1;
}
// Resource-ready candidate, not a full-domain pixel-coverage witness. Native
// domain/coordinate qualification is additionally required before production
// promotion. A selected/encoded candidate cannot replace last-good.
static int rgba_client_domain_ready(const struct rgba_capture *g) {
    return rgba_valid((struct rgba_capture *)g) && !g->destroyed && !g->pc.dead &&
        g->content_mode==RGBA_CLIENT_DOMAIN_MODE && g->pc.texture_ref && g->pc.command_buffer &&
        g->pc.format==80 && g->clear_status==4 && g->pc.gpu_status==4 &&
        g->pc.source_unchanged && g->pc.present_unchanged && g->inclusion &&
        g->domain.selected && g->domain.gpu_complete && g->pc.stage==PC_GPU_COMPLETE &&
        !g->pc.reason && !g->pc.gpu_pending && g->pc.capture_witness &&
        g->pc.width==g->domain.pixel_width && g->pc.height==g->domain.pixel_height &&
        g->domain.client_id==g->pc.client_id &&
        g->domain.commit_sequence==g->pc.client_commit_sequence;
}
// Mode3 is a client-local raster, independent of the normal Update's posed
// root node (which native optimization may remove). This retains the actual
// current root under its ContextLock and still requires the exact normal cohort.
static int rgba_add_client_local(struct rgba_capture *g,char *cwc,void *normal,void *u) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    void *client=(void *)p->client_context;u32 sequence=0;int result=0;
    g->client_nodes=0;g->client_reason=222;
    if(!client || !p->client_id || client!=*(void **)(cwc+0x48) ||
       p->client_id!=*(u32 *)(cwc+0x50) || g->root || g->domain.selected ||
       !g->client_api.transform_set || g->locked_client || a->lock_context(client)!=0)return 0;
    g->locked_client=client;
    g->client_reason=231;
    if(!p->client_included || !rgba_included(normal,client,&sequence))goto done;
    g->client_reason=235;
    if(sequence!=p->client_commit_sequence || *(u32 *)((char *)client+0x40)!=sequence)goto done;
    void *root=a->root(client);g->client_reason=230;if(!root)goto done;
    // getRootLayer resolves the Context's native root Handle under this lock.
    // No normal prepared-node presence, cache+28 or application-global identity.
    char *h=*(char **)((char *)root+0x98);g->client_reason=236;
    if(!h || !*(u64 *)((char *)client+0x110) ||
       *(void **)((char *)client+0x118)!=h || *(void **)(h+0x18)!=client ||
       *(void **)(h+0x10)!=root)goto done;
    a->assign_root(&g->root,root);if(g->root!=root)goto done;
    // Native destination origins are integer points. Do not silently truncate
    // an unsupported fractional local origin into a shifted client canvas.
    rect bounds=*(const rect *)((char *)root+0x48);g->client_reason=237;
    if(!__builtin_isfinite(bounds.x) || !__builtin_isfinite(bounds.y) ||
       bounds.x< -100000 || bounds.x>100000 || bounds.y< -100000 || bounds.y>100000 ||
       (double)(long long)bounds.x!=bounds.x || (double)(long long)bounds.y!=bounds.y)goto done;
    g->client_mapping=(struct rgba_matrix){.v={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}};
    g->client_reason=234;if(!rgba_client_domain_select(g,root))goto done;
    _Alignas(16) unsigned char transform[0x98]={0};
    g->client_api.transform_set(transform,&g->client_mapping,1);
    a->add_context(u,client,g->root,transform);
    g->client_reason=235;
    if(*(u32 *)((char *)client+0x40)!=sequence || a->root(client)!=root ||
       *(void **)((char *)root+0x98)!=h || *(void **)(h+0x10)!=root)goto done;
    result=1;g->client_reason=0;
done:
    g->locked_client=0;a->unlock_context(client);return result;
}
static int rgba_add_client(struct rgba_capture *g,char *cwc,void *normal,void *u) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    void *wrapper=(void *)p->context,*client=(void *)p->client_context,*wrapper_root=0;
    int result=0;g->client_reason=221;g->client_nodes=0;
    // Auxiliary native hosts need their actual inherited clipping. The copied
    // host-tree route will provide it; this primary-root qualifier must not
    // publish a partial capture as the complete window.
    if(*(void **)(cwc+0x70) || *(void **)(cwc+0x78) ||
       *(u32 *)(cwc+0x150) || *(u32 *)(cwc+0x154))return 0;
    if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE)return rgba_add_client_local(g,cwc,normal,u);
    g->client_reason=222;
    if(!client || client!=*(void **)(cwc+0x48) || p->client_id!=*(u32 *)(cwc+0x50) ||
       a->lock_context(wrapper)!=0)return 0;
    void *root=a->root(wrapper);if(root)a->assign_root(&wrapper_root,root);
    a->unlock_context(wrapper);
    if(!wrapper_root)return 0;
    if(a->lock_context(client)!=0)goto done;
    root=a->root(client);if(root)a->assign_root(&g->root,root);
    g->client_reason=230; // No retained client root.
    if(g->root) {
        void *node=rgba_client_node_scan(normal,wrapper_root,g->root,&g->client_nodes,&g->client_reason);
        u32 sequence=0;
        if(node) {
            g->client_reason=231; // Included list is malformed, absent or ambiguous.
            if(!rgba_included(normal,client,&sequence))goto unlock;
            g->client_reason=232; // Native accepted commit differs from this cohort.
            if(sequence!=p->client_commit_sequence)goto unlock;
            if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE &&
               *(u32 *)((char *)client+0x40)!=sequence) {g->client_reason=235;goto unlock;}
            g->client_reason=224;
            if(rgba_client_mapping(&g->client_api,node,&g->client_mapping)) {
                if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE &&
                   !rgba_client_domain_select(g,g->root)) {g->client_reason=234;goto unlock;}
                _Alignas(16) unsigned char transform[0x98]={0};
                g->client_api.transform_set(transform,&g->client_mapping,1);
                a->add_context(u,client,g->root,transform);
                if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE &&
                   *(u32 *)((char *)client+0x40)!=sequence) {g->client_reason=235;goto unlock;}
                result=1;g->client_reason=0;
            }
        }
    }
unlock:
    a->unlock_context(client);
done:
    a->assign_root(&wrapper_root,0);return result;
}
static void *rgba_model_lookup(struct rgba_model_control *m,void *context,u64 id) {
    if(!id)return 0;
    u32 seed=0;char *handle=m->lookup_handle(context,id,0,0,&seed);
    if(!handle || *(void **)(handle+0x18)!=context)return 0;
    char *layer=*(char **)(handle+0x10);
    return layer && *(void **)(layer+0x98)==handle?layer:0;
}
static int rgba_model_root_node(void *update,void *copy) {
    char *sentinel=(char *)update+0xd8,*node=*(char **)sentinel,*previous=sentinel,*seen[128];
    u32 count=0,found=0;
    for(;node!=sentinel;node=*(char **)node) {
        if(!node || count==128 || *(char **)(node+8)!=previous)return 0;
        for(u32 i=0;i<count;i++)if(seen[i]==node)return 0;
        seen[count++]=node;if(*(void **)(node+0x20)==copy)found++;
        previous=node;
    }
    return *(char **)(sentinel+8)==previous && found==1;
}
static int rgba_add_model(struct rgba_capture *g,char *cwc,void *u) {
    struct rgba_model_control *m=g->model;struct rgba_render_api *a=&g->api;
    void *context=(void *)g->pc.context;
    if(!rgba_model_control_valid(m) || !rgba_model_api_ready(&m->api))return 0;
    m->reason=RM_ROLE;m->nodes=m->copies=m->clock_contexts=m->witness=0;m->clock_before=m->clock_after=0;
    const u32 offsets[RM_ROLES]={0x80,0x88,0x98,0x90,0x60,0x70,0x78,0xa0,0xb0,0xb8};
    u64 ids[RM_ROLES]={0},omit[4]={0},mask=0;
    // Frontend ID reads precede Render::ContextLock, as in the presenter proof.
    for(u32 i=0;i<RM_ROLES;i++) {
        void *layer=*(void **)(cwc+offsets[i]);
        if(layer){m->reason=RM_FRONTEND_ID+i;ids[i]=m->layer_id(layer);if(!ids[i])return 0;}
    }
    if(!g->pc.engine || !g->pc.engine->ch)return 0;
    struct ch_win *w=slot(g->pc.engine->ch,g->pc.wid,0);
    // These pointers are engine-retained OWN objects in the exact WID slot.
    // A nonzero pointer must resolve to a live model in this wrapper Context;
    // the helper additionally proves each omission's unique tree membership.
    if(w) {
        void *layers[4]={(void *)w->bl_in,(void *)w->bl_act,(void *)w->bl_sh,(void *)w->bl_fill};
        for(u32 i=0;i<4;i++)if(layers[i]) {
            m->reason=RM_DECORATION_ID+i;omit[i]=m->layer_id(layers[i]);if(!omit[i])return 0;
        }
        if(w->mask){m->reason=RM_DECORATION_ID+4;mask=m->layer_id((void *)w->mask);if(!mask)return 0;}
    }
    if(a->lock_context(context)!=0)return 0;
    struct rgba_model_source source={0};struct rgba_model_result result={0};int ok=0;
    m->reason=RM_COMMIT;
    if(*(u32 *)((char *)context+0x40)!=g->normal_wrapper_sequence)goto done;
    m->reason=RM_ROLE;
    for(u32 i=0;i<RM_ROLES;i++)if(ids[i]) {
        m->reason=RM_LOOKUP_ROLE+i;
        source.role[i]=rgba_model_lookup(m,context,ids[i]);if(!source.role[i])goto done;
    }
    for(u32 i=0;i<4;i++)if(omit[i]) {
        m->reason=RM_LOOKUP_DECORATION+i;
        source.omit[i]=rgba_model_lookup(m,context,omit[i]);if(!source.omit[i])goto done;
    }
    if(mask){m->reason=RM_LOOKUP_MASK;source.own_mask=rgba_model_lookup(m,context,mask);if(!source.own_mask)goto done;}
    m->reason=RM_SOURCE_ROOT;
    if(source.role[RM_ROOT]!=a->root(context) || ids[RM_ROOT]!=*(u64 *)((char *)context+0x110))goto done;
    ok=rgba_model_copy(&m->api,&source,&result);
    m->reason=result.reason;m->nodes=result.nodes;m->copies=result.copies;
    if(ok) {
        g->root=result.root;ok=0;m->reason=RM_ROOT_WITNESS;
        char *handle=*(char **)((char *)source.role[RM_ROOT]+0x98);
        void *cache=*(void **)(handle+0x28);
        if(g->root==source.role[RM_ROOT] || *(void **)((char *)g->root+0x98)!=handle ||
           *(void **)(handle+0x10)!=source.role[RM_ROOT])goto done;
        m->witness|=1;m->reason=RM_ISOLATED;
        if(!(*(u64 *)((char *)u+0x4e8)&4))goto done;
        m->witness|=2;a->add_context(u,context,g->root,0);m->reason=RM_ROOT_WITNESS;
        if(*(void **)(handle+0x10)!=source.role[RM_ROOT] || *(void **)(handle+0x28)!=cache ||
           a->root(context)!=source.role[RM_ROOT])goto done;
        m->witness|=4;
        if(!rgba_model_root_node(u,g->root))goto done;
        m->witness|=8;m->reason=0;ok=1;
    }
done:
    a->unlock_context(context);return ok;
}
struct rgba_model_clock {void *context;u64 time;};
static int rgba_model_clocks(void *normal,struct rgba_model_clock *out,u32 *size) {
    *size=0;char *seen[256],*entry=*(char **)((char *)normal+0x140);
    for(;entry && *size<256;entry=*(char **)entry) {
        u32 n=*size;for(u32 i=0;i<n;i++)if(seen[i]==entry)return 0;
        void *context=*(void **)(entry+8);if(!context)return 0;
        for(u32 i=0;i<n;i++)if(out[i].context==context)return 0;
        double time=*(double *)((char *)context+0x288);if(!__builtin_isfinite(time))return 0;
        seen[n]=entry;out[n].context=context;__builtin_memcpy(&out[n].time,&time,8);*size=n+1;
    }
    return !entry && *size>0;
}
static int rgba_model_clock_proof(struct rgba_capture *g,struct rgba_model_clock *clocks,u32 size) {
    g->model->reason=RM_CLOCK;
    if(!rgba_client_cohort(g))return 0;
    char *entry=*(char **)((char *)g->update+0x140);u32 matched=0;
    for(;entry;entry=*(char **)entry) {
        void *context=*(void **)(entry+8);u32 i=0;while(i<size && clocks[i].context!=context)i++;
        if(i==size)return 0;
        g->model->clock_before=clocks[i].time;g->model->clock_after=*(u64 *)((char *)context+0x288);
        if(g->model->clock_before!=g->model->clock_after)return 0;
        matched++;
    }
    g->model->clock_contexts=matched;
    if(matched!=g->cohort_contexts)return 0;
    g->model->reason=0;return 1;
}
static int rgba_update(struct rgba_capture *g,char *cwc,char *state) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    void *normal=(void *)p->update,*context=(void *)p->context;
    if(g->update || g->root || !normal || !context || !p->client_included ||
       !rgba_included(normal,context,&g->normal_wrapper_sequence))return 0;
    // Snapshot/stream/restricting modes need their full native producer contract.
    if(cwc[0x7a0]&0xe0)return 0;
    void *display=*(void **)(state+0xe8);if(!display)return 0;
    void *interface=rgba_display_interface(display);if(!interface)return 0;
    u64 policy=*(u64 *)((char *)normal+0x4e8);int greedy=(int)((policy>>54)&1);
    if(policy&((1ULL<<8)|(1ULL<<16)|(1ULL<<32)))return 0;
    double time=a->get_time(normal);if(!__builtin_isfinite(time))return 0;
    // SetGreedy adds its epsilon on the transition from fresh Begin2's false.
    // Inherit the same sampled time, without applying that adjustment twice.
    double begin_time=time-(greedy?1e-9:0);
    void *u=a->begin_update(0,0x1fe4,0,begin_time,0,0,(rect *)(state+0x78),*(u32 *)(state+0xb8));
    if(!u)return 0;
    g->update=u;
    // These precede add_context AND survive through typed Finish. In particular,
    // isolated prevents private capture from acknowledging source presentation.
    a->isolated(u,1);a->hosted(u,1);a->skip_backdrops(u,1);
    _Alignas(16) unsigned char attributes[0x3c];a->attributes_from_state(attributes,state);
    int custom=*(u32 *)(state+0x110)!=0;
    if(custom)__builtin_memcpy(attributes,state+0x110,sizeof(attributes));
    a->use_skylight_attributes(u,custom);a->attributes(u,attributes);
    a->vbl_time(u,*(double *)((char *)normal+0x60));a->interval(u,*(double *)((char *)normal+0x68));
    a->displays(u,&interface,1);a->protection(u,a->get_protection(normal));a->add_flags(u,a->get_flags(normal));
    // These policies belong to the OUTER native Updater::UpdateState. The
    // selected normal Update is their exact already-resolved typed witness.
    a->greedy(u,greedy);a->ignore_flatten_cache(u,(int)((policy>>50)&1));
    a->flatten_backdrops(u,(int)((policy>>51)&1));a->create_flatten_surface(u,(int)((policy>>52)&1));
    u64 policy_mask=(1ULL<<50)|(1ULL<<51)|(1ULL<<52)|(1ULL<<54);
    if(a->get_time(u)!=time || ((*(u64 *)((char *)u+0x4e8)^policy)&policy_mask))return 0;
    if(g->content_mode==1 || g->content_mode==RGBA_CLIENT_DOMAIN_MODE)return rgba_add_client(g,cwc,normal,u);
    if(g->content_mode==2)return rgba_add_model(g,cwc,u);
    if(a->lock_context(context)!=0)return 0;
    void *root=a->root(context);
    if(root){a->assign_root(&g->root,root);a->add_context(u,context,g->root,0);}
    a->unlock_context(context);
    return g->root!=0;
}

static int rgba_flush_allowed(struct rgba_capture *g) {
    char *m=g->metal;
    // flush(false) has no GPU wait in this pinned build unless the optional
    // semaphore is present, or an external state installs an arbitrary callback.
    return m && !*(void **)(m+0x1338) && !*(void **)(m+0xfa0) && !*(void **)(m+0xfa8);
}
static int rgba_resources_owned(struct rgba_capture *g,void *shared_renderer,char *cap,int reuse) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    if((g->renderer && !reuse) || !shared_renderer || g->pc.texture_ref || g->clear_buffer || g->pc.command_buffer)return 0;
    char *shared_metal=*(char **)shared_renderer;if(!shared_metal)return 0;
    void *device=*(void **)(shared_metal+0xee8);if(!device)return 0;
    double w=g->content_mode==RGBA_CLIENT_DOMAIN_MODE?(double)g->domain.pixel_width:*(double *)(cap+0x38);
    double h=g->content_mode==RGBA_CLIENT_DOMAIN_MODE?(double)g->domain.pixel_height:*(double *)(cap+0x40);
    if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE && !g->domain.selected)return 0;
    if(!__builtin_isfinite(w) || !__builtin_isfinite(h) || w<1 || h<1 ||
       w>16384 || h>16384 || w*h>8388608 || (double)(u64)w!=w || (double)(u64)h!=h)return 0;
    if(!g->renderer)g->renderer=a->new_renderer(*a->callbacks,device,0,0);if(!g->renderer)return 0;
    g->shared_renderer=(u64)shared_renderer;g->shared_metal=(u64)shared_metal;
    g->shared_queue=(u64)*(void **)(shared_metal+0xef0);
    g->metal=*(void **)g->renderer;
    if(!g->metal || g->metal==shared_metal || g->renderer==shared_renderer)return 0;
    g->device=*(void **)((char *)g->metal+0xee8);g->queue=*(void **)((char *)g->metal+0xef0);
    if(g->device!=device || !g->queue || (u64)g->queue==g->shared_queue ||
       !rgba_flush_allowed(g) || rgba_send0(g,g->queue,g->sel.device)!=device)return 0;
    void *msg=p->engine->msg;
    void *desc=((void *(*)(void *,void *,u64,u64,u64,unsigned char))msg)(
        g->texture_class,g->sel.texture_2d,80,(u64)w,(u64)h,0);
    if(!desc)return 0;
    p->retain_obj(desc);rgba_set_u64(g,desc,g->sel.storage,0);
    rgba_set_u64(g,desc,g->sel.usage,5);rgba_set_u64(g,desc,g->sel.hazards,2);
    p->texture_ref=((void *(*)(void *,void *,void *))msg)(device,g->sel.new_texture,desc);
    p->release_obj(desc);if(!p->texture_ref || rgba_send0(g,p->texture_ref,g->sel.device)!=device)return 0;
    u64 (*get)(void *,void *)=msg;
    p->width=get(p->texture_ref,p->width_selector);p->height=get(p->texture_ref,p->height_selector);
    p->format=get(p->texture_ref,p->format_selector);
    if(p->width!=(u64)w || p->height!=(u64)h || p->format!=80 || get(p->texture_ref,p->type_selector)!=2)return 0;

    // Explicit transparent initialization on this SAME private queue. Completion
    // of the later final CB therefore also fences the clear; both are witnessed.
    void *cb=rgba_send0(g,g->queue,g->sel.command_buffer);if(!cb)return 0;
    void *pass=rgba_send0(g,g->pass_class,g->sel.pass_descriptor);if(!pass)return 0;
    void *attachments=rgba_send0(g,pass,g->sel.attachments);if(!attachments)return 0;
    void *attachment=((void *(*)(void *,void *,u64))msg)(attachments,g->sel.attachment_at,0);
    if(!attachment)return 0;
    ((void (*)(void *,void *,void *))msg)(attachment,g->sel.attachment_texture,p->texture_ref);
    rgba_set_u64(g,attachment,g->sel.load,2);rgba_set_u64(g,attachment,g->sel.store,1);
    struct {double r,g,b,a;} zero={0,0,0,0};
    ((void (*)(void *,void *,__typeof__(zero)))msg)(attachment,g->sel.clear,zero);
    void *encoder=((void *(*)(void *,void *,void *))msg)(cb,g->sel.render_encoder,pass);
    if(!encoder)return 0;
    rgba_send0(g,encoder,g->sel.end);g->clear_buffer=p->retain_obj(cb);if(!g->clear_buffer)return 0;
    g->clear_submitted=1;p->gpu_pending=1;rgba_send0(g,cb,g->sel.commit);
    return 1;
}

static int rgba_resources(struct rgba_capture *g,void *shared_renderer,char *cap) {
    return rgba_resources_owned(g,shared_renderer,cap,0);
}

// Capture the LAST OWN CB, including failure cleanup, after all native renderer
// work. Never claim the ordinary WS scheduled/backing tags as this witness.
static void rgba_seal(struct rgba_capture *g) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    if(!g->renderer || !g->metal || g->sealed)return;
    g->sealed=1;struct rgba_metal_state state={0};a->get_state(g->renderer,&state);
    if(state.cb)p->command_buffer=p->retain_obj(state.cb);
    // Returning even an empty state is the exact same-owner transfer contract.
    a->set_state(g->renderer,&state);
    if(p->command_buffer && state.owner==g->metal && rgba_flush_allowed(g)) {
        a->flush(g->metal,0);p->gpu_pending=1;
        g->command_buffer_bound=*(void **)((char *)g->metal+0xef8)==p->command_buffer &&
            !*(void **)((char *)g->metal+0xf00);
    } else if(!p->command_buffer) {
        // A previous internal private submission still needs terminal custody.
        void *submitted=*(void **)((char *)g->metal+0xef8);
        if(submitted){p->command_buffer=p->retain_obj(submitted);p->gpu_pending=1;}
    }
    p->command_after=(u64)p->command_buffer;
    p->capture_witness=g->render_called && g->inclusion && g->clear_submitted &&
        g->command_buffer_bound && p->command_buffer;
    if(!p->capture_witness && !p->reason)p->reason=215;
}

// Both admission routes render only into the same isolated OWN renderer.
// A normal admission supplies its callback-local owner witness; legacy callers
// retain the original metalCallbacks stack guard.
static void rgba_render_selected(struct rgba_capture *g,void *shared_renderer,
        char *selected,void *destination,rect canvas,char *cwc,char *state,
        int (*normal_owner)(struct pc_capture *,const void *),const void *scope) {
    struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    void *full_region=0;struct rgba_geometry geometry={0};int bound=0;
    struct rgba_model_clock clocks[256];u32 clock_count=0;
    g->selected_type=*(u32 *)(selected+0x180);g->source_flags=*(u32 *)(selected+0x218);
    if(g->content_mode==2 && !rgba_model_clocks((void *)p->update,clocks,&clock_count)){p->reason=233;goto done;}
    if(g->content_mode!=RGBA_CLIENT_DOMAIN_MODE && !rgba_update(g,cwc,state)){p->reason=210;goto done;}
    a->textures(g->renderer,&p->texture_ref,1,1);bound=1;
    if(g->content_mode==1 || g->content_mode==2 || g->content_mode==RGBA_CLIENT_DOMAIN_MODE) {
        full_region=p->engine->rgn(canvas);
        if(!full_region){p->reason=211;goto done;}
    }
    if(!rgba_geometry_setup_region_domain_owned(p,&a->geometry,g->renderer,shared_renderer,g->update,
          selected,*(char **)(selected+0x48),destination,&geometry,full_region,
          g->content_mode==RGBA_CLIENT_DOMAIN_MODE?&canvas:0,normal_owner,scope)){p->reason=211;goto done;}
    g->inclusion=rgba_included(g->update,(void *)p->client_context,&g->own_client_sequence) &&
        g->own_client_sequence==p->client_commit_sequence;
    if(g->content_mode==1 || g->content_mode==RGBA_CLIENT_DOMAIN_MODE)g->inclusion=g->inclusion && rgba_client_cohort(g);
    else g->inclusion=g->inclusion && rgba_included(g->update,(void *)p->context,&g->own_wrapper_sequence) &&
        g->own_wrapper_sequence==g->normal_wrapper_sequence;
    if(g->content_mode==2)g->inclusion=g->inclusion && rgba_model_clock_proof(g,clocks,clock_count);
    if(!g->inclusion){p->reason=212;goto done;}
    // Same offscreen path as native capture's specialized flags branch. It
    // consumes ONLY the OWN Update, leaving the ordinary CWC U/present intact.
    g->render_called=1;a->render_options(g->renderer,g->update,1);p->encoded++;
done:
    if(bound)a->textures(g->renderer,0,0,0);
    rgba_geometry_release(&a->geometry,&geometry);
    if(full_region)p->engine->release(full_region);
}

static void rgba_encode(void *mctx,void *compositor,void *head,void *owner) {
    struct rgba_capture *g=owner;struct pc_capture *p=&g->pc;struct rgba_render_api *a=&g->api;
    char *win=pc_source(p),*cwc=win?*(char **)(win+0x18):0;
    char *state=cwc?cwc+0x260+0x190*p->index:0,*cap=p->capture;
    void *destination=0,*shape=0;
    u64 start=p->engine->mabs?p->engine->mabs():0;
    if(!win || !cwc || !state || !cap || !rgba_api_ready(a)){p->reason=202;goto done;}
    void *shared_renderer=*(void **)((char *)mctx+0x90);
    // Select the retained client frame BEFORE target allocation. pc.capture_rect
    // remains the source-admission rectangle; no native capture field changes.
    if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE &&
       (p->baked_alpha!=1 || !rgba_update(g,cwc,state))) {p->reason=234;goto done;}
    if(!rgba_resources(g,shared_renderer,cap)){p->reason=203;goto done;}
    u32 flags=*(void **)(cap+0x60)?0x14440000:0x10440000;g->destination_flags=flags;
    rect canvas=g->content_mode==RGBA_CLIENT_DOMAIN_MODE?g->domain.mapped:p->capture_rect;
    destination=a->destination(p->texture_ref,g->device,canvas,*(float *)(cap+0x68),*(void **)(cap+0x60),flags);
    if(!destination || *(void **)((char *)destination+0xa0)){p->reason=204;goto done;}
    // Exact original-graph membership, bounded with duplicate/cycle rejection.
    char *stack[32],*seen[32],*selected=0;unsigned pending=1,count=0;stack[0]=head;
    while(pending) {
        char *s=stack[--pending];if(!s)continue;
        for(unsigned i=0;i<count;i++)if(seen[i]==s){p->reason=205;goto done;}
        if(count==32){p->reason=205;goto done;}seen[count++]=s;
        if(*(void **)s){if(pending==32){p->reason=205;goto done;}stack[pending++]=*(void **)s;}
        if(*(void **)(s+0x10)){if(pending==32){p->reason=205;goto done;}stack[pending++]=*(void **)(s+0x10);}
        // Reject BEFORE prepare: native type30 dispatches a compositor virtual
        // outside the proven CPU-only exact-one-type10 preparation contract.
        if(*(u32 *)(s+0x180)!=10 || !rgba_geometry_source(p,s,*(char **)(s+0x48)) || selected) {
            p->reason=206;goto done;
        }
        selected=s;
    }
    g->original_nodes=count;if(!selected){p->reason=206;goto done;}
    if(*(u32 *)((char *)destination+0x50)&0x10000000)shape=a->empty_shape();
    if((flags&0x10000000) && !shape){p->reason=207;goto done;}
    char *prepared=a->prepare_layers(compositor,head,destination,&shape);count=0;
    for(char *s=prepared;s;s=*(char **)(s+8)) {
        if(count==32){p->reason=208;goto done;}
        for(unsigned i=0;i<count;i++)if(seen[i]==s){p->reason=208;goto done;}
        seen[count++]=s;
        // This first qualifier intentionally refuses groups/additional draw
        // leaves; it cannot silently publish a partial composition as complete.
        if(s!=selected || *(u32 *)(s+0x180)!=10){p->reason=209;goto done;}
    }
    g->prepared_nodes=count;if(count!=1){p->reason=209;goto done;}
    rgba_render_selected(g,shared_renderer,selected,destination,canvas,cwc,state,0,0);
done:
    // Match native type10's paired destination unbind. Binding creates/pushes
    // a QC surface; leaving it current makes Context D2 assert. Unbind BEFORE
    // the final-CB transfer so encoder/surface finalization is fenced as well.
    if(shape)a->free_shape(0,shape);
    if(destination)a->release_destination(destination);
    rgba_seal(g);
    if(p->engine->mabs)g->encode_us=(double)(p->engine->mabs()-start)*p->engine->mabs_us;
}
void anim_rgba_frame(void *mctx,void *display,void *third,struct rgba_capture *g) {
    if(!rgba_valid(g) || g->destroyed)return;
    pc_frame(mctx,display,third,&g->pc,rgba_encode,g);
}
// A newer client commit can overtake the normal cohort before we retain its
// root. Retry that empty attempt on MAIN after native source cleanup, keeping
// the normal sequence check and every already-copied/GPU failure terminal.
static int rgba_client_retry_empty(struct rgba_capture *g,int retained_renderer) {
    struct pc_capture *p=&g->pc;
    if(g->content_mode!=RGBA_CLIENT_DOMAIN_MODE || g->destroyed || p->dead ||
       p->stage!=PC_INVALID || p->reason!=234 || g->client_reason!=235 ||
       !g->update || !g->api.finish_update || g->root || g->domain.selected ||
       (!retained_renderer && (g->renderer || g->metal || g->queue || g->device)) || g->clear_buffer ||
       g->clear_submitted || g->sealed || g->render_called || g->inclusion ||
       p->texture_ref || p->command_buffer || p->gpu_pending || p->encoded || p->capture_witness ||
       !p->source_unchanged || !p->present_unchanged || p->depth_after!=p->depth_before ||
       pc_normal_frame(p) || !pc_source(p))return 0;
    char *u=g->update;
    if(*(void **)(u+0x140) || *(u64 *)(u+0x2c0) ||
       *(void **)(u+0x280) || *(void **)(u+0x468) ||
       (*(u64 *)(u+0x4e8)&((1ULL<<21)|4))!=((1ULL<<21)|4))return 0;
    g->api.finish_update(g->update);g->update=0;
    g->normal_wrapper_sequence=0;g->client_reason=0;
    p->update=p->update_after=p->context=p->client_context=0;
    p->client_id=p->client_commit_sequence=p->client_transaction_seed=p->client_included=0;
    p->source_unchanged=p->present_unchanged=0;p->misses++;
    p->reason=0;p->stage=PC_ARMED;return 1;
}
static int rgba_client_retry(struct rgba_capture *g) {return rgba_client_retry_empty(g,0);}
int anim_rgba_poll(struct rgba_capture *g) {
    if(!rgba_valid(g) || !g->pc.is_main || g->pc.is_main()!=1)return 0;
    if(g->destroyed)return 1;
    if(g->quarantined || g->locked_client)return 0;
    if(rgba_client_retry(g))return 0;
    struct pc_capture *p=&g->pc;u64 (*status)(void *,void *)=p->engine->msg;
    int pending=0,error=0;
    if(g->clear_submitted) {
        if(!g->clear_buffer){p->gpu_pending=1;return 0;}
        g->clear_status=(u32)status(g->clear_buffer,p->status_selector);
        if(g->clear_status!=4 && g->clear_status!=5)pending=1;
        if(g->clear_status==5)error=1;
    }
    if(p->command_buffer) {
        p->gpu_status=(u32)status(p->command_buffer,p->status_selector);g->last_own_status=p->gpu_status;
        if(p->gpu_status!=4 && p->gpu_status!=5)pending=1;
        if(p->gpu_status==5)error=1;
    }
    // The private renderer retains its latest submission through typed Destroy.
    // A failed final-CB identity check must also fence that distinct submission;
    // completion of our earlier retained CB alone cannot permit cleanup.
    if(g->metal) {
        void *latest=*(void **)((char *)g->metal+0xef8);
        if(g->sealed && latest && latest!=p->command_buffer) {
            g->command_buffer_bound=0;p->capture_witness=0;
            if(!p->reason)p->reason=215;
            u32 latest_status=(u32)status(latest,p->status_selector);
            if(latest_status!=4 && latest_status!=5)pending=1;
            if(latest_status==5)error=1;
        }
    }
    // A returned-but-unsubmitted OWN current CB has no terminal witness. Keep
    // the image/resources quarantined; never convert NULL/uncommitted into READY.
    if(g->metal && *(void **)((char *)g->metal+0xf00))pending=1;
    p->gpu_pending=pending;
    if(!pending && error){if(p->stage==PC_ENCODED)p->stage=PC_GPU_ERROR;return 5;}
    if(!pending && p->stage==PC_ENCODED && p->capture_witness && g->clear_status==4 && p->gpu_status==4) {
        p->stage=PC_GPU_COMPLETE;
        if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE && g->domain.selected &&
           p->width==g->domain.pixel_width && p->height==g->domain.pixel_height)g->domain.gpu_complete=1;
        return 4;
    }
    return pending?0:1;
}
int anim_rgba_readback(struct rgba_capture *g) {
    if(!rgba_valid(g) || !g->pc.is_main || g->pc.is_main()!=1 || pc_normal_frame(&g->pc))return 0;
    struct pc_capture *p=&g->pc;
    anim_rgba_poll(g);g->readback_bytes=0;
    if(p->stage!=PC_GPU_COMPLETE || p->reason || p->gpu_pending || !p->texture_ref ||
       !p->capture_witness || !g->readback || !p->width || !p->height ||
       p->width>16384 || p->height>16384 || p->width*p->height>8388608 ||
       g->readback_capacity<p->width*p->height*4){g->readback_error=1;return 0;}
    struct {u64 x,y,z,w,h,d;} region={0,0,0,p->width,p->height,1};
    ((void (*)(void *,void *,void *,u64,__typeof__(region),u64))p->engine->msg)(
        p->texture_ref,g->sel.read_bytes,g->readback,p->width*4,region,0);
    g->readback_stride=p->width*4;g->readback_bytes=p->width*p->height*4;
    g->readback_count++;g->readback_error=0;return 1;
}
int anim_rgba_destroy(struct rgba_capture *g) {
    if(!rgba_valid(g) || !g->pc.is_main || g->pc.is_main()!=1)return 0;
    if(g->destroyed)return 1;
    if(g->quarantined || g->locked_client)return 0;
    anim_rgba_poll(g);if(g->pc.gpu_pending)return 0;
    // Queued sole MAIN timer only; Destroy may drain its OWN private native
    // completion work and must never run as compositor callback cleanup.
    if(pc_normal_frame(&g->pc))return 0;
    if(g->metal && *(void **)((char *)g->metal+0x2d8))return 0;
    if(g->update){g->api.finish_update(g->update);g->update=0;}
    if(g->root)g->api.assign_root(&g->root,0);
    if(g->renderer){g->api.destroy_renderer(g->renderer);g->renderer=0;g->metal=0;g->queue=0;g->device=0;}
    if(g->clear_buffer){g->pc.release_obj(g->clear_buffer);g->clear_buffer=0;}
    int result=anim_cache_destroy(&g->pc);if(result)g->destroyed=1;return result;
}
unsigned anim_rgba_state_size(void){return sizeof(struct rgba_capture);}
unsigned anim_rgba_api_offset(void){return __builtin_offsetof(struct rgba_capture,api);}

// Same original timer/forwarding slots as the baseline cache qualifier. Root
// publication validates this separate sidecar and publishes the signed self LAST.
static void rgba_dispatch_control(struct ctx *c,double now,int (*before_destroy)(struct rgba_capture *),
                                  int (*prepare)(struct rgba_capture *)) {
    void (*original)(struct ctx *,double)=*(void (**)(struct ctx *,double))((char *)c+PC_ORIGINAL_TICK);
    if(!original)return;
    original(c,now);
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->pc.engine!=c)return;
    struct pc_capture *p=&g->pc;p->dispatch_calls++;
    if(!p->is_main || p->is_main()!=1 || c->in_cb)return;
    u64 command=p->active_command;
    if(!command) {
        u64 sequence=__atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE);
        if(sequence==p->command_ack)return;
        command=__atomic_exchange_n(&p->command,0,__ATOMIC_ACQ_REL);if(!command)return;
        if(__atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE)!=sequence) {
            u64 empty=0;__atomic_compare_exchange_n(&p->command,&empty,command,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED);return;
        }
        p->command_claimed=sequence;p->active_command=command;
    }
    // Teardown remains available if the ordinary engine stops. Never create or
    // publish pixels after its native channel/session has become invalid.
    int live=!c->dead && c->ch && c->ch->h.magic==CH_MAGIC &&
        c->ch->h.size==(u32)sizeof(struct ch) && !c->ch->h.stop && pc_source(p);
    int result=0,done=1;
    if(command==1 && live){p->prepare_idle_permit=0x31454c44494350ULL;result=prepare?prepare(g):anim_rgba_prepare(g);}
    else if(command==2)result=anim_rgba_poll(g);
    else if(command==4) {
        // The consumer gate belongs after original tick and command claiming:
        // a concurrent controller may publish OFF during that original tick.
        if(!before_destroy || before_destroy(g))result=anim_rgba_destroy(g);
        if(!result)done=0;
    }
    else if(command==5)result=anim_rgba_readback(g);
    // There is deliberately no SHOW: the shell still contains the old native
    // snapshot. OWN texture pixels need a separately proved presentation bridge.
    if(done){p->command_result=result;p->active_command=0;__atomic_store_n(&p->command_ack,p->command_claimed,__ATOMIC_RELEASE);}
}
void anim_rgba_dispatch(struct ctx *c,double now) {rgba_dispatch_control(c,now,0,0);}
