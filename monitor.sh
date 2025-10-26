#!/bin/bash

set -e

# --- Configuration ---
GAME_NAME="LEGO & Brickbuilding"
NFS_BASE_PATH="/mnt/nfs"
STREAMS_PATH="$NFS_BASE_PATH/streams"
UI_OUTPUT_PATH="$NFS_BASE_PATH/ui"
RECORDER_MAKEFILE_PATH="/app/recorder/Makefile" # Path inside the container

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


# --- 3. Fetch Live Streams and Start Recorders ---
echo "Fetching live streams for category ID $LEGO_CATEGORY_ID"...
STREAMS_RESPONSE=$(curl -s -X GET "https://api.twitch.tv/helix/streams?game_id=$LEGO_CATEGORY_ID&first=20" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Client-Id: $TWITCH_CLIENT_ID")
LIVE_STREAMS=$(echo "$STREAMS_RESPONSE" | jq -c '.data[]')

if [[ -z "$LIVE_STREAMS" ]]; then
    echo "No live streams found in the LEGO category."
else
    echo "Found live streams. Checking for active recorders..."
    echo "$LIVE_STREAMS" | while IFS= read -r stream; do
        STREAM_NAME_ORIGINAL=$(echo "$stream" | jq -r '.user_login')
        # Sanitize the name for Kubernetes by replacing underscores with hyphens.
        STREAM_NAME_KUBE=$(echo "$STREAM_NAME_ORIGINAL" | sed 's/_/-/g')

        if kubectl get deployment "stream-recorder-$STREAM_NAME_KUBE" >/dev/null 2>&1; then
            echo "Recorder for '$STREAM_NAME_ORIGINAL' is already running. Skipping."
        else
            echo "Starting new recorder for stream: $STREAM_NAME_ORIGINAL"
            # Pass the original name to the 'stream' variable for the makefile
            make -f "$RECORDER_MAKEFILE_PATH" apply "stream=$STREAM_NAME_ORIGINAL" "fps=0.1" "duration=3600"
        fi
    done
fi

# --- 4. Aggregate All Results for the UI ---
echo "Aggregating all hand-finder results for UI..."
AGGREGATED_JSON="{}"

for stream_dir in "$STREAMS_PATH"/*/; do
    if [ ! -d "$stream_dir" ]; then continue; fi
    stream_name=$(basename "$stream_dir")
    sample_dir="$stream_dir/sample"
    if [ ! -d "$sample_dir" ]; then continue; fi

    # Check if there are any json files to avoid errors
    if ls "$sample_dir"/*.json 1> /dev/null 2>&1; then
        json_array=$(jq -s '.' "$sample_dir"/*.json)
        if [[ -n "$json_array" && "$json_array" != "null" ]]; then
            AGGREGATED_JSON=$(echo "$AGGREGATED_JSON" | jq --argjson data "$json_array" --arg name "$stream_name" '. + {($name): $data}')
        fi
    fi
done

# --- 5. Write UI Data File ---
mkdir -p "$UI_OUTPUT_PATH"
output_file="$UI_OUTPUT_PATH/analysis_data.json"
echo "$AGGREGATED_JSON" > "$output_file"

echo "Wrote aggregated UI data to $output_file."
echo "--- Cycle finished. ---"
