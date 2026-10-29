import { jobDownloadUrl } from "../lib/api";

interface Props {
  jobId: string;
  filename: string | null;
}

export default function DownloadButton({ jobId, filename }: Props) {
  return (
    <a
      className="button primary download-button"
      href={jobDownloadUrl(jobId)}
      download={filename ?? undefined}
      title={filename ?? undefined}
    >
      <span>Download</span>
      {filename && <span className="download-filename">{filename}</span>}
    </a>
  );
}
