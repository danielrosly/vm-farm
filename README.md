# vm-farm

## What is it:

This is a tool that can be used to configure, create and manage groups of VirtualBox VMs in Windows.
Following operations are possible for each defined group: 
* create, start, stop, delete, status for all VMs in a group
* create, restore last, delete last SNAPSHOT of all VMs in a group

All VMs in a group can be identical or can be different. Script operates at all VMs from group. All operations except creating VMs and showing their statuses are executed in parallel way.

## How to install

### Requirements

* Powershell 7 is needed.
* Permission needed: `Set-ExecutionPolicy -Scope CurrentUser Unrestricted`
* VirtualBox installation is needed.
   * VBoxManage.exe should be in PATH system variable.
* Set of external software is needed by VM creation script `create_vbox_vm_ubuntu_cloud.ps1`.
   * QEMU-IMG installed  from location :  https://cloudbase.it/qemu-img-windows/
   * CDBurnerXP installed from location :  https://cdburnerxp.se/pl/
   * See inside it for details and setting paths.

### Installation

1. Make sure requirements are fulfilled.
2. Copy all *.ps1 files to directory of your choice.
3. Execute: `Set-Alias vm_farm PATH_OF_DIR\vm_farm.ps1`
   1. Optionally, add this command to your profile: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles?view=powershell-7.3
4. Copy dirs `config` and `templates` and their contents from this repository to directory where you want to keep your configuration in.
5. Configure files in above dirs according to your needs - see below.
   1. Virtual Box should contain networks defined in configuration. They are not created automatically.


## Usage

Go to directory where configuration subdirs are located.

Run from directory with configuration subdirs: `vm_farm -Action "Help"`. You will see detailed help about how to use the tool.


### Details of configuration of VMs

There should be two subdirectories in current working directory from which `vm_farm` alias is executed:
* `config` - the one that contains JSON with global configuration of the program named `vm_initial_config.json`.
* `templates` - contains configuration files for VMs used by VM creation script: `network-config-default.yml`, `user-data-default.yml` and `vm-config-default.yml`.

Some params for hardware and image are also defined inside `create_vbox_vm_ubuntu_cloud.ps1` VM creation script.

Directory `config` contains file `vm_initial_config.json` with following parameters:
 -   "base_path" - directory where subdir for VMs is created.
 -   "group_id" - name of group and subdirectory for VMs. **Needs to have SLASH at the beginning**.
 -   "no_of_servers" - number of servers created, servers are numbered from 1 to this value.
 -   "names_of_servers" - beginning of names, above number of a server (from 1...) is appended at the end. **Warning: Full name of each server should be unique within WHOLE VirtualBox installation**.
 -   "ips_of_servers_host_only" - IP of server, number of server is added to last octet. So, first server has last octet higher by one, second by two and so on.
 -   "ips_of_servers_nat" - Static ip. Rules as above.
 -   "host_only_network" - Name of VirtualBox Host Only network for communication between guests and host.
 -   "nat_network" - Name of VirtualBox NAT Network to be used for communication with outside.
 -   "start_type" - How VM shows its window. One of "gui|sdl|headless|separate".
 -   "parallel_execution_limit" - number of parallel executions when managing servers.
 -   "wait_for_ssh_minutes" - up to how long to wait for start of servers after their creation (used only there).
 -   "user_name" - name of user for Ansible `hosts` file.
 -   "user_private_key" - location of private key for Ansibe `hosts` file.

When creating VMs, YAML file `hosts` (compatible with Ansible format) is created in directory where configuration files are located (either current one or selected by env variable - see below). It is used for storing information about created hosts, so **please don't remove it**.


### Optional configuration

If environment variable `VM_FARM_CONFIG` is set, it is used to get path for configuration subdirs/files normaly used as current dir described above. 
It means that this dir should contain both `config` and `templates` subdirs together with proper files. If this variable is set, also `host` file is created inside this dir.

Example command: 
`$env:VM_FARM_CONFIG = "C:\VM_FARM_1"`

### Individual configurations of VMs

If one or more VMs from the farm needs to have its individual configuration, dedicated set of files in `templates` directory for this machine should be prepared.

I.e. lets assume that there are four machines in the pool having names: `ubuntu1, ubuntu2, ubuntu3, ubuntu4`. If machine `ubuntu1` has to have different configuration than default, additional (except those described in one of sections above) set of files for this machine should be created inside `templates`. They should have names: `network-config-ubuntu1.yml`, `user-data-ubuntu1.yml` and `vm-config-ubuntu1.yml`. Formats identical like `-default` files. Not all three files must be present - only ones that contain differences in configuration.

### Examples of usages:

`vm_farm -Action "Create"` - creates VMs defined in configuration files in config and templates. After creation machines are in started state.

`vm_farm -Action "Start" -Param "WAIT4SSH"` - starts VMs from group defined in config and then waits util all of them make SSH port accesible for connecting.

##  Based on external sources:

Code that generates VMs ( "VM creation script" ) is generally a copy of https://github.com/ricsanfre/ubuntu-cloud-vbox with several smaller and bigger tweaks.

## TODO:
 - Parallelize collecting status data for VMs. Then print all in proper order (if possible).
 - Move paths of used tools to configuration file. Which one?
 - Automatically create networks configured.
  