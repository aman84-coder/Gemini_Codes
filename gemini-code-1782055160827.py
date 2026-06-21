def transform_lens_data(raw_df):
    """Converts RAW AWS Storage Lens format into the Dashboard's expected format."""
    # 1. Make column names lowercase to avoid case-sensitivity issues
    raw_df.columns = raw_df.columns.str.lower().str.strip()

    # If it's already a formatted report, return it as-is
    if 'total_size_gb' in raw_df.columns:
        return raw_df

    # 2. Check if it's the raw AWS format
    if 'bucket_name' in raw_df.columns and 'metric_name' in raw_df.columns:
        
        # Filter for BUCKET level metrics to prevent double counting Accounts
        if 'record_type' in raw_df.columns:
            df_bucket = raw_df[raw_df['record_type'] == 'BUCKET'].copy()
        else:
            df_bucket = raw_df.copy()

        # Get Capacity Data (StorageBytes)
        df_storage = df_bucket[df_bucket['metric_name'] == 'StorageBytes'].copy()
        
        # Convert Bytes to Gigabytes safely
        df_storage['value_gb'] = pd.to_numeric(df_storage['metric_value'], errors='coerce').fillna(0) / (1024**3)
        df_storage['storage_class'] = df_storage['storage_class'].fillna('STANDARD')

        # Pivot the data so Storage Classes become Columns
        pivot = df_storage.pivot_table(
            index=['aws_account_number', 'bucket_name'],
            columns='storage_class',
            values='value_gb',
            aggfunc='sum'
        ).reset_index()

        # Rename core columns to match our Dashboard UI
        pivot.rename(columns={'aws_account_number': 'AccountId', 'bucket_name': 'BucketName'}, inplace=True)

        # Calculate Total Size GB
        storage_classes = [c for c in pivot.columns if c not in ['AccountId', 'BucketName']]
        pivot['Total_Size_GB'] = pivot[storage_classes].sum(axis=1)

        # Format tier column names (e.g., 'STANDARD' becomes 'STANDARD_GB')
        for c in storage_classes:
            pivot[f"{str(c).upper()}_GB"] = pivot[c]

        # Get Growth Data (MonthOverMonthStorageBytes) if it exists
        df_growth = df_bucket[df_bucket['metric_name'] == 'MonthOverMonthStorageBytes'].copy()
        if not df_growth.empty:
            df_growth['Growth_GB'] = pd.to_numeric(df_growth['metric_value'], errors='coerce').fillna(0) / (1024**3)
            growth_agg = df_growth.groupby('bucket_name')['Growth_GB'].sum().reset_index()
            growth_agg.rename(columns={'bucket_name': 'BucketName'}, inplace=True)
            pivot = pd.merge(pivot, growth_agg, on='BucketName', how='left').fillna({'Growth_GB': 0.0})
        else:
            pivot['Growth_GB'] = 0.0  # Safe fallback if AWS didn't export growth metrics

        return pivot
        
    return raw_df 

def get_combined_lens_data():
    """Finds all storage lens CSVs, transforms them, and combines them."""
    lens_files = [f for f in os.listdir(CSV_FOLDER) if f.endswith('.csv') and 'storage_lens' in f.lower()]
    if not lens_files: return None
        
    dfs = []
    for file in lens_files:
        file_path = os.path.join(CSV_FOLDER, file)
        try:
            raw_df = read_csv_safe(file_path)
            
            # --> NEW: Pass the raw data through our transformer <--
            clean_df = transform_lens_data(raw_df) 
            dfs.append(clean_df)
            
        except Exception as e:
            app.logger.error(f"Failed to read/transform {file}: {e}")
            
    if not dfs: return None

    # Combine all processed dataframes into one master list
    combined_df = pd.concat(dfs, ignore_index=True)
    if 'BucketName' in combined_df.columns:
        combined_df = combined_df.drop_duplicates(subset=['BucketName'])
        
    return combined_df