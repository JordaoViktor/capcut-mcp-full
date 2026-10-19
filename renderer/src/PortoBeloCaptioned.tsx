import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {PortoBeloMotion} from './PortoBeloMotion';

export type Caption = {start: number; end: number; text: string};
export const PortoBeloCaptioned: React.FC<{captions: Caption[]}> = ({captions}) => {
  const time = 60 + useCurrentFrame() / useVideoConfig().fps;
  const caption = captions.find((cue) => time >= cue.start && time < cue.end);
  return <AbsoluteFill>
    <PortoBeloMotion />
    {caption && <div style={{position:'absolute',left:28,right:28,top:848,height:76,display:'flex',alignItems:'center',justifyContent:'center'}}>
      <div style={{fontFamily:'Arial, sans-serif',fontSize:30,fontWeight:700,color:'white',textAlign:'center',lineHeight:1.15,WebkitTextStroke:'4px black',paintOrder:'stroke fill',whiteSpace:'pre-line'}}>{caption.text}</div>
    </div>}
  </AbsoluteFill>;
};
