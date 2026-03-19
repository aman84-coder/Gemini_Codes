#!/bin/bash

# --- CONFIGURATION ---
BUCKET_FILE="buckets.txt"
DRY_RUN=true  # Set to false to actually apply changes to AWS
# ---------------------

if [[ ! -f "$BUCKET_FILE" ]]; then
    echo "Error: $BUCKET_FILE not found."
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "--- DRY RUN MODE ENABLED (No changes will be made) ---"
fi

while IFS= read -r BUCKET_NAME || [[ -n "$BUCKET_NAME" ]]; do
    [[ -z "$BUCKET_NAME" || "$BUCKET_NAME" =~ ^# ]] && continue

    echo "Processing: $BUCKET_NAME"

    # 1. Fetch current policy (if any)
    EXISTING_POLICY=$(aws s3api get-bucket-policy --bucket "$BUCKET_NAME" --query 'Policy' --output text 2>/dev/null)

    # 2. Define the statement block using jq variables for safety
    # This prevents shell injection and handles the bucket ARN correctly
    NEW_STMT=$(jq -n --arg bucket "$BUCKET_NAME" '{
        Sid: "AllowSSLRequestsOnly",
        Action: "s3:*",
        Effect: "Deny",
        Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"],
        Condition: {
            Bool: { "aws:SecureTransport": "false" }
        },
        Principal: "*"
    }')

    # 3. Merge or Create
    if [ -z "$EXISTING_POLICY" ]; then
        FINAL_POLICY=$(jq -n --argjson stmt "$NEW_STMT" '{Version: "2012-10-17", Statement: [$stmt]}')
    else
        # Append only if Sid "AllowSSLRequestsOnly" doesn't already exist
        FINAL_POLICY=$(echo "$EXISTING_POLICY" | jq --argjson stmt "$NEW_STMT" '
            if (.Statement | type == "array") then
                if (.Statement | any(.Sid == "AllowSSLRequestsOnly")) then . else .Statement += [$stmt] end
            else
                # Handles cases where Statement might be a single object instead of an array
                if (.Statement.Sid == "AllowSSLRequestsOnly") then . else .Statement = [.Statement, $stmt] end
            fi')
    fi

    # 4. Execute or Print
    if [ "$DRY_RUN" = true ]; then
        echo "PROPOSED POLICY FOR $BUCKET_NAME:"
        echo "$FINAL_POLICY" | jq .
    else
        aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$FINAL_POLICY"
        [ $? -eq 0 ] && echo "Successfully updated $BUCKET_NAME" || echo "Failed to update $BUCKET_NAME"
    fi

    echo "-------------------------------------------------"

done < "$BUCKET_FILE"