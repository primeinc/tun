<#
.SYNOPSIS
Test script for SMTP sink implementation without requiring VM deployment

.DESCRIPTION
Validates syntax, configuration, and integration of SMTP sink components
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$testResults = @()

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message
    )
    
    $result = [PSCustomObject]@{
        Test = $TestName
        Passed = $Passed
        Message = $Message
    }
    
    $script:testResults += $result
    
    if ($Passed) {
        Write-Host "✓ $TestName" -ForegroundColor Green
    } else {
        Write-Host "✗ $TestName" -ForegroundColor Red
        Write-Host "  $Message" -ForegroundColor Yellow
    }
}

Write-Host "Running SMTP Sink Tests..." -ForegroundColor Cyan
Write-Host

# Test 1: Check Python script syntax
Write-Host "1. Testing Python script syntax..." -ForegroundColor Cyan
try {
    $pythonScript = Get-Content "$PSScriptRoot\..\scripts\smtp_sink.py" -Raw
    $tempFile = [System.IO.Path]::GetTempFileName() + ".py"
    Set-Content -Path $tempFile -Value $pythonScript
    
    $result = & python -m py_compile $tempFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-TestResult -TestName "Python Syntax" -Passed $true -Message "Script compiles successfully"
    } else {
        Write-TestResult -TestName "Python Syntax" -Passed $false -Message "Syntax error: $result"
    }
    Remove-Item $tempFile -Force
} catch {
    Write-TestResult -TestName "Python Syntax" -Passed $false -Message "Failed to test: $_"
}

# Test 2: Check for required imports
Write-Host "`n2. Testing Python imports..." -ForegroundColor Cyan
try {
    $imports = @('asyncio', 'signal', 'sys', 'logging')
    $missingImports = @()
    
    foreach ($import in $imports) {
        $result = & python -c "import $import" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $missingImports += $import
        }
    }
    
    if ($missingImports.Count -eq 0) {
        Write-TestResult -TestName "Core Imports" -Passed $true -Message "All core modules available"
    } else {
        Write-TestResult -TestName "Core Imports" -Passed $false -Message "Missing: $($missingImports -join ', ')"
    }
} catch {
    Write-TestResult -TestName "Core Imports" -Passed $false -Message "Failed to test: $_"
}

# Test 3: Check aiosmtpd availability
Write-Host "`n3. Testing aiosmtpd availability..." -ForegroundColor Cyan
try {
    $result = & python -c "import aiosmtpd" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-TestResult -TestName "aiosmtpd Import" -Passed $true -Message "aiosmtpd is available"
    } else {
        Write-TestResult -TestName "aiosmtpd Import" -Passed $false -Message "aiosmtpd not installed: pip install aiosmtpd"
    }
} catch {
    Write-TestResult -TestName "aiosmtpd Import" -Passed $false -Message "Failed to test: $_"
}

# Test 4: Validate systemd service file syntax
Write-Host "`n4. Testing systemd service configuration..." -ForegroundColor Cyan
try {
    $installScript = Get-Content "$PSScriptRoot\..\scripts\install.sh" -Raw
    
    # Extract systemd service content - look for the SMTP sink service specifically
    if ($installScript -match '(?s)# Create SMTP sink service.*?cat > "\$smtp_service_file" <<EOF(.+?)EOF') {
        $serviceContent = $Matches[1].Trim()
        
        # Check for required sections
        $requiredSections = @('[Unit]', '[Service]', '[Install]')
        $missingSections = @()
        
        foreach ($section in $requiredSections) {
            if ($serviceContent -notmatch [regex]::Escape($section)) {
                $missingSections += $section
            }
        }
        
        if ($missingSections.Count -eq 0) {
            Write-TestResult -TestName "Systemd Service Structure" -Passed $true -Message "All required sections present"
        } else {
            Write-TestResult -TestName "Systemd Service Structure" -Passed $false -Message "Missing sections: $($missingSections -join ', ')"
        }
        
        # Check for security directives
        $securityDirectives = @('ProtectSystem', 'NoNewPrivileges', 'AmbientCapabilities')
        $missingDirectives = @()
        
        foreach ($directive in $securityDirectives) {
            if ($serviceContent -notmatch $directive) {
                $missingDirectives += $directive
            }
        }
        
        if ($missingDirectives.Count -eq 0) {
            Write-TestResult -TestName "Security Directives" -Passed $true -Message "All security directives present"
        } else {
            Write-TestResult -TestName "Security Directives" -Passed $false -Message "Missing directives: $($missingDirectives -join ', ')"
        }
    } else {
        Write-TestResult -TestName "Systemd Service Structure" -Passed $false -Message "Could not extract service definition"
    }
} catch {
    Write-TestResult -TestName "Systemd Service Structure" -Passed $false -Message "Failed to test: $_"
}

# Test 5: Check Bicep NSG rule
Write-Host "`n5. Testing Bicep NSG configuration..." -ForegroundColor Cyan
try {
    $bicepContent = Get-Content "$PSScriptRoot\..\infra\main.bicep" -Raw
    
    if ($bicepContent -match "name:\s*'SMTP'") {
        Write-TestResult -TestName "NSG SMTP Rule" -Passed $true -Message "SMTP rule found in NSG"
        
        # Check port configuration
        if ($bicepContent -match "destinationPortRange:\s*'25'") {
            Write-TestResult -TestName "NSG Port Configuration" -Passed $true -Message "Port 25 correctly configured"
        } else {
            Write-TestResult -TestName "NSG Port Configuration" -Passed $false -Message "Port 25 not found in SMTP rule"
        }
    } else {
        Write-TestResult -TestName "NSG SMTP Rule" -Passed $false -Message "SMTP rule not found in NSG configuration"
    }
} catch {
    Write-TestResult -TestName "NSG SMTP Rule" -Passed $false -Message "Failed to test: $_"
}

# Test 6: Check file references in redeploy-extension.ps1
Write-Host "`n6. Testing deployment script integration..." -ForegroundColor Cyan
try {
    $redeployContent = Get-Content "$PSScriptRoot\..\scripts\redeploy-extension.ps1" -Raw
    
    if ($redeployContent -match 'smtp_sink\.py') {
        Write-TestResult -TestName "Deployment Integration" -Passed $true -Message "smtp_sink.py included in deployment"
    } else {
        Write-TestResult -TestName "Deployment Integration" -Passed $false -Message "smtp_sink.py not found in deployment script"
    }
} catch {
    Write-TestResult -TestName "Deployment Integration" -Passed $false -Message "Failed to test: $_"
}

# Test 7: Validate install.sh bash syntax
Write-Host "`n7. Testing install.sh bash syntax..." -ForegroundColor Cyan
try {
    $installPath = Join-Path (Split-Path $PSScriptRoot) "scripts" "install.sh"
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        $result = & bash -n $installPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-TestResult -TestName "Bash Syntax" -Passed $true -Message "install.sh syntax is valid"
        } else {
            Write-TestResult -TestName "Bash Syntax" -Passed $false -Message "Syntax error: $result"
        }
    } else {
        Write-TestResult -TestName "Bash Syntax" -Passed $false -Message "Bash not available for testing"
    }
} catch {
    Write-TestResult -TestName "Bash Syntax" -Passed $false -Message "Failed to test: $_"
}

# Test 8: Check documentation
Write-Host "`n8. Testing documentation..." -ForegroundColor Cyan
try {
    $docPath = "$PSScriptRoot\..\docs\MX-SMTP-SINK.md"
    if (Test-Path $docPath) {
        $docContent = Get-Content $docPath -Raw
        
        # Check for critical sections
        $requiredSections = @('Security Considerations', 'CRITICAL WARNING', 'Setup', 'Usage')
        $missingSections = @()
        
        foreach ($section in $requiredSections) {
            if ($docContent -notmatch [regex]::Escape($section)) {
                $missingSections += $section
            }
        }
        
        if ($missingSections.Count -eq 0) {
            Write-TestResult -TestName "Documentation Completeness" -Passed $true -Message "All required sections present"
        } else {
            Write-TestResult -TestName "Documentation Completeness" -Passed $false -Message "Missing sections: $($missingSections -join ', ')"
        }
    } else {
        Write-TestResult -TestName "Documentation Completeness" -Passed $false -Message "Documentation file not found"
    }
} catch {
    Write-TestResult -TestName "Documentation Completeness" -Passed $false -Message "Failed to test: $_"
}

# Test 9: Simulate SMTP server startup (without actually binding to port)
Write-Host "`n9. Testing SMTP server initialization..." -ForegroundColor Cyan
try {
    $scriptsPath = Join-Path (Split-Path $PSScriptRoot) "scripts"
    $testScript = @"
import sys
sys.path.insert(0, r'$scriptsPath')
try:
    from smtp_sink import ConsoleHandler
    handler = ConsoleHandler()
    print("Handler created successfully")
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
"@
    
    $result = $testScript | & python - 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-TestResult -TestName "SMTP Handler Creation" -Passed $true -Message "Handler instantiates correctly"
    } else {
        Write-TestResult -TestName "SMTP Handler Creation" -Passed $false -Message "Failed to create handler: $result"
    }
} catch {
    Write-TestResult -TestName "SMTP Handler Creation" -Passed $false -Message "Failed to test: $_"
}

# Summary
Write-Host "`n" + ("="*50) -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host ("="*50) -ForegroundColor Cyan

$passed = ($testResults | Where-Object { $_.Passed }).Count
$failed = ($testResults | Where-Object { -not $_.Passed }).Count
$total = $testResults.Count

Write-Host "Total Tests: $total" -ForegroundColor White
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })

if ($Verbose) {
    Write-Host "`nDetailed Results:" -ForegroundColor Cyan
    $testResults | Format-Table -AutoSize
}

# Return success/failure
exit $(if ($failed -eq 0) { 0 } else { 1 })