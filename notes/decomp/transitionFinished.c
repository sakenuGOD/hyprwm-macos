
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* transitionFinished(Transition*) */

void transitionFinished(Transition *param_1)

{
  Transition TVar1;
  long lVar2;
  undefined8 *puVar3;
  long lVar4;
  undefined8 *puVar5;
  undefined8 *puVar6;
  undefined4 local_2c;
  long local_28;
  
  local_28 = *_DAT_1e61cee48;
  global_transition_list = _x_list_remove(global_transition_list,param_1);
  if (global_transition_list != 0) {
    lVar4 = 0;
    lVar2 = global_transition_list;
    do {
      lVar4 = lVar4 + 1;
      lVar2 = *(long *)(lVar2 + 8);
    } while (lVar2 != 0);
    if (lVar4 != 0) goto LAB_186f29ab0;
  }
  _CGXSetZoomState(0x30,0,1);
LAB_186f29ab0:
  _deschedule_callback(&_gMainThreadQueue,transitionTimeoutCallback,param_1);
  TVar1 = param_1[0x5a0];
  if (((byte)TVar1 >> 1 & 1) != 0) {
    _deschedule_callback(&_gMainThreadQueue,transitionTimerCallback,param_1);
    TVar1 = param_1[0x5a0];
  }
  if ((((byte)TVar1 >> 2 & 1) != 0) && (metalCallbacks != (undefined8 *)0x0)) {
    puVar3 = metalCallbacks;
    puVar5 = &metalCallbacks;
    do {
      puVar6 = puVar3;
      if (((code *)puVar3[1] == transitionMetalCallback) && ((Transition *)puVar3[2] == param_1)) {
        *puVar5 = *puVar3;
        _free(puVar3);
        puVar6 = puVar5;
      }
      puVar3 = (undefined8 *)*puVar6;
      puVar5 = puVar6;
    } while (puVar3 != (undefined8 *)0x0);
  }
  lVar4 = Transition::CopyUpdateRegion(param_1);
  _CGXInvalidateDisplayShape(0,0,lVar4);
  if (lVar4 != 0) {
    _CFRelease(lVar4);
  }
  if (((byte)param_1[0x5a0] & 1) != 0) {
    _CGXSetZoomState(8,0,1);
  }
  if ((*(int *)(param_1 + 0xc) != 0) && (lVar4 = _CGXConnectionForConnectionID(), lVar4 != 0)) {
    remove_connection_death_notification
              ((CGXConnectionNotificationContext *)(lVar4 + 0x78),transitionConnectionDiedCallback,
               param_1);
    local_2c = *(undefined4 *)(param_1 + 8);
    _WSPostNotificationToConnection(lVar4,0x6a4,&local_2c,4);
  }
  _CGXScheduleUpdateAllDisplays(0,0);
  (**(code **)(*(long *)param_1 + 8))(param_1);
  if (*_DAT_1e61cee48 != local_28) {
                    /* WARNING: Subroutine does not return */
    ___stack_chk_fail();
  }
  return;
}

