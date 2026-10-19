import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {PortoBeloEditorial, type EditorialProps} from './PortoBeloEditorial';
const defaults: EditorialProps = {captions:[],brand:{paleta:{}}};
registerRoot(()=> <Composition id="PortoBeloEditorial" component={PortoBeloEditorial} width={576} height={1024} fps={30} durationInFrames={300} defaultProps={defaults}/>);
