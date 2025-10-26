#!/bin/bash

set -e

# --- Configuration ---
GAME_NAME="LEGO & Brickbuilding"
NFS_BASE_PATH="/mnt/nfs"
STREAMS_PATH="$NFS_BASE_PATH/streams"
UI_OUTPUT_PATH="$NFS_BASE_PATH/ui"
RECORDER_MAKEFILE_PATH="/app/recorder"
ANNOTATOR_MAKEFILE_PATH="/app/annotator"

echo "--- Running Monitor Cycle (Bash - Aggregation Only) ---"

# --- 1. Authenticate with Twitch ---
if [[ -z "$TWITCH_CLIENT_ID" || -z "$TWITCH_CLIENT_SECRET" ]]; then
    echo "ERROR: TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET must be set." >&2
    exit 1
fi
echo "Authenticating with Twitch..."
TOKEN_RESPONSE=$(curl -s -X POST "https://id.twitch.tv/oauth2/token?client_id=$TWITCH_CLIENT_ID&client_secret=$TWITCH_CLIENT_SECRET&grant_type=client_credentials")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to get Twitch access token." >&2
    exit 1
fi
echo "Successfully authenticated."

# --- 2. Dynamically Fetch Category ID ---
echo "Fetching Category ID for '$GAME_NAME'"...
# URL encode the game name
GAME_NAME_ENCODED=$(echo "$GAME_NAME" | sed 's/ /%20/g' | sed 's/&/%26/g')
GAMES_RESPONSE=$(curl -s -X GET "https://api.twitch.tv/helix/games?name=$GAME_NAME_ENCODED" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Client-Id: $TWITCH_CLIENT_ID")
LEGO_CATEGORY_ID=$(echo "$GAMES_RESPONSE" | jq -r '.data[0].id')

if [[ -z "$LEGO_CATEGORY_ID" || "$LEGO_CATEGORY_ID" == "null" ]]; then
    echo "ERROR: Could not find Category ID for '$GAME_NAME'. Response: $GAMES_RESPONSE" >&2
    exit 1
fi
echo "Successfully found Category ID for '$GAME_NAME': $LEGO_CATEGORY_ID"


# --- 3. Fetch Live Streams and Start Recorders and Annotators ---
echo "Fetching live streams for category ID $LEGO_CATEGORY_ID"...
STREAMS_RESPONSE=$(curl -s -X GET "https://api.twitch.tv/helix/streams?game_id=$LEGO_CATEGORY_ID&first=20" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Client-Id: $TWITCH_CLIENT_ID")
LIVE_STREAMS=$(echo "$STREAMS_RESPONSE" | jq -c '.data[]')

# --- 4. Clean Up Old Streams ---
echo "Cleaning up recorders and annotators for offline streams..."
RUNNING_RECORDERS=$(kubectl get deployments -l component=stream-recorder -o jsonpath='{range .items[*]}{.metadata.labels.stream}{"\n"}{end}')
LIVE_STREAM_NAMES=$(echo "$STREAMS_RESPONSE" | jq -r '.data[].user_login')

for stream_name in $RUNNING_RECORDERS; do
    if ! echo "$LIVE_STREAM_NAMES" | grep -q -w "$stream_name"; then
        echo "Stream $stream_name is offline. Deleting recorder and annotator."
        (cd $RECORDER_MAKEFILE_PATH && make delete "stream=$stream_name")
        (cd $ANNOTATOR_MAKEFILE_PATH && make delete "stream=$stream_name")
    fi
done


if [[ -z "$LIVE_STREAMS" ]]; then
    echo "No live streams found in the LEGO category."
else
    echo "Found live streams. Checking for active recorders..."
    echo "$LIVE_STREAMS" | while IFS= read -r stream; do
        STREAM_NAME_ORIGINAL=$(echo "$stream" | jq -r '.user_login')
        KUBE_STREAM_NAME=$(echo "$STREAM_NAME_ORIGINAL" | sed 's/_/-/g')

        # Check for recorder
        if kubectl get deployment "stream-recorder-$KUBE_STREAM_NAME" >/dev/null 2>&1; then
            echo "Recorder for stream $STREAM_NAME_ORIGINAL already exists. Skipping."
        else
            echo "starting recorder for stream: $STREAM_NAME_ORIGINAL"
            (cd $RECORDER_MAKEFILE_PATH && make apply "stream=$STREAM_NAME_ORIGINAL" "fps=${FPS:-.1}")
        fi

        # Check for annotator
        if kubectl get deployment "annotator-$KUBE_STREAM_NAME" >/dev/null 2>&1; then
            echo "Annotator for stream $STREAM_NAME_ORIGINAL already exists. Skipping."
        else
            echo "Starting new annotator deployment for stream: $STREAM_NAME_ORIGINAL"
            (cd $ANNOTATOR_MAKEFILE_PATH && make apply "stream=$STREAM_NAME_ORIGINAL")
        fi
    done
fi

echo "--- Cycle finished. ---"
