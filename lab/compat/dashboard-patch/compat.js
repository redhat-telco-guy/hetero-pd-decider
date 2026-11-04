
// ---------- card compatibility (Stack tab) ----------
let CPD=null,cpBusy=false;const cpArm={};
function loadCompat(){if(cpBusy)return;cpBusy=true;api('api/compat').then(j=>{CPD=j;drawCompat();}).catch(e=>{CPD={error:e.message};drawCompat();}).finally(()=>{cpBusy=false;});}
setInterval(()=>{if(!$('stack').hidden)loadCompat();},10000);
const shortKey=k=>k?k.replace(/^kv-/,'').slice(0,8):'—';
const cardName2=c=>({'nvidia-t4':'T4','nvidia-a10g':'A10G','nvidia-l4':'L4','nvidia-a30':'A30','intel-gaudi3':'Gaudi 3'}[c]||c||'?');
function cpAction(id,action,btn){
  const k=id+action;
  if(!cpArm[k]){cpArm[k]=true;btn.textContent='Click again to confirm';setTimeout(()=>{cpArm[k]=false;drawCompat();},4000);return;}
  cpArm[k]=false;btn.disabled=true;btn.textContent='Saving…';
  api('api/compat/'+action,{id}).then(()=>setTimeout(loadCompat,800)).catch(e=>{alertBox(e.message);loadCompat();});
}
function alertBox(msg){const b=$('cpBody');const d=txt('div',msg,'err');b.prepend(d);setTimeout(()=>d.remove(),6000);}
function inputsText(i){if(!i)return 'not read yet';return [`model ${i.model}`,`vLLM ${i.version}`,`attention ${i.backend}`,`KV ${i.kv_dtype}, block ${i.block_size}`,`layout ${i.kv_buffer_device||'-'}${i.enable_permute_local_kv?', permute':''}${Object.keys(i.kv_layout_env||{}).length?', '+Object.entries(i.kv_layout_env).map(([a,b])=>a+'='+b).join(' '):''}`,`image ${(i.image||'').split('@').pop().slice(0,19)}`].join(' · ');}
function drawCompat(){
  const st=$('cpState'),b=$('cpBody');b.replaceChildren();
  if(!CPD){return;}
  if(CPD.error){st.className='pill p-idle';st.textContent='Not available';b.appendChild(txt('p',CPD.error,'muted small'));return;}
  if(!CPD.installed){st.className='pill p-idle';st.textContent='Not installed';b.appendChild(txt('p','Install the compatibility labeler first: bash lab/compat/60-compat-install.sh <namespace>','small'));return;}
  const live=CPD.pairs.filter(p=>p.live),waiting=live.filter(p=>p.status==='passed'&&!p.approved).length,testing=live.filter(p=>p.status==='testing').length;
  st.className='pill '+(waiting?'p-warn':testing?'p-move':'p-ok');st.textContent=waiting?`${waiting} waiting for approval`:testing?'Testing a pair':'Up to date';
  // servers
  b.appendChild(txt('div','Model servers and their keys','hwsec'));
  b.appendChild(tbl(['Server','Card','Role','Key','Settings behind the key'],CPD.pods.map(p=>[p.name,cardName2(p.cls),p.role==='decode'?'writes answers':p.role==='prefill'?'reads prompts':p.role,p.key?shortKey(p.key):'none yet',inputsText(p.inputs)])));
  // same-key pairs
  if(CPD.sameKey.length){b.appendChild(txt('div','Allowed automatically (same key)','hwsec'));
    b.appendChild(txt('p',CPD.sameKey.map(s=>`${cardName2(s.prefillClass)} (${s.prefill}) → ${cardName2(s.decodeClass)} (${s.decode})`).join(' · '),'small'));}
  // different-key pairs
  b.appendChild(txt('div','Pairs with different keys','hwsec'));
  if(!CPD.pairs.length){b.appendChild(txt('p','None: every reading card has the same key as the answering cards.','small muted'));return;}
  const statusText={untested:'Not tested yet',testing:'Testing…',passed:'Passed',failed:'Failed',error:'Test error'};
  const statusCls={untested:'p-idle',testing:'p-move',passed:'p-ok',failed:'p-bad',error:'p-warn'};
  const box=document.createElement('div');box.className='tablebox';const t=document.createElement('table');
  const hd=document.createElement('tr');['Reads → answers','Test','What the test found','Approval',''].forEach(h=>hd.appendChild(txt('th',h)));
  const th=document.createElement('thead');th.appendChild(hd);const tb=document.createElement('tbody');
  CPD.pairs.forEach(p=>{const tr=document.createElement('tr');if(!p.live)tr.style.opacity='.55';
    const c1=document.createElement('td');c1.append(txt('b',`${cardName2(p.prefillClass)} → ${cardName2(p.decodeClass)}`),document.createElement('br'),txt('span',`${shortKey(p.prefillKey)} → ${shortKey(p.decodeKey)}${p.live?'':' (no longer running)'}`,'small muted'));
    const c2=document.createElement('td');const pl=document.createElement('span');pl.className='pill '+(statusCls[p.status]||'p-idle');pl.textContent=statusText[p.status]||p.status;c2.appendChild(pl);
    const r=p.result||{};let found='—';
    if(p.status==='testing')found=`Running since ${(p.testStarted||'').slice(11,16)} UTC (a few minutes).`;
    else if(r.note)found=r.note;
    else if(r.compared===0&&r.errors)found=`All ${r.errors} split requests failed, so nothing could be compared. The answering card most likely refused the hand-off.`;
    else if(r.compared!=null)found=`${r.errors?r.errors+' split requests failed. ':''}First answer token matched in ${Math.round((r.first_token_same||0)*100)}% of ${r.compared} prompts; answers stayed identical for ${(r.split_agreement||0).toFixed(1)} tokens on average (the reading card on its own: ${(r.prefill_alone_agreement||0).toFixed(1)}).`;
    const c3=txt('td',found);c3.className='small';
    const c4=txt('td',p.approved?`Approved by ${p.approvedBy||'?'} ${(p.approvedAt||'').slice(0,16).replace('T',' ')}`:p.status==='passed'?'Waiting for your approval':p.revokedBy?`Revoked by ${p.revokedBy}`:'—');c4.className='small';
    const c5=document.createElement('td');c5.style.whiteSpace='nowrap';
    const btn=(label,action)=>{const x=document.createElement('button');x.className='btn';x.textContent=label;x.style.marginRight='6px';x.addEventListener('click',()=>cpAction(p.id,action,x));c5.appendChild(x);};
    if(p.live&&p.status==='passed'&&!p.approved)btn('Approve','approve');
    if(p.approved)btn('Revoke','revoke');
    if(p.live&&p.status!=='testing')btn('Re-test','retest');
    tr.append(c1,c2,c3,c4,c5);tb.appendChild(tr);});
  t.append(th,tb);box.appendChild(t);b.appendChild(box);
  b.appendChild(txt('p','A failed test cannot be approved. A re-test clears the approval until the new result is approved. If a server\'s settings change, it gets a new key and the pair must be tested and approved again.','small muted'));
}
