#!/bin/bash

# --- CONFIGURATION ---
BUCKET_FILE="buckets.txt"
DRY_RUN=true  # Set to false to apply changes
LOG_DIR="policy_backups_$(date +%Y%m%d_%H%M%S)"

# Counters for the summary report
count_modified=0
count_skipped=0
count_failed=0
# ---------------------

mkdir -p "$LOG_DIR"

if [[ ! -f "$BUCKET_FILE" ]]; then
    echo "Error: $BUCKET_FILE not found."
    exit 1
fi

echo "--- Starting Audit & Enforcement ---"
echo "Log Directory: $LOG_DIR"
[ "$DRY_RUN" = true ] && echo "MODE: DRY RUN" || echo "MODE: LIVE"

while IFS= read -r BUCKET_NAME || [[ -n "$BUCKET_NAME" ]]; do
    [[ -z "$BUCKET_NAME" || "$BUCKET_NAME" =~ ^# ]] && continue

    echo "-------------------------------------------------"
    echo "Processing: $BUCKET_NAME"

    # 1. Fetch current policy
    EXISTING_POLICY=$(aws s3api get-bucket-policy --bucket "$BUCKET_NAME" --query 'Policy' --output text 2>/dev/null)
    
    # Save original for audit
    if [ -n "$EXISTING_POLICY" ]; then
        echo "$EXISTING_POLICY" | jq . > "$LOG_DIR/${BUCKET_NAME}_original.json"
    else
        echo "No existing policy." > "$LOG_DIR/${BUCKET_NAME}_original.json"
    fi

    # 2. Define the HTTPS Statement
    NEW_STMT=$(jq -n --arg bucket "$BUCKET_NAME" '{
        Sid: "AllowSSLRequestsOnly",
        Action: "s3:*",
        Effect: "Deny",
        Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"],
        Condition: { "Bool": { "aws:SecureTransport": "false" } },
        Principal: "*"
    }')

    # 3. Check if policy already exists to determine Skip vs Modify
    ALREADY_HAS_POLICY=false
    if [ -n "$EXISTING_POLICY" ]; then
        if echo "$EXISTING_POLICY" | jq -e '.Statement | if type=="array" then any(.Sid == "AllowSSLRequestsOnly") else .Sid == "AllowSSLRequestsOnly" end' > /dev/null; then
            ALREADY_HAS_POLICY=true
        fi
    fi

    if [ "$ALREADY_HAS_POLICY" = true ]; then
        echo "Skip: HTTPS enforcement already exists."
        ((count_skipped++))
        continue
    fi

    # 4. Generate Final JSON
    if [ -z "$EXISTING_POLICY" ]; then
        FINAL_POLICY=$(jq -n --argjson stmt "$NEW_STMT" '{Version: "2012-10-17", Statement: [$stmt]}')
    else
        FINAL_POLICY=$(echo "$EXISTING_POLICY" | jq --argjson stmt "$NEW_STMT" '.Statement = (if .Statement | type == "array" then .Statement + [$stmt] else [.Statement, $stmt] end)')
    fi

    echo "$FINAL_POLICY" | jq . > "$LOG_DIR/${BUCKET_NAME}_new.json"

    # 5. Execute
    if [ "$DRY_RUN" = true ]; then
        echo "Dry Run: Proposed policy saved to log folder."
        ((count_modified++))
    else
        aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$FINAL_POLICY"
        if [ $? -eq 0 ]; then
            echo "Success: Policy applied."
            ((count_modified++))
        else
            echo "Error: AWS rejection."
            ((count_failed++))
        fi
    fi

done < "$BUCKET_FILE"

# --- FINAL SUMMARY REPORT ---
echo -e "\n================================================="
echo "                EXECUTION SUMMARY                "
echo "================================================="
echo "Total Buckets Processed: $((count_modified + count_skipped + count_failed))"
echo "Modified/Proposed:       $count_modified"
echo "Already Compliant:       $count_skipped"
echo "Failed:                  $count_failed"
echo "Audit logs saved to:     $LOG_DIR"
echo "================================================="