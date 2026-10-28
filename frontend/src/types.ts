export type Format = "mp4" | "mp3";

export type JobStatus = "queued" | "downloading" | "processing" | "done" | "error";

export interface VideoInfo {
  title: string;
  duration: number;
  thumbnail: string;
}

export interface JobEvent {
  status: JobStatus;
  progress: number;
  message?: string;
}
