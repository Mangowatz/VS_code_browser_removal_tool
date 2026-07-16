const fs = require('fs');
const path = require('path');
const localAppData = process.env.LOCALAPPDATA;
const cursorPaths = [
    path.join(localAppData, 'Programs', 'Cursor', 'resources', 'app', 'out', 'workbench.desktop.main.js'),
    'C:\\Program Files\\Cursor\\resources\\app\\out\\workbench.desktop.main.js'
];
let targetPath = null;
for (const p of cursorPaths) {
    if (fs.existsSync(p)) {
        targetPath = p;
        break;
    }
}
if (!targetPath) {
    console.log("Not found");
    process.exit(1);
}
const content = fs.readFileSync(targetPath, 'utf8');
const regex = /.{0,100}"Open Browser".{0,100}/g;
let match;
while ((match = regex.exec(content)) !== null) {
    console.log(match[0]);
}
