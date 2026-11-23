$registryPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"

# Create the registry key if it does not exist
If (!(Test-Path $registryPath)) {
    New-Item -Path "HKLM:\SOFTWARE\Policies" -Name "Google" -Force | Out-Null
    New-Item -Path "HKLM:\SOFTWARE\Policies\Google" -Name "Chrome" -Force | Out-Null
}

# 1. Disable Incognito Mode (1 = Disabled)
Set-ItemProperty -Path $registryPath -Name "IncognitoModeAvailability" -Value 1 -Type DWord

# 2. Disable Developer Tools (2 = Disallowed)
Set-ItemProperty -Path $registryPath -Name "DeveloperToolsAvailability" -Value 2 -Type DWord

# 3. Prevent clearing browsing data (0 = False)
Set-ItemProperty -Path $registryPath -Name "AllowDeletingBrowserHistory" -Value 0 -Type DWord

# 4. Enforce Google SafeSearch (1 = True)
Set-ItemProperty -Path $registryPath -Name "ForceGoogleSafeSearch" -Value 1 -Type DWord

Write-Host "Chrome lock-down policies applied successfully."
Write-Host "Please restart Chrome for the changes to take effect."
Write-Host "Note: You can check applied policies by navigating to chrome://policy/ in your Chrome address bar."
