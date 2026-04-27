# Import the NetApp ONTAP Toolkit
Import-Module DataONTAP

# --- Configuration ---
# Ensure this is the Cluster Management IP, NOT the SVM IP
$FSxNManagementIP = "10.0.1.50" 
$SMTPServer       = "localhost" # Local SMTP relay
$EmailTo          = "infraops@yourcompany.com"
$EmailFrom        = "fsxn-reporter@yourcompany.com"
$EmailSubject     = "FSxN Volume Report - $(Get-Date -Format 'yyyy-MM-dd')"
$CsvPath          = "C:\Temp\FSxN_Volume_Report_$(Get-Date -Format 'yyyyMMdd').csv"

# Credentials
$Username = "fsxadmin"
# Note: Using single quotes prevents PowerShell from misinterpreting special characters like $ or @
$Password = ConvertTo-SecureString 'YourExactPasswordHere!' -AsPlainText -Force
$Creds    = New-Object System.Management.Automation.PSCredential ($Username, $Password)

try {
    # Connect to the FSxN Controller
    Write-Output "Connecting to FSxN Controller ($FSxNManagementIP)..."
    Connect-NcController -Name $FSxNManagementIP -Credential $Creds -ErrorAction Stop

    # Fetch all volumes
    Write-Output "Gathering volume data and options..."
    $Volumes = Get-NcVol

    # Build the custom dataset
    Write-Output "Processing volume metrics..."
    $ReportData = foreach ($Vol in $Volumes) {
        
        # 1. Fetch snapdir-access option safely
        $SnapDirOption = Get-NcVolOption -Name $Vol.Name | Where-Object { $_.Name -eq "snapdir-access" }
        $SnapDirValue = if ($SnapDirOption) { $SnapDirOption.Value } else { "N/A" }

        # 2. Unpack the nested Tiering Policy
        $TieringPolicy = if ($null -ne $Vol.VolumeTieringAttributes.TieringPolicy) {
            $Vol.VolumeTieringAttributes.TieringPolicy
        } elseif ($null -ne $Vol.TieringPolicy) {
            $Vol.TieringPolicy
        } else {
            "None"
        }

        # 3. Target the correct Percentage Used property
        $PercentUsed = if ($null -ne $Vol.PercentageSizeUsed) {
            $Vol.PercentageSizeUsed
        } else {
            $Vol.PercentageUsed
        }

        # Construct the object with exact requested headers
        [PSCustomObject]@{
            "volume"         = $Vol.Name
            "used"           = [math]::Round($Vol.Used / 1GB, 2) 
            "percent-used"   = $PercentUsed
            "Tiering-policy" = $TieringPolicy
            "snapdir-access" = $SnapDirValue
        }
    }

    # Export the dataset to CSV
    Write-Output "Exporting data to CSV: $CsvPath"
    $ReportData | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    # Send the email with the CSV attached
    Write-Output "Sending email report via local relay..."
    $EmailBody = "Please find the daily FSxN volume capacity and configuration report attached."
    
    Send-MailMessage -To $EmailTo `
                     -From $EmailFrom `
                     -Subject $EmailSubject `
                     -Body $EmailBody `
                     -SmtpServer $SMTPServer `
                     -Attachments $CsvPath

    Write-Output "Report generated and emailed successfully."

} catch {
    Write-Error "Failed to execute reporting script: $($_.Exception.Message)"
} finally {
    # Clean up the session and temp files
    if (Get-NcController -ErrorAction SilentlyContinue) { 
        Invoke-NcSystemApi -Name "security-api-session-delete" -ErrorAction SilentlyContinue 
    }
    if (Test-Path $CsvPath) {
        Remove-Item -Path $CsvPath -Force -ErrorAction SilentlyContinue
    }
}