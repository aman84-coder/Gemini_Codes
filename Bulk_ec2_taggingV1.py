import boto3
import csv
import os

ec2 = boto3.client('ec2')
CSV_FILE = 'ec2_tags_single_column.csv'

def apply_single_column_tags():
    if not os.path.exists(CSV_FILE):
        print(f"Error: {CSV_FILE} not found.")
        return

    print(f"Processing {CSV_FILE}...")

    with open(CSV_FILE, mode='r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        
        for row in reader:
            if row.get('Action', '').upper() != 'UPDATE':
                continue

            instance_id = row['InstanceID']
            raw_tags = row.get('Tags', '')
            
            if not raw_tags:
                continue

            # Convert "Key1=Val1;Key2=Val2" into Boto3 format
            new_tags = []
            try:
                # Split by semicolon, then split each pair by the first '='
                tag_pairs = raw_tags.split(';')
                for pair in tag_pairs:
                    if '=' in pair:
                        k, v = pair.split('=', 1)
                        new_tags.append({'Key': k.strip(), 'Value': v.strip()})
            except Exception as e:
                print(f"Error parsing tags for {instance_id}: {e}")
                continue

            if new_tags:
                try:
                    print(f"Applying {len(new_tags)} tags to {instance_id}...")
                    ec2.create_tags(Resources=[instance_id], Tags=new_tags)
                    print(f"Successfully updated {instance_id}")
                except Exception as e:
                    print(f"Failed to update {instance_id}: {e}")

if __name__ == "__main__":
    apply_single_column_tags()