#This file handels the remote connection to the target machines

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