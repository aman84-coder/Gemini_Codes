import csv
from datetime import datetime
from pathlib import Path
import sys
import boto3
from botocore.exceptions import ClientError, ProfileNotFound


def load_snapshot_ids_from_file(file_path):
    """Reads snapshot IDs from a file and cleans hidden characters and formatting."""
    path = Path(file_path)
    if not path.is_file():
        print(f"[ERROR] File not found: {file_path}")
        sys.exit(1)

    snap_ids = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            clean_line = line.strip().replace("\r", "").replace("\n", "")
            if clean_line and not clean_line.startswith("#"):
                if "snap-" in clean_line:
                    start_idx = clean_line.find("snap-")
                    raw_id = clean_line[start_idx:].split()[0].split(",")[0]
                    snap_ids.append(raw_id)

    return list(set(snap_ids))


def fetch_snapshots_safely(ec2_client, snapshot_ids):
    """Fetches snapshot details individually to prevent single missing ID failures."""
    found_snapshots = {}

    for snap_id in snapshot_ids:
        try:
            response = ec2_client.describe_snapshots(SnapshotIds=[snap_id])
            for snap in response.get("Snapshots", []):
                found_snapshots[snap["SnapshotId"]] = snap
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            if error_code in [
                "InvalidSnapshot.NotFound",
                "InvalidGroup.NotFound",
            ]:
                pass
            else:
                print(f"  [WARN] Could not fetch snapshot {snap_id}: {e}")

    return found_snapshots


def get_amis_for_snapshot(ec2_client, snapshot_id):
    """
    Directly queries AWS for any AMI (including deprecated/disabled/shared/backup)
    associated with a specific snapshot ID using native API block-device filters.
    """
    ami_details_list = []
    try:
        response = ec2_client.describe_images(
            Filters=[
                {
                    "Name": "block-device-mapping.snapshot-id",
                    "Values": [snapshot_id],
                }
            ],
            IncludeDeprecated=True,  # Crucial for capturing deprecated/archived AMIs
            IncludeDisabled=True,  # Captures disabled AMIs
        )

        for image in response.get("Images", []):
            ami_details_list.append(
                {
                    "AmiId": image.get("ImageId"),
                    "AmiName": image.get("Name", "N/A"),
                    "AmiState": image.get("State"),
                    "CreationDate": image.get("CreationDate"),
                    "OwnerId": image.get("OwnerId", "N/A"),
                }
            )

    except ClientError as e:
        print(f"  [ERROR] Failed to query AMI for {snapshot_id}: {e}")

    return ami_details_list


def export_to_csv(results, output_filename):
    """Exports structured snapshot validation results into a user-friendly CSV file."""
    fieldnames = [
        "AWS Profile",
        "Account ID",
        "Region",
        "Snapshot ID",
        "Snapshot Status",
        "Is Associated with AMI",
        "Volume Size (GB)",
        "Snapshot Start Time",
        "Snapshot Owner ID",
        "Associated AMI ID",
        "AMI Name",
        "AMI State",
        "AMI Owner ID",
        "AMI Creation Date",
    ]

    with open(
        output_filename, mode="w", newline="", encoding="utf-8"
    ) as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\n[SUCCESS] Validation report exported to: {output_filename}")


def process_all_profiles_and_regions(profiles, regions, input_file, output_csv):
    """Loops through profiles and regions, validates snapshots against AMIs, and generates CSV rows."""
    target_snap_ids = load_snapshot_ids_from_file(input_file)
    print(
        f"Loaded {len(target_snap_ids)} unique Snapshot IDs from '{input_file}'."
    )

    all_results = []

    for profile in profiles:
        for region in regions:
            print(
                f"\n{'='*70}\nProfile: [{profile}] | Region: [{region}]\n{'='*70}"
            )

            try:
                session = boto3.Session(
                    profile_name=profile, region_name=region
                )
                ec2_client = session.client("ec2")

                sts_client = session.client("sts")
                account_id = sts_client.get_caller_identity()["Account"]
                print(f"Connected as Account ID: {account_id}")

            except ProfileNotFound:
                print(
                    f"[ERROR] Profile '{profile}' not found in AWS credentials."
                )
                continue
            except ClientError as e:
                print(
                    f"[ERROR] Authentication/Connection failed for profile '{profile}': {e}"
                )
                continue

            found_snapshots = fetch_snapshots_safely(
                ec2_client, target_snap_ids
            )

            for snap_id in target_snap_ids:
                if snap_id in found_snapshots:
                    snap_info = found_snapshots[snap_id]
                    size = snap_info.get("VolumeSize", "N/A")
                    start_time = (
                        snap_info.get("StartTime", "").strftime(
                            "%Y-%m-%d %H:%M:%S"
                        )
                        if "StartTime" in snap_info
                        else "N/A"
                    )
                    owner_id = snap_info.get("OwnerId", "N/A")

                    # Direct lookup for AMIs associated with this specific snapshot ID
                    associated_amis = get_amis_for_snapshot(ec2_client, snap_id)

                    if associated_amis:
                        for ami in associated_amis:
                            all_results.append(
                                {
                                    "AWS Profile": profile,
                                    "Account ID": account_id,
                                    "Region": region,
                                    "Snapshot ID": snap_id,
                                    "Snapshot Status": "Found",
                                    "Is Associated with AMI": "Yes",
                                    "Volume Size (GB)": size,
                                    "Snapshot Start Time": start_time,
                                    "Snapshot Owner ID": owner_id,
                                    "Associated AMI ID": ami["AmiId"],
                                    "AMI Name": ami["AmiName"],
                                    "AMI State": ami["AmiState"],
                                    "AMI Owner ID": ami["OwnerId"],
                                    "AMI Creation Date": ami["CreationDate"],
                                }
                            )
                    else:
                        all_results.append(
                            {
                                "AWS Profile": profile,
                                "Account ID": account_id,
                                "Region": region,
                                "Snapshot ID": snap_id,
                                "Snapshot Status": "Found",
                                "Is Associated with AMI": "No",
                                "Volume Size (GB)": size,
                                "Snapshot Start Time": start_time,
                                "Snapshot Owner ID": owner_id,
                                "Associated AMI ID": "N/A",
                                "AMI Name": "N/A",
                                "AMI State": "N/A",
                                "AMI Owner ID": "N/A",
                                "AMI Creation Date": "N/A",
                            }
                        )
                else:
                    all_results.append(
                        {
                            "AWS Profile": profile,
                            "Account ID": account_id,
                            "Region": region,
                            "Snapshot ID": snap_id,
                            "Snapshot Status": "Not Found",
                            "Is Associated with AMI": "No",
                            "Volume Size (GB)": "N/A",
                            "Snapshot Start Time": "N/A",
                            "Snapshot Owner ID": "N/A",
                            "Associated AMI ID": "N/A",
                            "AMI Name": "N/A",
                            "AMI State": "N/A",
                            "AMI Owner ID": "N/A",
                            "AMI Creation Date": "N/A",
                        }
                    )

    if all_results:
        export_to_csv(all_results, output_csv)
    else:
        print("\n[WARN] No validation data collected.")


if __name__ == "__main__":
    # --- CONFIGURATION ---
    INPUT_FILE = "snapshots.txt"
    OUTPUT_CSV = f"snapshot_ami_validation_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    
    # Configure your AWS Named Profiles and target Regions
    PROFILES = ["default"]
    REGIONS = ["us-east-1", "us-east-2"]

    process_all_profiles_and_regions(
        PROFILES, REGIONS, INPUT_FILE, OUTPUT_CSV
    )