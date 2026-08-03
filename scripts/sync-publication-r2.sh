#!/usr/bin/env bash

set -euo pipefail

: "${R2_BUCKET_NAME:?R2_BUCKET_NAME is required}"
: "${R2_OBJECT_PREFIX:=publication}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

if [[ -z "${R2_OBJECT_PREFIX}" ]]; then
  echo "R2_OBJECT_PREFIX must not be empty." >&2
  exit 1
fi

wrangler_command=(npx --yes wrangler@4)

is_syncable_path() {
  case "${1,,}" in
    *.avif|*.epub|*.gif|*.jpe|*.jpeg|*.jpg|*.mobi|*.pdf|*.png|*.svg|*.webp|*.zip)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

content_type_for() {
  case "${1,,}" in
    *.avif) printf '%s' 'image/avif' ;;
    *.epub) printf '%s' 'application/epub+zip' ;;
    *.gif) printf '%s' 'image/gif' ;;
    *.jpe|*.jpeg|*.jpg) printf '%s' 'image/jpeg' ;;
    *.mobi) printf '%s' 'application/x-mobipocket-ebook' ;;
    *.pdf) printf '%s' 'application/pdf' ;;
    *.png) printf '%s' 'image/png' ;;
    *.svg) printf '%s' 'image/svg+xml' ;;
    *.webp) printf '%s' 'image/webp' ;;
    *.zip) printf '%s' 'application/zip' ;;
    *) printf '%s' 'application/octet-stream' ;;
  esac
}

object_key_for() {
  printf '%s/%s' "${R2_OBJECT_PREFIX%/}" "${1#./}"
}

upload_file() {
  local path="$1"
  local object_key
  object_key="$(object_key_for "$path")"

  echo "Uploading ${path} -> ${R2_BUCKET_NAME}/${object_key}"
  "${wrangler_command[@]}" r2 object put "${R2_BUCKET_NAME}/${object_key}" \
    --file "$path" \
    --content-type "$(content_type_for "$path")" \
    --remote
}

delete_file() {
  local path="$1"
  local object_key
  object_key="$(object_key_for "$path")"

  echo "Deleting ${R2_BUCKET_NAME}/${object_key}"
  "${wrangler_command[@]}" r2 object delete "${R2_BUCKET_NAME}/${object_key}" \
    --remote
}

sync_all_files() {
  local path

  while IFS= read -r -d '' path; do
    if is_syncable_path "$path"; then
      upload_file "$path"
    fi
  done < <(git ls-files -z)
}

sync_changed_files() {
  local before="$1"
  local after="$2"
  local status
  local path

  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if ! is_syncable_path "$path"; then
      continue
    fi

    case "$status" in
      A|C|M|T)
        upload_file "$path"
        ;;
      D)
        delete_file "$path"
        ;;
    esac
  done < <(
    git diff --no-renames --name-status -z --diff-filter=ACMDT "$before" "$after"
  )
}

before="${GITHUB_EVENT_BEFORE:-}"
sync_all="${R2_SYNC_ALL:-false}"

if [[ "$sync_all" == "true" || -z "$before" || "$before" =~ ^0+$ ]]; then
  sync_all_files
else
  sync_changed_files "$before" "$GITHUB_SHA"
fi
