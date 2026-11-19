#!/bin/sh
set -eu

source_framework="${SCRIPT_INPUT_FILE_0:?Missing processed SDL2 framework}"
staged_framework="${SCRIPT_OUTPUT_FILE_0:?Missing staged SDL2 framework path}"

# Recreate the generated copy so it never retains files from an older SDL2 build.
/bin/rm -rf "$staged_framework"
/usr/bin/ditto "$source_framework" "$staged_framework"

if [ -d "$staged_framework/Versions/Current/Resources" ]; then
    /bin/cp "$SCRIPT_INPUT_FILE_2" "$staged_framework/Versions/Current/Resources/PrivacyInfo.xcprivacy"
else
    /bin/cp "$SCRIPT_INPUT_FILE_1" "$staged_framework/PrivacyInfo.xcprivacy"
fi
