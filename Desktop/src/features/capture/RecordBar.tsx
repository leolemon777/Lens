import { useEffect, useState } from "react";
import {
  discardRecording,
  getAppState,
  pauseRecording,
  stopRecording,
  type AppSnapshot,
} from "../../bridge/commands";

export default function RecordBar() {
  const [state, setState] = useState<AppSnapshot | null>(null);
  useEffect(() => {
    const tick = () => {
      void getAppState().then(setState).catch(() => undefined);
    };
    tick();
    const id = window.setInterval(tick, 250);
    return () => window.clearInterval(id);
  }, []);
  const seconds = Math.round((state?.recording_elapsed_ms || 0) / 1000);
  const clock = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  const diskGb = ((state?.disk_free_bytes ?? 0) / (1024 * 1024 * 1024)).toFixed(1);
  return (
    <main className="record-bar-window">
      <span className="rec-dot" />
      <strong>{state?.recording_paused ? "已暂停" : "录制中"}</strong>
      <span className="time">{clock}</span>
      <span
        className={`level ${state?.audio_system_enabled ? "" : "muted"}`}
        title={state?.audio_system_enabled ? "系统声音（开启）" : "系统声音（已静音）"}
      >
        <i style={{ width: `${state?.audio_system_enabled ? Math.round((state?.audio_peak_system ?? 0) * 100) : 0}%` }} />
      </span>
      <span
        className={`level ${state?.audio_mic_enabled ? "" : "muted"}`}
        title={state?.audio_mic_enabled ? "麦克风（开启）" : "麦克风（已静音）"}
      >
        <i style={{ width: `${state?.audio_mic_enabled ? Math.round((state?.audio_peak_mic ?? 0) * 100) : 0}%` }} />
      </span>
      {state?.camera_enabled ? (
        <span className="rec-tag camera" title="摄像头画中画/独立轨录制中">
          📷
        </span>
      ) : null}
      <small className={state?.disk_status === "ok" ? undefined : "warn"}>{diskGb} GiB</small>
      <button onClick={() => void pauseRecording(!state?.recording_paused)}>
        {state?.recording_paused ? "继续" : "暂停"}
      </button>
      <button className="stop" onClick={() => void stopRecording()}>
        停止
      </button>
      <button
        onClick={() => {
          if (window.confirm("丢弃这次录制并删除未完成项目？")) void discardRecording();
        }}
      >
        丢弃重录
      </button>
    </main>
  );
}
