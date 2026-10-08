#!/usr/sbin/dtrace -xmangled -s
/* Read-only: сколько раз в секунду вызывается каждая стадия конвейера кадра WindowServer.
 * Запуск: sudo dtrace -xmangled -s frame_pipeline.d <pid WindowServer> <секунд>  */
#pragma D option quiet
#pragma D option mangled

pid$1:SkyLight:__ZN2WS7UpdaterL14UpdateDisplays*:entry            { @c["SL  UpdateDisplays"] = count(); }
pid$1:SkyLight:__ZN2WS7UpdaterL21prepare_coreanimation*:entry     { @c["SL  prepare_coreanimation"] = count(); }
pid$1:SkyLight:__ZL26generate_layers_for_windowP*:entry   { @c["SL  generate_layers_for_window"] = count(); }
pid$1:SkyLight:__ZN2WS7Updater14defenestrator3L30ca_prepare_begin*:entry  { @c["SL  defenestrator3::ca_prepare_begin_window_update"] = count(); }
pid$1:SkyLight:__ZN2WS7Updater14defenestrator2L30ca_prepare_begin*:entry    { @c["SL  defenestrator2::ca_prepare_begin_window_update"] = count(); }
pid$1:SkyLight:*SLCADisplay13render_update*:entry         { @c["SL  SLCADisplay::render_update"] = count(); }
pid$1:SkyLight:__ZN2WS7UpdaterL22finalize_coreanimation*:entry    { @c["SL  finalize_coreanimation"] = count(); }
pid$1:QuartzCore:*IOMFBServer21begin_skylight_update*:entry { @c["CA  IOMFBServer::begin_skylight_update"] = count(); }
pid$1:QuartzCore:__ZN2CA12WindowServer6Server13render_update*:entry { @c["CA  Server::render_update"] = count(); }
pid$1:QuartzCore:*Display14render_displayERNS_3OGL*:entry { @c["CA  Display::render_display"] = count(); }
pid$1:QuartzCore:*IOMFBDisplay14swap_set_layer*:entry     { @c["CA  IOMFBDisplay::swap_set_layer"] = count(); }
pid$1:QuartzCore:*IOMFBDisplay13finish_updateE*:entry     { @c["CA  IOMFBDisplay::finish_update"] = count(); }
pid$1:IOMobileFramebuffer:_IOMobileFramebufferSwapEnd:entry { @c["FB  IOMobileFramebufferSwapEnd"] = count(); }

tick-1sec { printf("---- t=%d\n", ++sec); printa("%-55s %@6d\n", @c); clear(@c); }
tick-1sec /sec >= $2/ { exit(0); }
