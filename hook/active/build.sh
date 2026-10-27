#!/bin/zsh
# Собирает hyprforce.dylib (arm64e + arm64: системные приложения arm64e, сторонние — arm64).
set -eu
H=${0:A:h}; cd $H
clang -O2 -Wall -fobjc-arc -dynamiclib -arch arm64 -arch arm64e -framework AppKit -framework QuartzCore hyprforce.m -o hyprforce.dylib
codesign -f -s - hyprforce.dylib 2>/dev/null
clang -O2 -Wall -fobjc-arc -dynamiclib -arch arm64 -arch arm64e -framework AppKit hyprmenus.m -o hyprmenus.dylib
codesign -f -s - hyprmenus.dylib 2>/dev/null
clang -O2 -Wall -Wextra -Werror -fobjc-arc -dynamiclib -arch arm64 -arch arm64e -framework AppKit \
  -install_name @rpath/hypradmission.v3.dylib \
  ../admission/client.m ../admission/admission.m ../admission/lifecycle.m ../admission/grant.m -o hypradmission.v3.dylib
codesign -f -s - hypradmission.v3.dylib 2>/dev/null
echo "hyprforce.dylib собран"
