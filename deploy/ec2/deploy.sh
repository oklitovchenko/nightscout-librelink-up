#!/bin/sh
set -eu

docker_network=nightscout-server
ipv6_network=nightscout-server-ipv6
app_port=1337
health_poll_interval=4
app_container=nightscout-server-app

download_settings() {
  aws ssm get-parameter --region "$aws_region" \
    --name "$settings_parameter:$SSM_configVersion" \
    --with-decryption --query Parameter.Value --output text \
    > "$release/settings.json"
  printf '%s\n' "$image" > "$release/image"
}

remove_container() {
  if docker container inspect "$container" >/dev/null 2>&1; then
    docker rm -f "$container" >/dev/null
  fi
}

run_container() (
  operation=$1
  shift
  docker "$operation" --restart unless-stopped --network "$docker_network" \
    --log-opt max-size=10m --log-opt max-file=2 --name "$container" "$@"
)

activate_release() {
  ln -sfn "$release" current.new
  mv -Tf current.new current
  keep_release=true
}

run_uploader() {
  run_container create "$@" >/dev/null &&
    docker network connect "$ipv6_network" "$container" &&
    docker start "$container" >/dev/null
}

start_uploader() (
  directory=$1
  read -r release_image < "$directory/image" || exit 1
  remove_container || exit 1
  run_uploader --env-file "$directory/libre.env" \
    -e "NIGHTSCOUT_URL=$app_container:$app_port" \
    -e NIGHTSCOUT_DISABLE_HTTPS=true -e NIGHTSCOUT_API_V3=true "$release_image"
)

wait_for_uploader() {
  max_attempts=100
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    state=$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' \
      "$container") || return 1
    if [ "$state" != 'true 0' ]; then
      return 1
    fi
    if docker logs "$container" 2>&1 | grep -E \
      -e 'No new measurements to upload' \
      -e 'Upload of [0-9]+ measurements to Nightscout succeeded' \
      >/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "$health_poll_interval"
  done
  return 1
}

restore_uploader() {
  case "$previous" in
    '')
      docker rm -f "$container" >/dev/null 2>&1 || true
      ;;
    "$legacy_release")
      # The combined launcher's container has its own API v1 settings.
      docker rm -f "$container" >/dev/null 2>&1 || true
      legacy_image=$(sed -n '2p' "$legacy_release/images")
      run_uploader --env-file "$legacy_release/libre.env" "$legacy_image"
      ;;
    *)
      start_uploader "$previous"
      ;;
  esac
}

docker inspect "$app_container" | jq -e '
  .[0] | .State.Running
    and (.Config.Env | index("CONNECT_SOURCE=linkup") == null)
' >/dev/null || {
  echo "Start Nightscout with its built-in LibreLinkUp connector off." >&2
  exit 1
}

release=$(mktemp -d "$PWD/release.XXXXXXXX")
keep_release=false
cleanup_release() {
  if ! "$keep_release"; then
    rm -rf "$release"
  fi
}
trap cleanup_release EXIT

download_settings
jq -er 'to_entries[] | "\(.key)=\(.value)"' \
  "$release/settings.json" > "$release/libre.env"
rm "$release/settings.json"

legacy_release="$state_directory/current"
previous=$(readlink current || true)
if [ -z "$previous" ] && [ -f "$legacy_release/libre.env" ]; then
  previous=$legacy_release
fi
if start_uploader "$release" && wait_for_uploader; then
  activate_release
  if [ -n "$previous" ] && [ "$previous" != "$legacy_release" ]; then
    rm -rf "$previous"
  fi
  echo "LibreLinkUp reached Nightscout successfully"
else
  echo "LibreLinkUp did not complete a successful poll" >&2
  restore_uploader
  exit 1
fi
