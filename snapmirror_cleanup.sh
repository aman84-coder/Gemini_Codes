#!/bin/bash

# --- Configuration ---
DEST_CLUSTER="admin@dest-cluster-ip"
SRC_CLUSTER="admin@src-cluster-ip"
VOL_LIST="volumes.txt"

# Check if input file exists
if [ ! -f "$VOL_LIST" ]; then
    echo "Error: $VOL_LIST not found."
    exit 1
fi

echo "Starting Batch SnapMirror Cleanup..."

while IFS=, read -r SRC_PATH DEST_PATH; do
    echo "------------------------------------------------------"
    echo "Processing Destination: $DEST_PATH"

    # 1. Quiesce the relationship
    echo "[1/4] Quiescing..."
    ssh $DEST_CLUSTER "snapmirror quiesce -destination-path $DEST_PATH"

    # 2. Break the relationship
    echo "[2/4] Breaking..."
    ssh $DEST_CLUSTER "snapmirror break -destination-path $DEST_PATH"

    # 3. Delete the relationship (Destination side)
    echo "[3/4] Deleting relationship entry..."
    ssh $DEST_CLUSTER "snapmirror delete -destination-path $DEST_PATH"

    # 4. Release the relationship (Source side)
    # Note: destination-path is still used here to identify the relationship to release
    echo "[4/4] Releasing source snapshots on $SRC_CLUSTER..."
    ssh $SRC_CLUSTER "snapmirror release -destination-path $DEST_PATH -relationship-id *"
    
    echo "Done with $DEST_PATH"
done < "$VOL_LIST"

echo "------------------------------------------------------"
echo "Batch processing complete."