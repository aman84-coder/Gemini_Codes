#!/bin/bash

# Input CSV format: cluster_ip,svm_name
INPUT_FILE="clusters.csv"
OUTPUT_FILE="volume_report.csv"

# Write Header to Output
echo "Cluster,SVM,Volume,SnapshotPolicy" > "$OUTPUT_FILE"

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file $INPUT_FILE not found."
    exit 1
fi

while IFS=',' read -r cluster svm || [[ -n "$cluster" ]]; do
    # Skip header row if it exists
    [[ "$cluster" == "cluster" ]] && continue
    
    echo "Processing $cluster / $svm..."

    # SSH Command Breakdown:
    # -o BatchMode=yes: Ensures it doesn't hang for passwords
    # -q: Quiet mode to suppress many warnings
    # volume show: NetApp CLI command
    # -fields: Limits output to just what we need
    # -terse: Removes table formatting for easier parsing
    
    ssh -o BatchMode=yes -q "admin@$cluster" \
        "volume show -vserver $svm -fields snapshot-policy -terse" | \
        awk -F'\t' 'NR>1 {print "'$cluster'","'$svm'",$2,$3}' OFS=',' >> "$OUTPUT_FILE"

done < "$INPUT_FILE"

echo "Report generated: $OUTPUT_FILE"