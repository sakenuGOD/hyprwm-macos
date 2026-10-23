// Production guard, no fixture macro. Own executable must refuse before any
// native getter, actor dereference, listener or switch operation is attempted.
#include "DockSpacesBridge.m"
int main(void){@autoreleasepool{char out[32768]={0};int code=hypr_dockspaces_v1_json("{\"op\":\"status\"}",out,sizeof(out));NSDictionary *r=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:out length:strlen(out)] options:0 error:NULL];
 BOOL ok=code==4&&[r[@"error"]isEqual:@"exact_dock_platform_required"]&&DSDispatchCount==0&&!DSServer&&!DSLease;
 NSDictionary *report=@{@"ok":@(ok),@"production_guard_refused_wrong_process":@(ok),@"native_calls":@0,@"endpoint_created":@NO};NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return ok?0:1;}}
