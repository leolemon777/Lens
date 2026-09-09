import { formatDuration, sourceCaption, controlsFor, filterProjects, phaseLabels } from './utils.mjs';
const $ = id => document.getElementById(id);
const bridge = window.__TAURI__;
const native = Boolean(bridge?.core?.invoke);
const state = { info:null, sources:[], sourceId:'', mode:'display', crop:null, fps:30, busy:false, phase:'idle', projects:[], page:'capture', polling:false };
let toastTimer;
function toast(message, error = false) {
  const box = $('toast'); box.textContent = String(message); box.classList.toggle('error', error); box.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => box.hidden = true, error ? 11000 : 5000);
}
async function invoke(command, args = {}) {
  if (!native) throw new Error('这是界面预览。真实录屏需要在 Windows 上构建并启动 Lens.exe。');
  return bridge.core.invoke(command, args);
}
function selectedSource() { return state.sources.find(s => s.id === state.sourceId); }
function options() {
  return { sourceId:state.sourceId, fps:state.fps, title:$('record-title').value.trim(),
    systemAudio:$('system-audio').checked, microphone:$('microphone').checked, cursor:$('cursor').checked,
    crop:state.mode === 'region' ? state.crop : null };
}
function applyControls() {
  const hasSource = native && !!selectedSource() && (state.mode !== 'region' || !!state.crop);
  const c = controlsFor(state.phase, state.busy, hasSource, !!state.info?.ffmpegAvailable);
  for (const e of document.querySelectorAll('[data-mode],[data-fps],#source,#record-title,#cursor,#refresh-sources,#pick-region')) e.disabled = !c.configure;
  for (const id of ['system-audio','microphone']) $(id).disabled = !c.configure || !state.info?.ffmpegAvailable;
  $('record').disabled = !c.record; $('record').hidden = c.active;
  $('record-actions').hidden = !c.active;
  $('pause').disabled = !c.pause; $('pause').textContent = state.phase === 'paused' ? '▶ 继续' : 'Ⅱ 暂停';
  $('stop').disabled = !c.stop; $('screenshot').disabled = !c.screenshot;
  $('refresh-library').disabled = state.busy;
}
function updateSourceDetails() {
  const s = selectedSource();
  $('source-caption').textContent = sourceCaption(s, state.mode === 'region' ? state.crop : null);
  $('source-details').textContent = !s ? '—' : state.crop && state.mode === 'region' ? `${state.crop.width} × ${state.crop.height} · X ${state.crop.x} / Y ${state.crop.y}` : `${s.width} × ${s.height} · ${s.kind === 'window' ? '窗口画面' : '显示器画面'}`;
  $('crop-actions').hidden = state.mode !== 'region';
  $('pick-region').textContent = state.crop ? '重新框选 ↗' : '框选区域 ↗';
  applyControls();
}
function renderSourceSelect() {
  const kind = state.mode === 'window' ? 'window' : 'display';
  const sources = state.sources.filter(s => s.kind === kind);
  if (!sources.some(s => s.id === state.sourceId)) { state.sourceId = sources[0]?.id ?? ''; state.crop = null; }
  $('source').replaceChildren();
  if (!sources.length) { const o = new Option(native ? '没有可用来源，请刷新' : '需要 Windows 原生引擎', ''); $('source').add(o); }
  for (const s of sources) $('source').add(new Option(`${s.label} · ${s.width} × ${s.height}`, s.id));
  $('source').value = state.sourceId; updateSourceDetails();
}
async function refreshSources() { state.sources = await invoke('list_sources'); renderSourceSelect(); }
async function refreshLibrary() {
  state.projects = await invoke('list_projects'); $('library-count').textContent = state.projects.length; renderLibrary();
}
function assetUrl(path) { return bridge.core.convertFileSrc(path); }
function renderLibrary() {
  const visible = filterProjects(state.projects, $('search').value); const grid = $('project-grid'); grid.replaceChildren();
  $('empty-library').hidden = visible.length > 0;
  $('empty-library').querySelector('h2').textContent = state.projects.length ? '没有匹配的项目' : '你的第一条记录，从这里开始。';
  for (const p of visible) {
    const article = document.createElement('article'); article.className = 'project-card';
    const thumbnail = document.createElement('button'); thumbnail.className = 'project-thumb'; thumbnail.setAttribute('aria-label', `预览 ${p.manifest.title}`);
    thumbnail.disabled = !p.preview;
    if (p.thumbnail) { const img = document.createElement('img'); img.src = assetUrl(p.thumbnail); img.alt = ''; img.loading = 'lazy'; thumbnail.append(img); } else thumbnail.textContent = p.manifest.kind === 'recording' ? '▷' : '▧';
    if (p.manifest.kind === 'recording') { const duration = document.createElement('span'); duration.className = 'project-duration'; duration.textContent = formatDuration(p.manifest.durationSeconds); thumbnail.append(duration); }
    thumbnail.addEventListener('click', () => openViewer(p));
    const copy = document.createElement('div'); copy.className = 'project-copy';
    const title = document.createElement('h3'); title.textContent = p.manifest.title; title.title = p.manifest.title;
    const meta = document.createElement('p'); const d = new Date(p.manifest.createdAt);
    meta.textContent = `${Number.isNaN(d.getTime()) ? '未知时间' : d.toLocaleString('zh-CN', {month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit'})} · ${p.manifest.dimensions ? p.manifest.dimensions.width + ' × ' + p.manifest.dimensions.height : '尺寸未知'}`;
    copy.append(title, meta);
    if (p.manifest.state !== 'ready') { const warning = document.createElement('span'); warning.className = 'project-state'; warning.textContent = `项目状态：${p.manifest.state} · 原始素材保留`; copy.append(warning); }
    const actions = document.createElement('div'); actions.className = 'project-buttons';
    const open = document.createElement('button'); open.textContent = '打开文件夹 ↗'; open.onclick = () => invoke('open_project', {path:p.path}).catch(e => toast(e, true)); actions.append(open);
    if (p.recoverable) { const retry = document.createElement('button'); retry.textContent = '重试合成'; retry.onclick = () => action('retry_export', {path:p.path}, '已完成分段已重新合成'); actions.append(retry); }
    copy.append(actions); article.append(thumbnail, copy); grid.append(article);
  }
}
function openViewer(p) {
  if (!p.preview) return;
  $('viewer-title').textContent = p.manifest.title; $('viewer-media').replaceChildren();
  const media = document.createElement(p.manifest.kind === 'recording' ? 'video' : 'img');
  media.src = assetUrl(p.preview);
  if (media instanceof HTMLVideoElement) { media.controls = true; media.preload = 'metadata'; } else media.alt = p.manifest.title;
  media.addEventListener('error', () => toast('预览无法解码。请从项目文件夹打开原始文件，保留素材后再排查。', true), {once:true});
  $('viewer-media').append(media); $('viewer').showModal();
}
function closeViewer() { const v = $('viewer-media').querySelector('video'); if (v) { v.pause(); v.removeAttribute('src'); v.load(); } $('viewer-media').replaceChildren(); $('viewer').close(); }
function showPage(page) {
  state.page = page; for (const e of document.querySelectorAll('.page')) e.hidden = e.id !== `page-${page}`;
  for (const e of document.querySelectorAll('[data-page]')) e.classList.toggle('selected', e.dataset.page === page);
  $('page-title').textContent = {capture:'把此刻，记录下来。', library:'每一条记录，都在这里。', help:'专注录制，清楚掌控。'}[page];
  if (page === 'library' && native) refreshLibrary().catch(e => toast(e, true));
}
async function pollOnce() {
  if (!native || state.polling) return;
  state.polling = true;
  try {
    const s = await invoke('record_status'); const previous = state.phase; state.phase = s.phase;
    $('phase-label').textContent = phaseLabels[s.phase] ?? '未知状态'; $('state-badge').className = `state-badge ${s.phase}`;
    $('elapsed').textContent = formatDuration(s.elapsedSeconds); $('status-message').textContent = s.message;
    $('free-space').textContent = `${s.freeGib.toFixed(1)} GiB`;
    $('system-meter').style.width = `${Math.max(0, Math.min(100, s.systemLevel))}%`;
    $('mic-meter').style.width = `${Math.max(0, Math.min(100, s.microphoneLevel))}%`;
    if (previous !== 'idle' && s.phase === 'idle') await refreshLibrary();
    applyControls();
  } catch (e) { $('status-message').textContent = `引擎状态读取失败：${e}`; }
  finally { state.polling = false; }
}
async function poll() { await pollOnce(); setTimeout(poll, 500); }
async function action(command, args = {}, success) {
  if (state.busy) return; state.busy = true; applyControls();
  try { await invoke(command, args); if (success) toast(success); await pollOnce(); if (['stop_recording','take_screenshot','retry_export'].includes(command)) await refreshLibrary(); }
  catch (e) { toast(e, true); }
  finally { state.busy = false; await pollOnce(); applyControls(); }
}
function savePreferences() {
  try { localStorage.setItem('lens-windows-preferences', JSON.stringify({fps:state.fps, cursor:$('cursor').checked, system:$('system-audio').checked, microphone:$('microphone').checked})); } catch { /* Storage restrictions must not prevent recording. */ }
}
function loadPreferences() {
  try { const p = JSON.parse(localStorage.getItem('lens-windows-preferences') ?? '{}'); if ([30,60].includes(p.fps)) state.fps = p.fps; $('cursor').checked = p.cursor !== false; $('system-audio').checked = !!state.info?.ffmpegAvailable && p.system === true; $('microphone').checked = !!state.info?.ffmpegAvailable && p.microphone === true; } catch { /* Malformed preferences fall back to safe defaults. */ }
  for (const e of document.querySelectorAll('[data-fps]')) e.classList.toggle('selected', Number(e.dataset.fps) === state.fps);
}
for (const e of document.querySelectorAll('[data-page]')) e.onclick = () => showPage(e.dataset.page);
for (const e of document.querySelectorAll('[data-go-capture]')) e.onclick = () => showPage('capture');
for (const e of document.querySelectorAll('[data-mode]')) e.onclick = () => { state.mode = e.dataset.mode; state.crop = null; for (const b of document.querySelectorAll('[data-mode]')) b.classList.toggle('selected', b === e); renderSourceSelect(); };
for (const e of document.querySelectorAll('[data-fps]')) e.onclick = () => { state.fps = Number(e.dataset.fps); for (const b of document.querySelectorAll('[data-fps]')) b.classList.toggle('selected', b === e); savePreferences(); };
$('source').onchange = () => { state.sourceId = $('source').value; state.crop = null; updateSourceDetails(); };
$('refresh-sources').onclick = () => refreshSources().catch(e => toast(e, true));
$('refresh-library').onclick = () => refreshLibrary().catch(e => toast(e, true));
$('pick-region').onclick = () => invoke('select_region', {sourceId:state.sourceId}).catch(e => toast(e, true));
$('record').onclick = () => action('start_recording', {options:options()});
$('pause').onclick = () => action(state.phase === 'paused' ? 'resume_recording' : 'pause_recording');
$('stop').onclick = () => action('stop_recording', {}, '已完成保存');
$('screenshot').onclick = () => action('take_screenshot', {options:options()}, '截图已保存到素材库');
$('open-library').onclick = () => invoke('open_project', {path:null}).catch(e => toast(e, true));
$('search').oninput = renderLibrary;
$('close-viewer').onclick = closeViewer;
$('viewer').addEventListener('cancel', e => { e.preventDefault(); closeViewer(); });
for (const id of ['system-audio','microphone','cursor']) $(id).onchange = savePreferences;
$('record-title').value = `录屏 ${new Date().toLocaleDateString('zh-CN')}`;
async function init() {
  if (!native) { $('preview-banner').hidden = false; $('media-status').textContent = '仅界面预览：没有连接本地引擎。'; $('status-message').textContent = '请使用 Windows 构建后的 Lens.exe，浏览器版本不能录屏。'; renderSourceSelect(); applyControls(); return; }
  try {
    state.info = await invoke('app_info'); $('version').textContent = `v${state.info.version} · Rust / Tauri`;
    $('save-path').textContent = state.info.libraryPath; $('media-warning').hidden = state.info.ffmpegAvailable;
    $('media-status').textContent = state.info.ffmpegAvailable ? '已找到本地 FFmpeg 后处理组件。' : '没有找到 FFmpeg：声音和分段合成暂不可用。';
    loadPreferences(); await refreshSources(); await refreshLibrary();
    await bridge.event.listen('region-picked', event => { state.sourceId = event.payload.sourceId; state.crop = event.payload.crop; updateSourceDetails(); });
    await bridge.event.listen('close-blocked', event => toast(event.payload, true));
  } catch (e) { toast(`初始化失败：${e}`, true); }
  applyControls(); poll();
}
init();
