export interface KeyframeGroup {
  property_type?: string;
  keyframe_list?: Array<{ time_offset: number; values: number[] }>;
}

export interface MediaLayer {
  kind: "video" | "image";
  id: string | null;
  src: string;
  fromMs: number;
  durationMs: number;
  sourceStartMs: number;
  x: number;
  y: number;
  rotation: number;
  scaleX: number;
  scaleY: number;
  opacity: number;
  flipH: boolean;
  flipV: boolean;
  volume: number;
  blend: { mode: string; value: number } | null;
  keyframes: KeyframeGroup[];
  renderIndex: number;
  trackIndex: number;
  segIndex: number;
  zIndex: number;
}

export interface AudioLayer {
  kind: "audio";
  id: string | null;
  src: string;
  fromMs: number;
  durationMs: number;
  sourceStartMs: number;
  volume: number;
  keyframes: KeyframeGroup[];
  renderIndex: number;
  trackIndex: number;
  segIndex: number;
  zIndex: number;
}

export interface TextAnimation {
  kind: string;
  direction: "in" | "out";
  startMs: number;
  durationMs: number;
}

export interface TextLayer {
  kind: "text";
  id: string | null;
  text: string;
  fromMs: number;
  durationMs: number;
  x: number;
  y: number;
  rotation: number;
  scaleX: number;
  scaleY: number;
  opacity: number;
  flipH: boolean;
  flipV: boolean;
  fontSize: number;
  color: string;
  align: string;
  animations: TextAnimation[];
  keyframes: KeyframeGroup[];
  renderIndex: number;
  trackIndex: number;
  segIndex: number;
  zIndex: number;
}

export type RenderLayer = MediaLayer | AudioLayer | TextLayer;

export interface SkippedLayer {
  id: string | null;
  kind: string;
  reason: string;
}

export interface TimelineModel {
  width: number;
  height: number;
  fps: number;
  durationMs: number;
  durationFrames: number;
  background: string;
  layers: RenderLayer[];
  stats: { rendered: number; skipped: SkippedLayer[] };
}

export declare function buildTimelineModel(
  draft: unknown,
  draftDir?: string,
  resolveMedia?: (p: string) => string | null,
): TimelineModel;

export declare function draftMetadata(draft: unknown): {
  width: number;
  height: number;
  fps: number;
  durationInFrames: number;
};

export declare function sampleKeyframes(
  keyframes: KeyframeGroup[] | undefined,
  propertyType: string,
  localTimeUs: number,
  fallback: number,
): number;

export declare function parseCapcutColor(raw?: string): string;

export declare function parseTextContent(content?: string): {
  text: string;
  styleColor: string | null;
  styleSize: number | null;
};

export declare function blendModeToCss(label?: string): string | null;
