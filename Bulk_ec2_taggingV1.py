import boto3
import csv
import os

# Configuration
CSV_FILE = 'ec2_multiregion_tags.csv'
# Optional: Define specific regions if you don't want to scan everything
# REGIONS = ['us-east-1', 'us-west-2'] 

def get_all_regions():
    """Fetches all enabled regions for the account."""
    client = boto3.client('ec2', region_name='us-east-1')
    regions = [region['RegionName'] for region in client.describe_regions()['Regions']]
    return regions

def export_tags():
    """Phase 1: Export tags from all regions into one CSV."""
    regions = get_all_regions()
    print(f"Starting export across {len(regions)} regions...")

    with open(CSV_FILE, mode='w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['Region', 'InstanceID', 'Tags', 'Action'])

        for region in regions:
            print(f"Scanning {region}...")
            ec2 = boto3.client('ec2', region_name=region)
            try:
                paginator = ec2.get_paginator('describe_instances')
                for page in paginator.paginate():
                    for res in page['Reservations']:
                        for inst in res['Instances']:
                            inst_id = inst['InstanceId']
                            tag_list = [f"{t['Key']}={t['Value']}" for t in inst.get('Tags', [])]
                            tags_string = ";".join(tag_list)
                            writer.writerow([region, inst_id, tags_string, 'KEEP'])
            except Exception as e:
                print(f"Could not scan region {region}: {e}")

    print(f"Export complete: {CSV_FILE}")

def apply_tags():
    """Phase 2: Read CSV and apply updates to specific regions."""
    if not os.path.exists(CSV_FILE):
        print(f"Error: {CSV_FILE} not found.")
        return

    with open(CSV_FILE, mode='r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get('Action', '').upper() != 'UPDATE':
                continue

            region = row['Region']
            inst_id = row['InstanceID']
            raw_tags = row['Tags']
            
            # Re-initialize client for each row's specific region
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
                    print(f"[{region}] Updated {inst_id}")
                except Exception as e:
                    print(f"[{region}] Failed {inst_id}: {e}")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        if sys.argv[1] == "export": export_tags()
        elif sys.argv[1] == "apply": apply_tags()
    else:
        print("Usage: python script.py [export|apply]")