export interface AnimationSpec {
  kind: string;
  direction: "in" | "out";
  startMs: number;
  durationMs: number;
}

export declare function matchAnimationKind(entry: unknown): string | null;

export declare function applyAnimation(
  anim: AnimationSpec,
  localMs: number,
  style: Record<string, unknown>,
  text: string,
): string;
