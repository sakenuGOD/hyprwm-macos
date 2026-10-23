// Prepared graph provenance/fault contracts, not native rendering proof.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
struct rgba_matrix {double v[16];};
#include "../src/presentation_client.h"
static _Alignas(16) char update[0x160],nodes[6][0x90],layers[5][0xa0];
static int handles[5];
static void init_head(char *head){*(void **)head=head;*(void **)(head+8)=head;}
static void insert(char *head,char *node,char *parent,char *layer){
 char *last=*(char **)(head+8);*(void **)node=head;*(void **)(node+8)=last;
 *(void **)last=node;*(void **)(head+8)=node;
 *(void **)(node+0x58)=parent;*(void **)(node+0x20)=layer;init_head(node+0x60);
}
static void reset(void){
 memset(update,0,sizeof(update));memset(nodes,0,sizeof(nodes));memset(layers,0,sizeof(layers));
 for(unsigned i=0;i<5;i++)*(void **)(layers[i]+0x98)=&handles[i];
 init_head(update+0xd8);
 insert(update+0xd8,nodes[0],0,layers[0]);
 insert(nodes[0]+0x60,nodes[1],nodes[0],layers[1]);
 insert(nodes[1]+0x60,nodes[2],nodes[1],layers[2]);
}
static void graph_faults(void){
 u32 count=0;reset();assert(rgba_client_node(update,layers[0],layers[2],&count)==nodes[2] && count==3);
 // Native animated Layer copies preserve Handle; pointer equality is wrong.
 *(void **)(layers[3]+0x98)=&handles[2];*(void **)(nodes[2]+0x20)=layers[3];
 assert(rgba_client_node(update,layers[0],layers[2],&count)==nodes[2]);
 // Do not inspect foreign or app-internal graphs to recover outer placement.
 insert(update+0xd8,nodes[3],0,layers[4]);*(void **)(nodes[3]+0x60)=(void *)1;
 *(void **)(nodes[2]+0x60)=(void *)2;
 assert(rgba_client_node(update,layers[0],layers[2],&count)==nodes[2]);
 reset();insert(nodes[0]+0x60,nodes[3],nodes[0],layers[2]);
 assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();*(void **)(nodes[2]+0x58)=nodes[0];assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();*(void **)(nodes[1]+8)=nodes[1];assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();*(void **)nodes[1]=nodes[1];assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();*(void **)(nodes[0]+0x58)=nodes[1];assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();*(void **)(nodes[2]+0x20)=layers[3];assert(!rgba_client_node(update,layers[0],layers[2],&count));
 reset();insert(update+0xd8,nodes[3],0,layers[0]);assert(!rgba_client_node(update,layers[0],layers[2],&count));
}
static void scalar_diagnostics(void){
 u32 count=99,status=99;reset();
 assert(rgba_client_node_scan(update,layers[0],layers[2],&count,&status)==nodes[2] && count==3 && !status);
 *(void **)(nodes[2]+0x20)=layers[3];
 assert(!rgba_client_node_scan(update,layers[0],layers[2],&count,&status) && count==3 && status==RGBA_CLIENT_NODE_ABSENT);
 reset();insert(nodes[0]+0x60,nodes[3],nodes[0],layers[2]);
 assert(!rgba_client_node_scan(update,layers[0],layers[2],&count,&status) && count==4 && status==RGBA_CLIENT_NODE_DUPLICATE);
 reset();assert(!rgba_client_node_scan(update,layers[4],layers[2],&count,&status) && status==RGBA_CLIENT_WRAPPER_ABSENT);
 reset();insert(update+0xd8,nodes[3],0,layers[0]);
 assert(!rgba_client_node_scan(update,layers[0],layers[2],&count,&status) && status==RGBA_CLIENT_WRAPPER_DUPLICATE);
 reset();*(void **)(nodes[2]+0x58)=nodes[0];
 assert(!rgba_client_node_scan(update,layers[0],layers[2],&count,&status) && count==0 && status==RGBA_CLIENT_GRAPH_INVALID);
}
static struct rgba_matrix mapped;
static void map(void *mapper,void *node,void *to){
 assert(node==nodes[2] && !to);struct rgba_matrix **out=(struct rgba_matrix **)((char *)mapper+8);**out=mapped;
}
static void transform_set(void *out,const struct rgba_matrix *m,int affine){(void)out;(void)m;assert(affine);}
static void mapping_faults(void){
 const struct rgba_client_api a={(void *)0x1000,map,transform_set};struct rgba_matrix out={0};
 mapped=(struct rgba_matrix){.v={1.25,.5,0,0,-.25,.75,0,0,0,0,1,0,-19.375,42.125,0,1}};
 assert(rgba_client_mapping(&a,nodes[2],&out));assert(!memcmp(&out,&mapped,sizeof(out)));
 mapped.v[15]=0;assert(!rgba_client_mapping(&a,nodes[2],&out));mapped.v[15]=1;
 mapped.v[0]=1;mapped.v[1]=.5;mapped.v[4]=.5;mapped.v[5]=.25;
 assert(!rgba_client_mapping(&a,nodes[2],&out));mapped.v[5]=.75;
 mapped.v[12]=__builtin_nan("");assert(!rgba_client_mapping(&a,nodes[2],&out));
}
int main(void){graph_faults();scalar_diagnostics();mapping_faults();puts("RGBA selected-client graph/Handle/parent/cycle/map and scalar diagnosis contracts PASS");return 0;}
