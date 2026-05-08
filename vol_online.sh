#!/bin/bash

# --- Configuration ---
CLUSTER_IP="192.168.1.100"       # NetApp Management IP
ADMIN_USER="admin"               # Cluster Admin Username
VOL_FILE="volumes.txt"           # Text file containing volume names
LOG_FILE="vol_online_status.log"

# Check if input file exists
if [[ ! -f "$VOL_FILE" ]]; then
    echo "Error: Input file '$VOL_FILE' not found."
    exit 1
fi

echo "Starting volume check at $(date)" | tee -a "$LOG_FILE"

# Iterate through each volume in the text file
while IFS= read -r vol_name || [[ -n "$vol_name" ]]; do
    # Skip empty lines or comments
    [[ -z "$vol_name" || "$vol_name" =~ ^# ]] && continue

    echo "Checking volume: $vol_name"

    # 1. Check current state
    # We query the state and strip whitespace
    CURRENT_STATE=$(ssh "$ADMIN_USER@$CLUSTER_IP" "volume show -volume $vol_name -fields state" | awk 'NR==3 {print $2}' | tr -d '\r')

    if [[ "$CURRENT_STATE" == "online" ]]; then
        echo "  - Volume $vol_name is already online." | tee -a "$LOG_FILE"
    elif [[ -z "$CURRENT_STATE" ]]; then
        echo "  - Error: Volume $vol_name not found on cluster." | tee -a "$LOG_FILE"
    else
        echo "  - Volume $vol_name is $CURRENT_STATE. Attempting to bring online..." | tee -a "$LOG_FILE"
        
        # 2. Command to online the volume
        ONLINE_CMD=$(ssh "$ADMIN_USER@$CLUSTER_IP" "volume online -volume $vol_name" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            echo "  - Success: $vol_name is now online." | tee -a "$LOG_FILE"
        else
            echo "  - Failed to online $vol_name: $ONLINE_CMD" | tee -a "$LOG_FILE"
        fi
    fi

done < "$VOL_FILE"

echo "Finished at $(date)" | tee -a "$LOG_FILE"