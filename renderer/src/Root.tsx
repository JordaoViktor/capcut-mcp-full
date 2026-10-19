import React from "react";
import { Composition } from "remotion";
import { CapcutDraft } from "./CapcutDraft";
import { draftMetadata } from "./model.mjs";

/**
 * Single dynamic composition: `calculateMetadata` derives width/height/fps/
 * durationInFrames from the CapCut draft passed as input props, so one
 * composition serves every project.
 */
export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="CapcutDraft"
      component={CapcutDraft}
      durationInFrames={1}
      fps={30}
      width={1920}
      height={1080}
      defaultProps={{ draft: {}, draftDir: undefined }}
      calculateMetadata={({ props }) => draftMetadata(props.draft)}
    />
  );
};
