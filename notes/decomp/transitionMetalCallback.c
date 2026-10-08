
/* transitionMetalCallback(void*, std::shared_ptr<WS::Displays::Display>, void*, void*) */

void transitionMetalCallback
               (undefined8 param_1,undefined8 *param_2,undefined8 param_3,long *param_4)

{
  code *pcVar1;
  int iVar2;
  int iVar3;
  ulong uVar4;
  long *plVar5;
  ulong unaff_x30;
  long *plVar6;
  __shared_weak_count *this;
  
  if (((*(byte *)(param_4 + 0xb4) & 1) != 0) && (*(float *)(param_4 + 5) < 1.0)) {
    this = (__shared_weak_count *)param_2[1];
    plVar6 = (long *)*param_2;
    if (param_2[1] != 0) {
      plVar5 = (long *)(param_2[1] + 8);
      *plVar5 = *plVar5 + 1;
    }
    if (*(int *)((long)param_4 + 0x54) == 0) {
      uVar4 = 0xffffffff;
    }
    else {
      uVar4 = 0;
      plVar5 = param_4 + 0xb;
      do {
        iVar2 = (**(code **)(*(long *)*plVar5 + 0x28))();
        iVar3 = (**(code **)(*plVar6 + 0x28))(plVar6);
        if (iVar2 == iVar3) goto LAB_186f29d20;
        uVar4 = uVar4 + 1;
        plVar5 = plVar5 + 0x15;
      } while (uVar4 < *(uint *)((long)param_4 + 0x54));
      uVar4 = 0xffffffff;
    }
LAB_186f29d20:
    if (this != (__shared_weak_count *)0x0) {
      plVar6 = (long *)std::__shared_weak_count::__release_shared_abi_nqn210106_(this);
    }
    if (-1 < (int)uVar4) {
      (**(code **)(*param_4 + 0x18))(plVar6,param_4,uVar4,param_1);
      (**(code **)(*param_4 + 0x20))(param_4,uVar4,param_1);
      if (((unaff_x30 ^ unaff_x30 << 1) >> 0x3e & 1) != 0) {
                    /* WARNING: Does not return */
        pcVar1 = (code *)SoftwareBreakpoint(0xc471,0x186f29dc4);
        (*pcVar1)();
      }
                    /* WARNING: Could not recover jumptable at 0x000186f29dc8. Too many branches */
                    /* WARNING: Treating indirect jump as call */
      (**(code **)(*param_4 + 0x28))(param_4,uVar4,param_1);
      return;
    }
  }
  return;
}

