import boto3
import csv
import os

# Configuration
CSV_FILE = 'ec2_multiregion_tags.csv'
# Restricted to your specific regions
TARGET_REGIONS = ['us-east-1', 'us-east-2'] 

def export_tags():
    """Phase 1: Export tags from us-east-1 and us-east-2 into one CSV."""
    print(f"Starting export for regions: {TARGET_REGIONS}...")

    with open(CSV_FILE, mode='w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['Region', 'InstanceID', 'Tags', 'Action'])

        for region in TARGET_REGIONS:
            print(f"Scanning {region}...")
            # Initialize client for specific region
            ec2 = boto3.client('ec2', region_name=region)
            try:
                paginator = ec2.get_paginator('describe_instances')
                for page in paginator.paginate():
                    for res in page['Reservations']:
                        for inst in res['Instances']:
                            inst_id = inst['InstanceId']
                            
                            # Build the single-column tag string
                            tag_list = [f"{t['Key']}={t['Value']}" for t in inst.get('Tags', [])]
                            tags_string = ";".join(tag_list)
                            
                            writer.writerow([region, inst_id, tags_string, 'KEEP'])
            except Exception as e:
                print(f"Error scanning {region}: {e}")

    print(f"Export complete. File saved as: {CSV_FILE}")

def apply_tags():
    """Phase 2: Read CSV and apply updates to us-east-1 and us-east-2."""
    if not os.path.exists(CSV_FILE):
        print(f"Error: {CSV_FILE} not found.")
        return

    print("Applying updates from CSV...")
    with open(CSV_FILE, mode='r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Only process if Action is UPDATE and region is in our allowed list
            if row.get('Action', '').upper() != 'UPDATE':
                continue
            
            region = row['Region']
            if region not in TARGET_REGIONS:
                print(f"Skipping row: Region {region} is not in allowed list.")
                continue

            inst_id = row['InstanceID']
            raw_tags = row['Tags']
            
            ec2 = boto3.client('ec2', region_name=region)
            
            new_tags = []
            if raw_tags:
                for pair in raw_tags.split(';'):
                    if '=' in pair:
                        k, v = pair.split('=', 1)
                        new_tags.append({'Key': k.strip(), 'Value': v.strip()})

            if new_tags:
                try:
                    ec2.create_tags(Resources=[inst_id], Tags=new_tags)
                    print(f"[{region}] Successfully updated {inst_id}")
                except Exception as e:
                    print(f"[{region}] Failed to update {inst_id}: {e}")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        if sys.argv[1] == "export": export_tags()
        elif sys.argv[1] == "apply": apply_tags()
    else:
        print("Usage: python script.py [export|apply]")