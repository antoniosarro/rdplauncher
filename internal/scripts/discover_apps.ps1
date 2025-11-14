# internal/scripts/discover_apps.ps1
#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Discovers installed applications on Windows and outputs them as JSON.

.DESCRIPTION
    Scans multiple sources (System, Registry, Start Menu, UWP, Chocolatey, Scoop)
    to build a comprehensive list of installed applications with icons.
    Designed to run as a Windows service for the RDP launcher.

.OUTPUTS
    JSON array of application objects with Name, Path, Args, Icon, and Source properties.
#>

[CmdletBinding()]
param()

# Strict mode for better error catching
Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

#region Configuration

# System paths
$script:SystemRoot = $env:SystemRoot
$script:System32Path = Join-Path -Path $script:SystemRoot -ChildPath "System32"
$script:WinDir = $env:WINDIR

# Default fallback icon (32x32 transparent PNG)
$script:DefaultIconBase64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAAAXNSR0IB2cksfwAAAAlwSFlzAAALEwAACxMBAJqcGAAAASZQTFRFAAAA+vr65ubm4uLkhYmLvL7A7u7w+/r729vb4eHjFYPbFoTa5eXnGIbcG4jc+fn7Gofc7+/x7OzuF4Xb+fn54uLiC37Z5OTmEIHaIIjcEYHbDoDZFIPcJ43fHYjd9fX28PDy3d3fI4rd3d3dHojc19fXttTsJIve2dnZDX/YCn3Y09PTjL/p5+fph7zo2traJYzfIYjdE4Pb6urrW6Tf9PT1Ioneir7otNPsCX3Zhbvn+Pj5YKfhJYfWMo7a39/gKIzeKo7eMI3ZNJDcXqbg4eHhuNTsB3zYIoncBXvZLIrXIYjbLJDgt7m6ubu+YqjiKYvYvr6+tba3rs/sz8/P1+byJonXv7/DiImLxsbGjo6Ra6ruurq6io6QkJKVw8PD0tLSycnJq1DGywAAAGJ0Uk5TAP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////+BVJDaAAABY0lEQVR4nM2RaVOCUBSGr1CBgFZimppgoGnKopZSaYGmRpravq///0904IqOM9h00WeGT+9ztgtCS8Dzyh98fL6i2+HqQoaj0RPSzQNgzZc4F4wgvUuoqkr1er094MjlIeBCwRdFua9CqURQ51cty7Lykj0YCIIibnlEkS4TgCuky3nbTmSFsCKSHeso96N/Ox1aacjrlYQQ3gjNCYV7UlUJ6szCeRZyXmlkNjEZEPSuLIMAuYTreVYROQ8Y8SLTNAhlCdfzLMsaIhfHgEAT7pLtvFTH9QxTNWrmLsaEDu8558y2ZOP5LLNTNUQyiCFnHaRZnjTmzryhnR36FSdnIU9up7RGxAOuKJjOFX2vHvKU5jPiepbvxzR3BIffwROc++AAJy9qjQxQwz9rIjyGeN6tj8VACEyZCqfQn3H7F48vTvwEdlIP+aWvMNkPcl8h8DYeN5vNTqdzCNz5CIv4h7AE/AKcwUFbShJywQAAAABJRU5ErkJggg=="

#endregion

#region Helper Functions

<#
.SYNOPSIS
    Adds spaces to CamelCase or PascalCase strings.
#>
function Add-SpacesToCamelCase {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InputString
    )

    # Skip processing for invalid inputs
    if ([string]::IsNullOrWhiteSpace($InputString) -or 
        $InputString -match '\s' -or 
        $InputString -match '^\d+$' -or 
        $InputString.Length -lt 3) {
        return $InputString
    }

    try {
        # Insert spaces at camel case boundaries
        $pattern = '((?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-zA-Z])(?=[0-9]))'
        $spaced = $InputString -replace $pattern, ' '
        return $spaced.Trim()
    }
    catch {
        return $InputString
    }
}

<#
.SYNOPSIS
    Extracts and converts an application icon to 32x32 PNG Base64.
#>
function Get-ApplicationIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    # Validate prerequisites
    if (-not [System.Drawing.Icon] -or 
        -not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        return $script:DefaultIconBase64
    }

    try {
        # Extract icon from file
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($TargetPath)
        if ($null -eq $icon) {
            return $script:DefaultIconBase64
        }

        # Convert to bitmap and resize to 32x32
        $bitmap = $icon.ToBitmap()
        $resizedBitmap = New-Object System.Drawing.Bitmap(32, 32)
        $graphics = [System.Drawing.Graphics]::FromImage($resizedBitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($bitmap, 0, 0, 32, 32)

        # Convert to PNG Base64
        $stream = New-Object System.IO.MemoryStream
        $resizedBitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $base64 = [Convert]::ToBase64String($stream.ToArray())

        return $base64
    }
    catch {
        return $script:DefaultIconBase64
    }
    finally {
        # Clean up resources
        if ($stream) { $stream.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($resizedBitmap) { $resizedBitmap.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($icon) { $icon.Dispose() }
    }
}

<#
.SYNOPSIS
    Gets the best display name for an application using priority order.
#>
function Get-ApplicationName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$TargetPath,
        [string]$LnkPath
    )

    $appName = $null

    # Priority 1: Target executable's FileDescription
    if ($TargetPath -and 
        $TargetPath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase) -and 
        (Test-Path $TargetPath -PathType Leaf)) {
        try {
            $description = (Get-Item $TargetPath).VersionInfo.FileDescription
            if (-not [string]::IsNullOrWhiteSpace($description)) {
                $appName = $description.Trim() -replace '\s+', ' '
            }
        }
        catch { }
    }

    # Priority 2: LNK filename
    if (-not $appName -and $LnkPath -and (Test-Path $LnkPath -PathType Leaf)) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($LnkPath)
        $appName = Add-SpacesToCamelCase -InputString $baseName
    }

    # Priority 3: Target filename
    if (-not $appName -and $TargetPath -and (Test-Path $TargetPath -PathType Leaf)) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
        $appName = Add-SpacesToCamelCase -InputString $baseName
    }

    return $appName
}

<#
.SYNOPSIS
    Prettifies a package name by adding spaces.
#>
function Get-PrettifiedName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Extract last segment after period
    if ($Name -match '\.([^\.]+)$') {
        $productName = $Matches[1]
    }
    else {
        $productName = $Name
    }
    
    # Add spaces before capitals and special characters
    $prettyName = ($productName -creplace '([A-Z\W_]|\d+)(?<![a-z])', ' $&').Trim()
    return $prettyName
}

<#
.SYNOPSIS
    Gets the display name for a UWP application.
#>
function Get-UWPApplicationName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$App
    )

    if ($App.DisplayName) {
        return $App.DisplayName.Trim()
    }
    
    if ($App.Name) {
        return Get-PrettifiedName -Name $App.Name
    }

    return $null
}

<#
.SYNOPSIS
    Parses UWP AppxManifest.xml to extract logo path and App ID.
#>
function Get-ParsedUWPManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$InstallLocation
    )

    $manifestPath = Join-Path -Path $InstallLocation -ChildPath "AppxManifest.xml"
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        return @{ Logo = $null; AppId = $null }
    }

    try {
        $xmlContent = Get-Content $manifestPath -Raw -Encoding Default
        
        # Extract App ID
        $appId = "App" # Default
        if ($xmlContent -match '<Application[^>]*Id\s*=\s*"([^"]+)"') {
            $appId = $Matches[1]
        }

        # Extract Logo path
        $logo = $null
        $logoMatch = [regex]::Match(
            $xmlContent, 
            '<Properties.*?>.*?<Logo>(.*?)</Logo>.*?</Properties>', 
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        if ($logoMatch.Success) {
            $logo = $logoMatch.Groups[1].Value
        }

        return @{
            Logo  = $logo
            AppId = $appId
        }
    }
    catch {
        return @{ Logo = $null; AppId = $null }
    }
}

<#
.SYNOPSIS
    Converts a UWP logo to 32x32 PNG Base64.
#>
function Get-UWPLogoBase64 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$LogoPath,
        
        [Parameter(Mandatory)]
        [string]$InstallLocation
    )

    $logoFullPath = Join-Path -Path $InstallLocation -ChildPath $LogoPath

    # Try to find the logo file, checking scaled versions if needed
    if (-not (Test-Path $logoFullPath)) {
        $scaledVersions = @("scale-100", "scale-200", "scale-400")
        foreach ($scale in $scaledVersions) {
            $scaledPath = $logoFullPath -replace '\.png$', ".$scale.png"
            if (Test-Path $scaledPath) {
                $logoFullPath = $scaledPath
                break
            }
        }

        if (-not (Test-Path $logoFullPath)) {
            return $null
        }
    }

    try {
        $image = [System.Drawing.Image]::FromFile($logoFullPath)

        # Resize to 32x32
        $resizedBitmap = New-Object System.Drawing.Bitmap(32, 32)
        $graphics = [System.Drawing.Graphics]::FromImage($resizedBitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($image, 0, 0, 32, 32)

        # Convert to PNG Base64
        $stream = New-Object System.IO.MemoryStream
        $resizedBitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $base64 = [Convert]::ToBase64String($stream.ToArray())

        return $base64
    }
    catch {
        return $null
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($resizedBitmap) { $resizedBitmap.Dispose() }
        if ($image) { $image.Dispose() }
    }
}

#endregion

#region Application Collection

# Initialize collections
$apps = [System.Collections.Generic.List[PSCustomObject]]::new()
$addedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

<#
.SYNOPSIS
    Validates and adds an application to the collection if unique and valid.
#>
function Add-ApplicationIfValid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        [string]$InputPath,
        
        [Parameter(Mandatory)]
        [ValidateSet('system', 'winreg', 'startmenu', 'uwp', 'choco', 'scoop')]
        [string]$Source,
        
        [string]$LaunchArgs = "",
        
        [string]$IconBase64
    )

    # Handle UWP apps specially
    if ($Source -eq 'uwp') {
        $normalizedKey = ($InputPath + $LaunchArgs).ToLowerInvariant()
        
        if ($addedPaths.Contains($normalizedKey)) {
            return # Duplicate
        }

        $apps.Add([PSCustomObject]@{
                Name   = $Name
                Path   = $InputPath
                Args   = $LaunchArgs
                Icon   = $IconBase64
                Source = $Source
            })
        
        $addedPaths.Add($normalizedKey) | Out-Null
        return
    }

    # Resolve and validate non-UWP paths
    try {
        $resolved = Resolve-Path -Path $InputPath
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Leaf)) {
            return # Invalid path
        }
        
        $fullPath = $resolved.ProviderPath
        $normalizedKey = $fullPath.ToLowerInvariant()
    }
    catch {
        return # Path resolution failed
    }

    # Validate name
    if ([string]::IsNullOrWhiteSpace($Name) -or 
        $Name -like 'Microsoft? Windows? Operating System*') {
        return # Invalid name
    }

    # Check for duplicates
    if ($addedPaths.Contains($normalizedKey)) {
        return
    }

    # Get icon if not provided
    if (-not $IconBase64) {
        $IconBase64 = Get-ApplicationIcon -TargetPath $fullPath
    }

    # Add application
    $apps.Add([PSCustomObject]@{
            Name   = $Name
            Path   = $fullPath
            Args   = $LaunchArgs
            Icon   = $IconBase64
            Source = $Source
        })
    
    $addedPaths.Add($normalizedKey) | Out-Null
}

#endregion

#region Application Discovery

<#
.SYNOPSIS
    Discovers system tools.
#>
function Find-SystemTools {
    [CmdletBinding()]
    param()

    $tools = @(
        @{ Name = "Task Manager"; Path = Join-Path $script:System32Path "Taskmgr.exe" }
        @{ Name = "Control Panel"; Path = Join-Path $script:System32Path "control.exe" }
        @{ Name = "File Explorer"; Path = Join-Path $script:WinDir "explorer.exe" }
        @{ Name = "Command Prompt"; Path = Join-Path $script:System32Path "cmd.exe" }
        @{ Name = "PowerShell"; Path = Join-Path $script:System32Path "WindowsPowerShell\v1.0\powershell.exe" }
        @{ Name = "Notepad"; Path = Join-Path $script:System32Path "notepad.exe" }
        @{ Name = "Paint"; Path = Join-Path $script:System32Path "mspaint.exe" }
        @{ Name = "Registry Editor"; Path = Join-Path $script:WinDir "regedit.exe" }
        @{ Name = "Services"; Path = Join-Path $script:System32Path "services.msc" }
        @{ Name = "Device Manager"; Path = Join-Path $script:System32Path "devmgmt.msc" }
        @{ Name = "Computer Management"; Path = Join-Path $script:System32Path "compmgmt.msc" }
        @{ Name = "Disk Management"; Path = Join-Path $script:System32Path "diskmgmt.msc" }
        @{ Name = "Snipping Tool"; Path = Join-Path $script:System32Path "SnippingTool.exe" }
        @{ Name = "Calculator"; Path = Join-Path $script:System32Path "win32calc.exe" }
        @{ Name = "Remote Desktop Connection"; Path = Join-Path $script:System32Path "mstsc.exe" }
    )

    foreach ($tool in $tools) {
        Add-ApplicationIfValid -Name $tool.Name -InputPath $tool.Path -Source 'system'
    }
}

<#
.SYNOPSIS
    Discovers applications from Windows Registry App Paths.
#>
function Find-RegistryApps {
    [CmdletBinding()]
    param()

    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    )

    foreach ($regRoot in $regRoots) {
        if (-not (Test-Path $regRoot)) {
            continue
        }

        Get-ChildItem $regRoot | ForEach-Object {
            $keyName = $_.PSChildName
            $defaultValue = $null

            try {
                $defaultValue = (Get-ItemProperty $_.PSPath).'(default)'
                if ($defaultValue) {
                    $pathValue = $ExecutionContext.InvokeCommand.ExpandString($defaultValue.Trim('"'))
                    
                    $appName = Get-ApplicationName -TargetPath $pathValue
                    if (-not $appName) {
                        $appName = Add-SpacesToCamelCase -InputString ([System.IO.Path]::GetFileNameWithoutExtension($keyName))
                    }

                    if ($appName) {
                        Add-ApplicationIfValid -Name $appName -InputPath $pathValue -Source 'winreg'
                    }
                }
            }
            catch { }
        }
    }
}

<#
.SYNOPSIS
    Discovers applications from Start Menu shortcuts.
#>
function Find-StartMenuApps {
    [CmdletBinding()]
    param()

    $startMenuPaths = @("C:\ProgramData\Microsoft\Windows\Start Menu\Programs")

    # Add user-specific Start Menu paths
    try {
        $usersPath = "C:\Users"
        if (Test-Path $usersPath -PathType Container) {
            Get-ChildItem $usersPath -Directory | 
                Where-Object { $_.Name -notin @("Public", "All Users", "Default", "Default User") } |
                ForEach-Object {
                    $userStartMenu = Join-Path $_.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
                    if (Test-Path $userStartMenu -PathType Container) {
                        $startMenuPaths += $userStartMenu
                    }
                }
        }
    }
    catch { }

    # Collect .lnk files
    $lnkFiles = @()
    foreach ($path in $startMenuPaths) {
        if (Test-Path $path -PathType Container) {
            $lnkFiles += Get-ChildItem -Path $path -Recurse -Filter *.lnk -File
        }
    }

    if ($lnkFiles.Count -eq 0) {
        return
    }

    # Process shortcuts
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($lnk in $lnkFiles) {
            try {
                $link = $shell.CreateShortcut($lnk.FullName)
                $target = $link.TargetPath

                if (-not $target) {
                    continue
                }

                # Expand environment variables
                $target = $ExecutionContext.InvokeCommand.ExpandString($target)

                # Skip uninstallers
                if ($target -like '*uninstall*' -or $target -like '*unins000*') {
                    continue
                }

                # Fix SYSTEM profile paths
                $systemProfilePath = "C:\WINDOWS\system32\config\systemprofile"
                if ($target -like "$systemProfilePath*") {
                    $relativePath = $target -replace [regex]::Escape($systemProfilePath), ""
                    if ($lnk.FullName -match "\\Users\\([^\\]+)\\") {
                        $userName = $Matches[1]
                        $userTarget = "C:\Users\$userName$relativePath"
                        if (Test-Path $userTarget -PathType Leaf) {
                            $target = $userTarget
                        }
                    }
                }

                $appName = Get-ApplicationName -TargetPath $target -LnkPath $lnk.FullName

                if ($appName) {
                    Add-ApplicationIfValid -Name $appName -InputPath $target -Source 'startmenu'
                }
            }
            catch { }
        }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

<#
.SYNOPSIS
    Discovers UWP applications.
#>
function Find-UWPApps {
    [CmdletBinding()]
    param()

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        return
    }

    Get-AppxPackage -AllUsers | 
        Where-Object {
        $_.IsFramework -eq $false -and
        $_.IsResourcePackage -eq $false -and
        $_.SignatureKind -notin @('System', 'Developer') -and
        $_.InstallLocation
    } |
        ForEach-Object {
        $app = $_
        
        $manifest = Get-ParsedUWPManifest -InstallLocation $app.InstallLocation
        if (-not $manifest.AppId) {
            return
        }

        $launchArgs = "shell:AppsFolder\$($app.PackageFamilyName)!$($manifest.AppId)"
        $appName = Get-UWPApplicationName -App $app

        if ($appName) {
            $iconBase64 = $null
            if ($manifest.Logo) {
                $iconBase64 = Get-UWPLogoBase64 -LogoPath $manifest.Logo -InstallLocation $app.InstallLocation
            }

            Add-ApplicationIfValid `
                -Name $appName `
                -InputPath "explorer.exe" `
                -Source 'uwp' `
                -LaunchArgs $launchArgs `
                -IconBase64 $iconBase64
        }
    }
}

<#
.SYNOPSIS
    Discovers Chocolatey installed applications.
#>
function Find-ChocolateyApps {
    [CmdletBinding()]
    param()

    $chocoDir = "C:\ProgramData\chocolatey\bin"
    if (-not (Test-Path $chocoDir -PathType Container)) {
        return
    }

    Get-ChildItem -Path $chocoDir -Filter *.exe -File | ForEach-Object {
        $shim = $_
        
        try {
            $cmdInfo = Get-Command $shim.FullName
            if ($cmdInfo -and $cmdInfo.Source -ne $shim.FullName) {
                $exePath = $cmdInfo.Source
                $appName = Get-ApplicationName -TargetPath $exePath
                
                if (-not $appName) {
                    $appName = Add-SpacesToCamelCase -InputString $shim.BaseName
                }

                if ($appName) {
                    Add-ApplicationIfValid -Name $appName -InputPath $exePath -Source 'choco'
                }
            }
        }
        catch { }
    }
}

<#
.SYNOPSIS
    Discovers Scoop installed applications.
#>
function Find-ScoopApps {
    [CmdletBinding()]
    param()

    $scoopPaths = @(
        (Join-Path $env:USERPROFILE "scoop\shims")
        "C:\ProgramData\scoop\shims"
    )

    $scoopDir = $scoopPaths | Where-Object { Test-Path $_ -PathType Container } | Select-Object -First 1

    if (-not $scoopDir) {
        return
    }

    Get-ChildItem -Path $scoopDir -File | 
        Where-Object { $_.Name -ne 'scoop.ps1' } |
        ForEach-Object {
        $shim = $_
        $exePath = $null

        try {
            $cmdInfo = Get-Command $shim.FullName
            if ($cmdInfo -and $cmdInfo.Source -ne $shim.FullName) {
                $exePath = $cmdInfo.Source
            }
        }
        catch { }

        # Fallback: Parse shim file content
        if (-not $exePath -and $shim.Extension -in @('.cmd', '.ps1', '')) {
            try {
                $content = Get-Content $shim.FullName -Raw -TotalCount 5
                if ($content -match '(?<=")([^"]+?\.exe)(?=")') {
                    $relativePath = $Matches[1] -replace '%~dp0', $shim.DirectoryName
                    $exePath = (Resolve-Path $relativePath).Path
                }
            }
            catch { }
        }

        if ($exePath) {
            $appName = Get-ApplicationName -TargetPath $exePath
            if (-not $appName) {
                $appName = Add-SpacesToCamelCase -InputString $shim.BaseName
            }

            if ($appName) {
                Add-ApplicationIfValid -Name $appName -InputPath $exePath -Source 'scoop'
            }
        }
    }
}

#endregion

#region Main Execution

# Load System.Drawing for icon extraction
Add-Type -AssemblyName System.Drawing

# Run all discovery functions
Find-SystemTools
Find-RegistryApps
Find-StartMenuApps
Find-UWPApps
Find-ChocolateyApps
Find-ScoopApps

# Output as compressed JSON
$apps | ConvertTo-Json -Depth 5 -Compress

#endregion