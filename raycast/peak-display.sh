#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ForceIQ Peak on a Display
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peak
# @raycast.argument1 {"type": "text", "placeholder": "display UUID", "percentEncoded": true}
# @raycast.argument2 {"type": "dropdown", "placeholder": "state", "data": [{"title": "On", "value": "on"}, {"title": "Off", "value": "off"}]}

# Documentation:
# @raycast.description forceiq-peak://display (ForceIQ Peak, this Mac only). Opens a local URL; never sends anything.
# @raycast.author ForceIQ

open "forceiq-peak://display?id=$1&state=$2"
