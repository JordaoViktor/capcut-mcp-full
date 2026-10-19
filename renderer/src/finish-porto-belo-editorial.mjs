import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {bundle} from '@remotion/bundler';
import {selectComposition,renderMedia,renderStill} from '@remotion/renderer';

const folder=path.join(os.homedir(),'Movies/video-obra');
const artifacts=path.resolve(import.meta.dirname,'../artifacts/porto-belo-design');
const timestamp=(text)=>text.split(/[:,]/).map(Number).reduce((total,n,i)=>total+n*[3600,60,1,.001][i],0);
const captions=fs.readFileSync(path.join(folder,'video-obra-tratado.srt'),'utf8').trim().split(/\r?\n\r?\n/).map(block=>{
  const [,times,...lines]=block.split(/\r?\n/);
  const [start,end]=times.split(' --> ').map(timestamp);
  return {start,end,text:lines.join('\n')};
}).filter(cue=>cue.start<70&&cue.end>60);
const configDir=process.env.CAPCUT_MCP_CONFIG_DIR || path.join(os.homedir(),'.config/capcut-mcp');
const brand=JSON.parse(fs.readFileSync(path.join(configDir,'brand.json'),'utf8'));
const stylePath=path.join(configDir,'projects/0344C802-2BB0-4763-9DF0-B6B4ECDE15F5/style.json');
const overrides=fs.existsSync(stylePath)?JSON.parse(fs.readFileSync(stylePath,'utf8')).overrides || {}:{};
function merge(a,b){const result={...a};for(const [key,value] of Object.entries(b)){result[key]=value&&typeof value==='object'&&!Array.isArray(value)?merge(a[key]||{},value):value;}return result;}
const resolvedBrand=merge(brand,overrides);
fs.mkdirSync(artifacts,{recursive:true});
fs.writeFileSync(path.join(artifacts,'brand-aplicada.json'),JSON.stringify(resolvedBrand,null,2));
const inputProps={captions,brand:resolvedBrand};
const serveUrl=await bundle({entryPoint:path.join(import.meta.dirname,'porto-belo-editorial-entry.tsx'),publicDir:path.resolve(import.meta.dirname,'../public')});
const composition=await selectComposition({serveUrl,id:'PortoBeloEditorial',inputProps});
const insert=path.join(artifacts,'porto-belo-motion-design.mp4');
await renderStill({serveUrl,composition,inputProps,frame:180,output:path.join(artifacts,'preview-design.png')});
let previous=-1;
await renderMedia({serveUrl,composition,inputProps,codec:'h264',crf:17,concurrency:3,outputLocation:insert,onProgress:({progress})=>{const pct=Math.floor(progress*10)*10;if(pct!==previous){previous=pct;console.log(`Remotion ${pct}%`);}}});
const final=path.join(folder,'video-obra-motion-porto-belo-design.mp4');
// Only replace 60–70 seconds visually; copy the original AAC stream unchanged.
const result=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-y',
  '-i',path.join(folder,'video-obra-legendado-preview.mp4'),'-i',insert,'-i',path.join(folder,'video-obra-tratado.mp4'),
  '-filter_complex',"[0:v][2:v]overlay=enable='gte(t,60)*lt(t,70)':eof_action=pass[clean];[1:v]format=yuva420p,fade=t=in:st=0:d=0.4:alpha=1,fade=t=out:st=9.6:d=0.4:alpha=1,setpts=PTS+60/TB[m];[clean][m]overlay=enable='gte(t,60)*lt(t,70)':eof_action=pass:repeatlast=0[v]",
  '-map','[v]','-map','0:a:0','-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p','-c:a','copy','-movflags','+faststart',final],{stdio:'inherit'});
if(result.status!==0)throw new Error(`FFmpeg failed: ${result.status}`);
console.log(final);
