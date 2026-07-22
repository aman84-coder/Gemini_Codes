import sys
from pathlib import Path
import boto3
from botocore.exceptions import ClientError, ProfileNotFound


def load_snapshot_ids_from_file(file_path):
    """Reads snapshot IDs from a text file (one ID per line)."""
    path = Path(file_path)
    if not path.is_file():
        print(f"[ERROR] File not found: {file_path}")
        sys.exit(1)

    with open(path, "r") as f:
        # Strip whitespace and filter out empty lines or comments
        snap_ids = [
            line.strip()
            for line in f
            if line.strip() and not line.strip().startswith("#")
        ]

    return list(set(snap_ids))  # Deduplicate


def get_ami_snapshot_mapping(ec2_client):
    """Retrieves all AMIs owned by 'self' and creates a map of Snapshot ID -> AMI Details."""
    ami_map = {}
    try:
        images_response = ec2_client.describe_images(Owners=["self"])
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


def validate_snapshots_for_profile_region(
    profile_name, region_name, target_snap_ids
):
    """Validates target snapshot IDs for a specific AWS Profile + Region."""
    print(
        f"\n{'='*70}\nProcessing Profile: [{profile_name}] | Region: [{region_name}]\n{'='*70}"
    )

    try:
        session = boto3.Session(
            profile_name=profile_name, region_name=region_name
        )
        ec2_client = session.client("ec2")
    except ProfileNotFound:
        print(f"[ERROR] Profile '{profile_name}' not found in AWS credentials.")
        return

    # 1. Map all local AMIs
    ami_map = get_ami_snapshot_mapping(ec2_client)

    # 2. Describe only the target snapshots from the file (chunked in batches of 200 due to API limits)
    batch_size = 200
    found_snapshots = {}

    for i in range(0, len(target_snap_ids), batch_size):
        chunk = target_snap_ids[i : i + batch_size]
        try:
            response = ec2_client.describe_snapshots(SnapshotIds=chunk)
            for snap in response.get("Snapshots", []):
                found_snapshots[snap["SnapshotId"]] = snap
        except ClientError as e:
            # Catches InvalidSnapshot.NotFound if a snapshot ID doesn't exist in this region/account
            print(f"  [WARN] Some snapshots were not found in this account/region.")

    # 3. Report findings
    associated_count = 0
    unassociated_count = 0

    for snap_id in target_snap_ids:
        if snap_id in found_snapshots:
            snap_info = found_snapshots[snap_id]
            size = snap_info["VolumeSize"]

            if snap_id in ami_map:
                associated_count += 1
                print(f"\n[+] Snapshot ID: {snap_id} ({size} GB) -> ASSOCIATED")
                for ami in ami_map[snap_id]:
                    print(
                        f"    └── AMI ID: {ami['AmiId']} | Name: {ami['AmiName']} | State: {ami['AmiState']}"
                    )
            else:
                unassociated_count += 1
                print(f"\n[-] Snapshot ID: {snap_id} ({size} GB) -> UNASSOCIATED")
        else:
            print(f"\n[?] Snapshot ID: {snap_id} -> NOT FOUND in this Profile/Region")

    print(
        f"\nSummary for {profile_name} ({region_name}): {associated_count} Associated | {unassociated_count} Unassociated"
    )


if __name__ == "__main__":
    # --- CONFIGURATION ---
    INPUT_FILE = "snapshots.txt"
    PROFILES = ["default", "production", "staging"]  # Add your AWS profile names
    REGIONS = ["us-east-1", "us-west-2"]             # Add your target regions

    # Load IDs from file
    snapshot_ids = load_snapshot_ids_from_file(INPUT_FILE)
    print(f"Loaded {len(snapshot_ids)} unique Snapshot IDs from '{INPUT_FILE}'.")

    # Loop through profiles and regions
    for profile in PROFILES:
        for region in REGIONS:
            validate_snapshots_for_profile_region(profile, region, snapshot_ids)