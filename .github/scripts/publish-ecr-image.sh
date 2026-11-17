#!/bin/sh
set -eu

source_image=$1
registry="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
tag="$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
image="$registry/$ECR_REPOSITORY:$tag"
password=$(aws ecr get-login-password)
printf '%s\n' "$password" |
  docker login --username AWS --password-stdin "$registry"
unset password

docker tag "$source_image" "$image"
docker push "$image"
reference=$(docker inspect --format '{{index .RepoDigests 0}}' "$image")
digest=${reference##*@}
if ! printf '%s\n' "$digest" | grep -Eq '^sha256:[a-f0-9]{64}$'; then
  echo "Couldn't read the published image digest." >&2
  exit 1
fi
printf '%s\n' "$digest" >> "$GITHUB_STEP_SUMMARY"
