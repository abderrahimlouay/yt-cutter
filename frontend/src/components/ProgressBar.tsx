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
