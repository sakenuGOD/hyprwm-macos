/* сторона WindowManager.app: кто строит и отправляет запрос resize (со стеками) */
objc$target:_WMClientResizeWindowRequest:-initWithRequestID*:entry {
    printf("%d WM %s %s\n", timestamp/1000000, probemod, probefunc); ustack(45);
}
objc$target:_WMClientResizeWindowRequest:-encodeWithCoder?:entry {
    printf("%d WM encode\n", timestamp/1000000); ustack(45);
}
objc$target:_WMResizeTargetGeometry:+targetGeometryWithFrame*:entry {
    printf("%d WM geometry frame=(%d,%d %dx%d)\n", timestamp/1000000, 0,0,0,0);
}
tick-25s { exit(0); }
