import {cropFromDrag} from './utils.mjs';
const bridge = window.__TAURI__;
const selection = document.getElementById('selection');
let source, start, sending = false;
function error(e) { document.getElementById('error').textContent = String(e); }
function draw(end) {
  selection.hidden = false;
  selection.style.left = `${Math.min(start.x, end.x)}px`; selection.style.top = `${Math.min(start.y, end.y)}px`;
  selection.style.width = `${Math.abs(start.x-end.x)}px`; selection.style.height = `${Math.abs(start.y-end.y)}px`;
  try { const c = cropFromDrag(start, end, source.width, source.height, innerWidth, innerHeight); document.getElementById('size').textContent = `${c.width} × ${c.height}`; }
  catch { document.getElementById('size').textContent = '继续拖动'; }
}
async function finish(crop) {
  if (sending) return; sending = true;
  try { await bridge.core.invoke('finish_region', {crop}); }
  catch (e) { error(e); sending = false; }
}
window.addEventListener('pointerdown', e => {
  if (!source || sending || e.button !== 0) return;
  start = {x:e.clientX, y:e.clientY}; document.body.setPointerCapture(e.pointerId); draw(start);
});
window.addEventListener('pointermove', e => { if (start) draw({x:e.clientX, y:e.clientY}); });
window.addEventListener('pointerup', async e => {
  if (!start || sending) return;
  const first = start; start = null;
  try { await finish(cropFromDrag(first,{x:e.clientX,y:e.clientY},source.width,source.height,innerWidth,innerHeight)); }
  catch (e) { error(e); selection.hidden = true; }
});
window.addEventListener('pointercancel', () => { start = null; selection.hidden = true; });
window.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); finish(null); } });
if (bridge?.core) bridge.core.invoke('region_context').then(s => source = s).catch(error);
else error('这个窗口需要 Windows 版 Lens 启动，浏览器不能进行原生区域捕获。');
