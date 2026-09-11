import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const desktopRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const css = readFileSync(join(desktopRoot, "styles/probe.css"), "utf8");
const html = readFileSync(join(desktopRoot, "index.html"), "utf8");
const main = readFileSync(join(desktopRoot, "src/main.tsx"), "utf8");

function blockAfter(source, header) {
  const start = source.indexOf(header);
  if (start < 0) {
    throw new Error(`missing rule header: ${header}`);
  }
  const open = source.indexOf("{", start);
  const close = source.indexOf("}", open);
  if (open < 0 || close < 0) {
    throw new Error(`unclosed rule: ${header}`);
  }
  return source.slice(open + 1, close);
}

const overlayChrome = blockAfter(
  css,
  "html.overlay-window,\nhtml.overlay-window body,\nhtml.overlay-window #root",
);
if (!/background:\s*transparent/.test(overlayChrome)) {
  throw new Error("overlay html/body/#root must set background: transparent");
}

const dashboardBody = blockAfter(css, "\nbody {");
if (/html\.overlay-window/.test(dashboardBody)) {
  throw new Error("dashboard body fill must not be the overlay-window rule");
}

const surface = blockAfter(css, ".selection-surface {");
if (!/background:\s*rgba\(/.test(surface)) {
  throw new Error("selection-surface must keep a dim overlay fill");
}

if (!html.includes('classList.add("overlay-window")')) {
  throw new Error("index.html must tag overlay windows before paint");
}
if (!main.includes('classList.add("overlay-window")')) {
  throw new Error("main.tsx must tag overlay windows");
}

console.log("overlay html/body/#root background is transparent");
console.log("dashboard body is not the overlay-window rule");
console.log("selection-surface keeps a dim overlay fill");
console.log("overlay-window class is applied from ?window=overlay");
