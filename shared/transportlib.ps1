[string] $ROOT = ""
[string] $tool_BulkloaderPath = ""
[xml] $config = $null
[xml] $inputConfig = $null
$Paths = @{}
$CommConf = @{}
$DesignerConfList = @()
$AppDefs = @{}
$PackageConfs = @{}
$StationMapping = @{ DEV = 9001 ; TEST = 2 ; PROD = 1 }
$escapePattern = """{0}"""

Import-Module WebAdministration
Add-Type -Assembly System.Management.Automation
Add-Type -Assembly System.IO.Compression.FileSystem

# Import Exception Classes
[appdomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
    Try {
        $_.GetExportedTypes() | Where-Object { $_.Fullname -match 'Exception' }
    } Catch {}
} | Out-Null

function Load-Config
{
    $configPath = "$ROOT\shared\config.xml"
    if(-not (Test-Path $configPath))
        { Write-Warning "The transportation script installation is not complete: config.xml is missing" ; Exit }
    
    $config = New-Object XML
    $config.Load($configPath)
    $Script:config = $config

    Load-Notice "Loading platform specific configuration file..."
}

function Load-Paths
{
    foreach ($pathNode in $config.SelectNodes("/config/paths/*")) 
    {
        $Script:Paths[$pathNode.Name.ToString()] = $pathNode.InnerText.ToString()
    }

    Load-Notice "Loading path definitions for platform..."
}

function Reduce-Paths
{
    $workingPaths = @{}
    
    $Paths.Keys `
        | Where-Object { Test-Path $Paths[$_] } `
        | ForEach-Object {
            $workingPaths[$_] = $Paths[$_]
            "Application found: $($_)" | Write-Host -ForegroundColor Green 
        }

    $Paths = $workingPaths
}

function Load-CommConf
{
    foreach ($confAttr in $inputConfig.SelectNodes("/config/communications/comm[@platform='$Platform']")) 
    {
        $Script:CommConf[$confAttr.Attributes['stationNr'].Value] = $confAttr.Attributes['direction'].Value
    }

    Load-Notice "Loading configuration replication config for platform..."
}

function Load-InputConfig
{
    param([string] $Platform)
    [xml] $inputConfig = $null
    
    switch($Platform)
    {
        'DEV' { $inputConfig = $Script:config ; break }

        { $_ -in @('TEST', 'PROD') }
        {
            $inputConfig = New-Object System.Xml.XmlDocument
            $inputConfig.Load("$($Script:ROOT)\shared\config.xml")
            break
        }
    }
    
    $Script:inputConfig = $inputConfig    
}

function Load-PkgConfig
{
    $packages = @()
    foreach ($confNode in $inputConfig.SelectNodes("/config/flatfiles/package")) 
    {
        if(-not ($confNode.Attributes['usePath'].Value -in $Paths.Keys))
            { continue }

        $package = @{}
        $package['name'] = $confNode.Attributes['name'].Value
        $package['stopApps'] = $confNode.Attributes['stopApps'].Value -split ","
        $package['stopAppPool'] = $confNode.Attributes['stopAppPool'].Value
        $package['usePath'] = $confNode.Attributes['usePath'].Value
        
        $pathPattern = "$($Paths[$confNode.Attributes['usePath'].Value])\{0}"
        
        # <file> Processing
        $package['files'] = @()
        $confNode.SelectNodes("file").Foreach(
        { 
            $package['files'] += @{
                path = $pathPattern -f $_.Attributes['path'].Value
                originalPath = $_.Attributes['path'].Value
            }
        })      

        # <directory> Processing
        $package['directories'] = @()
        $confNode.SelectNodes("directory").Foreach(
        {
            $directory = @{} 
            $directory['path'] = ($pathPattern -f $_.Attributes['path'].Value)
            $directory['originalPath'] = $_.Attributes['path'].Value

            if($_.Attributes['exclude'].Value) 
                { $directory['exclude'] = $_.Attributes['exclude'].Value }

            $package['directories'] += $directory
        })

         # <ensureEmptyDir> Processing
        $package['ensureEmptyDirs'] = @()
        $confNode.SelectNodes("ensureEmptyDir").Foreach(
        {
            $emptyDir = @{} 
            $emptyDir['path'] = ($pathPattern -f $_.Attributes['path'].Value)
            $emptyDir['originalPath'] = $_.Attributes['path'].Value
            
            if($_.Attributes['symlinkLocation'].Value) 
                { $emptyDir['symlinkLocation'] = ($pathPattern -f $_.Attributes['symlinkLocation'].Value) }

            $package['ensureEmptyDirs'] += $emptyDir
        })

        $packages += $package
    }

    $Script:PackageConfs = $packages

    Load-Notice "Loading package configuration for platform..."
}

function Load-AppDefs
{
    foreach ($confAttr in $config.SelectNodes("/config/applications/app[@name]")) 
    {
        $AppDef = @{}
        $AppDef['serviceId'] = $confAttr.Attributes['serviceId'].Value
        $AppDef['type'] = $confAttr.Attributes['type'].Value
        $AppDef['hostedOn'] = $confAttr.Attributes['hostedOn'].Value

        $Script:AppDefs[$confAttr.Attributes['name'].Value] = $AppDef
    }
    
    Load-Notice "Loading running application/service configuration for platform..."
}

function Load-DesignerConfList
{
    foreach ($confAttr in $inputConfig.SelectNodes("/config/designerConfigs/*")) 
    {
        $Script:DesignerConfList += $confAttr.Attributes['id'].Value
    }

    Load-Notice "Loading designer configuration for platform..."
}

function Set-RootPath
{
    $scriptRoot = Split-Path -Parent -Path $script:MyInvocation.MyCommand.Definition
    if((Split-Path -Path $scriptRoot)[1] -ne "AuCRM-PSDeployment")
    {
        $ROOT = Split-Path -Parent -Path $scriptRoot
    }

    if((Split-Path -Path $ROOT)[1] -ne "AuCRM-PSDeployment")
    {
        $ROOT = (Get-Location).Path
    }

    $script:ROOT = $ROOT
}

function Set-ToolPaths
{
    $Script:tool_BulkloaderPath = (Join-Path $Script:ROOT ".\tools\bulkloader")
}

function Exec-Comm
{
    param([string] $StationNr, [string] $direction, [string] $dataStockLoad = "")

    $commCmd = """{0}\system\exe\mmco.exe"" -u su -p $($env:UPDATE_SUPW) -k $direction,$StationNr,$dataStockLoad --quiet" `
		-f ($Script:Paths['core'])
	# $commCmd | Write-Host -ForegroundColor Yellow
    
    cmd /c $commCmd
}

function Erase-CommDir
{
    param([string] $StationNr, [string] $direction)
    $commDir = "{0}\$StationNr\$direction"
    $commDir = $commDir -f ($Script:Paths['core'])

    rm ($commDir + "\*")
}

function Move-CommResult
{
    param([string] $StationNr, [string] $direction)
    $commDir = "{0}\$StationNr\$direction"
    $commDir = $commDir -f ($Script:Paths['core'])

    mv -Destination ("C:\AuCRM-PSDeployment\output\comm-$StationNr\") ($commDir + "\*")
}

function Copy-CommIn
{
    param([string] $StationNr, [string] $direction)
    $commFilePath = "{0}\$StationNr\$direction"
    $commFilePath = $commFilePath -f ($Script:Paths['core'])
    $commSrcPath = ("C:\AuCRM-PSDeployment\input\comm-$($Script:StationMapping[$global:Platform])\*")

    cp -Destination $commFilePath $commSrcPath
}

function Restart-App
{
    param([HashTable] $App)

    switch($App['type'])
    {
        'AppPool' 
        {
            Write-Host -ForegroundColor Cyan "Restarting App: $($App['serviceId'])"
            Restart-WebAppPool $App['serviceId'] 2>$null
        }
        'WindowsService'
        {
            Write-Host -ForegroundColor Cyan "Restarting App: $($App['serviceId'])"
            Restart-Service $App['serviceId'] 2>$null
        }
    }
}

function Stop-App
{
    param([HashTable] $App)

    switch($App['type'])
    {
        'AppPool' 
        {
            do
            {
                Write-Host -ForegroundColor Cyan "Stoping App: $($App['serviceId'])"
                Stop-WebAppPool $App['serviceId'] 2>$null
				
				Sleep -Seconds 1
				
				$appPoolStatus = (Get-WebAppPoolState $App['serviceId']).Value;
				Write-Host -ForegroundColor Cyan $appPoolStatus
            } while ($appPoolStatus -in "Started","Stopping")
        }
        'WindowsService'
        {
            if((Get-Service $App['serviceId']).Status -in @("Started", "Running"))
            {
                Write-Host -ForegroundColor Cyan "Stoping App: $($App['serviceId'])"
                Stop-Service $App['serviceId'] 2>$null
            }
        }
    }
}

function Start-App
{
    param([HashTable] $App)

    switch($App['type'])
    {
        'AppPool' 
        {
            switch((Get-WebAppPoolState $App['serviceId']).Value)
            {
                'Stopped'
                {
                    Write-Host -ForegroundColor Cyan "Starting App: $($App['serviceId'])"
                    Start-WebAppPool $App['serviceId'] 2>$null
                }
                'Stopping'
                {
                    Sleep -Seconds 1
                    Start-App $App
                }
            }
        }
        'WindowsService'
        {
            if((Get-Service $App['serviceId']).Status -in @("Stopped"))
            {
                Write-Host -ForegroundColor Cyan "Starting App: $($App['serviceId'])"
                Start-Service $App['serviceId'] 2>$null
            }
        }
    }
}

function Reload-Designer
{
    $serviceUri = "http://{0}/{1}/crm.services/"
    $serviceUri = $serviceUri -f $AppDefs['web']['hostedOn'],$AppDefs['web']['serviceId']

	$baseCMDbegin = " ""{0}\update.bulkloader.exe"" DataModel "
    $baseCMDbegin = $baseCMDbegin -f $tool_BulkloaderPath

	$baseCMDend = " -serviceUri:""$serviceUri"" -user:SU -password:$env:UPDATE_SUPW -language:ger -y" # -verbose
	
    $cmdPattern = "$baseCMDbegin {0} $baseCMDend {1}"

    Progress-Notice "Refreshing datamodel in designer module..."
	cmd /c ($cmdPattern -f "Update","")

    Progress-Notice "Refreshing catalogs in designer module..."
	cmd /c ($cmdPattern -f "Catalog","-variable:* -fixed:* ")

    Progress-Notice "Refreshing in designer module..."
	cmd /c ($cmdPattern -f "Process","")	

}

function Bulkloader-DownloadConfig
{
    param([string] $ConfigName)
    if($ConfigName.Length -lt 1) { Return }

    $outputDir = "$($Script:ROOT)\output\designer_Confs\$ConfigName"
    
    if((Test-Path $outputDir) -eq $false)
        { New-Item -Path $outputDir -Force -ItemType directory | Out-Null }
    
	$baseCMD = " ""{0}\update.bulkloader.exe"" Download Config {1} {2} {3} -y"
    
    $paramTargets = "-vertical:BB -configname:$ConfigName -languages:English,German"
    $paramConnection = "-configFile:$($escapePattern -f (Join-Path $Paths['web'] system\settings\settings.xml))"
    $paramOutput = "-xmlFilePath:$outputDir"

    $baseCMD = $baseCMD -f $tool_BulkloaderPath,$paramTargets,$paramConnection,$paramOutput

    cmd /c $baseCMD

    Progress-Notice ("Designer config downloaded: {0}!" -f $ConfigName)
}

function Bulkloader-UploadConfig
{
    param([string] $ConfigName)
    if($ConfigName.Length -lt 1) { Return }

    $inputDir = "$($Script:ROOT)\input\designer_Confs\$ConfigName"    
    if((Test-Path $inputDir) -eq $false) { Return }

	$baseCMD = " ""{0}\update.bulkloader.exe"" Upload Final {1} {2} -y" # -verbose
    
    $paramConnection = "-configFile:$($escapePattern -f (Join-Path $Paths['web'] system\settings\settings.xml))"
    $paramInput = "-xmlFilePath:$inputDir"

    $baseCMD = $baseCMD -f $tool_BulkloaderPath,$paramConnection,$paramInput

    Progress-Notice ("Uploading Config: {0}" -f $ConfigName)
    cmd /c $baseCMD
}

function Import-Packages 
{
    Progress-Notice "Starting importing flatfiles"
    $inputDirPattern = "$($Script:ROOT)\input\flatfiles\{0}"

    # Stop All the services marked in the package config
    $PackageConfs.ForEach({
        if($_['stopAppPool'] -eq "true")
            { Stop-App $AppDefs[$_['usePath']] } # For binary replace

        if(($_['stopApps'] -split ",").Length -gt 0)
        { 
            ($_['stopApps'] -split ",") | Where-Object { $_.Length -gt 0 } | ForEach-Object { Stop-App $AppDefs[$_] } 
        }

    })

    $PackageConfs.ForEach({
        $inputDirPath = ($inputDirPattern -f $_['name'])

        # Ensure Empty Dir
        $_['ensureEmptyDirs'].ForEach({
            if(-not (Test-Path $_['path']))
                { New-Item -Path $_['path'] -Force -ItemType directory 1> $null }
            
            if(-not ($null -eq $_['symlinkLocation']))
            {
                $symLinkPath = (Join-Path $_['symlinkLocation'] $_['originalPath'])
                if(-not (Test-Path $symLinkPath))
                {
                    $dir = $Script:escapePattern -f $_['path']
                    $symLink = $Script:escapePattern -f $symLinkPath
                    $createCmd = "mklink /D {0} {1}" -f $symLink,$dir

                    cmd /c $createCmd | Out-Null
                }
            }

        })

        # Directory Copying
        $_['directories'].ForEach({
            $destPath = $_['path']
            $sourcePath = "$inputDirPath\$($_['originalPath'])\*"
            
            Write-Host "Copying: $($sourcePath) --> $($destPath)"
            if(-not(Test-Path $destPath))
                { New-Item -ItemType Directory -Path $destPath }

            Try
                { Copy-Item -Recurse -Force -Destination $destPath -ErrorAction Stop $sourcePath }
            Catch
            {
                $targetObj = ([System.Management.Automation.ErrorRecord] $_).TargetObject
                $errDetails = ([System.Management.Automation.ErrorRecord] $_).ErrorDetails
                
                if($targetObj)
                    { Write-Warning $targetObj.ToString() }
                elseif($errDetails)
                    { Write-Warning $errDetails.ToString() }
            }
        })

        # File Copying
        $_['files'].ForEach({
            $source = (Join-Path $inputDirPath $_['originalPath'])
            $sourceDir = Split-Path -Parent $source
            
            if(-not (Test-Path $sourceDir))
                { New-Item -Path $sourceDir -Force -ItemType directory 1> $null }

            Try
                { Copy-Item -Path $source -Destination $_['path'] -ErrorAction Stop }
            Catch
            {
                $errorObj = ([System.Management.Automation.ErrorRecord] $_)
                if($null -ne $errorObj)
                {
                    if($null -eq $errorObj.TargetObject) {
                        Write-Warning ("Unknown Exception occured on copying {0} to {1}" -f $source,$_['path']) 
                        Write-Warning $errorObj
                    }
                    else
                        { Write-Warning $errorObj.TargetObject.ToString() }
                }

            }
        })

    })

    # Start All the services marked in the package config as stop
    $PackageConfs.ForEach({
        if($_['stopAppPool'] -eq "true")
            { Start-App $AppDefs[$_['usePath']] } # For binary replace

        if(($_['stopApps'] -split ",").Length -gt 0)
        { 
            ($_['stopApps'] -split ",") `
                | Where-Object { $_.Length -gt 0 } `
                | ForEach-Object { Start-App $AppDefs[$_] } 
        }

    })
}

function Export-Packages
{
    $outputDirPattern = "$($Script:ROOT)\output\flatfiles\{0}"

    # Clean Up 
    if((Test-Path ($outputDirPattern -f "")) -and (Get-ChildItem -Path ($outputDirPattern -f "*")).Length -gt 0)
        { rm -Recurse -Force -Path ($outputDirPattern -f "*") -Exclude "*.zip" | Out-Null }
    
    $PackageConfs.ForEach({
        $outDirPath = ($outputDirPattern -f $_['name'])
        New-Item -ItemType directory -Force $outDirPath 1> $null
        
        # Directory Copying
        $_['directories'].ForEach({            
            [string] $exclude = $_['exclude']

            Get-ChildItem -Path $_['path'] -Recurse `
                | Where-Object { -not ($_.Name -ilike ".*") } `
                | Where-Object { -not ($_.Name -ilike "$exclude") } `
                | Ensure-CopyAddresses -OutDirPath $outDirPath -OriginalPath $_['originalPath'] `
                | Copy-Item -Force `
                # | Debug-CopyPipe `

            # TODO: Ensure logic missing for empty dirs
        })

        # File Copying
        $_['files'].ForEach({
            $destination = (Split-Path -Parent (Join-Path $outDirPath $_['originalPath']))
            
            if(-not (Test-Path $destination))
                { New-Item -Path $destination -Force -ItemType directory 1> $null }

            Copy-Item -Path $_['path'] -Destination $destination
        })

    })
}

function Compress-Packages
{
	param([switch] $OutputIntoDest)

    $sourceDir = "$($Script:ROOT)\output"
    $tmpDir = "$($Script:ROOT)\tmp_pkg"
	$zipNamePattern = "$($Script:ROOT)\packages\packageTo--{0}`_{1}.zip"

    foreach($Platform in @("TEST", "PROD"))
    {
        # Create Temp dir for Packaging
        New-Item -Path $tmpDir -ItemType directory -Force | Out-Null

        # Output zip settings
        $zipName = ($zipNamePattern -f $Platform,$(get-date -f yyyy-MM-dd_HH_mm))
	    If (Test-Path $zipName) { Remove-Item $zipName }

        $packageSelection = @("designer_Confs", "flatfiles")
        $packageSelection += "{0}-{1}" -f "comm",$Script:StationMapping[$Platform]
        
        # Copy necessary items
        Get-ChildItem -Recurse -Force $sourceDir `
            | Where-Object { ([System.IO.FileSystemInfo] $_).Name -in $packageSelection } `
            | cp -Recurse -Force -Destination $tmpDir

        # Copy config.xml
        cp -Force `
            -Path (Join-Path $($Script:ROOT) "\shared\config.xml") `
            -Destination (Join-Path $tmpDir "\config.xml")

        # Compress to the dir packages
	    [System.IO.Compression.ZipFile]::CreateFromDirectory(`
            $tmpDir, $zipName, `
            [System.IO.Compression.CompressionLevel]::Fastest, $false `
        )
		
		# If OutputIntoDest switch is on, copy the package to the destination
		If($OutputIntoDest)
		{
			cp -Force $zipName -Destination (Join-Path $($Script:ROOT) ("\input-{0}{1}" -f $($Platform.ToLower()), "1"))
			cp -Force $zipName -Destination (Join-Path $($Script:ROOT) ("\input-{0}{1}" -f $($Platform.ToLower()), "2"))
		}
		
        # Notify end
	    Progress-Notice "Package for $Platform with the current time stamp created!"

        # Clean-up
        Remove-Item -Recurse -Force $tmpDir
    }

}

function Extract-Package
{
    $sourceDir = "$($Script:ROOT)\input"

    # Clean-up previous
    rm -Path (Join-Path $sourceDir "*") -Exclude "*.zip" -Force -Recurse

    # Find the newest input package
    Try
	{ $zipPath = (Get-ChildItem -Path $sourceDir\*.zip -File | sort LastWriteTime -Descending)[0].FullName }
    Catch 
    { "No Package found in the Input directory. Supply one and re-run the script!" | Write-Warning ; Exit }
    
    # Extract the newest input package
	[System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $sourceDir)

	Progress-Notice "Package extracted from the input directory!"
}

function CleanUp-PackageInput
{
    $sourceDir = "$($Script:ROOT)\input"

    # Clean-up input
    rm -Path (Join-Path $sourceDir "*") -Exclude "*.zip" -Force -Recurse
    
    # Move to archive
    mv -Path (Join-Path $sourceDir "*") -Destination (Join-Path $ROOT "\packages") -Include "*.zip" -Force
}

function Debug-CopyPipe
{
    Process
    {        
        $_ | Write-Host
        $_
    }
}

function Ensure-CopyAddresses
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
        $childItems,

        [Parameter(Mandatory=$True)]
        [string] $OutDirPath,

        [Parameter(Mandatory=$True)]
        [string] $OriginalPath
    )

    Process
    {
        $baseDir = (Join-Path $OutDirPath $OriginalPath)
        New-Item -ItemType directory -Force $baseDir | Out-Null

        foreach($sourceItem in $childItems)
        {
            [string] $source = ([System.IO.FileSystemInfo] $sourceItem).FullName
            [int] $startIdx = $source.IndexOf($OriginalPath)
            $dest = $source.Substring($startIdx, $source.Length - $startIdx)            
            
            [pscustomobject] @{ 
                Path = $source
                Destination = (Join-Path $OutDirPath $dest)
            }

        }
    }

}

function Load-Notice
{
    Write-Host -ForegroundColor Magenta $args[0]
}

function Progress-Notice
{
    Write-Host -ForegroundColor Yellow $args[0]
}

function Communication-Out
{
    param([string] $StationNr)

    Erase-CommDir -StationNr $StationNr -direction out
    Exec-Comm -StationNr $StationNr -direction out -dataStockLoad "u"
    Move-CommResult -StationNr $StationNr -direction out  
    
    Progress-Notice "Configuration replication finished for $StationNr!"  
}

function Communication-In
{
    param([string] $StationNr)

    Erase-CommDir -StationNr $StationNr -direction in
    Copy-CommIn -StationNr $StationNr -direction in

    Exec-Comm -StationNr $StationNr -direction in
    
    Progress-Notice "Configuration replication finished!"  
}

function Communication-Logic
{
    $CommConf.Keys | Where-Object { $CommConf[$_] -eq "out" } `
        | ForEach-Object { Communication-Out -StationNr $_ } `
        | ForEach-Object { Progress-Notice "Communication for Station with number $($_) done!" }
    
    $CommConf.Keys | Where-Object { $CommConf[$_] -eq "in" } `
        | ForEach-Object { Communication-In -StationNr $_ } `
        | ForEach-Object { Progress-Notice "Communication for Station with number $($_) done!" }
}

function CleanUp-Output
{
    $targetDir = "$($Script:ROOT)\output"

    @("comm-2\*", "comm-1\*", "designer_Confs\*", "flatfiles\*") | ForEach-Object `
    {
        rm -Path (Join-Path $targetDir $_) -Force -Recurse
    }

    Load-Notice "Cleaned up output!"
}


function Check-FlatfileTargets
{
    [bool] $ifAny = $false

    $PackageConfs | Where-Object { $_['usePath'] -in $Paths.Keys } `
        | ForEach-Object { $ifAny = $true }

    $ifAny
}

function BootStrap
{
    Load-Notice "Target Environment: $($global:Platform)"

    # Phase - Begin
    if($global:Platform -in @("TEST", "PROD"))
    {
        Extract-Package
    }
    elseif($global:Platform -in @("DEV"))
    {
        CleanUp-Output
    }
    else { Write-Warning "No compatible platfrom is set as target in the START-*.ps1" ; Exit }

    # Phase - Load
    Load-Config
    Load-InputConfig -Platform $global:Platform
    Load-Paths
    Reduce-Paths
    Load-CommConf
    Load-AppDefs
    Load-DesignerConfList
    Load-PkgConfig

    # Phase - End
}

function Finalizing
{
	param([switch] $OutputIntoDest)
	
    switch($global:Platform)
    {
        'DEV'
        {
			If($OutputIntoDest)
				{ Compress-Packages -OutputIntoDest }
			Else
				{ Compress-Packages }

            break
        }

        { $_ -in @('TEST', 'PROD') }
        {
            CleanUp-PackageInput

            break
        }
    }

    Progress-Notice "Deployment process finished!"
}

function Transport-Logic
{
    param([switch] $FlatsOnly)

    switch($global:Platform)
    {
        'DEV'
        {
            # Communication
            if("core" -in $Paths.Keys -and -not $FlatsOnly)
                { Communication-Logic }
			
            # Export designer
            if("web" -in $Paths.Keys -and -not $FlatsOnly)
                { $DesignerConfList | ForEach-Object { Bulkloader-DownloadConfig -ConfigName $_ } }

            # Export flatfiles
            if("web" -in $Paths.Keys)
                { Export-Packages }

            break
        }

        { $_ -in @('TEST', 'PROD') }
        {
            # Communication
            if("core" -in $Paths.Keys)
                { Communication-Logic }
    
            # Import designer
            if("web" -in $Paths.Keys)
            { 
                Restart-App $AppDefs['web']
                Reload-Designer
                $DesignerConfList | ForEach-Object { Bulkloader-UploadConfig -ConfigName $_ } 
            }

            # Import flatfiles
            if(Check-FlatfileTargets)
                { Import-Packages }

            break
        }
    }
    
}

# --- Boot-up Sequence ---
Set-RootPath
Set-ToolPaths