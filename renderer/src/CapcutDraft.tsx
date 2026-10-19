import React, { useMemo } from "react";
import { AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, useCurrentFrame } from "remotion";
import { applyAnimation } from "./animations.mjs";
import { buildTimelineModel, sampleKeyframes } from "./model.mjs";

type Props = {
  draft: unknown;
  draftDir?: string;
};

const US_PER_MS = 1000;

/**
 * Root composition: draws every CapCut segment as a Remotion Sequence.
 *
 * Render order: layers are sorted by (render_index, track order, segment
 * order) ascending, so higher render_index (and later overlay tracks) render
 * on top — matching CapCut's editor z-order for the clips this server can
 * write. Rendering is an approximation: no transitions, effects, stickers or
 * filters; blend modes and text animations map to their closest CSS
 * equivalents (see model.mjs / animations.mjs and the README).
 */
export const CapcutDraft: React.FC<Props> = ({ draft, draftDir }) => {
  const model = useMemo(() => buildTimelineModel(draft, draftDir, undefined), [draft, draftDir]);

  return (
    <AbsoluteFill style={{ backgroundColor: model.background }}>
      {model.layers.map((layer, index) => (
        <LayerSequence key={layer.id ?? `layer-${index}`} layer={layer} model={model} />
      ))}
    </AbsoluteFill>
  );
};

function msToFrames(ms: number, fps: number): number {
  return Math.round((ms * fps) / 1000);
}

function sequenceRange(layer: { fromMs: number; durationMs: number }, model: ReturnType<typeof buildTimelineModel>) {
  const from = Math.max(0, msToFrames(layer.fromMs, model.fps));
  const duration = Math.max(1, Math.min(model.durationFrames - from, msToFrames(layer.durationMs, model.fps)));
  return { from, duration };
}

const LayerSequence: React.FC<{ layer: any; model: ReturnType<typeof buildTimelineModel> }> = ({ layer, model }) => {
  const { from, duration } = sequenceRange(layer, model);
  const name = `${layer.kind}${layer.id ? `:${layer.id}` : ""}`;

  if (layer.kind === "audio") {
    return (
      <Sequence from={from} durationInFrames={duration} layout="none" name={name}>
        <AudioLayer layer={layer} model={model} />
      </Sequence>
    );
  }

  if (layer.kind === "text") {
    return (
      <Sequence from={from} durationInFrames={duration} name={name}>
        <TextLayer layer={layer} model={model} />
      </Sequence>
    );
  }

  return (
    <Sequence from={from} durationInFrames={duration} name={name}>
      <VisualLayer layer={layer} model={model} />
    </Sequence>
  );
};

/**
 * Samples a CapCut keyframe group at the current local time. Keyframe
 * `time_offset` values are microseconds relative to the segment start, which
 * is exactly the local time base inside a Sequence.
 */
function sample(layer: { keyframes?: unknown[] | null }, propertyType: string, frame: number, fps: number, fallback: number) {
  const localTimeUs = (frame * 1_000_000) / fps;
  return sampleKeyframes((layer.keyframes ?? undefined) as never, propertyType, localTimeUs, fallback);
}

const VisualLayer: React.FC<{ layer: any; model: ReturnType<typeof buildTimelineModel> }> = ({ layer, model }) => {
  const frame = useCurrentFrame();

  const x = layer.x + sample(layer, "KFTypePositionX", frame, model.fps, 0) * (model.width / 2);
  const y = layer.y + sample(layer, "KFTypePositionY", frame, model.fps, 0) * (model.height / 2);
  const uniform = sample(layer, "UNIFORM_SCALE", frame, model.fps, 1);
  const rotation = layer.rotation + sample(layer, "KFTypeRotation", frame, model.fps, 0);
  const scaleX = layer.scaleX * sample(layer, "KFTypeScaleX", frame, model.fps, 1) * uniform * (layer.flipH ? -1 : 1);
  const scaleY = layer.scaleY * sample(layer, "KFTypeScaleY", frame, model.fps, 1) * uniform * (layer.flipV ? -1 : 1);
  const opacity = layer.opacity * sample(layer, "KFTypeAlpha", frame, model.fps, 1);

  const saturation = sample(layer, "KFTypeSaturation", frame, model.fps, 0);
  const contrast = sample(layer, "KFTypeContrast", frame, model.fps, 0);
  const brightness = sample(layer, "KFTypeBrightness", frame, model.fps, 0);
  const filterParts: string[] = [];
  if (saturation !== 0) filterParts.push(`saturate(${1 + saturation})`);
  if (contrast !== 0) filterParts.push(`contrast(${1 + contrast})`);
  if (brightness !== 0) filterParts.push(`brightness(${1 + brightness})`);

  const style: React.CSSProperties = {
    justifyContent: "center",
    alignItems: "center",
    opacity,
    transform: `translate(${x}px, ${y}px) rotate(${rotation}deg) scale(${scaleX}, ${scaleY})`,
    filter: filterParts.length > 0 ? filterParts.join(" ") : undefined,
    mixBlendMode: layer.blend ? (layer.blend.mode as React.CSSProperties["mixBlendMode"]) : undefined,
  };

  const mediaStyle: React.CSSProperties = {
    width: model.width,
    height: model.height,
    objectFit: "contain",
  };

  return (
    <AbsoluteFill style={style}>
      {layer.kind === "image" ? (
        <Img src={layer.src} style={mediaStyle} />
      ) : (
        <OffthreadVideo
          src={layer.src}
          trimBefore={msToFrames(layer.sourceStartMs, model.fps)}
          durationInFrames={sequenceDurationFrames(layer, model)}
          volume={sample(layer, "KFTypeVolume", frame, model.fps, layer.volume)}
          style={mediaStyle}
        />
      )}
    </AbsoluteFill>
  );
};

const AudioLayer: React.FC<{ layer: any; model: ReturnType<typeof buildTimelineModel> }> = ({ layer, model }) => {
  const frame = useCurrentFrame();

  return (
    <Audio
      src={layer.src}
      trimBefore={msToFrames(layer.sourceStartMs, model.fps)}
      durationInFrames={sequenceDurationFrames(layer, model)}
      volume={sample(layer, "KFTypeVolume", frame, model.fps, layer.volume)}
    />
  );
};

function sequenceDurationFrames(layer: { durationMs: number }, model: ReturnType<typeof buildTimelineModel>) {
  return Math.max(1, msToFrames(layer.durationMs, model.fps));
}

const TextLayer: React.FC<{ layer: any; model: ReturnType<typeof buildTimelineModel> }> = ({ layer, model }) => {
  const frame = useCurrentFrame();
  const localMs = (frame * 1000) / model.fps;

  const x = layer.x + sample(layer, "KFTypePositionX", frame, model.fps, 0) * (model.width / 2);
  const y = layer.y + sample(layer, "KFTypePositionY", frame, model.fps, 0) * (model.height / 2);
  const uniform = sample(layer, "UNIFORM_SCALE", frame, model.fps, 1);
  const rotation = layer.rotation + sample(layer, "KFTypeRotation", frame, model.fps, 0);
  const scaleX = layer.scaleX * sample(layer, "KFTypeScaleX", frame, model.fps, 1) * uniform * (layer.flipH ? -1 : 1);
  const scaleY = layer.scaleY * sample(layer, "KFTypeScaleY", frame, model.fps, 1) * uniform * (layer.flipV ? -1 : 1);
  const opacity = layer.opacity * sample(layer, "KFTypeAlpha", frame, model.fps, 1);

  const style: React.CSSProperties = {
    opacity,
    transform: `translate(${x}px, ${y}px) rotate(${rotation}deg) scale(${scaleX}, ${scaleY})`,
    mixBlendMode:
      layer.blend && layer.blend.mode
        ? (layer.blend.mode as React.CSSProperties["mixBlendMode"])
        : undefined,
  };

  let text: string = layer.text;
  for (const anim of layer.animations ?? []) {
    text = applyAnimation(anim, localMs, style as unknown as Record<string, unknown>, text);
  }

  return (
    <AbsoluteFill style={style}>
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
        <div
          style={{
            fontSize: layer.fontSize,
            color: layer.color,
            fontFamily: "sans-serif",
            textAlign: layer.align === "left" ? "left" : layer.align === "right" ? "right" : "center",
            whiteSpace: "pre-wrap",
            maxWidth: "90%",
          }}
        >
          {text}
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
