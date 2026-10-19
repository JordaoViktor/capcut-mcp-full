import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';

export type PortoBeloProps = {transparent?: boolean};
const gold = '#e5c88e';
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

// Architectural illustration, not a depiction of the featured developments.
const Skyline: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return <svg viewBox="0 0 480 230" width="480" height="230" style={{overflow: 'visible'}}>
    <defs><linearGradient id="tower" x2="0" y2="1"><stop stopColor="#294b52"/><stop offset="1" stopColor="#122a33"/></linearGradient></defs>
    {[{x:12,w:62,h:92},{x:90,w:75,h:152},{x:181,w:80,h:203},{x:279,w:62,h:129},{x:357,w:97,h:171}].map((b,i) => {
      const s=spring({frame:frame-9-i*4,fps,config:{damping:22,stiffness:95}});
      return <g key={i} style={{transform:`translateY(${220*(1-s)}px) scaleY(${s})`,transformOrigin:'0px 220px'}}>
        <rect x={b.x} y={220-b.h} width={b.w} height={b.h} fill="url(#tower)" stroke={gold} strokeOpacity=".55"/>
        <path d={`M ${b.x+8} ${220-b.h} v -10 h ${b.w-16} v 10`} fill="none" stroke={gold} strokeOpacity=".5"/>
        {Array.from({length:Math.floor((b.h-18)/17)},(_,j)=><g key={j} opacity={interpolate(frame,[26+i*4+j*2,42+i*4+j*2],[0,.8],clamp)}>
          {[0,1,2].map(k=><rect key={k} x={b.x+11+k*(b.w-18)/3} y={232-b.h+j*17} width="5" height="5" fill={gold}/>)}</g>)}
      </g>;
    })}
    <path d="M0 221H480" stroke={gold} strokeWidth="1.5" pathLength="1" strokeDasharray="1" strokeDashoffset={1-interpolate(frame,[0,30],[0,1],clamp)}/>
  </svg>;
};

export const PortoBeloMotion: React.FC<PortoBeloProps> = ({transparent=false}) => {
  const frame=useCurrentFrame();
  const {fps,durationInFrames}=useVideoConfig();
  const intro=spring({frame,fps,config:{damping:22,stiffness:85}});
  const exit=interpolate(frame,[durationInFrames-17,durationInFrames-1],[1,0],clamp);
  const appear=(delay:number)=>spring({frame:frame-delay,fps,config:{damping:24,stiffness:100}});
  return <AbsoluteFill style={{backgroundColor:transparent?'transparent':'#091b24',fontFamily:'Arial, sans-serif',color:'#f6f3e9',overflow:'hidden'}}>
    <AbsoluteFill style={{opacity:exit,background:transparent?'transparent':'radial-gradient(ellipse at 85% 10%, #24454a99, transparent 60%)'}}>
      {!transparent&&<AbsoluteFill style={{opacity:.16,backgroundImage:'linear-gradient(#507078 1px,transparent 1px),linear-gradient(90deg,#507078 1px,transparent 1px)',backgroundSize:'48px 48px',transform:`translateY(${frame*.07}px)`}}/>}
      <div style={{position:'absolute',inset:transparent?'38px 22px 160px':'0',background:transparent?'linear-gradient(150deg,rgba(9,27,36,.97),rgba(14,40,46,.96))':'transparent',borderRadius:transparent?24:0}}/>
      <div style={{position:'absolute',top:74,left:48,right:48,opacity:intro,transform:`translateY(${18*(1-intro)}px)`}}>
        <div style={{display:'flex',gap:10,alignItems:'center',fontSize:12,letterSpacing:3,color:gold}}><span style={{width:7,height:7,borderRadius:10,background:gold}}/> SANTA CATARINA</div>
        <div style={{fontSize:65,fontWeight:700,letterSpacing:-3,marginTop:19,lineHeight:1}}>Porto Belo<span style={{color:gold}}>.</span></div>
        <div style={{fontSize:19,color:'#b6c9cb',marginTop:14,letterSpacing:.3}}>Quem constrói a cidade</div>
      </div>
      <div style={{position:'absolute',top:243,left:48}}><Skyline/></div>
      <div style={{position:'absolute',top:508,left:48,fontSize:11,letterSpacing:2.6,color:gold,opacity:appear(24)}}>CONSTRUTORAS EM PORTO BELO</div>
      {[
        {name:'MayBelly',project:'Oporto',delay:36,tag:'BALNEÁRIO PEREQUÊ'},
        {name:'Dallo',project:'Palais Royal',delay:90,tag:'BALNEÁRIO PEREQUÊ'},
      ].map((item,i)=>{
        const p=appear(item.delay);
        const highlight=interpolate(frame,[item.delay,item.delay+25,item.delay+65,item.delay+95],[0,1,1,0],clamp);
        return <div key={item.name} style={{position:'absolute',left:48,right:48,top:540+i*129,padding:'19px 24px',border:'1px solid #426064',borderLeft:`3px solid ${gold}`,background:`rgba(39,65,69,${.45+highlight*.3})`,opacity:p,transform:`translateX(${35*(1-p)}px)`,borderRadius:'0 12px 12px 0'}}>
          <div style={{display:'flex',justifyContent:'space-between',alignItems:'center'}}><span style={{fontSize:32,fontWeight:700,letterSpacing:-.7}}>{item.name}</span><span style={{fontSize:20,color:gold}}>↗</span></div>
          <div style={{fontSize:17,color:'#cad8d8',marginTop:8}}>{item.project} <span style={{fontSize:9,color:'#92abad',letterSpacing:1,marginLeft:8}}>{item.tag}</span></div>
        </div>;
      })}
      <div style={{position:'absolute',top:827,left:48,right:48,display:'flex',justifyContent:'space-between',fontSize:10,letterSpacing:1.5,color:'#94afb2',opacity:appear(115)}}><span>COSTA ESMERALDA</span><span>PORTO BELO / SC</span></div>
      {!transparent&&<div style={{position:'absolute',bottom:79,left:48,right:48,height:2,background:'#29444b'}}><div style={{height:'100%',width:`${interpolate(frame,[0,durationInFrames-1],[0,100])}%`,background:gold}}/></div>}
    </AbsoluteFill>
  </AbsoluteFill>;
};
