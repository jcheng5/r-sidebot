#!/usr/bin/env bash

set -e

# This script downloads new chat CSS/JS assets from py-shiny, and stamps the
# directory with a GIT_VERSION.

REPO_URL="https://github.com/posit-dev/py-shiny.git"
DIRECTORY="shiny/www/py-shiny/chat"
BRANCH=chat-append-incremental

if [ ! -f "r-sidebot.Rproj" ]; then
  echo "Error: You must execute this script from the repo root (./scripts/update-chat.sh)."
  exit 1
fi

# Clone the repository with sparse-checkout enabled
git clone -b "$BRANCH" --depth 1 "$REPO_URL" repo_tmp

# Conservatively delete the existing
rm -f chat/GIT_VERSION chat/chat.css chat/chat.css.map chat/chat.js chat/chat.js
if [ -d chat ]; then
    rm -r chat
fi

cp -R "repo_tmp/$DIRECTORY" .
(cd repo_tmp && git rev-parse HEAD > ../chat/GIT_VERSION)
rm -rf repo_tmp
