#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Talk to 3PO (voice toggle)
# @raycast.mode silent

# Optional parameters:
# @raycast.icon images/peak.png
# @raycast.packageName ForceIQ Peak

# Documentation:
# @raycast.description forceiq-peak://voice: first run starts dictation, the next run stops it and hands the words to 3PO. Needs Voice turned on in Peak's Settings. Audio stays on this Mac.
# @raycast.author ForceIQ

open "forceiq-peak://voice"
