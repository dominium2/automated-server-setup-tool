<#
.SYNOPSIS
    Clears the cached PuTTY/Plink SSH host key for a specific IP address.

.DESCRIPTION
    When VMs are recreated on the same IP, the SSH host key changes, triggering a 
    potential security breach warning in Plink. This function removes the specific 
    cached key from the Windows Registry to allow a fresh connection while keeping 
    standard SSH security checks intact.

.PARAMETER IPAddress
    The IP address of the VM to clear from the cache.
#>
function Clear-CachedSSHKey {
    param (
        [Parameter(Mandatory=$true)]
        [string]$IPAddress
    )
    
    # PuTTY and Plink store cached host keys in this registry path
    $registryPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
    
    if (Test-Path $registryPath) {
        $keyItem = Get-Item -Path $registryPath
        
        # PuTTY stores keys as Name=Value. The name format is usually algorithm@port:IP
        # We escape the IP address to ensure regex parses the literal periods.
        $escapedIP = [regex]::Escape($IPAddress)
        $matchingKeys = $keyItem.GetValueNames() | Where-Object { $_ -match ":$escapedIP$" }
        
        if ($matchingKeys.Count -gt 0) {
            foreach ($key in $matchingKeys) {
                Remove-ItemProperty -Path $registryPath -Name $key -Force
                Write-Host "Successfully cleared cached SSH key for $IPAddress ($key)." -ForegroundColor Green
            }
        } else {
            Write-Host "No cached SSH keys found for $IPAddress." -ForegroundColor Yellow
        }
    } else {
        Write-Host "PuTTY SSH Host Keys registry path not found. Nothing to clear." -ForegroundColor Yellow
    }
}

Clear-CachedSSHKey -IPAddress "192.168.56.11"