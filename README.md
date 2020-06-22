# AuCRM PSDeployment
Powershell powered packaging and deployment scripts for AuCRM (Aurea CRM)

## Info
- packaging or deployment is driven by shared/config.xml (except of some hard-coded logics)
- currently the transportation (packing & deployment) is only possible for max. 2 stations
- the config.xml of the source station is included in the zip package. Thus, consistency of output and input are always ensured.

## Setup
1. Clone the repository to C:\AuCRM-PSDeployment (this path should be configurable in later versions)
2. Adjust the shared/config.xml according to your deployment needs
3. Set system-wide environment variables
    - UPDATE_SUPW
4. Copy pre-configured bulkloader from the designer folder to tools\bulkloader
5. Create a shortcut for the specific Powershell script ("Deploy-Package.ps1" or "Export-Package.ps1")
6. Repeat these steps for all stations
    - don't forget to adjust application paths and service names in the config.xml!

## Usage
1. Start *Export-Package.ps1* on the developer station.
2. In the *packages* folder a new zip file shows up
3. Copy the new zip package to the *input* folder of the destination station
4. Start the *Deploy-Package.ps1* on the destination station
    - this will take the newest zip from the input folder *(dont't need to care about a clean folder)*, ...
    - extract it and process the deployment according to config.xml of the **source** station

## Features
- Configuration of individual communication pathes
    - Post action: recycling web AppPool
    - Post action: reloading designer (Data model, Roles/Processes, Catalogs fixed/variable)
- Transportation of Designer Configs by name
- Copy of flat files with predefined locations (with optional exclusion of unnecessary items)
- Ensuring the existence of an empty dir (e.g. your application need an empty log dir to start)
- Creating symbolic link (important for binaries)
- Stopping and starting of AppPools and WindowsServices *(crucial for replacing binaries)*
- Remote deployment call is only supported via working WinRM service

## TODOs
- get rid of hard coded configuration options
- support for multiple stations (e.g. staging, test)
- class for collecting loaded settings
- add Pester for unit-testing
