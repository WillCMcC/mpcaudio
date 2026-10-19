#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="mpcaudio"
machine="3218i"
login="${CAPROVER_LOGIN_TOOL:-$HOME/code/caprover-control/scripts/caprover-login.sh}"
config="${CAPROVER_CONFIG:-$HOME/.config/configstore/caprover.json}"
deploy="${CAPROVER_DEPLOY_TOOL:-$HOME/brain/bin/caprover-tar-deploy.sh}"
lock_attempts="${CAPROVER_LOCK_ATTEMPTS:-90}"
lock_retry_seconds="${CAPROVER_LOCK_RETRY_SECONDS:-5}"

cd "$project_root"

commit="${TODOBOY_DEPLOY_COMMIT:-$(git rev-parse HEAD)}"
jq -nc --arg commit "$commit" '{commit:$commit}' > version.json

"$login" >/dev/null
read -r base token < <(jq -er --arg machine "$machine" '
  .CapMachines[] | select(.name == $machine) | [.baseUrl, .authToken] | @tsv
' "$config")

apps="$({ curl --fail-with-body --silent --show-error --max-time 30 --insecure \
  -H "x-captain-auth: $token" -H 'x-namespace: captain' \
  "$base/api/v2/user/apps/appDefinitions"; } 2>&1)" || {
  echo "could not read CapRover apps: $apps" >&2
  exit 1
}

cap_post() {
  local endpoint="$1" payload="$2" attempt http_status curl_status=0
  local response_file
  response_file="$(mktemp "${TMPDIR:-/tmp}/boy-dev-caprover.XXXXXX.json")"
  for attempt in $(seq 1 "$lock_attempts"); do
    curl_status=0
    http_status="$(curl --silent --show-error --max-time 120 --insecure \
      -o "$response_file" -w '%{http_code}' \
      -X POST -H "x-captain-auth: $token" -H 'x-namespace: captain' -H 'Content-Type: application/json' \
      --data "$payload" "$base/api/v2$endpoint")" || curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
      rm -f "$response_file"
      return "$curl_status"
    fi
    if [ "$http_status" = 429 ]; then
      if [ "$attempt" -eq "$lock_attempts" ]; then
        echo "CapRover remained locked after $lock_attempts attempts" >&2
        cat "$response_file" >&2
        rm -f "$response_file"
        return 22
      fi
      echo "CapRover mutation lock is busy; retrying registration in ${lock_retry_seconds}s ($attempt/$lock_attempts)..." >&2
      sleep "$lock_retry_seconds"
      continue
    fi
    if [[ "$http_status" != 2* ]]; then
      echo "CapRover returned HTTP $http_status" >&2
      cat "$response_file" >&2
      rm -f "$response_file"
      return 22
    fi
    cat "$response_file"
    rm -f "$response_file"
    return 0
  done
}

if ! jq -e --arg app "$app" '.data.appDefinitions[] | select(.appName == $app)' <<<"$apps" >/dev/null; then
  echo "Registering CapRover app $app..."
  payload="$(jq -nc --arg appName "$app" '{appName:$appName,hasPersistentData:false}')"
  response="$(cap_post /user/apps/appDefinitions/register "$payload")"
  jq -e '.status == 100' <<<"$response" >/dev/null || { echo "CapRover registration failed" >&2; exit 1; }
fi

"$deploy" "$app" "$machine"
