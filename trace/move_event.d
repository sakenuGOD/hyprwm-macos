/* путь события WindowMoved при серверном resize */
pid$target::WSPackagesScheduleCoalescedWindowMoveEventIfNeeded:entry { printf("SCHED win=%p\n", arg0); }
pid$target::WSWindowIsMoveEventPending:return { printf("  pending=%d\n", (int)arg1); }
pid$target::*window_id_post_coalesced_move_event_callback*:entry { printf("CB wid=%d\n", (int)arg0); }
pid$target::*window_post_move_event*:entry { printf("POST* %s\n", probefunc); }
tick-6s { exit(0); }
