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
