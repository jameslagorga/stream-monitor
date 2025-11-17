#!/bin/bash

set -eou pipefail

# --- Configuration ---
TARGET_RECORDER_COUNT="${TARGET_RECORDER_COUNT:-8}"
# Simplified list of categories to find top streams
GAME_NAMES=(
    "LEGO & Brickbuilding"
    "Miniatures & Models"
)
RECORDER_TEMPLATE_PATH="/app/recorder/deployment.yaml.template"

# --- 1. Authenticate with Twitch ---
if [[ -z "$TWITCH_CLIENT_ID" || -z "$TWITCH_CLIENT_SECRET" ]]; then
    echo "ERROR: TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET must be set." >&2
    exit 1
fi
TOKEN_RESPONSE=$(curl -s -X POST "https://id.twitch.tv/oauth2/token?client_id=$TWITCH_CLIENT_ID&client_secret=$TWITCH_CLIENT_SECRET&grant_type=client_credentials")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to get Twitch access token." >&2
    exit 1
fi

# --- 3. Get Recorder Job Status ---


# Get all streams that have a job, regardless of status
ALL_STREAM_JOBS=$(kubectl get jobs -l component=stream-recorder -o json | jq -r '.items[] | .metadata.labels.stream' | sort -u)
# Get only streams with an active pod
ACTIVE_STREAM_JOBS=$(kubectl get pods -l component=stream-recorder -o json | jq -r '.items[] | select(.status.phase == "Running") | .metadata.labels.stream' | sort -u)
ACTIVE_COUNT=$(echo "$ACTIVE_STREAM_JOBS" | wc -w | tr -d ' ')
echo "Found $ACTIVE_COUNT active recorder(s)."

# --- 4. Check if More Recorders are Needed ---
if [[ $ACTIVE_COUNT -ge $TARGET_RECORDER_COUNT ]]; then
    echo "Target recorder count of $TARGET_RECORDER_COUNT reached. Exiting."
    exit 0
fi

NEEDED_COUNT=$((TARGET_RECORDER_COUNT - ACTIVE_COUNT))
echo "Need to start $NEEDED_COUNT new recorder(s)."

# --- 5. Fetch Top Live Streams ---
echo "Fetching top live streams to find candidates..."
ALL_LIVE_STREAMS_JSON="[]"
for GAME_NAME in "${GAME_NAMES[@]}"; do
    GAME_NAME_ENCODED=$(echo "$GAME_NAME" | sed 's/ /%20/g; s/&/%26/g')
    GAME_ID=$(curl -s -X GET "https://api.twitch.tv/helix/games?name=$GAME_NAME_ENCODED" -H "Authorization: Bearer $ACCESS_TOKEN" -H "Client-Id: $TWITCH_CLIENT_ID" | jq -r '.data[0].id')
    if [[ -z "$GAME_ID" || "$GAME_ID" == "null" ]]; then
        echo "WARNING: Could not find Category ID for '$GAME_NAME'." >&2
        continue
    fi
    
    STREAMS_RESPONSE=$(curl -s -X GET "https://api.twitch.tv/helix/streams?game_id=${GAME_ID}&first=20" -H "Authorization: Bearer $ACCESS_TOKEN" -H "Client-Id: $TWITCH_CLIENT_ID")
    # Add streams to the list only if the API returned a valid data array
    if echo "$STREAMS_RESPONSE" | jq -e '.data and (.data | length > 0)' > /dev/null; then
        ALL_LIVE_STREAMS_JSON=$(echo "$ALL_LIVE_STREAMS_JSON" | jq --argjson new_data "$(echo "$STREAMS_RESPONSE" | jq '.data')" '. + $new_data')
    fi
done

# Filter for live streams
LIVE_STREAMS=$(echo "$ALL_LIVE_STREAMS_JSON" | jq -c '[.[] | select(.type == "live")]')

# --- 5a. Fetch Rankings from Query Service ---
echo "Fetching stream rankings from query-service..."
RANKINGS_JSON_RAW=$(curl -s "http://query-service.default.svc.cluster.local:8080/api/rankings")
RANKINGS_JSON="${RANKINGS_JSON_RAW:-[]}"

# --- 5b. Prioritize Streams by Hand Count ---
echo "Prioritizing streams by hand count history..."
# Use shell parameter expansion to provide a default of '[]' if the variables are empty or null.
# This prevents 'jq' from receiving a null input.
TOP_STREAMS=$(
  jq -n \
    --argjson live_streams "${LIVE_STREAMS:-[]}" \
    --argjson rankings "${RANKINGS_JSON:-[]}" '
    # Create a lookup map from rankings: {stream_name: four_or_more_hands_percentage}
    ($rankings
      | map({(.stream_name): .four_or_more_hands_percentage})
      | add
    ) as $rankings_map
    | $live_streams
    | map(
        . + {
          # Add the ranking score. Use 5.0 as a default (0.05 * 100) if not found in map.
          score: ($rankings_map[.user_login] // 5.0)
        }
      )
    # Sort by the new score, descending
    | sort_by(-.score)
  '
)


# --- 6. Find and Start New Recorders ---
CANDIDATE_COUNT=0
echo "$TOP_STREAMS" | jq -r '.[] | .user_login' | while IFS= read -r STREAM_NAME; do
    if [[ $CANDIDATE_COUNT -ge $NEEDED_COUNT ]]; then
        break
    fi

    # Check if this stream has any job associated with it already
    if echo "$ALL_STREAM_JOBS" | grep -q -w "$STREAM_NAME"; then
        echo "Stream '$STREAM_NAME' already has a job (active, succeeded, or failed). Skipping."
        continue
    fi

    CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))

    # Sanitize name for Kubernetes
    KUBE_STREAM_NAME=$(echo "$STREAM_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g' | sed 's/[^a-z0-9-]//g' | sed 's/^-*//' | sed 's/-*$//' | cut -c 1-63)

    echo "Starting new recorder for stream: $STREAM_NAME"
    sed -e "s/{{STREAM_NAME}}/$STREAM_NAME/g" \
        -e "s/{{STREAM_NAME_KUBE}}/$KUBE_STREAM_NAME/g" \
        -e "s/{{SAMPLING_FPS}}/20/g" \
        -e "s/{{DURATION}}/600/g" \
        "$RECORDER_TEMPLATE_PATH" | kubectl apply -f -
done


echo "--- Monitor run complete ---"
