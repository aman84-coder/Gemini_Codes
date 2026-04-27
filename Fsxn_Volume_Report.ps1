# Import the NetApp ONTAP Toolkit
Import-Module DataONTAP

# --- Configuration ---
$FSxNManagementIP = "10.0.1.50" # Replace with your FSxN Management Endpoint IP
$SMTPServer       = "localhost" # Local SMTP relay
$EmailTo          = "infraops@yourcompany.com"
$EmailFrom        = "fsxn-reporter@yourcompany.com"
$EmailSubject     = "FSxN Volume Report - $(Get-Date -Format 'yyyy-MM-dd')"
$CsvPath          = "C:\Temp\FSxN_Volume_Report_$(Get-Date -Format 'yyyyMMdd').csv"

# Credentials (Retrieve dynamically in production)
$Username = "fsxadmin"
$Password = ConvertTo-SecureString "YourSecurePassword!" -AsPlainText -Force
$Creds    = New-Object System.Management.Automation.PSCredential ($Username, $Password)

try {
    # Connect to the FSxN Controller
    Write-Output "Connecting to FSxN Controller..."
    Connect-NcController -Name $FSxNManagementIP -Credential $Creds -ErrorAction Stop

    # Fetch all volumes
    Write-Output "Gathering volume data and options..."
    $Volumes = Get-NcVol

    # Build the custom dataset
    $ReportData = foreach ($Vol in $Volumes) {
        
        # Retrieve the specific snapdir-access option for the current volume
        $SnapDirOption = Get-NcVolOption -Volume $Vol.Name -Key "snapdir-access"

        # Construct the object with exact requested headers
        [PSCustomObject]@{
            "volume"         = $Vol.Name
            "used"           = [math]::Round($Vol.Used / 1GB, 2) # Converted bytes to GB for readability
            "percent-used"   = $Vol.PercentageUsed
            "Tiering-policy" = $Vol.TieringPolicy
            "snapdir-access" = $SnapDirOption.Value
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
    if (Get-NcController) { 
        Invoke-NcSystemApi -Name "security-api-session-delete" -ErrorAction SilentlyContinue 
    }
    if (Test-Path $CsvPath) {
        Remove-Item -Path $CsvPath -Force -ErrorAction SilentlyContinue
    }
}