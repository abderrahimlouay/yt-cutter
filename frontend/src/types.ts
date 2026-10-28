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
