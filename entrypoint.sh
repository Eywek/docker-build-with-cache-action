#!/usr/bin/env bash

set -e

dummy_image_name=my_awesome_image
# split tags (to allow multiple comma-separated tags)
IFS=, read -ra INPUT_IMAGE_TAG <<< "$INPUT_IMAGE_TAG"

# helper functions
_has_value() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "INFO: Missing value $var_name" >&2
    return 1
  fi
}

_get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
    sort -n |
    tail -n 1
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_full_image_name() {
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${INPUT_IMAGE_NAME}
}

_tag() {
  local tag
  tag="${1:?You must provide a tag}"
  docker tag $dummy_image_name "$(_get_full_image_name):$tag"
}

_push() {
  local tag
  tag="${1:?You must provide a tag}"
  docker push "$(_get_full_image_name):$tag"
}

_push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  echo -e "\nPushing git tag: $git_tag"
  _tag $git_tag
  _push $git_tag
}

_push_image_tags() {
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    echo "Pushing: $tag"
    _push $tag
  done
  if [ "$INPUT_PUSH_GIT_TAG" = true ]; then
    _push_git_tag
  fi
}

_push_image_stages() {
  local stage_number=1
  local stage_image
  for stage in $(_get_stages); do
    echo -e "\nPushing stage: $stage_number"
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  echo -e "\nPushing stage: $stage_number"
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag $dummy_image_name $stage_image
  docker push $stage_image
}


# action steps
check_required_input() {
  echo -e "\n[Action Step] Checking required input..."
  _has_value IMAGE_NAME "${INPUT_IMAGE_NAME}" \
    && _has_value IMAGE_TAG "${INPUT_IMAGE_TAG}" \
    && return
  exit 1
}

pull_cached_stages() {
  if [ "$INPUT_PULL_IMAGE_AND_STAGES" != true ]; then
    return
  fi
  echo -e "\n[Action Step] Pulling image..."
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  echo -e "\n[Action Step] Building image..."
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  # build image using cache
  set -o pipefail
  set -x
  docker build \
    $cache_from \
    --tag $dummy_image_name \
    --file ${INPUT_CONTEXT}/${INPUT_DOCKERFILE} \
    ${INPUT_BUILD_EXTRA_ARGS} \
    ${INPUT_CONTEXT} | tee "$BUILD_LOG"
  set +x
}

tag_image() {
  echo -e "\n[Action Step] Tagging image..."
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    echo "Tagging: $tag"
    _tag $tag
  done
}

push_image_and_stages() {
  if [ "$INPUT_PUSH_IMAGE_AND_STAGES" != true ]; then
    return
  fi

  if [ "$not_logged_in" ]; then
    echo "ERROR: Can't push when not logged in to registry. Set push_image_and_stages=false if you don't want to push" >&2
    return 1
  fi

  echo -e "\n[Action Step] Pushing image..."
  _push_image_tags
  _push_image_stages
}

logout_from_registry() {
  if [ "$not_logged_in" ]; then
    return
  fi
  echo -e "\n[Action Step] Log out from registry..."
  docker logout "${INPUT_REGISTRY}"
}

login_to_registry() {
  echo "Logging into gcr.io with GCLOUD_SERVICE_ACCOUNT_KEY..."
  echo ${GCLOUD_SERVICE_ACCOUNT_KEY} | base64 --decode --ignore-garbage > /tmp/key.json
  gcloud auth activate-service-account --quiet --key-file /tmp/key.json
  gcloud auth configure-docker --quiet
}


# run the action
check_required_input
login_to_registry
pull_cached_stages
build_image
tag_image
push_image_and_stages
logout_from_registry
