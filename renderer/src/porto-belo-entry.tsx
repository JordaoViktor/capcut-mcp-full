import React from 'react';
import {Composition,registerRoot} from 'remotion';
import {PortoBeloMotion} from './PortoBeloMotion';
import {PortoBeloCaptioned, type Caption} from './PortoBeloCaptioned';
registerRoot(()=> <>
  <Composition id="PortoBeloMotion" component={PortoBeloMotion} width={576} height={1024} fps={30} durationInFrames={300} defaultProps={{transparent:false}}/>
  <Composition id="PortoBeloCaptioned" component={PortoBeloCaptioned} width={576} height={1024} fps={30} durationInFrames={300} defaultProps={{captions:[] as Caption[]}}/>
</>);
