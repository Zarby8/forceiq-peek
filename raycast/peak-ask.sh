#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Ask in ForceIQ Peek
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peek
# @raycast.argument1 {"type": "text", "placeholder": "question (opens the ask field; nothing is sent)", "optional": true, "percentEncoded": true}

# Documentation:
# @raycast.description forceiq-peak://ask (ForceIQ Peek, this Mac only). Opens a local URL; never sends anything.
# @raycast.author ForceIQ

if [ -n "${1:-}" ]; then
  open "forceiq-peak://ask?q=$1"
else
  open "forceiq-peak://ask"
fi
