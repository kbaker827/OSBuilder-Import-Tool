<#	
	.NOTES
	===========================================================================
	 Created on:   	1/10/2019
	 Author:		Andrew Jimenez (asjimene) - https://github.com/asjimene/
	 Filename:     	Import-OSBuild.ps1
	===========================================================================
    .SYNOPSIS
        Imports Image File Builds created using the OSDBuilder tool by David Segura (http://www.osdbuilder.com)

    .DESCRIPTION
        ## OSDBuilder Import Tool
        The purpose of this tool is to import OSBuilds and OSMedia created using David Segura's OSDBuilder module into SCCM. It's primary functions are as follows:
        1. Copy the OSBuild/OSMedia into the correct content shares (wim file and optionally OS Upgrade Packages)
        2. Import the OSBuild/OSMedia into SCCM Operating System Images (Optionally import OS Upgrade Package)
        3. Distribute Content to a specified Distribution Point Group
        4. Optionally update a specified task sequence step with the new OS Image

        .EXAMPLE
        .\Import-OSBuild.ps1
        Imports an OSBuild wim file only

        .EXAMPLE
        .\Import-OSBuild.ps1 -ImportOSUpgrade
        Import an OSBuild wim file and the cooresponding OS Upgrade Package

        .EXAMPLE
        .\Import-OSBuild.ps1 -OSUploadName "Windows 10 Enterprise x64 1809" -ImportOSUpgrade
        Import the latest OSBuild with the name like "Windows 10 Enterprise x64 1809", and import the cooresponding OSUpgrade package. This flag is helpful for automating the upload process, say... after an OSBuild is completed.

        .EXAMPLE
        .\Import-OSBuild.ps1 -OSUploadMedia -OSUploadName "Windows 10 Enterprise x64 1809" -UpdateTS -TaskSequenceName "DEV Task Sequence" -TaskSequenceStepName "Install Windows 10 x64" 
        Import the latest OSMedia with the name like "Windows 10 Enterprise x64 1809", then update the step "Install Windows 10 x64" in the task sequence "DEV Task Sequence" with the newly uploaded media

        .EXAMPLE
        .\Import-OSBuild -Import-OSMedia -ImportOSUpgrade
        Import an OSMedia wim file and the cooresponding OS Upgrade Package

        .EXAMPLE
        .\Import-OSBuild -UseExistingPackages
        Import an OSBuild, but do not create a new wim on the content share, instead update an exising wim
        NOTE: This flag cannot be used silently

        .EXAMPLE
        .\Import-OSBuild -UseExistingPackages -ImportOSUpgrade
        Import an OSBuild wim file, and the cooresponding OS Upgrade Package but use an exising wim and Upgrade Package

#>

param (
    # Also import the associated OSUpgrade package
    [Parameter(Mandatory = $false)]
    [switch]$ImportOSUpgrade = $false,

    # Import OSMedia instead of OSBuild
    [Parameter(Mandatory = $false)]
    [switch]$ImportOSMedia = $false,

    # Upgrade an existing Image and (optionally) Upgrade Package
    [Parameter(Mandatory = $false)]
    [switch]$UseExistingPackages = $false,

    # Build/Media Name to upload (Uses '-like "*$OSUploadName*"' to choose the latest OSBuild or OSMedia with the provided name)
    [Parameter(Mandatory = $false)]
    [string]$OSUploadName,

    # Update an Operating System image in a task sequence with the newly uploaded Operating System
    [Parameter(ParameterSetName = 'TSUpdate', Mandatory = $false)]
    [switch]$UpdateTS = $false,

    # Specify the Name of the Task Sequence to Update (Requires UpdateTS switch)
    [Parameter(ParameterSetName = 'TSUpdate', Mandatory = $true)]
    [string]$TaskSequenceName,

    # Specify the Name of the Operating System Step to Update (Requires UpdateTS switch)
    [Parameter(ParameterSetName = 'TSUpdate', Mandatory = $true)]
    [string]$TaskSequenceStepName
)


## Global Variables

# SCCM Variables
$Global:ContentShare = "\\Path\to\Content\share"
$Global:OSUpgradeContentShare = "\\Path\to\OSUpgrades\share"
$Global:SCCMSite = "SITE:"
$Global:PreferredDistributionLoc = "PreferredGroupName" #Must be a distribution point group at this time

# Logging Variables
$Global:LogPath = "$PSScriptRoot\OSDBuilder-Import.log"
$Global:MaxLogSize = 1000kb

# Other Variables
$Global:rCpyThreads = 4 # Number of threads for Robocopy to use during OSUpgrade Copy

## Functions

function Add-LogContent {
	param
	(
		[parameter(Mandatory = $false)]
		[switch]$Load,
		[parameter(Mandatory = $true)]
		$Content
	)
	if ($Load) {
		if ((Get-Item $LogPath -ErrorAction SilentlyContinue).length -gt $MaxLogSize) {
			Write-Output "$(Get-Date -Format G) - $Content" > $LogPath
		}
		else {
			Write-Output "$(Get-Date -Format G) - $Content" >> $LogPath
		}
	}
	else {
		Write-Output "$(Get-Date -Format G) - $Content" >> $LogPath
	}
}

function copy-OSDBuilderObject {
    param (
        [ValidateSet('Image','UpgradePackage')][string]$Type,
        [string]$name,
        [string]$source,
        [string]$destination
    )
    If ($Type -eq "Image"){
        # Copy the selected install.wim to the ContentShare using the build name
        Add-LogContent "Attempting to Copy $source to $destination"
        try {
            Copy-Item -Path $source -Destination $destination -Force
            Add-LogContent "Copy Completed Successfully"
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Add-LogContent "ERROR: Copying $source to $destination failed! Skipping import for $name"
            Add-LogContent "ERROR: $ErrorMessage"
        }
    } 
    Else {
            # Copy the selected Upgrade Package to the ContentShare using the build name
            Add-LogContent "Attempting to Copy OS Upgrade Files from $source to $destination"
            
            try {
                #Copy-Item -Path "$($source)\OS" -Destination "$destination" -Recurse -Force
                
                $rcpyArguments = "`"$source`" `"$destination`" /MIR /Z /MT:$Global:rCpyThreads"
                Add-LogContent "Copy Command: robocopy.exe $rcpyArguments"

                Start-Process "robocopy.exe" -ArgumentList $rcpyArguments -Wait -NoNewWindow
                Add-LogContent "Copy Completed Successfully"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Add-LogContent "ERROR: Copying $source to $destination failed! Skipping import for $name"
                Add-LogContent "ERROR: $ErrorMessage"
            }
    }
}

function import-OSDBuilderObject {
    param (
        [ValidateSet('Image','UpgradePackage')][string]$Type,
        [string]$Name,
        [string]$Path,
        [string]$version,
        [string]$Description
    )

    # Import the Copied wim into SCCM
    Add-LogContent "Importing $Name"
    Push-Location
    Set-Location $Global:SCCMSite
    try {
        if ($Type -eq "Image"){
            New-CMOperatingSystemImage -Name "$Name" -Path "$Path" -Version "$version" -Description "$Description"
            Add-LogContent "Successfully Imported the Operating System as $Name"
        }
        Else {
            New-CMOperatingSystemInstaller -Name "$Name" -Path "$Path" -Version "$version" -Description "$Description"
            Add-LogContent "Successfully Imported the Operating System as $Name"
        }
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        Add-LogContent "ERROR: Importing wim into SCCM from $Path failed! Skipping import for $Name"
        Add-LogContent "ERROR: $ErrorMessage"
    }
    Pop-Location
}

function Update-OSContent {
    param (
        [ValidateSet('Image','UpgradePackage')][string]$Type,
        [string]$Name
    )

    # Distribute the new OSImage to the Specified Distribution Point Group
    Add-LogContent "Distributing $Name to $($Global:PreferredDistributionLoc)"
    Push-Location
    Set-Location $Global:SCCMSite
    if ($updateExistingImage){
        try {
            if ($Type -eq "Image"){
                Invoke-CMContentRedistribution -InputObject $(Get-CMOperatingSystemImage -Name "$Name") -DistributionPointGroupName $Global:PreferredDistributionLoc
                Add-LogContent "Successfully Completed Copy, and Re-Distribution of OSBuild: $Name"
            }
            else {
                Invoke-CMContentRedistribution -InputObject $(Get-CMOperatingSystemInstaller -Name "$Name") -DistributionPointGroupName $Global:PreferredDistributionLoc
                Add-LogContent "Successfully Completed Copy, and Re-Distribution of OSUpgrade: $Name"
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Add-LogContent "ERROR: Distributing OSImage $Name Failed!"
            Add-LogContent "ERROR: $ErrorMessage"
        }
    } 
    else {
        try {
            if ($Type -eq "Image"){
                Start-CMContentDistribution -OperatingSystemImageName "$Name" -DistributionPointGroupName $Global:PreferredDistributionLoc
                Add-LogContent "Successfully Completed Copy, Import, and Distribution of OSBuild: $Name"
            }
            else {
                Start-CMContentDistribution -OperatingSystemInstallerName "$Name" -DistributionPointGroupName $Global:PreferredDistributionLoc
                Add-LogContent "Successfully Completed Copy, Import, and Distribution of OSUpgrade: $Name"
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Add-LogContent "ERROR: Distributing OSImage $Name Failed!"
            Add-LogContent "ERROR: $ErrorMessage"
        }
    }
    Pop-Location
}

## Main

Add-LogContent -Content "Starting Import-OSBuild" -Load

# Import ConfigurationManager Cmdlets
if (-not (Get-Module ConfigurationManager)) {
    try {
        Add-LogContent "Importing ConfigurationManager Module"
        Import-Module (Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    } 
    catch {
        $ErrorMessage = $_.Exception.Message
		Add-LogContent "ERROR: Importing ConfigurationManager Module Failed! Exiting!"
        Add-LogContent "ERROR: $ErrorMessage"
        Exit
    }
}

# Import OSDBuilder Module Cmdlets
if (-not (Get-Module OSDBuilder)) {
    try {
        Add-LogContent "Importing OSDBuilder Module"
        Import-Module OSDBuilder
    } 
    catch {
        $ErrorMessage = $_.Exception.Message
		Add-LogContent "ERROR: Importing OSDBuilder Module Failed! Exiting!"
        Add-LogContent "ERROR: $ErrorMessage"
        Exit
    }
}

# Check OSDBuilder Version
if ((Get-Module OSDBuilder).Version -lt "19.6.3.0") { 
    Write-Host "OSDBuilder Version is out-of-date, please upgrade to the latest version"
    Add-LogContent "OSDBuilder Version is out-of-date, please upgrade to the latest version"
    Exit
}

# Search the OSBuilder Path for new Wim Files to import, loop if none are selected
$selectedBuilds = $null
while ([System.String]::IsNullOrEmpty($selectedBuilds)) {
    if ($ImportOSMedia) {
        if ([System.String]::IsNullOrEmpty($OSUploadName)) {
            $selectedBuilds = Get-OSMedia -GridView
        }
        else {
            $selectedBuilds = Get-OSMedia | Where-Object -Property Name -like "$OSUploadName*" | Sort-Object ModifiedTime | Select-Object -Last 1
        }
        Add-LogContent "Selected the Following Media to import: $($SelectedBuilds.Name -join " ; ")"
    } 
    Else {
        if ([System.String]::IsNullOrEmpty($OSUploadName)) {
            $selectedBuilds = Get-OSBuilds -GridView
        }
        else {
            $selectedBuilds = Get-OSBuilds | Where-Object -Property Name -like "$OSUploadName*" | Sort-Object ModifiedTime | Select-Object -Last 1
        }
        Add-LogContent "Selected the Following Builds to import: $($SelectedBuilds.Name -join " ; ")"
    }
}

if ($UseExistingPackages){
    # Get the OSImage name and the OSUpgradePackage name from SCCM
    Push-Location
    Set-Location $Global:SCCMSite
    $OSImageSelection = Get-CMOperatingSystemImage | Select-Object Name,ImageOSVersion,SourceDate,PkgSourcePath | Out-GridView -Title "Select the OS Image to Upgrade" -OutputMode Single
    $Global:ContentShare = $OSImageSelection.PkgSourcePath
    if ($ImportOSUpgrade) {
        $OSUpgradeSelection = Get-CMOperatingSystemInstaller | Select-Object Name,ImageOSVersion,SourceDate,PkgSourcePath | Out-Gridview -Title "Select the Upgrade Package to Update" -OutputMode Single
        $Global:OSUpgradeContentShare = $OSUpgradeSelection.PkgSourcePath
    }
    Pop-Location
}

ForEach ($Build in $SelectedBuilds){
    # Set Build Variables
    $BuildName = $Build.Name
    $BuildVersion = $Build.UBR
    $BuildDescription = $Build.Imagename + " Version $BuildVersion - Imported from OSDBuilder on: $(Get-Date -Format G)"
    $wimLocation = Join-Path -Path $Build.FullName -ChildPath "OS\sources\install.wim"
    $OSLocation = Join-Path -Path $Build.FullName -ChildPath "OS"

    if ($Global:ContentShare -like "*.wim") {
        Add-LogContent "Specified content location is a wim, will update existing wim, and use existing Upgrade Content Share"
        $updateExistingImage = $true

        $BuildName = $OSImageSelection.Name
        $destinationPath = "$Global:ContentShare"
        $osUpgradePath = "$Global:OSUpgradeContentShare"

        # Backup the Existing image File (as long as it exists)
        try {
            Add-LogContent "Backing up: $destinationPath to: $($destinationPath.Replace(".wim","-$((Get-Date).ToString(`"yyyyMMdd`")).wim"))"
            Move-Item -path "$destinationPath" -Destination $destinationPath.Replace(".wim","-$((Get-Date).ToString(`"yyyyMMdd`")).wim") -ErrorAction Stop
            Add-LogContent "Backed up: $destinationPath to: $($destinationPath.Replace(".wim","-$((Get-Date).ToString(`"yyyyMMdd`")).wim"))"
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Add-LogContent "ERROR: Unable to backup $destinationPath"
            Add-LogContent "ERROR: $ErrorMessage"
        }

        # Backup the Existing Upgrade Content Path
        if ($ImportOSUpgrade) {
            try {
                Add-LogContent "Backing Up $OSUpgradePath to: $OSUpgradePath-$((Get-Date).ToString(`"yyyyMMdd`"))"
                Move-Item -path "$OSUpgradePath" -Destination "$OSUpgradePath-$((Get-Date).ToString(`"yyyyMMdd`"))" -ErrorAction Stop
                Add-LogContent "Backed Up $OSUpgradePath to: $OSUpgradePath-$((Get-Date).ToString(`"yyyyMMdd`"))"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Add-LogContent "ERROR: Unable to backup $destinationPath"
                Add-LogContent "ERROR: $ErrorMessage"
            }
        }
    } else {
        $destinationPath = "$Global:ContentShare\$($Build.Name).wim"
        $osUpgradePath = "$Global:OSUpgradeContentShare\$($Build.Name)"
    }

    # Upgrade and Import OS Item
    if ((Test-Path $wimLocation) -and (-not (Test-Path $destinationPath)) -and (-not $updateExistingImage)){
        Add-LogContent "Pre-Check Complete - Import can continue"
        
        # Copy the selected install.wim to the ContentShare using the build name
        copy-OSDBuilderObject -Type Image -name $BuildName -source $wimLocation -destination $destinationPath

        # Import the newly Copied wim
        import-OSDBuilderObject -Type Image -Name $BuildName -Path $destinationPath -version $BuildVersion -Description $BuildDescription
        
        # Distribute the new OSImage to the Specified Distribution Point Group
        Update-OSContent -Type Image -Name $BuildName

    }
    elseif ((Test-Path $OSLocation) -and $updateExistingImage) {
        Add-LogContent "Pre-Check Complete - Updating Existing OSImage Item - Import can continue"

        # Copy the install.wim to the same location as the original
        copy-OSDBuilderObject -Type Image -name $BuildName -source $wimLocation -destination $destinationPath

        # Redistribute the Content
        Update-OSContent -Type Image -Name $BuildName
    } 
    else {
        if (-not (Test-Path $wimLocation)){
            Add-LogContent "ERROR: install.wim not found at $wimLocation - Skipping import for $($Build.Name)"
        }
        if (Test-Path $destinationPath){
            Add-LogContent "ERROR: $destinationPath already exists! Skipping import for $($Build.Name)"
        }
    }

    # Import OSUpgradePackage
    if ($ImportOSUpgrade) {
        if ((Test-Path $OSLocation) -and (-not (Test-Path $osUpgradePath)) -and (-not $updateExistingImage)){
            Add-LogContent "Pre-Check Complete - Creating New OSUpgrade Item - Import can continue"

            # Copy the Upgrade package to the Content Share
            copy-OSDBuilderObject -Type UpgradePackage -name $BuildName -source $OSLocation -destination $osUpgradePath

            # Import the OS Upgrade Package
            import-OSDBuilderObject -Type UpgradePackage -Name $BuildName -Path $osUpgradePath -version $BuildVersion -Description $BuildDescription

            # Distribute the Content
            Start-Sleep 10 ## Should help with failed content distribution
            Update-OSContent -Type UpgradePackage -Name $BuildName

        }
        elseif ((Test-Path $OSLocation) -and $updateExistingImage) {
            Add-LogContent "Pre-Check Complete - Updating Existing OSUpgrade Item - Import can continue"

            # Copy the Upgrade package to the Content Share
            $OSUpgradeName =$OSUpgradeSelection.Name
            copy-OSDBuilderObject -Type UpgradePackage -name $OSUpgradeName -source $OSLocation -destination $osUpgradePath

            # Distribute the Content
            Start-Sleep 10 ## Should help with failed content distribution
            Update-OSContent -Type UpgradePackage -Name $OSUpgradeName
        } 
        Else {
            if (-not (Test-Path $wimLocation)){
                Add-LogContent "ERROR: install.wim not found at $wimLocation - Skipping import for $($Build.Name)"
            }
            if (Test-Path $destinationPath){
                Add-LogContent "ERROR: $osUpgradePath already exists! Skipping import for $($Build.Name)"
            }
        }
    }
}

if ($UpdateTS) {
    Push-Location
    Set-Location $Global:SCCMSite
    Add-LogContent "Waiting 60 Seconds before updating task sequence (This hopefully prevents some issues)"
    Start-Sleep 60
    Add-LogContent "Updating Task Sequence Step $TaskSequenceStepName on $TaskSequenceName with new package $BuildName" 
    Add-LogContent "Set-CMTaskSequenceStepApplyOperatingSystem -ImagePackage (Get-CMOperatingSystemImage -Name `"$BuildName`") -ImagePackageIndex 1 -TaskSequenceName $TaskSequenceName -StepName $TaskSequenceStepName"
    try {
        Set-CMTaskSequenceStepApplyOperatingSystem -ImagePackage (Get-CMOperatingSystemImage -Name "$BuildName") -ImagePackageIndex 1 -TaskSequenceName $TaskSequenceName -StepName $TaskSequenceStepName -ErrorAction Stop
    } catch {
        $ErrorMessage = $_.Exception.Message
        Add-LogContent "ERROR: Failed to Update Task Sequence"
        Add-LogContent $ErrorMessage
    }
    Pop-Location
}

Add-LogContent "Import-OSBuild has Completed!"