
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* CGXInvokeTransition(Transition*, float) */

undefined8 CGXInvokeTransition(Transition *param_1,float param_2)

{
  long *plVar1;
  undefined8 uVar2;
  undefined8 *puVar3;
  double dVar4;
  undefined8 local_80;
  undefined8 local_78;
  code *local_70;
  undefined *puStack_68;
  undefined8 *local_60;
  undefined8 local_58;
  undefined8 *local_50;
  undefined8 local_48;
  undefined1 local_40;
  long local_38;
  
  local_38 = *_DAT_1e61cee48;
  local_60 = &local_58;
  local_58 = 0;
  local_48 = 0x2000000000;
  local_40 = 0;
  local_80 = _DAT_1e61cee28;
  local_78 = 0x42000000;
  local_70 = ____ZL19CGXInvokeTransitionP10Transitionf_block_invoke;
  puStack_68 = &__block_descriptor_tmp_7_11536;
  puVar3 = global_transition_list;
  local_50 = local_60;
  if (global_transition_list != (undefined8 *)0x0) {
    do {
      _apply_foreach_block((void *)*puVar3,&local_80);
      puVar3 = (undefined8 *)puVar3[1];
    } while (puVar3 != (undefined8 *)0x0);
    if (*(char *)(local_50 + 3) == '\x01') {
      transitionFinished(param_1);
      uVar2 = 0x3f6;
      goto LAB_186f29a0c;
    }
  }
  _CGXSetZoomState(0x38,1,1);
  dVar4 = (double)_SLSCurrentRealTime();
  for (plVar1 = metalCallbacks; plVar1 != (long *)0x0; plVar1 = (long *)*plVar1) {
    if (((code *)plVar1[1] == transitionMetalCallback) && ((Transition *)plVar1[2] == param_1))
    goto LAB_186f299cc;
  }
  plVar1 = (long *)_malloc_type_malloc(0x18,0xa00402214fce6);
  plVar1[1] = (long)transitionMetalCallback;
  plVar1[2] = (long)param_1;
  *plVar1 = (long)metalCallbacks;
  metalCallbacks = plVar1;
LAB_186f299cc:
  *(float *)(param_1 + 0x20) = (float)(dVar4 + -0.03333333333333333);
  *(float *)(param_1 + 0x24) = (float)(dVar4 + (double)param_2);
  param_1[0x5a0] = (Transition)((byte)param_1[0x5a0] | 0xd);
  transitionTimerCallback(param_1,dVar4);
  uVar2 = 0;
LAB_186f29a0c:
  __Block_object_dispose(&local_58,8);
  if (*_DAT_1e61cee48 != local_38) {
                    /* WARNING: Subroutine does not return */
    ___stack_chk_fail();
  }
  return uVar2;
}

