import path from 'node:path';
import fs from 'node:fs';
import {bundle} from '@remotion/bundler';
import {selectComposition,renderStill,renderMedia} from '@remotion/renderer';

const output=path.resolve(import.meta.dirname,'../artifacts/porto-belo');
fs.mkdirSync(output,{recursive:true});
const serveUrl=await bundle({entryPoint:path.join(import.meta.dirname,'porto-belo-entry.tsx')});
const composition=await selectComposition({serveUrl,id:'PortoBeloMotion'});
await renderStill({serveUrl,composition,frame:150,output:path.join(output,'porto-belo-preview.png')});
let previous=-1;
await renderMedia({serveUrl,composition,codec:'h264',crf:17,pixelFormat:'yuv420p',concurrency:3,outputLocation:path.join(output,'porto-belo-motion.mp4'),onProgress:({progress})=>{const pct=Math.floor(progress*10)*10;if(pct!==previous){previous=pct;console.log(`${pct}%`);}}});
console.log(path.join(output,'porto-belo-motion.mp4'));
