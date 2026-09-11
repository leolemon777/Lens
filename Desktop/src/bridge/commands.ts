export type OverlayMode = "screenshot" | "record" | "scrolling";

export interface LibraryItem {
  id: string;
  kind: string;
  title: string;
  state: string;
  created_at: string;
  package_path: string;
  preview_path: string | null;
  duration_seconds: number | null;
  width: number | null;
  height: number | null;
  search_text?: string;
}

export interface CaptionCue {
  startSeconds: number;
  endSeconds: number;
  text: string;
}

export interface PackageInspect {
  schemaVersion: string;
  kind: string;
  title: string;
  writable: boolean;
  assets: Array<{
    relativePath: string;
    container: string;
    readable: boolean;
    note: string;
    byteLen: number;
  }>;
}

export interface CaptureExclusion {
  status: "excluded" | "fallback";
  reason?: string;
}

export interface AppSnapshot {
  library_root: string;
  dpi_awareness: string;
  recording: boolean;
  recording_paused: boolean;
  recording_elapsed_ms: number;
  capture_exclusion: CaptureExclusion | null;
  last_item: LibraryItem | null;
  items: LibraryItem[];
  scrolling: boolean;
  scroll_frames: number;
  camera_count: number;
  camera_message: string;
  disk_free_bytes: number;
  disk_status: string;
  audio_peak_system: number;
  audio_peak_mic: number;
  recording_fps: number;
  audio_system_enabled: boolean;
  audio_mic_enabled: boolean;
  camera_enabled: boolean;
  audio_system_device_id: string | null;
  audio_mic_device_id: string | null;
  camera_device_link: string | null;
}

export interface AudioDeviceInfo {
  id: string;
  name: string;
  is_default: boolean;
  flow: "render" | "capture";
}

export interface VideoCaptureDeviceInfo {
  name: string;
  symbolic_link: string;
}

export interface VideoEditTimeline {
  schemaVersion: string;
  segments: Array<{
    id: string;
    sourceStartSeconds: number;
    sourceEndSeconds: number;
    playbackRate: number;
    isEnabled: boolean;
    transition?: string;
  }>;
}

export interface OverlayDrag {
  origin_x: number;
  origin_y: number;
  current_x: number;
  current_y: number;
  device_pixel_ratio: number;
  confirmed_at_ms: number;
  alt_held?: boolean;
}

export interface WindowInfo {
  hwnd: number;
  title: string;
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface OcrDocument {
  schemaVersion: string;
  engine: string;
  fullText: string;
  blocks: Array<{ text: string }>;
}

async function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke: call } = await import("@tauri-apps/api/core");
  return call<T>(command, args);
}

export const getAppState = () => invoke<AppSnapshot>("get_app_state");
export const setLibraryRoot = (path: string) => invoke<AppSnapshot>("set_library_root", { path });
export const openRegionOverlay = (mode: OverlayMode) => invoke<void>("open_region_overlay", { mode });
export const captureDisplay = () => invoke<LibraryItem>("capture_display");
export const completeRegionSelection = (drag: OverlayDrag) =>
  invoke<LibraryItem>("complete_region_selection", { drag });
export const cancelRegionSelection = () => invoke<void>("cancel_region_selection");
export const startDisplayRecording = () => invoke<LibraryItem>("start_display_recording");
export const startWindowRecording = (hwnd: number) =>
  invoke<LibraryItem>("start_window_recording", { hwnd });
export const stopRecording = () => invoke<LibraryItem>("stop_recording");
export const pauseRecording = (paused: boolean) => invoke<AppSnapshot>("pause_recording", { paused });
export const listWindows = () => invoke<WindowInfo[]>("list_windows");
export const listSnapEdges = () => invoke<number[][]>("list_snap_edges");
export const captureWindow = (hwnd: number) => invoke<LibraryItem>("capture_window", { hwnd });
export const scrollingTick = () => invoke<number>("scrolling_tick");
export const finishScrolling = () => invoke<LibraryItem>("finish_scrolling");
export const recognizeOcr = (packagePath: string) =>
  invoke<OcrDocument>("recognize_ocr", { package: packagePath });
export const deleteItem = (packagePath: string) => invoke<void>("delete_item", { package: packagePath });
export const exportVideo = (packagePath: string, preset: string, taskId: string) =>
  invoke<string>("export_video", { package: packagePath, preset, taskId });
export const cancelMediaTask = (taskId: string) =>
  invoke<boolean>("cancel_media_task", { taskId });
export const mediaTaskStatus = (taskId: string) =>
  invoke<"running" | "cancelling" | "notFound">("media_task_status", { taskId });
export const pinLast = () => invoke<void>("pin_last");
export const saveAnnotation = (packagePath: string, pngBase64: string) =>
  invoke<string>("save_annotation", { package: packagePath, pngBase64 });
export const saveScreenshotPlan = (packagePath: string, plan: unknown) =>
  invoke<void>("save_screenshot_plan", { package: packagePath, plan });
export const saveTimeline = (packagePath: string, timeline: VideoEditTimeline) =>
  invoke<void>("save_timeline", { package: packagePath, timeline });
export const renderEdit = (packagePath: string, timeline: VideoEditTimeline, taskId: string) =>
  invoke<string>("render_edit", { package: packagePath, timeline, taskId });
export const loadScreenshotPlan = (packagePath: string) =>
  invoke<Record<string, unknown> | null>("load_screenshot_plan", { package: packagePath });
export const loadCaptions = (packagePath: string) =>
  invoke<CaptionCue[]>("load_captions", { package: packagePath });
export const loadTranscriptionStatus = (packagePath: string) =>
  invoke<{ status: string; message: string } | null>("load_transcription_status", { package: packagePath });
export const saveCaptions = (packagePath: string, cues: CaptionCue[]) =>
  invoke<void>("save_captions", { package: packagePath, cues });
export const loadTimeline = (packagePath: string) =>
  invoke<VideoEditTimeline | null>("load_timeline", { package: packagePath });
export const inspectPackage = (packagePath: string) =>
  invoke<PackageInspect>("inspect_package", { package: packagePath });
export const captureWindowsComposite = (hwnds: number[]) =>
  invoke<LibraryItem>("capture_windows_composite", { hwnds });
export const discardRecording = () => invoke<void>("discard_recording");
export const setRecordingFps = (fps: number) => invoke<AppSnapshot>("set_recording_fps", { fps });
export const cancelScrolling = () => invoke<void>("cancel_scrolling");
export const exportScreenshot = (
  packagePath: string,
  dataUrl: string,
  format: "png" | "jpeg",
  targetPath?: string,
) =>
  invoke<string>("export_screenshot", {
    package: packagePath,
    dataUrl,
    format,
    targetPath,
  });
export const revealInExplorer = (path: string) =>
  invoke<void>("reveal_in_explorer", { path });
export const previewSrc = async (path: string) => {
  if (/\.(mp4|webm|mov|m4v)$/i.test(path)) {
    const { convertFileSrc } = await import("@tauri-apps/api/core");
    return convertFileSrc(path);
  }
  return invoke<string>("preview_src", { path });
};
export const openLibrary = () => invoke<void>("open_library");
export const openQuickAccess = () => invoke<void>("open_quick_access");
export const openRecordBar = () => invoke<void>("open_record_bar_cmd");
export const listAudioDevices = () => invoke<AudioDeviceInfo[]>("list_audio_devices");
export const listCameraDevices = () => invoke<VideoCaptureDeviceInfo[]>("list_camera_devices");
export const setRecordingAudioConfig = (
  enableSystem: boolean,
  enableMic: boolean,
  systemDeviceId?: string | null,
  micDeviceId?: string | null,
) =>
  invoke<AppSnapshot>("set_recording_audio_config", {
    enableSystem,
    enableMic,
    systemDeviceId: systemDeviceId ?? null,
    micDeviceId: micDeviceId ?? null,
  });
export const setRecordingCameraConfig = (
  enableCamera: boolean,
  cameraDeviceLink?: string | null,
) =>
  invoke<AppSnapshot>("set_recording_camera_config", {
    enableCamera,
    cameraDeviceLink: cameraDeviceLink ?? null,
  });

export interface CameraKeyframe {
  time: number;
  scale: number;
  center: { x: number; y: number };
  easing: string;
  reason: string;
}

export interface CameraPipConfig {
  isEnabled: boolean;
  position: "bottomRight" | "bottomLeft" | "topRight" | "topLeft";
  scale: number;
  shape: "circle" | "roundedRect";
}

export interface AudioEnhanceConfig {
  duckingEnabled: boolean;
  duckingAttenuationDb: number;
  normalizeEnabled: boolean;
}

export interface AutoEditPlan {
  schemaVersion: string;
  preset: string;
  camera: {
    mode: string;
    zoomScale: number;
    keyframes: CameraKeyframe[];
    pip?: CameraPipConfig;
  };
  captions: {
    isEnabled: boolean;
    maxCharactersPerCue: number;
    cues: CaptionCue[];
  };
  timeline: VideoEditTimeline;
  audio?: AudioEnhanceConfig;
}

export const loadAutoEditPlan = (packagePath: string) =>
  invoke<AutoEditPlan | null>("load_auto_edit_plan", { package: packagePath });

export const saveAutoEditPlan = (packagePath: string, plan: AutoEditPlan) =>
  invoke<void>("save_auto_edit_plan", { package: packagePath, plan });
