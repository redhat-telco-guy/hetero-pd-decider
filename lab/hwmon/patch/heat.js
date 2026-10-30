
// ---------- heat test (Stack tab) ----------
function heatCardsVis(){$('heatCardsL').hidden=$('heatTarget').value==='a30';}
$('heatTarget').addEventListener('change',heatCardsVis);heatCardsVis();
$('heatGo').addEventListener('click',()=>{$('heatErr').textContent='';
  const b={target:$('heatTarget').value,gaudiCards:+$('heatCards').value,users:+$('heatUsers').value,minutes:+$('heatMin').value};
  api('api/heat/start',b).then(()=>loadHW()).catch(e=>{$('heatErr').textContent=e.message;});});
$('heatStop').addEventListener('click',()=>{api('api/heat/stop',{}).then(()=>loadHW()).catch(e=>{$('heatErr').textContent=e.message;});});
function drawHeat(){
  const h=(HWD&&HWD.heat)||{};const run=!!h.running;
  $('heatGo').hidden=run;$('heatStop').hidden=!run;['heatTarget','heatCards','heatUsers','heatMin'].forEach(i=>$(i).disabled=run);
  const s=$('heatStatus');s.replaceChildren();
  if(!h.phase||h.phase==='idle'){s.textContent='No heat test has run since the dashboard started.';return;}
  const now=Date.now()/1000;const tgt={a30:'A30',gaudi:'Gaudi 3',both:'A30 and Gaudi 3'}[h.target]||h.target;
  const p=document.createElement('div');
  const pl=document.createElement('span');pl.className='pill '+(h.phase==='load'?'p-move':h.phase==='starting'?'p-warn':h.phase==='stopped'?'p-bad':'p-ok');
  pl.textContent={load:'Load running',starting:'Starting',stopped:'Stopped',done:'Finished'}[h.phase]||h.phase;p.append(pl,' ',`${tgt} · ${h.users} at a time per card · ${h.minutes} min`);s.appendChild(p);
  if(h.msg)s.appendChild(txt('div',h.msg,h.phase==='stopped'?'bad-t':''));
  if(h.started){const el=Math.max(0,Math.min(now,h.until)-h.started);const left=Math.max(0,h.until-now);
    s.appendChild(txt('div',`${run&&h.phase==='load'?`${Math.floor(left/60)}:${String(Math.floor(left%60)).padStart(2,'0')} left · `:''}${fmtN(h.done)} requests done · ${el>0?fmtN(h.tokens/el,0):0} tokens/s · ${fmtN(h.errors)} errors${h.lastErr?' (last: '+h.lastErr+')':''}`,'muted'));}
}
