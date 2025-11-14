$info = @{
    ComputerName = $env:COMPUTERNAME
    OSVersion = [System.Environment]::OSVersion.VersionString
    ProcessorCount = $env:NUMBER_OF_PROCESSORS
    Uptime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Memory = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
}

$info | ConvertTo-Json