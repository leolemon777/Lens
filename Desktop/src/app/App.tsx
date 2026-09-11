import { useCallback, useEffect, useRef, useState } from "react";
import { getCurrentWindow, LogicalSize } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import {
  cancelScrolling,
  deleteItem,
  finishScrolling,
  getAppState,
  listAudioDevices,
  listCameraDevices,
  listWindows,
  openLibrary,
  openRegionOverlay,
  pauseRecording,
  pinLast,
  previewSrc,
  recognizeOcr,
  revealInExplorer,
  scrollingTick,
  setLibraryRoot,
  setRecordingAudioConfig,
  setRecordingCameraConfig,
  setRecordingFps,
  startDisplayRecording,
  startWindowRecording,
  stopRecording,
  type AppSnapshot,
  type AudioDeviceInfo,
  type LibraryItem,
  type VideoCaptureDeviceInfo,
  type WindowInfo,
} from "../bridge/commands";
import Overlay from "../features/capture/Overlay";
import RecordBar from "../features/capture/RecordBar";
import ScreenshotEditor from "../features/screenshot-editor/ScreenshotEditor";
import VideoEditor from "../features/video-editor/VideoEditor";

export default function App() {
  const windowKind = new URLSearchParams(window.location.search).get("window");
  if (windowKind === "overlay") return <Overlay />;
  if (windowKind === "pin") return <Pin />;
  if (windowKind === "quick-access") return <QuickAccess />;
  if (windowKind === "island") return <Island />;
  if (windowKind === "record-bar") return <RecordBar />;
  return <Shell />;
}

function QuickAccess() {
  const [src, setSrc] = useState<string | null>(null);
  const [item, setItem] = useState<LibraryItem | null>(null);
  const [dragError, setDragError] = useState<string | null>(null);
  const dragWindow = (event: React.PointerEvent) => {
    if (event.button === 0) {
      event.preventDefault();
      void getCurrentWindow().startDragging().catch(cause => setDragError(String(cause)));
    }
  };

  useEffect(() => {
    void getAppState().then(async (state) => {
      const last = state.last_item;
      setItem(last);
      if (last?.preview_path) setSrc(await previewSrc(last.preview_path));
    });
  }, []);

  return (
    <main className="quick-access">
      <div className="qa-thumb-box qa-drag-handle" onPointerDown={dragWindow} title="拖动调整位置">
        {src ? <img src={src} alt="thumb" /> : <span className="thumb" />}
      </div>
      <div className="qa-body">
        <b className="qa-drag-handle" onPointerDown={dragWindow} title="拖动调整位置">{item?.title ?? "截图已复制"}</b>
        <small className="qa-drag-handle" onPointerDown={dragWindow}>{dragError ?? "已保存 · 拖动此处调整位置"}</small>
        <div className="qa-actions">
          <button type="button" onClick={() => void pinLast()}>
            贴图
          </button>
          <button type="button" onClick={() => void openLibrary().then(() => getCurrentWindow().close())}>
            编辑
          </button>
          {item?.package_path && (
            <button
              type="button"
              onClick={() => void revealInExplorer(item.package_path)}
              title="在文件夹中查看"
            >
              定位
            </button>
          )}
          <button type="button" onClick={() => void getCurrentWindow().close()}>
            关闭
          </button>
        </div>
      </div>
    </main>
  );
}

function Pin() {
  const [src, setSrc] = useState<string | null>(null);
  const [item, setItem] = useState<LibraryItem | null>(null);
  const [opacity, setOpacity] = useState(1.0);
  const [scale, setScale] = useState(1.0);
  const [locked, setLocked] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    void getAppState().then(async (state) => {
      const last = state.last_item;
      setItem(last);
      const path = last?.preview_path;
      if (path) setSrc(await previewSrc(path));
    });
  }, []);

  const copyImage = useCallback(() => {
    if (!src) return;
    void fetch(src)
      .then((response) => response.blob())
      .then((blob) =>
        navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })]),
      )
      .then(() => {
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      });
  }, [src]);

  const cycleOpacity = useCallback(() => {
    const levels = [1.0, 0.8, 0.6, 0.4];
    setOpacity((prev) => {
      const idx = levels.findIndex((v) => Math.abs(v - prev) < 0.05);
      return idx >= 0 ? levels[(idx + 1) % levels.length] : 1.0;
    });
  }, []);

  const zoomIn = useCallback(() => setScale((s) => Math.min(3.0, s * 1.2)), []);
  const zoomOut = useCallback(() => setScale((s) => Math.max(0.25, s / 1.2)), []);
  const resetScale = useCallback(() => setScale(1.0), []);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        window.close();
        return;
      }
      if (event.ctrlKey || event.metaKey) {
        if (event.key === "c" || event.key === "C") {
          event.preventDefault();
          copyImage();
        } else if (event.key === "+" || event.key === "=") {
          event.preventDefault();
          zoomIn();
        } else if (event.key === "-") {
          event.preventDefault();
          zoomOut();
        } else if (event.key === "0") {
          event.preventDefault();
          resetScale();
        } else if (event.key === "w" || event.key === "W") {
          event.preventDefault();
          window.close();
        }
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [copyImage, zoomIn, zoomOut, resetScale]);

  const handleWheel = useCallback(
    (event: React.WheelEvent) => {
      if (event.ctrlKey || event.altKey) {
        event.preventDefault();
        const delta = event.deltaY < 0 ? 0.05 : -0.05;
        setOpacity((prev) => Math.min(1.0, Math.max(0.4, prev + delta)));
      } else {
        event.preventDefault();
        const factor = event.deltaY < 0 ? 1.08 : 1 / 1.08;
        setScale((s) => Math.min(3.0, Math.max(0.25, s * factor)));
      }
    },
    [],
  );

  return (
    <main
      className={`pin-surface ${locked ? "is-locked" : ""}`}
      style={{ opacity }}
      onWheel={handleWheel}
    >
      <div
        className="pin-content"
        {...(!locked ? { "data-tauri-drag-region": "true" } : {})}
      >
        {src ? (
          <img
            src={src}
            alt="pinned"
            style={{ transform: `scale(${scale})`, transformOrigin: "center center" }}
            draggable={false}
          />
        ) : (
          <p className="pin-empty">没有可贴的截图</p>
        )}
      </div>
      <div className="pin-toolbar">
        <button type="button" onClick={copyImage}>
          {copied ? "✓ 已复制" : "复制"}
        </button>
        <button type="button" onClick={zoomIn} title="放大 (Ctrl+=)">
          +
        </button>
        <button type="button" onClick={zoomOut} title="缩小 (Ctrl+-)">
          -
        </button>
        {scale !== 1 && (
          <button type="button" onClick={resetScale} title="重置大小 (Ctrl+0)">
            {Math.round(scale * 100)}%
          </button>
        )}
        <button type="button" onClick={cycleOpacity} title="循环切换透明度">
          {Math.round(opacity * 100)}%
        </button>
        <button
          type="button"
          className={locked ? "active-lock" : ""}
          onClick={() => setLocked((value) => !value)}
          title={locked ? "已锁定位置（点击解锁）" : "锁定位置（不可拖动）"}
        >
          {locked ? "🔒 已锁定" : "🔓 锁定"}
        </button>
        {item?.package_path && (
          <button
            type="button"
            onClick={() => void revealInExplorer(item.package_path)}
            title="在资源管理器中定位"
          >
            定位
          </button>
        )}
        <button type="button" onClick={() => window.close()} title="关闭 (Esc)">
          关闭
        </button>
      </div>
    </main>
  );
}

function Island() {
  return <Shell compact />;
}

function Shell({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<AppSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState<LibraryItem | null>(null);
  const [query, setQuery] = useState("");
  const [windows, setWindows] = useState<WindowInfo[] | null>(null);
  const [ocrText, setOcrText] = useState<string | null>(null);
  const [moreMenu, setMoreMenu] = useState(false);
  const [countdown, setCountdown] = useState<number | null>(null);
  const [showDeviceSettings, setShowDeviceSettings] = useState(false);
  const [recordSetup, setRecordSetup] = useState(false);
  const countdownTimer = useRef<number | null>(null);
  const surface = useRef<HTMLElement>(null);
  const [audioDevices, setAudioDevices] = useState<AudioDeviceInfo[]>([]);
  const [cameraDevices, setCameraDevices] = useState<VideoCaptureDeviceInfo[]>([]);

  const loadDevices = async () => {
    try {
      const [aDevs, cDevs] = await Promise.all([listAudioDevices(), listCameraDevices()]);
      setAudioDevices(aDevs);
      setCameraDevices(cDevs);
    } catch (cause) {
      setError(`无法读取设备：${String(cause)}`);
    }
  };

  const refresh = useCallback(async () => {
    const next = await getAppState();
    setState(next);
    setSelected((current) => {
      if (current) return next.items.find((item) => item.id === current.id) ?? current;
      return next.last_item ?? next.items[0] ?? null;
    });
  }, []);

  useEffect(() => {
    void refresh().catch((cause) => setError(String(cause)));
    const timer = window.setInterval(() => {
      void refresh().catch(() => undefined);
    }, 1000);
    const unlisten = listen("lens-changed", () => {
      void refresh();
    });
    const unlistenOpen = listen<string>("lens-open-item", event => {
      void getAppState().then(next => {
        setState(next);
        setSelected(next.items.find(item => item.package_path === event.payload) ?? next.last_item);
      }).catch(cause => setError(String(cause)));
    });
    return () => {
      window.clearInterval(timer);
      void unlisten.then((close) => close());
      void unlistenOpen.then(close => close());
    };
  }, [refresh]);

  useEffect(() => {
    if (!state?.scrolling) return;
    const timer = window.setInterval(() => {
      void scrollingTick().catch(() => undefined);
    }, 450);
    return () => window.clearInterval(timer);
  }, [state?.scrolling]);

  const run = useCallback(
    async (action: () => Promise<unknown>) => {
      setBusy(true);
      setError(null);
      try {
        await action();
        await refresh();
      } catch (cause) {
        setError(String(cause));
      } finally {
        setBusy(false);
      }
    },
    [refresh],
  );

  const [mediaSrc, setMediaSrc] = useState<string | null>(null);
  const [recentSrc, setRecentSrc] = useState<string | null>(null);

  useEffect(() => {
    if (!selected?.preview_path) {
      setMediaSrc(null);
      return;
    }
    void previewSrc(selected.preview_path)
      .then(setMediaSrc)
      .catch(() => setMediaSrc(null));
  }, [selected]);

  const startWithCountdown = () => {
    if (countdownTimer.current !== null || busy) return;
    setCountdown(3);
    let remaining = 3;
    countdownTimer.current = window.setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        window.clearInterval(countdownTimer.current!);
        countdownTimer.current = null;
        setCountdown(null);
        setRecordSetup(false);
        void run(() => startDisplayRecording());
      } else {
        setCountdown(remaining);
      }
    }, 1000);
  };

  const cancelCountdown = () => {
    if (countdownTimer.current !== null) window.clearInterval(countdownTimer.current);
    countdownTimer.current = null;
    setCountdown(null);
  };

  useEffect(() => () => {
    if (countdownTimer.current !== null) window.clearInterval(countdownTimer.current);
  }, []);

  useEffect(() => {
    if (!compact || !surface.current) return;
    const observer = new ResizeObserver(() => {
      const height = Math.min(Math.ceil(surface.current!.getBoundingClientRect().height) + 2, window.screen.availHeight - 80);
      void getCurrentWindow().setSize(new LogicalSize(680, Math.max(340, height))).catch(() => undefined);
    });
    observer.observe(surface.current);
    return () => observer.disconnect();
  }, [compact]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.target as HTMLElement).matches("input, textarea, select, [contenteditable]")) return;
      if (event.key === "Escape") {
        event.preventDefault();
        if (countdown !== null) cancelCountdown();
        else if (windows) setWindows(null);
        else if (ocrText !== null) setOcrText(null);
        else if (moreMenu) setMoreMenu(false);
        else if (recordSetup) { setRecordSetup(false); setShowDeviceSettings(false); }
        else if (compact) void getCurrentWindow().hide();
      } else if (!busy && !state?.recording && !state?.scrolling && countdown === null && !event.ctrlKey && !event.altKey && !event.metaKey) {
        if (event.key === "1") void run(() => openRegionOverlay("screenshot"));
        if (event.key === "2") setRecordSetup(true);
        if (event.key === "3" && selected) void run(async () => setOcrText((await recognizeOcr(selected.package_path)).fullText));
        if (event.key === "4") void run(() => openRegionOverlay("scrolling"));
        if (event.key === "5") void run(() => pinLast());
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [compact, countdown, windows, ocrText, moreMenu, recordSetup, busy, state?.recording, state?.scrolling, selected, run]);

  const filtered = (state?.items ?? []).filter((item) => {
    const q = query.trim().toLowerCase();
    if (!q) return true;
    const tokens = q.split(/\s+/).filter(Boolean);
    const haystack = `${item.title} ${item.kind} ${item.search_text ?? ""}`.toLowerCase();
    return tokens.every((token) => haystack.includes(token));
  });

  const seconds = Math.round((state?.recording_elapsed_ms || 0) / 1000);
  const clock = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  const recent = state?.last_item ?? filtered[0];
  useEffect(() => {
    if (!recent?.preview_path) {
      setRecentSrc(null);
      return;
    }
    void previewSrc(recent.preview_path)
      .then(setRecentSrc)
      .catch(() => setRecentSrc(null));
  }, [recent?.preview_path]);

  const diskGb = ((state?.disk_free_bytes ?? 0) / (1024 * 1024 * 1024)).toFixed(1);

  return (
    <main ref={surface} className={`lens-app ${compact ? "compact-shell" : "library-shell"} ${recordSetup ? "is-record-setup" : ""}`}>
      {!compact && <header className="library-toolbar"><strong>Lens 库</strong><span>截图与标注</span><button onClick={() => void run(() => openRegionOverlay("screenshot"))}>新截图</button><button onClick={() => setRecordSetup(value => !value)}>录屏设置</button></header>}
      {!compact && error && <div className="alert" role="alert">{error}</div>}
      <section className="glass-island">
        <div className="island-header" data-tauri-drag-region>
          <span className="mark" />
          Lens
          <span className="header-caption">{recordSetup ? "录制设置" : "捕捉此刻，留住灵感"}</span>
          {compact && <button className="close-control" aria-label="关闭操作中心" title="关闭 · Esc" onClick={() => void getCurrentWindow().hide()}>×</button>}
        </div>
        <div className="island-divider" />
        {countdown != null ? (
          <div className="rec-bar">
            <span className="time">{countdown}</span>
            <span>即将开始录制</span>
            <button className="countdown-cancel" onClick={cancelCountdown}>取消 · Esc</button>
          </div>
        ) : state?.recording ? (
          <div className="rec-bar">
            <span className="rec-dot" />
            <span className="time">{clock}</span>
            <span
              className={`level ${state.audio_system_enabled ? "" : "muted"}`}
              title={state.audio_system_enabled ? "系统声音（开启）" : "系统声音（已静音）"}
            >
              <i style={{ width: `${state.audio_system_enabled ? Math.round((state.audio_peak_system ?? 0) * 100) : 0}%` }} />
            </span>
            <span
              className={`level ${state.audio_mic_enabled ? "" : "muted"}`}
              title={state.audio_mic_enabled ? "麦克风（开启）" : "麦克风（已静音）"}
            >
              <i style={{ width: `${state.audio_mic_enabled ? Math.round((state.audio_peak_mic ?? 0) * 100) : 0}%` }} />
            </span>
            {state.camera_enabled ? (
              <span className="rec-tag camera" title="摄像头画中画/独立分轨录制中">
                📷
              </span>
            ) : null}
            <small>{diskGb} GiB</small>
            <span className="spacer" />
            <button disabled={busy} onClick={() => void run(() => pauseRecording(!state.recording_paused))}>
              {state.recording_paused ? "继续" : "暂停"}
            </button>
            <button className="stop" disabled={busy} onClick={() => void run(() => stopRecording())}>
              停止
            </button>
          </div>
        ) : state?.scrolling ? (
          <div className="rec-bar scrolling-bar">
            <span className="rec-dot cyan" />
            <span className="time">长截图中 · {state.scroll_frames ?? 0} 帧</span>
            <small>向下滚动内容自动对齐拼接</small>
            <span className="spacer" />
            <button className="primary" disabled={busy} onClick={() => void run(() => finishScrolling())}>
              完成
            </button>
            <button disabled={busy} onClick={() => void run(() => cancelScrolling())}>
              取消
            </button>
          </div>
        ) : (
          <div className="tile-row">
            <button className="tile" disabled={busy} onClick={() => { setMoreMenu(false); void run(() => openRegionOverlay("screenshot")); }}>
              <span className="tile-icon cyan">
                <svg viewBox="0 0 24 24">
                  <rect x="4" y="6" width="16" height="12" rx="2" />
                  <circle cx="12" cy="12" r="3" />
                </svg>
              </span>
              <strong>截图</strong>
              <span>松手就已复制</span>
            </button>
            <button className={`tile ${recordSetup ? "selected-tile" : ""}`} aria-expanded={recordSetup} disabled={busy} onClick={() => { setRecordSetup((open) => !open); setMoreMenu(false); }}>
              <span className="tile-icon red">
                <svg viewBox="0 0 24 24">
                  <circle cx="12" cy="12" r="7" />
                  <circle cx="12" cy="12" r="3" fill="currentColor" stroke="none" />
                </svg>
              </span>
              <strong>录屏</strong>
              <span>停下就能拖走</span>
            </button>
            <button className="tile" aria-expanded={moreMenu} disabled={busy} onClick={() => setMoreMenu((open) => !open)}>
              <span className="tile-icon muted">
                <svg viewBox="0 0 24 24">
                  <circle cx="6" cy="12" r="1.4" fill="currentColor" stroke="none" />
                  <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
                  <circle cx="18" cy="12" r="1.4" fill="currentColor" stroke="none" />
                </svg>
              </span>
              <strong>更多</strong>
              <span>文字 · 长截图 · 贴图</span>
            </button>
            {moreMenu ? (
              <div className="flyout right">
                <button
                  disabled={!selected || busy}
                  onClick={() => {
                    setMoreMenu(false);
                    selected &&
                      void run(async () => setOcrText((await recognizeOcr(selected.package_path)).fullText));
                  }}
                >
                  OCR 文字
                </button>
                <button
                  onClick={() => {
                    setMoreMenu(false);
                    void run(() => openRegionOverlay("scrolling"));
                  }}
                >
                  长截图
                </button>
                <button
                  onClick={() => {
                    setMoreMenu(false);
                    void run(() => pinLast());
                  }}
                >
                  贴图
                </button>
                <button
                  onClick={() => {
                    setMoreMenu(false);
                    void run(() => setRecordingFps(state?.recording_fps === 60 ? 30 : 60));
                  }}
                >
                  切换 {state?.recording_fps === 60 ? "30" : "60"} FPS
                </button>
              </div>
            ) : null}
          </div>
        )}
        {recordSetup && !state?.recording && !state?.scrolling && countdown == null ? (
          <>
            {showDeviceSettings ? (
              <div className="device-select-dialog">
                <div className="device-select-row">
                  <strong>麦克风输入:</strong>
                  <select
                    value={state?.audio_mic_device_id ?? ""}
                    onChange={(e) => {
                      if (!state) return;
                      const devId = e.target.value ? e.target.value : null;
                      void run(() =>
                        setRecordingAudioConfig(
                          state.audio_system_enabled,
                          state.audio_mic_enabled,
                          state.audio_system_device_id,
                          devId
                        )
                      );
                    }}
                  >
                    <option value="">默认麦克风</option>
                    {audioDevices
                      .filter((d) => d.flow === "capture")
                      .map((d) => (
                        <option key={d.id} value={d.id}>
                          {d.name} {d.is_default ? "(默认)" : ""}
                        </option>
                      ))}
                  </select>
                </div>
                <div className="device-select-row">
                  <strong>摄像头采集:</strong>
                  <select
                    value={state?.camera_device_link ?? ""}
                    onChange={(e) => {
                      if (!state) return;
                      const link = e.target.value ? e.target.value : null;
                      void run(() => setRecordingCameraConfig(state.camera_enabled, link));
                    }}
                  >
                    <option value="">默认摄像头</option>
                    {cameraDevices.map((d) => (
                      <option key={d.symbolic_link} value={d.symbolic_link}>
                        {d.name}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="device-select-row">
                  <strong>录制帧率:</strong>
                  <button
                    type="button"
                    className="rec-prep-btn"
                    onClick={() => void run(() => setRecordingFps(state?.recording_fps === 60 ? 30 : 60))}
                  >
                    {state?.recording_fps ?? 30} FPS (点击切换)
                  </button>
                </div>
              </div>
            ) : null}
            <div className="rec-prep-bar">
              <button
                type="button"
                className={`rec-prep-btn ${state?.audio_system_enabled ? "active" : ""}`}
                onClick={() => {
                  if (!state) return;
                  void run(() =>
                    setRecordingAudioConfig(
                      !state.audio_system_enabled,
                      state.audio_mic_enabled,
                      state.audio_system_device_id,
                      state.audio_mic_device_id
                    )
                  );
                }}
                title="录制系统内部发出的声音"
              >
                系统声 · {state?.audio_system_enabled ? "开" : "关"}
              </button>
              <button
                type="button"
                className={`rec-prep-btn ${state?.audio_mic_enabled ? "active" : ""}`}
                onClick={() => {
                  if (!state) return;
                  void run(() =>
                    setRecordingAudioConfig(
                      state.audio_system_enabled,
                      !state.audio_mic_enabled,
                      state.audio_system_device_id,
                      state.audio_mic_device_id
                    )
                  );
                }}
                title="录制麦克风人声"
              >
                麦克风 · {state?.audio_mic_enabled ? "开" : "关"}
              </button>
              <button
                type="button"
                className={`rec-prep-btn ${state?.camera_enabled ? "active" : ""}`}
                onClick={() => {
                  if (!state) return;
                  void run(() =>
                    setRecordingCameraConfig(!state.camera_enabled, state.camera_device_link)
                  );
                }}
                title="在录屏中加入摄像头画面"
              >
                摄像头 · {state?.camera_enabled ? "开" : "关"}
              </button>
              <button
                type="button"
                className={`rec-prep-btn ${showDeviceSettings ? "active" : ""}`}
                onClick={() => {
                  void loadDevices();
                  setShowDeviceSettings((v) => !v);
                }}
                title="选择指定音频与摄像头设备"
              >
                设备设置
              </button>
            </div>
            <div className="record-start-row"><small>{state?.recording_fps ?? 30} FPS</small><button disabled={busy} onClick={() => void run(() => openRegionOverlay("record"))}>录制区域</button><button disabled={busy} onClick={() => void run(async () => setWindows(await listWindows()))}>录制窗口</button><button className="record-start" disabled={busy || !state} onClick={startWithCountdown}>录制当前屏幕</button></div>
          </>
        ) : null}
        {state?.disk_status === "warn" ? <p className="path-line">磁盘低于 5 GiB，请尽快结束录制。</p> : null}
        {state?.scrolling ? (
          <button className="chip primary" style={{ marginBottom: 8 }} onClick={() => void run(() => finishScrolling())}>
            完成长截图 · {state.scroll_frames} 帧
          </button>
        ) : null}
        <div className="island-divider" />
        <div className="recent">
          <div className="recent-head">
            <p>最近</p>
            <button type="button" onClick={() => void openLibrary()}>
              查看全部
            </button>
          </div>
          {recent ? (
            <button className="recent-card" onClick={() => { setSelected(recent); if (compact) void openLibrary(); }}>
              {recentSrc ? (recent.kind === "recording" ? <video className="thumb" src={recentSrc} muted preload="metadata" /> : <img className="thumb" src={recentSrc} alt="" />) : <span className="thumb" />}
              <div>
                <b>{recent.title}</b>
                <small>
                  {recent.width ?? "?"} × {recent.height ?? "?"} · 已保存到本地
                </small>
              </div>
              <span className="check">✓</span>
            </button>
          ) : (
            <div className="recent-card">
              <div>
                <b>还没有记录</b>
                <small>完成第一次截图后，它会在这里立即出现。</small>
              </div>
            </div>
          )}
        </div>
        <div className="island-divider" />
        <div className="footer">
          <span><kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>1</kbd> 截图</span>
          <span><kbd>1–5</kbd> 快速操作 · <kbd>Esc</kbd> 关闭</span>
        </div>
        {error && <div className="alert" role="alert">{error}<button onClick={() => setError(null)} aria-label="关闭错误提示">×</button></div>}
        {compact && ocrText !== null && <div className="ocr-result"><div className="panel-header"><b>识别文字</b><button onClick={() => setOcrText(null)}>完成</button></div><textarea aria-label="识别文字" value={ocrText} onChange={e => setOcrText(e.target.value)} /><button onClick={() => void run(() => navigator.clipboard.writeText(ocrText))}>复制文字</button></div>}
      </section>

      {windows ? (
        <div className="window-picker glass-panel" style={{ margin: "0 auto", width: "min(620px, 100%)" }}>
          <div className="panel-header">
            <h2>选择要录制的窗口</h2>
            <button onClick={() => setWindows(null)}>关闭</button>
          </div>
          {windows.map((item) => (
            <div key={item.hwnd} className="library-card">
              <span>{item.title}</span>
              <button
                onClick={() =>
                  void run(async () => {
                    await startWindowRecording(item.hwnd);
                    setWindows(null);
                  })
                }
              >
                录制
              </button>
            </div>
          ))}
        </div>
      ) : null}

      {compact ? null : (
        <section className="workspace">
          <article className="glass-panel library-panel">
            <div className="panel-header">
              <h2>Lens 库</h2>
              <span>{filtered.length} 项</span>
            </div>
            <input
              className="search-box"
              placeholder="搜索标题 / OCR / 转写 / 摘要"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            <label className="library-root">
              素材库路径
              <input
                defaultValue={state?.library_root ?? ""}
                onBlur={(event) => {
                  if (event.target.value && event.target.value !== state?.library_root) {
                    void run(() => setLibraryRoot(event.target.value));
                  }
                }}
              />
            </label>
            <div className="library-list">
              {filtered.map((item) => (
                <button
                  key={item.id}
                  className={selected?.id === item.id ? "library-card active" : "library-card"}
                  onClick={() => {
                    setSelected(item);
                    setOcrText(null);
                  }}
                >
                  <strong>{item.title}</strong>
                  <span>
                    {item.kind === "screenshot" ? "截图" : "录屏"} · {item.width ?? "?"}×{item.height ?? "?"}
                    {item.created_at ? ` · ${item.created_at.slice(0, 10)}` : ""}
                  </span>
                </button>
              ))}
              {state && filtered.length === 0 ? <p className="empty">没有匹配的素材。</p> : null}
            </div>
          </article>

          <article className="glass-panel preview-panel">
            <div className="panel-header">
              <h2>{selected?.title ?? "预览"}</h2>
            </div>
            {selected?.kind === "recording" ? (
              <VideoEditor item={selected} mediaSrc={mediaSrc} busy={busy} run={run} />
            ) : selected?.kind === "screenshot" && mediaSrc ? (
              <ScreenshotEditor item={selected} mediaSrc={mediaSrc} busy={busy} run={run} />
            ) : (
              <p className="empty">选择一条素材查看</p>
            )}
            {ocrText ? <pre className="ocr-box">{ocrText}</pre> : null}
            {selected ? (
              <p className="path-line">
                <span>{selected.package_path}</span>
                <button
                  type="button"
                  onClick={() => void revealInExplorer(selected.package_path)}
                  title="在文件资源管理器中定位"
                >
                  定位
                </button>
                <button
                  type="button"
                  onClick={() =>
                    selected &&
                    void run(async () => {
                      await deleteItem(selected.package_path);
                      setSelected(null);
                    })
                  }
                >
                  删除
                </button>
              </p>
            ) : null}
          </article>
        </section>
      )}
    </main>
  );
}
