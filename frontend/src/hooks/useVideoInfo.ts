import { useCallback, useEffect, useRef, useState } from "react";
import { fetchInfo, messageOf } from "../lib/api";
import type { VideoInfo } from "../types";

export type VideoState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; url: string; info: VideoInfo }
  | { status: "error"; message: string };

export function useVideoInfo() {
  const [state, setState] = useState<VideoState>({ status: "idle" });
  const controller = useRef<AbortController | null>(null);

  const load = useCallback(async (url: string) => {
    controller.current?.abort();
    const ctrl = new AbortController();
    controller.current = ctrl;
    setState({ status: "loading" });
    try {
      const info = await fetchInfo(url, ctrl.signal);
      if (!ctrl.signal.aborted) setState({ status: "ready", url, info });
    } catch (error) {
      if (!ctrl.signal.aborted) setState({ status: "error", message: messageOf(error) });
    }
  }, []);

  const reset = useCallback(() => {
    controller.current?.abort();
    setState({ status: "idle" });
  }, []);

  useEffect(() => () => controller.current?.abort(), []);

  return { state, load, reset };
}
