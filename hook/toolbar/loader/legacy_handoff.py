"""Filesystem-only explicit handoff of an original manual lease.

Does not inspect/attach the process. MenuManager.adopt_existing performs the
fresh exact-birth check later, under the root coordinator lock.
"""
from pathlib import Path
from event_menus import private_json,sha,sign

def envelope(runtime,bundles,key,token_path,on_path):
 token_path=Path(token_path).resolve(strict=True);on_path=Path(on_path).resolve(strict=True)
 token=private_json(token_path);on=private_json(on_path);i=token['identity']
 bundle=Path(i['executable']).parents[2]
 import plistlib
 info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
 descriptor=bundles.inspect({'bundle_path':str(bundle),'bundle_id':info['CFBundleIdentifier'],'executable':i['executable']})
 # Older actual receipts omitted effect booleans. Require root to attest
 # that exact reviewed controller source, rather than inventing native fields.
 controller=on.get('controller_sha256');effect=runtime._grant.get('legacy_controller_effects',{}).get(controller,{})
 if effect.get('allow_activation') is not False or effect.get('allow_input') is not False:raise ValueError('root attestation of exact original controller effect boundary required')
 proof=dict(on)
 proof.update(activation_attempted=False,input_attempted=False,legacy_effect_boundary_source='root-reviewed-controller-sha256',legacy_controller_sha256=controller)
 if proof.get('native',{}).get('enabled') is not True:raise ValueError('successful original ON/STAGE proof required')
 matches=on.get('native',{}).get('current_menu_matches')
 if type(matches) not in (bool,int) or matches not in (True,1):raise ValueError('original ON current-menu match required')
 proof.update(enabled=True,current_menu_matches=True)
 for field in ('module_sha256','module_uuid','menu_lease_flags','handle','identity'):
  if on.get(field)!=token.get(field):raise ValueError('original token/ON '+field+' mismatch')
 if on.get('main_uuid','').replace('-','').lower() not in [row['main_uuid'] for row in descriptor['images']]:raise ValueError('original loaded main image not installed current image')
 proof.update(legacy_token=str(token_path),legacy_on_receipt=str(on_path),legacy_on_sha256=sha(on_path))
 owner={'identity':i,'descriptor':descriptor,'proof':proof,'phase':'applied','epoch':runtime._grant['epoch'],'nonce':runtime._grant['nonce']}
 if runtime.verify_legacy_owner(owner) is not True:raise ValueError('actual immutable original manual token chain refused')
 return sign(owner,key)
