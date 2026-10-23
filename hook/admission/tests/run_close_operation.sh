#!/bin/bash
# Headless only. --live on the fixture is a separate root-operated desktop check.
set -eu
admission_dir="$(cd "$(dirname "$0")/.." && pwd)"
close_test_dir="${1:-$(mktemp -d /tmp/hyprwm-close-operation.XXXXXX)}"
mkdir -p "$close_test_dir"
for close_arch in arm64 arm64e; do
    close_binary="$close_test_dir/CloseOperationFixture-$close_arch"
    clang -arch "$close_arch" -O1 -g -fobjc-arc -fobjc-arc-exceptions \
        -Wall -Wextra -Werror -fsanitize=address,undefined \
        "$admission_dir/tests/CloseOperationFixture.m" -framework AppKit -o "$close_binary"
    for close_case in metadata unit=preparation unit=immediate unit=after-enqueue \
        unit=deferred-off unit=reopened unit=stale-generation unit=off-after-set; do
        ASAN_OPTIONS=detect_leaks=0 "$close_binary" "--$close_case"
    done
done
