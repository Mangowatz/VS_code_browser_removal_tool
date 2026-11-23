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
    },
    @{
        Name = "Antigravity IDE"
        InstallBase = "$env:LOCALAPPDATA\Programs\Antigravity IDE"
        Keybindings = "$env:APPDATA\Antigravity\User\keybindings.json"
    }
)

# The human-readable titles of all browser-related commands we want to hide
$titles = @(
    "Go Back", "Go Forward", "Reload", "Hard Reload", "Open in External Browser",
    "Focus URL Input", "Find in Page", "Toggle Developer Tools",
    "Clear Storage (Ephemeral)", "Clear Storage (Global)", "Clear Storage (Workspace)",
    "Clear Storage (Agent)",
    "Add Element to Chat", "Add Console Logs to Chat", "Open Integrated Browser",
    "Quick Open Browser Tab...", "Open URL", "Simple Browser: Show", "Open Browser",
    "New Integrated Browser", "New Tab", "Close All Browser Tabs",
    "Close All Browser Tabs in Group", "Toggle Favorite", "Show History",
    "Manage Permissions", "Add Screenshot to Chat", "Add Area Screenshot to Chat",
    "Add Full Page Screenshot to Chat", "Add Element Comment to Chat",
    "Open Settings", "Browser"
)

foreach ($editor in $editors) {
    Log ""
    Log "--- Processing $($editor.Name) ---"
    
    # 1. Find workbench JS
    if (-not (Test-Path $editor.InstallBase)) {
        Log "Install directory not found: $($editor.InstallBase)"
        continue
    }
    
    $targetFiles = @("workbench.desktop.main.js", "workbench.glass.main.js", "sessions.desktop.main.js")
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

    # Hide any titles we stripped to "" from the F1 menu (handles both localize calls and object syntax)
    $emptyTitleF1Pattern = '(title:\s*(?:[a-zA-Z0-9_\$]+\(\d+,\s*""\)|""|\{\s*value:\s*""[^}]*\}|\{\s*original:\s*""[^}]*\})(?:(?!title:).){0,150}?)f1\s*:\s*(?:!0|true)'
    $emptyTitleMatches = [regex]::Matches($content, $emptyTitleF1Pattern)
    if ($emptyTitleMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $emptyTitleF1Pattern, '${1}f1:!1')
        $patchCount += $emptyTitleMatches.Count
        Log "  Patched f1 flag for $($emptyTitleMatches.Count) stripped titles"
    }

    # Hide any disabled.* commands from the F1 menu
    $disabledIdF1Pattern = '(id:\s*"disabled\.[^"]+"(?:(?!id:).){0,200}?)f1\s*:\s*(?:!0|true)'
    $disabledMatches = [regex]::Matches($content, $disabledIdF1Pattern)
    if ($disabledMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $disabledIdF1Pattern, '${1}f1:!1')
        $patchCount += $disabledMatches.Count
        Log "  Patched f1 flag for $($disabledMatches.Count) disabled.* commands"
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
        if (-not $content.Contains('Error("Integrated browser removed")')) {
            $content = [regex]::Replace($content, $openIntegratedBrowserPattern, '${1} throw new Error("Integrated browser removed"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $patchCount++
            Log "  Neutered Open Integrated Browser command"
        }
    }

    # 3.3 Neuter NEW Quick Open Browser Tab Command
    $quickOpenBrowserPattern = '("Quick Open Browser Tab\.\.\.".*?run\([^)]*\)\s*\{)'
    $qobMatches = [regex]::Matches($content, $quickOpenBrowserPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($qobMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Quick browser removed")')) {
            $content = [regex]::Replace($content, $quickOpenBrowserPattern, '${1} throw new Error("Quick browser removed"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $patchCount++
            Log "  Neutered Quick Open Browser Tab command"
        }
    }

    # 3.4 Neuter NEW Native Browser Editor Resolver
    $browserResolverPattern = '(createEditorInput:\(\{resource:[a-zA-Z0-9_]+,options:[a-zA-Z0-9_]+\}\)=>\{)(let [a-zA-Z0-9_]+=[a-zA-Z0-9_\.]+\.parse[^}]*Invalid browser view resource)'
    $brMatches = [regex]::Matches($content, $browserResolverPattern)
    if ($brMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Integrated browser editor removed")')) {
            $content = [regex]::Replace($content, $browserResolverPattern, '${1} throw new Error("Integrated browser editor removed"); ${2}')
            $patchCount++
            Log "  Neutered Native Browser Editor Resolver"
        }
    }
    
    # 3.5 Neuter ALL VS Code Native Browser Commands (workbench.action.browser.*)
    # VS Code 1.90+ has a full browser namespace: prefix="workbench.action.browser" with command enum.
    # The command IDs are built dynamically via template literals from the prefix, so we neuter the
    # base prefix itself, which breaks ALL browser commands at once.
    $browserPrefixPattern = '=\s*"workbench\.action\.browser"'
    $prefixMatches = [regex]::Matches($content, $browserPrefixPattern)
    if ($prefixMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $browserPrefixPattern, '="disabled.workbench.action.browser"')
        $patchCount += $prefixMatches.Count
        Log "  Neutered browser command prefix ($($prefixMatches.Count) matches) - disables all workbench.action.browser.* commands"
    }

    # 3.6 Strip the "Browser" button from the Title Bar (Agents window right toolbar)
    # The action registers id: *.OpenOrList with menu: { id: *.TitleBar, ... }.
    # Even if hidden by default, VS Code's toolbar context menu exposes EVERY item
    # registered to *.TitleBar as a toggleable checkbox in the right-click menu!
    # Removing menu:{id:*.TitleBar...} completely removes "Browser" from that menu.
    $titleBarMenuPattern = 'menu:\{id:[a-zA-Z0-9_\$]+\.TitleBar,group:"navigation",order:10,when:[^}]+\}'
    $tbMatches = [regex]::Matches($content, $titleBarMenuPattern)
    if ($tbMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $titleBarMenuPattern, 'menu:[]')
        $patchCount += $tbMatches.Count
        Log "  Completely removed Browser from TitleBar menu / toolbar dropdown ($($tbMatches.Count) matches)"
    }

    # Also neuter *.OpenOrList run() so clicking it can never open anything
    $openOrListRunPattern = '(\.OpenOrList.+?\}\)\s*\}\s*async\s+run\([a-zA-Z0-9_]+\)\{)'
    $runMatches = [regex]::Matches($content, $openOrListRunPattern)
    if ($runMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Browser command removed")')) {
            $content = [regex]::Replace($content, $openOrListRunPattern, '${1} throw new Error("Browser command removed"); ')
            $patchCount += $runMatches.Count
            Log "  Neutered OpenOrList run implementation ($($runMatches.Count) matches)"
        }
    }

    # 3.7 Remove "New Integrated Browser" from the editor New Tab dropdown
    # It registers via class extending Zre/Zde with id: *.Open+".fromNewTabButton"
    $newTabButtonPattern = '(?:\$|G)\(class extends (?:Zre|Zde)\{constructor\(\)\{super\(\{id:[a-zA-Z0-9_\$]+\.Open\+"\.fromNewTabButton",title:[a-zA-Z0-9_\$]+\(\d+,"New Integrated Browser"\),icon:[a-zA-Z0-9_\$]+\.globe,order:4\}\)\}openTab\([a-zA-Z0-9_]+\)\{return [^}]+\}\}\);'
    $ntbMatches = [regex]::Matches($content, $newTabButtonPattern)
    if ($ntbMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $newTabButtonPattern, '/* New Integrated Browser tab removed */')
        $patchCount += $ntbMatches.Count
        Log "  Completely unregistered 'New Integrated Browser' from New Tab dropdown ($($ntbMatches.Count) matches)"
    }

    # Also neuter the openTab function in any browser tab class if still present
    $openTabPattern = '(openTab\([a-zA-Z0-9_]+\)\{return [a-zA-Z0-9_]+\.get\([a-zA-Z0-9_]+\)\.executeCommand\([a-zA-Z0-9_\$]+\.Open\)\})'
    $otMatches = [regex]::Matches($content, $openTabPattern)
    if ($otMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Integrated browser tab removed")')) {
            $content = [regex]::Replace($content, $openTabPattern, 'openTab(){throw new Error("Integrated browser tab removed");}')
            $patchCount += $otMatches.Count
            Log "  Neutered browser new tab openTab function ($($otMatches.Count) matches)"
        }
    }

    # Strip the literal title "New Integrated Browser"
    $newIntBrowserTitle = '"New Integrated Browser"'
    if ($content.Contains($newIntBrowserTitle)) {
        $content = $content.Replace($newIntBrowserTitle, '""')
        $patchCount++
        Log "  Stripped 'New Integrated Browser' title"
    }

    # 3.8 Neuter the localhost link opener that auto-opens browser for local URLs
    $localhostOpenerStr = 'static{this.OPENER_ID="workbench.integratedBrowser"}'
    if ($content.Contains($localhostOpenerStr)) {
        $content = $content.Replace('"workbench.integratedBrowser"', '"disabled.workbench.integratedBrowser"')
        $patchCount++
        Log "  Neutered localhost link opener"
    }

    # 3.9 Hide Browser from View menu
    $viewMenuBrowserPattern = '[a-zA-Z0-9_\$]+\.appendMenuItem\([a-zA-Z0-9_\$]+\.MenubarViewMenu,\{group:"4_auxbar",command:\{id:[a-zA-Z0-9_\$]+\.OpenOrList,title:d\(\d+,null\)\},order:2\}\);'
    $vmbMatches = [regex]::Matches($content, $viewMenuBrowserPattern)
    if ($vmbMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $viewMenuBrowserPattern, '/* Browser MenubarViewMenu item removed */')
        $patchCount += $vmbMatches.Count
        Log "  Removed Browser from MenubarViewMenu ($($vmbMatches.Count) matches)"
    }

    # 3.10 Neuter the Browser Editor View Component (Js.createEditor)
    # If anything ever tries to instantiate the browser editor pane, break it immediately
    $jsCreateEditorPattern = '(createEditor\([a-zA-Z0-9_]+\)\{let [a-zA-Z0-9_]+=this\._register\(this\.contextKeyService\.createScoped\([a-zA-Z0-9_]+\)\);)'
    $jsMatches = [regex]::Matches($content, $jsCreateEditorPattern)
    if ($jsMatches.Count -gt 0) {
        if (-not $content.Contains('Error("Browser editor disabled")')) {
            $content = [regex]::Replace($content, $jsCreateEditorPattern, 'createEditor(e){ throw new Error("Browser editor disabled"); let t=this._register(this.contextKeyService.createScoped(e));')
            $patchCount += $jsMatches.Count
            Log "  Neutered Browser Editor Component (Js.createEditor) ($($jsMatches.Count) matches)"
        }
    }

    # 3.11 Disable the browser editor type registration for *.html files
    # First, repair any syntax errors from previous runs where s?.false was injected
    if ($content.Contains('(s?.false&&')) {
        $content = $content.Replace('(s?.false&&', '(false)&&')
        $patchCount++
        Log "  Repaired (s?.false syntax error in $($fileObj.Name)"
    } elseif ($content.Contains('s?.false')) {
        $content = $content.Replace('s?.false', 'false')
        $patchCount++
        Log "  Repaired s?.false syntax error in $($fileObj.Name)"
    }

    # Neutering *.html default editor assignment to browser editor
    $htmlBrowserPattern = '\["\*\.html"\]\s*=\s*"workbench\.editor\.browser"'
    $htmlMatches = [regex]::Matches($content, $htmlBrowserPattern)
    if ($htmlMatches.Count -gt 0) {
        $content = [regex]::Replace($content, $htmlBrowserPattern, '["*.html"]="disabled.workbench.editor.browser"')
        $patchCount += $htmlMatches.Count
        Log "  Disabled browser editor registration for *.html files ($($htmlMatches.Count) matches)"
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
            "workbench.action.newBrowser",
            "cursor.newBrowser",
            "cursor.newBrowserTab",
            "composer.toggleBrowserTab", 
            "composer.openBrowserTab",
            "composer.newBrowser",
            "workbench.action.focusOrOpenBrowserEditor",
            "workbench.action.reloadBrowserTab",
            "workbench.action.focusBrowserLocationBar",
            "glass.openBrowserTab",
            "openInCursorBrowser",
            "action-open-browser",
            "simpleBrowser.show"
        )
        
        # Dynamically discover any other command IDs by their exact UI titles
        $discoverTitles = @("New Browser Tab", "New Browser", "Open Browser")
        foreach ($dt in $discoverTitles) {
            # Check title after id
            $findPattern = 'id:\s*"([a-zA-Z0-9_\.-]+)"(?:(?!id:).){0,150}?title:\s*(?:[a-zA-Z0-9_\$]+\(\d+,\s*"' + $dt + '"\)|(?:\{[^}]*value:\s*"' + $dt + '"|"' + $dt + '"))'
            $matches = [regex]::Matches($content, $findPattern)
            foreach ($match in $matches) {
                $foundId = $match.Groups[1].Value
                if ($cursorBrowserCmds -notcontains $foundId) {
                    $cursorBrowserCmds += $foundId
                    Log "  Dynamically discovered browser command ID: $foundId for title '$dt'"
                }
            }
            
            # Check id after title
            $findPatternReverse = 'title:\s*(?:[a-zA-Z0-9_\$]+\(\d+,\s*"' + $dt + '"\)|(?:\{[^}]*value:\s*"' + $dt + '"|"' + $dt + '"))(?:(?!title:).){0,150}?id:\s*"([a-zA-Z0-9_\.-]+)"'
            $matchesRev = [regex]::Matches($content, $findPatternReverse)
            foreach ($match in $matchesRev) {
                $foundId = $match.Groups[1].Value
                if ($cursorBrowserCmds -notcontains $foundId) {
                    $cursorBrowserCmds += $foundId
                    Log "  Dynamically discovered browser command ID: $foundId for title '$dt'"
                }
            }
        }
        
        foreach ($cmd in $cursorBrowserCmds) {
            # Break legacy Class.ID assignments (which happen after the class definition)
            $idAssignPattern = '\.ID="(?:disabled\.)?' + $cmd + '"'
            $matchesId = [regex]::Matches($content, $idAssignPattern)
            if ($matchesId.Count -gt 0) {
                $content = [regex]::Replace($content, $idAssignPattern, '.ID="broken_' + $cmd + '"')
                $patchCount++
                Log "  Neutered Cursor command (Class.ID breaking): $cmd"
            }

            # Legacy class-based patching (for older versions)
            $pattern = '(class [a-zA-Z0-9_\$]+ extends [a-zA-Z0-9_\$]+\s*\{\s*static\s*\{\s*this\.ID="(?:disabled\.)?' + $cmd + '"\s*\}.*?run\([^)]*\)\s*\{)'
            $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($matches.Count -gt 0) {
                $matchText = $matches[0].Value
                if (-not $matchText.Contains("Cursor browser removed")) {
                    $content = [regex]::Replace($content, $pattern, '${1} throw new Error("Cursor browser removed"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $patchCount++
                    Log "  Neutered Cursor command (legacy): $cmd"
                }
            }

            # Object-based patching (registerAction2({ id: "...", run(e,t) { ... } }))
            $objPattern = '(id:\s*"(?:disabled\.)?' + $cmd + '"(?:(?!id:).){0,250}?(?:async\s+)?run\s*\([^)]*\)\s*\{)'
            $objMatches = [regex]::Matches($content, $objPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($objMatches.Count -gt 0) {
                $matchText = $objMatches[0].Value
                if (-not $matchText.Contains("Browser removed")) {
                    $content = [regex]::Replace($content, $objPattern, '${1} throw new Error("Browser removed"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $patchCount++
                    Log "  Neutered Cursor command (object): $cmd"
                }
            }

            # Arrow-function patching (registerAction2({ id: "...", run: async (e) => { ... } }))
            $arrowPattern = '(id:\s*"(?:disabled\.)?' + $cmd + '"(?:(?!id:).){0,250}?run\s*:\s*(?:async\s*)?(?:[a-zA-Z0-9_]+|\([^)]*\))\s*=>\s*\{)'
            $arrowMatches = [regex]::Matches($content, $arrowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($arrowMatches.Count -gt 0) {
                $matchText = $arrowMatches[0].Value
                if (-not $matchText.Contains("Browser removed")) {
                    $content = [regex]::Replace($content, $arrowPattern, '${1} throw new Error("Browser removed"); ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $patchCount++
                    Log "  Neutered Cursor command (arrow): $cmd"
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
        $cursorTitles = @("New Browser Tab", "New Browser", "Open Browser", "Focus Browser Location Bar", "Open cursor.com in Browser", "Reload Browser Tab")
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
            if (-not $matchText.Contains("Cursor browser removed")) {
                # We replace both f1:!0 with f1:!1 AND inject the error into the run function
                $content = [regex]::Replace($content, $agentBrowserPattern, '${1} throw new Error("Cursor browser removed"); ')
                $content = [regex]::Replace($content, '(\{id:[a-zA-Z0-9_\.]+,title:"New Browser",icon:"globe".{0,150}?)f1:(!0|true)', '${1}f1:!1')
                $patchCount += $abMatches.Count
                Log "  Neutered Agent Overview New Browser command"
            }
        }

        # 5.4 Neuter the lowest-level internal createBrowserTab function
        $createTabPattern = '(createBrowserTab\([a-zA-Z0-9_]+=\{\}\)\{)'
        $ctMatches = [regex]::Matches($content, $createTabPattern)
        if ($ctMatches.Count -gt 0) {
            if (-not $content.Contains('Error("Internal createBrowserTab removed")')) {
                $content = [regex]::Replace($content, $createTabPattern, '${1} throw new Error("Internal createBrowserTab removed"); ')
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
            "New Browser Tab", "New Browser", "Open Browser", "Focus Browser Location Bar", "Open cursor.com in Browser", 
            "Reload Browser Tab", "Focus or Open Browser", "Simple Browser: Show", 
            "Open Port in Browser", "New Integrated Browser", "Close All Browser Tabs",
            "Close All Browser Tabs in Group", "New Tab", "Browser"
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
    
    # 7.5 Patch editor settings.json to disable the integrated browser via config
    if ($editor.Name -eq "VS Code") {
        $settingsPath = "$env:APPDATA\Code\User\settings.json"
    } elseif ($editor.Name -match "Windsurf") {
        $settingsPath = "$env:APPDATA\Windsurf\User\settings.json"
    } elseif ($editor.Name -match "Cursor") {
        $settingsPath = "$env:APPDATA\Cursor\User\settings.json"
    } elseif ($editor.Name -match "Antigravity") {
        $settingsPath = "$env:APPDATA\Antigravity\User\settings.json"
    } else {
        $settingsPath = $null
    }
    
    if ($settingsPath -and (Test-Path (Split-Path $settingsPath))) {
        $browserSettings = @{
            "workbench.browser.showInTitleBar"    = $false
            "workbench.browser.enableChatTools"   = $false
            "workbench.browser.openLocalhostLinks" = $false
            "workbench.browser.enableRemoteProxy" = $false
        }
        
        if (Test-Path $settingsPath) {
            $settingsBackup = "$backupDir\$($editor.Name -replace '[^\w]','_')_settings.json.$timestamp.bak"
            Copy-Item $settingsPath $settingsBackup
            
            $settingsContent = [System.IO.File]::ReadAllText($settingsPath)
            # Remove trailing comments-only content and parse
            try {
                # Strip single-line comments for parsing (VS Code settings allow // comments)
                $cleanJson = $settingsContent -replace '//.*$', '' -replace ',\s*}', '}' -replace ',\s*]', ']'
                $settingsObj = $cleanJson | ConvertFrom-Json
            } catch {
                # If parsing fails, start fresh with a wrapper
                $settingsObj = [PSCustomObject]@{}
            }
        } else {
            $settingsObj = [PSCustomObject]@{}
        }
        
        $settingsChanged = $false
        foreach ($key in $browserSettings.Keys) {
            $val = $browserSettings[$key]
            if (-not ($settingsObj.PSObject.Properties.Name -contains $key) -or $settingsObj.$key -ne $val) {
                $settingsObj | Add-Member -MemberType NoteProperty -Name $key -Value $val -Force
                $settingsChanged = $true
            }
        }
        
        if ($settingsChanged) {
            $newSettingsJson = $settingsObj | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($settingsPath, $newSettingsJson, $utf8NoBom)
            Log "  Patched settings.json with browser disable flags"
        }
    }

    # 8. Keybindings.json universal overrides
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
        "glass.openBrowserTab",
        "workbench.action.browser.open",
        "workbench.action.browser.open.fromNewTabButton",
        "workbench.action.browser.openFile",
        "workbench.action.browser.newTab",
        "workbench.action.browser.quickOpen",
        "workbench.action.browser.openOrList",
        "workbench.action.browser.closeAll",
        "workbench.action.browser.closeAllInGroup",
        "workbench.action.browser.goBack",
        "workbench.action.browser.goForward",
        "workbench.action.browser.reload",
        "workbench.action.browser.hardReload",
        "workbench.action.browser.focusUrlInput",
        "workbench.action.browser.openExternal",
        "workbench.action.browser.toggleDevTools",
        "workbench.action.browser.addElementToChat",
        "workbench.action.browser.addConsoleLogsToChat",
        "workbench.action.browser.addScreenshotToChat",
        "workbench.action.browser.addAreaScreenshotToChat",
        "workbench.action.browser.addFullPageScreenshotToChat",
        "workbench.action.browser.showFind"
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

    # 9. Invalidate V8 bytecode cache for this editor
    $cacheBases = @(
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\Code Cache",
        "$env:APPDATA\Antigravity\CachedData",
        "$env:APPDATA\Antigravity\Code Cache",
        "$env:APPDATA\Cursor\CachedData",
        "$env:APPDATA\Cursor\Code Cache",
        "$env:APPDATA\Windsurf\CachedData",
        "$env:APPDATA\Windsurf\Code Cache"
    )
    foreach ($cb in $cacheBases) {
        if (Test-Path $cb) {
            Remove-Item -Path "$cb\*" -Recurse -Force -ErrorAction SilentlyContinue
            Log "  Cleared bytecode cache: $cb"
        }
    }
}

Log ""
Log "=== Finished Universal Patching ==="
Log "Please restart all open instances of VS Code, Windsurf, Antigravity IDE, and Cursor to apply the changes."
