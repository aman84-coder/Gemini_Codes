# --- Configuration ---
$InputFile       = "C:\Scripts\SourceFiles.csv" # Path to your CSV
$SourcePrefix    = "\\corp"                     # Common root to be replaced
$DestinationBase = "\\fil_share_copy\corp"      # New root destination
$LogFile         = "C:\Scripts\CopyLog.log"     # Where to log results
$MaxThreads      = 10                           # Recommended: 8-15 for network I/O

# --- Pre-Execution Setup ---
Function Write-Log {
    Param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$TimeStamp - $Message" | Out-File -FilePath $LogFile -Append
}

# Ensure destination exists
if (!(Test-Path $DestinationBase)) {
    New-Item -ItemType Directory -Path $DestinationBase -Force | Out-Null
}

# --- Initialize Runspace Pool (Multithreading Engine) ---
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.Generic.List[PSObject]

# --- Load Input ---
# Expects CSV with header "FilePath"
$Files = Import-Csv $InputFile 

Write-Log "--- STARTING SESSION: Mapping $SourcePrefix to $DestinationBase ---"

foreach ($Row in $Files) {
    $SourceFilePath = $Row.FilePath
    
    # Define the worker logic
    $ScriptBlock = {
        Param($SourceFile, $SrcPrefix, $DestBase, $Log)
        try {
            if (!(Test-Path $SourceFile)) { return "SKIP: Source missing: $SourceFile" }
            
            # 1. Calculate Destination Mapping
            # Example: \\corp\finance\file.txt -> \\fil_share_copy\corp\finance\file.txt
            $FullDestPath = $SourceFile.Replace($SrcPrefix, $DestBase)
            
            # 2. Extract Path Details using .NET for speed
            $TargetDir = [System.IO.Path]::GetDirectoryName($FullDestPath)
            $FileName  = [System.IO.Path]::GetFileName($SourceFile)
            $SourceDir = [System.IO.Path]::GetDirectoryName($SourceFile)

            # 3. Recreate Folder Structure
            if (!(Test-Path $TargetDir)) {
                New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            }

            # 4. Robocopy Execution
            # /SEC  = Copies Data, Attributes, Timestamps, and ACLs
            # /B    = Backup Mode (bypass NTFS owner restrictions)
            # /Z    = Restartable mode (safe for network drops)
            # /R:2 /W:5 = 2 Retries, 5 sec wait
            # /NP /NDL /NFL = Quiet mode to save memory/log space
            $RoboParams = @("$SourceDir", "$TargetDir", "$FileName", "/SEC", "/B", "/Z", "/R:2", "/W:5", "/NP", "/NDL", "/NFL", "/LOG+:$Log")
            Start-Process robocopy -ArgumentList $RoboParams -Wait -WindowStyle Hidden
            
            return "SUCCESS: $SourceFile -> $FullDestPath"
        } catch {
            return "ERROR: $SourceFile - $($_.Exception.Message)"
        }
    }

    # 5. Launch the Thread
    $PowerShell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($SourceFilePath).AddArgument($SourcePrefix).AddArgument($DestinationBase).AddArgument($LogFile)
    $PowerShell.RunspacePool = $RunspacePool
    
    $Jobs.Add((New-Object PSObject -Property @{
        Instance = $PowerShell
        Handle   = $PowerShell.BeginInvoke()
    }))
}

# --- Monitor Completion ---
while ($Jobs.Handle.IsCompleted -contains $false) {
    Write-Progress -Activity "Migrating Files" -Status "Threads active. Check $LogFile for details."
    Start-Sleep -Seconds 1
}

# --- Collect Results and Cleanup ---
foreach ($Job in $Jobs) {
    $Result = $Job.Instance.EndInvoke($Job.Handle)
    if ($Result) { Write-Log $Result }
    $Job.Instance.Dispose()
}

$RunspacePool.Close()
Write-Log "--- SESSION COMPLETE ---"