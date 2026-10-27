#include "../src/anim4.c"
#include <stdio.h>
#define OFFSET(type,field) printf("#define OFF_" #type "_" #field " %lu\n",__builtin_offsetof(struct type,field))
int main(void){
 printf("#define SIZE_RGBA %lu\n#define SIZE_NORMAL %lu\n",sizeof(struct rgba_capture),sizeof(struct rgba_normal_binding));
 OFFSET(rgba_capture,magic);OFFSET(rgba_capture,size);OFFSET(rgba_capture,version);OFFSET(rgba_capture,content_mode);OFFSET(rgba_capture,locked_client);OFFSET(rgba_capture,quarantined);OFFSET(rgba_capture,api);
 OFFSET(rgba_render_api,unlock_context);OFFSET(pc_capture,is_main);OFFSET(pc_capture,client_context);OFFSET(pc_capture,stage);OFFSET(pc_capture,reason);OFFSET(pc_capture,update);
 OFFSET(rgba_normal_binding,capture);OFFSET(rgba_normal_binding,inflight);OFFSET(rgba_normal_binding,dead);

 printf("#define SIZE_CTX %lu\n#define SIZE_CH %lu\n#define SIZE_INPLACE %lu\n#define SIZE_BEGIN %lu\n#define ORDINARY_SLOTS %u\n",sizeof(struct ctx),sizeof(struct ch),sizeof(struct rgba_inplace),sizeof(struct rgba_begin_binding),RGBA_ORDINARY_SLOTS);
 OFFSET(pc_capture,engine);OFFSET(ctx,ch);OFFSET(ctx,by_id);OFFSET(ctx,tx_ctor);OFFSET(ctx,tx_add);OFFSET(ctx,tx_dtor);OFFSET(ch,win);OFFSET(ch_win,wid);OFFSET(ch_win,used);
 OFFSET(rgba_inplace,on);OFFSET(rgba_inplace,presenting);OFFSET(rgba_inplace,window);OFFSET(rgba_inplace,creator);OFFSET(rgba_inplace,pid_version);OFFSET(rgba_inplace,wid);OFFSET(rgba_inplace,context);OFFSET(rgba_inplace,host);
 printf("#define SIZE_CARRIER %lu\n#define SIZE_CARRIER_SLOT %lu\n",sizeof(struct rgba_carrier),sizeof(struct rgba_carrier_slot));
 OFFSET(rgba_carrier,capture);OFFSET(rgba_carrier,depth);OFFSET(rgba_carrier,dead);OFFSET(rgba_carrier,slots);OFFSET(rgba_carrier_slot,view);OFFSET(rgba_carrier_slot,root);
 printf("#define SIZE_CLOSE %lu\n#define SIZE_CLOSE_SLOT %lu\n",sizeof(struct rgba_close),sizeof(struct rgba_close_slot));
 printf("#define SIZE_ACCEPTED_CLOSE %lu\n#define SIZE_ACCEPTED_CLOSE_SLOT %lu\n#define OFFSET_ACCEPTED_CLOSE_PROFILE %lu\n",sizeof(struct rgba_accepted_close),sizeof(struct rgba_accepted_close_slot),__builtin_offsetof(struct rgba_accepted_close,profile));
 OFFSET(rgba_close,capture);OFFSET(rgba_close,slots);OFFSET(rgba_close_slot,view);OFFSET(rgba_close_slot,clone);OFFSET(rgba_close_slot,source);OFFSET(rgba_close_slot,clone_wid);OFFSET(rgba_close_slot,source_wid);OFFSET(rgba_close_slot,stamp);OFFSET(rgba_view,wid);OFFSET(rgba_view,window);OFFSET(rgba_view,shown);OFFSET(rgba_view,active);
 OFFSET(rgba_view,context);OFFSET(ctx,in_cb);
 printf("#define SIZE_DRAWING %lu\n#define SIZE_DRAW_SLOT %lu\n",sizeof(struct rgba_drawing),sizeof(struct rgba_draw_slot));
 OFFSET(rgba_drawing,capture);OFFSET(rgba_drawing,dead);OFFSET(rgba_drawing,slots);
 OFFSET(rgba_draw_slot,epoch);OFFSET(rgba_draw_slot,viewport_state);OFFSET(rgba_draw_slot,viewport_epoch);
 OFFSET(rgba_begin_binding,capture);OFFSET(rgba_begin_binding,dead);
}
