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
