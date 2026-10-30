
// ---------- live hardware (Stack tab) ----------
let HWD=null,hwBusy=false;
function loadHW(){if(hwBusy)return;hwBusy=true;api('api/hw').then(j=>{HWD=j;drawHW();}).catch(()=>{HWD=null;drawHW();}).finally(()=>{hwBusy=false;});}
setInterval(()=>{if(!$('stack').hidden)loadHW();},5000);
const f0=v=>v==null?'—':fmtN(v,0);
const lvl=(v,warn,crit)=>v==null?'':crit!=null&&v>=crit?'b':warn!=null&&v>=warn?'w':'';
function hbar(v,max,l){const d=document.createElement('div');d.className='hbar';const i=document.createElement('i');i.style.width=Math.max(2,Math.min(100,v/max*100))+'%';if(l)i.className=l;d.appendChild(i);return d;}
function tbl(head,rows){const box=document.createElement('div');box.className='tablebox';const t=document.createElement('table');const th=document.createElement('tr');head.forEach(h=>th.appendChild(txt('th',h)));const tb=document.createElement('tbody');
  rows.forEach(r=>{const tr=document.createElement('tr');r.forEach(c=>{const d=document.createElement('td');if(c instanceof Node)d.appendChild(c);else d.textContent=c==null?'—':c;tr.appendChild(d);});tb.appendChild(tr);});
  const thd=document.createElement('thead');thd.appendChild(th);t.append(thd,tb);box.appendChild(t);return box;}
function cardStop(c){return c.vendor==='Intel'?80:(c.slowdown||c.maxOp||85);}
function drawHW(){
  const st=$('hwState'),nodesEl=$('hwNodes'),iss=$('hwIssues');iss.replaceChildren();nodesEl.replaceChildren();
  if(!HWD){st.className='pill p-idle';st.textContent=online?'Not available':'Offline';$('hwAge').textContent='';
    iss.appendChild(txt('li','Live hardware readings need the hw-monitor service (lab/hwmon/53-hw-monitor.sh) and the dashboard opened from the cluster.'));return;}
  const issues=[];const now=Date.now()/1000;
  $('hwAge').textContent='updated '+Math.max(0,Math.round(now-HWD.t))+' s ago';
  const nodes=(HWD.nodes||[]).slice().sort((a,b)=>(a.node||'').localeCompare(b.node||''));
  nodes.forEach(n=>{
    const sh=(n.node||'?').split('.')[0];const p=document.createElement('div');p.className='panel';nodesEl.appendChild(p);
    const sv=n.server||{};
    p.appendChild(txt('h3',`${sh}${sv.model?' · '+(sv.maker||'').replace(/ Inc\.?| Computer| Cloud Technology/g,'')+' '+sv.model:''}`));
    if(n.error){p.appendChild(txt('p',n.error,'muted small'));issues.push(['w',`${sh}: ${n.error}`]);return;}
    p.appendChild(txt('div',[sv.bios&&'BIOS '+sv.bios,sv.bmc&&'BMC firmware '+sv.bmc,sv.upSince&&'up since '+sv.upSince].filter(Boolean).join(' · '),'small muted'));
    let cards=(n.cards||[]).map(c=>({...c}));
    if(HWD.gaudiNode&&HWD.gaudiNode===n.node)cards=cards.concat((HWD.gaudi||[]).map(g=>({vendor:'Intel',id:g.id,c:g.c,w:g.w,limitW:600,util:g.util,serial:g.serial,stale:g.stale})));
    const zones=n.zones||[],fans=n.fans||[],temps=n.temps||[];
    const inlet=temps.find(t=>/inlet|ambient/i.test(t.name));const exh=temps.find(t=>/exhaust|outlet/i.test(t.name));
    const rpm=fans.map(f=>f.rpm);const avg=rpm.length?rpm.reduce((a,b)=>a+b,0)/rpm.length:null;
    const mini=document.createElement('div');mini.className='mini';
    const m=(v,l)=>{const d=document.createElement('div');d.append(txt('b',v),txt('span',l));mini.appendChild(d);};
    m(zones.length?zones.map(z=>f0(z.pct)).join(' / ')+'%':avg!=null?fmtN(avg/1000,1)+'k':'—',zones.length?'fan control setting':'fan RPM (average)');
    m(inlet?f0(inlet.c)+' °C':'—','air in'+(exh?` · out ${f0(exh.c)} °C`:''));
    m(n.power!=null?f0(n.power)+' W':'—','server power');
    const hc=cards.reduce((a,c)=>c.c!=null&&(a==null||c.c>a.c)?c:a,null);
    m(hc?f0(hc.c)+' °C':'—',hc?'hottest card ('+hc.id+')':'cards');
    p.appendChild(mini);
    if(cards.length){p.appendChild(txt('div','Cards','hwsec'));
      p.appendChild(tbl(['Card','Temp','Stop / slowdown','Room left','Power','Load'],cards.map(c=>{const stop=cardStop(c);const l=lvl(c.c,stop-8,stop);
        if(l==='b')issues.push(['b',`${sh}: ${c.id} at ${f0(c.c)} °C (stop ${stop} °C)`]);else if(l==='w')issues.push(['w',`${sh}: ${c.id} at ${f0(c.c)} °C, only ${f0(stop-c.c)} °C below ${stop} °C`]);
        return [c.id+(c.stale?' (no fresh reading)':''),c.c==null?'—':f0(c.c)+' °C',stop+' °C'+(c.vendor==='Intel'?' (watchdog)':''),hbar(c.c||0,stop,l),c.w==null?'—':`${f0(c.w)} of ${f0(c.limitW)} W`,c.util==null?'—':f0(c.util)+'%'];})));}
    if(zones.length&&hc&&hc.c!=null){const zp=Math.max(...zones.map(z=>z.pct));if(zp<=40&&hc.c>=cardStop(hc)-15)issues.push(['b',`${sh}: fans held at ${f0(zp)}% while ${hc.id} is at ${f0(hc.c)} °C`]);}
    p.appendChild(txt('div','Hottest server sensors (from the BMC)','hwsec'));
    p.appendChild(tbl(['Sensor','Now','Warn','Critical',''],temps.filter(t=>!/inlet|ambient/i.test(t.name)).slice(0,6).map(t=>{const l=lvl(t.c,t.warn,t.crit);
      if(l==='b')issues.push(['b',`${sh}: ${t.name} at ${f0(t.c)} °C, at or above its critical limit ${f0(t.crit)} °C`]);else if(l==='w')issues.push(['w',`${sh}: ${t.name} at ${f0(t.c)} °C, above its warning limit ${f0(t.warn)} °C`]);
      return [t.name,f0(t.c)+' °C',t.warn==null?'—':f0(t.warn)+' °C',t.crit==null?'—':f0(t.crit)+' °C',hbar(t.c,t.crit||100,l)];})));
    if((n.blind||[]).length){p.appendChild(txt('p',`The BMC cannot read: ${n.blind.join(', ')}. Its fan control does not see those parts.`,'small'));issues.push(['w',`${sh}: BMC has no reading for ${n.blind.length} card-slot sensors (${n.blind.slice(0,3).join(', ')}…)`]);}
    if(fans.length){p.appendChild(txt('div','Fans','hwsec'));
      p.appendChild(txt('div',`${fans.length} fan rotors, ${f0(Math.min(...rpm))}–${f0(Math.max(...rpm))} RPM`+(zones.length?` · fan control ${zones.map(z=>z.name.replace(/_/g,' ')+' '+f0(z.pct)+'%').join(', ')}`:' · this server reports RPM only')+(fans.some(f=>f.status&&!/ok/i.test(f.status))?' · a fan reports a problem':''),'small'));}
    const nics=(n.nics||[]).filter(x=>x.state==='up'||x.default);
    if(nics.length){p.appendChild(txt('div','Network cards in use','hwsec'));
      p.appendChild(tbl(['Port','Speed','Errors','Drops','Card'],nics.map(x=>{const e=x.rxErr+x.txErr+x.crc;if(e>0)issues.push(['w',`${sh}: ${x.name} has ${fmtN(e)} errors`]);
        return [x.name+(x.default?' (cluster traffic)':''),x.speed>0?(x.speed>=1000?fmtN(x.speed/1000)+' Gb/s':x.speed+' Mb/s'):'—',fmtN(e),fmtN(x.rxDrop+x.txDrop),(x.desc||'').replace(/^.*?: /,'').slice(0,48)];})));}
    const ch=(n.chips||[]).filter(c=>!/nvme/i.test(c.chip));
    if(ch.length){const d=document.createElement('details');d.className='hw';d.appendChild(txt('summary',`Chip temperatures from Linux drivers (${ch.length})`));
      d.appendChild(txt('pre',ch.map(c=>`${c.chip} ${c.dev} ${c.label}: ${f0(c.c)} °C${c.max?' max '+f0(c.max):''}${c.crit?' crit '+f0(c.crit):''}`).join('\n')));p.appendChild(d);}
    const k=n.kernel||{};const d2=document.createElement('details');d2.className='hw';d2.appendChild(txt('summary',`Kernel warnings since boot about cards, PCIe or heat: ${k.count==null?'—':k.count}`));
    d2.appendChild(txt('pre',(k.last||[]).join('\n')||'none'));p.appendChild(d2);
    const d3=document.createElement('details');d3.className='hw';d3.appendChild(txt('summary','Latest BMC events'));d3.appendChild(txt('pre',(n.sel||[]).join('\n')||'none'));p.appendChild(d3);
  });
  (HWD.watchdog||[]).slice(-2).forEach(w=>issues.push(['w',w]));
  const order={b:0,w:1};issues.sort((a,b)=>order[a[0]]-order[b[0]]);
  const worst=issues.length?issues[0][0]:'';
  st.className='pill '+(worst==='b'?'p-bad':worst==='w'?'p-warn':'p-ok');st.textContent=worst==='b'?'Needs attention':worst==='w'?'Warnings':'All normal';
  issues.slice(0,8).forEach(([l,t])=>{const li=txt('li',t);if(l==='b')li.className='bad-t';iss.appendChild(li);});
  drawHWCharts();
}
function drawHWCharts(){
  const S2=HWD.series||{},sers=Object.keys(S2);const nm=k=>k.split(':')[0];
  const nvC=['var(--nv)','color-mix(in srgb,var(--nv) 55%,var(--ink))'],gdC=['var(--gd)','color-mix(in srgb,var(--gd) 55%,var(--ink))'];
  const g=(HWD.gaudi||[]);const temp=[];
  sers.filter(k=>k.includes(':card:')).sort().forEach((k,i)=>temp.push({name:k.split(':card:')[1],color:nvC[i%2],pts:S2[k]}));
  sers.filter(k=>k.startsWith('gaudi:')).sort().forEach((k,i)=>{const s=k.slice(6);const gg=g.find(x=>x.serial===s);temp.push({name:gg?gg.id:'Gaudi '+s,color:gdC[i%2],pts:S2[k]});});
  const nodeColor=k=>HWD.gaudiNode&&HWD.gaudiNode.split('.')[0]===nm(k)?'var(--gd)':'var(--nv)';
  const per=suf=>sers.filter(k=>k.endsWith(':'+suf)).sort().map(k=>({name:nm(k),color:nodeColor(k),pts:S2[k]}));
  lineChart('chTemp','lgTemp',temp,{unit:'°C',refs:[{v:80,label:'Gaudi stop 80 °C'}],yMin:20});
  lineChart('chPow','lgPow',per('power'),{unit:'W',yMin:0});
  lineChart('chFan','lgFan',per('fanrpm'),{unit:'RPM',yMin:0});
  lineChart('chZone','lgZone',per('fanpct'),{unit:'%',yMin:0,yMax:100,empty:'Only the Gaudi server reports a fan setting in percent.'});
}
function lineChart(id,lg,series,o){
  const el=$(id),L=$(lg);el.replaceChildren();L.replaceChildren();
  series=series.filter(s=>s.pts&&s.pts.length);
  if(!series.length){el.appendChild(txt('p',o.empty||'No readings yet.','small muted'));return;}
  if(series.length>1)series.forEach(s=>{const sp=document.createElement('span');const i=document.createElement('i');i.style.background=s.color;sp.append(i,s.name);L.appendChild(sp);});
  const W=Math.max(300,el.clientWidth||460),H=190,ml=44,mr=96,mt=10,mb=24;const now=Date.now()/1000,t0=now-3600;
  let lo=Infinity,hi=-Infinity;series.forEach(s=>s.pts.forEach(p=>{lo=Math.min(lo,p[1]);hi=Math.max(hi,p[1]);}));(o.refs||[]).forEach(r=>{hi=Math.max(hi,r.v);});
  if(o.yMin!=null)lo=Math.min(lo,o.yMin);if(o.yMax!=null)hi=Math.max(hi,o.yMax);if(hi-lo<1)hi=lo+1;
  const steps=[1,2,5,10,20,25,50,100,200,250,500,1000,2000,2500,5000,10000];const step=steps.find(st=>(hi-lo)/st<=5)||20000;
  lo=Math.floor(lo/step)*step;hi=Math.ceil(hi/step)*step;
  const X=t=>ml+(t-t0)/3600*(W-ml-mr),Y=v=>mt+(1-(v-lo)/(hi-lo))*(H-mt-mb);
  const NS='http://www.w3.org/2000/svg';const sv=document.createElementNS(NS,'svg');sv.setAttribute('viewBox',`0 0 ${W} ${H}`);sv.setAttribute('role','img');
  sv.setAttribute('aria-label',series.map(s=>`${s.name} now ${f0(s.pts[s.pts.length-1][1])} ${o.unit}`).join('; '));
  const el2=(tag,a,t)=>{const e=document.createElementNS(NS,tag);for(const k in a)e.setAttribute(k,a[k]);if(t!=null)e.textContent=t;sv.appendChild(e);return e;};
  for(let v=lo;v<=hi+1e-9;v+=step){el2('line',{x1:ml,x2:W-mr,y1:Y(v),y2:Y(v),stroke:'var(--grid)'});el2('text',{x:ml-6,y:Y(v)+4,'text-anchor':'end','font-size':11,fill:'var(--muted)'},fmtN(v));}
  for(let m=0;m<=60;m+=15){const t=t0+m*60;el2('text',{x:X(t),y:H-6,'text-anchor':'middle','font-size':11,fill:'var(--muted)'},m===60?'now':new Date(t*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));}
  (o.refs||[]).forEach(r=>{if(r.v<lo||r.v>hi)return;el2('line',{x1:ml,x2:W-mr,y1:Y(r.v),y2:Y(r.v),stroke:'var(--bad)','stroke-dasharray':'4 4','stroke-width':1.5});el2('text',{x:ml+4,y:Y(r.v)-4,'font-size':11,fill:'var(--bad)'},r.label);});
  const ends=[];
  series.forEach(s=>{const pts=s.pts.filter(p=>p[0]>=t0);if(!pts.length)return;let d='';let prev=null;
    pts.forEach(p=>{d+=(prev&&p[0]-prev[0]<90?'L':'M')+X(p[0]).toFixed(1)+' '+Y(p[1]).toFixed(1);prev=p;});
    el2('path',{d,fill:'none',stroke:s.color,'stroke-width':2,'stroke-linejoin':'round','stroke-linecap':'round'});
    const lp=pts[pts.length-1];el2('circle',{cx:X(lp[0]),cy:Y(lp[1]),r:4,fill:s.color,stroke:'var(--surface)','stroke-width':2});ends.push({y:Y(lp[1]),s,v:lp[1]});});
  ends.sort((a,b)=>a.y-b.y);for(let i=1;i<ends.length;i++)if(ends[i].y-ends[i-1].y<13)ends[i].y=ends[i-1].y+13;
  ends.forEach(e=>el2('text',{x:W-mr+8,y:e.y+4,'font-size':11,fill:'var(--ink)'},`${series.length>1?e.s.name+' ':''}${f0(e.v)}`));
  const cross=el2('line',{y1:mt,y2:H-mb,stroke:'var(--muted)','stroke-width':1,visibility:'hidden'});
  const tip=document.createElement('div');tip.className='tip';tip.hidden=true;el.append(sv,tip);
  sv.addEventListener('pointermove',e=>{const r=sv.getBoundingClientRect();const x=(e.clientX-r.left)*W/r.width;if(x<ml||x>W-mr){cross.setAttribute('visibility','hidden');tip.hidden=true;return;}
    const t=t0+(x-ml)/(W-ml-mr)*3600;cross.setAttribute('x1',x);cross.setAttribute('x2',x);cross.setAttribute('visibility','visible');
    tip.replaceChildren(txt('b',new Date(t*1000).toLocaleTimeString()));
    series.forEach(s=>{let best=null;s.pts.forEach(p=>{if(!best||Math.abs(p[0]-t)<Math.abs(best[0]-t))best=p;});if(best&&Math.abs(best[0]-t)<90){const d=document.createElement('div');const i=document.createElement('i');i.style.cssText=`display:inline-block;width:10px;height:3px;margin-right:5px;vertical-align:middle;background:${s.color}`;d.append(i,`${s.name}: ${f0(best[1])} ${o.unit}`);tip.appendChild(d);}});
    tip.hidden=false;tip.style.left=Math.min(e.clientX-r.left+12,r.width-170)+'px';tip.style.top='8px';});
  sv.addEventListener('pointerleave',()=>{cross.setAttribute('visibility','hidden');tip.hidden=true;});
}
