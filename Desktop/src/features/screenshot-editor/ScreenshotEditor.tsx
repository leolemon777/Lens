import { useCallback, useEffect, useRef, useState } from "react";
import {
  exportScreenshot,
  loadScreenshotPlan,
  previewSrc,
  revealInExplorer,
  saveAnnotation,
  saveScreenshotPlan,
  type LibraryItem,
} from "../../bridge/commands";

export type Tool =
  | "select"
  | "rectangle"
  | "ellipse"
  | "arrow"
  | "freehand"
  | "highlight"
  | "step"
  | "text"
  | "blur"
  | "pixelate";

export interface Point {
  x: number;
  y: number;
}

export interface Annotation {
  id: string;
  kind: Exclude<Tool, "select">;
  bounds: { x: number; y: number; width: number; height: number };
  start?: Point;
  end?: Point;
  points?: Point[];
  text?: string;
  style: {
    lineWidth: number;
    fontSize: number;
    color: { red: number; green: number; blue: number; alpha: number };
    intensity: number;
  };
}

const TOOLS: Array<[Tool, string]> = [
  ["select", "选择"],
  ["rectangle", "矩形"],
  ["ellipse", "椭圆"],
  ["arrow", "箭头"],
  ["freehand", "画笔"],
  ["highlight", "高亮"],
  ["step", "编号"],
  ["text", "文字"],
  ["blur", "模糊"],
  ["pixelate", "马赛克"],
];

const PRESET_COLORS = [
  { label: "红", value: { red: 1, green: 0.23, blue: 0.19, alpha: 1 } },
  { label: "橙", value: { red: 1, green: 0.58, blue: 0, alpha: 1 } },
  { label: "黄", value: { red: 1, green: 0.8, blue: 0, alpha: 1 } },
  { label: "绿", value: { red: 0.2, green: 0.78, blue: 0.35, alpha: 1 } },
  { label: "青", value: { red: 0.13, green: 0.78, blue: 0.88, alpha: 1 } },
  { label: "蓝", value: { red: 0.1, green: 0.58, blue: 1, alpha: 1 } },
  { label: "紫", value: { red: 0.63, green: 0.36, blue: 0.94, alpha: 1 } },
  { label: "白", value: { red: 1, green: 1, blue: 1, alpha: 1 } },
  { label: "黑", value: { red: 0.1, green: 0.1, blue: 0.1, alpha: 1 } },
];

const CANVAS_THEMES = [
  {
    id: "blue",
    name: "经典蓝紫",
    kind: "gradient" as const,
    c1: "rgb(51, 89, 235)",
    c2: "rgb(140, 56, 224)",
    p1: { red: 0.2, green: 0.35, blue: 0.92, alpha: 1 },
    p2: { red: 0.55, green: 0.22, blue: 0.88, alpha: 1 },
  },
  {
    id: "sunset",
    name: "落日霞光",
    kind: "gradient" as const,
    c1: "rgb(235, 87, 87)",
    c2: "rgb(242, 153, 74)",
    p1: { red: 0.92, green: 0.34, blue: 0.34, alpha: 1 },
    p2: { red: 0.95, green: 0.6, blue: 0.29, alpha: 1 },
  },
  {
    id: "cyan",
    name: "青绿晨曦",
    kind: "gradient" as const,
    c1: "rgb(17, 153, 142)",
    c2: "rgb(56, 239, 125)",
    p1: { red: 0.07, green: 0.6, blue: 0.56, alpha: 1 },
    p2: { red: 0.22, green: 0.94, blue: 0.49, alpha: 1 },
  },
  {
    id: "dark",
    name: "极简暗色",
    kind: "solid" as const,
    c1: "rgb(28, 28, 30)",
    c2: "rgb(28, 28, 30)",
    p1: { red: 0.11, green: 0.11, blue: 0.12, alpha: 1 },
    p2: { red: 0.11, green: 0.11, blue: 0.12, alpha: 1 },
  },
];

type AspectRatioOption = "automatic" | "square" | "landscape4x3" | "widescreen16x9" | "portrait9x16";

const ASPECT_RATIOS: Array<[AspectRatioOption, string, number | null]> = [
  ["automatic", "自适应", null],
  ["square", "1:1", 1],
  ["landscape4x3", "4:3", 4 / 3],
  ["widescreen16x9", "16:9", 16 / 9],
  ["portrait9x16", "9:16", 9 / 16],
];

function newId() {
  return `ann-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function strokeColor(annotation: Annotation) {
  const { red, green, blue, alpha } = annotation.style.color;
  return `rgba(${Math.round(red * 255)}, ${Math.round(green * 255)}, ${Math.round(blue * 255)}, ${alpha})`;
}

export default function ScreenshotEditor({
  item,
  busy,
  run,
}: {
  item: LibraryItem;
  mediaSrc: string | null;
  busy: boolean;
  run: (action: () => Promise<unknown>) => Promise<void>;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [tool, setTool] = useState<Tool>("rectangle");
  const [annotations, setAnnotations] = useState<Annotation[]>([]);
  const [redo, setRedo] = useState<Annotation[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [step, setStep] = useState(1);

  // 样式状态
  const [activeColor, setActiveColor] = useState(PRESET_COLORS[0].value);
  const [lineWidthMultiplier, setLineWidthMultiplier] = useState(1); // 1 = 标准, 0.6 = 细, 1.8 = 粗

  // 画布状态
  const [canvasOn, setCanvasOn] = useState(false);
  const [canvasTheme, setCanvasTheme] = useState(CANVAS_THEMES[0]);
  const [aspectRatio, setAspectRatio] = useState<AspectRatioOption>("automatic");
  const [paddingFraction, setPaddingFraction] = useState(0.08);
  const [textValue, setTextValue] = useState("注意");
  const [fontFraction, setFontFraction] = useState(0.045);
  const draftRef = useRef<Annotation | null>(null);

  // 状态反馈与结果展示
  const [statusMsg, setStatusMsg] = useState<string | null>(null);
  const [lastExportPath, setLastExportPath] = useState<string | null>(null);

  // 拖拽操作引用
  const dragRef = useRef<{
    start: Point;
    points: Point[];
    isMoving?: boolean;
    initialTarget?: Annotation;
  } | null>(null);

  useEffect(() => {
    let active = true;
    setCanvasOn(false);
    setAnnotations([]);
    setSelectedId(null);
    setLastExportPath(null);
    setCanvasTheme(CANVAS_THEMES[0]);
    setAspectRatio("automatic");
    setPaddingFraction(0.08);
    void loadScreenshotPlan(item.package_path)
      .then((plan) => {
        if (!active) return;
        const loaded = (plan?.annotations ?? []) as Annotation[];
        setAnnotations(loaded);
        setRedo([]);
        if (plan?.canvasStyle || plan?.canvas) {
          setCanvasOn(true);
          const saved = (plan.canvasStyle ?? plan.canvas) as { padding?: number; aspectRatio?: AspectRatioOption; primaryColor?: typeof PRESET_COLORS[number]["value"] };
          if (typeof saved.padding === "number") setPaddingFraction(Math.max(0, Math.min(0.3, saved.padding)));
          if (ASPECT_RATIOS.some(([ratio]) => ratio === saved.aspectRatio)) setAspectRatio(saved.aspectRatio!);
          const theme = CANVAS_THEMES.find(theme => saved.primaryColor && Math.abs(theme.p1.red - saved.primaryColor.red) < 0.01 && Math.abs(theme.p1.green - saved.primaryColor.green) < 0.01 && Math.abs(theme.p1.blue - saved.primaryColor.blue) < 0.01);
          if (theme) setCanvasTheme(theme);
        }
        setStep(loaded.filter((ann) => ann.kind === "step").length + 1);
      })
      .catch(() => {
        if (!active) return;
        setAnnotations([]);
      });
    return () => { active = false; };
  }, [item.id, item.package_path]);

  const showStatus = (msg: string) => {
    setStatusMsg(msg);
    setTimeout(() => setStatusMsg(null), 3500);
  };

  // 画布布局规划与重绘
  const paint = useCallback((includeSelection = true) => {
    const canvas = canvasRef.current;
    const image = imageRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx || !image) return;

    const imgW = image.naturalWidth;
    const imgH = image.naturalHeight;

    if (!canvasOn) {
      canvas.width = imgW;
      canvas.height = imgH;
      ctx.clearRect(0, 0, imgW, imgH);
      ctx.drawImage(image, 0, 0);
      ctx.save();
      for (const annotation of [...annotations, ...(draftRef.current ? [draftRef.current] : [])]) {
        drawAnnotation(ctx, annotation, imgW, imgH);
        if (includeSelection && annotation.id === selectedId) {
          drawSelectionBox(ctx, annotation);
        }
      }
      ctx.restore();
      return;
    }

    // 开启背景画布：计算自适应或比例约束
    const shortest = Math.min(imgW, imgH);
    const pad = Math.round(shortest * paddingFraction);
    const minW = imgW + pad * 2;
    const minH = imgH + pad * 2;

    const ratioMeta = ASPECT_RATIOS.find(([r]) => r === aspectRatio);
    const targetRatio = ratioMeta?.[2] ?? null;

    let outW = minW;
    let outH = minH;
    if (targetRatio != null) {
      if (outW / outH < targetRatio) {
        outW = Math.round(outH * targetRatio);
      } else {
        outH = Math.round(outW / targetRatio);
      }
    }

    canvas.width = outW;
    canvas.height = outH;

    // 绘制背景
    if (canvasTheme.kind === "gradient") {
      const grad = ctx.createLinearGradient(0, 0, outW, outH);
      grad.addColorStop(0, canvasTheme.c1);
      grad.addColorStop(1, canvasTheme.c2);
      ctx.fillStyle = grad;
    } else {
      ctx.fillStyle = canvasTheme.c1;
    }
    ctx.fillRect(0, 0, outW, outH);

    // 计算图像放置坐标（居中）
    const posX = Math.round((outW - imgW) / 2);
    const posY = Math.round((outH - imgH) / 2);
    const radius = Math.round(shortest * 0.025);

    // 绘制原图投影与圆角
    ctx.save();
    ctx.shadowColor = "rgba(0, 0, 0, 0.32)";
    ctx.shadowBlur = Math.round(shortest * 0.04);
    ctx.shadowOffsetY = Math.round(shortest * 0.02);

    ctx.beginPath();
    if (typeof ctx.roundRect === "function") {
      ctx.roundRect(posX, posY, imgW, imgH, radius);
    } else {
      ctx.rect(posX, posY, imgW, imgH);
    }
    ctx.fillStyle = "#fff";
    ctx.fill();
    ctx.restore();

    // 绘制原图裁切至圆角
    ctx.save();
    ctx.beginPath();
    if (typeof ctx.roundRect === "function") {
      ctx.roundRect(posX, posY, imgW, imgH, radius);
    } else {
      ctx.rect(posX, posY, imgW, imgH);
    }
    ctx.clip();
    ctx.drawImage(image, posX, posY);
    ctx.restore();

    // 绘制标注层（相对原图坐标偏移 posX, posY）
    ctx.save();
    ctx.translate(posX, posY);
    for (const annotation of [...annotations, ...(draftRef.current ? [draftRef.current] : [])]) {
      drawAnnotation(ctx, annotation, imgW, imgH);
      if (includeSelection && annotation.id === selectedId) {
        drawSelectionBox(ctx, annotation);
      }
    }
    ctx.restore();
  }, [annotations, canvasOn, canvasTheme, aspectRatio, paddingFraction, selectedId]);

  const paintRef = useRef(paint);
  paintRef.current = paint;
  useEffect(() => {
    let active = true;
    imageRef.current = null;
    const image = new Image();
    image.onload = () => {
      if (!active) return;
      imageRef.current = image;
      paintRef.current();
    };
    image.onerror = () => { if (active) setStatusMsg("原始截图加载失败，请重新打开素材。"); };
    void previewSrc(`${item.package_path}/raw/screenshot.png`).then(src => { if (active) image.src = src; }).catch(() => { if (active) setStatusMsg("无法读取原始截图。"); });
    return () => { active = false; };
  }, [item.package_path]);

  useEffect(() => {
    paint();
  }, [paint]);

  // 计算鼠标在原图坐标系下的点
  const pointFromEvent = (event: React.PointerEvent<HTMLCanvasElement>): Point => {
    const canvas = event.currentTarget;
    const rect = canvas.getBoundingClientRect();
    const image = imageRef.current;
    if (!image) return { x: 0, y: 0 };

    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    const rawX = (event.clientX - rect.left) * scaleX;
    const rawY = (event.clientY - rect.top) * scaleY;

    if (!canvasOn) {
      return { x: rawX, y: rawY };
    }

    const shortest = Math.min(image.naturalWidth, image.naturalHeight);
    const pad = Math.round(shortest * paddingFraction);
    const minW = image.naturalWidth + pad * 2;
    const minH = image.naturalHeight + pad * 2;

    const ratioMeta = ASPECT_RATIOS.find(([r]) => r === aspectRatio);
    const targetRatio = ratioMeta?.[2] ?? null;

    let outW = minW;
    let outH = minH;
    if (targetRatio != null) {
      if (outW / outH < targetRatio) {
        outW = Math.round(outH * targetRatio);
      } else {
        outH = Math.round(outW / targetRatio);
      }
    }

    const offsetX = (outW - image.naturalWidth) / 2;
    const offsetY = (outH - image.naturalHeight) / 2;
    return { x: rawX - offsetX, y: rawY - offsetY };
  };

  const commit = (annotation: Annotation) => {
    setAnnotations((current) => [...current, annotation]);
    setRedo([]);
    setSelectedId(annotation.id);
  };

  const deleteSelected = useCallback(() => {
    if (!selectedId) return;
    setAnnotations((current) => {
      const target = current.find((a) => a.id === selectedId);
      if (target) setRedo((r) => [...r, target]);
      return current.filter((item) => item.id !== selectedId);
    });
    setSelectedId(null);
  }, [selectedId]);

  const undo = useCallback(() => {
    setAnnotations((current) => {
      const next = current.slice(0, -1);
      const removed = current[current.length - 1];
      if (removed) setRedo((stack) => [...stack, removed]);
      return next;
    });
  }, []);

  const doRedo = useCallback(() => {
    setRedo((stack) => {
      const next = stack[stack.length - 1];
      if (next) setAnnotations((current) => [...current, next]);
      return stack.slice(0, -1);
    });
  }, []);

  // 复制当前画布位图到系统剪贴板
  const copyCanvas = useCallback(async () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    try {
      paint(false);
      const blob = await new Promise<Blob>((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new Error("无法生成图片")), "image/png"));
      await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })]);
      showStatus("✓ 已复制标注图至剪贴板");
    } catch {
      showStatus("复制失败，请重试");
    } finally {
      paint();
    }
  }, [paint]);

  // 保存非破坏性计划与预览图
  const handleSaveEdit = useCallback(async () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const plan = {
      schemaVersion: "0.3",
      annotations,
      canvasStyle: canvasOn
        ? {
            backgroundKind: canvasTheme.kind,
            primaryColor: canvasTheme.p1,
            secondaryColor: canvasTheme.p2,
            padding: paddingFraction,
            cornerRadius: 0.025,
            shadowRadius: 0.035,
            shadowOpacity: 0.32,
            aspectRatio,
          }
        : null,
    };
    await run(async () => {
      paint(false);
      const preview = canvas.toDataURL("image/png");
      paint();
      await saveScreenshotPlan(item.package_path, plan);
      await saveAnnotation(item.package_path, preview);
      showStatus("✓ 编辑已保存并更新预览");
    });
  }, [annotations, canvasOn, canvasTheme, aspectRatio, paddingFraction, item.package_path, run, paint]);

  // 导出 PNG
  const handleExportPng = useCallback(async () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    await run(async () => {
      paint(false);
      const dataUrl = canvas.toDataURL("image/png");
      paint();
      const savedPath = await exportScreenshot(item.package_path, dataUrl, "png");
      setLastExportPath(savedPath);
      showStatus(`✓ 成功导出 PNG`);
    });
  }, [item.package_path, run, paint]);

  // 导出 JPEG
  const handleExportJpeg = useCallback(async () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    await run(async () => {
      paint(false);
      const dataUrl = canvas.toDataURL("image/jpeg", 0.92);
      paint();
      const savedPath = await exportScreenshot(item.package_path, dataUrl, "jpeg");
      setLastExportPath(savedPath);
      showStatus(`✓ 成功导出 JPEG`);
    });
  }, [item.package_path, run, paint]);

  // 快捷键绑定 (Ctrl+Z, Ctrl+Shift+Z, Ctrl+S, Ctrl+C, Delete)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return;
      }
      if (e.key === "Delete" || e.key === "Backspace") {
        if (selectedId) {
          e.preventDefault();
          deleteSelected();
        }
      } else if (e.ctrlKey || e.metaKey) {
        if (e.key === "z" || e.key === "Z") {
          e.preventDefault();
          if (e.shiftKey) {
            doRedo();
          } else {
            undo();
          }
        } else if (e.key === "y" || e.key === "Y") {
          e.preventDefault();
          doRedo();
        } else if (e.key === "s" || e.key === "S") {
          e.preventDefault();
          void handleSaveEdit();
        } else if (e.key === "c" || e.key === "C") {
          if (!selectedId) {
            e.preventDefault();
            void copyCanvas();
          }
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [selectedId, deleteSelected, undo, doRedo, handleSaveEdit, copyCanvas]);

  return (
    <div className="screenshot-editor-container">
      {/* 顶部主工具栏 */}
      <div className="tool-row main-tools">
        {TOOLS.map(([id, label]) => (
          <button
            key={id}
            type="button"
            className={tool === id ? "primary" : undefined}
            onClick={() => {
              setTool(id);
              if (id !== "select") setSelectedId(null);
            }}
          >
            {label}
          </button>
        ))}
        <span className="tool-separator" />
        <button type="button" onClick={undo} disabled={annotations.length === 0} title="撤销 (Ctrl+Z)">
          撤销
        </button>
        <button type="button" onClick={doRedo} disabled={redo.length === 0} title="重做 (Ctrl+Shift+Z)">
          重做
        </button>
        <button
          type="button"
          className={canvasOn ? "primary" : undefined}
          onClick={() => setCanvasOn((v) => !v)}
          title="开关画布与背景外框"
        >
          {canvasOn ? "✓ 画布开启" : "画布"}
        </button>
        <span className="tool-separator" />
        <button type="button" disabled={busy} onClick={() => void copyCanvas()} title="复制图像 (Ctrl+C)">
          复制
        </button>
        <button type="button" className="primary" disabled={busy} onClick={() => void handleSaveEdit()} title="保存修改 (Ctrl+S)">
          保存修改
        </button>
        <button type="button" disabled={busy} onClick={() => void handleExportPng()} title="导出标准 PNG 文件">
          导出 PNG
        </button>
        <button type="button" disabled={busy} onClick={() => void handleExportJpeg()} title="导出高质量 JPEG 文件">
          导出 JPEG
        </button>
      </div>

      {/* 次级属性栏：颜色、线宽与画布配置 */}
      <div className="sub-tool-row">
        <label>自选颜色 <input type="color" aria-label="自选标注颜色" value={`#${[activeColor.red, activeColor.green, activeColor.blue].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("")}`} onChange={e => setActiveColor({red: parseInt(e.target.value.slice(1, 3), 16) / 255, green: parseInt(e.target.value.slice(3, 5), 16) / 255, blue: parseInt(e.target.value.slice(5, 7), 16) / 255, alpha: 1})} /></label>
        {tool === "text" && <label>文字 <input aria-label="标注文字" value={textValue} onChange={e => setTextValue(e.target.value)} /><span> 字号 </span><input aria-label="文字大小" type="range" min="0.015" max="0.12" step="0.005" value={fontFraction} onChange={e => setFontFraction(Number(e.target.value))} /></label>}
        <div className="color-picker-group">
          <span className="sub-label">颜色：</span>
          {PRESET_COLORS.map((c) => {
            const isSelected =
              activeColor.red === c.value.red &&
              activeColor.green === c.value.green &&
              activeColor.blue === c.value.blue;
            return (
              <button
                key={c.label}
                type="button"
                className={`color-dot ${isSelected ? "selected" : ""}`}
                style={{
                  background: `rgb(${c.value.red * 255}, ${c.value.green * 255}, ${c.value.blue * 255})`,
                }}
                onClick={() => setActiveColor(c.value)}
                title={c.label}
              />
            );
          })}
        </div>

        <div className="stroke-width-group">
          <span className="sub-label">线宽：</span>
          <button
            type="button"
            className={lineWidthMultiplier === 0.6 ? "primary" : undefined}
            onClick={() => setLineWidthMultiplier(0.6)}
          >
            细
          </button>
          <button
            type="button"
            className={lineWidthMultiplier === 1 ? "primary" : undefined}
            onClick={() => setLineWidthMultiplier(1)}
          >
            中
          </button>
          <button
            type="button"
            className={lineWidthMultiplier === 1.8 ? "primary" : undefined}
            onClick={() => setLineWidthMultiplier(1.8)}
          >
            粗
          </button>
        </div>

        {canvasOn && (
          <div className="canvas-options-group">
            <label>留白 {Math.round(paddingFraction * 100)}% <input aria-label="画布留白" type="range" min="0" max="0.3" step="0.01" value={paddingFraction} onChange={e => setPaddingFraction(Number(e.target.value))} /></label>
            <span className="sub-label">背景：</span>
            {CANVAS_THEMES.map((theme) => (
              <button
                key={theme.id}
                type="button"
                className={canvasTheme.id === theme.id ? "primary" : undefined}
                onClick={() => setCanvasTheme(theme)}
              >
                {theme.name}
              </button>
            ))}
            <span className="sub-label" style={{ marginLeft: 8 }}>比例：</span>
            {ASPECT_RATIOS.map(([r, label]) => (
              <button
                key={r}
                type="button"
                className={aspectRatio === r ? "primary" : undefined}
                onClick={() => setAspectRatio(r)}
              >
                {label}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* 提示与导出反馈 */}
      {statusMsg && <div className="editor-toast">{statusMsg}</div>}
      {lastExportPath && (
        <div className="export-success-bar">
          <span>文件已导出至：<code>{lastExportPath}</code></span>
          <button
            type="button"
            className="primary"
            onClick={() => void revealInExplorer(lastExportPath)}
          >
            在文件夹中查看
          </button>
          <button type="button" onClick={() => setLastExportPath(null)}>
            关闭
          </button>
        </div>
      )}

      {/* 画布渲染区域 */}
      <canvas
        ref={canvasRef}
        className="preview-canvas"
        onPointerDown={(event) => {
          if (event.button !== 0 || !imageRef.current || busy) return;
          event.currentTarget.setPointerCapture(event.pointerId);
          const point = pointFromEvent(event);
          if (tool === "select") {
            const hit = [...annotations].reverse().find((ann) => contains(ann, point));
            setSelectedId(hit?.id ?? null);
            if (hit) {
              dragRef.current = {
                start: point,
                points: [point],
                isMoving: true,
                initialTarget: JSON.parse(JSON.stringify(hit)),
              };
            }
            return;
          }
          dragRef.current = { start: point, points: [point], isMoving: false };
        }}
        onPointerMove={(event) => {
          if (!dragRef.current) return;
          const point = pointFromEvent(event);

          if (tool === "select") {
            if (dragRef.current.isMoving && dragRef.current.initialTarget) {
              const dx = point.x - dragRef.current.start.x;
              const dy = point.y - dragRef.current.start.y;
              const initial = dragRef.current.initialTarget;
              setAnnotations((current) =>
                current.map((ann) => {
                  if (ann.id !== initial.id) return ann;
                  return moveAnnotation(initial, dx, dy);
                }),
              );
            }
            return;
          }

          dragRef.current.points.push(point);
          if (tool !== "text" && tool !== "step") {
            const from = dragRef.current.start;
            draftRef.current = { id: "draft", kind: tool, bounds: { x: Math.min(from.x, point.x), y: Math.min(from.y, point.y), width: Math.abs(point.x - from.x), height: Math.abs(point.y - from.y) }, start: from, end: point, points: tool === "freehand" ? [...dragRef.current.points] : undefined, style: { lineWidth: 0.006 * lineWidthMultiplier, fontSize: fontFraction, color: activeColor, intensity: 0.035 } };
            paint();
          }
        }}
        onPointerUp={(event) => {
          if (!dragRef.current) return;
          const from = dragRef.current.start;
          const to = pointFromEvent(event);
          const points = dragRef.current.points;
          const isMoving = dragRef.current.isMoving;
          dragRef.current = null;
          draftRef.current = null;
          paint();

          if (tool === "select") {
            if (isMoving) {
              setRedo([]);
            }
            return;
          }

          const currentStyle = {
            lineWidth: 0.006 * lineWidthMultiplier,
            fontSize: fontFraction,
            color: activeColor,
            intensity: 0.035,
          };

          if (tool === "text") {
            const text = textValue;
            if (!text.trim()) return;
            commit({
              id: newId(),
              kind: "text",
              bounds: { x: from.x, y: from.y - 24, width: 160, height: 32 },
              start: from,
              text,
              style: currentStyle,
            });
            return;
          }

          if (tool === "step") {
            commit({
              id: newId(),
              kind: "step",
              bounds: { x: from.x - 16, y: from.y - 16, width: 32, height: 32 },
              start: from,
              text: String(step),
              style: currentStyle,
            });
            setStep((v) => v + 1);
            return;
          }

          const x = Math.min(from.x, to.x);
          const y = Math.min(from.y, to.y);
          const w = Math.abs(to.x - from.x);
          const h = Math.abs(to.y - from.y);

          // 忽略几乎没有拖动的微小点击
          if (tool !== "freehand" && w < 4 && h < 4) {
            return;
          }

          commit({
            id: newId(),
            kind: tool,
            bounds: { x, y, width: w, height: h },
            start: from,
            end: to,
            points: tool === "freehand" ? points : undefined,
            style: currentStyle,
          });
        }}
        onPointerCancel={() => { dragRef.current = null; draftRef.current = null; paint(); }}
        aria-label="截图标注画布"
      />

      {/* 底部对象状态 */}
      {selectedId ? (
        <div className="selected-bar">
          <span>已选中标注对象</span>
          <button type="button" className="danger" onClick={deleteSelected}>
            删除选中对象 (Delete)
          </button>
        </div>
      ) : null}
    </div>
  );
}

function moveAnnotation(initial: Annotation, dx: number, dy: number): Annotation {
  const next: Annotation = {
    ...initial,
    bounds: {
      ...initial.bounds,
      x: initial.bounds.x + dx,
      y: initial.bounds.y + dy,
    },
  };
  if (initial.start) {
    next.start = { x: initial.start.x + dx, y: initial.start.y + dy };
  }
  if (initial.end) {
    next.end = { x: initial.end.x + dx, y: initial.end.y + dy };
  }
  if (initial.points) {
    next.points = initial.points.map((p) => ({ x: p.x + dx, y: p.y + dy }));
  }
  return next;
}

function contains(annotation: Annotation, point: Point) {
  const { x, y, width, height } = annotation.bounds;
  const pad = 8;
  return (
    point.x >= x - pad &&
    point.x <= x + Math.max(width, 16) + pad &&
    point.y >= y - pad &&
    point.y <= y + Math.max(height, 16) + pad
  );
}

function drawSelectionBox(ctx: CanvasRenderingContext2D, annotation: Annotation) {
  const { x, y, width: w, height: h } = annotation.bounds;
  ctx.save();
  ctx.strokeStyle = "#38ef7d";
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);
  ctx.strokeRect(x - 4, y - 4, Math.max(w, 16) + 8, Math.max(h, 16) + 8);
  ctx.restore();
}

function drawAnnotation(
  ctx: CanvasRenderingContext2D,
  annotation: Annotation,
  width: number,
  height: number,
) {
  const shortest = Math.min(width, height);
  const line = Math.max(2.5, shortest * annotation.style.lineWidth);
  ctx.lineWidth = line;
  ctx.strokeStyle = strokeColor(annotation);
  ctx.fillStyle = strokeColor(annotation);
  const { x, y, width: w, height: h } = annotation.bounds;

  if (annotation.kind === "rectangle") {
    ctx.strokeRect(x, y, w, h);
  }

  if (annotation.kind === "ellipse") {
    ctx.beginPath();
    ctx.ellipse(x + w / 2, y + h / 2, Math.max(1, w / 2), Math.max(1, h / 2), 0, 0, Math.PI * 2);
    ctx.stroke();
  }

  if (annotation.kind === "arrow" && annotation.start && annotation.end) {
    const from = annotation.start;
    const to = annotation.end;
    ctx.beginPath();
    ctx.moveTo(from.x, from.y);
    ctx.lineTo(to.x, to.y);
    ctx.stroke();
    const angle = Math.atan2(to.y - from.y, to.x - from.x);
    const arrowSize = Math.max(14, shortest * 0.024);
    ctx.beginPath();
    ctx.moveTo(to.x, to.y);
    ctx.lineTo(
      to.x - arrowSize * Math.cos(angle - 0.45),
      to.y - arrowSize * Math.sin(angle - 0.45),
    );
    ctx.lineTo(
      to.x - arrowSize * Math.cos(angle + 0.45),
      to.y - arrowSize * Math.sin(angle + 0.45),
    );
    ctx.closePath();
    ctx.fill();
  }

  if (annotation.kind === "highlight") {
    ctx.fillStyle = "rgba(255, 214, 10, 0.38)";
    ctx.fillRect(x, y, w, h);
  }

  if (annotation.kind === "step" && annotation.start) {
    const r = Math.max(14, Math.round(shortest * 0.022));
    ctx.beginPath();
    ctx.arc(annotation.start.x, annotation.start.y, r, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "#fff";
    ctx.font = `bold ${Math.round(r * 1.1)}px "Segoe UI", system-ui, sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(annotation.text ?? "1", annotation.start.x, annotation.start.y);
  }

  if (annotation.kind === "text" && annotation.start) {
    const fontSize = Math.max(16, Math.round(shortest * annotation.style.fontSize));
    ctx.font = `600 ${fontSize}px "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif`;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(annotation.text ?? "", annotation.start.x, annotation.start.y);
  }

  if (annotation.kind === "freehand" && annotation.points && annotation.points.length > 1) {
    ctx.beginPath();
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.moveTo(annotation.points[0].x, annotation.points[0].y);
    for (const point of annotation.points.slice(1)) ctx.lineTo(point.x, point.y);
    ctx.stroke();
  }

  if ((annotation.kind === "blur" || annotation.kind === "pixelate") && w > 1 && h > 1) {
    try {
      const sample = ctx.getImageData(x, y, Math.max(1, Math.round(w)), Math.max(1, Math.round(h)));
      if (annotation.kind === "pixelate") {
        const block = Math.max(6, Math.round(shortest * 0.015));
        for (let py = 0; py < sample.height; py += block) {
          for (let px = 0; px < sample.width; px += block) {
            const i = (py * sample.width + px) * 4;
            for (let by = 0; by < block && py + by < sample.height; by++) {
              for (let bx = 0; bx < block && px + bx < sample.width; bx++) {
                const j = ((py + by) * sample.width + (px + bx)) * 4;
                sample.data[j] = sample.data[i];
                sample.data[j + 1] = sample.data[i + 1];
                sample.data[j + 2] = sample.data[i + 2];
              }
            }
          }
        }
      } else {
        // 盒式模糊优化
        for (let i = 0; i < sample.data.length; i += 16) {
          const avgR = (sample.data[i] + sample.data[i + 4] + sample.data[i + 8] + sample.data[i + 12]) / 4;
          const avgG = (sample.data[i + 1] + sample.data[i + 5] + sample.data[i + 9] + sample.data[i + 13]) / 4;
          const avgB = (sample.data[i + 2] + sample.data[i + 6] + sample.data[i + 10] + sample.data[i + 14]) / 4;
          for (let k = 0; k < 16; k += 4) {
            sample.data[i + k] = avgR;
            sample.data[i + k + 1] = avgG;
            sample.data[i + k + 2] = avgB;
          }
        }
      }
      ctx.putImageData(sample, x, y);
    } catch {
      // 忽略跨域像素读取异常
    }
  }
}
