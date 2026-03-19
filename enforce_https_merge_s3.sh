#!/bin/bash

BUCKET_FILE="buckets.txt"

if [[ ! -f "$BUCKET_FILE" ]]; then
    echo "Error: $BUCKET_FILE not found."
    exit 1
fi

# The Deny Statement to be injected
HTTPS_STATEMENT='{
  "Sid": "AllowSSLRequestsOnly",
  "Action": "s3:*",
  "Effect": "Deny",
  "Resource": [
    "arn:aws:s3:::REPLACE_BUCKET_NAME",
    "arn:aws:s3:::REPLACE_BUCKET_NAME/*"
  ],
  "Condition": {
    "Bool": {
      "aws:SecureTransport": "false"
    }
  },
  "Principal": "*"
}'

while IFS= read -r BUCKET_NAME || [[ -n "$BUCKET_NAME" ]]; do
    [[ -z "$BUCKET_NAME" || "$BUCKET_NAME" =~ ^# ]] && continue

    echo "Processing $BUCKET_NAME..."

    # 1. Try to get existing policy
    EXISTING_POLICY=$(aws s3api get-bucket-policy --bucket "$BUCKET_NAME" --query 'Policy' --output text 2>/dev/null)

    # Prepare the specific statement for this bucket
    CURRENT_STMT=$(echo "$HTTPS_STATEMENT" | sed "s/REPLACE_BUCKET_NAME/$BUCKET_NAME/g")

    if [ -z "$EXISTING_POLICY" ]; then
        # 2. No policy exists, create a new one
        FINAL_POLICY=$(jq -n --argjson stmt "$CURRENT_STMT" '{Version: "2012-10-17", Statement: [$stmt]}')
        echo "No existing policy found. Creating new one..."
    else
        # 3. Policy exists, append statement using jq
        # This checks if the Sid already exists to avoid duplicates
        FINAL_POLICY=$(echo "$EXISTING_POLICY" | jq --argjson stmt "$CURRENT_STMT" '
            if (.Statement | any(.Sid == "AllowSSLRequestsOnly")) then
                . 
            else
                .Statement += [$stmt]
            end')
        echo "Existing policy found. Merging HTTPS enforcement..."
    fi

    # 4. Apply the final JSON
    aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$FINAL_POLICY"
    
    if [ $? -eq 0 ]; then
        echo "Done: HTTPS enforced for $BUCKET_NAME."
    else
        echo "Error: Failed to update $BUCKET_NAME."
    fi
    echo "-------------------------------------------------"

done < "$BUCKET_FILE"