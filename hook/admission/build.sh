#!/bin/sh
set -eu
admission_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
admission_out=${1:-/tmp/hyprwm-admission}
mkdir -p "$admission_out"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$admission_dir/client.m" "$admission_dir/client_probe.m" -o "$admission_out/client_probe"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
  "$admission_dir/client.m" "$admission_dir/admission.m" "$admission_dir/fixture.m" -o "$admission_out/fixture"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit -dynamiclib \
  -arch arm64 -arch arm64e "$admission_dir/client.m" "$admission_dir/admission.m" -o "$admission_out/admission.dylib"
codesign -s - --force "$admission_out/admission.dylib"
cp "$admission_out/admission.dylib" "$admission_out/hypradmission.v1.dylib.tmp"
mv "$admission_out/hypradmission.v1.dylib.tmp" "$admission_out/hypradmission.v1.dylib"
# Explicitly do not run the GUI fixture or inject the sidecar here.
