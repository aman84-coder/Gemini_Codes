# --- Configuration ---
$InputFile       = "C:\Scripts\SourceFiles.txt" # Plain text file, one path per line
$SourcePrefix    = "\\corp"                     
$DestinationBase = "\\fil_share_copy\corp"      
$LogFile         = "C:\Scripts\CopyLog.log"     
$MaxThreads      = 12

# --- Pre-Execution Setup ---
Function Write-Log {
    Param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$TimeStamp - $Message" | Out-File -FilePath $LogFile -Append
}

# --- Initialize Runspace Pool ---
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.Generic.List[PSObject]

# --- Load Input ---
if (!(Test-Path $InputFile)) { Write-Error "Input file not found!"; return }
$FilePaths = Get-Content $InputFile | Where-Object { $_ -match "\\\\" } # Only process lines that look like UNC paths

Write-Log "--- STARTING SESSION: Processing $($FilePaths.Count) lines from text file ---"

foreach ($SourceFilePath in $FilePaths) {
    # Clean up any accidental leading/trailing whitespace from the text file
    $SourceFilePath = $SourceFilePath.Trim()

    $ScriptBlock = {
        Param($SourceFile, $SrcPrefix, $DestBase, $Log)
        try {
            if (!(Test-Path $SourceFile)) { return "SKIP: Source missing: $SourceFile" }
            
            # 1. Case-Insensitive Prefix Replacement
            # This ensures that \\CORP and \\corp both work
            if ($SourceFile -ilike "$SrcPrefix*") {
                $RelativePath = $SourceFile.Substring($SrcPrefix.Length)
                $FullDestPath = $DestBase + $RelativePath
            } else {
                return "SKIP: Prefix mismatch for $SourceFile"
            }
            
            $TargetDir = [System.IO.Path]::GetDirectoryName($FullDestPath)
            $FileName  = [System.IO.Path]::GetFileName($SourceFile)
            $SourceDir = [System.IO.Path]::GetDirectoryName($SourceFile)

            if (!(Test-Path $TargetDir)) {
                New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            }

            # 2. Robocopy Execution
            $RoboParams = @("$SourceDir", "$TargetDir", "$FileName", "/SEC", "/B", "/Z", "/R:2", "/W:5", "/NP", "/NDL", "/NFL", "/LOG+:$Log")
            Start-Process robocopy -ArgumentList $RoboParams -Wait -WindowStyle Hidden
            
            return "SUCCESS: $SourceFile -> $FullDestPath"
        } catch {
            return "ERROR: $SourceFile - $($_.Exception.Message)"
        }
    }

    $PowerShell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($SourceFilePath).AddArgument($SourcePrefix).AddArgument($DestinationBase).AddArgument($LogFile)
    $PowerShell.RunspacePool = $RunspacePool
    
    $Jobs.Add((New-Object PSObject -Property @{
        Instance = $PowerShell
        Handle   = $PowerShell.BeginInvoke()
    }))
}

# --- Monitor ---
while ($Jobs.Handle.IsCompleted -contains $false) { Start-Sleep -Milliseconds 500 }

foreach ($Job in $Jobs) {
    $Result = $Job.Instance.EndInvoke($Job.Handle)
    if ($Result) { Write-Log $Result }
    $Job.Instance.Dispose()
}

$RunspacePool.Close()
Write-Log "--- SESSION COMPLETE ---"