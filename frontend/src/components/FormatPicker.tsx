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
