# it is moved outside of vm_farm.ps1 because it has to be included into two places it it (due to parallel execution)
# by default waits for 4 minutes
function waitForSsh {
    param (
        [Parameter(Position = 0)]
        [string]$vmName,
        [Parameter(Position = 1)]
        [string]$vmIp,
        [Parameter(Position = 2)]
        [int]$attempts = 16,
        [Parameter(Position = 3)]
        [int]$retryDelay = 15
    )
    $vmPort = 22
    Write-Host "[$vmName] Waiting for SSH to be accessible at ${vmIp}:${vmPort}."
    $Global:ProgressPreference = 'SilentlyContinue'
    $ssh_up = $false
    for ($i = 1; $i -le $attempts; $i++) {
        Write-Debug("[$vmName] Waiting for SSH at ${vmIp}. Loop no.$i")
        $result = Test-NetConnection -ComputerName $vmIp -Port $vmPort -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Write-Debug("[$vmName] Result of connection: $result")
        if ($result -eq 'True') {
            Write-Host "[$vmName] SSH connection to $vmIp is possible. Server is fully up."
            $ssh_up = $true
            break
        } 
        else {
            # Connection failed
            if ( $i -lt $attempts){
                Write-Debug "[$vmName] Attempt $i : SSH connection failed. Waiting."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Debug "[$vmName] Attempt $i : SSH connection failed. It was last check."
            }
        }
    }
    # Check if all connection attempts failed
    if (-not $ssh_up) {
        Write-Output "[$vmName] Failed to establish SSH connection to $vmIp after $attempts attempts."
        Exit 100
    }
}
