$ErrorActionPreference = 'Stop'
$file = (Get-ChildItem -Path $env:LOCALAPPDATA\Programs\Cursor\resources\app\out -Recurse -Filter 'workbench.desktop.main.js' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $file) {
    $file = (Get-ChildItem -Path 'C:\Program Files\Cursor\resources\app\out' -Recurse -Filter 'workbench.desktop.main.js' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if ($file) {
    $content = [System.IO.File]::ReadAllText($file)
    $matches = [regex]::Matches($content, '.{0,120}"Open Browser".{0,120}')
    $results = $matches | ForEach-Object { $_.Value }
    [System.IO.File]::WriteAllLines('C:\Users\Zacha\OneDrive\Documents\myApplications\VS_code_browser_removal_tool\open_browser_matches.txt', $results)
}
