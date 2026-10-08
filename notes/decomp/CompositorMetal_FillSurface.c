
/* WARNING: Function: _objc_release replaced with injection: _objc_release_fixup */
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* CompositorMetal::FillSurface(__IOSurface*, CGRect, WSPixelFormat, float __vector(4)) */

ulong CompositorMetal::FillSurface
                (undefined8 param_1_00,undefined8 param_2,undefined8 param_3,undefined8 param_4,
                undefined8 param_5,long param_1,long param_7,undefined8 param_8)

{
  code *pcVar1;
  int iVar2;
  uint uVar3;
  ulong uVar4;
  ulong uVar5;
  ulong uVar6;
  undefined8 uVar7;
  long lVar8;
  undefined8 extraout_x1;
  ulong unaff_x30;
  undefined8 uVar9;
  undefined1 auVar10 [16];
  
  if (param_7 == 0) {
                    /* WARNING: Subroutine does not return */
    ___assert_rtn("FillSurface","CompositorMetal.mm",0xcc0,"surface != nullptr");
  }
  iVar2 = _CGRectIsNull();
  if (iVar2 == 0) {
    iVar2 = _CGRectIsInfinite(param_1_00,param_2,param_3,param_4);
    if (iVar2 != 0) {
                    /* WARNING: Subroutine does not return */
      ___assert_rtn("FillSurface","CompositorMetal.mm",0xcc2,"!CGRectIsInfinite(rect)");
    }
    uVar4 = _IOSurfaceGetWidth(param_7);
    uVar5 = _IOSurfaceGetHeight(param_7);
    uVar9 = _CGRectIntersection(param_1_00,param_2,param_3,param_4,0,0,(double)uVar4,(double)uVar5);
    uVar6 = _CGRectIsEmpty();
    if ((uVar6 & 1) == 0) {
      auVar10 = _WSPixelFormatGetMTLPixelFormat(param_8);
      auVar10 = _objc_msgSend_texture2DDescriptorWithPixelFormat_width_height_mipmapped_
                          (_DAT_1e6164238,auVar10._8_8_,auVar10._0_8_,uVar4,uVar5,0);
      uVar7 = auVar10._0_8_;
      _objc_msgSend_setUsage_(uVar7,auVar10._8_8_,4);
      auVar10 = _IOSurfaceGetProtectionOptions(param_7);
      _objc_msgSend_setProtectionOptions_(uVar7,auVar10._8_8_,auVar10._0_8_);
      lVar8 = _objc_msgSend_newTextureWithDescriptor_iosurface_plane_
                        (*(undefined8 *)(*(long *)(param_1 + 0x10) + 0x80),extraout_x1,uVar7,param_7
                         ,0);
      if ((*(char *)(*(long *)(param_1 + 0x10) + 0x1d0) != '\x01') || (uVar6 = 0, lVar8 != 0)) {
        uVar3 = _CGRectEqualToRect(0,0,(double)uVar4,(double)uVar5,uVar9,param_2,param_3,param_4);
        MetalContext::BeginUpdate(*(MetalContext **)(param_1 + 0x10));
        MetalContext::StartComposite(*(undefined8 *)(param_1 + 0x10),lVar8,uVar3 ^ 1);
        metal_clear_rect(0x3f800000,uVar9,param_2,param_3,param_4,param_5,
                         *(undefined8 *)(param_1 + 0x10));
        MetalContext::EndCurrentComposite(SUB81(*(undefined8 *)(param_1 + 0x10),0));
        MetalContext::EndUpdate(*(MetalContext **)(param_1 + 0x10),true,false);
        if (((unaff_x30 ^ unaff_x30 << 1) >> 0x3e & 1) != 0) {
                    /* WARNING: Does not return */
          pcVar1 = (code *)SoftwareBreakpoint(0xc471,0x186f3dd8c);
          (*pcVar1)();
        }
        return 0;
      }
    }
    return uVar6;
  }
                    /* WARNING: Subroutine does not return */
  ___assert_rtn("FillSurface","CompositorMetal.mm",0xcc1,"!CGRectIsNull(rect)");
}

