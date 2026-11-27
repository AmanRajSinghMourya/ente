import fs from "node:fs";
import path from "node:path";

const appDir = path.join(import.meta.dirname, "../apps/auth");
const extensionDir = path.join(appDir, "out");

fs.renameSync(
    path.join(extensionDir, "_next"),
    path.join(extensionDir, "next"),
);
fs.rmSync(path.join(extensionDir, "_headers"), { force: true });
fs.rmSync(path.join(extensionDir, "_redirects"), { force: true });

for (const entry of fs.readdirSync(extensionDir, {
    recursive: true,
    withFileTypes: true,
})) {
    if (!entry.isFile() || !/\.(html|js|css)$/.test(entry.name)) continue;
    const file = path.join(entry.parentPath, entry.name);
    const text = fs.readFileSync(file, "utf8");
    if (text.includes("/_next/"))
        fs.writeFileSync(file, text.replaceAll("/_next/", "/next/"));
}

fs.cpSync(path.join(appDir, "extension"), extensionDir, { recursive: true });
