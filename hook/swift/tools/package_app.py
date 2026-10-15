"""Write bounded native bundle metadata and a source/binary packaging receipt."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def source_refs(project):
    sources = [project / 'hook/swift/Package.swift'] + list((project / 'hook/swift/Sources').rglob('*.swift'))
    sources += [path for path in (project / 'hook/swift/Sources').rglob('*') if path.suffix in ('.c', '.m', '.h')]
    sources += list((project / 'hook/src').glob('*.h'))
    sources += [project / 'hook/src' / name for name in ('axlib.c', 'winsnap.m', 'chanlib.c', 'managed_process_identity.c')]
    sources += [project / 'hook/identity/transport_native.m']
    return [dict(path=str(path.relative_to(project)), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            for path in sorted(set(sources))]


if len(sys.argv) == 4 and sys.argv[1] == '--snapshot':
    Path(sys.argv[3]).write_text(json.dumps(source_refs(Path(sys.argv[2]).resolve()), indent=2) + '\n')
    raise SystemExit(0)

if len(sys.argv) == 4 and sys.argv[1] == '--seal':
    signed_bundle = Path(sys.argv[2]).resolve()
    embedded = signed_bundle / 'Contents/Resources/BuildManifest.json'
    receipt = json.loads(embedded.read_text())
    binary = signed_bundle / 'Contents/MacOS/hyprwm-swift'
    receipt.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   embedded_manifest_sha256=hashlib.sha256(embedded.read_bytes()).hexdigest(),
                   signature_verified=True)
    Path(sys.argv[3]).write_text(json.dumps(receipt, indent=2) + '\n')
    raise SystemExit(0)

root, bundle = map(lambda value: Path(value).resolve(), sys.argv[1:3])
version, build = sys.argv[3:5]
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d{1,4}(?:\.\d{1,2}){0,2}', build):
    raise SystemExit('Numeric app version/build required')
package = root / 'hook/swift/Package.swift'
platform = re.search(r'platforms:\s*\[\.macOS\(\.v(\d+)\)\]', package.read_text())
if not platform:
    raise SystemExit('Swift package minimum macOS platform unavailable')
runtime_options = (root / 'hook/swift/Sources/HyprCore/RuntimeOptions.swift').read_text()
snapshot_default = re.search(r'public\s+var\s+snapshotFrames\s*=\s*(true|false)\b', runtime_options)
if not snapshot_default or snapshot_default[1] != 'false':
    raise SystemExit('Release requires the compiled snapshotFrames default to remain false.')
info = dict(CFBundleDevelopmentRegion='ru', CFBundleDisplayName='HyprWM',
            CFBundleName='HyprWM', CFBundleExecutable='hyprwm-swift', CFBundlePackageType='APPL',
            CFBundleIdentifier='dev.hyprwm.HyprWM', CFBundleShortVersionString=version,
            CFBundleVersion=build, CFBundleIconFile='AppIcon', LSUIElement=True,
            LSMinimumSystemVersion=platform[1] + '.0', NSHighResolutionCapable=True,
            NSSupportsAutomaticGraphicsSwitching=True, HyprWMLaunchRole='menu-only',
            HyprWMSourceRoot=str(root))
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
(bundle / 'Contents/PkgInfo').write_bytes(b'APPL????')
refs = source_refs(root)
if len(sys.argv) != 6 or refs != json.loads(Path(sys.argv[5]).read_text()):
    raise SystemExit('Sources changed during release build; no bundle installed. Repeat after edits settle.')
binary = bundle / 'Contents/MacOS/hyprwm-swift'
uuid_output = subprocess.run(['dwarfdump', '--uuid', str(binary)], check=True, text=True, capture_output=True).stdout
uuid = {architecture: value.lower() for value, architecture in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', uuid_output)}
if not uuid:
    raise SystemExit('Mach-O binary UUID unavailable')
receipt = dict(schema=1, product='HyprWM', bundle_id=info['CFBundleIdentifier'], launch_role='menu-only',
               version=version, build=build, minimum_macos=info['LSMinimumSystemVersion'],
               sdk=subprocess.run(['xcrun', '--show-sdk-version'], check=True, text=True, capture_output=True).stdout.strip(),
               compiled_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), binary_uuid=uuid,
               source_root=str(root), sources=refs, distribution='local-ad-hoc',
               runtime_defaults=dict(snapshot_frames=False, snapshot_environment_override='HYPRWM_SNAPSHOT_FRAMES'),
               daemon_replacement_performed=False, native_engine_installation_performed=False)
(bundle / 'Contents/Resources/BuildManifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
