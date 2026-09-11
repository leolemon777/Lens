import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = path => readFileSync(new URL(path, import.meta.url), "utf8");
const capability = JSON.parse(read("../src-tauri/capabilities/main.json"));
const permission = read("../src-tauri/permissions/product.toml");
const host = read("../src-tauri/src/lib.rs");
const commands = host.match(/generate_handler!\[([\s\S]*?)\]/)[1].split(",").map(s => s.trim()).filter(Boolean);
assert.ok(capability.permissions.includes("allow-lens-product"));
for (const command of commands) {
  assert.ok(permission.includes(`"${command}"`), `Loopback frontend cannot invoke ${command}`);
}
for (const window of ["main", "island", "overlay", "quick-access", "record-bar", "pin"]) {
  assert.ok(capability.windows.includes(window), `Missing capability for ${window}`);
}
assert.ok(capability.remote.urls.every(url => url.startsWith("http://127.0.0.1")));
// WebView2 creation from a synchronous UI-thread command can freeze the app.
for (const command of ["capture_display", "capture_window", "complete_region_selection", "start_display_recording", "start_window_recording", "stop_recording", "finish_scrolling", "pin_last", "capture_windows_composite", "open_quick_access", "open_record_bar_cmd"]) {
  assert.ok(host.includes(`#[tauri::command(async)]\nfn ${command}(`), `${command} must run off the UI thread`);
}
console.log(`Product capability covers ${commands.length} commands and all six windows; remote scope stays on loopback.`);
