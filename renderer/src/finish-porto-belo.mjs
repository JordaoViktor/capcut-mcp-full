import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {bundle} from '@remotion/bundler';
import {selectComposition,renderMedia} from '@remotion/renderer';

const folder=path.join(os.homedir(),'Movies/video-obra');
const artifacts=path.resolve(import.meta.dirname,'../artifacts/porto-belo');
const timestamp=(text)=>text.split(/[:,]/).map(Number).reduce((total,n,i)=>total+n*[3600,60,1,.001][i],0);
const captions=fs.readFileSync(path.join(folder,'video-obra-tratado.srt'),'utf8').trim().split(/\r?\n\r?\n/).map(block=>{
  const [,times,...lines]=block.split(/\r?\n/);
  const [start,end]=times.split(' --> ').map(timestamp);
  return {start,end,text:lines.join('\n')};
}).filter(cue=>cue.start<70&&cue.end>60);
const inputProps={captions};
const serveUrl=await bundle({entryPoint:path.join(import.meta.dirname,'porto-belo-entry.tsx')});
const composition=await selectComposition({serveUrl,id:'PortoBeloCaptioned',inputProps});
const insert=path.join(artifacts,'porto-belo-motion-legendado.mp4');
let previous=-1;
await renderMedia({serveUrl,composition,inputProps,codec:'h264',crf:17,concurrency:3,outputLocation:insert,onProgress:({progress})=>{const pct=Math.floor(progress*10)*10;if(pct!==previous){previous=pct;console.log(`Remotion ${pct}%`);}}});
const final=path.join(folder,'video-obra-motion-porto-belo.mp4');
// Only replace 60–70 seconds visually; copy the original AAC stream unchanged.
const result=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-y',
  '-i',path.join(folder,'video-obra-legendado-preview.mp4'),'-i',insert,
  '-filter_complex',"[1:v]format=yuva420p,fade=t=in:st=0:d=0.3:alpha=1,fade=t=out:st=9.5:d=0.5:alpha=1,setpts=PTS+60/TB[m];[0:v][m]overlay=enable='gte(t,60)*lt(t,70)':eof_action=pass:repeatlast=0[v]",
  '-map','[v]','-map','0:a:0','-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p','-c:a','copy','-movflags','+faststart',final],{stdio:'inherit'});
if(result.status!==0)throw new Error(`FFmpeg failed: ${result.status}`);
console.log(final);
