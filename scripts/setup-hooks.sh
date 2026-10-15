#!/bin/sh
set -eu
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/post-commit
printf '%s\n' 'Post-commit synchronization enabled.'
