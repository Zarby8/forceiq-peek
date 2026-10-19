#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Switch App with ForceIQ Peek
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peek
# @raycast.argument1 {"type": "text", "placeholder": "bundle id from your Peek profile", "percentEncoded": true}

# Documentation:
# @raycast.description forceiq-peak://switch (ForceIQ Peek, this Mac only). Opens a local URL; never sends anything.
# @raycast.author ForceIQ

open "forceiq-peak://switch?app=$1"
