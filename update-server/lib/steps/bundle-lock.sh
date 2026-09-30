#!/usr/bin/env bash
if [[ -n "$BUNDLE" && -n "$IMAGES_LOCK" ]]; then
  # Step contract: operates only on private staged inputs, contributes metadata.
  python3 "${SCRIPT_DIR}/lib/bundle_lock.py" --registry "$REGISTRY_FILE" \
    --archive "$ARCHIVE" --bundle "$BUNDLE" --images-lock "$IMAGES_LOCK" \
    --output "$STAGE/transformed/$(basename "$ARCHIVE")"
  ARCHIVE="$STAGE/transformed/$(basename "$ARCHIVE")"
  python3 "${SCRIPT_DIR}/lib/channel.py" images "$REGISTRY_FILE" "$IMAGES_LOCK" "$RELEASE_EXTRA"
fi
