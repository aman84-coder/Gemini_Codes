#!/bin/bash

# ==============================================================================
# Configuration Variables
# ==============================================================================
CLUSTER_IP="10.x.x.x"           # Source Cluster Management IP
SSH_USER="your_ssh_user"        # SSH username
SRC_VSERVER="your_source_svm"   # The Source SVM containing the volumes
DRY_RUN="true"                  # Set to "false" to actually execute the release

# ==============================================================================
# Pre-flight
# ==============================================================================
echo "=============================================================================="
echo "Querying cluster $CLUSTER_IP for SnapMirror relationships..."
if [[ "$DRY_RUN" == "true" ]]; then
    echo "WARNING: Running in DRY_RUN mode. No relationships will be released."
else
    echo "DANGER: DRY_RUN is false. Relationships WILL be released."
fi
echo "=============================================================================="

# ==============================================================================
# Step 1: Discover Relationships
# ==============================================================================
# 'set -rows 0' disables pagination so the output doesn't hang.
# We request only the source-path and destination-path fields.
RAW_LIST=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${CLUSTER_IP}" \
    "set -rows 0; snapmirror show -source-vserver ${SRC_VSERVER} -fields source-path,destination-path")

if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to connect or retrieve data from the cluster."
    exit 1
fi

# ==============================================================================
# Step 2: Parse and Execute
# ==============================================================================
# ONTAP output includes a header and a separator line.
# awk 'NR>2 && NF==2' skips the first two lines and ensures we only read valid pairs.
echo "$RAW_LIST" | awk 'NR>2 && NF==2 {print $1, $2}' | while read -r SRC_PATH DEST_PATH; do
    
    # Failsafe: Skip if either variable is empty
    [[ -z "$SRC_PATH" || -z "$DEST_PATH" ]] && continue

    echo ">>> Found Relationship: Source [ $SRC_PATH ] -> Destination [ $DEST_PATH ]"
    
    # The command to release the relationship from the source
    CMD="set -confirmations off; snapmirror release -source-path ${SRC_PATH} -destination-path ${DEST_PATH}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY RUN] Would execute: $CMD"
    else
        echo "    [EXECUTING] Releasing..."
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${CLUSTER_IP}" "$CMD"
        
        if [[ $? -eq 0 ]]; then
            echo "    [SUCCESS] Released base snapshots and relationship for $SRC_PATH."
        else
            echo "    [FAILED] Could not release relationship. Check cluster logs."
        fi
    fi
    echo "------------------------------------------------------------------------------"

done

echo "SnapMirror release batch job complete."