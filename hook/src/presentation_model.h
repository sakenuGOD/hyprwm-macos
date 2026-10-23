// Borrowed MODEL layers are used only while the caller holds ContextLock and
// keeps the source root/Context alive through every source child-array access.
// Native C2 and setters provide PAC/object custody and Ext copy-on-write.
// Selected only by the explicitly configured experimental MODEL capture mode.
#define RGBA_MODEL_LIMIT 128
enum rgba_model_role {
    RM_ROOT,RM_STYLE,RM_CLIP,RM_BODY,RM_PRIMARY,RM_ABOVE,RM_BELOW,
    RM_NEUTRAL,RM_BACKDROP,RM_PORTAL,RM_ROLES
};
enum {
    RM_API=241,RM_ROLE,RM_GRAPH,RM_LIMIT,RM_MASK,RM_ALLOC,RM_ARRAY,RM_COMMIT,RM_ISOLATED,RM_ROOT_WITNESS,RM_CLOCK,
    RM_FRONTEND_ID=260,RM_DECORATION_ID=280,RM_LOOKUP_ROLE=300,RM_LOOKUP_DECORATION=320,RM_SOURCE_ROOT=340,RM_LOOKUP_MASK
};
struct rgba_model_api {
    void *(*allocate)(u64);
    void (*copy_layer)(void *,const void *);
    void (*release)(void *);
    void *(*new_array)(u32,void *const *,int,u32);
    void (*sublayers)(void *,void *);
    void (*animations)(void *,void *);
    void (*modifiers)(void *,void *);
    void (*remote_effects)(void *,void *);
    void (*number)(void *,const u32 *,u64,int,u64,const double *);
    void (*corner_contents)(void *,void *);
    void (*corner_center)(void *,void *);
    void (*corner_radii)(void *,void *);
    void (*mask)(void *,void *);
    void (*filters)(void *,void *);
    void (*compositing_filter)(void *,void *);
};
struct rgba_model_source {
    void *role[RM_ROLES];
    void *omit[4]; // Exact retained OWN decoration identities, never names/types.
    void *own_mask;
};
struct rgba_model_result {
    void *root; // Transfers exactly one creator reference on success.
    u32 nodes,copies,reason;
};
#define RGBA_MODEL_MAGIC 0x314c444f4d4d5748ULL
#define RGBA_MODEL_OFFSET 2048
struct rgba_model_control {
    u64 magic;u32 size,version;
    struct rgba_model_api api;
    u64 (*layer_id)(void *);
    void *(*lookup_handle)(void *,u64,u32,int,u32 *);
    u32 reason,nodes,copies,clock_contexts,witness,pad;
    u64 clock_before,clock_after; // Scalar refusal evidence, never Context pointers.
};
static int rgba_model_control_valid(struct rgba_model_control *m) {
    return m && m->magic==RGBA_MODEL_MAGIC && m->size==sizeof(*m) && m->version==1 &&
        m->layer_id && m->lookup_handle;
}
static int rgba_model_api_ready(const struct rgba_model_api *a) {
    return a && a->allocate && a->copy_layer && a->release && a->new_array &&
        a->sublayers && a->animations && a->modifiers && a->remote_effects &&
        a->number && a->corner_contents && a->corner_center && a->corner_radii &&
        a->mask && a->filters && a->compositing_filter;
}
static void rgba_model_number(const struct rgba_model_api *a,void *layer,u32 atom,double value) {
    a->number(layer,&atom,1,0,1,&value);
}
static int rgba_model_children(void *layer,void **out,u32 *count) {
    void *children=*(void **)((char *)layer+0x70);*count=0;
    if(!children)return 1;
    if(*(u32 *)((char *)layer+0xc)&(1U<<13)) {
        out[0]=children;*count=1;return 1;
    }
    u32 n=*(u32 *)((char *)children+0x10);
    if(n>RGBA_MODEL_LIMIT)return 0;
    for(u32 i=0;i<n;i++) {
        out[i]=((void **)((char *)children+0x18))[i];
        if(!out[i])return 0;
    }
    *count=n;return 1;
}
struct rgba_model_node {
    void *source,*copy;
    u32 parent,role,omitted;
};
static int rgba_model_parent(struct rgba_model_node *nodes,u32 parent,u32 child) {
    return child && child<RGBA_MODEL_LIMIT && nodes[child].parent==parent;
}
static int rgba_model_copy(const struct rgba_model_api *a,const struct rgba_model_source *s,
                           struct rgba_model_result *out) {
    if(!out)return 0;
    *out=(struct rgba_model_result){.reason=RM_API};
    if(!rgba_model_api_ready(a) || !s)return 0;
    out->reason=RM_ROLE;
    for(u32 i=RM_ROOT;i<=RM_PRIMARY;i++)if(!s->role[i])return 0;
    for(u32 i=0;i<RM_ROLES;i++)if(s->role[i]) {
        for(u32 j=0;j<i;j++)if(s->role[i]==s->role[j])return 0;
        for(u32 j=0;j<4;j++)if(s->role[i]==s->omit[j])return 0;
    }
    // Unknown masks are not guessed to be WS corner styling. Preserve root80's
    // configured content/frame mask; clear clip98 only for exact OWN provenance.
    void *mask=*(void **)((char *)s->role[RM_CLIP]+0x78);
    if(mask!=s->own_mask || *(void **)((char *)s->role[RM_STYLE]+0x78)) {
        out->reason=RM_MASK;return 0;
    }
    for(u32 i=0;i<4;i++)if(s->omit[i])
        for(u32 j=0;j<i;j++)if(s->omit[i]==s->omit[j])return 0;
    struct rgba_model_node nodes[RGBA_MODEL_LIMIT];
    void *children[RGBA_MODEL_LIMIT];u32 indexes[RM_ROLES],count=1;
    for(u32 i=0;i<RM_ROLES;i++)indexes[i]=RGBA_MODEL_LIMIT;
    nodes[0]=(struct rgba_model_node){.source=s->role[RM_ROOT]};
    // Parent precedes child; reverse order below constructs children first.
    for(u32 i=0;i<count;i++) {
        struct rgba_model_node *n=&nodes[i];n->role=RM_ROLES;
        for(u32 j=0;j<RM_ROLES;j++)if(n->source==s->role[j]) {
            n->role=j;indexes[j]=i;break;
        }
        n->omitted=n->role==RM_BACKDROP || n->role==RM_PORTAL ||
            (i && nodes[n->parent].omitted);
        for(u32 j=0;j<4;j++)if(n->source==s->omit[j])n->omitted=1;
        u32 size;out->reason=RM_GRAPH;
        if(!rgba_model_children(n->source,children,&size))return 0;
        if(size>RGBA_MODEL_LIMIT-count){out->reason=RM_LIMIT;return 0;}
        for(u32 j=0;j<size;j++) {
            for(u32 k=0;k<count;k++)if(nodes[k].source==children[j])return 0;
            nodes[count++]=(struct rgba_model_node){.source=children[j],.parent=i};
        }
    }
    out->nodes=count;out->reason=RM_ROLE;
    for(u32 i=0;i<4;i++)if(s->omit[i]) {
        u32 found=0;for(u32 j=0;j<count;j++)if(nodes[j].source==s->omit[i])found++;
        if(found!=1)return 0;
    }
    for(u32 i=RM_ROOT;i<=RM_PRIMARY;i++)if(indexes[i]==RGBA_MODEL_LIMIT || nodes[indexes[i]].omitted)return 0;
    for(u32 i=RM_ABOVE;i<RM_ROLES;i++)if(s->role[i] &&
        (indexes[i]==RGBA_MODEL_LIMIT || (i<=RM_NEUTRAL && nodes[indexes[i]].omitted)))return 0;
    // Pinned baseline chain. Neutral alpha-mask, when present, is retained on
    // the native clip98 -> body90 path rather than flattened to an identity.
    if(!rgba_model_parent(nodes,indexes[RM_ROOT],indexes[RM_STYLE]) ||
       !rgba_model_parent(nodes,indexes[RM_STYLE],indexes[RM_CLIP]))return 0;
    if(s->role[RM_NEUTRAL]) {
        if(!rgba_model_parent(nodes,indexes[RM_CLIP],indexes[RM_NEUTRAL]) ||
           !rgba_model_parent(nodes,indexes[RM_NEUTRAL],indexes[RM_BODY]))return 0;
    }else if(!rgba_model_parent(nodes,indexes[RM_CLIP],indexes[RM_BODY]))return 0;
    if(!rgba_model_parent(nodes,indexes[RM_BODY],indexes[RM_PRIMARY]))return 0;
    for(u32 i=RM_ABOVE;i<=RM_BELOW;i++)if(s->role[i] &&
        !rgba_model_parent(nodes,indexes[RM_BODY],indexes[i]))return 0;
    for(u32 i=RM_BACKDROP;i<=RM_PORTAL;i++)if(s->role[i] &&
        !rgba_model_parent(nodes,indexes[RM_CLIP],indexes[i]))return 0;
    if(s->role[RM_PORTAL] && !s->role[RM_NEUTRAL])return 0;
    for(u32 reverse=count;reverse;reverse--) {
        u32 i=reverse-1;struct rgba_model_node *n=&nodes[i];
        if(n->omitted)continue;
        int targeted=n->role==RM_ROOT || n->role==RM_STYLE || n->role==RM_CLIP || n->role==RM_NEUTRAL;
        u32 size;int changed=0;
        // Source child order is recovered directly, never from traversal order.
        if(!rgba_model_children(n->source,children,&size)){out->reason=RM_GRAPH;goto failed;}
        u32 kept=0;
        for(u32 j=0;j<size;j++) {
            u32 k=0;while(k<count && nodes[k].source!=children[j])k++;
            if(k==count){out->reason=RM_GRAPH;goto failed;}
            if(nodes[k].omitted){changed=1;continue;}
            if(nodes[k].copy){children[kept++]=nodes[k].copy;changed=1;}
            else children[kept++]=nodes[k].source;
        }
        if(!targeted && !changed)continue;
        // Native C2 is a base Layer constructor, not a polymorphic clone.
        // Only the proved WS body may be copied for structural surgery.
        // Host/app/unknown subclasses remain native objects or refuse.
        if(!targeted && n->role!=RM_BODY){out->reason=RM_ROLE;goto failed;}
        out->reason=RM_ALLOC;n->copy=a->allocate(0xa0);if(!n->copy)goto failed;
        a->copy_layer(n->copy,n->source);out->copies++;
        if(!targeted)a->animations(n->copy,*(void **)((char *)n->source+0x90));
        else {a->modifiers(n->copy,0);a->remote_effects(n->copy,0);}
        if(changed) {
            // Every admitted copy retains its required chain/primary child.
            if(!kept){out->reason=RM_ROLE;goto failed;}
            out->reason=RM_ARRAY;void *array=a->new_array(kept,children,1,0);
            if(!array)goto failed;
            a->sublayers(n->copy,array);a->release(array);
        }
        if(n->role==RM_ROOT)rgba_model_number(a,n->copy,0x21b,1);
        if(n->role==RM_STYLE || n->role==RM_CLIP) {
            rgba_model_number(a,n->copy,0xa4,0);
            a->corner_contents(n->copy,0);a->corner_center(n->copy,0);a->corner_radii(n->copy,0);
        }
        if(n->role==RM_STYLE) {
            rgba_model_number(a,n->copy,0x4d,0);rgba_model_number(a,n->copy,0x265,0);
            rgba_model_number(a,n->copy,0x284,0);
        }
        if(n->role==RM_CLIP && mask)a->mask(n->copy,0);
        if(n->role==RM_NEUTRAL) {
            a->filters(n->copy,0);a->compositing_filter(n->copy,0);rgba_model_number(a,n->copy,0x28a,0);
        }
    }
    out->root=nodes[0].copy;nodes[0].copy=0;out->reason=0;
    for(u32 i=0;i<count;i++)if(nodes[i].copy)a->release(nodes[i].copy);
    return 1;
failed:
    for(u32 i=0;i<count;i++)if(nodes[i].copy)a->release(nodes[i].copy);
    return 0;
}
