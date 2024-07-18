#!/usr/bin/env bash

set -e

REPO_URL="https://github.com/posit-dev/py-shiny.git"
DIRECTORY="shiny/www/py-shiny/chat"

# Clone the repository with sparse-checkout enabled
git clone --depth 1 "$REPO_URL" repo_tmp

# Conservatively delete the existing
rm -f chat/GIT_VERSION chat/chat.css chat/chat.css.map chat/chat.js chat/chat.js
if [ -d chat ]; then
    rm -r chat
fi

cp -R "repo_tmp/$DIRECTORY" .
(cd repo_tmp && git rev-parse HEAD > ../chat/GIT_VERSION)
rm -rf repo_tmp