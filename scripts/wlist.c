#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
int main(){
  CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  for(CFIndex i=0;i<CFArrayGetCount(a);i++){
    CFDictionaryRef d=CFArrayGetValueAtIndex(a,i);
    int wid=0, layer=0; CGRect r={0};
    CFNumberRef n=CFDictionaryGetValue(d,kCGWindowNumber); if(n)CFNumberGetValue(n,kCFNumberIntType,&wid);
    CFNumberRef ln=CFDictionaryGetValue(d,kCGWindowLayer); if(ln)CFNumberGetValue(ln,kCFNumberIntType,&layer);
    CFDictionaryRef b=CFDictionaryGetValue(d,kCGWindowBounds); if(b)CGRectMakeWithDictionaryRepresentation(b,&r);
    char owner[128]="?"; CFStringRef o=CFDictionaryGetValue(d,kCGWindowOwnerName); if(o)CFStringGetCString(o,owner,128,kCFStringEncodingUTF8);
    char name[128]=""; CFStringRef nm=CFDictionaryGetValue(d,kCGWindowName); if(nm)CFStringGetCString(nm,name,128,kCFStringEncodingUTF8);
    if(layer==0 && r.size.width>100 && r.size.height>100)
      printf("wid=%-6d (0x%x) layer=%d  %.0fx%.0f @ (%.0f,%.0f)  %s | %s\n",wid,wid,layer,r.size.width,r.size.height,r.origin.x,r.origin.y,owner,name);
  }
  return 0;
}
