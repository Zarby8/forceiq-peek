#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle ForceIQ Peek
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peek

# Documentation:
# @raycast.description forceiq-peak://toggle (ForceIQ Peek, this Mac only). Opens a local URL; never sends anything.
# @raycast.author ForceIQ

open "forceiq-peak://toggle"
