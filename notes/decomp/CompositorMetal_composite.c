
/* WARNING: Function: _objc_release replaced with injection: _objc_release_fixup */
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* CompositorMetal::composite(WSCompositeSourceLayer*, WSCompositeDestination*, bool, bool) */

void __thiscall
CompositorMetal::composite
          (CompositorMetal *this,WSCompositeSourceLayer *param_1,WSCompositeDestination *param_2,
          bool param_3,bool param_4)

{
  uint uVar1;
  uint uVar2;
  int iVar3;
  int iVar4;
  int iVar5;
  int iVar6;
  undefined8 *puVar7;
  code *pcVar8;
  uint uVar9;
  uint uVar10;
  float fVar11;
  float fVar12;
  float fVar13;
  undefined8 *puVar14;
  undefined1 *puVar15;
  __shared_weak_count *p_Var16;
  undefined1 *puVar17;
  __shared_weak_count *p_Var18;
  undefined8 uVar19;
  long lVar20;
  long lVar21;
  ulong uVar22;
  Displays *this_00;
  ShaderComposer *this_01;
  MetalShader *this_02;
  objc_object *poVar23;
  long lVar24;
  MetalContext *pMVar25;
  objc_object *poVar26;
  float fVar27;
  undefined8 uVar28;
  float fVar29;
  undefined1 auVar30 [16];
  int *local_f8;
  undefined1 *local_f0;
  __shared_weak_count *p_Stack_e8;
  undefined1 *local_e0;
  __shared_weak_count *p_Stack_d8;
  undefined8 local_d0;
  long lStack_c8;
  undefined8 local_c0;
  ulong uStack_b8;
  undefined8 local_b0;
  ulong uStack_a8;
  undefined8 local_a0;
  long lStack_98;
  undefined8 local_90;
  undefined8 uStack_88;
  long local_80;
  
  local_80 = *_DAT_1e61cee48;
  uVar9 = *(uint *)(param_2 + 0x50);
  if ((uVar9 >> 0x1c & 1) == 0) {
    local_f8 = (int *)0x0;
    uVar19 = Compositor::prepare_layers((Compositor *)this,param_1,param_2,&local_f8);
    lVar20 = _CGRegionCreateEmptyRegion();
  }
  else {
    local_f8 = (int *)_shape_empty();
    uVar19 = Compositor::prepare_layers((Compositor *)this,param_1,param_2,&local_f8);
    lVar20 = _region_create_with_shape(local_f8);
  }
  if (param_4) {
    MetalContext::BeginUpdate(*(MetalContext **)(this + 0x10));
  }
  uVar10 = *(uint *)(param_2 + 0x50);
  uVar1 = 0;
  if ((uVar10 & 0x80400000) != 0x80000000) {
    uVar1 = uVar10 >> 0xd & 2;
  }
  if ((uVar10 & 0x40000) != 0) {
    uVar1 = 1;
  }
  uVar2 = 1;
  if ((uVar10 & 0x20000) != 0) {
    uVar2 = 2;
  }
  lVar21 = *(long *)(this + 0x10);
  *(byte *)(lVar21 + 0x17c) = (byte)(uVar10 >> 0x16) & 1;
  if ((uVar10 & 0x80400000) != 0x80000000) {
    uVar2 = uVar1;
  }
  uVar22 = MetalContext::StartComposite(lVar21,param_2,uVar2);
  lVar21 = lVar20;
  if ((uVar22 & 1) == 0) {
    pMVar25 = *(MetalContext **)(this + 0x10);
    pMVar25[0x17c] = (MetalContext)0x1;
  }
  else {
    if ((uVar9 >> 0x1c & 1) != 0) {
      uVar28 = *(undefined8 *)(param_2 + 0xf0);
      if ((*(long *)(param_2 + 0x100) != 0) && ((char)param_2[0x51] < '\0')) {
        lVar21 = _CGRegionCreateIntersectionWithRegion(lVar20);
        _CGRegionRelease(lVar20);
      }
      fVar27 = 1.0;
      if (*(float *)(param_2 + 0x68) != 0.0) {
        fVar27 = *(float *)(param_2 + 0x68);
      }
      _MetalClearRegion(fVar27,(int)uVar28,*(undefined8 *)(this + 0x10),lVar21);
    }
    this_00 = (Displays *)_MetalCompositeLayers(*(undefined8 *)(this + 0x10),uVar19,param_2);
    if (((byte)param_2[0x53] >> 5 & 1) != 0) {
      pMVar25 = *(MetalContext **)(this + 0x10);
      uVar22 = (*(long *)(pMVar25 + 0x28) + *(long *)(pMVar25 + 0x20)) - 1;
      lVar20 = *(long *)(*(long *)(pMVar25 + 8) + (uVar22 / 0x17) * 8);
      lVar24 = *(long *)(lVar20 + (uVar22 / 0x17) * -0xfd0 + uVar22 * 0xb0);
      poVar26 = *(objc_object **)(lVar20 + (uVar22 % 0x17) * 0xb0 + 8);
      iVar3 = *(int *)(lVar24 + 0x2c);
      iVar5 = *(int *)(lVar24 + 0x30);
      iVar4 = *(int *)(lVar24 + 0x34);
      iVar6 = *(int *)(lVar24 + 0x38);
      fVar27 = 1.0;
      if (*(float *)(lVar24 + 0x68) != 0.0) {
        fVar27 = *(float *)(lVar24 + 0x68);
      }
      this_01 = *(ShaderComposer **)(pMVar25 + 0xa8);
      if (get_basic_vertex_descriptor()::once != -1) {
        _dispatch_once(&get_basic_vertex_descriptor()::once,&__block_literal_global_5606);
      }
      this_02 = (MetalShader *)
                ShaderComposer::precompiled_shader
                          (this_01,10,(NSString *)&cfstringStruct_1eecf0818,
                           (NSString *)&cfstringStruct_1eecf09f8,
                           get_basic_vertex_descriptor()::descriptor);
      poVar23 = (objc_object *)MetalShader::CopyPipelineState(this_02,pMVar25,false,false);
      this_00 = (Displays *)0x0;
      if (poVar23 != (objc_object *)0x0) {
        MetalContext::SetPipelineState(pMVar25,poVar23);
        auVar30 = MetalContext::RenderEncoder(pMVar25);
        uVar22 = (*(long *)(pMVar25 + 0x28) + *(long *)(pMVar25 + 0x20)) - 1;
        _objc_msgSend_setVertexBytes_length_atIndex_
                  (auVar30._0_8_,auVar30._8_8_,
                   *(long *)(*(long *)(pMVar25 + 8) + (uVar22 / 0x17) * 8) + (uVar22 % 0x17) * 0xb0
                   + 0x30,0x40,1);
        MetalContext::SetRenderFragmentTexture(pMVar25,poVar26,1);
        fVar12 = (float)iVar5 * fVar27;
        fVar13 = (float)(iVar6 - iVar5) * fVar27;
        fVar11 = (float)iVar3 * fVar27;
        fVar27 = (float)(iVar4 - iVar3) * fVar27;
        fVar29 = fVar11 + fVar27;
        local_e0 = (undefined1 *)CONCAT44(fVar12,fVar11);
        local_d0 = CONCAT44(fVar13 + fVar12,fVar11);
        local_90 = CONCAT44(fVar13 + fVar12,fVar29);
        p_Stack_d8 = (__shared_weak_count *)0x0;
        lStack_c8 = (ulong)(uint)fVar13 << 0x20;
        uStack_b8 = (ulong)(uint)fVar27;
        local_b0 = CONCAT44(fVar12,fVar29);
        local_c0 = CONCAT44(fVar12,fVar29);
        uStack_88 = CONCAT44(fVar13,fVar27);
        uStack_a8 = uStack_b8;
        local_a0 = local_d0;
        lStack_98 = lStack_c8;
        ManagedBufferPool::EncodeVertexData(*(void **)(pMVar25 + 0x98),(ulong)&local_e0,0x60);
        auVar30 = MetalContext::RenderEncoder(pMVar25);
        this_00 = (Displays *)
                  _objc_msgSend_drawPrimitives_vertexStart_vertexCount_
                            (auVar30._0_8_,auVar30._8_8_,3,0,6);
      }
    }
    if (((byte)param_2[0x52] & 1) != 0) {
      uVar19 = *(undefined8 *)(this + 0x10);
      local_e0 = &SUB_aaaaaaaaaaaaaaaa;
      p_Stack_d8 = (__shared_weak_count *)&SUB_aaaaaaaaaaaaaaaa;
      WS::Displays::CAManager(this_00);
      WS::Displays::Manager::display_by_id((int)&local_e0);
      puVar15 = local_f0;
      p_Var16 = p_Stack_e8;
      puVar14 = metalCallbacks;
      puVar17 = local_e0;
      p_Var18 = p_Stack_d8;
      if (local_e0 != (undefined1 *)0x0) {
        while (p_Stack_e8 = p_Var18, local_f0 = puVar17, local_e0 = local_f0,
              p_Stack_d8 = p_Stack_e8, puVar14 != (undefined8 *)0x0) {
          puVar7 = (undefined8 *)*puVar14;
          pcVar8 = (code *)puVar14[1];
          if (p_Stack_e8 != (__shared_weak_count *)0x0) {
            *(long *)(p_Stack_e8 + 8) = *(long *)(p_Stack_e8 + 8) + 1;
          }
          (*pcVar8)(uVar19,&local_f0,0,puVar14[2]);
          puVar14 = puVar7;
          puVar15 = local_f0;
          p_Var16 = p_Stack_e8;
          puVar17 = local_e0;
          p_Var18 = p_Stack_d8;
          if (p_Stack_e8 != (__shared_weak_count *)0x0) {
            std::__shared_weak_count::__release_shared_abi_nqn210106_(p_Stack_e8);
            puVar15 = local_f0;
            p_Var16 = p_Stack_e8;
            puVar17 = local_e0;
            p_Var18 = p_Stack_d8;
          }
        }
      }
      p_Stack_e8 = p_Var16;
      local_f0 = puVar15;
      if (p_Stack_d8 != (__shared_weak_count *)0x0) {
        std::__shared_weak_count::__release_shared_abi_nqn210106_(p_Stack_d8);
      }
    }
    MetalContext::EndCurrentComposite(SUB81(*(undefined8 *)(this + 0x10),0));
    pMVar25 = *(MetalContext **)(this + 0x10);
    pMVar25[0x17c] = (MetalContext)0x1;
  }
  if (param_4) {
    MetalContext::EndUpdate(pMVar25,param_3,false);
  }
  if (lVar21 != 0) {
    _CFRelease(lVar21);
  }
  if (*_DAT_1e61cee48 != local_80) {
                    /* WARNING: Subroutine does not return */
    ___stack_chk_fail();
  }
  return;
}

