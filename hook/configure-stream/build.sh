#!/bin/zsh
# Recipe only. Qualification and an explicit root grant precede any loading.
set -eu
cd "${0:A:h}"
clang -O2 -Wall -Wextra -Werror -fobjc-arc -dynamiclib -arch arm64 -arch arm64e \
  -framework AppKit -framework ApplicationServices \
  -install_name @rpath/HyprConfigureStream.v1.dylib \
  ConfigureStream.m -o HyprConfigureStream.v1.dylib
codesign -f -s - HyprConfigureStream.v1.dylib
