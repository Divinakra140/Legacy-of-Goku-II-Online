#!/bin/zsh
# Puts the lobby list's latest code (lobby/src) live on Cloudflare - the GLOBAL MULTIPLAYER list players see.
# Keeps its password (the LOBBY_KEY secret) and every game listed. Needs lobby/.cloudflare_token, as
# set_lobby_password.sh does.
B="$(cd "$(dirname "$0")/.." && pwd)"
cd "$B/lobby" || exit 1
node test/directory.test.mjs || { echo "The lobby tests failed - nothing was put live."; exit 1; }
T=$(tr -d ' \r\n\t' < .cloudflare_token) || exit 1
ID=$(curl -s https://api.cloudflare.com/client/v4/accounts -H "Authorization: Bearer $T" | python3 -I -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])") || { echo "Could not reach the Cloudflare account."; exit 1; }
CLOUDFLARE_API_TOKEN="$T" CLOUDFLARE_ACCOUNT_ID="$ID" npx --yes wrangler@4 deploy -c wrangler.private.toml || exit 1
echo "Done: the lobby list runs the new code."
