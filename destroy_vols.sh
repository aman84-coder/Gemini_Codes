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

echo "Starting volume destruction batch job on cluster: $CLUSTER_IP"
echo "Reading from: $VOL_FILE"
echo "=============================================================================="

# ==============================================================================
# Execution Loop
# ==============================================================================
while IFS= read -r VOL_NAME || [[ -n "$VOL_NAME" ]]; do
    
    # Trim whitespace and skip empty lines/comments
    VOL_NAME=$(echo "$VOL_NAME" | xargs)
    [[ -z "$VOL_NAME" || "$VOL_NAME" == \#* ]] && continue

    echo ">>> Processing Volume: $VOL_NAME"

    # Added -n flag to prevent SSH from consuming the while loop's stdin
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${CLUSTER_IP}" \
        "set -confirmations off; \
         volume offline -vserver ${VSERVER} -volume ${VOL_NAME}; \
         volume destroy -vserver ${VSERVER} -volume ${VOL_NAME}"

    if [[ $? -eq 0 ]]; then
        echo "[SUCCESS] Offlined and destroyed: $VOL_NAME"
    else
        echo "[FAILED] Could not process: $VOL_NAME (Check cluster logs or SSH keys)"
    fi
    echo "------------------------------------------------------------------------------"

done < "$VOL_FILE"

echo "Batch job complete."