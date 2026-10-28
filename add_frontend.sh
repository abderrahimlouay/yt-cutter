#!/usr/bin/env bash
# add_frontend.sh - writes the React + TypeScript frontend into the yt-cutter scaffold.
# Run from the yt-cutter project root:  bash add_frontend.sh
set -euo pipefail

ROOT="${1:-.}"
F="$ROOT/frontend"

[ -f "$F/package.json" ] || { echo "Run this from the yt-cutter project root (frontend/package.json not found)." >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm is required." >&2; exit 1; }

echo "[*] Writing frontend files"
mkdir -p "$F/src/components" "$F/src/hooks" "$F/src/lib"

# ------------------------------------------------------------------ vite config
# 127.0.0.1 (not "localhost") avoids Node resolving to IPv6 while uvicorn listens on IPv4.
cat > "$F/vite.config.ts" <<'EOF'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:8000",
    },
  },
});
EOF

# ------------------------------------------------------------------ types + limits
cat > "$F/src/types.ts" <<'EOF'
export type Format = "mp4" | "mp3";
export type Quality = 360 | 480 | 720 | 1080;
export type JobStatus = "queued" | "downloading" | "processing" | "done" | "error";

export interface VideoInfo {
  id: string;
  title: string;
  duration: number;
  thumbnail: string | null;
}

export interface JobEvent {
  id: string;
  status: JobStatus;
  progress: number;
  message: string | null;
  filename: string | null;
  duration: number | null;
}

export interface CutOptions {
  format: Format;
  quality: Quality;
  accurate: boolean;
}

export interface CutRequest extends CutOptions {
  url: string;
  start: number;
  end: number;
}
EOF

cat > "$F/src/lib/limits.ts" <<'EOF'
// Keep in sync with YTCUTTER_MAX_CLIP_SECONDS on the backend (the server is the real enforcer).
// Override at build time with VITE_MAX_CLIP_SECONDS.
export const MAX_CLIP_SECONDS = Number(import.meta.env.VITE_MAX_CLIP_SECONDS ?? 600);
export const MIN_CLIP_SECONDS = 1;
export const DEFAULT_CLIP_SECONDS = 30;
EOF

# ------------------------------------------------------------------ lib/time.ts
cat > "$F/src/lib/time.ts" <<'EOF'
/** 65 -> "1:05", 3723 -> "1:02:03" */
export function formatTime(totalSeconds: number): string {
  const s = Math.max(0, Math.round(totalSeconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

/** "90" -> 90, "1:30" -> 90, "1:02:03" -> 3723. Returns null if the text is not a valid time. */
export function parseTime(input: string): number | null {
  const text = input.trim();
  if (!text) return null;

  const parts = text.split(":");
  if (parts.length > 3) return null;

  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    const isLast = i === parts.length - 1;
    const valid = isLast ? /^\d+(\.\d+)?$/.test(part) : /^\d+$/.test(part);
    if (!valid) return null;
    const value = Number(part);
    if (i > 0 && value >= 60) return null; // "1:75" is not a time
    total = total * 60 + value;
  }
  return total;
}
EOF

cat > "$F/src/lib/time.test.ts" <<'EOF'
import { describe, expect, it } from "vitest";
import { formatTime, parseTime } from "./time";

describe("formatTime", () => {
  it("formats minutes and seconds", () => {
    expect(formatTime(0)).toBe("0:00");
    expect(formatTime(65)).toBe("1:05");
    expect(formatTime(600)).toBe("10:00");
  });
  it("formats hours", () => {
    expect(formatTime(3723)).toBe("1:02:03");
  });
  it("never goes negative", () => {
    expect(formatTime(-5)).toBe("0:00");
  });
});

describe("parseTime", () => {
  it("parses plain seconds", () => {
    expect(parseTime("90")).toBe(90);
    expect(parseTime(" 12.5 ")).toBe(12.5);
  });
  it("parses mm:ss and hh:mm:ss", () => {
    expect(parseTime("1:30")).toBe(90);
    expect(parseTime("90:00")).toBe(5400);
    expect(parseTime("1:02:03")).toBe(3723);
  });
  it("rejects invalid input", () => {
    for (const bad of ["", "abc", "-5", "1:75", "1:2:3:4", "1.5:30", "1::2", ":"]) {
      expect(parseTime(bad)).toBeNull();
    }
  });
});
EOF

# ------------------------------------------------------------------ lib/api.ts
cat > "$F/src/lib/api.ts" <<'EOF'
import type { CutRequest, JobEvent, VideoInfo } from "../types";

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong";
}

async function readError(res: Response): Promise<string> {
  try {
    const body = await res.json();
    if (typeof body?.detail === "string") return body.detail;
    if (typeof body?.error === "string" && !body.error.startsWith("Rate limit")) return body.error;
  } catch {
    // body was not JSON
  }
  if (res.status === 429) return "Too many requests, please wait a minute and try again.";
  if (res.status === 422) return "Invalid input.";
  return `Request failed (${res.status})`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") throw error;
    throw new ApiError("Cannot reach the server. Is the backend running?", 0);
  }
  if (!res.ok) throw new ApiError(await readError(res), res.status);
  return (await res.json()) as T;
}

function postJson<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
  return request<T>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
}

export const fetchInfo = (url: string, signal?: AbortSignal) =>
  postJson<VideoInfo>("/api/info", { url }, signal);

export const startCut = (req: CutRequest) =>
  postJson<{ job_id: string }>("/api/cut", req);

export const getJob = (jobId: string) =>
  request<JobEvent>(`/api/jobs/${encodeURIComponent(jobId)}`);

export const jobEventsUrl = (jobId: string) =>
  `/api/jobs/${encodeURIComponent(jobId)}/events`;

export const jobDownloadUrl = (jobId: string) =>
  `/api/jobs/${encodeURIComponent(jobId)}/download`;
EOF

# ------------------------------------------------------------------ hooks
cat > "$F/src/hooks/useVideoInfo.ts" <<'EOF'
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchInfo, messageOf } from "../lib/api";
import type { VideoInfo } from "../types";

export type VideoState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; url: string; info: VideoInfo }
  | { status: "error"; message: string };

export function useVideoInfo() {
  const [state, setState] = useState<VideoState>({ status: "idle" });
  const controller = useRef<AbortController | null>(null);

  const load = useCallback(async (url: string) => {
    controller.current?.abort();
    const ctrl = new AbortController();
    controller.current = ctrl;
    setState({ status: "loading" });
    try {
      const info = await fetchInfo(url, ctrl.signal);
      if (!ctrl.signal.aborted) setState({ status: "ready", url, info });
    } catch (error) {
      if (!ctrl.signal.aborted) setState({ status: "error", message: messageOf(error) });
    }
  }, []);

  const reset = useCallback(() => {
    controller.current?.abort();
    setState({ status: "idle" });
  }, []);

  useEffect(() => () => controller.current?.abort(), []);

  return { state, load, reset };
}
EOF

cat > "$F/src/hooks/useJob.ts" <<'EOF'
import { useCallback, useEffect, useRef, useState } from "react";
import { jobEventsUrl, messageOf, startCut } from "../lib/api";
import type { CutRequest, JobEvent, JobStatus } from "../types";

export type JobState =
  | { phase: "idle" }
  | { phase: "starting" }
  | { phase: "running"; jobId: string; status: JobStatus; progress: number }
  | { phase: "done"; jobId: string; filename: string | null }
  | { phase: "error"; message: string };

/** Starts a cut job and follows its progress over Server-Sent Events. */
export function useJob() {
  const [state, setState] = useState<JobState>({ phase: "idle" });
  const source = useRef<EventSource | null>(null);

  const close = useCallback(() => {
    source.current?.close();
    source.current = null;
  }, []);

  const start = useCallback(
    async (request: CutRequest) => {
      close();
      setState({ phase: "starting" });

      let jobId: string;
      try {
        jobId = (await startCut(request)).job_id;
      } catch (error) {
        setState({ phase: "error", message: messageOf(error) });
        return;
      }

      setState({ phase: "running", jobId, status: "queued", progress: 0 });
      const es = new EventSource(jobEventsUrl(jobId));
      source.current = es;

      es.onmessage = (msg) => {
        if (source.current !== es) return; // a newer job replaced this one
        let event: JobEvent;
        try {
          event = JSON.parse(msg.data) as JobEvent;
        } catch {
          return;
        }
        if (event.status === "done") {
          close();
          setState({ phase: "done", jobId, filename: event.filename });
        } else if (event.status === "error") {
          close();
          setState({ phase: "error", message: event.message ?? "The job failed" });
        } else {
          setState({ phase: "running", jobId, status: event.status, progress: event.progress });
        }
      };

      es.onerror = () => {
        if (source.current !== es) return;
        // CONNECTING means the browser is retrying; the server resends the current state on reconnect.
        if (es.readyState === EventSource.CLOSED) {
          close();
          setState({ phase: "error", message: "Lost connection to the server" });
        }
      };
    },
    [close],
  );

  const reset = useCallback(() => {
    close();
    setState({ phase: "idle" });
  }, [close]);

  useEffect(() => close, [close]);

  return { state, start, reset };
}
EOF

# ------------------------------------------------------------------ components
cat > "$F/src/components/UrlForm.tsx" <<'EOF'
import { useState, type FormEvent } from "react";

interface Props {
  loading: boolean;
  error: string | null;
  onSubmit: (url: string) => void;
}

export default function UrlForm({ loading, error, onSubmit }: Props) {
  const [url, setUrl] = useState("");

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (url.trim()) onSubmit(url.trim());
  };

  return (
    <form onSubmit={submit}>
      <div className="row">
        <input
          type="text"
          inputMode="url"
          autoComplete="off"
          spellCheck={false}
          placeholder="Paste a YouTube link"
          aria-label="YouTube URL"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
        <button className="button primary" type="submit" disabled={loading || !url.trim()}>
          {loading ? "Loading…" : "Load video"}
        </button>
      </div>
      {error && (
        <div className="error" role="alert">
          {error}
        </div>
      )}
    </form>
  );
}
EOF

cat > "$F/src/components/VideoPreview.tsx" <<'EOF'
import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";

export interface PreviewHandle {
  /** Jump to a time and pause. */
  seek: (seconds: number) => void;
  /** Play from `start` and pause automatically at `end`. */
  playRange: (start: number, end: number) => void;
}

interface Props {
  videoId: string;
}

const ORIGIN = "https://www.youtube-nocookie.com";

/** YouTube embed controlled through postMessage (no extra script needed). */
const VideoPreview = forwardRef<PreviewHandle, Props>(function VideoPreview({ videoId }, ref) {
  const frame = useRef<HTMLIFrameElement>(null);
  const timer = useRef<number | undefined>(undefined);

  const send = (func: string, args: unknown[] = []) => {
    frame.current?.contentWindow?.postMessage(JSON.stringify({ event: "command", func, args }), ORIGIN);
  };

  useImperativeHandle(ref, () => ({
    seek(seconds) {
      window.clearTimeout(timer.current);
      send("seekTo", [seconds, true]);
      send("pauseVideo");
    },
    playRange(start, end) {
      window.clearTimeout(timer.current);
      send("seekTo", [start, true]);
      send("playVideo");
      timer.current = window.setTimeout(() => send("pauseVideo"), Math.max(0, end - start) * 1000);
    },
  }));

  useEffect(() => () => window.clearTimeout(timer.current), []);

  return (
    <div className="preview">
      <iframe
        ref={frame}
        title="Video preview"
        src={`${ORIGIN}/embed/${encodeURIComponent(videoId)}?enablejsapi=1&rel=0&playsinline=1`}
        allow="accelerometer; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />
    </div>
  );
});

export default VideoPreview;
EOF

cat > "$F/src/components/RangeSlider.tsx" <<'EOF'
import { useEffect, useState } from "react";
import { MIN_CLIP_SECONDS } from "../lib/limits";
import { formatTime, parseTime } from "../lib/time";

interface Props {
  duration: number;
  start: number;
  end: number;
  maxClip: number;
  disabled?: boolean;
  onChange: (start: number, end: number) => void;
  /** Called when the user finishes moving a handle, so the preview can jump there. */
  onSeek?: (seconds: number) => void;
}

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), max);

export default function RangeSlider({ duration, start, end, maxClip, disabled, onChange, onSeek }: Props) {
  const max = Math.floor(duration);

  // Moving one handle keeps the clip between MIN_CLIP_SECONDS and maxClip by pushing the other handle.
  const moveStart = (value: number): [number, number] => {
    const s = clamp(Math.round(value), 0, Math.max(0, max - MIN_CLIP_SECONDS));
    let e = end;
    if (e - s < MIN_CLIP_SECONDS) e = Math.min(max, s + MIN_CLIP_SECONDS);
    if (e - s > maxClip) e = s + maxClip;
    return [s, e];
  };

  const moveEnd = (value: number): [number, number] => {
    const e = clamp(Math.round(value), Math.min(MIN_CLIP_SECONDS, max), max);
    let s = start;
    if (e - s < MIN_CLIP_SECONDS) s = Math.max(0, e - MIN_CLIP_SECONDS);
    if (e - s > maxClip) s = e - maxClip;
    return [s, e];
  };

  const dragStart = (value: number) => onChange(...moveStart(value));
  const dragEnd = (value: number) => onChange(...moveEnd(value));

  const commitStart = (value: number) => {
    const [s, e] = moveStart(value);
    onChange(s, e);
    onSeek?.(s);
  };
  const commitEnd = (value: number) => {
    const [s, e] = moveEnd(value);
    onChange(s, e);
    onSeek?.(e);
  };

  const startPct = max > 0 ? (start / max) * 100 : 0;
  const endPct = max > 0 ? (end / max) * 100 : 100;

  return (
    <div>
      <div className="range">
        <div className="range-track">
          <div className="range-fill" style={{ left: `${startPct}%`, width: `${endPct - startPct}%` }} />
        </div>
        <input
          type="range"
          min={0}
          max={max}
          step={1}
          value={start}
          disabled={disabled}
          aria-label="Start time"
          aria-valuetext={formatTime(start)}
          style={{ zIndex: start > max / 2 ? 5 : 3 }}
          onChange={(e) => dragStart(Number(e.target.value))}
          onPointerUp={() => onSeek?.(start)}
          onKeyUp={() => onSeek?.(start)}
        />
        <input
          type="range"
          min={0}
          max={max}
          step={1}
          value={end}
          disabled={disabled}
          aria-label="End time"
          aria-valuetext={formatTime(end)}
          style={{ zIndex: 4 }}
          onChange={(e) => dragEnd(Number(e.target.value))}
          onPointerUp={() => onSeek?.(end)}
          onKeyUp={() => onSeek?.(end)}
        />
      </div>

      <div className="time-fields">
        <TimeField label="Start" value={start} disabled={disabled} onCommit={commitStart} />
        <TimeField label="End" value={end} disabled={disabled} onCommit={commitEnd} />
        <span className="muted clip-length">
          Clip length {formatTime(end - start)} (max {formatTime(maxClip)})
        </span>
      </div>
    </div>
  );
}

interface TimeFieldProps {
  label: string;
  value: number;
  disabled?: boolean;
  onCommit: (seconds: number) => void;
}

function TimeField({ label, value, disabled, onCommit }: TimeFieldProps) {
  const [draft, setDraft] = useState(formatTime(value));

  useEffect(() => {
    setDraft(formatTime(value));
  }, [value]);

  const commit = () => {
    const parsed = parseTime(draft);
    if (parsed !== null) onCommit(parsed);
    setDraft(formatTime(value)); // resynced by the effect above if the value changed
  };

  return (
    <label className="field">
      {label}
      <input
        type="text"
        inputMode="numeric"
        value={draft}
        disabled={disabled}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === "Enter") e.currentTarget.blur();
        }}
      />
    </label>
  );
}
EOF

cat > "$F/src/components/FormatPicker.tsx" <<'EOF'
import type { CutOptions, Format, Quality } from "../types";

const FORMATS: Format[] = ["mp4", "mp3"];
const QUALITIES: Quality[] = [360, 480, 720, 1080];

interface Props {
  value: CutOptions;
  onChange: (next: CutOptions) => void;
  disabled?: boolean;
}

export default function FormatPicker({ value, onChange, disabled }: Props) {
  return (
    <div className="options">
      <div className="segmented" role="radiogroup" aria-label="Format">
        {FORMATS.map((format) => (
          <label key={format} className={value.format === format ? "active" : ""}>
            <input
              type="radio"
              name="format"
              value={format}
              checked={value.format === format}
              disabled={disabled}
              onChange={() => onChange({ ...value, format })}
            />
            {format.toUpperCase()}
          </label>
        ))}
      </div>

      <label className="field inline">
        Quality
        <select
          value={value.quality}
          disabled={disabled || value.format === "mp3"}
          onChange={(e) => onChange({ ...value, quality: Number(e.target.value) as Quality })}
        >
          {QUALITIES.map((q) => (
            <option key={q} value={q}>
              {q}p
            </option>
          ))}
        </select>
      </label>

      <label className="check">
        <input
          type="checkbox"
          checked={value.accurate}
          disabled={disabled}
          onChange={(e) => onChange({ ...value, accurate: e.target.checked })}
        />
        Frame-accurate (slower)
      </label>
    </div>
  );
}
EOF

cat > "$F/src/components/ProgressBar.tsx" <<'EOF'
import type { JobStatus } from "../types";

interface Props {
  status: JobStatus;
  progress: number;
}

const LABELS: Record<JobStatus, string> = {
  queued: "Waiting in the queue…",
  downloading: "Cutting the clip…",
  processing: "Finishing up…",
  done: "Done",
  error: "Failed",
};

export default function ProgressBar({ status, progress }: Props) {
  // yt-dlp does not always report percentages while cutting a section
  const indeterminate = status === "queued" || (status === "downloading" && progress === 0);

  return (
    <div>
      <div className="progress-label">
        <span>{LABELS[status]}</span>
        {!indeterminate && <span>{progress}%</span>}
      </div>
      <div
        className={`progress${indeterminate ? " indeterminate" : ""}`}
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={indeterminate ? undefined : progress}
        aria-label={LABELS[status]}
      >
        <div className="progress-fill" style={indeterminate ? undefined : { width: `${progress}%` }} />
      </div>
    </div>
  );
}
EOF

cat > "$F/src/components/DownloadButton.tsx" <<'EOF'
import { jobDownloadUrl } from "../lib/api";

interface Props {
  jobId: string;
  filename: string | null;
}

export default function DownloadButton({ jobId, filename }: Props) {
  return (
    <a className="button primary" href={jobDownloadUrl(jobId)} download={filename ?? undefined}>
      Download{filename ? ` ${filename}` : ""}
    </a>
  );
}
EOF

# ------------------------------------------------------------------ App + entry + styles
cat > "$F/src/App.tsx" <<'EOF'
import { useEffect, useRef, useState } from "react";
import DownloadButton from "./components/DownloadButton";
import FormatPicker from "./components/FormatPicker";
import ProgressBar from "./components/ProgressBar";
import RangeSlider from "./components/RangeSlider";
import UrlForm from "./components/UrlForm";
import VideoPreview, { type PreviewHandle } from "./components/VideoPreview";
import { useJob } from "./hooks/useJob";
import { useVideoInfo } from "./hooks/useVideoInfo";
import { DEFAULT_CLIP_SECONDS, MAX_CLIP_SECONDS, MIN_CLIP_SECONDS } from "./lib/limits";
import type { CutOptions } from "./types";

export default function App() {
  const { state: video, load } = useVideoInfo();
  const job = useJob();
  const preview = useRef<PreviewHandle>(null);

  const [range, setRange] = useState({ start: 0, end: DEFAULT_CLIP_SECONDS });
  const [options, setOptions] = useState<CutOptions>({ format: "mp4", quality: 720, accurate: true });

  const info = video.status === "ready" ? video.info : null;
  const videoUrl = video.status === "ready" ? video.url : "";

  // a new video starts with a default range and a clean job
  useEffect(() => {
    if (info) setRange({ start: 0, end: Math.min(Math.floor(info.duration), DEFAULT_CLIP_SECONDS) });
    job.reset();
  }, [info?.id]);

  const phase = job.state.phase;
  const busy = phase === "starting" || phase === "running";
  const length = range.end - range.start;
  const canCut = info !== null && !busy && length >= MIN_CLIP_SECONDS && length <= MAX_CLIP_SECONDS;

  const cut = () => {
    if (!canCut) return;
    void job.start({ url: videoUrl, start: range.start, end: range.end, ...options });
  };

  return (
    <main className="app">
      <h1>yt-cutter</h1>
      <p className="subtitle">Cut a section out of a YouTube video and download just that clip.</p>

      <section className="card">
        <UrlForm
          loading={video.status === "loading"}
          error={video.status === "error" ? video.message : null}
          onSubmit={load}
        />
      </section>

      {info && (
        <>
          <section className="card">
            <h2 className="video-title">{info.title}</h2>
            <VideoPreview ref={preview} videoId={info.id} />
            <div className="preview-actions">
              <button className="button" onClick={() => preview.current?.playRange(range.start, range.end)}>
                Play selection
              </button>
              <button className="button" onClick={() => preview.current?.seek(range.start)}>
                Go to start
              </button>
              <button className="button" onClick={() => preview.current?.seek(range.end)}>
                Go to end
              </button>
            </div>
          </section>

          <section className="card">
            <RangeSlider
              duration={info.duration}
              start={range.start}
              end={range.end}
              maxClip={MAX_CLIP_SECONDS}
              disabled={busy}
              onChange={(start, end) => setRange({ start, end })}
              onSeek={(seconds) => preview.current?.seek(seconds)}
            />
            <FormatPicker value={options} onChange={setOptions} disabled={busy} />
          </section>

          <section className="card">
            {job.state.phase === "running" && (
              <ProgressBar status={job.state.status} progress={job.state.progress} />
            )}

            {job.state.phase === "error" && (
              <div className="error" role="alert">
                {job.state.message}
              </div>
            )}

            {job.state.phase === "done" ? (
              <div className="row actions">
                <DownloadButton jobId={job.state.jobId} filename={job.state.filename} />
                <button className="button" onClick={job.reset}>
                  Cut another clip
                </button>
              </div>
            ) : (
              <div className="actions">
                <button className="button primary" onClick={cut} disabled={!canCut}>
                  {busy ? "Working…" : "Cut clip"}
                </button>
              </div>
            )}
          </section>
        </>
      )}

      <p className="muted footer">
        For personal use. Downloading from YouTube may violate its Terms of Service; only cut content you
        have the right to use.
      </p>
    </main>
  );
}
EOF

cat > "$F/src/main.tsx" <<'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
EOF

cat > "$F/src/styles.css" <<'EOF'
:root {
  --bg: #f6f7f9;
  --card: #ffffff;
  --text: #16181d;
  --muted: #667085;
  --border: #d9dde3;
  --accent: #e5322d;
  --accent-text: #ffffff;
  --track: #e4e7ec;
  --danger: #b42318;
  --danger-bg: #fef3f2;
  color-scheme: light dark;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1115;
    --card: #181b21;
    --text: #eceef2;
    --muted: #98a2b3;
    --border: #2c313a;
    --accent: #ff4a44;
    --track: #2c313a;
    --danger: #fda29b;
    --danger-bg: #2a1514;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}

.app { max-width: 720px; margin: 0 auto; padding: 32px 16px 64px; }
h1 { margin: 0 0 4px; font-size: 28px; }
.subtitle { margin: 0 0 24px; color: var(--muted); }
.muted { color: var(--muted); font-size: 14px; }
.footer { margin-top: 32px; }

.card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 20px;
  margin-bottom: 16px;
}

.row { display: flex; gap: 8px; flex-wrap: wrap; }
.row > input { flex: 1; min-width: 0; }
.actions { margin-top: 12px; }
.actions:first-child { margin-top: 0; }

input[type="text"], select {
  font: inherit;
  color: inherit;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px 12px;
}

:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

.button {
  font: inherit;
  font-weight: 600;
  display: inline-block;
  text-align: center;
  text-decoration: none;
  cursor: pointer;
  color: var(--text);
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px 16px;
}
.button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.button:disabled { opacity: 0.5; cursor: not-allowed; }

.error {
  background: var(--danger-bg);
  color: var(--danger);
  border-radius: 8px;
  padding: 10px 12px;
  margin-top: 12px;
}
.actions + .error, .error:first-child { margin-top: 0; margin-bottom: 12px; }

.video-title { margin: 0 0 12px; font-size: 18px; }

.preview { position: relative; aspect-ratio: 16 / 9; border-radius: 8px; overflow: hidden; background: #000; }
.preview iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
.preview-actions { display: flex; gap: 8px; margin-top: 12px; flex-wrap: wrap; }

/* dual-handle slider: two range inputs stacked on one track */
.range { position: relative; height: 32px; margin: 8px 0 16px; }
.range-track {
  position: absolute; top: 50%; left: 0; right: 0;
  height: 6px; margin-top: -3px;
  background: var(--track); border-radius: 3px;
}
.range-fill { position: absolute; top: 0; bottom: 0; background: var(--accent); border-radius: 3px; }
.range input[type="range"] {
  position: absolute; inset: 0;
  width: 100%; height: 100%; margin: 0;
  background: none; pointer-events: none;
  -webkit-appearance: none; appearance: none;
}
.range input[type="range"]::-webkit-slider-runnable-track { background: transparent; }
.range input[type="range"]::-moz-range-track { background: transparent; }
.range input[type="range"]::-webkit-slider-thumb {
  -webkit-appearance: none; pointer-events: auto; cursor: grab;
  width: 22px; height: 22px; border-radius: 50%;
  background: #fff; border: 3px solid var(--accent);
}
.range input[type="range"]::-moz-range-thumb {
  pointer-events: auto; cursor: grab;
  width: 16px; height: 16px; border-radius: 50%;
  background: #fff; border: 3px solid var(--accent);
}
.range input[type="range"]:disabled::-webkit-slider-thumb { cursor: not-allowed; }
.range input[type="range"]:disabled::-moz-range-thumb { cursor: not-allowed; }

.time-fields { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-end; margin-bottom: 20px; }
.clip-length { margin-left: auto; }
.field { display: flex; flex-direction: column; gap: 4px; font-size: 14px; color: var(--muted); }
.field input { width: 110px; text-align: center; font-variant-numeric: tabular-nums; }
.field.inline select { width: 100px; }

.options { display: flex; gap: 20px; flex-wrap: wrap; align-items: flex-end; }
.segmented { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
.segmented label { position: relative; padding: 9px 16px; cursor: pointer; font-weight: 600; }
.segmented label.active { background: var(--accent); color: var(--accent-text); }
.segmented label:focus-within { outline: 2px solid var(--accent); outline-offset: -2px; }
.segmented input { position: absolute; opacity: 0; pointer-events: none; }
.check { display: flex; align-items: center; gap: 8px; padding-bottom: 10px; cursor: pointer; }

.progress-label { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 14px; }
.progress { height: 10px; background: var(--track); border-radius: 5px; overflow: hidden; }
.progress-fill { height: 100%; background: var(--accent); transition: width 0.3s; }
.progress.indeterminate .progress-fill { width: 35%; animation: slide 1.2s ease-in-out infinite; }
@keyframes slide { from { margin-left: -35%; } to { margin-left: 100%; } }
@media (prefers-reduced-motion: reduce) {
  .progress.indeterminate .progress-fill { animation: none; width: 100%; opacity: 0.5; }
}

@media (max-width: 480px) {
  .clip-length { margin-left: 0; width: 100%; }
}
EOF

# ------------------------------------------------------------------ test tooling
echo "[*] Installing vitest"
(
  cd "$F"
  npm install --silent --save-dev vitest
  npm pkg set scripts.test="vitest run" >/dev/null
)

echo "[+] Done. Verify with:"
echo "    cd frontend && npm run build && npm test"
echo "    npm run dev     # needs the backend running on port 8000"
