#!/bin/bash

# ==============================================================================
# Configuration Variables
# ==============================================================================
CLUSTER_IP="10.x.x.x"           # Replace with your Cluster Management IP
SSH_USER="your_ssh_user"        # Replace with your SSH username
VSERVER="your_vserver_name"     # Replace with the target SVM name
VOL_FILE="volumes.txt"          # Text file containing one volume name per line

# ==============================================================================
# Pre-flight Checks
# ==============================================================================
if [[ ! -f "$VOL_FILE" ]]; then
    echo "ERROR: Volume list file '$VOL_FILE' not found."
    exit 1
fi

echo "=============================================================================="
echo "DANGER: Starting FORCE DESTROY volume batch job on cluster: $CLUSTER_IP"
echo "This will aggressively remove snapshot locks and permanently delete volumes."
echo "Reading from: $VOL_FILE"
echo "=============================================================================="

# ==============================================================================
# Execution Loop
# ==============================================================================
while IFS= read -r VOL_NAME || [[ -n "$VOL_NAME" ]]; do
    
    # Trim whitespace and skip empty lines or comments
    VOL_NAME=$(echo "$VOL_NAME" | xargs)
    [[ -z "$VOL_NAME" || "$VOL_NAME" == \#* ]] && continue

    echo ">>> Forcefully Processing Volume: $VOL_NAME"

    # SSH command sequence:
    # 1. Elevate to advanced mode
    # 2. Disable confirmations
    # 3. Force-delete all snapshots, bypassing SnapMirror locks
    # 4. Offline the volume
    # 5. Destroy the volume
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${CLUSTER_IP}" \
        "set -privilege advanced; \
         set -confirmations off; \
         snapshot delete -vserver ${VSERVER} -volume ${VOL_NAME} -snapshot * -ignore-owners true; \
         volume offline -vserver ${VSERVER} -volume ${VOL_NAME}; \
         volume destroy -vserver ${VSERVER} -volume ${VOL_NAME}"

    if [[ $? -eq 0 ]]; then
        echo "[SUCCESS] Locks cleared, offlined, and destroyed: $VOL_NAME"
    else
        echo "[FAILED/PARTIAL] Could not fully process $VOL_NAME. (Check cluster logs)"
    fi
    echo "------------------------------------------------------------------------------"

done < "$VOL_FILE"

echo "Force destroy batch job complete."