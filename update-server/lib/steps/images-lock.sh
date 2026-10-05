#!/usr/bin/env bash
# Registered step "images-lock": a product that ships registry-pulled, digest
# pinned images (no docker bundle) publishes its image lock in the signed channel
# entry.  The update agent maps every compose service to these digests and pulls
# nothing else.  Operates only on private staged inputs and contributes metadata.
if [[ -n "$IMAGES_LOCK" ]]; then
  # The package carries the lock it was built with; it must be the one published.
  python3 "${SCRIPT_DIR}/lib/registry.py" validate-lock-in-archive "$REPO_ROOT" "$PRODUCT" "$ARCHIVE" "$IMAGES_LOCK"
  python3 "${SCRIPT_DIR}/lib/channel.py" images "$REGISTRY_FILE" "$IMAGES_LOCK" "$RELEASE_EXTRA"
fi
