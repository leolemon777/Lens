import { useCallback, useEffect, useRef, useState } from "react";
import { cancelRegionSelection, completeRegionSelection, listSnapEdges } from "../../bridge/commands";

interface Point {
  x: number;
  y: number;
}

interface DragState {
  origin: Point;
  current: Point;
  committed: boolean;
}

export default function Overlay() {
  const instantScreenshot = new URLSearchParams(window.location.search).get("mode") === "screenshot";
  const submitting = useRef(false);
  const [drag, setDrag] = useState<DragState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [edges, setEdges] = useState<number[][]>([]);
  const originRef = useRef<Point | null>(null);
  const altRef = useRef(false);

  useEffect(() => {
    void listSnapEdges().then(setEdges).catch(() => setEdges([]));
  }, []);

  const confirm = useCallback(async () => {
    if (!drag || submitting.current) return;
    if (Math.abs(drag.current.x - drag.origin.x) < 2 || Math.abs(drag.current.y - drag.origin.y) < 2) return;
    submitting.current = true;
    try {
      setError(null);
      await completeRegionSelection({
        origin_x: drag.origin.x,
        origin_y: drag.origin.y,
        current_x: drag.current.x,
        current_y: drag.current.y,
        device_pixel_ratio: window.devicePixelRatio || 1,
        confirmed_at_ms: Date.now(),
        alt_held: altRef.current,
      });
    } catch (cause) {
      submitting.current = false;
      setError(String(cause));
    }
  }, [drag]);

  useEffect(() => {
    if (instantScreenshot && drag?.committed) void confirm();
  }, [instantScreenshot, drag?.committed, confirm]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Alt") altRef.current = event.type === "keydown";
      if (event.key === "Escape") void cancelRegionSelection();
      if (event.key === "Enter") void confirm();
      if (!originRef.current && drag && ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) {
        event.preventDefault();
        const step = (event.shiftKey ? 10 : 1) / (window.devicePixelRatio || 1);
        const dx = event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0;
        const dy = event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0;
        setDrag((current) =>
          current
            ? {
                ...current,
                origin: { x: current.origin.x + dx, y: current.origin.y + dy },
                current: { x: current.current.x + dx, y: current.current.y + dy },
              }
            : current,
        );
      }
    };
    window.addEventListener("keydown", handler);
    window.addEventListener("keyup", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      window.removeEventListener("keyup", handler);
    };
  }, [confirm, drag]);

  const left = drag ? Math.min(drag.origin.x, drag.current.x) : 0;
  const top = drag ? Math.min(drag.origin.y, drag.current.y) : 0;
  const width = drag ? Math.abs(drag.current.x - drag.origin.x) : 0;
  const height = drag ? Math.abs(drag.current.y - drag.origin.y) : 0;
  const dpr = window.devicePixelRatio || 1;
  const toCss = (physical: number, origin: number) => physical / dpr - origin;
  const screenX = window.screenX || window.screenLeft || 0;
  const screenY = window.screenY || window.screenTop || 0;
  const guides = altRef.current || !drag
    ? []
    : edges.flatMap(([x1, y1, x2, y2]) => {
        const lines: Array<{ vertical?: number; horizontal?: number }> = [];
        const cx1 = toCss(x1, screenX);
        const cy1 = toCss(y1, screenY);
        const cx2 = toCss(x2, screenX);
        const cy2 = toCss(y2, screenY);
        if (Math.abs(left - cx1) <= 8 || Math.abs(left + width - cx1) <= 8) lines.push({ vertical: cx1 });
        if (Math.abs(left - cx2) <= 8 || Math.abs(left + width - cx2) <= 8) lines.push({ vertical: cx2 });
        if (Math.abs(top - cy1) <= 8 || Math.abs(top + height - cy1) <= 8) lines.push({ horizontal: cy1 });
        if (Math.abs(top - cy2) <= 8 || Math.abs(top + height - cy2) <= 8) lines.push({ horizontal: cy2 });
        return lines;
      });

  return (
    <main
      className="selection-surface"
      onPointerDown={(event) => {
        if (event.button !== 0 || submitting.current) return;
        event.currentTarget.setPointerCapture(event.pointerId);
        const point = { x: event.clientX, y: event.clientY };
        originRef.current = point;
        setDrag({ origin: point, current: point, committed: false });
      }}
      onPointerMove={(event) => {
        const origin = originRef.current;
        if (!origin) return;
        setDrag({ origin, current: { x: event.clientX, y: event.clientY }, committed: false });
      }}
      onPointerUp={(event) => {
        if (!originRef.current || submitting.current) return;
        setDrag((current) => (current ? { ...current, current: { x: event.clientX, y: event.clientY }, committed: true } : current));
        originRef.current = null;
      }}
    >
      {drag ? (
        <>
          <div
            className="selection-rectangle"
            style={{ left, top, width, height }}
          />
          <div className="selection-size" style={{ left, top: Math.max(12, top - 28) }}>
            {Math.round(width)} × {Math.round(height)}
          </div>
          {guides.map((guide, index) =>
            guide.vertical != null ? (
              <div key={`v-${index}`} className="snap-guide vertical" style={{ left: guide.vertical }} />
            ) : (
              <div key={`h-${index}`} className="snap-guide horizontal" style={{ top: guide.horizontal }} />
            ),
          )}
        </>
      ) : (
        <p className="overlay-hint">{instantScreenshot ? "拖动截屏，松手完成 · Esc 取消" : "拖拽选择区域 · Enter 确认 · Esc 取消"}</p>
      )}
      {error ? <div className="selection-error">{error}</div> : null}
      {drag?.committed && !instantScreenshot ? (
        <div className="selection-actions">
          <button type="button" className="primary" onPointerDown={(e) => e.stopPropagation()} onClick={() => void confirm()}>
            确认
          </button>
          <button type="button" onPointerDown={(e) => e.stopPropagation()} onClick={() => void cancelRegionSelection()}>
            取消
          </button>
        </div>
      ) : null}
    </main>
  );
}
