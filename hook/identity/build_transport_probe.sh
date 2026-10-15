#!/bin/sh
set -eu
identity_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
identity_out=${1:-/tmp/hyprwm-identity}
mkdir -p "$identity_out"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$identity_dir/property_transport_probe.m" -o "$identity_out/property_transport_probe"
"$identity_out/property_transport_probe" --offline-selftest
