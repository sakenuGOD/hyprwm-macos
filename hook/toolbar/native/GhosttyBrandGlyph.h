// Authentic Ghostty logo paths, monochrome outer silhouette + terminal cutouts.
// Source: ghostty-org/website@7962e91e190ff226be1a4983eb9368b7ddb4dff9 public/ghostty-logo.svg
// MIT, Copyright (c) 2024 Ghostty. Full license: assets/LICENSE.Ghostty.
static NSBezierPath *ghosttyBrandPath(void) {
    NSBezierPath *path=[NSBezierPath bezierPath];path.windingRule=NSEvenOddWindingRule;
    [path moveToPoint:NSMakePoint(20.3955,0)];
    [path curveToPoint:NSMakePoint(16.879,1.0667) controlPoint1:NSMakePoint(19.1436,0) controlPoint2:NSMakePoint(17.9152,0.3751)];
    [path curveToPoint:NSMakePoint(13.3625,0) controlPoint1:NSMakePoint(15.8428,0.3751) controlPoint2:NSMakePoint(14.6121,0)];
    [path curveToPoint:NSMakePoint(9.84606,1.0667) controlPoint1:NSMakePoint(12.113,0) controlPoint2:NSMakePoint(10.8822,0.3751)];
    [path curveToPoint:NSMakePoint(6.37177,0) controlPoint1:NSMakePoint(8.8169,0.3751) controlPoint2:NSMakePoint(7.62598,0.0094)];
    [path lineToPoint:NSMakePoint(6.33426,0)];
    [path curveToPoint:NSMakePoint(1.83316,1.9059) controlPoint1:NSMakePoint(4.63228,0) controlPoint2:NSMakePoint(3.0358,0.6775)];
    [path curveToPoint:NSMakePoint(-0.00244141,6.3883) controlPoint1:NSMakePoint(0.64928,3.1156) controlPoint2:NSMakePoint(-0.00244141,4.7074)];
    [path lineToPoint:NSMakePoint(-0.00244141,18.6374)];
    [path curveToPoint:NSMakePoint(13.3625,32) controlPoint1:NSMakePoint(-9.70841e-05,26.00557) controlPoint2:NSMakePoint(5.99433,32)];
    [path curveToPoint:NSMakePoint(26.7252,18.6374) controlPoint1:NSMakePoint(20.7307,32) controlPoint2:NSMakePoint(26.7252,26.00557)];
    [path lineToPoint:NSMakePoint(26.7252,6.3836)];
    [path curveToPoint:NSMakePoint(20.7472,0.0094) controlPoint1:NSMakePoint(26.7252,2.9914) controlPoint2:NSMakePoint(24.0995,0.1922)];
    [path curveToPoint:NSMakePoint(20.3955,0) controlPoint1:NSMakePoint(20.6299,0.0023) controlPoint2:NSMakePoint(20.5127,0)];
    [path closePath];
    [path moveToPoint:NSMakePoint(11.2808,19.5634)];
    [path lineToPoint:NSMakePoint(7.3494,21.8327)];
    [path curveToPoint:NSMakePoint(5.88654,21.4412) controlPoint1:NSMakePoint(6.83833,22.12808) controlPoint2:NSMakePoint(6.18192,21.9523)];
    [path curveToPoint:NSMakePoint(6.27804,19.9783) controlPoint1:NSMakePoint(5.59115,20.9301) controlPoint2:NSMakePoint(5.76698,20.2737)];
    [path lineToPoint:NSMakePoint(8.60361,18.635)];
    [path lineToPoint:NSMakePoint(6.27804,17.2917)];
    [path curveToPoint:NSMakePoint(5.88654,15.8289) controlPoint1:NSMakePoint(5.76698,16.9964) controlPoint2:NSMakePoint(5.59115,16.3423)];
    [path curveToPoint:NSMakePoint(7.3494,15.4374) controlPoint1:NSMakePoint(6.18192,15.3178) controlPoint2:NSMakePoint(6.83599,15.142)];
    [path lineToPoint:NSMakePoint(11.2808,17.7067)];
    [path curveToPoint:NSMakePoint(11.2808,19.5611) controlPoint1:NSMakePoint(11.9935,18.1193) controlPoint2:NSMakePoint(11.9935,19.1484)];
    [path lineToPoint:NSMakePoint(11.2808,19.5634)];
    [path closePath];
    [path moveToPoint:NSMakePoint(20.1822,19.7087)];
    [path lineToPoint:NSMakePoint(15.0176,19.7087)];
    [path curveToPoint:NSMakePoint(13.9463,18.6374) controlPoint1:NSMakePoint(14.4269,19.7087) controlPoint2:NSMakePoint(13.9463,19.2305)];
    [path curveToPoint:NSMakePoint(15.0176,17.566) controlPoint1:NSMakePoint(13.9463,18.0443) controlPoint2:NSMakePoint(14.4245,17.566)];
    [path lineToPoint:NSMakePoint(20.1822,17.566)];
    [path curveToPoint:NSMakePoint(21.2535,18.6374) controlPoint1:NSMakePoint(20.773,17.566) controlPoint2:NSMakePoint(21.2535,18.0443)];
    [path curveToPoint:NSMakePoint(20.1822,19.7087) controlPoint1:NSMakePoint(21.2535,19.2305) controlPoint2:NSMakePoint(20.7753,19.7087)];
    [path closePath];
    return path;
}
static BOOL usesGhosttyBrandGlyph(NSString *bundle) {return [bundle isKindOfClass:NSString.class]&&[bundle caseInsensitiveCompare:@"com.mitchellh.ghostty"]==NSOrderedSame;}
static NSImage *ghosttyBrandGlyph(void) {
    static NSImage *image;static dispatch_once_t once;dispatch_once(&once,^{image=[[NSImage alloc] initWithSize:NSMakeSize(27,32)];[image lockFocus];[NSColor.whiteColor setFill];[ghosttyBrandPath() fill];[image unlockFocus];image.template=YES;});return image;
}
