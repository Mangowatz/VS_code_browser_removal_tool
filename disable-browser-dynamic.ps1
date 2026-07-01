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

# Define a UTF8 encoding without BOM. Writing a BOM causes Node.js JSON parsers to crash, breaking the editor.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

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
    
    $targetFiles = @("workbench.desktop.main.js", "workbench.glass.main.js")
    $allWorkbenchFiles = @()
    foreach ($tf in $targetFiles) {
        $foundFiles = Get-ChildItem $editor.InstallBase -Recurse -Filter $tf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\_\\' }
        if ($foundFiles) { $allWorkbenchFiles += $foundFiles }
    }
    
    if ($allWorkbenchFiles.Count -eq 0) {
        Log "Could not find any workbench JS files in $($editor.InstallBase)"
        continue
    }
    
    foreach ($fileObj in $allWorkbenchFiles) {
        $workbenchJs = $fileObj.FullName
        Log "Found workbench JS: $workbenchJs"
        
        # Backup
        $backupFile = "$backupDir\$($editor.Name -replace '[^\w]','_')_$($fileObj.Name).$timestamp.bak"
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

    # Hide any titles we stripped to "" from the F1 menu
    $emptyTitleF1Pattern = '(title:[a-zA-Z0-9_\$]+\(\d+,""\)[^}]*?f1:)(?:!0|true)'
    $emptyTitleMatches = [regex]::Matches($content, $emptyTitleF1Pattern)
    if ($emptyTitleMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $emptyTitleF1Pattern, '${1}!1')
        $patchCount += $emptyTitleMatches.Count
        Log "  Patched f1 flag for $($emptyTitleMatches.Count) stripped titles"
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
    
    # 5. Cursor AI Browser Overrides (Glass Palette removal)
    if ($editor.Name -match "Cursor") {
        # 5.1 Neuter Cursor explicitly named AI Browser Commands
        $cursorBrowserCmds = @(
            "workbench.action.openBrowserEditor", 
            "workbench.action.newBrowserTab", 
            "composer.toggleBrowserTab", 
            "composer.openBrowserTab",
            "workbench.action.focusOrOpenBrowserEditor",
            "workbench.action.reloadBrowserTab",
            "workbench.action.focusBrowserLocationBar",
            "glass.openBrowserTab"
        )
        foreach ($cmd in $cursorBrowserCmds) {
            # Legacy class-based patching
            $pattern = '(class [a-zA-Z0-9_\$]+ extends [a-zA-Z0-9_\$]+\s*\{\s*static\s*\{\s*this\.ID="' + $cmd + '"\s*\}.*?run\([^)]*\)\s*\{)'
            $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($matches.Count -gt 0) {
                $matchText = $matches[0].Value
                if (-not $matchText.Contains("Cursor browser completely neutralized")) {
                    $content = [regex]::Replace($content, $pattern, '${1} throw new Error("Cursor browser completely neutralized"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $patchCount++
                    Log "  Neutered Cursor command (legacy): $cmd"
                }
            }

            # New universal string-level neutering (replaces registrations and calls alike)
            $searchString = '"' + $cmd + '"'
            if ($content.Contains($searchString)) {
                $content = $content.Replace($searchString, '"disabled.' + $cmd + '"')
                $patchCount++
                Log "  Universally neutered command literal: $cmd"
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

        # 5.3 neuter the Agent Overview 'New Browser' command
        $agentBrowserPattern = '(\{id:[a-zA-Z0-9_\.]+,title:"New Browser",icon:"globe".{0,200}run:[a-zA-Z0-9_]+=>\{)'
        $abMatches = [regex]::Matches($content, $agentBrowserPattern)
        if ($abMatches.Count -gt 0) {
            $matchText = $abMatches[0].Value
            if (-not $matchText.Contains("Cursor browser completely neutralized")) {
                # We replace both f1:!0 with f1:!1 AND inject the error into the run function
                $content = [regex]::Replace($content, $agentBrowserPattern, '${1} throw new Error("Cursor browser completely neutralized"); ')
                $content = [regex]::Replace($content, '(\{id:[a-zA-Z0-9_\.]+,title:"New Browser",icon:"globe".{0,150}?)f1:(!0|true)', '${1}f1:!1')
                $patchCount += $abMatches.Count
                Log "  Neutered Agent Overview New Browser command"
            }
        }

        # 5.4 Neuter the lowest-level internal createBrowserTab function
        $createTabPattern = '(createBrowserTab\([a-zA-Z0-9_]+=\{\}\)\{)'
        $ctMatches = [regex]::Matches($content, $createTabPattern)
        if ($ctMatches.Count -gt 0) {
            if (-not $content.Contains('Error("Internal createBrowserTab neutralized")')) {
                $content = [regex]::Replace($content, $createTabPattern, '${1} throw new Error("Internal createBrowserTab neutralized"); ')
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

    # 6. Neuter simple browser extension (Rename folder)
    $extDir = Join-Path $editor.InstallBase "resources\app\extensions\simple-browser"
    $extDisabledDir = Join-Path $editor.InstallBase "resources\app\extensions\simple-browser.disabled"
    if (Test-Path $extDir) {
        Rename-Item -Path $extDir -NewName "simple-browser.disabled" -Force
        Log "  Disabled simple browser extension entirely"
    }

    
        if ($patchCount -gt 0) {
            [System.IO.File]::WriteAllText($workbenchJs, $content, $utf8NoBom)
            Log "Saved $patchCount dynamic patches to workbench JS: $($fileObj.Name)."
        } else {
            Log "No patches were needed or found for $($fileObj.Name)."
        }
    } # End of $allWorkbenchFiles loop

    # 7. Strip UI strings from nls.messages.json (Command Palette Localizations)
    $nlsPath = Join-Path $editor.InstallBase "resources\app\out\nls.messages.json"
    if (Test-Path $nlsPath) {
        $nlsContent = Get-Content $nlsPath -Raw
        $nlsPatchCount = 0
        $nlsTitles = @(
            "New Browser Tab", "Focus Browser Location Bar", "Open cursor.com in Browser", 
            "Reload Browser Tab", "Focus or Open Browser", "Simple Browser: Show", 
            "Open Port in Browser"
        )
        foreach ($nt in $nlsTitles) {
            $searchString = '"' + $nt + '"'
            if ($nlsContent.Contains($searchString)) {
                $nlsContent = $nlsContent.Replace($searchString, '""')
                $nlsPatchCount++
            }
        }
        if ($nlsPatchCount -gt 0) {
            $nlsBackup = "$backupDir\$($editor.Name -replace '[^\w]','_')_nls.messages.json.$timestamp.bak"
            Copy-Item $nlsPath $nlsBackup
            [System.IO.File]::WriteAllText($nlsPath, $nlsContent, $utf8NoBom)
            Log "  Stripped $nlsPatchCount localized titles from nls.messages.json"
        }
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
        "workbench.action.openBrowserEditor",
        "workbench.action.focusOrOpenBrowserEditor",
        "glass.openBrowserTab"
    )
    
    $kbContent = "// Universal browser removal overrides`r`n["
    for ($i = 0; $i -lt $browserCommands.Count; $i++) {
        $comma = if ($i -lt $browserCommands.Count - 1) { "," } else { "" }
        $kbContent += "`r`n  { `"key`": `"`", `"command`": `"$($browserCommands[$i])`", `"when`": `"false`" }$comma"
    }
    $kbContent += ","
    $kbContent += "`r`n  { `"key`": `"ctrl+t`", `"command`": `"-workbench.action.newBrowserTab`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+t`", `"command`": `"cursor.ai.dummy`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+shift+b`", `"command`": `"-glass.openBrowserTab`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+shift+b`", `"command`": `"-workbench.action.focusOrOpenBrowserEditor`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+shift+b`", `"command`": `"-workbench.action.openBrowserEditor`" },"
    $kbContent += "`r`n  { `"key`": `"ctrl+shift+b`", `"command`": `"workbench.action.tasks.build`" }"
    $kbContent += "
]"
    
    [System.IO.File]::WriteAllText($kbPath, $kbContent, $utf8NoBom)
    Log "Updated keybindings"
}

Log ""
Log "=== Finished Universal Patching ==="
Log "Please restart all open instances of VS Code, Windsurf, and Cursor to apply the changes."
