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
