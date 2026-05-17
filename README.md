# VS Code Browser Lobotomy

A highly aggressive, dynamic PowerShell script designed to completely and permanently eradicate all integrated browser functionality from VS Code, Cursor, and Windsurf. 

If you want to force all web traffic (including previews, documentation links, simple browsers, and AI-triggered browser tabs) to open in your system's external browser, this script is the ultimate nuclear option.

## Why?
Modern code editors like VS Code, Cursor, and Windsurf are increasingly embedding native "Simple Browsers" or webviews to render previews, documentation, or let AI agents browse the web within the IDE. 
Standard settings often fail to disable these features fully. This script exists to violently excise these features at the source code level.

## Supported Environments
- VS Code (Standard)
- Cursor (Program Files & AppData installations)
- Windsurf

## Features
The script achieves total browser eradication through a multi-layered defense strategy:

1. **Dynamic Minified Source Patching**: It parses the minified `workbench.desktop.main.js` and injects JavaScript exceptions directly into the execution paths of core browser commands and APIs. Because it uses regex pattern matching, the script survives minor IDE updates where variable names might change.
2. **Command Palette Cloaking**: It strips the internal `f1:true` flag from all browser-related UI commands, forcefully hiding them from the Command Palette drop-down so you (and AI agents) can't even see them.
3. **Core Editor Resolver Annihilation**: It injects an immediate `throw new Error()` into the lowest-level internal constructor (`createBrowserTab`), meaning even if an AI agent bypasses the UI and attempts to spawn a tab programmatically, it instantly crashes in the background.
4. **Simple Browser Extension Neuter**: It locates the built-in VS Code `simple-browser` extension and lobotomizes its rendering `show()` method.
5. **AI Specific Defenses**:
   - Destroys Cursor Composer's hidden AI browser commands (`workbench.action.openBrowserEditor`, `composer.openBrowserTab`, etc.).
   - Disables the native `open_browser_page` tool used by Copilot Chat.
   - Diverts Windsurf Cascade preview payloads from `in-ide` to your native system browser.
6. **Keybinding Nullification**: It writes an aggressive override block to your `keybindings.json`, mapping `Ctrl+T`, `Ctrl+Shift+B` (simple browser), and other shortcuts to dead-end dummy actions.

## Usage

**Warning:** This script directly modifies the internal source files of your code editors. It automatically creates timestamped backups of any file it modifies in `C:\Users\YourUser\vscode-simple-browser-backup\`. 

1. Ensure all instances of VS Code, Cursor, and Windsurf are completely closed.
2. Open **PowerShell** as **Administrator**.
3. Run the script:
   ```powershell
   .\disable-browser-dynamic.ps1
   ```
4. Review the log output in the console to ensure the dynamic patches were applied successfully.
5. Open your IDE. Integrated browsers are now dead.

## Maintenance
Because this script modifies the internal IDE files, **every time your IDE installs an update, the files will be overwritten**. You must re-run this script after every IDE update to restore the lobotomy.

## Backups and Logs
Every time the script runs, it generates a comprehensive log file and `.bak` backups of the unpatched JavaScript files in:
`%USERPROFILE%\vscode-simple-browser-backup\`
