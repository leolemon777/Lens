export function formatDuration(seconds) {
  const value = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const h = Math.floor(value / 3600), m = Math.floor(value / 60) % 60, s = value % 60;
  return (h ? String(h).padStart(2, '0') + ':' : '') + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
}
export function sourceCaption(source, crop) {
  if (!source) return '选择一个显示器或窗口';
  return crop ? `区域 ${crop.width} × ${crop.height}` : source.label;
}
export function cropFromDrag(start, end, physicalWidth, physicalHeight, cssWidth, cssHeight) {
  if (![start.x, start.y, end.x, end.y, physicalWidth, physicalHeight, cssWidth, cssHeight].every(Number.isFinite) || Math.min(physicalWidth, physicalHeight, cssWidth, cssHeight) <= 0) throw new Error('选区尺寸无效');
  // Round inward, never include pixels outside the selection on fractional DPI displays.
  const scaleX = physicalWidth / cssWidth, scaleY = physicalHeight / cssHeight;
  const x = Math.max(0, Math.ceil(Math.min(start.x, end.x) * scaleX));
  const y = Math.max(0, Math.ceil(Math.min(start.y, end.y) * scaleY));
  const right = Math.min(physicalWidth, Math.floor(Math.max(start.x, end.x) * scaleX));
  const bottom = Math.min(physicalHeight, Math.floor(Math.max(start.y, end.y) * scaleY));
  const width = Math.floor((right - x) / 2) * 2, height = Math.floor((bottom - y) / 2) * 2;
  if (width < 2 || height < 2) throw new Error('选区至少为 2 × 2 像素');
  return { x, y, width, height };
}
export function controlsFor(phase, busy, sourceAvailable, mediaAvailable) {
  const idle = phase === 'idle';
  return {
    configure: idle && !busy,
    record: idle && !busy && sourceAvailable,
    screenshot: idle && !busy && sourceAvailable,
    pause: !busy && ((phase === 'recording' && mediaAvailable) || phase === 'paused'),
    stop: !busy && ['recording', 'paused'].includes(phase),
    active: !idle,
  };
}
export function filterProjects(projects, query) {
  const text = String(query).trim().toLocaleLowerCase();
  return projects.filter(p => String(p.manifest.title).toLocaleLowerCase().includes(text));
}
export const phaseLabels = Object.freeze({ idle:'准备就绪', starting:'初始化中', recording:'正在录制', pausing:'保存分段', paused:'已暂停', stopping:'停止录制', processing:'合成与保存' });
