/* каденция анимации: наш шаг (CGXSetWindowTransform3DList) vs вывод кадра на панель */
pid$target::CGXSetWindowTransform3DList:entry { printf("X %lld\n", timestamp/1000); }
pid$target::IOMobileFramebufferSwapEnd:entry  { printf("S %lld\n", timestamp/1000); }
tick-7s { exit(0); }
