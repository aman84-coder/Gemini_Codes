#!/bin/bash

# --- Configuration ---
CLUSTER_IP="192.168.1.100"       # NetApp Management IP
ADMIN_USER="admin"               # Cluster Admin Username
VOL_FILE="volumes.txt"           # Text file containing volume names
LOG_FILE="vol_online_status.log"

# SSH Options to prevent hangs and prompt issues
SSH_OPTS="-n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"

if [[ ! -f "$VOL_FILE" ]]; then
    echo "Error: Input file '$VOL_FILE' not found."
    exit 1
fi

echo "-------------------------------------------" | tee -a "$LOG_FILE"
echo "Starting volume check: $(date)" | tee -a "$LOG_FILE"

while IFS= read -r vol_name || [[ -n "$vol_name" ]]; do
    [[ -z "$vol_name" || "$vol_name" =~ ^# ]] && continue
    
    # Clean volume name (remove whitespace/carriage returns)
    vol_name=$(echo "$vol_name" | tr -d '\r' | xargs)

    echo "Checking: $vol_name"

    # 1. Fetch the raw status line for the volume
    # We use -terse to get a comma-separated format that is version-independent
    RAW_OUT=$(ssh $SSH_OPTS "$ADMIN_USER@$CLUSTER_IP" "volume show -volume $vol_name -fields state -terse" 2>&1)

    # Check if the command actually succeeded
    if [[ $? -ne 0 ]]; then
        echo "  [ERROR] Connection failed for $vol_name. Check SSH keys/Network." | tee -a "$LOG_FILE"
        continue
    fi

    # 2. Extract state (look for 'online' or 'offline' in the string)
    if [[ "$RAW_OUT" == *"online"* ]]; then
        echo "  [SKIP] $vol_name is already online." | tee -a "$LOG_FILE"
    
    elif [[ "$RAW_OUT" == *"offline"* ]]; then
        echo "  [ACTION] $vol_name is offline. Bringing online..." | tee -a "$LOG_FILE"
        
        # Execute the online command
        RESULT=$(ssh $SSH_OPTS "$ADMIN_USER@$CLUSTER_IP" "volume online -volume $vol_name" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            echo "  [SUCCESS] $vol_name is now online." | tee -a "$LOG_FILE"
        else
            echo "  [FAILED] Error bringing $vol_name online: $RESULT" | tee -a "$LOG_FILE"
        fi
    else
        echo "  [NOT FOUND] Volume $vol_name not found or unexpected status." | tee -a "$LOG_FILE"
    fi

done < "$VOL_FILE"

echo "Finished at $(date)" | tee -a "$LOG_FILE"