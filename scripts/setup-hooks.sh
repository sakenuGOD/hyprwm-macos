#!/bin/sh
set -eu
cd "$(git rev-parse --show-toplevel)"
if [ "$(git config --local --get core.hooksPath || true)" = .githooks ]; then
    git config --local --unset core.hooksPath
fi
printf '%s\n' 'Automatic synchronization is disabled. Push explicitly when ready.'
