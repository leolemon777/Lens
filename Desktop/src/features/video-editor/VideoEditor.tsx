import { useEffect, useRef, useState, useCallback } from "react";
import {
  cancelMediaTask,
  exportVideo,
  inspectPackage,
  loadAutoEditPlan,
  loadCaptions,
  loadTimeline,
  loadTranscriptionStatus,
  previewSrc,
  renderEdit,
  saveAutoEditPlan,
  saveCaptions,
  saveTimeline,
  type AutoEditPlan,
  type CaptionCue,
  type LibraryItem,
  type PackageInspect,
  type VideoEditTimeline,
} from "../../bridge/commands";

function emptyTimeline(duration: number): VideoEditTimeline {
  return {
    schemaVersion: "0.1",
    segments: [
      {
        id: "main",
        sourceStartSeconds: 0,
        sourceEndSeconds: duration || 1,
        playbackRate: 1,
        isEnabled: true,
        transition: "cut",
      },
    ],
  };
}

export default function VideoEditor({
  item,
  mediaSrc,
  busy,
  run,
}: {
  item: LibraryItem;
  mediaSrc: string | null;
  busy: boolean;
  run: (action: () => Promise<unknown>) => Promise<void>;
}) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [timeline, setTimeline] = useState<VideoEditTimeline>(emptyTimeline(item.duration_seconds ?? 1));
  const [history, setHistory] = useState<VideoEditTimeline[]>([]);
  const [historyIndex, setHistoryIndex] = useState(0);
  const [editPlan, setEditPlan] = useState<AutoEditPlan | null>(null);
  const [cues, setCues] = useState<CaptionCue[]>([]);
  const [inspect, setInspect] = useState<PackageInspect | null>(null);
  const [playhead, setPlayhead] = useState(0);
  const [renderedSrc, setRenderedSrc] = useState<string | null>(null);
  const [transcriptionMessage, setTranscriptionMessage] = useState<string | null>(null);
  const [exportPath, setExportPath] = useState<string | null>(null);
  const [activeTaskId, setActiveTaskId] = useState<string | null>(null);
  const [cancelRequested, setCancelRequested] = useState(false);
  const activeTaskRef = useRef<string | null>(null);
  const [activeTab, setActiveTab] = useState<"timeline" | "camera" | "audio" | "captions">("timeline");

  const pushTimeline = useCallback((next: VideoEditTimeline) => {
    setHistory((prev) => {
      const sliced = prev.slice(0, historyIndex + 1);
      return [...sliced, next];
    });
    setHistoryIndex((prev) => prev + 1);
    setTimeline(next);
  }, [historyIndex]);

  const undo = useCallback(() => {
    if (historyIndex > 0) {
      const target = historyIndex - 1;
      setHistoryIndex(target);
      setTimeline(history[target]);
    }
  }, [historyIndex, history]);

  const redo = useCallback(() => {
    if (historyIndex < history.length - 1) {
      const target = historyIndex + 1;
      setHistoryIndex(target);
      setTimeline(history[target]);
    }
  }, [historyIndex, history]);

  useEffect(() => {
    setRenderedSrc(null);
    setExportPath(null);
    setTranscriptionMessage(null);
    void loadTimeline(item.package_path).then((loaded) => {
      const tl = loaded ?? emptyTimeline(item.duration_seconds ?? 1);
      setTimeline(tl);
      setHistory([tl]);
      setHistoryIndex(0);
    });
    void loadAutoEditPlan(item.package_path).then((plan) => {
      setEditPlan(plan);
    });
    void loadCaptions(item.package_path).then(setCues);
    void loadTranscriptionStatus(item.package_path).then((status) => setTranscriptionMessage(status?.message ?? null));
    void inspectPackage(item.package_path).then(setInspect).catch(() => setInspect(null));
    return () => {
      const taskId = activeTaskRef.current;
      if (taskId) void cancelMediaTask(taskId);
    };
  }, [item.id, item.package_path, item.duration_seconds]);

  const createMediaTask = (kind: "render" | "export") => {
    const random = typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const taskId = `${kind}-${random}`;
    activeTaskRef.current = taskId;
    setActiveTaskId(taskId);
    setCancelRequested(false);
    return taskId;
  };

  const finishMediaTask = (taskId: string) => {
    if (activeTaskRef.current === taskId) {
      activeTaskRef.current = null;
      setActiveTaskId(null);
      setCancelRequested(false);
    }
  };

  const persistAndRender = (next: VideoEditTimeline) => {
    setTimeline(next);
    void run(async () => {
      await saveTimeline(item.package_path, next);
      await saveCaptions(item.package_path, cues);
      if (editPlan) {
        await saveAutoEditPlan(item.package_path, { ...editPlan, timeline: next });
      }
      const taskId = createMediaTask("render");
      try {
        const path = await renderEdit(item.package_path, next, taskId);
        setRenderedSrc(await previewSrc(path));
      } finally {
        finishMediaTask(taskId);
      }
    });
  };

  const exportCurrent = (preset: string) => run(async () => {
    await saveTimeline(item.package_path, timeline);
    await saveCaptions(item.package_path, cues);
    if (editPlan) {
      await saveAutoEditPlan(item.package_path, { ...editPlan, timeline });
    }
    const taskId = createMediaTask("export");
    try {
      setExportPath(await exportVideo(item.package_path, preset, taskId));
    } finally {
      finishMediaTask(taskId);
    }
  });

  const macSidecar = inspect?.assets.some(
    (asset) => asset.container === "caf" || asset.container === "mov",
  );
  const hasCameraTrack = inspect?.assets.some((asset) => asset.relativePath.includes("camera.mp4"));

  return (
    <>
      <div className="tool-row">
        <button disabled={busy} onClick={() => void exportCurrent("original")}>
          原画导出
        </button>
        <button disabled={busy} onClick={() => void exportCurrent("balanced")}>
          平衡导出
        </button>
        <button disabled={busy} onClick={() => void exportCurrent("light")}>
          轻量导出
        </button>
        <button disabled={busy || historyIndex <= 0} onClick={undo} title="撤销时间线操作 (Ctrl+Z)">
          ↶ 撤销
        </button>
        <button disabled={busy || historyIndex >= history.length - 1} onClick={redo} title="重做时间线操作 (Ctrl+Y)">
          ↷ 重做
        </button>
        <button
          disabled={busy || renderedSrc !== null}
          onClick={() => {
            const at = videoRef.current?.currentTime ?? playhead;
            const next = {
              ...timeline,
              segments: timeline.segments.flatMap((segment) => {
                if (!segment.isEnabled || at <= segment.sourceStartSeconds + 0.05 || at >= segment.sourceEndSeconds - 0.05) {
                  return [segment];
                }
                return [
                  { ...segment, id: `${segment.id}-a`, sourceEndSeconds: at },
                  {
                    ...segment,
                    id: `${segment.id}-b`,
                    sourceStartSeconds: at,
                    transition: "cut",
                  },
                ];
              }),
            };
            pushTimeline(next);
            persistAndRender(next);
          }}
        >
          在播放头分割
        </button>
        <button className="primary" disabled={busy} onClick={() => persistAndRender(timeline)}>
          成片（同一计划）
        </button>
        {activeTaskId ? (
          <button
            className="danger"
            disabled={cancelRequested}
            onClick={() => {
              setCancelRequested(true);
              void cancelMediaTask(activeTaskId).then((found) => {
                if (!found) finishMediaTask(activeTaskId);
              });
            }}
          >
            {cancelRequested ? "正在取消…" : "取消当前任务"}
          </button>
        ) : null}
      </div>
      {exportPath ? <p className="path-line">已导出：{exportPath}</p> : null}
      {renderedSrc ? <p>正在预览已生成的成片。<button onClick={() => setRenderedSrc(null)}>返回源素材进行分割</button></p> : null}
      {renderedSrc || mediaSrc ? (
        <video
          ref={videoRef}
          className="preview-media"
          src={renderedSrc ?? mediaSrc ?? undefined}
          controls
          onTimeUpdate={(event) => setPlayhead(event.currentTarget.currentTime)}
        />
      ) : null}
      {macSidecar ? <p className="path-line">只读打开 Mac 包：CAF/MOV 未改写 raw/</p> : null}

      <div className="editor-tabs" style={{ display: "flex", gap: "8px", marginTop: "12px", borderBottom: "1px solid rgba(0,0,0,0.1)", paddingBottom: "8px" }}>
        <button
          type="button"
          className={`chip ${activeTab === "timeline" ? "primary" : ""}`}
          onClick={() => setActiveTab("timeline")}
        >
          ⏱️ 时间线片段 ({timeline.segments.length})
        </button>
        <button
          type="button"
          className={`chip ${activeTab === "camera" ? "primary" : ""}`}
          onClick={() => setActiveTab("camera")}
        >
          🎥 运镜与画中画 {editPlan?.camera?.pip?.isEnabled ? "· PiP开" : ""}
        </button>
        <button
          type="button"
          className={`chip ${activeTab === "audio" ? "primary" : ""}`}
          onClick={() => setActiveTab("audio")}
        >
          🔊 音频与闪避
        </button>
        <button
          type="button"
          className={`chip ${activeTab === "captions" ? "primary" : ""}`}
          onClick={() => setActiveTab("captions")}
        >
          📝 字幕 ({cues.length})
        </button>
      </div>

      {activeTab === "timeline" ? (
        <div className="timeline-list">
          {timeline.segments.map((segment, index) => (
            <div key={segment.id} className="timeline-row">
              <label>
                <input
                  type="checkbox"
                  checked={segment.isEnabled}
                  onChange={(event) => {
                    const next = {
                      ...timeline,
                      segments: timeline.segments.map((item, i) =>
                        i === index ? { ...item, isEnabled: event.target.checked } : item,
                      ),
                    };
                    pushTimeline(next);
                  }}
                />
                {segment.sourceStartSeconds.toFixed(2)}–{segment.sourceEndSeconds.toFixed(2)}s
              </label>
              <label>
                倍速
                <input
                  type="number"
                  min={0.5}
                  max={3}
                  step={0.25}
                  value={segment.playbackRate}
                  onChange={(event) => {
                    const next = {
                      ...timeline,
                      segments: timeline.segments.map((item, i) =>
                        i === index ? { ...item, playbackRate: Number(event.target.value) } : item,
                      ),
                    };
                    pushTimeline(next);
                  }}
                />
              </label>
              <select
                value={segment.transition || "cut"}
                onChange={(event) => {
                  const next = {
                    ...timeline,
                    segments: timeline.segments.map((item, i) =>
                      i === index ? { ...item, transition: event.target.value } : item,
                    ),
                  };
                  pushTimeline(next);
                }}
              >
                <option value="cut">硬切</option>
                <option value="crossfade">交叉淡化</option>
              </select>
              <button
                onClick={() => {
                  if (index === 0) return;
                  const segments = [...timeline.segments];
                  [segments[index - 1], segments[index]] = [segments[index], segments[index - 1]];
                  pushTimeline({ ...timeline, segments });
                }}
                title="上移片段"
              >
                上移
              </button>
              <button
                onClick={() => {
                  if (index >= timeline.segments.length - 1) return;
                  const segments = [...timeline.segments];
                  [segments[index + 1], segments[index]] = [segments[index], segments[index + 1]];
                  pushTimeline({ ...timeline, segments });
                }}
                title="下移片段"
              >
                下移
              </button>
              <button
                onClick={() => {
                  const copy = { ...segment, id: `${segment.id}-copy-${Date.now()}` };
                  const segments = [...timeline.segments];
                  segments.splice(index + 1, 0, copy);
                  pushTimeline({ ...timeline, segments });
                }}
                title="复制此片段"
              >
                复制
              </button>
              {timeline.segments.length > 1 && (
                <button
                  onClick={() => {
                    const segments = timeline.segments.filter((_, i) => i !== index);
                    pushTimeline({ ...timeline, segments });
                  }}
                  title="删除此片段"
                >
                  删除
                </button>
              )}
            </div>
          ))}
        </div>
      ) : null}

      {activeTab === "camera" ? (
        <div className="camera-editor" style={{ padding: "12px", background: "rgba(0,0,0,0.03)", borderRadius: "12px", marginTop: "10px" }}>
          <h4>智能运镜（Auto-Zoom）与聚焦</h4>
          <label style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
            <input
              type="checkbox"
              checked={editPlan?.camera?.mode !== "off"}
              onChange={(e) => {
                const nextPlan: AutoEditPlan = editPlan ?? {
                  schemaVersion: "1.2",
                  preset: "natural",
                  camera: { mode: "event-driven", zoomScale: 1.6, keyframes: [] },
                  captions: { isEnabled: true, maxCharactersPerCue: 42, cues: [] },
                  timeline,
                };
                nextPlan.camera.mode = e.target.checked ? "event-driven" : "off";
                setEditPlan({ ...nextPlan });
                void saveAutoEditPlan(item.package_path, nextPlan);
              }}
            />
            启用基于鼠标焦点与点击的智能平滑运镜
          </label>
          <p style={{ fontSize: "12px", color: "var(--lens-secondary)" }}>
            已规划 {editPlan?.camera?.keyframes?.length ?? 0} 个运镜关键帧（点击聚焦 1.6x 变焦缓动回弹）。
          </p>

          <h4 style={{ marginTop: "16px" }}>摄像头画中画（PiP）</h4>
          {hasCameraTrack ? (
            <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
              <label style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                <input
                  type="checkbox"
                  checked={editPlan?.camera?.pip?.isEnabled ?? true}
                  onChange={(e) => {
                    if (!editPlan) return;
                    const next = {
                      ...editPlan,
                      camera: {
                        ...editPlan.camera,
                        pip: {
                          ...(editPlan.camera.pip ?? { position: "bottomRight" as const, scale: 0.22, shape: "roundedRect" as const }),
                          isEnabled: e.target.checked,
                        },
                      },
                    };
                    setEditPlan(next);
                    void saveAutoEditPlan(item.package_path, next);
                  }}
                />
                开启摄像头独立画中画叠加
              </label>
              <div style={{ display: "flex", gap: "16px", alignItems: "center" }}>
                <label>
                  位置：
                  <select
                    value={editPlan?.camera?.pip?.position ?? "bottomRight"}
                    onChange={(e) => {
                      if (!editPlan) return;
                      const next = {
                        ...editPlan,
                        camera: {
                          ...editPlan.camera,
                          pip: {
                            ...(editPlan.camera.pip ?? { isEnabled: true, scale: 0.22, shape: "roundedRect" as const }),
                            position: e.target.value as any,
                          },
                        },
                      };
                      setEditPlan(next);
                      void saveAutoEditPlan(item.package_path, next);
                    }}
                  >
                    <option value="bottomRight">右下角 (默认)</option>
                    <option value="bottomLeft">左下角</option>
                    <option value="topRight">右上角</option>
                    <option value="topLeft">左上角</option>
                  </select>
                </label>
                <label>
                  尺寸比例：
                  <select
                    value={editPlan?.camera?.pip?.scale ?? 0.22}
                    onChange={(e) => {
                      if (!editPlan) return;
                      const next = {
                        ...editPlan,
                        camera: {
                          ...editPlan.camera,
                          pip: {
                            ...(editPlan.camera.pip ?? { isEnabled: true, position: "bottomRight" as const, shape: "roundedRect" as const }),
                            scale: Number(e.target.value),
                          },
                        },
                      };
                      setEditPlan(next);
                      void saveAutoEditPlan(item.package_path, next);
                    }}
                  >
                    <option value={0.18}>小 (18%)</option>
                    <option value={0.22}>中 (22% 标准)</option>
                    <option value={0.28}>大 (28%)</option>
                  </select>
                </label>
              </div>
            </div>
          ) : (
            <p style={{ fontSize: "12px", color: "var(--lens-tertiary)" }}>
              当前录屏素材未包含独立摄像头视频轨。
            </p>
          )}
        </div>
      ) : null}

      {activeTab === "audio" ? (
        <div className="audio-editor" style={{ padding: "12px", background: "rgba(0,0,0,0.03)", borderRadius: "12px", marginTop: "10px" }}>
          <h4>广播级音频处理与智能闪避</h4>
          <label style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
            <input
              type="checkbox"
              checked={editPlan?.audio?.duckingEnabled ?? true}
              onChange={(e) => {
                if (!editPlan) return;
                const next = {
                  ...editPlan,
                  audio: {
                    ...(editPlan.audio ?? { duckingAttenuationDb: -12.0, normalizeEnabled: true }),
                    duckingEnabled: e.target.checked,
                  },
                };
                setEditPlan(next);
                void saveAutoEditPlan(item.package_path, next);
              }}
            />
            人声智能闪避（Ducking）：麦克风说话时系统声音自动柔和压低 12 dB
          </label>
          <label style={{ display: "flex", alignItems: "center", gap: "8px" }}>
            <input
              type="checkbox"
              checked={editPlan?.audio?.normalizeEnabled ?? true}
              onChange={(e) => {
                if (!editPlan) return;
                const next = {
                  ...editPlan,
                  audio: {
                    ...(editPlan.audio ?? { duckingEnabled: true, duckingAttenuationDb: -12.0 }),
                    normalizeEnabled: e.target.checked,
                  },
                };
                setEditPlan(next);
                void saveAutoEditPlan(item.package_path, next);
              }}
            />
            动态响度均衡（DynAudNorm）：避免音量忽大忽小，消除爆音
          </label>
        </div>
      ) : null}

      {activeTab === "captions" ? (
        <div className="caption-editor">
          <h3>字幕（人工校正）</h3>
          {transcriptionMessage ? <p>{transcriptionMessage}</p> : null}
          {cues.length === 0 ? <p>暂无识别字幕。</p> : null}
          {cues.map((cue, index) => (
            <label key={`${cue.startSeconds}-${index}`} className="caption-row">
              {cue.startSeconds.toFixed(1)}s
              <input
                value={cue.text}
                onChange={(event) => {
                  const next = cues.map((item, i) => (i === index ? { ...item, text: event.target.value } : item));
                  setCues(next);
                }}
              />
            </label>
          ))}
          <button
            disabled={busy}
            onClick={() =>
              void run(async () => {
                await saveCaptions(item.package_path, cues);
              })
            }
          >
            保存字幕
          </button>
        </div>
      ) : null}
    </>
  );
}
