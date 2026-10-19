import React, {useEffect, useState} from 'react';
import {AbsoluteFill, cancelRender, continueRender, delayRender, Easing, Img, interpolate, staticFile, useCurrentFrame} from 'remotion';
import type {Caption} from './PortoBeloCaptioned';

export type EditorialProps = {
  captions: Caption[];
  brand: {paleta: Record<string, string | number>};
};
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const ease = Easing.bezier(.22, .61, .36, 1);

// Generic architectural drawing: it does not represent either named building.
const Architecture: React.FC<{color: string; muted: string}> = ({color, muted}) => {
  const frame = useCurrentFrame();
  const draw = interpolate(frame, [24, 100], [0, 1], {...clamp, easing: ease});
  const drift = interpolate(frame, [0, 299], [0, -5], clamp);
  return <svg width="480" height="178" viewBox="0 0 480 178" style={{transform: `translateY(${drift}px) scale(${1 + frame / 22000})`, transformOrigin: '50% 100%'}}>
    <path d="M0 166H480" stroke={muted} opacity=".35"/>
    {[
      {x:12,w:62,h:67}, {x:87,w:69,h:111}, {x:170,w:77,h:150},
      {x:261,w:77,h:92}, {x:352,w:96,h:128},
    ].map((b,i)=><g key={i}>
      <path d={`M${b.x} 166 V${166-b.h} H${b.x+b.w} V166`} fill="none" stroke={color} strokeWidth=".8" pathLength="1" strokeDasharray="1" strokeDashoffset={1-draw}/>
      <path d={`M${b.x+7} ${166-b.h} v-6 h${b.w-14} v6`} fill="none" stroke={color} strokeWidth=".6" opacity={draw*.55}/>
      {Array.from({length:Math.floor(b.h/15)-1},(_,row)=><path key={row} d={`M${b.x+8} ${178-b.h+row*15}h${b.w-16}`} stroke={muted} strokeWidth=".5" opacity={draw*.6}/>)}
      {[1,2,3].map(col=><path key={col} d={`M${b.x+col*b.w/4} ${174-b.h}V165`} stroke={muted} strokeWidth=".5" opacity={draw*.5}/>)}
    </g>)}
  </svg>;
};

export const PortoBeloEditorial: React.FC<EditorialProps> = ({captions, brand}) => {
  const frame = useCurrentFrame();
  const [fontHandle] = useState(()=>delayRender('Carregando as fontes do contexto de design'));
  useEffect(()=>{
    Promise.all([
      new FontFace('EditorialDisplay', `url(${staticFile('porto-belo-brand/CormorantGaramond.ttf')})`, {weight:'300 700'}),
      new FontFace('EditorialBody', `url(${staticFile('porto-belo-brand/Montserrat.ttf')})`, {weight:'100 900'}),
    ].map(async font=>{(document.fonts as FontFaceSet & {add(font: FontFace): FontFaceSet}).add(await font.load());})).then(()=>continueRender(fontHandle)).catch(cancelRender);
  },[fontHandle]);
  const p=brand.paleta;
  const color=(key:string,fallback:string)=>typeof p[key]==='string'?p[key] as string:fallback;
  const wine=color('wine','#4D1512'), ink=color('ink','#211D1B'), champagne=color('champagne','#F6DDAE');
  const gold=color('gold','#E2A34B'), stone=color('stone','#B9B0A5'), ivory=color('ivory','#F8F5EE');
  const fade=(start:number)=>interpolate(frame,[start,start+12],[0,1],clamp);
  const reveal=(start:number)=>({opacity:fade(start),transform:`translateY(${interpolate(frame,[start,start+24],[9,0],{...clamp,easing:ease})}px)`});
  const time=60+frame/30;
  const caption=captions.find(c=>time>=c.start&&time<c.end);
  return <AbsoluteFill style={{backgroundColor:ink,color:champagne,fontFamily:'EditorialBody',overflow:'hidden'}}>
    <div style={{position:'absolute',inset:'0 0 auto',height:510,backgroundColor:wine}}/>
    <div style={{position:'absolute',top:70,left:48,right:48,display:'flex',alignItems:'center',justifyContent:'space-between',...reveal(0)}}>
      <div style={{fontSize:12,letterSpacing:3,fontWeight:500}}>PORTO BELO / SC</div>
      <Img src={staticFile('porto-belo-brand/logo-thc.png')} style={{width:72,height:'auto',objectFit:'contain'}}/>
    </div>
    <div style={{position:'absolute',left:48,top:152,fontFamily:'EditorialDisplay',fontSize:61,lineHeight:.96,fontWeight:400,letterSpacing:-1.4,...reveal(5)}}>Quem constrói<br/><span style={{fontStyle:'italic'}}>a cidade.</span></div>
    <div style={{position:'absolute',left:50,top:299,fontSize:12,letterSpacing:2,color:ivory,...reveal(15)}}>UM OLHAR SOBRE PORTO BELO</div>
    <div style={{position:'absolute',top:333,left:48,opacity:fade(20)}}><Architecture color={champagne} muted={stone}/></div>
    <div style={{position:'absolute',top:540,left:48,color:stone,fontSize:10,letterSpacing:2.3,...reveal(27)}}>CONSTRUTORAS NA REGIÃO</div>
    {[
      {name:'MayBelly',project:'Oporto',start:36,y:583},
      {name:'Dallo',project:'Palais Royal',start:90,y:701},
    ].map(item=><div key={item.name} style={{position:'absolute',top:item.y,left:48,right:48,...reveal(item.start)}}>
      <div style={{fontFamily:'EditorialDisplay',fontSize:43,lineHeight:1,fontWeight:500}}>{item.name}</div>
      <div style={{marginTop:10,fontSize:13,fontWeight:400,color:ivory}}>{item.project}<span style={{color:stone,margin:'0 9px'}}>·</span><span style={{color:stone,fontSize:11}}>Balneário Perequê</span></div>
      <div style={{height:1,background:stone,opacity:.25,marginTop:22,width:`${interpolate(frame,[item.start+4,item.start+34],[0,100],{...clamp,easing:ease})}%`}}/>
      <div style={{position:'absolute',top:16,right:0,width:21,height:1,background:gold,opacity:.85}}/>
    </div>)}
    {caption&&<div style={{position:'absolute',top:848,left:40,right:40,height:78,display:'flex',alignItems:'center',justifyContent:'center'}}>
      <div style={{fontSize:25,fontWeight:500,lineHeight:1.25,textAlign:'center',color:ivory,whiteSpace:'pre-line'}}>{caption.text}</div>
    </div>}
    <div style={{position:'absolute',left:48,right:48,bottom:58,display:'flex',justifyContent:'space-between',alignItems:'center',fontSize:9,letterSpacing:2,color:stone,opacity:fade(125)}}>
      <span>COSTA ESMERALDA</span><span style={{width:32,height:1,background:gold}}/><span>SANTA CATARINA</span>
    </div>
  </AbsoluteFill>;
};
