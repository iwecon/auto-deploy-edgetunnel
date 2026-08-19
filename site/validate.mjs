import { readFile, access } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDirectory = dirname(fileURLToPath(import.meta.url));
const requiredFiles = [
  "index.html",
  "styles.css",
  "app.js",
  "favicon.svg",
  "robots.txt",
  "sitemap.xml",
  ".nojekyll",
  "fonts/SmileySans-Oblique.woff2",
  "fonts/LICENSE.txt",
];

await Promise.all(requiredFiles.map((file) => access(join(siteDirectory, file))));

const html = await readFile(join(siteDirectory, "index.html"), "utf8");
const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]));
const anchors = [...html.matchAll(/href="#([^"]+)"/g)].map((match) => match[1]);
const duplicateIDs = [...ids].filter(
  (id) => [...html.matchAll(new RegExp(`\\sid="${id}"`, "g"))].length > 1,
);

const missingAnchors = anchors.filter((anchor) => !ids.has(anchor));
const requiredText = [
  "把 EdgeTunnel 部署",
  "安全不是一句口号，是边界",
  "brew install --HEAD",
  "install.sh | sh",
];
const missingText = requiredText.filter((text) => !html.includes(text));

if (!html.includes('<html lang="zh-CN">')) {
  throw new Error("index.html 缺少 zh-CN 语言声明");
}
if (duplicateIDs.length > 0) {
  throw new Error(`重复的 id：${duplicateIDs.join(", ")}`);
}
if (missingAnchors.length > 0) {
  throw new Error(`无效的页内链接：${missingAnchors.join(", ")}`);
}
if (missingText.length > 0) {
  throw new Error(`缺少关键内容：${missingText.join(", ")}`);
}

console.log(`Validated ${requiredFiles.length} site files and ${anchors.length} internal links.`);
