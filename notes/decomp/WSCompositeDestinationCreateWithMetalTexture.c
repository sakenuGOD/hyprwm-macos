
/* WARNING: Function: _objc_retain replaced with injection: _objc_retain_fixup */
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

long _WSCompositeDestinationCreateWithMetalTexture
               (double param_1,double param_2,double param_3,double param_4,float param_5,
               long param_6,long param_7,undefined8 param_8,undefined4 param_9,undefined8 param_10,
               undefined8 param_11,undefined8 param_12,undefined8 param_13)

{
  int iVar1;
  ulong uVar2;
  long lVar3;
  undefined8 uVar4;
  ulong uVar5;
  long lVar6;
  undefined1 uVar7;
  undefined4 uVar8;
  char *pcVar9;
  char *local_b8;
  undefined4 local_b0;
  char *local_ac;
  long local_98;
  
  local_98 = *_DAT_1e61cee48;
  if (param_7 == 0) {
                    /* WARNING: Subroutine does not return */
    ___assert_rtn("WSCompositeDestinationCreateWithMetalTexture","CompositeDestinationMetal.mm",0xac
                  ,"device != nil");
  }
  uVar2 = _objc_msgSend_isRemovable(param_7);
  if ((param_6 == 0) && ((uVar2 & 1) != 0)) {
    lVar6 = 0;
    goto LAB_186ee4aec;
  }
  if (param_6 == 0) {
                    /* WARNING: Subroutine does not return */
    ___assert_rtn("WSCompositeDestinationCreateWithMetalTexture","CompositeDestinationMetal.mm",0xb1
                  ,"texture != nil");
  }
  lVar3 = _objc_msgSend_pixelFormat(param_6);
  uVar2 = lVar3 - 0x226;
  uVar8 = 0x3f800000;
  if (uVar2 < 5) {
    uVar8 = *(undefined4 *)(&DAT_1871cfae8 + uVar2 * 4);
  }
  uVar4 = _objc_msgSend_acceleratorPort(param_7);
  lVar6 = _CompositeDestinationCreateCommon(uVar8,3,uVar4);
  if (0x6d < lVar3) {
    if (lVar3 < 0x226) {
      if ((lVar3 == 0x6e) || (lVar3 == 0x73)) {
        uVar8 = 0x20;
        goto LAB_186ee4938;
      }
      if (lVar3 != 0x7d) goto LAB_186ee48d0;
      uVar8 = 0x18;
    }
    else {
      if ((4 < uVar2) || ((1L << (uVar2 & 0x3f) & 0x15U) == 0)) goto LAB_186ee48d0;
LAB_186ee48b8:
      uVar8 = 0x10;
LAB_186ee4938:
      if (lVar3 < 0x73) {
        if (lVar3 < 0x5a) {
          uVar7 = 8;
          if ((lVar3 == 0x46) || (lVar3 == 0x50)) goto LAB_186ee4a48;
        }
        else {
          if ((lVar3 == 0x5a) || (lVar3 == 0x5e)) goto LAB_186ee4980;
          if (lVar3 == 0x6e) goto LAB_186ee4a38;
        }
LAB_186ee49b4:
        local_b8 = (char *)0x0;
        pcVar9 = "metal_format_get_bits_per_channel";
        iVar1 = _asprintf(&local_b8,"Unimplemented pixel format of %lu used in %s.");
        _SLSLogBreak(iVar1);
        uVar4 = _default_log;
        iVar1 = _os_log_type_enabled(_default_log,0x10);
        goto joined_r0x000186ee49ec;
      }
      if ((uVar2 < 5) && ((1L << (uVar2 & 0x3f) & 0x15U) != 0)) {
LAB_186ee4980:
        uVar7 = 10;
        goto LAB_186ee4a48;
      }
      if (lVar3 == 0x73) {
LAB_186ee4a38:
        uVar7 = 0x10;
        goto LAB_186ee4a48;
      }
      if (lVar3 != 0x7d) goto LAB_186ee49b4;
    }
    uVar7 = 0x20;
LAB_186ee4a48:
    if (param_5 <= 1.0) {
      param_5 = 0.0;
    }
    uVar2 = _objc_msgSend_width(param_6);
    uVar5 = _objc_msgSend_height(param_6);
    uVar4 = _CGColorSpaceRetain(param_8);
    *(undefined8 *)(lVar6 + 0x60) = uVar4;
    *(undefined4 *)(lVar6 + 0x40) = 0;
    *(undefined4 *)(lVar6 + 0x44) = uVar8;
    *(undefined1 *)(lVar6 + 0x54) = uVar7;
    *(undefined4 *)(lVar6 + 0x50) = param_9;
    *(int *)(lVar6 + 0x2c) = (int)param_1;
    *(int *)(lVar6 + 0x30) = (int)param_2;
    *(int *)(lVar6 + 0x34) = (int)(param_1 + param_3);
    *(int *)(lVar6 + 0x38) = (int)(param_2 + param_4);
    *(undefined4 *)(lVar6 + 0x3c) = 0;
    *(float *)(lVar6 + 0x48) = (float)uVar2;
    *(float *)(lVar6 + 0x4c) = (float)uVar5;
    uVar8 = NEON_ucvtf((int)param_5);
    *(undefined4 *)(lVar6 + 0x68) = uVar8;
    *(long *)(lVar6 + 0x88) = param_6;
    *(long *)(lVar6 + 0x90) = param_7;
    uVar4 = _objc_msgSend_protectionOptions(param_6);
    *(undefined8 *)(lVar6 + 0xb8) = uVar4;
    lVar3 = _objc_msgSend_iosurface(param_6);
    if (lVar3 != 0) {
      _objc_msgSend_iosurface(param_6);
      uVar4 = _CFRetain();
      *(undefined8 *)(lVar6 + 0x98) = uVar4;
    }
LAB_186ee4aec:
    if (*_DAT_1e61cee48 == local_98) {
      return lVar6;
    }
                    /* WARNING: Subroutine does not return */
    ___stack_chk_fail();
  }
  uVar8 = 10;
  if (lVar3 < 0x50) {
    if (lVar3 == 10) {
      uVar7 = 8;
      uVar8 = 0xe;
      goto LAB_186ee4a48;
    }
    if (lVar3 == 0x46) goto LAB_186ee4938;
  }
  else {
    if (lVar3 == 0x50) goto LAB_186ee4938;
    if ((lVar3 == 0x5a) || (lVar3 == 0x5e)) goto LAB_186ee48b8;
  }
LAB_186ee48d0:
  local_b8 = (char *)0x0;
  pcVar9 = "metal_format_get_bitmap_type";
  iVar1 = _asprintf(&local_b8,"Unimplemented pixel format of %lu used in %s.");
  _SLSLogBreak(iVar1);
  uVar4 = _default_log;
  iVar1 = _os_log_type_enabled(_default_log,0x10);
joined_r0x000186ee49ec:
  if (iVar1 != 0) {
    local_b0 = 0x8200102;
    local_ac = local_b8;
    __os_log_error_impl(&MACH_HEADER,uVar4,0x10,"%s",&local_b0,0xc,param_12,param_13,lVar3,pcVar9);
  }
  DAT_1ea5f73e8 = local_b8;
                    /* WARNING: Subroutine does not return */
  _abort();
}

