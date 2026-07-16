$ErrorActionPreference = 'Stop'
$file = 'C:\Users\Zacha\vscode-simple-browser-backup\Cursor__AppData__workbench.desktop.main.js.20260716-172322.bak'
$content = [System.IO.File]::ReadAllText($file)
$parts = $content -split '"disabled.workbench.action.openBrowserEditor"'
$results = @()
for ($i=0; $i -lt $parts.Length - 1; $i++) {
    $before = $parts[$i]
    $after = $parts[$i+1]
    # Give a HUGE window to capture the whole class
    $snippet = $before.Substring([math]::Max(0, $before.Length - 200)) + '"disabled.workbench.action.openBrowserEditor"' + $after.Substring(0, [math]::Min($after.Length, 800))
    $results += $snippet
    $results += "----------------------------------------"
}
[System.IO.File]::WriteAllLines('C:\Users\Zacha\OneDrive\Documents\myApplications\VS_code_browser_removal_tool\fast_results_openbrowser.txt', $results)
