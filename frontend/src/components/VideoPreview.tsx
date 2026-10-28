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
