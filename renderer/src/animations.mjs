/**
 * CapCut text animation -> CSS approximation.
 *
 * CapCut's real animation presets are rendered by its own engine; we map the
 * curated set from `CapcutMcp.CapCut.TextAnimations` (matched by resource_id,
 * falling back to the Chinese display name stored in the material) onto
 * CSS transforms/filters. Documented approximations, listed in the repo
 * README.
 *
 * Plain `.mjs` so it can be unit-tested from Node without a TS loader.
 */

/** @typedef {'fade' | 'slide_up' | 'slide_down' | 'slide_left' | 'slide_right' | 'blur' | 'typewriter'} AnimationKind */

const RESOURCE_ID_KINDS = {
  6724916044072227332: 'fade',
  6724919382104871427: 'fade',
  6763470111253729803: 'slide_up',
  7403255792146584081: 'slide_left',
  6923135604519604737: 'blur',
  7210980292243231233: 'typewriter',
  7403256664498901520: 'slide_down',
  6724920744431587853: 'slide_right',
  6923134492760609282: 'blur',
};

const NAME_KINDS = {
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
 * @param {{ resource_id?: string, name?: string, type?: string }} entry
 * @returns {AnimationKind | null}
 */
export function matchAnimationKind(entry) {
  if (!entry) return null;
  const byResource = RESOURCE_ID_KINDS[entry.resource_id];
  if (byResource) return byResource;
  return NAME_KINDS[entry.name] ?? null;
}

function easeOut(t) {
  return 1 - Math.pow(1 - t, 3);
}

function easeIn(t) {
  return t * t * t;
}

/**
 * Applies one animation at the given local time to a mutable style object
 * (and optionally rewrites the text for the typewriter effect).
 *
 * @param {{ kind: AnimationKind, direction: 'in' | 'out', startMs: number, durationMs: number }} anim
 * @param {number} localMs - ms since the segment start
 * @param {Record<string, any>} style - CSS style object mutated in place
 * @param {string} text
 * @returns {string} the (possibly rewritten) text
 */
export function applyAnimation(anim, localMs, style, text) {
  const progress = clamp01((localMs - anim.startMs) / anim.durationMs);

  // Intro effects ease in; outro effects ease out.
  const eased = anim.direction === 'in' ? easeOut(progress) : easeIn(progress);
  const enterAmount = 1 - eased; // 1 -> 0 for intros, 0 -> 1 for outros
  const travel = 40;

  if (anim.direction === 'out') {
    style.opacity = (style.opacity ?? 1) * (1 - eased);
  } else {
    style.opacity = (style.opacity ?? 1) * eased;
  }

  switch (anim.kind) {
    case 'fade':
      break;
    case 'slide_up':
      style.transform = composeTransform(style.transform, 0, anim.direction === 'in' ? enterAmount * travel : eased * travel);
      break;
    case 'slide_down':
      style.transform = composeTransform(style.transform, 0, anim.direction === 'in' ? -enterAmount * travel : eased * travel);
      break;
    case 'slide_left':
      style.transform = composeTransform(style.transform, anim.direction === 'in' ? enterAmount * travel : eased * travel, 0);
      break;
    case 'slide_right':
      style.transform = composeTransform(style.transform, anim.direction === 'in' ? -enterAmount * travel : eased * travel, 0);
      break;
    case 'blur': {
      const blurPx = anim.direction === 'in' ? enterAmount * 8 : eased * 8;
      style.filter = joinFilters(style.filter, `blur(${blurPx.toFixed(2)}px)`);
      break;
    }
    case 'typewriter': {
      if (anim.direction === 'in') {
        const chars = Math.round(text.length * eased);
        return text.slice(0, chars);
      }
      break;
    }
    default:
      break;
  }
  return text;
}

function composeTransform(existing, x, y) {
  const offset = `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px)`;
  return existing ? `${existing} ${offset}` : offset;
}

function joinFilters(existing, next) {
  return existing ? `${existing} ${next}` : next;
}

function clamp01(v) {
  return Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0));
}
