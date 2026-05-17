#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Universally disables the integrated browser across VS Code, Windsurf, and Cursor.
.DESCRIPTION
    Uses regular expressions to dynamically find and neutralize browser commands
    in the minified JavaScript of the workbench. This allows the script to survive
    editor updates even when variable names change.
#>

$ErrorActionPreference = 'Stop'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = "$env:USERPROFILE\vscode-simple-browser-backup"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
$logFile = "$backupDir\disable-browser-dynamic-$timestamp.log"

function Log($msg) {
    $entry = "$(Get-Date -Format 'HH:mm:ss') $msg"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

Log "=== Universal Dynamic Browser Removal ==="

# Define all editor environments
$editors = @(
    @{
        Name = "VS Code"
        InstallBase = "C:\Program Files\Microsoft VS Code"
        Keybindings = "$env:APPDATA\Code\User\keybindings.json"
    },
    @{
        Name = "Windsurf"
        InstallBase = "$env:LOCALAPPDATA\Programs\Windsurf"
        Keybindings = "$env:APPDATA\Windsurf\User\keybindings.json"
    },
    @{
        Name = "Cursor (Program Files)"
        InstallBase = "C:\Program Files\Cursor"
        Keybindings = "$env:APPDATA\Cursor\User\keybindings.json"
    },
    @{
        Name = "Cursor (AppData)"
        InstallBase = "$env:LOCALAPPDATA\Programs\Cursor"
        Keybindings = "$env:APPDATA\Cursor\User\keybindings.json"
    }
)

# The human-readable titles of all browser-related commands we want to hide
$titles = @(
    "Go Back", "Go Forward", "Reload", "Hard Reload", "Open in External Browser",
    "Focus URL Input", "Find in Page", "Toggle Developer Tools",
    "Clear Storage (Ephemeral)", "Clear Storage (Global)", "Clear Storage (Workspace)",
    "Add Element to Chat", "Add Console Logs to Chat", "Open Integrated Browser",
    "Quick Open Browser Tab...", "Open URL"
)

foreach ($editor in $editors) {
    Log ""
    Log "--- Processing $($editor.Name) ---"
    
    # 1. Find workbench JS
    if (-not (Test-Path $editor.InstallBase)) {
        Log "Install directory not found: $($editor.InstallBase)"
        continue
    }
    
    # We ignore any folders named '_' which are sometimes used for backups/staging in Cursor
    $workbenchJsFiles = Get-ChildItem $editor.InstallBase -Recurse -Filter "workbench.desktop.main.js" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\_\\' }
    if ($workbenchJsFiles.Count -eq 0) {
        Log "Could not find workbench.desktop.main.js in $($editor.InstallBase)"
        continue
    }
    
    $workbenchJs = $workbenchJsFiles[0].FullName
    Log "Found workbench JS: $workbenchJs"
    
    # Backup
    $backupFile = "$backupDir\$($editor.Name -replace '[^\w]','_')_workbench.desktop.main.js.$timestamp.bak"
    Copy-Item $workbenchJs $backupFile
    Log "Created backup at $backupFile"
    
    $content = [System.IO.File]::ReadAllText($workbenchJs)
    $patchCount = 0
    
    # 2. Dynamic Regex Patching for Command Palette visibility (f1 flag)
    foreach ($title in $titles) {
        # Regex Explanation:
        # 1. `("Title"` -> Matches the exact title string in quotes.
        # 2. `(?:(?!"[A-Z]).){0,200}?` -> Lazily matches up to 200 characters of surrounding code. 
        #    The negative lookahead `(?!"[A-Z])` ensures it stops if it encounters another capitalized quoted string, 
        #    preventing it from accidentally matching across completely unrelated commands.
        # 3. `)f1\s*:\s*(?:!0|true)` -> Matches the end of our target block where the f1 visibility flag is set to true or !0. 
        # The entire matched prefix (everything before the actual boolean value) is captured in group $1, 
        # and we replace the boolean value with !1 (false).
        $pattern = '("' + [regex]::Escape($title) + '"(?:(?!"[A-Z]).){0,200}?)f1\s*:\s*(?:!0|true)'
        
        $matches = [regex]::Matches($content, $pattern)
        if ($matches.Count -gt 0) {
            $content = [regex]::Replace($content, $pattern, '${1}f1:!1')
            $patchCount += $matches.Count
            Log "  Patched f1 flag for: $title"
        }
    }
    
    # 3. Neuter openBrowserTab programmatic API
    # Regex Explanation:
    # `(async \s*\$?openBrowserTab\s*\([^)]*\)\s*\{)` -> Matches the start of the `async openBrowserTab(e,t,o){` function declaration.
    # It accounts for whitespace and an optional `$` prefix. 
    # We replace it by injecting `throw new Error("Integrated browser disabled");` right inside the function block so it fails immediately.
    $obtPattern = '(async \s*\$?openBrowserTab\s*\([^)]*\)\s*\{)'
    $obtMatches = [regex]::Matches($content, $obtPattern)
    if ($obtMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Integrated browser disabled")')) {
            $content = [regex]::Replace($content, $obtPattern, '${1}throw new Error("Integrated browser disabled");')
            $patchCount++
            Log "  Neutered openBrowserTab function"
        }
    }

    # 3.1 Neuter NEW Native open_browser_page Tool (VS Code 1.90+)
    $openBrowserToolPattern = '(var [a-zA-Z0-9_\$]+="open_browser_page".*?async invoke\([^)]*\)\s*\{)'
    $obtMatches2 = [regex]::Matches($content, $openBrowserToolPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($obtMatches2.Count -gt 0) {
        if (-not $content.Contains("The integrated browser has been permanently disabled on this system")) {
            $content = [regex]::Replace($content, $openBrowserToolPattern, '${1} return { content: [{ kind: "text", value: "The integrated browser has been permanently disabled on this system." }] }; ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $patchCount++
            Log "  Neutered native open_browser_page tool"
        }
    }

    # 3.2 Neuter NEW Native Open Integrated Browser Command
    $openIntegratedBrowserPattern = '("Open Integrated Browser".*?async run\([^)]*\)\s*\{)'
    $oibMatches = [regex]::Matches($content, $openIntegratedBrowserPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($oibMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Integrated browser forcibly disabled")')) {
            $content = [regex]::Replace($content, $openIntegratedBrowserPattern, '${1} throw new Error("Integrated browser forcibly disabled"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $patchCount++
            Log "  Neutered Open Integrated Browser command"
        }
    }

    # 3.3 Neuter NEW Quick Open Browser Tab Command
    $quickOpenBrowserPattern = '("Quick Open Browser Tab\.\.\.".*?run\([^)]*\)\s*\{)'
    $qobMatches = [regex]::Matches($content, $quickOpenBrowserPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($qobMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Quick browser forcibly disabled")')) {
            $content = [regex]::Replace($content, $quickOpenBrowserPattern, '${1} throw new Error("Quick browser forcibly disabled"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $patchCount++
            Log "  Neutered Quick Open Browser Tab command"
        }
    }

    # 3.4 Neuter NEW Native Browser Editor Resolver
    $browserResolverPattern = '(createEditorInput:\(\{resource:[a-zA-Z0-9_]+,options:[a-zA-Z0-9_]+\}\)=>\{)(let [a-zA-Z0-9_]+=[a-zA-Z0-9_\.]+\.parse[^}]*Invalid browser view resource)'
    $brMatches = [regex]::Matches($content, $browserResolverPattern)
    if ($brMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Integrated browser editor forcefully disabled")')) {
            $content = [regex]::Replace($content, $browserResolverPattern, '${1} throw new Error("Integrated browser editor forcefully disabled"); ${2}')
            $patchCount++
            Log "  Neutered Native Browser Editor Resolver"
        }
    }
    
    # 4. Zero View Menu keybinding
    # Regex Explanation:
    # `("Browser"[^}]+keybinding:\{[^}]+?primary:)\d+` -> Matches the "Browser" command title, looks ahead for its keybinding block, 
    # and captures everything up to the `primary:` key code assignment.
    # We replace the actual key code digits with 0, disabling the keyboard shortcut.
    $viewMenuPattern = '("Browser"[^}]+keybinding:\{[^}]+?primary:)\d+'
    $vmMatches = [regex]::Matches($content, $viewMenuPattern)
    if ($vmMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $viewMenuPattern, '${1}0')
        $patchCount++
        Log "  Zeroed View menu keybinding"
    }

    # 4.5 Strip onOpenExternalUri bindings
    # VS Code has a fallback manifest embedded in workbench.desktop.main.js that registers
    # the simple-browser to intercept http/https links. We must strip these out.
    $externalUriHooks = '"onOpenExternalUri:http","onOpenExternalUri:https",'
    if ($content.Contains($externalUriHooks)) {
        # Using [string]::Empty to ensure we delete the string entirely without breaking JS array syntax
        $content = $content.Replace($externalUriHooks, [string]::Empty)
        $patchCount++
        Log "  Stripped onOpenExternalUri hooks from internal manifest"
    }
    
    # 5. Windsurf Cascade Browser Overrides
    if ($editor.Name -match "Windsurf") {
        # Break the Cascade preview widget "in-ide" payload
        $inIdeValuePattern = 'value:"in-ide"'
        if ($content.Contains($inIdeValuePattern)) {
            $content = $content.Replace($inIdeValuePattern, 'value:"system"')
            $patchCount++
            Log "  Diverted Cascade preview widget payload to system"
        }

        # Strip the literal UI text from the In-IDE button so it collapses
        $inIdeTextPattern = 'children:"In-IDE"'
        if ($content.Contains($inIdeTextPattern)) {
            $content = $content.Replace($inIdeTextPattern, 'children:""')
            $patchCount++
            Log "  Stripped literal 'In-IDE' text from Cascade UI"
        }
    }
    
    # 5. Cursor AI Browser Overrides (Glass Palette Lobotomy)
    if ($editor.Name -match "Cursor") {
        # 5.1 Neuter Cursor explicitly named AI Browser Commands
        $cursorBrowserCmds = @("workbench.action.openBrowserEditor", "workbench.action.newBrowserTab", "composer.toggleBrowserTab", "composer.openBrowserTab")
        foreach ($cmd in $cursorBrowserCmds) {
            $pattern = '(class [a-zA-Z0-9_\$]+ extends [a-zA-Z0-9_\$]+\s*\{\s*static\s*\{\s*this\.ID="' + $cmd + '"\s*\}.*?run\([^)]*\)\s*\{)'
            $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($matches.Count -gt 0) {
                $matchText = $matches[0].Value
                # Only apply patch if this specific command hasn't been neutered yet
                if (-not $matchText.Contains("Cursor browser completely lobotomized")) {
                    $content = [regex]::Replace($content, $pattern, '${1} throw new Error("Cursor browser completely lobotomized"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $patchCount++
                    Log "  Neutered Cursor command: $cmd"
                }
            }
        }

        # The AI browser commands need their literal UI titles stripped to drop them from the glass palette
        $cursorTitles = @("New Browser Tab", "Focus Browser Location Bar", "Open cursor.com in Browser", "Reload Browser Tab")
        foreach ($ct in $cursorTitles) {
            $searchString = '"' + $ct + '"'
            if ($content.Contains($searchString)) {
                $content = $content.Replace($searchString, '""')
                $patchCount++
                Log "  Stripped Cursor AI browser title: $ct"
            }
        }
        
        # We also enforce f1:!1 on all toggle/close/open browser commands in the AI sidebar 
        $aiBrowserPattern = '(title:\{value:"(?:Toggle|Open|Close) Browser",original:"(?:Toggle|Open|Close) Browser"\}(?:(?!f1:).){0,150}?)f1:(!0|true)'
        $aiMatches = [regex]::Matches($content, $aiBrowserPattern)
        if ($aiMatches.Count -gt 0) {
            $content = [regex]::Replace($content, $aiBrowserPattern, '${1}f1:!1')
            $patchCount += $aiMatches.Count
            Log "  Patched f1 flag for Cursor sidebar browser toggle"
        }

        # 5.2 Forcefully hide the New Browser Tab command from the command palette
        $nbtPalettePattern = '(\{id:[a-zA-Z0-9_\.]+,title:Ht\(\d+,""\),category:Ls\.View,)f1:(!0|true)'
        $nbtMatches = [regex]::Matches($content, $nbtPalettePattern)
        if ($nbtMatches.Count -gt 0) {
            $content = [regex]::Replace($content, $nbtPalettePattern, '${1}f1:!1')
            $patchCount += $nbtMatches.Count
            Log "  Forcefully hid New Browser Tab from Command Palette"
        }

        # 5.3 Lobotomize the Agent Overview 'New Browser' command
        $agentBrowserPattern = '(\{id:[a-zA-Z0-9_\.]+,title:"New Browser",icon:"globe".{0,200}run:[a-zA-Z0-9_]+=>\{)'
        $abMatches = [regex]::Matches($content, $agentBrowserPattern)
        if ($abMatches.Count -gt 0) {
            $matchText = $abMatches[0].Value
            if (-not $matchText.Contains("Cursor browser completely lobotomized")) {
                # We replace both f1:!0 with f1:!1 AND inject the error into the run function
                $content = [regex]::Replace($content, $agentBrowserPattern, '${1} throw new Error("Cursor browser completely lobotomized"); ')
                $content = [regex]::Replace($content, '(\{id:[a-zA-Z0-9_\.]+,title:"New Browser",icon:"globe".{0,150}?)f1:(!0|true)', '${1}f1:!1')
                $patchCount += $abMatches.Count
                Log "  Neutered Agent Overview New Browser command"
            }
        }

        # 5.4 Neuter the lowest-level internal createBrowserTab function
        $createTabPattern = '(createBrowserTab\([a-zA-Z0-9_]+=\{\}\)\{)'
        $ctMatches = [regex]::Matches($content, $createTabPattern)
        if ($ctMatches.Count -gt 0) {
            if (-not $content.Contains('Error("Internal createBrowserTab lobotomized")')) {
                $content = [regex]::Replace($content, $createTabPattern, '${1} throw new Error("Internal createBrowserTab lobotomized"); ')
                $patchCount += $ctMatches.Count
                Log "  Neutered core createBrowserTab function"
            }
        }
        
        # Strip Cursor's explicit link context menu injection
        # Matches: new ca("openInCursorBrowser","Open in Cursor Browser",void 0,!0,()=>{P(),i.commandService.executeCommand("workbench.action.openBrowserEditor",{url:R})}),
        # Note: 'ca' might be 'la' or another minified name, so we use [a-zA-Z0-9_]+
        $cursorContextMenuPattern = 'new [a-zA-Z0-9_]+\("openInCursorBrowser","Open in Cursor Browser",void 0,!0,\(\)=>\{[^\}]+\.executeCommand\("workbench\.action\.openBrowserEditor",\{url:R\}\)\}\),'
        $cmMatches = [regex]::Matches($content, $cursorContextMenuPattern)
        if ($cmMatches.Count -gt 0) {
            $content = [regex]::Replace($content, $cursorContextMenuPattern, '')
            $patchCount += $cmMatches.Count
            Log "  Stripped Cursor link context menu injection"
        }
    }

    # 6. Neuter Built-in Simple Browser Extension
    $extPath = Join-Path (Split-Path $workbenchJs -Parent) "..\..\..\extensions\simple-browser\dist\extension.js"
    # For some installations, it might be in a different relative path
    if (-not (Test-Path $extPath)) {
        $extPath = Join-Path $editor.InstallBase "resources\app\extensions\simple-browser\dist\extension.js"
    }

    if (Test-Path $extPath) {
        $extContent = Get-Content $extPath -Raw
        $extPatchCount = 0

        # Universally match the show() methods in the simple browser extension
        $sbPattern = '(show\([^)]*\)\s*\{)'
        $sbMatches = [regex]::Matches($extContent, $sbPattern)
        if ($sbMatches.Count -gt 0) {
            if (-not $extContent.Contains('Error("Simple browser extension completely lobotomized")')) {
                $extContent = [regex]::Replace($extContent, $sbPattern, '${1} throw new Error("Simple browser extension completely lobotomized"); ')
                $extPatchCount += $sbMatches.Count
            }
        }

        if ($extPatchCount -gt 0) {
            $extBackup = "$backupDir\$($editor.Name -replace '[^\w]','_')_simple-browser-extension.js.$timestamp.bak"
            Copy-Item $extPath $extBackup
            [System.IO.File]::WriteAllText($extPath, $extContent, [System.Text.Encoding]::UTF8)
            Log "  Neutered simple browser extension ($extPatchCount patches)"
        }
    }

    
    if ($patchCount -gt 0) {
        [System.IO.File]::WriteAllText($workbenchJs, $content, [System.Text.Encoding]::UTF8)
        Log "Saved $patchCount dynamic patches to workbench JS."
    } else {
        Log "No patches were needed or found."
    }
    
    # 5. Keybindings.json universal overrides
    $kbPath = $editor.Keybindings
    if (-not (Test-Path (Split-Path $kbPath))) {
        New-Item -ItemType Directory -Path (Split-Path $kbPath) -Force | Out-Null
    }
    
    if (Test-Path $kbPath) {
        $kbBackup = "$backupDir\$($editor.Name -replace '[^\w]','_')_keybindings.json.$timestamp.bak"
        Copy-Item $kbPath $kbBackup
    }
    
    $browserCommands = @(
        "simpleBrowser.show",
        "simpleBrowser.api.open",
        "workbench.action.browser.openFromViewMenu",
        "workbench.action.url.openUrl",
        "workbench.action.newBrowserTab",
        "workbench.action.focusBrowserLocationBar",
        "cursor.openCursorWebsite",
        "workbench.action.reloadBrowserTab",
        "composer.toggleBrowserTab",
        "composer.openBrowserTab",
        "composer.closeBrowserTab",
        "workbench.action.openBrowserEditor"
    )
    
    $kbContent = "// Universal browser removal overrides`r`n["
    for ($i = 0; $i -lt $browserCommands.Count; $i++) {
        $comma = if ($i -lt $browserCommands.Count - 1) { "," } else { "" }
        $kbContent += "`r`n  { `"key`": `"`", `"command`": `"$($browserCommands[$i])`", `"when`": `"false`" }$comma"
    }
    $kbContent += "`r`n  { `"key`": `"ctrl+t`", `"command`": `"-workbench.action.newBrowserTab`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+t`", `"command`": `"cursor.ai.dummy`" }"
    $kbContent += "
]"
    
    Set-Content -Path $kbPath -Value $kbContent -Encoding UTF8
    Log "Updated keybindings"
}

Log ""
Log "=== Finished Universal Patching ==="
Log "Please restart all open instances of VS Code, Windsurf, and Cursor to apply the changes."
