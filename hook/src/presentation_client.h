// Exact prepared primary-client placement in its selected native Update.
// These arena pointers remain local to the serialized compositor callback.
struct rgba_client_api {
    const void *map_vtable;
    void (*map)(void *,void *,void *);
    void (*transform_set)(void *,const struct rgba_matrix *,int);
};
static int rgba_client_api_ready(const struct rgba_client_api *a) {
    return a && a->map_vtable && a->map && a->transform_set;
}
// Scalar diagnostics describe this callback only; no arena pointer is retained.
enum { RGBA_CLIENT_GRAPH_INVALID=225,RGBA_CLIENT_WRAPPER_ABSENT,
       RGBA_CLIENT_WRAPPER_DUPLICATE,RGBA_CLIENT_NODE_ABSENT,RGBA_CLIENT_NODE_DUPLICATE };
static void *rgba_client_node_scan(void *update,void *wrapper_root,void *client_root,u32 *visited,u32 *status) {
    if(!visited || !status)return 0;
    *visited=0;*status=RGBA_CLIENT_GRAPH_INVALID;
    if(!update || !wrapper_root || !client_root || !visited)return 0;
    void *wrapper_handle=*(void **)((char *)wrapper_root+0x98);
    void *client_handle=*(void **)((char *)client_root+0x98);
    if(!wrapper_handle || !client_handle || wrapper_handle==client_handle)return 0;
    char *sentinel=(char *)update+0xd8,*previous=sentinel,*wrapper=0;
    char *seen[512];unsigned count=0,wrapper_count=0;
    for(char *node=*(char **)sentinel;node!=sentinel;node=*(char **)node) {
        if(!node || count==512 || *(char **)(node+8)!=previous || *(void **)(node+0x58))return 0;
        for(unsigned i=0;i<count;i++)if(seen[i]==node)return 0;
        seen[count++]=node;previous=node;
        char *layer=*(char **)(node+0x20);
        if(layer && *(void **)(layer+0x98)==wrapper_handle){wrapper=node;wrapper_count++;}
    }
    if(*(char **)(sentinel+8)!=previous)return 0;
    if(wrapper_count!=1) {
        *visited=count;*status=wrapper_count?RGBA_CLIENT_WRAPPER_DUPLICATE:RGBA_CLIENT_WRAPPER_ABSENT;return 0;
    }
    struct client_walk {char *head,*next,*previous,*parent;} stack[64];
    unsigned depth=1,matches=0;
    stack[0]=(struct client_walk){wrapper+0x60,*(char **)(wrapper+0x60),wrapper+0x60,wrapper};
    void *selected=0;
    while(depth) {
        struct client_walk *walk=&stack[depth-1];char *node=walk->next;
        if(node==walk->head) {
            if(*(char **)(walk->head+8)!=walk->previous)return 0;
            depth--;continue;
        }
        if(!node || count==512 || *(char **)(node+8)!=walk->previous ||
           *(char **)(node+0x58)!=walk->parent)return 0;
        for(unsigned i=0;i<count;i++)if(seen[i]==node)return 0;
        seen[count++]=node;walk->next=*(char **)node;walk->previous=node;
        char *layer=*(char **)(node+0x20);
        if(layer && *(void **)(layer+0x98)==client_handle) {
            selected=node;matches++;
            // The app subtree is rendered natively from this retained root.
            // Its internal portals are not another outer hosting placement.
            continue;
        }
        if(depth==64)return 0;
        stack[depth++]=(struct client_walk){node+0x60,*(char **)(node+0x60),node+0x60,node};
    }
    *visited=count;
    *status=matches==1?0:matches?RGBA_CLIENT_NODE_DUPLICATE:RGBA_CLIENT_NODE_ABSENT;
    return matches==1?selected:0;
}
static void *rgba_client_node(void *update,void *wrapper_root,void *client_root,u32 *visited) {
    u32 status;return rgba_client_node_scan(update,wrapper_root,client_root,visited,&status);
}
static int rgba_client_mapping(const struct rgba_client_api *a,void *node,struct rgba_matrix *out) {
    if(!rgba_client_api_ready(a) || !node || !out)return 0;
    struct rgba_matrix matrix={.v={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}};
    struct {const void *vtable;struct rgba_matrix *output;} mapper={a->map_vtable,&matrix};
#if __has_feature(ptrauth_calls)
    mapper.vtable=__builtin_ptrauth_sign_unauthenticated(mapper.vtable,2,
        __builtin_ptrauth_blend_discriminator(&mapper.vtable,0x60db));
#endif
    a->map(&mapper,node,0);
    for(unsigned i=0;i<16;i++)if(!__builtin_isfinite(matrix.v[i]))return 0;
    // First native qualifier covers finite nonsingular planar placement. App
    // content/nested layers remain arbitrary native graph below this root.
    if(matrix.v[2]!=0 || matrix.v[3]!=0 || matrix.v[6]!=0 || matrix.v[7]!=0 ||
       matrix.v[8]!=0 || matrix.v[9]!=0 || matrix.v[10]!=1 || matrix.v[11]!=0 ||
       matrix.v[14]!=0 || matrix.v[15]!=1)return 0;
    double determinant=matrix.v[0]*matrix.v[5]-matrix.v[1]*matrix.v[4];
    if(!__builtin_isfinite(determinant) || determinant==0)return 0;
    *out=matrix;return 1;
}
