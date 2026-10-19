/**
 * CapCut draft -> Remotion timeline model.
 *
 * Pure conversion layer: takes the decoded `draft_content.json` /
 * `draft_info.json` shape (times in MICROSECONDS, transform x/y in
 * half-canvas units, CapCut `rgba(1,1,1,1)` = white color convention) and
 * produces a flat, render-order-sorted list of layers the React components
 * can draw frame by frame.
 *
 * Plain `.mjs` (not `.ts`) so the Node CLI (`render.mjs`) can import it for
 * the render summary without needing a TypeScript loader — the Remotion
 * bundle compiles the .tsx side, but the CLI runs in plain Node.
 *
 * Rendering is an APPROXIMATION of what CapCut renders (documented in the
 * repo README): no transitions, no effects/stickers/filters, blend modes and
 * text animations mapped to their closest CSS/Remotion equivalents.
 */

/** @typedef {{ start?: number, duration?: number }} TimeRangeUs */
/** @typedef {{ alpha?: number, rotation?: number, scale?: {x?: number, y?: number}, transform?: {x?: number, y?: number}, flip?: {horizontal?: boolean, vertical?: boolean} }} ClipProps */
/** @typedef {{ id?: string, material_id?: string, target_timerange?: TimeRangeUs, source_timerange?: TimeRangeUs, clip?: ClipProps, render_index?: number, volume?: number, extra_material_refs?: string[], common_keyframes?: Array<Object> }} Segment */
/** @typedef {{ id?: string, type?: string, segments?: Segment[] }} Track */
/** @typedef {{ id?: string, text?: string, content?: string, text_size?: number, font_size?: number, font_color?: string, alignment?: string }} TextMaterial */
/** @typedef {{ id?: string, path?: string, type?: string, duration?: number }} MediaMaterial */
/** @typedef {{ id?: string, type?: string, animations?: Array<{type?: string, name?: string, resource_id?: string, start?: number, duration?: number}> }} AnimationMaterial */
/** @typedef {{ id?: string, type?: string, name?: string, value?: number }} MixModeEffect */

/** @typedef {{ kind: 'video' | 'image', src: string, fromMs: number, durationMs: number, sourceStartMs: number, x: number, y: number, rotation: number, scaleX: number, scaleY: number, opacity: number, flipH: boolean, flipV: boolean, volume: number, blend: {mode: string, value: number} | null, keyframes: Array<Object>, zIndex: number }} MediaLayer */
/** @typedef {{ kind: 'audio', src: string, fromMs: number, durationMs: number, sourceStartMs: number, volume: number, keyframes: Array<Object>, zIndex: number }} AudioLayer */
/** @typedef {{ kind: 'text', text: string, fromMs: number, durationMs: number, x: number, y: number, rotation: number, scaleX: number, scaleY: number, opacity: number, flipH: boolean, flipV: boolean, fontSize: number, color: string, align: string, animations: Array<Object>, keyframes: Array<Object>, zIndex: number }} TextLayer */
/** @typedef {MediaLayer | AudioLayer | TextLayer} RenderLayer */

/** @typedef {{ id: string | null, kind: string, reason: string }} SkippedLayer */
/** @typedef {{ width: number, height: number, fps: number, durationMs: number, durationFrames: number, background: string, layers: RenderLayer[], stats: {rendered: number, skipped: SkippedLayer[]} }} TimelineModel */

const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.tiff', '.heic']);
const DEFAULT_FPS = 30;
const DEFAULT_WIDTH = 1920;
const DEFAULT_HEIGHT = 1080;

/**
 * CapCut's own transform coordinate system (per pyCapCut and real draft
 * diffs): x/y are measured in HALF canvas-width/height units, y pointing
 * DOWN. 0/0 = canvas center, 1/1 = bottom-right quarter point.
 *
 * @param {number} value - CapCut transform component
 * @param {number} extent - half-canvas extent in px (width/2 or height/2)
 * @returns {number} pixel offset
 */
function capcutUnitToPx(value, extent) {
  const v = typeof value === 'number' && Number.isFinite(value) ? value : 0;
  return v * extent;
}

/**
 * CapCut writes text colors as `rgba(r,g,b,a)` with 0..1 floats
 * (rgba(1,1,1,1) is WHITE). Real drafts may also carry already-scaled
 * 0..255 values; detect by range and normalize to CSS `rgba()`.
 *
 * @param {string | undefined} raw
 * @returns {string} CSS color string
 */
export function parseCapcutColor(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return '#FFFFFF';
  const m = /^rgba\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)$/i.exec(raw.trim());
  if (!m) return '#FFFFFF';
  const [r, g, b, a] = [m[1], m[2], m[3], m[4]].map(Number);
  return cssRgba(r, g, b, a);
}

function cssRgba(r, g, b, a) {
  const maxComponent = Math.max(r, g, b);
  const scale = maxComponent > 1.0 ? 1 : 255;
  return `rgba(${Math.round(r * scale)}, ${Math.round(g * scale)}, ${Math.round(b * scale)}, ${clamp01(a)})`;
}

function clamp01(v) {
  return Math.min(1, Math.max(0, Number.isFinite(v) ? v : 1));
}

/**
 * CapCut text `content` is a JSON string `{"styles":[...],"text":"..."}`
 * (confirmed against real drafts — styles[0].fill.content.solid.color holds
 * 0..1 RGB floats and styles[0].size the font size); older/tool-written
 * drafts carry the raw string. Returns the plain text plus the first
 * style's fill color and size when present.
 *
 * @param {string | undefined} content
 * @returns {{ text: string, styleColor: string | null, styleSize: number | null }}
 */
export function parseTextContent(content) {
  if (typeof content !== 'string' || content.trim() === '') {
    return { text: '', styleColor: null, styleSize: null };
  }
  try {
    const parsed = JSON.parse(content);
    if (parsed && typeof parsed === 'object' && typeof parsed.text === 'string') {
      const style = Array.isArray(parsed.styles) ? parsed.styles[0] : null;
      return {
        text: parsed.text,
        styleColor: style ? colorFromFill(style.fill) : null,
        styleSize: style && typeof style.size === 'number' ? style.size : null,
      };
    }
  } catch {
    // Not JSON — treat as literal text (how this server's add_text writes it).
  }
  return { text: content, styleColor: null, styleSize: null };
}

/**
 * Real drafts (verified on a live CapCut 8.9.1 install) carry the fill at
 * `styles[0].fill.content.solid.color` as `[r,g,b]` 0..1 floats with alpha
 * on `fill.alpha`/`solid.alpha`; pyCapCut-derived docs also reference
 * `fill.contentcolor.rgba` as `[r,g,b,a]`. Support both.
 */
function colorFromFill(fill) {
  if (!fill) return null;
  const solid = fill.content && fill.content.solid;
  if (solid && Array.isArray(solid.color) && solid.color.length >= 3) {
    return cssRgba(solid.color[0], solid.color[1], solid.color[2], solid.alpha ?? fill.alpha ?? 1);
  }
  const rgba = fill.contentcolor && fill.contentcolor.rgba;
  if (Array.isArray(rgba) && rgba.length >= 4) {
    return cssRgba(rgba[0], rgba[1], rgba[2], rgba[3]);
  }
  return null;
}

/**
 * Blend mode label (as written into mix_mode effect materials) -> CSS
 * mix-blend-mode. CSS has no linear-burn; multiply is the closest
 * approximation and is documented as such.
 *
 * @param {string | undefined} label
 * @returns {string | null}
 */
export function blendModeToCss(label) {
  const map = {
    Screen: 'screen',
    Multiply: 'multiply',
    'Soft Light': 'soft-light',
    Overlay: 'overlay',
    Color: 'color',
    Darken: 'darken',
    Lighten: 'lighten',
    'Linear Burn': 'multiply',
    'Color Burn': 'color-burn',
    'Color Dodge': 'color-dodge',
  };
  return map[label] ?? null;
}

/**
 * @param {Record<string, any> | undefined | null} materials
 * @returns {Map<string, Record<string, any>>}
 */
function materialsById(materials) {
  const byId = new Map();
  for (const bucket of ['videos', 'audios', 'photos', 'texts']) {
    const list = materials && materials[bucket];
    if (!Array.isArray(list)) continue;
    for (const mat of list) {
      if (mat && typeof mat.id === 'string') byId.set(mat.id, { ...mat, __bucket: bucket });
    }
  }
  return byId;
}

/**
 * @param {Record<string, any> | undefined | null} materials
 * @returns {Map<string, Record<string, any>>} mix_mode effects + animation materials, by id
 */
function refsById(materials) {
  const byId = new Map();
  for (const bucket of ['effects', 'animations']) {
    const list = materials && materials[bucket];
    if (!Array.isArray(list)) continue;
    for (const mat of list) {
      if (mat && typeof mat.id === 'string') byId.set(mat.id, { ...mat, __bucket: bucket });
    }
  }
  return byId;
}

/**
 * Resolves a media path: absolute paths pass through (when they exist),
 * relative paths resolve against the draft folder (CapCut writes media
 * references relative to the project folder for locally-imported assets).
 * Cloud/URL assets are not resolvable -> null (skipped with a reason).
 *
 * @param {string | undefined} rawPath
 * @param {string | undefined} draftDir
 * @param {((p: string) => string | null) | undefined} resolveMedia
 * @returns {string | null}
 */
function resolveMediaPath(rawPath, draftDir, resolveMedia) {
  if (typeof rawPath !== 'string' || rawPath.trim() === '') return null;
  if (/^https?:\/\//i.test(rawPath)) {
    // Remote URLs are kept as-is; Remotion can fetch http(s) sources itself.
    return rawPath;
  }
  if (rawPath.startsWith('HXC://') || rawPath.startsWith('templaterc://')) return null;

  const candidate = typeof resolveMedia === 'function' ? resolveMedia(rawPath) : rawPath;
  if (candidate) return candidate;

  if (draftDir && !rawPath.startsWith('/')) {
    const joined = draftDir.replace(/\/$/, '') + '/' + rawPath;
    const resolved = typeof resolveMedia === 'function' ? resolveMedia(joined) : joined;
    if (resolved) return resolved;
  }
  return null;
}

function materialKind(material) {
  const bucket = material && material.__bucket;
  if (bucket === 'audios') return 'audio';
  const p = typeof material.path === 'string' ? material.path.toLowerCase() : '';
  if (IMAGE_EXTS.has(p.slice(p.lastIndexOf('.')))) return 'image';
  return 'video';
}

/**
 * Builds the full timeline model from a decoded draft.
 *
 * @param {Record<string, any>} draft - decoded draft JSON
 * @param {string | undefined} draftDir - folder containing the draft JSON (for relative media paths)
 * @param {((p: string) => string | null) | undefined} resolveMedia - returns the usable path, or null if the file is missing/unusable
 * @returns {TimelineModel}
 */
export function buildTimelineModel(draft, draftDir, resolveMedia) {
  const canvas = (draft && draft.canvas_config) || {};
  const width = normalizeInt(canvas.width, DEFAULT_WIDTH, 16, 8192);
  const height = normalizeInt(canvas.height, DEFAULT_HEIGHT, 16, 8192);
  const fps = normalizeNumber(draft && draft.fps, DEFAULT_FPS, 1, 240);
  const background = parseBackground(canvas.background);

  const materials = (draft && draft.materials) || {};
  const mediaById = materialsById(materials);
  const refById = refsById(materials);

  const tracks = (draft && Array.isArray(draft.tracks) && draft.tracks) || [];
  /** @type {RenderLayer[]} */
  const layers = [];
  /** @type {SkippedLayer[]} */
  const skipped = [];
  let rendered = 0;
  let maxEndMs = 0;

  // Draft `duration` is stored in microseconds and can be stale (0 for
  // projects created programmatically). The union of segment ends is the
  // ground truth; draft.duration only ever widens it.
  tracks.forEach((track, trackIndex) => {
    const segments = (track && Array.isArray(track.segments) && track.segments) || [];
    segments.forEach((segment, segIndex) => {
      const ctx = {
        trackIndex,
        segIndex,
        trackType: track && track.type,
        width,
        height,
        mediaById,
        refById,
        draftDir,
        resolveMedia,
      };
      const maxed = collectLayer(segment, ctx, layers, skipped);
      if (maxed > maxEndMs) maxEndMs = maxed;
      if (maxed > 0) rendered += 1;
    });
  });

  const draftDurationMs = normalizeNumber(draft && draft.duration, 0, 0, Number.MAX_SAFE_INTEGER) / 1000;
  const durationMs = Math.max(maxEndMs, draftDurationMs);
  const durationFrames = Math.max(1, Math.ceil((durationMs * fps) / 1000));

  // Stable z-order: higher render_index on top; ties broken by track order
  // (later tracks on top — matches CapCut's editor where overlay tracks sit
  // below the main video track in the JSON but render above it).
  layers.sort(
    (a, b) =>
      (a.renderIndex ?? 0) - (b.renderIndex ?? 0) ||
      (a.trackIndex ?? 0) - (b.trackIndex ?? 0) ||
      (a.segIndex ?? 0) - (b.segIndex ?? 0),
  );
  layers.forEach((layer, i) => {
    layer.zIndex = i;
  });

  return {
    width,
    height,
    fps,
    durationMs,
    durationFrames,
    background,
    layers,
    stats: { rendered, skipped },
  };
}

/**
 * @returns {number} the layer's end ms (0 when skipped)
 */
function collectLayer(segment, ctx, layers, skipped) {
  const segId = typeof segment.id === 'string' ? segment.id : null;
  const target = segment.target_timerange || {};
  const startMs = toMs(target.start);
  const durationMs = toMs(target.duration);

  if (!Number.isFinite(startMs) || startMs < 0) {
    skipped.push({ id: segId, kind: 'unknown', reason: 'invalid target_timerange.start' });
    return 0;
  }
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    skipped.push({ id: segId, kind: 'unknown', reason: 'invalid or missing target_timerange.duration' });
    return 0;
  }

  const material = ctx.mediaById.get(segment.material_id);
  const clip = segment.clip || {};

  if (ctx.trackType === 'text' || (material && material.__bucket === 'texts')) {
    return collectTextLayer(segment, material, { ...ctx, startMs, durationMs, segId, clip }, layers, skipped);
  }

  if (!material) {
    skipped.push({ id: segId, kind: 'unknown', reason: `material not found: ${segment.material_id}` });
    return 0;
  }

  const src = resolveMediaPath(material.path, ctx.draftDir, ctx.resolveMedia);
  if (!src) {
    skipped.push({ id: segId, kind: 'media', reason: `media not resolvable: ${material.path}` });
    return 0;
  }

  const kind = materialKind(material);
  if (kind === 'audio') {
    layers.push({
      kind: 'audio',
      id: segId,
      src,
      fromMs: startMs,
      durationMs,
      sourceStartMs: toMs((segment.source_timerange || {}).start),
      volume: normalizeNumber(segment.volume, 1, 0, 100),
      keyframes: Array.isArray(segment.common_keyframes) ? segment.common_keyframes : [],
      renderIndex: segment.render_index ?? 0,
      trackIndex: ctx.trackIndex,
      segIndex: ctx.segIndex,
      zIndex: 0,
    });
    return startMs + durationMs;
  }

  const blend = findBlendMode(segment, ctx.refById);
  layers.push({
    kind,
    id: segId,
    src,
    fromMs: startMs,
    durationMs,
    sourceStartMs: toMs((segment.source_timerange || {}).start),
    x: capcutUnitToPx(clip.transform && clip.transform.x, ctx.width / 2),
    y: capcutUnitToPx(clip.transform && clip.transform.y, ctx.height / 2),
    rotation: normalizeNumber(clip.rotation, 0, -3600, 3600),
    scaleX: normalizeNumber(clip.scale && clip.scale.x, 1, 0.001, 100),
    scaleY: normalizeNumber(clip.scale && clip.scale.y, 1, 0.001, 100),
    opacity: clamp01(clip.alpha ?? 1),
    flipH: Boolean(clip.flip && clip.flip.horizontal),
    flipV: Boolean(clip.flip && clip.flip.vertical),
    volume: normalizeNumber(segment.volume, 1, 0, 100),
    blend,
    keyframes: Array.isArray(segment.common_keyframes) ? segment.common_keyframes : [],
    renderIndex: segment.render_index ?? 0,
    trackIndex: ctx.trackIndex,
    segIndex: ctx.segIndex,
    zIndex: 0,
  });
  return startMs + durationMs;
}

function collectTextLayer(segment, material, ctx, layers, skipped) {
  if (!material) {
    skipped.push({ id: ctx.segId, kind: 'text', reason: `text material not found: ${segment.material_id}` });
    return 0;
  }
  const parsed = parseTextContent(material.content);
  if (parsed.text.trim() === '') {
    skipped.push({ id: ctx.segId, kind: 'text', reason: 'empty text content' });
    return 0;
  }

  // Font size ground truth (verified against real CapCut drafts): the size
  // lives in the content JSON's `styles[0].size`, as a percentage of canvas
  // height (8.0 = 8%). Real drafts ALSO carry material-level `font_size`
  // with the same value, while `text_size` is a constant 30 in both real
  // and tool-written materials — it is CapCut's legacy scale, NOT the
  // render size (picking it produced ~4x oversized text). So: styles size
  // first, then the material's font_size, then CapCut's 8% default.
  const fontSizeRaw = parsed.styleSize ?? material.font_size ?? 8;
  const fontSize = Math.min(
    ctx.height * 0.9,
    Math.max(8, (normalizeNumber(fontSizeRaw, 8, 0.1, 200) / 100) * ctx.height),
  );
  const color = parsed.styleColor || parseCapcutColor(material.font_color);

  layers.push({
    kind: 'text',
    id: ctx.segId,
    text: parsed.text,
    fromMs: ctx.startMs,
    durationMs: ctx.durationMs,
    x: capcutUnitToPx(ctx.clip.transform && ctx.clip.transform.x, ctx.width / 2),
    y: capcutUnitToPx(ctx.clip.transform && ctx.clip.transform.y, ctx.height / 2),
    rotation: normalizeNumber(ctx.clip.rotation, 0, -3600, 3600),
    scaleX: normalizeNumber(ctx.clip.scale && ctx.clip.scale.x, 1, 0.001, 100),
    scaleY: normalizeNumber(ctx.clip.scale && ctx.clip.scale.y, 1, 0.001, 100),
    opacity: clamp01(ctx.clip.alpha ?? 1),
    flipH: Boolean(ctx.clip.flip && ctx.clip.flip.horizontal),
    flipV: Boolean(ctx.clip.flip && ctx.clip.flip.vertical),
    fontSize,
    color,
    align: typeof material.alignment === 'string' ? material.alignment : 'center',
    blend: findBlendMode(segment, ctx.refById),
    animations: resolveAnimations(segment, ctx.refById),
    keyframes: Array.isArray(segment.common_keyframes) ? segment.common_keyframes : [],
    renderIndex: segment.render_index ?? 0,
    trackIndex: ctx.trackIndex,
    segIndex: ctx.segIndex,
    zIndex: 0,
  });
  return ctx.startMs + ctx.durationMs;
}

function findBlendMode(segment, refById) {
  const refs = Array.isArray(segment.extra_material_refs) ? segment.extra_material_refs : [];
  for (const ref of refs) {
    const mat = refById.get(ref);
    if (mat && mat.__bucket === 'effects' && mat.type === 'mix_mode') {
      const css = blendModeToCss(mat.name);
      const value = normalizeNumber(mat.value, 1, 0, 1);
      if (css && value > 0) return { mode: css, value };
    }
  }
  return null;
}

/**
 * Resolves the text animations attached to a segment (via
 * extra_material_refs -> materials.animations) into animation specs with
 * resolved start/duration in ms. Only animations actually attached to THIS
 * segment are returned.
 */
function resolveAnimations(segment, refById) {
  const refs = Array.isArray(segment.extra_material_refs) ? segment.extra_material_refs : [];
  /** @type {Array<Object>} */
  const out = [];
  for (const ref of refs) {
    const mat = refById.get(ref);
    if (!mat || mat.__bucket !== 'animations') continue;
    const entries = Array.isArray(mat.animations) ? mat.animations : [];
    for (const entry of entries) {
      const kind = matchAnimation(entry);
      if (!kind) continue;
      out.push({
        kind,
        direction: entry.type === 'out' ? 'out' : 'in',
        startMs: toMs(entry.start),
        durationMs: Math.max(1, toMs(entry.duration)),
      });
    }
  }
  return out;
}

function matchAnimation(entry) {
  const byResource = ANIMATION_BY_RESOURCE_ID[entry.resource_id];
  if (byResource) return byResource;
  return ANIMATION_BY_NAME[entry.name] ?? null;
}

// resource_id values from CapcutMcp.CapCut.TextAnimations (Elixir side) —
// stable CapCut-internal IDs for the curated animation set.
const ANIMATION_BY_RESOURCE_ID = {
  6724916044072227332: 'fade', // 渐显 fade_in
  6724919382104871427: 'fade', // 渐隐 fade_out
  6763470111253729803: 'slide_up', // 向上滑动
  7403255792146584081: 'slide_left', // 向左滑动
  6923135604519604737: 'blur', // 模糊 in
  7210980292243231233: 'typewriter', // 打字机
  7403256664498901520: 'slide_down', // 向下滑动
  6724920744431587853: 'slide_right', // 向右滑动
  6923134492760609282: 'blur', // 模糊 out
};

// Fallback matching by CapCut's display name (our tools write the Chinese
// label into the animation material's `name` field).
const ANIMATION_BY_NAME = {
  渐显: 'fade',
  渐隐: 'fade',
  向上滑动: 'slide_up',
  向左滑动: 'slide_left',
  向下滑动: 'slide_down',
  向右滑动: 'slide_right',
  模糊: 'blur',
  打字机: 'typewriter',
};

/**
 * @param {Array<Object> | undefined} keyframes
 * @param {string} propertyType
 * @param {number} localTimeUs - time relative to the segment start, in µs
 * @param {number} fallback
 * @returns {number}
 */
export function sampleKeyframes(keyframes, propertyType, localTimeUs, fallback) {
  const group = Array.isArray(keyframes)
    ? keyframes.find((kf) => kf && kf.property_type === propertyType)
    : null;
  const points = (group && Array.isArray(group.keyframe_list) && group.keyframe_list) || [];
  if (points.length === 0) return fallback;

  const value = (p) => (Array.isArray(p.values) && Number.isFinite(p.values[0]) ? p.values[0] : 0);
  const sorted = [...points].sort((a, b) => a.time_offset - b.time_offset);

  if (sorted.length === 1 || localTimeUs <= sorted[0].time_offset) {
    return value(sorted[0]);
  }
  const last = sorted[sorted.length - 1];
  if (localTimeUs >= last.time_offset) return value(last);

  for (let i = 0; i < sorted.length - 1; i += 1) {
    const a = sorted[i];
    const b = sorted[i + 1];
    if (localTimeUs >= a.time_offset && localTimeUs <= b.time_offset) {
      const span = b.time_offset - a.time_offset;
      const t = span <= 0 ? 1 : (localTimeUs - a.time_offset) / span;
      return value(a) + (value(b) - value(a)) * t;
    }
  }
  return value(last);
}

/**
 * Composition metadata for Remotion's `calculateMetadata`: derives canvas
 * size, fps and durationInFrames from the draft. Runs inside the Node
 * render process, so no media-existence checking happens here.
 *
 * @param {Record<string, any>} draft
 * @returns {{ width: number, height: number, fps: number, durationInFrames: number }}
 */
export function draftMetadata(draft) {
  const model = buildTimelineModel(draft, undefined, undefined);
  return {
    width: model.width,
    height: model.height,
    fps: model.fps,
    durationInFrames: model.durationFrames,
  };
}

function parseBackground(bg) {
  if (typeof bg === 'string' && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(bg)) return bg;
  return '#000000';
}

function toMs(us) {
  const v = typeof us === 'number' && Number.isFinite(us) ? us : 0;
  return v / 1000;
}

function normalizeNumber(value, fallback, min, max) {
  const v = typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  return Math.min(max, Math.max(min, v));
}

function normalizeInt(value, fallback, min, max) {
  const v = Number.isInteger(value) ? value : Math.round(normalizeNumber(value, fallback, min, max));
  return Math.min(max, Math.max(min, v));
}
