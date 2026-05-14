# --- Configuration ---
$InputFile       = "C:\Scripts\SourceFiles.txt" # Plain text file, one path per line
$SourcePrefix    = "\\corp"                     
$DestinationBase = "\\fil_share_copy\corp"      
$LogFile         = "C:\Scripts\CopyLog.log"     
$MaxThreads      = 12

# --- Setup ---
Function Write-Log {
    Param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host $Message # Print to console so you see it live
    "$TimeStamp - $Message" | Out-File -FilePath $LogFile -Append
}

# --- Load and Clean Input ---
if (!(Test-Path $InputFile)) { Write-Error "Input file not found!"; return }

# Read the file and strip any hidden BOM or whitespace
$FilePaths = Get-Content $InputFile | ForEach-Object { $_.Trim().Trim([char]65279) } | Where-Object { $_ -match "\\\\" }

Write-Log "--- STARTING SESSION: Total Files to process: $($FilePaths.Count) ---"

$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.Generic.List[PSObject]

foreach ($Path in $FilePaths) {
    $ScriptBlock = {
        Param($SourceFile, $SrcPrefix, $DestBase, $Log)
        try {
            # Robust Path Validation
            if (!(Test-Path -Path $SourceFile -PathType Leaf)) { 
                return "SKIP: Source missing or inaccessible: [$SourceFile]" 
            }
            
            # Mapping Logic
            if ($SourceFile -ilike "$SrcPrefix*") {
                $RelativePath = $SourceFile.Substring($SrcPrefix.Length)
                $FullDestPath = $DestBase + $RelativePath
                $TargetDir    = [System.IO.Path]::GetDirectoryName($FullDestPath)
                $FileName     = [System.IO.Path]::GetFileName($SourceFile)
                $SourceDir    = [System.IO.Path]::GetDirectoryName($SourceFile)
            } else {
                return "SKIP: Prefix mismatch for $SourceFile"
            }

            # Create Folder Structure
            if (!(Test-Path $TargetDir)) {
                New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            }

            # Robocopy Execution
            $RoboParams = @("$SourceDir", "$TargetDir", "$FileName", "/SEC", "/B", "/Z", "/R:1", "/W:2", "/NP", "/NDL", "/NFL", "/LOG+:$Log")
            $Process = Start-Process robocopy -ArgumentList $RoboParams -Wait -PassThru -WindowStyle Hidden
            
            if ($Process.ExitCode -lt 8) {
                return "SUCCESS: $SourceFile"
            } else {
                return "ERROR: Robocopy failed with code $($Process.ExitCode) for $SourceFile"
            }
        } catch {
            return "ERROR: Critical failure on $SourceFile - $($_.Exception.Message)"
        }
    }

    $PowerShell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($Path).AddArgument($SourcePrefix).AddArgument($DestinationBase).AddArgument($LogFile)
    $PowerShell.RunspacePool = $RunspacePool
    $Jobs.Add((New-Object PSObject -Property @{ Instance = $PowerShell; Handle = $PowerShell.BeginInvoke() }))
}

# --- Monitor ---
while ($Jobs.Handle.IsCompleted -contains $false) { Start-Sleep -Milliseconds 200 }

foreach ($Job in $Jobs) {
    $Result = $Job.Instance.EndInvoke($Job.Handle)
    if ($Result) { Write-Log $Result }
    $Job.Instance.Dispose()
}

$RunspacePool.Close()
Write-Log "--- SESSION COMPLETE ---"