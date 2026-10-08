
/* WARNING: Removing unreachable block (ram,0x00018a94ecb0) */
/* WARNING: Removing unreachable block (ram,0x00018a94dd10) */
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* CA::WindowServer::IOMFBDisplay::finish_update(CA::Render::Update*, unsigned int, unsigned long
   long) */

ulong __thiscall
CA::WindowServer::IOMFBDisplay::finish_update
          (IOMFBDisplay *this,Update *param_1,uint param_2,ulonglong param_3)

{
  bool bVar1;
  bool bVar2;
  undefined4 *puVar3;
  IOMFBDisplay *pIVar4;
  small_vector_base<void(block_pointer)(__CFDictionary_const*)> *psVar5;
  uint uVar6;
  ushort uVar7;
  ushort uVar8;
  undefined1 auVar9 [16];
  undefined1 auVar10 [16];
  undefined1 auVar11 [16];
  double dVar12;
  uint *puVar13;
  bool bVar14;
  bool bVar15;
  bool bVar16;
  IOMFBDisplay IVar17;
  undefined1 uVar18;
  byte bVar19;
  byte bVar20;
  byte bVar21;
  int iVar22;
  uint uVar23;
  uint uVar24;
  int iVar25;
  uint uVar26;
  int iVar27;
  undefined4 uVar28;
  undefined8 uVar29;
  ulong uVar30;
  long lVar31;
  undefined8 uVar32;
  Context *pCVar33;
  LayerNode *pLVar34;
  undefined1 *puVar35;
  void *pvVar36;
  Shape *this_00;
  ulong uVar37;
  __IOSurface *p_Var38;
  long lVar39;
  Surface *pSVar40;
  undefined4 *puVar41;
  char *pcVar42;
  Rect *pRVar43;
  ushort uVar44;
  uint uVar45;
  float *pfVar46;
  IOMFBDisplay *pIVar47;
  CASharedEvent *pCVar48;
  long *plVar49;
  long lVar50;
  undefined8 uVar51;
  ulong uVar52;
  undefined8 uVar53;
  long *plVar54;
  float fVar55;
  double dVar56;
  double extraout_d0_00;
  undefined1 auVar58 [16];
  undefined1 auVar59 [16];
  undefined1 auVar60 [16];
  undefined1 auVar61 [16];
  double extraout_d0;
  double extraout_var;
  undefined1 auVar62 [16];
  undefined1 auVar63 [16];
  undefined8 uVar57;
  undefined1 auVar64 [16];
  undefined1 auVar65 [16];
  undefined1 auVar66 [16];
  undefined1 auVar67 [16];
  undefined1 auVar68 [16];
  undefined1 extraout_q0 [16];
  double extraout_var_00;
  float fVar69;
  undefined1 auVar70 [16];
  undefined1 auVar71 [16];
  undefined1 auVar72 [16];
  undefined1 auVar73 [16];
  undefined1 auVar74 [16];
  undefined1 auVar75 [16];
  undefined1 auVar76 [16];
  undefined1 auVar77 [16];
  undefined1 auVar78 [16];
  undefined1 auVar79 [16];
  int iVar80;
  int iVar81;
  double dVar82;
  double dVar83;
  undefined8 *puVar84;
  double dVar85;
  undefined1 *puVar86;
  ulong local_238;
  undefined8 local_1d0;
  undefined8 uStack_1c8;
  undefined8 uStack_1c0;
  undefined8 uStack_1b8;
  bool local_1a1;
  undefined8 local_1a0;
  undefined1 *puStack_198;
  undefined1 *local_190;
  undefined8 *puStack_188;
  undefined1 auStack_180 [32];
  undefined8 local_160;
  undefined8 uStack_158;
  undefined1 *local_150;
  undefined8 *puStack_148;
  undefined8 uStack_140;
  undefined4 uStack_138;
  undefined4 local_134;
  undefined4 uStack_130;
  undefined4 uStack_12c;
  undefined4 uStack_128;
  undefined4 uStack_124;
  undefined8 local_120;
  undefined8 uStack_118;
  undefined8 uStack_110;
  undefined8 uStack_108;
  undefined8 local_100;
  undefined8 uStack_f8;
  undefined8 uStack_f0;
  undefined8 uStack_e8;
  undefined8 local_e0;
  undefined8 uStack_d8;
  undefined8 uStack_d0;
  undefined8 uStack_c8;
  undefined4 *local_c0;
  undefined8 uStack_b8;
  undefined8 local_b0;
  undefined8 uStack_a8;
  long local_a0;
  
  local_a0 = *_DAT_1e61cee48;
  pIVar4 = this + 0x6398;
  pcVar42 = (char *)param_3;
  uVar29 = _objc_autoreleasePoolPush();
  bVar20 = DAT_1ecfeca92;
  this[0x6448] = (IOMFBDisplay)0x0;
  uVar30 = (**(code **)(*(long *)this + 0x18))(this);
  if ((uVar30 & 1) == 0) {
    uVar45 = 0;
    param_2 = param_2 & 0xfffffffb;
  }
  else {
    uVar45 = (param_2 & 4) >> 2;
    if ((((byte)this[(ulong)*(uint *)(this + 0x6628) * 0x30 + 0x66a0] >> 5 & 1) == 0) ||
       (*(int *)(this + (ulong)*(uint *)(this + 0x6628) * 0x30 + 0x6690) == 0 ||
        ((bVar20 & 1) != 0 || uVar45 != 0))) {
      *(undefined4 *)(this + 0x6440) = 0;
      if ((bVar20 & 1) != 0 || uVar45 != 0) goto LAB_18a94d4dc;
      uVar45 = 0;
    }
    else if (*(uint *)(this + 0x6440) < 5) {
      *(uint *)(this + 0x6440) = *(uint *)(this + 0x6440) + 1;
LAB_18a94d4dc:
      local_150 = (undefined1 *)CONCAT44(local_150._4_4_,0x79ecf7b);
      uStack_158 = DAT_18a996b18._8_8_;
      local_160 = (__IOSurface *)DAT_18a996b18;
      iVar22 = _MGIsDeviceOneOfType(&local_160);
      if (iVar22 == 0) {
        uVar45 = 1;
      }
      else {
        uVar45 = (uint)((*(ushort *)(this + 0x2a0) & 0x1c00) == 0);
      }
    }
    else {
      uVar45 = 0;
      *(undefined4 *)(this + 0x6440) = 0;
    }
    if (DAT_1ecfecb17 == '\x01') {
      if (x_log_get_windowserver()::once != -1) {
        _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
      }
      uVar51 = x_log_get_windowserver()::log;
      iVar22 = _os_log_type_enabled(x_log_get_windowserver()::log,0);
      if (iVar22 != 0) {
        local_160 = (__IOSurface *)CONCAT44(uVar45,0x4000100);
        pcVar42 = "finish_update vsync_off enabled:%d";
        __os_log_impl(&MACH_HEADER,uVar51,0,"finish_update vsync_off enabled:%d",&local_160,8);
      }
    }
  }
  uVar51 = *(undefined8 *)(param_1 + 0x108);
  if (((uint)uVar51 >> 0x15 & 1) == 0) {
    (**(code **)(*(long *)this + 0x200))(this);
  }
  if ((*(long *)(this + 0x67f8) != 0) && ((*(byte *)(*(long *)(this + 0x67f8) + 0x14c) & 1) != 0)) {
    delete_detached_layer(this);
  }
  if (this[0x72f6] == (IOMFBDisplay)0x1) {
LAB_18a94d628:
    iVar22 = update_secure_indicators(this,param_1,0.0);
    local_238 = 0x40000000000;
    if (iVar22 == 0) {
      local_238 = 0;
    }
    goto LAB_18a94f4cc;
  }
  if (((byte)param_1[0x4eb] >> 1 & 1) == 0) {
    if ((*(long *)(this + 0x290) == 0) ||
       (iVar22 = Display::is_enabled_for_vsync_render((Display *)this), iVar22 == 0))
    goto LAB_18a94d5b4;
    if (((byte)param_1[0x4eb] >> 1 & 1) != 0) goto LAB_18a94d5a8;
  }
  else {
LAB_18a94d5a8:
    uVar30 = Display::is_enabled_for_replay_render_with_mode((Display *)this);
    if ((uVar30 & 1) == 0) {
LAB_18a94d5b4:
      uVar30 = (**(code **)(*(long *)this + 0x8b0))(this);
      if ((uVar30 & 1) == 0) goto LAB_18a94d628;
    }
  }
  if ((param_2 >> 3 & 1) == 0) {
    if ((this[0x730f] == (IOMFBDisplay)0x1) &&
       (fVar55 = (float)(**(code **)(*(long *)this + 0x3c8))(this), fVar55 == 0.0)) {
      bVar14 = *(double *)(this + 0x6c58) != 0.0;
    }
    else {
      bVar14 = false;
    }
    if (this[0x72f5] == (IOMFBDisplay)0x1) {
      this[0x72f6] = (IOMFBDisplay)0x1;
      if ((*(int *)(this + 0x6450) == 0) ||
         (iVar22 = _IORegistryEntrySetCFProperty
                             (*(int *)(this + 0x6450),&cfstringStruct_1eeee78e0,*_DAT_1e6150eb8),
         iVar22 != 0)) {
        if (x_log_get_windowserver()::once != -1) {
          _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
        }
        uVar57 = x_log_get_windowserver()::log;
        iVar22 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
        if (iVar22 != 0) {
          local_160 = (__IOSurface *)((ulong)local_160 & 0xffffffffffff0000);
          pcVar42 = "Failed to enable skip spinner!";
          __os_log_error_impl(&MACH_HEADER,uVar57,0x10,"Failed to enable skip spinner!",&local_160,2
                             );
        }
      }
    }
    iVar22 = (**(code **)(*(long *)this + 0x640))(this);
    if (iVar22 == 0) {
      uVar18 = false;
    }
    else {
      uVar18 = Display::Mode::is_hdr((Mode *)(this + 0x290));
    }
    iVar22 = (**(code **)(*(long *)this + 0x60))(this);
    if (iVar22 == 0) {
      bVar20 = 0;
    }
    else {
      lVar31 = std::
               __hash_table<std::__hash_value_type<CA::WindowServer::Display::Mode,CA::WindowServer::IOMFBDisplay::ModeInfo>,std::__unordered_map_hasher<CA::WindowServer::Display::Mode,std::pair<CA::WindowServer::Display::Mode_const,CA::WindowServer::IOMFBDisplay::ModeInfo>,CA::WindowServer::IOMFBDisplay::ModeHash,std::equal_to<CA::WindowServer::Display::Mode>,true>,std::__unordered_map_equal<CA::WindowServer::Display::Mode,std::pair<CA::WindowServer::Display::Mode_const,CA::WindowServer::IOMFBDisplay::ModeInfo>,std::equal_to<CA::WindowServer::Display::Mode>,CA::WindowServer::IOMFBDisplay::ModeHash,true>,std::allocator<std::pair<CA::WindowServer::Display::Mode_const,CA::WindowServer::IOMFBDisplay::ModeInfo>>>
               ::
               __emplace_unique_key_args<CA::WindowServer::Display::Mode,std::piecewise_construct_t_const&,std::tuple<CA::WindowServer::Display::Mode_const&>,std::tuple<>>
                         ((Mode *)(this + 0x6998),*(piecewise_construct_t **)(this + 0x290),
                          (tuple *)(this + 0x290),(tuple *)pcVar42);
      bVar20 = *(byte *)(lVar31 + 0x2c);
    }
    uVar57 = *(undefined8 *)(this + 0x98);
    uVar53 = *(undefined8 *)(this + 0xa0);
    uVar23 = _pthread_mutex_lock((pthread_mutex_t *)(this + 0x6638));
    uVar30 = (ulong)uVar23;
    if (*(int *)(this + 0x662c) == 0) {
      uVar23 = 0;
      bVar15 = false;
    }
    else {
      iVar22 = 0;
      uVar23 = 0;
      uVar52 = 0;
      pIVar47 = this + 0x66a0;
      do {
        IVar17 = *pIVar47;
        if (((*(int *)(pIVar47 + -0x28) == 0) || (*(uint *)(pIVar47 + -0x10) == 0)) ||
           (uVar30 = IOMobileFramebuffer::swap_wait
                               ((IOMobileFramebuffer *)(this + 0x6458),*(uint *)(pIVar47 + -0x10),
                                0x80000000), (int)uVar30 == 0)) {
          iVar22 = iVar22 + 1;
        }
        uVar23 = uVar23 | ((byte)IVar17 & 0x20) >> 5;
        uVar52 = uVar52 + 1;
        pIVar47 = pIVar47 + 0x30;
      } while (uVar52 < *(uint *)(this + 0x662c));
      bVar15 = iVar22 == 1;
    }
    plVar54 = *(long **)(this + 0x67f8);
    if ((plVar54 == (long *)0x0) || ((*(byte *)((long)plVar54 + 0x14c) & 1) != 0)) {
      bVar16 = false;
LAB_18a94d850:
      bVar1 = bVar16;
      if (DAT_1ecfecadb == '\x01') {
        (**(code **)(*(long *)this + 0x318))(this);
        dVar82 = extraout_d0_00;
        dVar83 = extraout_var_00;
      }
      else {
        if (!bVar15) {
          dVar82 = 0.0;
          dVar83 = 0.0;
          iVar22 = _CAGetDebugValueWithDefault(uVar30);
          if ((iVar22 == 0) || (*(double *)(param_1 + 0x40) <= *(double *)(this + 0x6858))) {
            bVar15 = false;
          }
          else {
            dVar56 = *(double *)(this + 0x72c8);
            bVar15 = 0.0 < dVar56;
            bVar1 = false;
            if (dVar56 <= 0.0) {
              bVar1 = bVar16;
            }
            dVar82 = 0.0;
            if (0.0 < dVar56) {
              dVar82 = dVar56;
            }
            dVar83 = 0.0;
            if ((0.0 < dVar56) && (bVar16)) {
              bVar15 = (*(uint *)((long)plVar54 + 0x2c) & 0xfffdffff) == 0;
              if (!bVar15) {
                dVar56 = 0.0;
              }
              dVar82 = dVar56;
              dVar83 = 0.0;
              bVar1 = true;
            }
          }
          goto LAB_18a94d8fc;
        }
        dVar82 = *(double *)(this + 0x72c8);
        dVar83 = 0.0;
      }
      bVar15 = true;
    }
    else if ((((*(uint *)(this + 0x280) >> 4 & 1) == 0) ||
             ((*(byte *)((long)plVar54 + 0x35) >> 5 & 1) == 0)) || (*(int *)(this + 0x6c28) != 0)) {
      if (-1 < (char)param_1[0x4e9]) {
        bVar16 = true;
        goto LAB_18a94d850;
      }
      bVar15 = false;
      dVar82 = 0.0;
      dVar83 = dVar82;
      bVar1 = true;
    }
    else {
      (**(code **)(*(long *)this + 0x318))(this);
      bVar15 = true;
      dVar82 = extraout_d0;
      dVar83 = extraout_var;
      bVar1 = true;
    }
LAB_18a94d8fc:
    dVar56 = (double)(**(code **)(*(long *)this + 0x328))(this);
    dVar56 = dVar56 * 0.125;
    if ((param_2 & 0x10) != 0) {
      dVar56 = 0.0;
    }
    dVar12 = (*(double *)(param_1 + 0x40) - dVar56) + dVar82;
    if (!bVar15) {
      dVar12 = *(double *)(param_1 + 0x40) - dVar56;
    }
    dVar85 = *(double *)(param_1 + 0x70) + 0.0001;
    if (*(double *)(param_1 + 0x70) + 0.0001 <= dVar12) {
      dVar85 = dVar12;
    }
    if (dVar82 != *(double *)(this + 0x72c8)) {
      *(double *)(this + 0x72c8) = dVar82;
      auVar59._8_8_ = dVar83;
      auVar59._0_8_ = dVar82;
      uVar32 = _CAHostTimeWithTime(auVar59);
      _kdebug_trace(0x31ca02c8,uVar32,0,0,0);
    }
    auVar78._8_8_ = dVar83;
    auVar78._0_8_ = dVar82;
    uVar32 = _CAHostTimeWithTime(auVar78);
    _kdebug_trace(0x31ca02c4,uVar32,0,0,0);
    *(double *)(this + 0x72d0) = dVar82;
    _os_unfair_lock_lock(this + 0x6800);
    initialize_timings(this);
    lVar31 = *(long *)(this + 0x6810);
    if (lVar31 != 0) {
      auVar58._8_8_ = dVar83;
      auVar58._0_8_ = dVar82;
      uVar32 = _CAHostTimeWithTime(auVar58);
      *(undefined8 *)(lVar31 + 8) = uVar32;
    }
    _os_unfair_lock_unlock(this + 0x6800);
    bVar16 = (bool)(bVar1 ^ 1);
    if (plVar54 == (long *)0x0) {
      bVar16 = true;
    }
    if (((!bVar16) && ((Handle *)*plVar54 != (Handle *)0x0)) &&
       (pCVar33 = (Context *)CA::Render::Handle::lock_context((Handle *)*plVar54),
       pCVar33 != (Context *)0x0)) {
      uVar30 = 0x80000000000;
      if (!bVar15) {
        uVar30 = 0;
      }
      *(ulong *)(*plVar54 + 0x78) = *(ulong *)(*plVar54 + 0x78) & 0xfffff7ffffffffff | uVar30;
      pLVar34 = *(LayerNode **)(pCVar33 + 0x178);
      if (pLVar34 != (LayerNode *)0x0) {
        LOAcquire();
        iVar22 = *(int *)(pLVar34 + 0x10);
        *(int *)(pLVar34 + 0x10) = iVar22 + -1;
        LORelease();
        if (iVar22 == 1) {
          CA::Render::LayerNode::delete_node(pLVar34);
        }
        *(undefined8 *)(pCVar33 + 0x178) = 0;
      }
      CA::Render::Handle::unlock_context(pCVar33);
    }
    dVar83 = 0.0;
    if (this[0x730e] == (IOMFBDisplay)0x1) {
      auVar59 = _CACurrentMediaTimeDelta();
      dVar83 = auVar59._0_8_;
    }
    dVar85 = dVar83 + dVar85;
    uVar32 = 0;
    uVar30 = (**(code **)(*(long *)this + 0x878))(this);
    if (((uVar30 & 1) == 0) && (iVar22 = (**(code **)(*(long *)this + 0x830))(this), iVar22 == 0)) {
      local_238 = 0;
    }
    else {
      iVar22 = update_secure_indicators(this,param_1,dVar85);
      local_238 = 0x40000000000;
      if (iVar22 == 0) {
        local_238 = 0;
      }
    }
    uVar6 = *(uint *)(this + 0x6624);
    pIVar47 = this + (ulong)uVar6 * 0x30 + 0x6690;
    if ((*(int *)pIVar47 == 0) &&
       (iVar22 = _IOMobileFramebufferSwapBegin(*(undefined8 *)(this + 0x6470),pIVar47), iVar22 == 0)
       ) {
      this[0x6468] = (IOMFBDisplay)0x0;
    }
    *(undefined4 *)(this + 0x6710) = 0;
    this[(ulong)uVar6 * 0x30 + 0x66a0] =
         (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0x1f);
    *(double *)(param_1 + 0x3f8) = dVar85;
    auVar60._8_8_ = uVar32;
    auVar60._0_8_ = dVar85;
    local_160 = (__IOSurface *)_CAHostTimeWithTime(auVar60);
    local_1a0._0_4_ = 1;
    _IOMobileFramebufferSwapSetTimestamps(*(undefined8 *)(this + 0x6458),&local_1a0,&local_160,1);
    auVar61._0_8_ = *(double *)(this + 0x69e0) + dVar83;
    auVar61._8_8_ = 0;
    local_160 = (__IOSurface *)_CAHostTimeWithTime(auVar61);
    local_1a0 = (undefined1 *)CONCAT44(local_1a0._4_4_,2);
    _IOMobileFramebufferSwapSetTimestamps(*(undefined8 *)(this + 0x6458),&local_1a0,&local_160,1);
    if ((((byte)this[0x72e7] & 1) != 0) ||
       ((uint)(byte)this[0x72d9] != (*(uint *)(this + 0x280) >> 2 & 1))) {
      _IOMobileFramebufferSwapSetBackgroundColor
                (ZEXT816(0),ZEXT816(0),ZEXT816(0),*(undefined8 *)(this + 0x6458));
    }
    this[0x72d9] = (IOMFBDisplay)((byte)(*(uint *)(this + 0x280) >> 2) & 1);
    if (this[0x7317] == (IOMFBDisplay)0x1) {
      IVar17 = (IOMFBDisplay)0x3;
      if (this[0x72e2] != (IOMFBDisplay)0x0) {
        IVar17 = (IOMFBDisplay)0x4;
      }
      if (this[0x72e5] == (IOMFBDisplay)0x0) {
        IVar17 = this[0x72e2];
      }
      _IOMobileFramebufferSwapSetColorRemapMode(*(undefined8 *)(this + 0x6458),IVar17);
      this[0x7317] = (IOMFBDisplay)0x0;
    }
    if (this[0x63d5] == (IOMFBDisplay)0x1) {
      this[0x63d5] = (IOMFBDisplay)0x0;
    }
    if (bVar14) {
      iVar22 = (**(code **)(*(long *)this + 0x770))(this);
      if (iVar22 == 0) {
LAB_18a94dc94:
        local_120 = 0;
        uStack_138 = 0;
        local_134 = 0;
        uStack_140 = 0;
        uStack_128 = 0;
        uStack_124 = 0;
        uStack_130 = 0;
        uStack_12c = 0;
        uStack_158 = (undefined8 *)0x0;
        local_160 = (__IOSurface *)0x0;
        puStack_148 = (undefined8 *)0x0;
        local_150 = (undefined1 *)0x0;
        _IOMobileFramebufferSetMatrix(*(undefined8 *)(this + 0x6458),9,&local_160);
      }
      else {
        if (CADeviceUseHarmonyXYZD50::once != -1) {
          _dispatch_once(&CADeviceUseHarmonyXYZD50::once,&__block_literal_global_177);
        }
        if (CADeviceUseHarmonyXYZD50::use_d50_xyz != '\x01') goto LAB_18a94dc94;
        uStack_12c = 0;
        uStack_128 = 0;
        uStack_130 = 0;
        puStack_148 = (undefined8 *)0x0;
        local_150 = (undefined1 *)0x0;
        uStack_138 = 0;
        local_134 = 0;
        uStack_140 = 0;
        uStack_158 = (undefined8 *)0x0;
        local_160 = (__IOSurface *)0x0;
        swap_set_icc_matrix(this,6,*(undefined4 *)(this + 0x18),0,&local_160);
      }
      this[0x6ae8] = (IOMFBDisplay)0x0;
    }
    update_contrast_enhancer(this,*(double *)(param_1 + 0x40));
    update_blend_display_color_spaces(this);
    update_system_gamma(this);
    update_blackpoint_adaptation(this);
    update_gamma_adjustment(this);
    update_user_adjustment(this);
    update_apple_look(this);
    uVar30 = (**(code **)(*(long *)this + 0x640))(*(long *)this + 0x640,this);
    if ((((uVar30 & 1) == 0) && (this[0x72ea] == (IOMFBDisplay)0x1)) &&
       (iVar22 = set_framebuffer_ax_matrix(this), iVar22 != 0)) {
      if (x_log_get_windowserver()::once != -1) {
        _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
      }
      uVar32 = x_log_get_windowserver()::log;
      iVar22 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
      if (iVar22 != 0) {
        local_160 = (__IOSurface *)((ulong)local_160 & 0xffffffffffff0000);
        __os_log_error_impl(&MACH_HEADER,uVar32,0x10,
                            "IOMFB was not able to set accessibility matrix.\n",&local_160,2);
      }
    }
    if (::initialized != -1) {
      _dispatch_once_f(&::initialized,(void *)0x0,init_debug);
    }
    if ((int)DAT_1ecfec730 != 0) {
      _pthread_mutex_lock((pthread_mutex_t *)&_ctx_lock);
      puVar35 = (undefined1 *)get_ctx(this);
      if (puVar35 != (undefined1 *)0x0) {
        _os_unfair_lock_lock(&CA::Render::FlattenManager::flattened_lock);
        if (CA::Render::FlattenManager::flattened_cache != (uint *)0x0) {
          if (::initialized != -1) {
            _dispatch_once_f(&::initialized,(void *)0x0,init_debug);
          }
          puVar13 = CA::Render::FlattenManager::flattened_cache;
          lVar31 = 0;
          local_1a0 = (undefined1 *)CONCAT44(local_1a0._4_4_,(int)DAT_1ecfec730);
          puStack_148 = &local_160;
          uStack_158 = &local_1a0;
          local_160 = (__IOSurface *)&DAT_1eeec6000;
          uVar26 = *CA::Render::FlattenManager::flattened_cache;
          local_150 = puVar35;
          do {
            for (plVar49 = *(long **)(*(long *)(puVar13 + 4) + lVar31 * 8); plVar49 != (long *)0x0;
                plVar49 = (long *)*plVar49) {
                    /* WARNING: Read-only address (ram,0x00018a996b18) is written */
              X::HashTable<unsigned_int,CA::Render::FlattenedCacheEntry*>::
              foreach(std::function<void(unsigned_int,CA::Render::FlattenedCacheEntry*)>)::
              {lambda(void*,void*,void*)#1}::__invoke
                        ((void *)plVar49[2],(void *)plVar49[3],&local_160);
            }
                    /* WARNING: Read-only address (ram,0x00018a996b18) is written */
            lVar31 = lVar31 + 1;
          } while (lVar31 != 1L << ((ulong)uVar26 & 0x3f));
          std::__function::__value_func<void(unsigned_int,CA::Render::FlattenedCacheEntry*)>::
          ~__value_func_abi_nqn210106_
                    ((__value_func<void(unsigned_int,CA::Render::FlattenedCacheEntry*)> *)&local_160
                    );
        }
        _os_unfair_lock_unlock(&CA::Render::FlattenManager::flattened_lock);
      }
      if (0.0 < DAT_1ecfec730) {
        DAT_1ecfec730 = DAT_1ecfec730 + -1.0;
      }
      _pthread_mutex_unlock((pthread_mutex_t *)&_ctx_lock);
      if (::initialized != -1) {
        _dispatch_once_f(&::initialized,(void *)0x0,init_debug);
      }
    }
    if (((int)DAT_1ecfec734 != 0) && (0.0 < DAT_1ecfec734)) {
      DAT_1ecfec734 = DAT_1ecfec734 + -1.0;
    }
    if (bVar1) {
      if (((uVar18 & 1) == 0) &&
         ((((byte)this[0x72da] & 1) != 0 ||
          (((byte)this[0x72e7] & 1) != 0 || (uVar45 != 0 || uVar23 != 0))))) {
        uVar23 = *(uint *)(plVar54 + 6);
        IVar17 = (IOMFBDisplay)0x1;
        if ((*(int *)(this + 0x6520) != 2) && (*(int *)(this + 0x6520) != 4)) {
          IVar17 = this[0x72e7];
        }
        if (uVar45 == 0) {
          bVar19 = 0x20;
        }
        else {
          pSVar40 = (Surface *)plVar54[3];
          uVar26 = *(uint *)(pSVar40 + 0x40);
          uVar24 = vsync_off_pixel_format(this,uVar26);
          if (uVar24 != uVar26) {
            bVar19 = 0x20;
            if ((uVar26 != 0x77343061) || ((*(ulong *)(pSVar40 + 0x104) >> 0x22 & 1) == 0))
            goto LAB_18a94e09c;
            bVar19 = (**(code **)(*(long *)this + 0x10))(this);
            IVar17 = (IOMFBDisplay)(bVar19 | (byte)IVar17);
          }
          if ((((byte)IVar17 & 1) == 0) &&
             (iVar22 = supports_vsync_off_mem_region(pSVar40), iVar22 != 0)) {
            uVar23 = uVar23 | 0x80;
            this[(ulong)uVar6 * 0x30 + 0x66a0] =
                 (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] | 0x20);
            bVar19 = 0x30;
          }
          else {
            bVar19 = 0x20;
          }
        }
LAB_18a94e09c:
        uVar32 = (**(code **)(*(long *)plVar54[3] + 0xa8))();
        local_160 = (__IOSurface *)plVar54[0x1d];
        uStack_158 = (undefined8 *)plVar54[0x1e];
        local_150 = (undefined1 *)plVar54[0x1f];
        puStack_148 = (undefined8 *)plVar54[0x20];
        dVar83 = (double)plVar54[0x21];
        puVar86 = (undefined1 *)plVar54[0x22];
        puVar35 = (undefined1 *)plVar54[0x23];
        puVar84 = (undefined8 *)plVar54[0x24];
        local_1a0 = (undefined1 *)dVar83;
        puStack_198 = puVar86;
        local_190 = puVar35;
        puStack_188 = puVar84;
        if (::initialized != -1) {
          _dispatch_once_f(&::initialized,(void *)0x0,init_debug);
        }
        if (((int)DAT_1ecfec71c != 0) &&
           (pvVar36 = (void *)_CAIOSurfaceWriteToFileWithSuffix(uVar32,"detached-src"),
           pvVar36 != (void *)0x0)) {
          if (0.0 < DAT_1ecfec71c) {
            DAT_1ecfec71c = DAT_1ecfec71c + -1.0;
          }
          _free(pvVar36);
        }
        local_1a1 = false;
        swap_set_layer((Update *)this,(uint)(byte)this[0x6989],(Surface *)plVar54[3],
                       (Rect *)&local_160,(Rect *)&local_1a0,uVar23,
                       *(uint *)(this + (ulong)uVar6 * 0x30 + 0x6690),*(uint *)(param_1 + 0xe8),
                       false,&local_1a1);
        this[(ulong)uVar6 * 0x30 + 0x66a0] =
             (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0xbf | local_1a1 << 6);
        uStack_b8 = DAT_18a996b18._8_8_;
        local_c0 = (undefined4 *)DAT_18a996b18;
        local_b0 = CONCAT44(local_b0._4_4_,0x79ecf7b);
        iVar22 = _MGIsDeviceOneOfType(&local_c0);
        if ((iVar22 != 0) && (((*(ushort *)(this + 0x2a0) & 0x1c00) == 0 & uVar45) == 1)) {
          this[0x6448] = (IOMFBDisplay)0x1;
        }
        if (CADeviceSupportsMedina::once != -1) {
          _dispatch_once(&CADeviceSupportsMedina::once,&__block_literal_global_220);
        }
        if ((CADeviceSupportsMedina::medina == '\x01') &&
           (lVar31 = *(long *)(this + 0x6498), lVar31 != 0)) {
          if (*(long *)(lVar31 + 0x80) == 0) {
            lVar50 = sil_mgr_instance((void *)0x0,0xffffffff);
            *(long *)(lVar31 + 0x80) = lVar50;
            if (lVar50 == 0) goto LAB_18a94e244;
          }
          if ((byte)this[0x64a0] - 3 < 2) {
            pfVar46 = (float *)(*(long *)(this + 0x6498) + 0x10c);
            lVar31 = 4;
            do {
              if (((uint)pfVar46[-3] < 3) && (0.0 <= *pfVar46)) {
                bVar16 = true;
                goto LAB_18a94e248;
              }
              pfVar46 = pfVar46 + 7;
              lVar31 = lVar31 + -1;
            } while (lVar31 != 0);
          }
        }
LAB_18a94e244:
        bVar16 = false;
LAB_18a94e248:
        if (this[0x6989] == (IOMFBDisplay)0x2) {
          if ((*(byte *)((long)plVar54 + 0x2d) & 0x20) == 0) {
            bVar16 = true;
          }
          if (bVar16) goto LAB_18a94e268;
          if (*(long *)(this + 0x290) == -1) {
            uVar23 = *(uint *)(this + 0x58);
            uVar26 = *(uint *)(this + 0x5c);
          }
          else {
            uVar26 = (uint)*(long *)(this + 0x290);
            uVar23 = uVar26 & 0x3fff;
            uVar26 = uVar26 >> 0xe & 0x3fff;
          }
          fVar55 = 0.01;
          if ((((byte)this[0x72db] & 1) == 0) &&
             (fVar55 = 0.01, (*(ushort *)(this + 0x2a0) & 0x1c00) != 0x1000)) {
            if (CADeviceHasNotch::once != -1) {
              _dispatch_once(&CADeviceHasNotch::once,&__block_literal_global_199);
            }
            fVar55 = 0.05;
            if (CADeviceHasNotch::has_notch == '\0') {
              fVar55 = 0.01;
            }
          }
          if ((double)((float)(int)uVar23 * 0.01) <=
              ABS(((double)puVar35 + dVar83 * 2.0) - (double)(int)uVar23)) {
            bVar16 = false;
          }
          else {
            if ((double)(fVar55 * (float)(int)uVar26) <=
                ABS(((double)puVar84 + (double)puVar86 * 2.0) - (double)(int)uVar26))
            goto LAB_18a94e268;
            if ((double)((float)(int)uVar23 * 0.01) <= dVar83) {
              bVar16 = (double)puVar86 < (double)(fVar55 * (float)(int)uVar26);
            }
            else {
              bVar16 = true;
            }
          }
        }
        else {
LAB_18a94e268:
          bVar16 = false;
        }
        set_trinity_hint(this,bVar16);
        uVar23 = *(uint *)(plVar54[3] + 0x38);
        if ((double)puVar35 != (double)uVar23) {
          Display::add_display_trace_log
                    ((Display *)this,1,uVar23,(long)(double)puVar35,
                     *(undefined4 *)(plVar54[3] + 0x3c),(long)(double)puVar84);
        }
        iVar22 = *(int *)(this + (ulong)(byte)this[0x6989] * 4 + 0x6c3c);
        iVar27 = _IOSurfaceGetID(uVar32);
        uVar52 = (ulong)(byte)this[0x6989];
        if (iVar22 == iVar27) {
          uVar30 = 0;
        }
        else {
          uVar30 = *(ulong *)(&DAT_18a996ae0 + uVar52 * 8);
          uVar28 = _IOSurfaceGetID(uVar32);
          uVar52 = (ulong)(byte)this[0x6989];
          *(undefined4 *)(this + uVar52 * 4 + 0x6c3c) = uVar28;
        }
        uVar23 = 2;
        if ((int)uVar52 != 0) {
          uVar23 = 0;
        }
        uStack_b8 = 0;
        local_c0 = (undefined4 *)0x0;
        uStack_a8 = 0;
        local_b0 = 0;
        uStack_1c8 = 0;
        local_1d0 = 0;
        uStack_1b8 = 0;
        uStack_1c0 = 0;
        swap_set_layer((Update *)this,uVar23,(Surface *)0x0,(Rect *)&local_c0,(Rect *)&local_1d0,0,
                       *(uint *)pIVar47,*(uint *)(param_1 + 0xe8),false,(bool *)0x0);
      }
      else {
        bVar19 = 0;
        uVar30 = 0;
      }
      lVar31 = plVar54[3];
      *(short *)(lVar31 + 0x104) = (short)*(undefined4 *)(lVar31 + 0x104) + 1;
      *(long *)(this + (ulong)uVar6 * 0x30 + 0x6688) = lVar31;
      if ((*(byte *)((long)plVar54 + 0x14c) >> 2 & 1) != 0) {
        this[(ulong)uVar6 * 0x30 + 0x66a0] =
             (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] | 2);
      }
    }
    else {
      set_trinity_hint(this,false);
      if ((((byte)this[0x72da] & 1) != 0) ||
         (((byte)this[0x72e7] & 1) != 0 || (uVar45 != 0 || uVar23 != 0))) {
        if (*(int *)(this + 0x6520) != 3) {
          uStack_158 = (undefined8 *)0x0;
          local_160 = (__IOSurface *)0x0;
          puStack_148 = (undefined8 *)0x0;
          local_150 = (undefined1 *)0x0;
          puStack_198 = (undefined1 *)0x0;
          local_1a0 = (undefined1 *)0x0;
          puStack_188 = (undefined8 *)0x0;
          local_190 = (undefined1 *)0x0;
          swap_set_layer((Update *)this,1,(Surface *)0x0,(Rect *)&local_160,(Rect *)&local_1a0,0,
                         *(uint *)pIVar47,*(uint *)(param_1 + 0xe8),false,(bool *)0x0);
        }
        uStack_158 = (undefined8 *)0x0;
        local_160 = (__IOSurface *)0x0;
        puStack_148 = (undefined8 *)0x0;
        local_150 = (undefined1 *)0x0;
        puStack_198 = (undefined1 *)0x0;
        local_1a0 = (undefined1 *)0x0;
        puStack_188 = (undefined8 *)0x0;
        local_190 = (undefined1 *)0x0;
        swap_set_layer((Update *)this,2,(Surface *)0x0,(Rect *)&local_160,(Rect *)&local_1a0,0,
                       *(uint *)pIVar47,*(uint *)(param_1 + 0xe8),false,(bool *)0x0);
      }
      bVar19 = 0;
      uVar30 = 0;
    }
    if (this[0x732b] == (IOMFBDisplay)0x1) {
      _IOMobileFramebufferSwapSetParams(*(undefined8 *)(this + 0x6458),0,0,4);
    }
    uVar23 = *(uint *)(this + 0x6520);
    if (uVar23 < 2) {
      uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
      if (((((uVar52 & 1) == 0) && (((byte)this[0x389] & 1) == 0)) &&
          (((byte)*pIVar4 >> 1 & 1) != 0)) && (this[0x6551] == (IOMFBDisplay)0x1))
      goto LAB_18a94e3a8;
    }
    else if ((uVar23 == 2) || (uVar23 == 4)) {
LAB_18a94e3a8:
      uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
      if ((uVar52 & 1) == 0) {
        uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
        if (((uVar52 & 1) == 0) && (((byte)this[0x389] & 1) == 0)) {
          bVar16 = ((byte)*pIVar4 & 2) == 0;
        }
        else {
          bVar16 = true;
        }
        if (((bool)(bVar1 & bVar16)) &&
           (((uVar52 = (**(code **)(*(long *)this + 0x6b8))(this), (uVar52 & 1) != 0 ||
             ((DAT_1ecfecad1 & 1) != 0)) || (this[0x6620] != (IOMFBDisplay)0x1))))
        goto LAB_18a94e4f8;
      }
      local_1a0 = (undefined1 *)((ulong)local_1a0 & 0xffffffffffffff00);
      iVar22 = set_cursor_surface(this,false,(uint *)pIVar47,(bool *)&local_1a0);
      if ((iVar22 == 0) || (((ulong)local_1a0 & 1) != 0)) {
        *(undefined4 *)(this + 0x6520) = 0;
        if (x_log_get_cursor()::once != -1) {
          _dispatch_once(&x_log_get_cursor()::once,&__block_literal_global_24204);
        }
        uVar32 = x_log_get_cursor()::log;
        iVar22 = _os_log_type_enabled(x_log_get_cursor()::log,0x10);
        if (iVar22 != 0) {
          local_160 = (__IOSurface *)((ulong)local_160 & 0xffffffffffff0000);
          __os_log_error_impl(&MACH_HEADER,uVar32,0x10,"Cursor disabled: failed set_cursor_surface",
                              &local_160,2);
        }
        this[0x72e7] = (IOMFBDisplay)0x1;
      }
    }
LAB_18a94e4f8:
    uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
    if ((((uVar52 & 1) == 0) && (((byte)this[0x389] & 1) == 0)) && (((byte)*pIVar4 >> 1 & 1) != 0))
    {
      IVar17 = (IOMFBDisplay)(*(int *)(this + 0x6520) == 4);
    }
    else {
      IVar17 = (IOMFBDisplay)0x0;
    }
    this[0x6551] = IVar17;
    uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
    if ((((uVar52 & 1) == 0) && (((byte)this[0x389] & 1) == 0)) && (((byte)*pIVar4 >> 1 & 1) != 0))
    {
      uStack_158 = (undefined8 *)0x0;
      local_160 = (__IOSurface *)0x0;
      puStack_148 = (undefined8 *)0x0;
      local_150 = (undefined1 *)0x0;
      puStack_198 = (undefined1 *)0x0;
      local_1a0 = (undefined1 *)0x0;
      puStack_188 = (undefined8 *)0x0;
      local_190 = (undefined1 *)0x0;
      swap_set_layer((Update *)this,(uint)(byte)this[0x698b],(Surface *)0x0,(Rect *)&local_160,
                     (Rect *)&local_1a0,0,*(uint *)pIVar47,*(uint *)(param_1 + 0xe8),false,
                     (bool *)0x0);
    }
    lVar31 = *(long *)(this + (ulong)uVar6 * 0x30 + 0x6680);
    *(undefined4 *)(lVar31 + 0xc) = *(undefined4 *)(this + (ulong)uVar6 * 0x30 + 0x6690);
    if ((options_are_visual & 1) == 0) {
      if ((!bVar1) || ((*(byte *)((long)plVar54 + 0x2d) >> 4 & 1) == 0)) {
        if ((*(long *)(lVar31 + 0x20) == 0) ||
           ((*(ulong *)(param_1 + 0x108) & 0x600000) != 0x400000)) goto LAB_18a94e710;
        if ((bVar1) || (uVar52 = *(ulong *)(lVar31 + 0x10), uVar52 == 0)) {
LAB_18a94e6e8:
          if ((plVar54 == (long *)0x0) || ((*(byte *)((long)plVar54 + 0x2d) & 1) == 0))
          goto LAB_18a94e710;
        }
        else if ((uVar52 & 1) == 0) {
          if (*(int *)(uVar52 + 4) != 6) goto LAB_18a94e6e8;
        }
        else if (uVar52 != 1) goto LAB_18a94e6e8;
      }
LAB_18a94e6f8:
      *(byte *)(lVar31 + 0x44) = *(byte *)(lVar31 + 0x44) | 4;
      bVar19 = bVar19 | 8;
    }
    else if ((bVar1) &&
            (((((*(byte *)((long)plVar54 + 0x2d) >> 4 & 1) != 0 &&
               (uVar52 = (**(code **)(*(long *)this + 0x6b8))(this), (uVar52 & 1) == 0)) &&
              (((byte)this[0x389] & 1) != 0)) &&
             ((((byte)this[0x6540] & 1) == 0 &&
              (((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] >> 1 & 1) != 0)))))) goto LAB_18a94e6f8;
LAB_18a94e710:
    this_00 = *(Shape **)(lVar31 + 0x10);
    if (this_00 == (Shape *)0x0) {
LAB_18a94e738:
      *(undefined8 *)(lVar31 + 0x10) = 1;
    }
    else if (((ulong)this_00 & 1) == 0) {
      if (*(int *)(this_00 + 4) != 6) {
LAB_18a94e734:
        Shape::unref(this_00);
        goto LAB_18a94e738;
      }
    }
    else if (this_00 != (Shape *)0x1) goto LAB_18a94e734;
    *(byte *)(lVar31 + 0x44) = *(byte *)(lVar31 + 0x44) & 0xf7;
    if (*(long **)(lVar31 + 0x20) != (long *)0x0) {
      (**(code **)(**(long **)(lVar31 + 0x20) + 0xd8))();
    }
    if (*(long **)(lVar31 + 0x28) != (long *)0x0) {
      (**(code **)(**(long **)(lVar31 + 0x28) + 0xd8))();
    }
    if (((uVar18 & 1) == 0) &&
       (((*(long *)(lVar31 + 0x20) == 0 && (*(long *)(lVar31 + 0x28) == 0)) ||
        ((*(byte *)(lVar31 + 0x44) >> 2 & 1) != 0)))) {
LAB_18a94e7e4:
      uVar52 = (**(code **)(*(long *)this + 0x6b8))(this);
      if (((uVar52 & 1) != 0) || (*(uint *)(this + 0x6520) < 2)) {
        uStack_158 = (undefined8 *)0x0;
        local_160 = (__IOSurface *)0x0;
        puStack_148 = (undefined8 *)0x0;
        local_150 = (undefined1 *)0x0;
        puStack_198 = (undefined1 *)0x0;
        local_1a0 = (undefined1 *)0x0;
        puStack_188 = (undefined8 *)0x0;
        local_190 = (undefined1 *)0x0;
        swap_set_layer((Update *)this,(uint)(byte)this[0x6988],(Surface *)0x0,(Rect *)&local_160,
                       (Rect *)&local_1a0,0,*(uint *)pIVar47,*(uint *)(param_1 + 0xe8),false,
                       (bool *)0x0);
      }
      bVar16 = false;
    }
    else {
      if (bVar1) {
        local_150 = (undefined1 *)CONCAT44(local_150._4_4_,0x79ecf7b);
        uStack_158 = DAT_18a996b18._8_8_;
        local_160 = (__IOSurface *)DAT_18a996b18;
        uVar52 = _MGIsDeviceOneOfType(&local_160);
        if ((uVar52 & 1) != 0) goto LAB_18a94e7e4;
      }
      iVar80 = (int)uVar53;
      iVar81 = (int)((ulong)uVar53 >> 0x20);
      iVar22 = (int)uVar57;
      iVar27 = (int)((ulong)uVar57 >> 0x20);
      if (((*(byte *)(lVar31 + 0x44) >> 1 & 1) == 0) ||
         (((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] >> 4 & 1) != 0)) {
        bVar16 = false;
      }
      else {
        *(byte *)(lVar31 + 0x44) = *(byte *)(lVar31 + 0x44) & 0xfd;
        plVar54 = (long *)current_page_surface
                                    (this,true,false,false,false,*(ulonglong *)(param_1 + 0x118),
                                     SUB41(uVar45,0),false);
        if (plVar54 == (long *)0x0) {
LAB_18a94e950:
          bVar16 = false;
        }
        else if (this[0x72ec] == (IOMFBDisplay)0x1) {
          uVar52 = (**(code **)(*plVar54 + 0xe8))(plVar54);
          uVar37 = (**(code **)(*(long *)this + 0x5a0))(this);
          if ((uVar52 & (uVar37 ^ 0xffffffffffffffff)) == 0) {
            if (this[0x72ec] != (IOMFBDisplay)0x1) goto LAB_18a94f1f4;
            uVar52 = CONCAT44((int)((ulong)*(undefined8 *)(this + 0xa0) >> 0x20) + 1,
                              (int)*(undefined8 *)(this + 0xa0) + 1) & 0xfffffffefffffffe;
            auVar62._0_8_ = (long)(int)uVar52;
            auVar62._8_8_ = (long)(int)(uVar52 >> 0x20);
            auVar59 = NEON_scvtf(auVar62,8);
            local_160 = (__IOSurface *)0x0;
            auVar63._0_8_ = *(ulong *)(param_1 + 0x40);
            auVar63._8_8_ = 0;
            auVar72._8_8_ = 0;
            auVar72._0_8_ = auVar59._8_8_;
            iVar25 = IOMobileFramebuffer::get_wireless_surface_options
                               (auVar63,auVar59,auVar72,*(undefined8 *)(this + 0x6458),&local_160,
                                DAT_1ecfeca56 == '\x01');
            if (iVar25 != 0) goto LAB_18a94e950;
            pSVar40 = (Surface *)IOSurface::wrap_buffer((Display *)this,local_160,false,false);
            *(Surface **)(lVar31 + 0x20) = pSVar40;
            bVar16 = pSVar40 != (Surface *)0x0;
            if (pSVar40 == (Surface *)0x0 || (uVar18 & 1) != 0) goto LAB_18a94e960;
            goto LAB_18a94f528;
          }
          bVar16 = false;
        }
        else {
LAB_18a94f1f4:
          pSVar40 = (Surface *)
                    current_page_surface
                              (this,false,true,false,(bool)uVar18,*(ulonglong *)(param_1 + 0x118),
                               SUB41(uVar45,0),false);
          bVar16 = false;
          if (pSVar40 != (Surface *)0x0 && (uVar18 & 1) == 0) {
LAB_18a94f528:
            uVar23 = 0x400;
            if (((byte)this[0x388] & 0x40) != 0) {
              uVar23 = 0x600;
            }
            uVar23 = (uint)((ulong)*(undefined8 *)(param_1 + 0x4e8) >> 0x24) & 0x20000 | uVar23;
            if (this[0x72ec] == (IOMFBDisplay)0x1) {
              uVar26 = Display::Mode::is_hdr((Mode *)(this + 0x290));
              if (((byte)this[0x63d7] & 1) != 0) goto LAB_18a94f64c;
              if (uVar26 == 0) goto LAB_18a94f770;
              uVar26 = 1;
LAB_18a94f6d8:
              uStack_d8 = 0;
              local_e0 = 0;
              uStack_c8 = 0;
              uStack_d0 = 0;
              uStack_f8 = 0;
              local_100 = 0;
              uStack_e8 = 0;
              uStack_f0 = 0;
              uStack_118 = 0;
              local_120 = 0;
              uStack_108 = 0;
              uStack_110 = 0;
              uStack_138 = 0;
              local_134 = 0;
              uStack_140 = 0;
              uStack_128 = 0;
              uStack_124 = 0;
              uStack_130 = 0;
              uStack_12c = 0;
              uStack_158 = (undefined8 *)0x0;
              local_160 = (__IOSurface *)0x0;
              puStack_148 = (undefined8 *)0x0;
              local_150 = (undefined1 *)0x0;
              fVar55 = (float)Display::display_attributes();
              if ((*(ushort *)(param_1 + 0x109) & 0x380) == 0) {
                if (uVar26 != 0) {
                  iVar25 = (**(code **)(*plVar54 + 0x88))(plVar54);
                  fVar55 = extraout_q0._0_4_;
                  if (iVar25 != 0) goto LAB_18a94f710;
                }
                bVar21 = copy_surface((Surface *)this,pSVar40,(uint)plVar54,uVar23,(Rect *)0x0,
                                      (Rect *)0x0,(ScalerStatistics *)0x0,fVar55);
              }
              else {
LAB_18a94f710:
                uVar57 = (**(code **)(*(long *)pSVar40 + 0xe8))(pSVar40);
                bVar21 = (**(code **)(*(long *)this + 0x290))
                                   (this,pSVar40,plVar54,&local_160,param_1,uVar23,uVar57,1);
              }
              this[(ulong)uVar6 * 0x30 + 0x66a0] =
                   (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0xfe | bVar21);
            }
            else {
              if (this[0x63d7] == (IOMFBDisplay)0x1) {
                uVar26 = 0;
LAB_18a94f64c:
                if ((*(int *)(param_1 + 0x1a4) - 2U < 4) || ((uVar26 & 1) != 0)) goto LAB_18a94f6d8;
              }
LAB_18a94f770:
              auVar59 = ZEXT816(0);
              uStack_158 = (undefined8 *)0x0;
              local_160 = (__IOSurface *)0x0;
              puStack_148 = (undefined8 *)0x0;
              local_150 = (undefined1 *)0x0;
              if ((bVar20 & 1) == 0) {
                pRVar43 = (Rect *)0x0;
              }
              else {
                iVar25 = iVar80;
                if (iVar80 <= iVar81) {
                  iVar25 = iVar81;
                }
                auVar68._0_4_ = -(uint)(0x3ffffffe < iVar25);
                auVar68._4_4_ = auVar68._0_4_;
                auVar68._8_4_ = auVar68._0_4_;
                auVar68._12_4_ = auVar68._0_4_;
                auVar70._0_8_ = (long)iVar22;
                auVar70._8_8_ = (long)iVar27;
                auVar74._8_8_ = 0xffdfffffffffffff;
                auVar74._0_8_ = 0xffdfffffffffffff;
                auVar59 = NEON_scvtf(auVar70,8);
                auVar59 = auVar59 ^ (auVar59 ^ auVar74) & auVar68;
                bVar2 = 0x3ffffffe < iVar25;
                auVar71._0_8_ = (long)iVar80;
                auVar71._8_8_ = (long)iVar81;
                auVar78 = NEON_scvtf(auVar71,8);
                auVar79._8_8_ = 0x7fefffffffffffff;
                auVar79._0_8_ = 0x7fefffffffffffff;
                auVar75._0_8_ = -(ulong)((long)((ulong)CONCAT14(bVar2,(uint)bVar2) << 0x3f) < 0);
                auVar75._8_8_ = -(ulong)((long)((ulong)bVar2 << 0x3f) < 0);
                auVar78 = auVar78 ^ (auVar78 ^ auVar79) & auVar75;
                uStack_158 = auVar59._8_8_;
                local_160 = auVar59._0_8_;
                puStack_148 = auVar78._8_8_;
                local_150 = auVar78._0_8_;
                uVar23 = uVar23 | 0x10000;
                pRVar43 = (Rect *)&local_160;
              }
              bVar21 = copy_surface((Surface *)this,pSVar40,(uint)plVar54,uVar23,(Rect *)0x0,pRVar43
                                    ,(ScalerStatistics *)0x0,auVar59._0_4_);
              this[(ulong)uVar6 * 0x30 + 0x66a0] =
                   (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0xfe | bVar21);
            }
          }
        }
      }
LAB_18a94e960:
      if ((*(byte *)(lVar31 + 0x44) & 1) != 0) {
        this[(ulong)uVar6 * 0x30 + 0x66a0] =
             (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] | 1);
      }
      if ((((!bVar1) || (((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] >> 4 & 1) == 0)) ||
          (this[0x72e7] == (IOMFBDisplay)0x1)) &&
         (pSVar40 = *(Surface **)(lVar31 + 0x20), pSVar40 != (Surface *)0x0)) {
        local_150 = (undefined1 *)NEON_ucvtf((ulong)*(uint *)(pSVar40 + 0x38));
        puStack_148 = (undefined8 *)NEON_ucvtf((ulong)*(uint *)(pSVar40 + 0x3c));
        local_160 = (__IOSurface *)0x0;
        uStack_158 = (undefined8 *)0x0;
        iVar25 = iVar80;
        if (iVar80 <= iVar81) {
          iVar25 = iVar81;
        }
        auVar73._0_4_ = -(uint)(0x3ffffffe < iVar25);
        auVar73._4_4_ = auVar73._0_4_;
        auVar73._8_4_ = auVar73._0_4_;
        auVar73._12_4_ = auVar73._0_4_;
        auVar76._0_8_ = (long)iVar22;
        auVar76._8_8_ = (long)iVar27;
        auVar59 = NEON_scvtf(auVar76,8);
        auVar9._8_8_ = 0xffdfffffffffffff;
        auVar9._0_8_ = 0xffdfffffffffffff;
        auVar59 = auVar59 ^ (auVar59 ^ auVar9) & auVar73;
        bVar1 = 0x3ffffffe < iVar25;
        auVar77._0_8_ = (long)iVar80;
        auVar77._8_8_ = (long)iVar81;
        auVar78 = NEON_scvtf(auVar77,8);
        auVar11._8_4_ = 0xffffffff;
        auVar11._0_8_ = 0x7fefffffffffffff;
        auVar11._12_4_ = 0x7fefffff;
        auVar10._8_8_ = -(ulong)((long)((ulong)bVar1 << 0x3f) < 0);
        auVar10._0_8_ = -(ulong)((long)((ulong)CONCAT14(bVar1,(uint)bVar1) << 0x3f) < 0);
        auVar78 = auVar78 ^ (auVar78 ^ auVar11) & auVar10;
        puStack_198 = auVar59._8_8_;
        local_1a0 = auVar59._0_8_;
        local_190 = auVar78._0_8_;
        puStack_188 = auVar78._8_8_;
        if ((bVar20 & 1) != 0) {
          local_1a0 = (undefined1 *)0x0;
          puStack_198 = (undefined1 *)0x0;
          local_190 = local_150;
          puStack_188 = puStack_148;
        }
        uVar23 = (uint)(byte)this[0x72f6] << 5;
        IVar17 = (IOMFBDisplay)0x1;
        if ((*(int *)(this + 0x6520) != 2) && (*(int *)(this + 0x6520) != 4)) {
          IVar17 = this[0x72e7];
        }
        if (uVar45 != 0) {
          uVar45 = *(uint *)(pSVar40 + 0x40);
          uVar26 = vsync_off_pixel_format(this,uVar45);
          if (uVar26 != uVar45) {
            if ((uVar45 != 0x77343061) || ((*(ulong *)(pSVar40 + 0x104) >> 0x22 & 1) == 0))
            goto LAB_18a94ead8;
            bVar20 = (**(code **)(*(long *)this + 0x10))(this);
            IVar17 = (IOMFBDisplay)(bVar20 | (byte)IVar17);
          }
          if ((((byte)IVar17 & 1) == 0) &&
             (iVar22 = supports_vsync_off_mem_region(pSVar40), iVar22 != 0)) {
            bVar19 = bVar19 | 0x10;
            uVar23 = uVar23 | 0x80;
            this[(ulong)uVar6 * 0x30 + 0x66a0] =
                 (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] | 0x20);
          }
        }
LAB_18a94ead8:
        local_c0 = (undefined4 *)((ulong)local_c0 & 0xffffffffffffff00);
        swap_set_layer((Update *)this,(uint)(byte)this[0x6988],pSVar40,(Rect *)&local_160,
                       (Rect *)&local_1a0,uVar23,*(uint *)(this + (ulong)uVar6 * 0x30 + 0x6690),
                       *(uint *)(param_1 + 0xe8),false,(bool *)&local_c0);
        this[(ulong)uVar6 * 0x30 + 0x66a0] =
             (IOMFBDisplay)
             ((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0x7f | (char)local_c0._0_1_ << 7);
        if (::initialized != -1) {
          _dispatch_once_f(&::initialized,(void *)0x0,init_debug);
        }
        if ((int)DAT_1ecfec720 != 0) {
          p_Var38 = (__IOSurface *)(**(code **)(*(long *)pSVar40 + 0xa8))(pSVar40);
          dump_framebuffer(this,p_Var38);
        }
        iVar22 = *(int *)(this + (ulong)(byte)this[0x6988] * 4 + 0x6c3c);
        (**(code **)(*(long *)pSVar40 + 0xa8))(pSVar40);
        iVar27 = _IOSurfaceGetID();
        if (iVar22 != iVar27) {
          uVar30 = *(ulong *)(&layer_value + (ulong)(byte)this[0x6988] * 8) | uVar30;
          (**(code **)(*(long *)pSVar40 + 0xa8))(pSVar40);
          uVar28 = _IOSurfaceGetID();
          *(undefined4 *)(this + (ulong)(byte)this[0x6988] * 4 + 0x6c3c) = uVar28;
        }
      }
    }
    _mach_absolute_time();
    uVar57 = _CATimeWithHostTime();
    *(undefined8 *)(param_1 + 0x78) = uVar57;
    *(ulong *)(param_1 + 0x470) = uVar30;
    auVar64._0_8_ = *(ulong *)(param_1 + 0x70);
    auVar64._8_8_ = 0;
    local_160 = (__IOSurface *)_CAHostTimeWithTime(auVar64);
    local_1a0._0_4_ = 4;
    _IOMobileFramebufferSwapSetTimestamps(*(undefined8 *)(this + 0x6458),&local_1a0,&local_160,1);
    auVar65._0_8_ = *(ulong *)(param_1 + 0x78);
    auVar65._8_8_ = 0;
    local_160 = (__IOSurface *)_CAHostTimeWithTime(auVar65);
    local_1a0 = (undefined1 *)CONCAT44(local_1a0._4_4_,5);
    _IOMobileFramebufferSwapSetTimestamps(*(undefined8 *)(this + 0x6458),&local_1a0,&local_160,1);
    update_contrast_preservation_allowed(this);
    if (!bVar14) {
      swap_brightness(this);
    }
    swap_display_edr_factor(this);
    swap_display_headroom_used(this,param_1);
    swap_hdr_metadata(this,param_1);
    iVar22 = (**(code **)(*(long *)this + 0x8e0))(*(long *)this + 0x8e0,this);
    if (iVar22 != 0) {
      if (*(double *)(param_1 + 0x298) != 0.0) {
        local_1a0 = (undefined1 *)CONCAT44((int)(*(double *)(param_1 + 0x298) * 65536.0),1);
        puStack_198 = (undefined1 *)((ulong)puStack_198 & 0xffffffff00000000);
        iVar22 = _IOMobileFramebufferSwapSetParams(*(undefined8 *)(this + 0x6458),&local_1a0,0xc,1);
        if (iVar22 != 0) {
          if (x_log_get_windowserver()::once != -1) {
            _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
          }
          uVar57 = x_log_get_windowserver()::log;
          iVar27 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
          if (iVar27 != 0) {
            local_160 = (__IOSurface *)CONCAT44(*(undefined4 *)(this + 0x18),0x4000200);
            uStack_158._0_6_ = CONCAT42(iVar22,0x400);
            __os_log_error_impl(&MACH_HEADER,uVar57,0x10,
                                "display %u swap_adaptive_sync_metadata returned error %x\n",
                                &local_160,0xe);
          }
        }
      }
      uVar57 = *(undefined8 *)(param_1 + 0x2a0);
      uVar53 = *(undefined8 *)(param_1 + 0x2a8);
      uVar30 = *(ulong *)(param_1 + 0x4e8);
      if (init_iomfb()::once != -1) {
        _dispatch_once(&init_iomfb()::once,&__block_literal_global_15482);
      }
      if (((iomfb_swap_set_lfc_timestamps_f != (code *)0x0) &&
          (iVar22 = (*iomfb_swap_set_lfc_timestamps_f)
                              (*(undefined8 *)(this + 0x6458),uVar57,uVar53,uVar30 >> 9 & 1),
          iVar22 != -0x1ffffd39)) && (iVar22 != 0)) {
        if (x_log_get_windowserver()::once != -1) {
          _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
        }
        uVar57 = x_log_get_windowserver()::log;
        iVar27 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
        if (iVar27 != 0) {
          local_160 = (__IOSurface *)CONCAT44(*(undefined4 *)(this + 0x18),0x4000200);
          uStack_158._0_6_ = CONCAT42(iVar22,0x400);
          __os_log_error_impl(&MACH_HEADER,uVar57,0x10,
                              "display %u swap_set_lfc_timestamps returned error %x\n",&local_160,
                              0xe);
        }
      }
    }
    bVar20 = bVar19 | 4;
    if (((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 1) == 0) {
      bVar20 = bVar19;
    }
    _IOMobileFramebufferSwapDebugInfo
              (*(undefined8 *)(this + 0x6458),param_3,
               bVar20 | (byte)this[(ulong)uVar6 * 0x30 + 0x66a0] >> 3 & 2);
    if ((((byte)this[0x7331] & 1) == 0) && (lVar50 = *(long *)(this + 0x6498), lVar50 != 0)) {
      if (*(long *)(lVar50 + 0x80) == 0) {
        lVar39 = sil_mgr_instance((void *)0x0,0xffffffff);
        *(long *)(lVar50 + 0x80) = lVar39;
        if (lVar39 == 0) goto LAB_18a94ee28;
      }
      if (*(double *)(this + 0x69f0) != 0.0) {
        _IOMobileFramebufferSwapSetSecureAnimation(*(undefined8 *)(this + 0x6458),1);
      }
    }
LAB_18a94ee28:
    if (this[0x72fb] == (IOMFBDisplay)0x1) {
      _pthread_mutex_lock((pthread_mutex_t *)(this + 0x6778));
      *(undefined4 *)(this + 0x67e8) = *(undefined4 *)pIVar47;
      _pthread_mutex_unlock((pthread_mutex_t *)(this + 0x6778));
    }
    IVar17 = this[0x6468];
    iVar22 = _IOMobileFramebufferSwapEnd(*(undefined8 *)(this + 0x6470));
    if (this[0x72f6] == (IOMFBDisplay)0x1) {
      IOMobileFramebuffer::swap_wait((IOMobileFramebuffer *)(this + 0x6458),0,2);
    }
    if (bVar14) {
      IOMobileFramebuffer::swap_wait((IOMobileFramebuffer *)(this + 0x6458),0,2);
      local_160 = (__IOSurface *)((ulong)local_160 & 0xffffffff00000000);
      iVar27 = _IOMobileFramebufferSwapBegin(*(undefined8 *)(this + 0x6470),&local_160);
      if (iVar27 == 0) {
        this[0x6468] = (IOMFBDisplay)0x0;
      }
      swap_brightness(this);
      _IOMobileFramebufferSwapEnd(*(undefined8 *)(this + 0x6470));
      IOMobileFramebuffer::swap_wait((IOMobileFramebuffer *)(this + 0x6458),0,2);
    }
    pSVar40 = *(Surface **)(lVar31 + 0x20);
    if (bVar16) {
      if (pSVar40 != (Surface *)0x0) {
        Surface::unref(pSVar40);
        *(undefined8 *)(lVar31 + 0x20) = 0;
      }
    }
    else if (pSVar40 != (Surface *)0x0) {
      *(ulong *)(pSVar40 + 0x104) = *(ulong *)(pSVar40 + 0x104) & 0xfffffffdffffffff;
    }
    if (iVar22 == 0) {
      if ((*(int *)(this + 0x6520) == 2) && (*(int *)(this + 0x6528) == 0)) {
        *(undefined4 *)(this + 0x6528) = *(undefined4 *)pIVar47;
      }
      if (((byte)this[0x72ea] & 1) == 0) {
        this[0x72ea] = (IOMFBDisplay)0x1;
        IOMobileFramebuffer::swap_wait((IOMobileFramebuffer *)(this + 0x6458),*(uint *)pIVar47,1);
        if ((*(int *)(this + 0x6450) == 0) ||
           (iVar22 = _IORegistryEntrySetCFProperty
                               (*(int *)(this + 0x6450),&cfstringStruct_1eeee78e0,*_DAT_1e6150eb0),
           iVar22 != 0)) {
          if (x_log_get_windowserver()::once != -1) {
            _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
          }
          uVar57 = x_log_get_windowserver()::log;
          iVar22 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
          if (iVar22 != 0) {
            local_160 = (__IOSurface *)((ulong)local_160 & 0xffffffffffff0000);
            __os_log_error_impl(&MACH_HEADER,uVar57,0x10,"Failed to disable skip spinner!",
                                &local_160,2);
          }
        }
      }
      if (x_malloc_get_zone::once != -1) {
        _dispatch_once_f(&x_malloc_get_zone::once,(void *)0x0,malloc_zone_init);
      }
      puVar41 = (undefined4 *)_malloc_type_zone_calloc(malloc_zone,1,0xe0,0xdeec3011);
      if (puVar41 != (undefined4 *)0x0) {
        *(undefined8 *)(puVar41 + 0x14) = 0;
        *(undefined4 **)(puVar41 + 0x12) = puVar41 + 0x14;
        *(undefined8 *)(puVar41 + 0x1a) = 0;
        *(undefined8 *)(puVar41 + 0x16) = 0;
        *(undefined4 **)(puVar41 + 0x18) = puVar41 + 0x1a;
        puVar3 = puVar41 + 0x26;
        *(undefined8 *)(puVar41 + 0x1c) = 0;
        *(undefined4 **)(puVar41 + 0x1e) = puVar3;
        *(undefined4 **)(puVar41 + 0x20) = puVar3;
        *(undefined4 **)(puVar41 + 0x22) = puVar3;
        *(undefined8 *)(puVar41 + 0x24) = 4;
      }
      local_c0 = puVar41;
      if (this[0x72fb] == (IOMFBDisplay)0x1) {
        puVar41[1] = *(undefined4 *)(param_1 + 0xe8);
        *(undefined8 *)(puVar41 + 2) = *(undefined8 *)(param_1 + 0x40);
        *puVar41 = *(undefined4 *)pIVar47;
        if ((*(long **)(lVar31 + 0x20) != (long *)0x0) &&
           (lVar31 = (**(code **)(**(long **)(lVar31 + 0x20) + 0xa8))(), lVar31 != 0)) {
          uVar28 = _IOSurfaceGetID();
          puVar41[0x30] = uVar28;
        }
        *(byte *)(puVar41 + 0x31) = (char)*(undefined4 *)(this + 0x662c) - ((bVar15 ^ 0xffU) & 1);
        uVar7 = *(ushort *)(puVar41 + 0x37);
        uVar44 = uVar7 & 1 | (*(ushort *)(param_1 + 0x4e8) >> 10 & 1) << 1;
        *(ushort *)(puVar41 + 0x37) = uVar7 & 0xfffc | uVar44;
        *(undefined8 *)(puVar41 + 4) = *(undefined8 *)(param_1 + 0x3e0);
        *(undefined8 *)(puVar41 + 6) = *(undefined8 *)(param_1 + 0x68);
        *(double *)(puVar41 + 0x2e) = dVar56;
        *(ushort *)(puVar41 + 0x37) =
             uVar7 & 0xffdc | uVar44 | (ushort)((ulong)uVar51 >> 0x10) & 0x20;
        if (*(char *)(*(long *)(this + 0x300) + 4) == '\x01') {
          uVar44 = (ushort)(*(char *)(*(long *)(this + 0x300) + 5) == '\x01');
        }
        else {
          uVar44 = 0;
        }
        uVar8 = *(ushort *)(puVar41 + 0x37);
        *(ushort *)(puVar41 + 0x37) = uVar8 & 0xfffe | uVar44;
        uVar7 = 0;
        if ((*(ulong *)(param_1 + 0x108) & 0x18000) != 0) {
          uVar7 = 0x200;
        }
        *(ushort *)(puVar41 + 0x37) = uVar7 | uVar8 & 0xfdfe | uVar44;
        fVar55 = *(float *)(param_1 + 0x4cc);
        if (((*(ushort *)(param_1 + 0x109) & 0x180) != 0) && (fVar55 <= *(float *)(param_1 + 0x4d0))
           ) {
          fVar55 = *(float *)(param_1 + 0x4d0);
        }
        if (*(long *)(this + 0x2c0) == 0) {
          fVar69 = 1.0;
        }
        else {
          fVar69 = *(float *)(*(long *)(this + 0x2c0) + 4);
        }
        if (fVar69 <= fVar55) {
          if (*(long *)(this + 0x2c0) == 0) {
            fVar55 = 1.0;
          }
          else {
            fVar55 = *(float *)(*(long *)(this + 0x2c0) + 4);
          }
        }
        else {
          fVar55 = *(float *)(param_1 + 0x4cc);
          if (((*(ushort *)(param_1 + 0x109) & 0x180) != 0) &&
             (fVar55 <= *(float *)(param_1 + 0x4d0))) {
            fVar55 = *(float *)(param_1 + 0x4d0);
          }
        }
        puVar41[0x36] = fVar55;
        auVar66._0_8_ = *(ulong *)(param_1 + 1000);
        auVar66._8_8_ = 0;
        lVar31 = _CAHostTimeWithTime(auVar66);
        local_160 = (__IOSurface *)0x0;
        uStack_158 = (undefined8 *)0x0;
        _mach_get_times(&local_160,&uStack_158,0);
        *(long *)(puVar41 + 8) = ((long)uStack_158 - (long)local_160) + lVar31;
        *(byte *)((long)puVar41 + 0xc5) =
             *(byte *)((long)puVar41 + 0xc5) & 0xf0 | (byte)this[0x6438] & 0xf;
        auVar67._0_8_ = *(ulong *)(param_1 + 0x70);
        auVar67._8_8_ = 0;
        lVar31 = _CAHostTimeWithTime(auVar67);
        local_160 = (__IOSurface *)0x0;
        uStack_158 = (undefined8 *)0x0;
        _mach_get_times(&local_160,&uStack_158,0);
        *(long *)(puVar41 + 10) = (long)uStack_158 + (lVar31 - (long)local_160);
        *(undefined8 *)(puVar41 + 0xe) = 0xffffffffffffffff;
        uVar7 = *(ushort *)(puVar41 + 0x37);
        uVar44 = 8;
        if (dVar82 <= 0.0) {
          uVar44 = 0;
        }
        uVar44 = uVar44 | ((byte)this[0x72f8] & 1) << 2;
        *(ushort *)(puVar41 + 0x37) = uVar44 | uVar7 & 0xfff3;
        *(undefined8 *)(puVar41 + 0x10) = *(undefined8 *)(param_1 + 0x400);
        uVar44 = uVar44 | uVar7 & 0x73 | ((byte)IVar17 & 1) << 7;
        *(ushort *)(puVar41 + 0x37) = uVar7 & 0xff00 | uVar44;
        *(ushort *)(puVar41 + 0x37) =
             *(ushort *)(param_1 + 0x4e8) >> 7 & 0x100 | uVar7 & 0xfe00 | uVar44;
      }
      this[0x72f8] = (IOMFBDisplay)0x0;
      iVar22 = finish_update_(this,(Page *)(this + (ulong)uVar6 * 0x30 + 0x6678),param_1,param_2);
      if (this[0x72fb] == (IOMFBDisplay)0x1) {
        uVar51 = _mach_continuous_time();
        puVar41 = local_c0;
        *(undefined8 *)(local_c0 + 0xc) = uVar51;
        _os_unfair_lock_lock(this + 0x6718);
        local_1a0 = auStack_180;
        psVar5 = (small_vector_base<void(block_pointer)(__CFDictionary_const*)> *)(this + 0x6738);
        puStack_188 = (undefined8 *)&DAT_00000004;
        uStack_158 = (undefined8 *)0x0;
        local_160 = (__IOSurface *)0x0;
        puStack_148 = (undefined8 *)0x0;
        local_150 = (undefined1 *)0x0;
        uStack_138 = 0;
        local_134 = 0;
        uStack_140 = 0;
        uStack_128 = 0;
        uStack_124 = 0;
        uStack_130 = 0;
        uStack_12c = 0;
        puStack_198 = local_1a0;
        local_190 = local_1a0;
        X::small_vector_base<void(block_pointer)(__CFDictionary_const*)>::small_vector_base
                  ((small_vector_base<void(block_pointer)(__CFDictionary_const*)> *)&local_160,
                   (small_vector_base *)psVar5,(_func_void___CFDictionary_ptr *)&uStack_140);
        if (psVar5 != (small_vector_base<void(block_pointer)(__CFDictionary_const*)> *)&local_1a0) {
          X::small_vector_base<void(block_pointer)(__CFDictionary_const*)>::move
                    (psVar5,(small_vector_base *)&local_1a0,
                     (_func_void___CFDictionary_ptr *)(this + 0x6758));
        }
        psVar5 = (small_vector_base<void(block_pointer)(__CFDictionary_const*)> *)(puVar41 + 0x1e);
        if (psVar5 != (small_vector_base<void(block_pointer)(__CFDictionary_const*)> *)&local_160) {
          X::small_vector_base<void(block_pointer)(__CFDictionary_const*)>::move
                    (psVar5,(small_vector_base *)&local_160,
                     (_func_void___CFDictionary_ptr *)(puVar41 + 0x26));
        }
        if (local_160 != (__IOSurface *)local_150) {
          _free(local_160);
        }
        if (local_1a0 != local_190) {
          _free(local_1a0);
        }
        std::
        vector<std::unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>,std::allocator<std::unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>>>
        ::push_back_abi_nqn210106_
                  ((vector<std::unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>,std::allocator<std::unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>>>
                    *)(this + 0x6720),(unique_ptr *)&local_c0);
        _os_unfair_lock_unlock(this + 0x6718);
        _pthread_mutex_lock((pthread_mutex_t *)(this + 0x6778));
        *(undefined4 *)(this + 0x67e8) = 0;
        _pthread_cond_signal((pthread_cond_t *)(this + 0x67b8));
        _pthread_mutex_unlock((pthread_mutex_t *)(this + 0x6778));
      }
      finish_cursor_update(this);
      if (*(int *)(this + 0x6a18) != 0) {
        *(int *)(this + 0x6a18) = *(int *)(this + 0x6a18) + -1;
      }
      uVar30 = 0x80000;
      if (iVar22 == 0) {
        uVar30 = 0;
      }
      local_238 = uVar30 | local_238;
      std::
      unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>
      ::reset_abi_nqn210106_
                ((unique_ptr<CA::WindowServer::IOMFBDisplay::FrameInfo,std::default_delete<CA::WindowServer::IOMFBDisplay::FrameInfo>>
                  *)&local_c0,(FrameInfo *)0x0);
    }
    else {
      if (x_log_get_windowserver()::once != -1) {
        _dispatch_once(&x_log_get_windowserver()::once,&__block_literal_global_18584);
      }
      uVar51 = x_log_get_windowserver()::log;
      iVar27 = _os_log_type_enabled(x_log_get_windowserver()::log,0x10);
      if (iVar27 != 0) {
        local_160 = (__IOSurface *)CONCAT44(*(undefined4 *)(this + 0x18),0x4000200);
        uStack_158._0_6_ = CONCAT42(iVar22,0x400);
        __os_log_error_impl(&MACH_HEADER,uVar51,0x10,"display %u swap_end returned error %x\n",
                            &local_160,0xe);
      }
      if (DAT_1ecfeca65 == '\x01') {
        _kdebug_trace(0x31ca0094,*(undefined4 *)pIVar47,(long)iVar22,*(undefined4 *)(param_1 + 0xe8)
                      ,0);
      }
      uVar45 = (uint)(byte)this[(ulong)uVar6 * 0x30 + 0x66a0];
      if (((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] >> 6 & 1) != 0) {
        pCVar48 = *(CASharedEvent **)(*(long *)(this + (ulong)uVar6 * 0x30 + 0x6688) + 0x10);
        lVar31 = _objc_msgSend_signaledValue(*(undefined8 *)(pCVar48 + 0x20));
        CASharedEvent::force_complete(pCVar48,lVar31 + 1,false,true);
        uVar45 = (byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0xffffffbf;
        this[(ulong)uVar6 * 0x30 + 0x66a0] = SUB41(uVar45,0);
      }
      if (uVar45 >> 7 != 0) {
        pCVar48 = *(CASharedEvent **)
                   (*(long *)(*(long *)(this + (ulong)uVar6 * 0x30 + 0x6680) + 0x20) + 0x10);
        lVar31 = _objc_msgSend_signaledValue(*(undefined8 *)(pCVar48 + 0x20));
        CASharedEvent::force_complete(pCVar48,lVar31 + 1,false,true);
        this[(ulong)uVar6 * 0x30 + 0x66a0] =
             (IOMFBDisplay)((byte)this[(ulong)uVar6 * 0x30 + 0x66a0] & 0x7f);
      }
      *(undefined4 *)pIVar47 = 0;
      local_238 = local_238 | 0x1000000;
    }
  }
  else {
    _pthread_mutex_lock((pthread_mutex_t *)(this + 0x6638));
    uVar45 = *(uint *)(this + 0x6624);
    if (*(int *)(this + (ulong)uVar45 * 0x30 + 0x6690) != 0) {
      _IOMobileFramebufferSwapCancel(*(undefined8 *)(this + 0x6458));
      *(undefined4 *)(this + (ulong)uVar45 * 0x30 + 0x6690) = 0;
    }
    if (*(undefined8 **)(this + 0x69d0) != (undefined8 *)0x0) {
      (**(code **)**(undefined8 **)(this + 0x69d0))();
    }
    iVar22 = update_secure_indicators(this,param_1,0.0);
    local_238 = 0x40000000000;
    if (iVar22 == 0) {
      local_238 = 0;
    }
  }
  _pthread_mutex_unlock((pthread_mutex_t *)(this + 0x6638));
LAB_18a94f4cc:
  _objc_autoreleasePoolPop(uVar29);
  if (*_DAT_1e61cee48 != local_a0) {
                    /* WARNING: Subroutine does not return */
    ___stack_chk_fail();
  }
  return local_238;
}


