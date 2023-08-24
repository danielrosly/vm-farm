# Get other parameters from command line parameters
param(
[Parameter(Mandatory=$true)]
[ValidateSet("Help", "Create", "Delete", "Start", "Stop", "Status", "Snapshot_create", "Snapshot_delete_last", "Snapshot_restore_last")]
[string]$Action,

[Parameter(Mandatory=$false)]
[string]$Param = "Empty"
)

if ($Action -eq "Help") {
@"
===========================================================================================================================

HELP:

Script creates/deletes and manages group of VMs in VirtualBox.`n
 - **Available commands**: Create, Delete, Start, Stop, Status, Snapshot_create, Snapshot_restore_last, Snapshot_delete_last, Help.
 - **Executing command**: vm_farm.ps1 -Action "name-of-command" [-Param "value-of-parameter"]

 Configuration:
 - of VM group and application itself: config\vm_initial_config.json
 - of individual VM applied to each of them: templates\\*.yml
 - Some params are also defined inside create_vbox_vm_ubuntu_cloud.ps1 script.

Characteristics of VMs:
 - VMs are numbered form 1 to max number.Their names contain common part (defined in config) followed by number.
 - Their IPs are set by adding number to last octet.`n

 Operations:
 - Operations Create, Start and Snapshot_restore_last allow to provide 'WAIT4SSH' as -Param. This waits for all servers to expose SSH at port 22.
 - Operation Create leaves SEED.ISO in DVD drive for started machine. Operation Stop ejects eventual DVDs from VMs, unless -Param is set to 'LEAVEDVD'.
 - Operation Stop kills VMs after several attempts to stop them gracefully. If -Param is set to "SHUTDOWN", then immediate kill is executed.

 Snapshots:
 - Snapshots with the same names are created for whole group.
 - Snapshots have names: Snapshot-YYYYMMDD-HHmmss (moment of creation)
 - Operation Snapshot_create allows to provide description of snapshot as -Param
 - Restoring last snapshot shuts down VMs (if they are running), restores snapshot and starts VMs again.

 Other:
 - You can add '-Debug' as first parameter to force application to ask for confirmation at the end (debug info is also printed).
"@ |  Show-Markdown
    Exit
}

# main parameters
try{
    # Check proper values of PARAM:
    if ( $Action -ne 'Snapshot_create'  -and @('Empty','WAIT4SSH','LEAVEDVD','SHUTDOWN') -notcontains $Param){
        Write-Error 'Wrong value of Param. Please execute following to get help: vm_farm.ps1 -Action "Help"'
        Exit
    }

    # Read configuration parameters either from fixed path or from environment variable
    Write-Debug "VM_FARM_CONFIG variable (without quotes): [$env:VM_FARM_CONFIG]"
    $config_dir = Get-Location
    if (Test-Path "Env:VM_FARM_CONFIG") {
        $config_dir = $env:VM_FARM_CONFIG
    }
    Write-Debug "Config dir: $config_dir"
    $config_file = "${config_dir}\config\vm_initial_config.json"
    Write-Debug "Config file: $config_file"
    if (-not (Test-Path $config_file)) {
        Write-Error "Configuration file '$config_file' does not exist."
        Exit
    }
    $config = Get-Content $config_file | ConvertFrom-Json    

    Write-Host "What to do: $Action"
    Write-Host "Parameter: $Param"
    Write-Host "Configuration: $($config | ConvertTo-Json -Depth 2)"
}
catch {
    Write-Error 'Error configuration. Please execute following to get help: vm_farm.ps1 -Action "Help"'
    Exit
}

Set-ExecutionPolicy -Scope CurrentUser Unrestricted

if ($Action -eq "Status") {
    if (-not (Test-Path "${config_dir}\hosts")) {
        Write-Error "File 'hosts' doesn't exist in directory ${config_dir}\."
        Exit 100
    }
    Write-Host "==============================================================================================="
    Write-Host " Name of VM       IP           SSH port   VM status    SSH works? " 
    $vms = & VBoxManage.exe list vms
    foreach ($vm in $vms) {
        # searching for IP
        $vmName = $vm -replace '^"(.+)" .+$','$1'
        $matchedLine = Get-Content -Path "${config_dir}\hosts" | Select-String -Pattern $vmName | Select-Object -ExpandProperty Line
        Write-Debug "Found [$matchedLine] for $vmName"
        if ($matchedLine){
            $index = (Get-Content -Path "${config_dir}\hosts").IndexOf($matchedLine)
            $ipLine = (Get-Content -Path "${config_dir}\hosts")[$index + 1]
            $ip = $ipLine.Substring($ipLine.IndexOf('ansible_host: ') + 14)
            $portLine = (Get-Content -Path "${config_dir}\hosts")[$index + 3]
            $port = $portLine.Substring($portLine.IndexOf('ansible_port: ') + 14)
            Write-Debug "Found $ip and $port for $vmName"

            $vmInfo = & VBoxManage.exe showvminfo $vmName
            # Extract the group names from the VM info
            $groups = $vmInfo | Select-String -Pattern "^Groups: (.+)$" | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}
            Write-Debug "Groups found: [$groups] for $vmName"
            # Check if the virtual machine belongs to the current group and printing info
            if ($groups -contains $($config.group_id)) {
                $output = & VBoxManage.exe showvminfo $vmName --machinereadable | Select-String -Pattern '^.*VMState="(.*)"$' | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}
                $result = Test-NetConnection -ComputerName $ip -Port $port -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if ($result -eq 'True'){
                    $ssh = 'yes'
                }
                else {
                    $ssh = 'no'
                }
                Write-Host " ${vmName}    ${ip}     ${port}       ${output}         ${ssh}"
            }
        }
    }
    Write-Host ''
    Exit
}

# first usage of function for creating VMs
. "${PSScriptRoot}\WaitForSsh.ps1"

. "${PSScriptRoot}\deleteVmDir.ps1"

if ($Action -eq "Create") {
    # clearing dirs
    for ($i = 1; $i -le $($config.no_of_servers); $i++) {
        $vmDir = "$($config.base_path)$($config.group_id)\$($config.names_of_servers)$i"
        Write-Debug "Checking directory: $vmDir"
        $result = ListAndDeleteDirectory $vmDir "\.iso$"
        if (-not $result){
            Write-Error "Directory $vmDir contains data. VM seems to exist there. Please delete it first. See command 'Delete'."
            Exit
        }
    }
    # creating VMs
    Unblock-File ${PSScriptRoot}\create_vbox_vm_ubuntu_cloud.ps1
    $t_ipArray = $($config.ips_of_servers_host_only).Split(".")
    $t_ipNatArray = $($config.ips_of_servers_nat).Split(".")
    $t_hosts  = @()
    for ($i = 1; $i -le $($config.no_of_servers); $i++) {
        # host only
        $t_lastOctet = [int]$t_ipArray[3] + $i
        $t_newIpAddress = $t_ipArray[0] + "." + $t_ipArray[1] + "." + $t_ipArray[2] + "." + $t_lastOctet
        # nat
        $t_lastOctet = [int]$t_ipNatArray[3] + $i
        $t_newIpNatAddress = $t_ipNatArray[0] + "." + $t_ipNatArray[1] + "." + $t_ipNatArray[2] + "." + $t_lastOctet
        $t_name = "$($config.names_of_servers)$i"
        Write-Host "`n`n`nCreating VM no.$i with name=$t_name and IP(HO)=$t_newIpAddress and IP(NAT)=$t_newIpNatAddress"
        $currentDir = Get-Location
        & $PSScriptRoot\create_vbox_vm_ubuntu_cloud.ps1 -name "$t_name" -ip_ho "$t_newIpAddress" -ip_nat "$t_newIpNatAddress" -group_id "$($config.group_id)" -base_path "$($config.base_path)" -vbox_host_only_adapter "$($config.host_only_network)" -vbox_natnet_adapter "$($config.nat_network)" -script_base "${config_dir}"
        Set-Location $currentDir
        $t_host_data = @{}
        $t_host_data["num"] = $i
        $t_host_data["ip"] = $t_newIpAddress
        $t_host_data["name"] = $t_name
        $t_hosts += $t_host_data
    }
    # Generate hosts file for ansible
    Set-Content -Path "${config_dir}\hosts" -Value "---`nall:`n  children:"
    foreach ($vm in $t_hosts){
        Write-Debug("Ansible line for $($vm.num)")
        if ( $vm.num -eq 1){
            Add-Content -Path "${config_dir}\hosts" -Value "    master:`n      hosts:`n        $($vm.name):`n          ansible_host: $($vm.ip)`n          ansible_user: $($config.user_name)`n          ansible_port: 22`n          ansible_connection: ssh`n          ansible_ssh_private_key_file: `"$($config.user_private_key)`""
        }
        else {
            if ( $vm.num -eq 2){
                Add-Content -Path "${config_dir}\hosts" -Value "    workers:`n      hosts:"
            }
            Add-Content -Path "${config_dir}\hosts" -Value "        $($vm.name):`n          ansible_host: $($vm.ip)`n          ansible_user: $($config.user_name)`n          ansible_port: 22`n          ansible_connection: ssh`n          ansible_ssh_private_key_file: `"$($config.user_private_key)`""
        }
    }
    if ( $Param -eq "WAIT4SSH" ) {
        Write-Host("`n")
        Write-Debug("Waiting for start of VMs. Sequential waiting.")
        $delay = $config.wait_for_ssh_minutes * 4
        foreach ($vm in $t_hosts){
            Write-Host("Foreach loop: waiting up to $($config.wait_for_ssh_minutes) minutes for start of $($vm.name)")
            waitForSsh $vm.name $vm.ip $delay 15
        }
    }
}
else {
    # Get the list of all virtual machines
    $vms = & VBoxManage.exe list vms

    # Generate a unique name for the snapshot - for case it is used, so it is the same for all machines
    $snapshotName = "Snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    # Building data for paralell loop
    $fullVms  = @()
    foreach ($vm in $vms) {

        # searching for IP
        if (-not (Test-Path "${config_dir}\hosts")) {
            Write-Error "File 'hosts' doesn't exist in directory ${config_dir}\."
            Exit 100
        }
        $vmName = $vm -replace '^"(.+)" .+$','$1'
        $matchedLine = Get-Content -Path "${config_dir}\hosts" | Select-String -Pattern $vmName | Select-Object -ExpandProperty Line
        Write-Debug "Found [$matchedLine] for $vmName"
        if ( -not $matchedLine){
            $ip = ''
        }
        else {
            $index = (Get-Content -Path "${config_dir}\hosts").IndexOf($matchedLine)
            $ipLine = (Get-Content -Path "${config_dir}\hosts")[$index + 1]
            $ip = $ipLine.Substring($ipLine.IndexOf('ansible_host: ') + 14)
            Write-Debug "Found $ip for $vmName"
        }

        $hashmap = @{}
        # Add key-value pairs to the hashmap
        $hashmap["vm"] = $vm
        $hashmap["ip"] = $ip
        $hashmap["action"] = $Action
        $hashmap["config"] = $config
        $hashmap["param"] = $Param
        $hashmap["snapshot"] = $snapshotName
        $hashmap["debug"] = $DebugPreference
        $hashmap["workdir"] = $PSScriptRoot
        $hashmap["confdir"] = $config_dir
        $fullVms += $hashmap
    }

    # Loop through each virtual machine - in parallel
    $fullVms | ForEach-Object -ThrottleLimit $config.parallel_execution_limit -Parallel {
        # =====================================================================================
        # PROCEDURES

        function isMachineRunning($vmName) {
            $output = & VBoxManage.exe showvminfo $vmName --machinereadable | Select-String -Pattern '^.*VMState="(.*)"$' | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}
            Write-Debug "[$vmName] Running check returned $output"
            if ($output -ne "poweroff" -and $output -ne "saved") {
                return $true
            }
            else {
                return $false
            }
        }
        
        function stopVM($vmName, $vmParam) {
            # Stop vm with the specified name
            Write-Debug "[$vmName] Executing stopVM for $vmName with vmParam: $vmParam."
            if (isMachineRunning $vmName) {
                if ($vmParam -eq 'Empty'){
                    Write-Debug "[$vmName] Shutting off gracefully."
                    & VBoxManage.exe controlvm $vmName acpipowerbutton
                    $t_res = 'stop'
                }
                else {
                    Write-Debug "[$vmName] Shutting off immediately."
                    & VBoxManage.exe controlvm $vmName poweroff
                    $t_res = 'poweroff'
                }
            } 
            # Attempts to check if VM is stopped - in total 3 minutes
            $maxTries = 36
            $delay = 5 # in seconds
            $tryCount = 0
            $success = $false
            do {
                $tryCount++
                Write-Debug "[$vmName] Checking if machine is running, attempt $tryCount..."
                if (isMachineRunning $vmName) {
                    Write-Debug "[$vmName] Still not stopped: $_"
                    Start-Sleep -Seconds $delay
                } else {
                    Write-Debug "[$vmName] Virtual machine $vmName stopped."
                    $success = $true
                }
            } while  (!$success -and $tryCount -lt $maxTries)
            if (-not $success) {
                & VBoxManage.exe controlvm $vmName poweroff
                Write-Debug "[$vmName] Virtual machine $vmName powered off."
                return 'poweroff'
            }
            return $t_res
        }

        $DebugPreference = $_.debug

        # =====================================================================================
        # MAIN BODY

        # Get the name of the virtual machine
        $vmName = $_.vm -replace '^"(.+)" .+$','$1'
        Write-Debug "[$vmName] Processing virtual machine: $vmName"

        # second usage of function in paralell execution
        $t_workdir = $_.workdir
        Write-Debug "[$vmName] Workdir: ${t_workdir}"
        . "${t_workdir}\WaitForSsh.ps1"

        # Action to execute
        $t_action = $_.action
        $t_start = $_.config.start_type
        $t_ip = $_.ip
        $t_param = $_.param
        $t_snapshot = $_.snapshot
        Write-Debug "[$vmName] Action: $t_action   Start type: $t_start"
        Write-Debug "[$vmName] Param is $t_param"
        Write-Debug "[$vmName] Snapshot is $t_snapshot"

        # Get the details of the virtual machine
        $vmInfo = & VBoxManage.exe showvminfo $vmName

        # Extract the group names from the VM info
        $groups = $vmInfo | Select-String -Pattern "^Groups: (.+)$" | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}
        Write-Debug "[$vmName] Groups found: [$groups]"

        # Check if the virtual machine belongs to the specified group
        if ($groups -contains $($_.config.group_id)) {
            $t_gid = $_.config.group_id
            $t_basepath = $_.config.base_path
            Write-Debug "[$vmName] Group Id is $t_gid  Base path is $t_basepath"
            Write-Host "`n[$vmName] Executing command $t_action for virtual machine $vmName"
            # =============================================
            # Different actions for machine that belongs to our group
            switch ($t_action) {
                "Delete" {
                    if (-not (isMachineRunning $vmName)) {
                        Write-Debug "[$vmName] Attempting delete of $vmName"
                        & VBoxManage.exe unregistervm $vmName --delete
                        $t_dir = $t_gid.Replace('/','\')
                        Write-Debug "[$vmName] Removing remains for VM. Location: $t_basepath$t_dir\$vmName"
                        Remove-Item -Path "$t_basepath$t_dir\$vmName" -Recurse -Force
                        Write-Host "[$vmName] Virtual machine $vmName has been deleted."
                    }
                    else {
                        Write-Host "[$vmName] Virtual machine $vmName is not powered off. Not deleting."
                    }
                }
                "Start" {
                    # Start vm with the specified name
                    if (-not (isMachineRunning $vmName)) {
                        & VBoxManage.exe startvm $vmName --type $($t_start)
                        Write-Host "[$vmName] Virtual machine $vmName started."
                    }
                    Write-Debug "[$vmName] Param is $t_param"
                    if ($t_param -eq "WAIT4SSH"){
                        waitForSsh $vmName $t_ip
                    }
                }
                "Stop" {
                    # Stop vm with the specified name
                    if (stopVM $vmName $t_param -eq 'stop') {
                        Write-Host "[$vmName] Stop function made machine $vmName stopped."
                    }
                    else {
                        Write-Host "[$vmName] Stop function made machine $vmName powered off."
                    }
                    # just make sure that DVD is empty, to prevent problems with starting
                    if ($t_param -ne "LEAVEDVD"){
                        Write-Debug "[$vmName] Ejecting DVD"
                        & VBoxManage.exe storageattach $vmName --storagectl "IDE" --port 1 --device 0 --medium emptydrive
                    }

                }
                "Snapshot_create" {
                    if ($t_param -eq "Empty"){
                        $t_desc = "Description not provided."
                    }
                    else {
                        $t_desc = $t_param
                    }
                    # Create the snapshot with the specified name
                    Write-Debug "[$vmName] Snapshot for $vmName named $t_snapshot desc: $t_desc"
                    & VBoxManage.exe snapshot $vmName take $t_snapshot --description="$t_desc"
                    # Output a message to the console indicating that the snapshot was created
                    Write-Host "[$vmName] Snapshot named $t_snapshot created."
                }
                "Snapshot_delete_last" {
                    # List of snapshots
                    $snapshots = & VBoxManage.exe snapshot $vmName list --machinereadable | Select-String -Pattern '^.*SnapshotName="(Snapshot-\d{8}-\d{6})"$' | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}

                    if ($null -eq $snapshots) {
                        Write-Host "[$vmName] No snapshots to delete for VM: $vmName"
                    }
                    else {
                        if ($snapshots.GetType().IsArray) {
                            $sortedSnapshots = $snapshots | Sort-Object -Descending
                            $lastSnapshot = $sortedSnapshots[0]
                        } else {
                            $lastSnapshot = $snapshots
                        }
    
                        # Delete last snapshot
                        & VBoxManage.exe snapshot $vmName delete $lastSnapshot
                        Write-Host "[$vmName] Deleted snapshot '$lastSnapshot'"
                    }
                }
                "Snapshot_restore_last" {
                    # List of snapshots
                    $snapshots = & VBoxManage.exe snapshot $vmName list --machinereadable | Select-String -Pattern '^.*SnapshotName="(Snapshot-\d{8}-\d{6})"$' | ForEach-Object {$_.Matches.Groups[1].Value.Trim()}

                    # Stop vm with the specified name. Immediately, as former state is restored anyway.
                    stopVM $vmName 'SHUTDOWN'

                    if ($snapshots.GetType().IsArray) {
                        $sortedSnapshots = $snapshots | Sort-Object -Descending
                        $lastSnapshot = $sortedSnapshots[0]
                    } else {
                        $lastSnapshot = $snapshots
                    }
            
                    # Attempts to restore snapshot
                    $maxTries = 5
                    $delay = 3 # in seconds
                    $tryCount = 0
                    $success = $false
                    do {
                        $tryCount++
                        Write-Debug "[$vmName] Trying commandlet, attempt $tryCount..."
                        $output = & VBoxManage.exe snapshot $vmName restore $lastSnapshot | Out-String
                        if ($output -contains "error: ") {
                            Write-Debug "[$vmName] Commandlet failed: $_"
                            Start-Sleep -Seconds $delay
                        } else {
                            $success = $true
                        }
                    } while  (!$success -and $tryCount -lt $maxTries)
                    if ($success) {
                        Write-Host "[$vmName] Restored snapshot '$lastSnapshot'"
                    }
                    else {
                        Write-Error "[$vmName] Failed to restore snapshot '$lastSnapshot'"
                        Write-Error "[$vmName] Don't know what to do. Please review VirtualBox config manually. Exiting."
                        Exit 10
                    }
            
                    # Start vm with the specified name
                    & VBoxManage.exe startvm $vmName --type $($t_start)
                    Write-Host "[$vmName] Started virtual machine: $vmName"                    
                    Write-Debug "[$vmName] Param is $t_param"
                    if ($t_param -eq "WAIT4SSH"){
                        waitForSsh $vmName $t_ip
                    }
                }
            }
            # =============================================
        }
    }
    if ($DebugPreference -ne "SilentlyContinue"){
        Write-Host "`nOperations finished. Press any key to continue..."
        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") > $null
    }
}



# Call the procedure with the parameters
#MyProcedure -Param1 $param1 -Param2 $param2 -Config $config
