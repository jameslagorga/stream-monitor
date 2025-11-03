#!/bin/bash

set -e

# --- Configuration ---
GAME_NAMES=(
    "LEGO & Brickbuilding"
    "Miniatures & Models"
)
NFS_BASE_PATH="/mnt/nfs"
STREAMS_PATH="$NFS_BASE_PATH/streams"
UI_OUTPUT_PATH="$NFS_BASE_PATH/ui"
RECORDER_MAKEFILE_PATH="/app/recorder"
ANNOTATOR_MAKEFILE_PATH="/app/annotator"
HAMER_MAKEFILE_PATH="/app/hamer"

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

# --- 2. Dynamically Fetch Category IDs ---
CATEGORY_IDS=()
for GAME_NAME in "${GAME_NAMES[@]}"; do
    echo "Fetching Category ID for '$GAME_NAME'"...
    # URL encode the game name
    GAME_NAME_ENCODED=$(echo "$GAME_NAME" | sed 's/ /%20/g' | sed 's/&/%26/g')
    GAMES_RESPONSE=$(curl -s -X GET "https://api.twitch.tv/helix/games?name=$GAME_NAME_ENCODED" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Client-Id: $TWITCH_CLIENT_ID")
    CATEGORY_ID=$(echo "$GAMES_RESPONSE" | jq -r '.data[0].id')

    if [[ -z "$CATEGORY_ID" || "$CATEGORY_ID" == "null" ]]; then
        echo "WARNING: Could not find Category ID for '$GAME_NAME'. Response: $GAMES_RESPONSE" >&2
    else
        echo "Successfully found Category ID for '$GAME_NAME': $CATEGORY_ID"
        CATEGORY_IDS+=($CATEGORY_ID)
    fi
done

if [ ${#CATEGORY_IDS[@]} -eq 0 ]; then
    echo "ERROR: No valid category IDs found." >&2
    exit 1
fi


# --- 3. Fetch Live Streams ---
GAME_ID_QUERY_PARAMS=$(printf "game_id=%s&" "${CATEGORY_IDS[@]}")
GAME_ID_QUERY_PARAMS=${GAME_ID_QUERY_PARAMS%&}
echo "Fetching live streams for category IDs ${CATEGORY_IDS[*]}..." 

ALL_LIVE_STREAMS_JSON="[]"
CURSOR=""

while true; do
    API_URL="https://api.twitch.tv/helix/streams?${GAME_ID_QUERY_PARAMS}&first=100"
    if [[ -n "$CURSOR" && "$CURSOR" != "null" ]]; then
        API_URL="${API_URL}&after=$CURSOR"
    fi

    STREAMS_RESPONSE=$(curl -s -X GET "$API_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Client-Id: $TWITCH_CLIENT_ID")

    # Check for errors in response
    if echo "$STREAMS_RESPONSE" | jq -e '.error' > /dev/null; then
        echo "ERROR: Twitch API returned an error: $(echo $STREAMS_RESPONSE | jq -r '.message')"
        break
    fi

    ALL_LIVE_STREAMS_JSON=$(echo "$ALL_LIVE_STREAMS_JSON" | jq --argjson new_data "$(echo "$STREAMS_RESPONSE" | jq '.data')" '. + $new_data')

    CURSOR=$(echo "$STREAMS_RESPONSE" | jq -r '.pagination.cursor')
    if [[ -z "$CURSOR" || "$CURSOR" == "null" ]]; then
        break # No more pages
    fi
done

LIVE_STREAMS=$(echo "$ALL_LIVE_STREAMS_JSON" | jq -c '.[]' | head -n 8)

# --- 4. Start Recorders ---
if [[ -z "$LIVE_STREAMS" ]]; then
    echo "No live streams found in the selected categories."
else
    echo "Found live streams. Checking for active recorders..."
    echo "$LIVE_STREAMS" | while IFS= read -r stream; do
        STREAM_NAME_ORIGINAL=$(echo "$stream" | jq -r '.user_login')
        KUBE_STREAM_NAME=$(echo "$STREAM_NAME_ORIGINAL" | sed 's/_/-/g' | sed 's/-$//')

        # Check for recorder
        if kubectl get job "stream-recorder-$KUBE_STREAM_NAME" >/dev/null 2>&1; then
            echo "Recorder for stream $STREAM_NAME_ORIGINAL already exists. Skipping."
        else
            echo "starting recorder for stream: $STREAM_NAME_ORIGINAL"
            sed -e "s/{{STREAM_NAME}}/$STREAM_NAME_ORIGINAL/g" -e "s/{{STREAM_NAME_KUBE}}/$KUBE_STREAM_NAME/g" -e "s/{{SAMPLING_FPS}}/${FPS:20}/g" /app/recorder/deployment.yaml.template | kubectl apply -f -
        fi
    done
fi
