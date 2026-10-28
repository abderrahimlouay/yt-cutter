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
