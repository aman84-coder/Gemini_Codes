import boto3
import csv
import sys

ec2 = boto3.client('ec2')
CSV_FILE = 'ec2_tags_fix.csv'

def export_current_tags():
    """Phase 1: Scan EC2 and create a CSV for you to edit"""
    print(f"Exporting tags to {CSV_FILE}...")
    instances = ec2.describe_instances()
    
    with open(CSV_FILE, mode='w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['InstanceID', 'Existing_Key', 'Existing_Value', 'New_Key', 'New_Value', 'Action'])
        
        for res in instances['Reservations']:
            for inst in res['Instances']:
                inst_id = inst['InstanceId']
                for tag in inst.get('Tags', []):
                    # We pre-fill New_Key/Value with the existing ones so you only edit what's wrong
                    writer.writerow([inst_id, tag['Key'], tag['Value'], tag['Key'], tag['Value'], 'KEEP'])
    print("Done. Edit the 'New_Key', 'New_Value', and set Action to 'UPDATE' for changes.")

def apply_fixes_from_csv():
    """Phase 2: Read the edited CSV and update AWS"""
    print(f"Reading {CSV_FILE} and applying updates...")
    with open(CSV_FILE, mode='r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row['Action'].upper() == 'UPDATE':
                # 1. Add the standardized tag
                ec2.create_tags(
                    Resources=[row['InstanceID']],
                    Tags=[{'Key': row['New_Key'], 'Value': row['New_Value']}]
                )
                
                # 2. If the Key name changed, delete the old one
                if row['Existing_Key'] != row['New_Key']:
                    ec2.delete_tags(
                        Resources=[row['InstanceID']],
                        Tags=[{'Key': row['Existing_Key']}]
                    )
                print(f"Fixed {row['InstanceID']}: {row['Existing_Key']} -> {row['New_Key']}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "export": export_current_tags()
        elif sys.argv[1] == "apply": apply_fixes_from_csv()
    else:
        print("Usage: python script.py [export|apply]")