#!/usr/bin/env python3
"""Audit native controls against schema and concrete consumer mappings.

This generated artifact deliberately distinguishes runtime-format compatibility
from renderer support. It never loads or mutates the running service.
"""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
source=(ROOT/'swift/Sources/hyprwm-swift/SettingsModel.swift').read_text()
schema=json.loads((ROOT/'config/runtime.schema.json').read_text())
fields=[]
for match in re.finditer(r'\.init\("([^"]+)","([^"]+)",\.(\w+),"([^"]+)",\.(number|toggle|choice|color)\((.*?)\)(?=,)|\.init\("([^"]+)","([^"]+)",\.(\w+),"([^"]+)",\.(toggle|color)',source):
    groups=match.groups();path,title,page,group,kind=(groups[:5] if groups[0] else groups[6:11])
    line=source[match.start():source.index('\n',match.start())]
    mapping=re.search(r'source:"([^"]+)"',line)
    fields.append({'path':path,'label':title,'section':page,'control':kind,'editable':True,'effective_mapping':mapping.group(1) if mapping else path,'validator':'native JSONSchema + NativeRuntimeConfig.build','consumer':''})

consumers={'layout':'HyprConfig.makeDwindle / WM.tile / Python WM.configured', 'appearance':'Appearance.swift / Deco.swift / engine.py / native effects receiver', 'focus':'WM focus consumers / Python WM focus selection', 'drag':'RuntimeOptions / WM drag / Python configured input', 'runtime':'LiveEngine / engine.py runtime_settings', 'animations':'HyprConfig.animation / engine.py anim', 'time_scale':'NativeRuntimeConfig.build / runtimecfg.build_config'}
for field in fields:
    field['consumer']='RuntimeOptions.overviewHiddenWindows / OverviewBridge confirmed empty pool / OverviewEntryBarrier' if field['path']=='runtime.overview_hidden_windows' else 'NativeRuntimeConfig / Channel.configure buffer bit25 / live native buffer projection' if field['path']=='runtime.window_resize_mode' else consumers[field['path'].split('.')[0]]
fields.append({'path':'appearance.border.active.colors[*]','section':'appearance','control':'ColorPicker + add/remove','editable':True,'effective_mapping':'config.general.col.active_border.colors','consumer':'native border renderer','validator':'1..8 valid runtime colors'})
for event in ['windowsMove','windowsIn','windowsOut','fadeIn','fadeOut','fadeSwitch','border','fadeShadow','fadeGlow']:
    for key,control in [('enabled','Toggle'),('curve','Picker'),('time_scale','Slider + numeric field'),('duration_ms','Slider + numeric field')]+([('style','Picker')] if event in ['windowsIn','windowsOut'] else []):
        fields.append({'path':f'animations.{event}.{key}','section':'animations','control':control,'editable':True,'consumer':'HyprConfig.animation / native engine / Python engine','condition':'duration_ms only for bezier; border/fadeShadow only bezier' if key in ['curve','duration_ms'] else ''})
for path,control in [('curves.<name>.type','new curve type Picker: bezier/spring'),('curves.<name>.mass','Slider + numeric field'),('curves.<name>.stiffness','Slider + numeric field'),('curves.<name>.damping','Slider + numeric field'),('curves.<name>.points','direct draggable graph + X/Y fields'),('window_rules[*].match.class','TextField with validated regex'),('window_rules[*].match.title','TextField with validated regex'),('window_rules[*].name','TextField'),('window_rules[*].enabled','Toggle'),('window_rules[*].float','Tile/Float/Ignore Picker'),('window_rules[*].ignore','Tile/Float/Ignore Picker'),('window_rules[*].no_anim','Toggle'),('window_rules[*].no_follow_mouse','Toggle'),('window_rules[*].opacity','Slider'),('hotkeys[*].keycode','native click-to-record NSButton'),('hotkeys[*].modifiers','native click-to-record NSButton'),('hotkeys[*].enabled','Toggle'),('hotkeys[*].id','baseline selector (not user editable)'),('hotkeys[*].command','action identity selector (not executable override)')]:
    fields.append({'path':path,'section':'hotkeys' if path.startswith('hotkeys') else 'rules' if path.startswith('window') else 'animations','control':control,'editable':'selector' not in control,'consumer':'keys/binds.py -> atomic /tmp/hyprkeys.json -> native hot-reload' if path.startswith('hotkeys') else 'windowrules.ignore_decision / native WM exclusion / float/window policies' if path.startswith('window') else 'native curve slots / engine curve sampling'})
hidden=[{'path':f'appearance.{p}','reason':'Window opacity is unfinished; no general opacity UI or blur promise.'} for p in ['active_opacity','inactive_opacity','fullscreen_opacity']]
hidden += [{'path':f'animations.{p}','reason':'Compatibility/inheritance node or absent native renderer; no fake action control.'} for p in schema['properties']['animations']['properties'] if p not in ['enabled','windowsMove','windowsIn','windowsOut','fadeIn','fadeOut','fadeSwitch','border','fadeShadow','fadeGlow']]
result={'generated_from':['SettingsModel.swift','SettingsViews.swift','SettingsPreviews.swift','SettingsRulesHotkeys.swift','runtime.schema.json'],'controls':fields,'hidden_compatibility_fields':hidden,'validation':'Native full-document schema validation and runtime resolution before atomic write; invalid/unknown keys leave disk unchanged. Existing unrelated fields merge from latest disk; concurrent disk change aborts write.','preview_safety':'--ui-preview bypasses persistence and control mutations, does not set onboarding completion.','runtime_scope':'Lua keys with no runtime override/confirmed consumer are not advertised. External environment overrides retain precedence.'}
path=ROOT/'swift/SettingsInventory.json';path.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(f'{len(fields)} inventoried controls/mappings -> {path}')
