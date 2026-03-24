import streamlit as st
import boto3
import re
import time

# Initialize Boto3 Client
ec2 = boto3.client('ec2')

st.set_page_config(page_title="AWS Storage Agent", page_icon="💾")

# Sidebar for Configuration
with st.sidebar:
    st.title("Settings")
    region = st.text_input("AWS Region", value="us-east-1")
    st.info("Ensure your IAM Role has permissions for: \n- ec2:DescribeInstances\n- ec2:DescribeVolumes\n- ec2:CreateSnapshot\n- ec2:DescribeSnapshots")

st.title("💬 EBS Operations Chat")
st.caption(f"Connected to Region: **{region}**")

# Initialize chat history
if "messages" not in st.session_state:
    st.session_state.messages = [{"role": "assistant", "content": "Hello! I can list volumes, snapshot individual disks, or snapshot ALL volumes for an instance. Just ask!"}]

# Helper to display chat
for msg in st.session_state.messages:
    st.chat_message(msg["role"]).write(msg["content"])

if prompt := st.chat_input():
    st.session_state.messages.append({"role": "user", "content": prompt})
    st.chat_message("user").write(prompt)

    response = ""
    try:
        ec2 = boto3.client('ec2', region_name=region)

        # LOGIC 1: List Volumes with SIZE
        if "list" in prompt.lower() and "i-" in prompt:
            instance_id = re.search(r'i-[a-z0-9]+', prompt).group()
            res = ec2.describe_instances(InstanceIds=[instance_id])
            vol_details = []
            for resv in res['Reservations']:
                for inst in resv['Instances']:
                    for dev in inst.get('BlockDeviceMappings', []):
                        v_id = dev['Ebs']['VolumeId']
                        v_info = ec2.describe_volumes(VolumeIds=[v_id])['Volumes'][0]
                        vol_details.append(f"- `{v_id}` (**{v_info['Size']} GiB**)")
            response = f"Volumes for `{instance_id}`:\n\n" + "\n".join(vol_details) if vol_details else "No volumes found."

        # LOGIC 2: Snapshot ALL volumes for an instance
        elif "snapshot all" in prompt.lower() and "i-" in prompt:
            instance_id = re.search(r'i-[a-z0-9]+', prompt).group()
            res = ec2.describe_instances(InstanceIds=[instance_id])
            snaps_created = []
            
            for resv in res['Reservations']:
                for inst in resv['Instances']:
                    for dev in inst.get('BlockDeviceMappings', []):
                        v_id = dev['Ebs']['VolumeId']
                        snap = ec2.create_snapshot(
                            VolumeId=v_id,
                            Description=f"Bulk snapshot for {instance_id}",
                            TagSpecifications=[{'ResourceType': 'snapshot', 'Tags': [{'Key': 'CreatedBy', 'Value': 'ChatBot_Bulk'}]}]
                        )
                        snaps_created.append(snap['SnapshotId'])
            
            response = f"🚀 **Bulk Action Started!**\n\nTriggered {len(snaps_created)} snapshots for `{instance_id}`: " + ", ".join([f"`{s}`" for s in snaps_created])

        # LOGIC 3: Check Progress of bot-triggered snapshots
        elif "progress" in prompt.lower() or "status" in prompt.lower():
            # Filters snapshots created by this bot using the Tag
            snaps = ec2.describe_snapshots(Filters=[{'Name': 'tag:CreatedBy', 'Values': ['ChatBot_Bulk', 'ChatAgent']}])['Snapshots']
            
            # Sort by start time to show most recent first
            sorted_snaps = sorted(snaps, key=lambda x: x['StartTime'], reverse=True)[:5]
            
            if not sorted_snaps:
                response = "I couldn't find any recent snapshots triggered by this bot."
            else:
                progress_list = []
                for s in sorted_snaps:
                    icon = "✅" if s['State'] == 'completed' else "⏳"
                    progress_list.append(f"{icon} `{s['SnapshotId']}`: **{s['State']}** ({s['Progress']})")
                response = "**Recent Snapshot Progress:**\n\n" + "\n".join(progress_list)

        # LOGIC 4: Single Snapshot
        elif "snapshot" in prompt.lower() and "vol-" in prompt:
            vol_id = re.search(r'vol-[a-z0-9]+', prompt).group()
            snap = ec2.create_snapshot(
                VolumeId=vol_id,
                TagSpecifications=[{'ResourceType': 'snapshot', 'Tags': [{'Key': 'CreatedBy', 'Value': 'ChatAgent'}]}]
            )
            response = f"✅ **Success!** Snapshot `{snap['SnapshotId']}` created for `{vol_id}`."

        else:
            response = "I didn't understand. Try:\n- 'List volumes for i-xxxx'\n- 'Snapshot all for i-xxxx'\n- 'Show progress'"

    except Exception as e:
        response = f"❌ **Error:** {str(e)}"

    st.session_state.messages.append({"role": "assistant", "content": response})
    st.chat_message("assistant").write(response)