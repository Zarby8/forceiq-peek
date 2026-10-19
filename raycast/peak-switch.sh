#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Switch App with ForceIQ Peak
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peak
# @raycast.argument1 {"type": "text", "placeholder": "bundle id from your Peak profile", "percentEncoded": true}

# Documentation:
# @raycast.description forceiq-peak://switch (ForceIQ Peak, this Mac only). Opens a local URL; never sends anything.
# @raycast.author ForceIQ

open "forceiq-peak://switch?app=$1"
