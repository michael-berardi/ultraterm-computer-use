#!/usr/bin/env bash
# Sourced by the build scripts. Sets publisher_build_flags (an array) so every swift build of one
# release stamps the same publisher bundle identifier (ULTRATERM_COMPUTER_USE_BUNDLE_ID) into the
# app, the CLI and the Locked Use installer and broker. Unset: the source default stays in place.
publisher_build_flags=()
publisher_bundle_identifier="${ULTRATERM_COMPUTER_USE_BUNDLE_ID:-}"
if [[ -n "$publisher_bundle_identifier" ]]; then
  if [[ ! "$publisher_bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "Invalid ULTRATERM_COMPUTER_USE_BUNDLE_ID" >&2
    return 1 2>/dev/null || exit 1
  fi
  publisher_build_flags=(-Xcc "-DOCU_PUBLISHER_BUNDLE_ID=\"${publisher_bundle_identifier}\"")
fi
