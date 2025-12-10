#This file handles the remote connection to the target machines

function Test-RemoteConnection {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password
    )

    try {
        Write-Host "Testing connectivity to $IP..." -ForegroundColor Cyan
        
        # Ping the target machine 4 times
        $successfulPings = 0
        $maxAttempts = 4
        
        for ($i = 1; $i -le $maxAttempts; $i++) {
            Write-Host "  Ping attempt $i of $maxAttempts..." -NoNewline
            
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            
            if ($pingResult) {
                $successfulPings++
                Write-Host " Success" -ForegroundColor Green
            }
            else {
                Write-Host " Failed" -ForegroundColor Red
            }
            
            Start-Sleep -Milliseconds 500
        }
        
        # Check if all pings were successful
        if ($successfulPings -eq $maxAttempts) {
            Write-Host "All pings successful! Proceeding with connection..." -ForegroundColor Green
            
            # TODO: Implement SSH/WinRM connection logic here
            # Detect OS and use appropriate method
            
            return $true
        }
        else {
            Write-Host "Ping test failed. $successfulPings out of $maxAttempts pings successful." -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error testing connection to $IP : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-SSHConnection {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password
    )
    
    try {
        Write-Host "Testing SSH connection to $IP..." -ForegroundColor Cyan

        #Create secure string from password
        $sshSecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $sshCredential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)

        # Test SSH connection
        $sshSession = New-PSSession -HostName $IP -UserName $User -SSHTransport -ErrorAction Stop

        if ($sshSession) {
            Write-Host "SSH connection successful!" -ForegroundColor Green
            
            # Test by running a command
            $result = Invoke-Command -Session $sshSession -ScriptBlock { hostname }
            Write-Host "Connected to: $result" -ForegroundColor Green
            
            # Close session
            Remove-PSSession -Session $sshSession
            return $true
        }
    }
    catch {
        Write-Host "Error testing SSH connection to $IP : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Export functions to make them available when module is imported
Export-ModuleMember -Function Test-RemoteConnection, Test-SSHConnection
