#!/bin/sh
set -eu
identity_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
identity_out=${1:-/tmp/hyprwm-identity}
mkdir -p "$identity_out"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit -dynamiclib \
  -arch arm64 -arch arm64e "$identity_dir/identity.m" "$identity_dir/publisher.m" "$identity_dir/transport_native.m" -o "$identity_out/identity.dylib"
codesign -s - --force "$identity_out/identity.dylib"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
  "$identity_dir/identity.m" "$identity_dir/publisher.m" "$identity_dir/transport_native.m" "$identity_dir/offline_test.m" -o "$identity_out/offline_test"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit -framework QuartzCore -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  "$identity_dir/identity.m" "$identity_dir/publisher.m" "$identity_dir/transport_native.m" "$identity_dir/fixture.m" -o "$identity_out/fixture"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -dynamiclib \
  -arch arm64 -arch arm64e "$identity_dir/transport_native.m" -o "$identity_out/identity_reader.dylib"
codesign -s - --force "$identity_out/identity_reader.dylib"
"$identity_out/offline_test"
