# Create VBOX Ubuntu VM from Ubuntu Cloud Image
#
# Author: Ricardo Sanchez (ricsanfre@gmail.com)
# Script automate:
# - Img Download from Ubuntu website
# - Image conversion to VBox vdi format
# - Initial configuration through cloud-init
# - VM creation, configuration and startup

# Pre-requisites: 
# 1. Powershell 7.0
#     Out-File command generate by default files in utf8NoBOM format (Compatible with cloud-init)
#     PS 5 version Out-File does not generate files that are unix-compatible
# 2. PowerShell policy is required:
#     Set-ExecutionPolicy -Scope CurrentUser Unrestricted
# 3. QEMU-IMG installed and set $qemu_img_exe variable below. Location :  https://cloudbase.it/qemu-img-windows/
# 4. CDBurnerXP installed and set $cdbxpcmd_exe variable below. Location :  https://cdburnerxp.se/pl/
# 5. VBoxManage.exe should be in Path system variable.

# Input pararmeters
param([Switch] $help,
      [string] $base_path='d:\VirtualMachines',
      [string] $name='',
      [string] $ip_ho='',
      [string] $ip_nat='',
      [string] $vbox_natnet_adapter='',
      [string] $vbox_host_only_adapter='',
      [string] $force_download='false',
      [string] $group_id='',
      [string] $script_base = ''
      )

# Printing help message
if ( $help -or ( $name -eq '') -or ( $ip_ho -eq '' ) -or ( $ip_nat -eq '' ) -or ( $vbox_natnet_adapter -eq '' ) -or ( $vbox_host_only_adapter -eq '' ))
{
  
@"

Script Usage:

create_vbox_vm_ubuntu_cloud.ps1 -name *server_name*
                                -path *path*
                                -ip_ho *server_ip_ho*
                                -ip_nat *server_ip_nat*
                                -vbox_natnet_adapter *natnet_if*
                                -vbox_host_only_adapter *hostonly_if*


Parameters:
- **name**: (M) server name. VM server name and hostname. (M)
- **ip_ho**: (M) must belong to selected VBox HostOnly network
- **ip_nat**: (M) must belong to selected VBox NAT Network
- **path**: (O) Base path used for creating the VM directory (default value: my directory). A directory with name **name** is created in **path** directory. If a server already exists within that directory, VM is not created. 
- **vbox_natnet_adapter** (O) and **vbox_host_only_adapter** (O): VBOX interfaces names
- **force_downloas** (O): Force download of img even when there is an existing image
- **group_id** (O): Name of group to be used to locate VM in VirtualBox


VM is created with two interfaces:
- **NIC1** NAT network with static ip (server_ip_ho)
- **NIC2** hostonly with static ip (server_ip_nat)

> NOTE: VBOX interfaces adapter names might need to be adapted to your own environment
> Commands for obtained VBOX configured interfaces
    vboxmanage list hostonlyifs
    vboxmanage list natnets

The script will download img from ubuntu website if it is not available in **img** directory or *force_download* true parameter has been selected

The script will be use user-data, network-config and vm-config templates located in **templates** directory named with *server_name* suffix:
- user-data-*server_name*.yml
- network-config-*server_name*.yml
- vm-config-*server_name*.yml

If any of the files is missing the `default` files will be used.

"@ | Show-Markdown
  
  exit
}

$temp_base = [System.IO.Path]::GetTempPath() + "vbox_vm.tmp\"
New-Item -ItemType Directory -Path "$temp_base" -Force
if ($script_base -eq ''){
  $script_base = $PSScriptRoot
}
Write-Debug "Using Temporary Directory: $temp_base and Script Base: $script_base"

# Exec files
$qemu_img_exe = "C:\Program Files\QEMU\qemu-img.exe"
$cdbxpcmd_exe = "C:\Program Files\CDBurnerXP\cdbxpcmd.exe"

# Getting Parameters - first part
$server_name=$name
$server_ip_ho=$ip_ho
$server_ip_nat=$ip_nat

# Setting working directories
if ($group_id -eq ''){
  $working_directory="${base_path}\${server_name}"
}
else {
  $working_directory="${base_path}${group_id}\${server_name}"
}

# Check if working directory already exists
if (Test-Path -Path $working_directory)
{
  Write-Error "ERROR: Server ${server_name} already exits within directory ${base_path}"
  exit 10
}

# Setting cloud-init templates
$userdata_template = ${server_name}
$network_template = ${server_name}
$vm_template = ${server_name}

if ( -not (Test-Path -Path ${script_base}\templates\user-data-${userdata_template}.yml) )
{
  # If specific user-data template does not exit use default template
  $userdata_template = 'default'
}

if ( -not (Test-Path -Path ${script_base}\templates\network-config-${network_template}.yml) )
{
  # If specific network-config template does not exit use default template
  $network_template = 'default'
}

if ( -not (Test-Path -Path ${script_base}\templates\vm-config-${vm_template}.yml) )
{
  # If specific vm-config template does not exit use default template
  $vm_template = 'default'
}

# Check cloud init templates exit: specific or default
if ( -not (Test-Path -Path ${script_base}\templates\user-data-${userdata_template}.yml) -or
    -not (Test-Path -Path ${script_base}\templates\network-config-${network_template}.yml) -or
    -not (Test-Path -Path ${script_base}\templates\vm-config-${vm_template}.yml) )
{
  Write-Error "ERROR: Cloud init templates for ${server_name} do not exist in ${script_base}\templates"
  exit 100
}

Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
Install-Module powershell-yaml
$vmYaml = Get-Content -Path "${script_base}\templates\vm-config-${vm_template}.yml" -Raw | ConvertFrom-Yaml

# Getting Parameters - second part - hardware parameters of VMs
$server_memory = $vmYaml.vm.memory
$server_cores = $vmYaml.vm.cores
$server_disk_size = $vmYaml.vm.disk_size
$ubuntuversion = $vmYaml.vm.ubuntu_version

@"
Creating VM with the following parameters

  - Ubuntu Release: ${ubuntuversion}
  - Memory: ${server_memory}
  - CPU Cores: ${server_cores}
  - Disk: ${server_disk_size}
  - Cloud-init user-data template: user-data-${userdata_template}.yml
  - Cloud-init network-config template: network-config-${network_template}.yml
  - NIC1 - NatNetwork: ${vbox_natnet_adapter}. IP: ${server_ip_nat}
  - NIC2 - HostOnlyAdapter: ${vbox_host_only_adapter}. IP: ${server_ip_ho}
  
"@ | Write-Output

# Check if configured adapters
Write-Output "Checking VBOX interfaces adapters..."
$found_natnet_adapter=$false
$found_hostonly_adapter=$false

# Obtain configured hostonly and natnet adapter names
$vbox_natnetifs = & VBoxManage.exe list natnets | Select-String "^Name:"

Write-Output "NatNets Adapters:"
foreach ($if in $vbox_natnetifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  Write-Output "${interface}"
  if ( $interface -eq $vbox_natnet_adapter )
  {
    $found_natnet_adapter=$true
  }
}
$vbox_hostonlyifs= & VBoxManage.exe list hostonlyifs | Select-String "^Name:"
Write-Output "HostOnly Adapters:"
foreach ($if in $vbox_hostonlyifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  Write-Output "${interface}"
  if ( $interface -eq $vbox_host_only_adapter )
  {
    $found_hostonly_adapter=$true
  }
}

if ( ( -not $found_natnet_adapter ) -or (-not $found_hostonly_adapter) )
{
  Write-Error "ERROR: Interfaces adapters not found in VBOX. Please review your config."
  exit 100
}

$seed_directory_name="seed"
$seed_directory="${working_directory}\${seed_directory_name}"

## image type: ova, vmdk, img, tar.gz
$imagetype="img"
$distro="ubuntu-${ubuntuversion}-server-cloudimg-amd64"
$img_dist="${distro}.${imagetype}"
$img_raw="${distro}.raw"
$img_vdi="${distro}.vdi"
$seed_iso="seed.iso"

## URL to most recent cloud image
$releases_url="https://cloud-images.ubuntu.com/releases/${ubuntuversion}/release"
$img_url="${releases_url}/${img_dist}"

# Step 1. Create working directory
Write-Output "Creating Working directory ${working_directory}"
if ($group_id -eq ''){
  New-Item -Path ${base_path} -Name ${server_name} -ItemType "directory"
}
else {
  New-Item -Path ${base_path}${group_id} -Name ${server_name} -ItemType "directory"
}


# Step 2. Move to working directory
Write-Output "Moving to working directory ${working_directory}"
Set-Location $working_directory

# Step 3 download Img if not already downloaded or force download has been selected 
# Remove PS download progress bar to speed up the download

if ( -not (Test-Path -Path "${temp_base}${img_dist}" -PathType Leaf) -or ( ${force_download} -eq 'true' ) )
{
  Write-Output "Downloading image ${img_url} to ${temp_base}${img_dist}"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $img_url -OutFile "${temp_base}${img_dist}"

  # Step 4. Remove old one and convert the img to raw format using qemu
  Remove-Item "${temp_base}${img_raw}" -ErrorAction SilentlyContinue
  Write-Output "Converting img to raw format"
  & ${qemu_img_exe} convert -O raw "${temp_base}${img_dist}" "${temp_base}${img_raw}"
}

# Step 5. Convert raw img to vdi
Write-Output "Converting raw to vdi"
& VBoxManage.exe convertfromraw "${temp_base}${img_raw}" ${img_vdi}

# Step 7. Enlarge vdi size
Write-Output "Enlarging vdi to ${server_disk_size} MB"
& VBoxManage.exe modifyhd ${img_vdi} --resize ${server_disk_size}

# Step 8. Create seed directory with cloud-init config files
Write-Output "Creating seed directory"
New-Item -Path ${working_directory} -Name ${seed_directory_name} -ItemType "directory"

Write-Output "Creating cloud-init files"
# Create meta-data file
@"
instance-id: ubuntucloud-001
local-hostname: ${server_name}
"@ | Out-File -FilePath "${seed_directory}/meta-data" -Append

# Create user-data file

# Get template
$user_data = (Get-Content ${script_base}\templates\user-data-${userdata_template}.yml -Raw)
# Replace template variables
$user_data = $user_data -f $server_name
# Generate output file
$user_data | Out-File -FilePath "${seed_directory}/user-data" -Append


# Create network-config - see example: https://github.com/brennancheung/playbooks/blob/master/cloud-init-lab/network-config-v2.template.yaml
# Get IPs of gates - just like network, but with 1 in last octet
$natArray = $server_ip_nat.Split(".")
$nat_newIpAddress = $natArray[0] + "." + $natArray[1] + "." + $natArray[2] + ".1"
$hoArray = $server_ip_ho.Split(".")
$ho_newIpAddress = $hoArray[0] + "." + $hoArray[1] + "." + $hoArray[2] + ".1"
# Get template
$network_config = (Get-Content ${script_base}\templates\network-config-${network_template}.yml -Raw)
# Replace template variables
$network_config = $network_config -f $server_ip_ho, $server_ip_nat, $nat_newIpAddress
# Generate output file
$network_config | Out-File -FilePath "${seed_directory}/network-config" -Append
Write-Debug "------------Effective network config:`n$network_config------------End of effective n.c."

# Step 9. Create seed iso file
Write-Output "Creating seed.iso"
& ${cdbxpcmd_exe} --burndata -folder:${seed_directory} -iso:${seed_iso} -format:iso -changefiledates -name:CIDATA

# Step 10. Create VM
Write-Output "Creating VM ${server_name}"
if ($group_id -eq ''){
  & VBoxManage.exe createvm --name ${server_name} --register
}
else {
  & VBoxManage.exe createvm --name ${server_name} --groups "$group_id" --register
}
& VBoxManage.exe modifyvm ${server_name} --cpus ${server_cores} --memory ${server_memory} --acpi on --nic1 natnetwork --nat-network1 "${vbox_natnet_adapter}" --nic2 hostonly --hostonlyadapter2 "${vbox_host_only_adapter}"

# Enabling nested virtualization
& VBoxManage.exe modifyvm ${server_name} --nested-hw-virt on


# Adding SATA controler

& VBoxManage.exe storagectl ${server_name} --name "SATA"  --add sata --controller IntelAhci --portcount 5
& VBoxManage.exe storagectl ${server_name} --name "IDE"  --add ide --controller PIIX4
# Adding vdi and iso
& VBoxManage.exe storageattach ${server_name} --storagectl "SATA" --port 0 --device 0 --type hdd --medium ${img_vdi}
& VBoxManage.exe storageattach ${server_name} --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium ${seed_iso}
& VBoxManage.exe modifyvm ${server_name} --boot1 disk --boot2 dvd --boot3 none --boot4 none
# Enabling serial port
& VBoxManage.exe modifyvm ${server_name} --uart1 0x3F8 4 --uartmode1 server \\.\pipe\${server_name}

# Starting in headless mode causes problems with VirtualBox... so it is not used here.
Write-Output "Starting VM ${server_name}"
& VBoxManage.exe startvm ${server_name}

Write-Output "Cleaning..."
# Step 11. Deleting temporary files
Remove-Item -Path $seed_directory -Recurse -Force
Write-Output "END."
