#!/bin/bash

# ==========================================
# Configuration Variables
# ==========================================
CLUSTER_IP="your_cluster_mgmt_ip"
SSH_USER="your_ssh_user"
VOL_FILE="volumes.txt"

# Email Configuration
EMAIL_FROM="storage-reports@onitygroup.com"
EMAIL_TO="storage-admin@onitygroup.com"
SUBJECT="ONTAP Volume Usage Report"

# ==========================================
# Pre-flight Checks
# ==========================================
if [ ! -f "$VOL_FILE" ]; then
    echo "Error: Input file '$VOL_FILE' not found!"
    exit 1
fi

# ==========================================
# Fetch Data from ONTAP
# ==========================================
echo "Fetching volume data from ONTAP cluster..."
RAW_DATA=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$CLUSTER_IP" \
    "set -rows 0; volume show -fields vserver,volume,files-used,used")

if [ $? -ne 0 ]; then
    echo "Error: Failed to connect or retrieve data from the ONTAP cluster."
    exit 1
fi

# ==========================================
# Parse Data and Generate HTML Table Rows
# ==========================================
echo "Parsing data against $VOL_FILE..."
TABLE_ROWS=$(echo "$RAW_DATA" | awk -v vol_file="$VOL_FILE" '
BEGIN {
    # Read the target volumes into memory before processing the ONTAP output
    while ((getline vol < vol_file) > 0) {
        # Strip potential Windows carriage returns
        sub(/\r$/, "", vol)
        if (vol != "") {
            wanted_vols[vol] = 1
        }
    }
    close(vol_file)
    output=0
}
# Start processing only after we see the header line
/^vserver/ { output=1; next }
# Skip the dashed separator line
/^--/ { next }
# Process lines where we have columns, and the volume name ($2) is in our wanted list
NF >= 4 && output == 1 {
    if ($2 in wanted_vols) {
        printf "<tr>\n"
        printf "  <td style=\"padding: 8px; border: 1px solid #ddd;\">%s</td>\n", $1
        printf "  <td style=\"padding: 8px; border: 1px solid #ddd;\">%s</td>\n", $2
        printf "  <td style=\"padding: 8px; border: 1px solid #ddd;\">%s</td>\n", $3
        printf "  <td style=\"padding: 8px; border: 1px solid #ddd;\">%s</td>\n", $4
        printf "</tr>\n"
    }
}')

# Check if any rows were actually generated
if [ -z "$TABLE_ROWS" ]; then
    echo "Warning: None of the volumes in $VOL_FILE were found on the cluster. Email aborted."
    exit 0
fi

# ==========================================
# Construct the Final HTML
# ==========================================
HTML_CONTENT="
<html>
<head>
  <style>
    table { border-collapse: collapse; width: 80%; font-family: Arial, sans-serif; }
    th { background-color: #f2f2f2; padding: 12px 8px; border: 1px solid #ddd; text-align: left; }
    td { padding: 8px; border: 1px solid #ddd; }
  </style>
</head>
<body>
  <h2>ONTAP Volume Usage Summary</h2>
  <table>
    <tr>
      <th>vserver</th>
      <th>volume</th>
      <th>fileused</th>
      <th>UsedSize(GB)</th>
    </tr>
    $TABLE_ROWS
  </table>
</body>
</html>
"

# ==========================================
# Send the Email (Python 3 SMTP Bypass)
# ==========================================
# We export these variables so Python can securely read them from the environment
export EMAIL_FROM EMAIL_TO SUBJECT HTML_CONTENT

echo "Generating email via local SMTP..."

python3 -c '
import smtplib, os
from email.mime.text import MIMEText

try:
    # Construct the email
    msg = MIMEText(os.environ["HTML_CONTENT"], "html", "utf-8")
    msg["Subject"] = os.environ["SUBJECT"]
    msg["From"] = os.environ["EMAIL_FROM"]
    msg["To"] = os.environ["EMAIL_TO"]

    # Connect to local mail server and send
    server = smtplib.SMTP("localhost")
    server.send_message(msg)
    server.quit()
    print(f"Success: Report generated and sent to {os.environ[\"EMAIL_TO\"]}.")
except ConnectionRefusedError:
    print("Error: Could not connect to localhost on port 25. Is Sendmail/Postfix running?")
except Exception as e:
    print(f"Error sending email: {e}")
'