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
# Read the file line by line. IFS= ensures trailing spaces don't break the read.
while IFS= read -r VOL_NAME || [[ -n "$VOL_NAME" ]]; do
    
    # Trim leading/trailing whitespace and skip empty lines or comments (#)
    VOL_NAME=$(echo "$VOL_NAME" | xargs)
    [[ -z "$VOL_NAME" || "$VOL_NAME" == \#* ]] && continue

    echo ">>> Processing Volume: $VOL_NAME"

    # SSH into the cluster and execute the commands.
    # -o BatchMode=yes prevents SSH from prompting for a password if keys fail.
    # set -confirmations off bypasses the ONTAP interactive "Are you sure?" prompt.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${CLUSTER_IP}" \
        "set -confirmations off; \
         volume offline -vserver ${VSERVER} -volume ${VOL_NAME}; \
         volume destroy -vserver ${VSERVER} -volume ${VOL_NAME}"

    # Check the exit status of the SSH command
    if [[ $? -eq 0 ]]; then
        echo "[SUCCESS] Offlined and destroyed: $VOL_NAME"
    else
        echo "[FAILED] Could not process: $VOL_NAME (Check cluster logs or SSH keys)"
    fi
    echo "------------------------------------------------------------------------------"

done < "$VOL_FILE"

echo "Batch job complete."