import sys
from pathlib import Path
import boto3
from botocore.exceptions import ClientError, ProfileNotFound


def load_snapshot_ids_from_file(file_path):
    """Reads snapshot IDs from a file and aggressively cleans hidden line break characters."""
    path = Path(file_path)
    if not path.is_file():
        print(f"[ERROR] File not found: {file_path}")
        sys.exit(1)

    snap_ids = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            # Strip spaces, carriage returns (\r), and newlines (\n)
            clean_line = line.strip().replace("\r", "").replace("\n", "")
            if clean_line and not clean_line.startswith("#"):
                # Extract pure snapshot ID if copied with extra text
                if "snap-" in clean_line:
                    start_idx = clean_line.find("snap-")
                    # EBS Snapshot IDs are typically 'snap-' + 8 or 17 hex chars
                    raw_id = clean_line[start_idx:].split()[0].split(",")[0]
                    snap_ids.append(raw_id)

    return list(set(snap_ids))


def get_ami_snapshot_mapping(ec2_client):
    """Retrieves AMIs accessible to 'self' and maps Snapshot ID -> AMI Details."""
    ami_map = {}
    try:
        # Check both self-owned AMIs and explicitly shared AMIs
        images_response = ec2_client.describe_images(
            Owners=["self"],
            ExecutableUsers=["self"]
        )
        for image in images_response.get("Images", []):
            ami_details = {
                "AmiId": image.get("ImageId"),
                "AmiName": image.get("Name", "N/A"),
                "AmiState": image.get("State"),
                "CreationDate": image.get("CreationDate"),
            }

            for block_device in image.get("BlockDeviceMappings", []):
                if "Ebs" in block_device and "SnapshotId" in block_device["Ebs"]:
                    snap_id = block_device["Ebs"]["SnapshotId"]
                    if snap_id not in ami_map:
                        ami_map[snap_id] = []
                    ami_map[snap_id].append(ami_details)

    except ClientError as e:
        print(f"  [ERROR] Describing images failed: {e}")

    return ami_map


def fetch_snapshots_safely(ec2_client, snapshot_ids):
    """Fetches snapshot details, querying individually if bulk requests throw NotFound errors."""
    found_snapshots = {}

    # Try querying individually to avoid one missing/cross-account snapshot failing the entire batch
    for snap_id in snapshot_ids:
        try:
            # Querying directly by SnapshotId works for both self-owned and shared snapshots
            response = ec2_client.describe_snapshots(SnapshotIds=[snap_id])
            for snap in response.get("Snapshots", []):
                found_snapshots[snap["SnapshotId"]] = snap
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            if error_code in ["InvalidSnapshot.NotFound", "InvalidGroup.NotFound"]:
                pass  # Truly doesn't exist in this region or account
            else:
                print(f"  [WARN] Could not fetch {snap_id}: {e}")

    return found_snapshots


def validate_snapshots_for_profile_region(profile_name, region_name, target_snap_ids):
    """Validates target snapshot IDs for a specific AWS Profile + Region."""
    print(f"\n{'='*70}\nProfile: [{profile_name}] | Region: [{region_name}]\n{'='*70}")

    try:
        session = boto3.Session(profile_name=profile_name, region_name=region_name)
        ec2_client = session.client("ec2")
        
        # Verify account identity for logging
        sts_client = session.client("sts")
        account_id = sts_client.get_caller_identity()["Account"]
        print(f"Connected as Account ID: {account_id}")

    except ProfileNotFound:
        print(f"[ERROR] Profile '{profile_name}' not found in AWS credentials.")
        return
    except ClientError as e:
        print(f"[ERROR] Authentication failed for {profile_name}: {e}")
        return

    # 1. Fetch AMI Mapping
    ami_map = get_ami_snapshot_mapping(ec2_client)

    # 2. Safely query individual snapshots
    found_snapshots = fetch_snapshots_safely(ec2_client, target_snap_ids)

    # 3. Process & Display Results
    associated_count = 0
    unassociated_count = 0

    for snap_id in target_snap_ids:
        if snap_id in found_snapshots:
            snap_info = found_snapshots[snap_id]
            size = snap_info.get("VolumeSize", "N/A")
            owner_id = snap_info.get("OwnerId", "Unknown")

            if snap_id in ami_map:
                associated_count += 1
                print(f"\n[+] Snapshot ID: {snap_id} ({size} GB | Owner: {owner_id}) -> ASSOCIATED")
                for ami in ami_map[snap_id]:
                    print(f"    └── AMI ID: {ami['AmiId']} | Name: {ami['AmiName']} | State: {ami['AmiState']}")
            else:
                unassociated_count += 1
                print(f"\n[-] Snapshot ID: {snap_id} ({size} GB | Owner: {owner_id}) -> UNASSOCIATED (No active AMI)")
        else:
            print(f"\n[?] Snapshot ID: {snap_id} -> NOT FOUND in Account [{account_id}] / Region [{region_name}]")

    print(f"\nSummary for {profile_name} ({region_name}): {associated_count} Associated | {unassociated_count} Unassociated")


if __name__ == "__main__":
    # --- CONFIGURATION ---
    INPUT_FILE = "snapshots.txt"
    PROFILES = ["default", "production", "staging"]  # Replace with your local profile names
    REGIONS = ["us-east-1", "us-west-2"]             # Replace with target regions

    snapshot_ids = load_snapshot_ids_from_file(INPUT_FILE)
    print(f"Loaded {len(snapshot_ids)} unique Snapshot IDs from '{INPUT_FILE}': {snapshot_ids}")

    for profile in PROFILES:
        for region in REGIONS:
            validate_snapshots_for_profile_region(profile, region, snapshot_ids)