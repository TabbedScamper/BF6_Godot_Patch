(function (root) {
  'use strict';
  const CHANNEL = 'bf6-home';
  const text = (v, fallback = '', max = 512) => typeof v === 'string' ? v.slice(0, max) : fallback;
  const id = v => typeof v === 'string' && v.length > 0 && v.length <= 512 && !/[\u0000-\u001f]/.test(v) ? v : '';
  const count = v => Number.isSafeInteger(v) && v >= 0 ? v : null;
  function localImage(v) {
    if (typeof v !== 'string') return '';
    if (v.length <= 5592440 && /^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(v)) return v;
    if (v.length > 512) return '';
    return /^(?:\.\.\/mapthumbs\/|mapthumbs\/|images\/)[a-zA-Z0-9_-]+\.(?:png|jpe?g|webp)$/i.test(v) ? v : '';
  }
  function records(values, fn, limit = 20000) {
    const seen = new Set();
    return (Array.isArray(values) ? values.slice(0, limit) : []).flatMap(raw => {
      if (!raw || typeof raw !== 'object' || !id(raw.id) || seen.has(raw.id)) return [];
      seen.add(raw.id); return [fn(raw)];
    });
  }
  function normalize(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new TypeError('Home state must be an object');
    const simple = value => ({id:id(value.id), name:text(value.name, value.id), image:localImage(value.image), available:value.available !== false,
      subtitle:text(value.subtitle),imported:value.imported===true,nameOverlay:value.nameOverlay===true,searchText:text(value.searchText,'',4096)});
    return {
      eyebrow:text(raw.eyebrow, 'B F 6   S D K'), title:text(raw.title, 'CHOOSE MAPS'),
      subtitle:typeof raw.subtitle === 'string' ? text(raw.subtitle) : null, status:text(raw.status, '', 4096), busy:raw.busy === true,experienceHeading:text(raw.experienceHeading,'My experiences'),
      maps:records(raw.maps, m => ({...simple(m), size:['S','M','L','XL'].includes(m.size) ? m.size : 'M', paid:m.paid !== false,
        objectCount:count(m.objectCount), backupCount:count(m.backupCount) || 0,
        saves:records(m.saves, s => ({id:id(s.id), name:text(s.name,s.id), canLink:s.canLink === true, canDelete:s.canDelete === true}))})),
      groups:records(raw.groups, g => ({id:g.id,label:text(g.label)}), 8).filter(g => ['paid','free'].includes(g.id)),
      actions:records(raw.actions, a => ({id:a.id,label:text(a.label,a.id),visible:a.visible !== false,enabled:a.enabled !== false,
        placement:['header','prepare','footer','experiences'].includes(a.placement) ? a.placement : 'header',tooltip:text(a.tooltip),unread:a.unread === true,allowWhileBusy:a.allowWhileBusy === true||a.placement==='prepare'}),128),
      experiences:records(raw.experiences,simple)
    };
  }
  function authorized(state, event) {
    if (!state || !event || typeof event !== 'object') return null;
    if (event.action === 'ready') return {channel:CHANNEL,action:'ready'};
    if (event.action === 'tool') {
      const action = state.actions.find(a => a.id === event.id && a.visible && a.enabled && (!state.busy||a.allowWhileBusy));
      return action ? {channel:CHANNEL,action:'tool',id:action.id} : null;
    }
    if (state.busy) return null;
    if (event.action === 'open_experience') {
      const item = state.experiences.find(v => v.id === event.id && v.available);
      return item ? {channel:CHANNEL,action:event.action,id:item.id} : null;
    }
    const map = state.maps.find(m => m.id === event.id);
    if (!map) return null;
    if (event.action === 'open_map') return map.available ? {channel:CHANNEL,action:'open_map',id:map.id} : null;
    if (event.action === 'backups') return map.backupCount > 0 ? {channel:CHANNEL,action:'backups',id:map.id} : null;
    if (!['resume','link_save','delete_save'].includes(event.action)) return null;
    const save = map.saves.find(s => s.id === event.saveId);
    if (!save || (event.action === 'link_save' && !save.canLink) || (event.action === 'delete_save' && !save.canDelete)) return null;
    return {channel:CHANNEL,action:event.action,id:map.id,saveId:save.id};
  }
  function transport(event) {
    const payload = JSON.stringify(event);
    if (typeof root.bf6HomeHostPost === 'function') root.bf6HomeHostPost(payload);
    else if (root.ipc && typeof root.ipc.postMessage === 'function') root.ipc.postMessage(payload);
    else if (root.console && typeof root.console.log === 'function') root.console.log('BF6_HOME:' + payload);
  }
  function controller(send = transport, render = () => {}) {
    let state = normalize({});
    return {
      setState(raw) { const next = normalize(raw); state = next; render(next); return true; },
      dispatch(event) { const checked = authorized(state,event); if (!checked) return false; send(checked); return true; },
      getState() { return normalize(state); }
    };
  }
  const exported = {normalize,authorized,localImage,controller};
  if (typeof module !== 'undefined' && module.exports) module.exports = exported;
  if (!root.document) return;

  const doc = root.document, elements = new Map(), cards = new Map();
  const el = (tag, className, value) => {const node=doc.createElement(tag);if(className)node.className=className;if(value!==undefined)node.textContent=value;return node;};
  const byId = key => doc.getElementById(key);
  const focusKey = node => node && node.dataset ? node.dataset.focusKey : null;
  const button = (label, className, event, key) => {
    const node=el('button',className,label);node.type='button';node.dataset.focusKey=key;
    node.addEventListener('click', e => {e.stopPropagation();app.dispatch(event);});return node;
  };
  let app, experienceQuery = '';
  function makeCard(data, kind, busy) {
    const card=el('article','map-card' + (!data.available?' unavailable':''));
    const openAction=kind==='map'?'open_map':'open_experience';
    const open=button('', 'map-open', {action:openAction,id:data.id},kind+':'+data.id);
    open.setAttribute('aria-label',(data.available?'Open ':'Unavailable: ')+data.name);open.disabled=busy||!data.available;card.append(open);
    const art=el('div','art');
    const placeholder=el('span','no-preview','NO PREVIEW');art.append(placeholder);
    if(data.image){const img=el('img');img.alt='';img.src=data.image;img.loading='lazy';img.decoding='async';placeholder.hidden=true;
      img.addEventListener('error',()=>{img.remove();placeholder.hidden=false;},{once:true});art.append(img);}
    if(kind==='map')art.append(el('span','size-badge',data.size));
    else if(data.nameOverlay){placeholder.hidden=true;art.append(el('span','experience-name-overlay',data.name.toUpperCase()));}
    card.append(art);
    const bar=el('div','namebar'), caption=el('div','map-caption');
    const name=el('h3','map-name',data.name.toUpperCase());name.title=data.name;caption.append(name);
    if(kind==='map')caption.append(el('p','object-count',data.objectCount===null?'':data.objectCount+' OBJECTS'));
    else caption.append(el('p','object-count',data.subtitle));bar.append(caption);
    if(kind==='map'&&data.saves.length){
      const details=el('details','resume');details.dataset.mapId=data.id;
      const summary=el('summary','', 'RESUME ('+data.saves.length+')');summary.dataset.focusKey='resume:'+data.id;
      summary.setAttribute('aria-label','Resume a saved project on '+data.name);
      if(busy){summary.tabIndex=-1;summary.addEventListener('click',e=>e.preventDefault());}
      details.append(summary);const menu=el('div','resume-menu');
      data.saves.forEach(save=>{
        const row=el('div','save-row');
        const add=(action,label,cls)=>{const b=button(label,cls,{action,id:data.id,saveId:save.id},action+':'+data.id+':'+save.id);b.disabled=busy;row.append(b);};
        add('resume',save.name,'save-name');if(save.canLink)add('link_save','LINK','save-link');if(save.canDelete)add('delete_save','x','save-delete');menu.append(row);
      });details.append(menu);bar.append(details);
    }
    if(kind==='map'&&data.backupCount){const backups=button('BACKUPS ('+data.backupCount+')','backups',{action:'backups',id:data.id},'backups:'+data.id);backups.disabled=busy;backups.title='Every rolling backup this map has, newest first. Opening one leaves your saves untouched.';bar.append(backups);}
    bar.append(el('span',data.imported?'imported':'plus',data.imported?'IMPORTED':'+'));card.append(bar);return card;
  }
  function render(state) {
    const scroller=byId('map-scroll'), scroll=scroller.scrollTop, focused=focusKey(doc.activeElement);
    const opened=new Set(Array.from(doc.querySelectorAll('details[open]')).map(n=>n.dataset.mapId));
    byId('eyebrow').textContent=state.eyebrow;byId('title').textContent=state.title;
    byId('subtitle').textContent=state.subtitle===null ? state.maps.length+' maps  -  click a map to open its base, or resume a saved project below it.' : state.subtitle;
    byId('status').textContent=state.status;byId('status').hidden=!state.status;byId('home').setAttribute('aria-busy',String(state.busy));
    for(const placement of ['header','prepare','footer']){
      const host=byId(placement+'-actions');const fragment=doc.createDocumentFragment();
      state.actions.filter(a=>a.visible&&a.placement===placement).forEach(a=>{const b=button(a.label.toUpperCase(),'tool'+(a.unread?' unread':''),{action:'tool',id:a.id},'tool:'+a.id);b.disabled=(state.busy&&!a.allowWhileBusy)||!a.enabled;b.title=a.tooltip;fragment.append(b);});host.replaceChildren(fragment);
    }
    const groups=[{id:'paid',label:'Battlefield 6 maps',kind:'map',items:state.maps.filter(m=>m.paid)},
      {id:'free',label:'RedSec maps - free for everyone',kind:'map',items:state.maps.filter(m=>!m.paid)}];
    state.groups.forEach(g=>{const group=groups.find(v=>v.id===g.id);if(group&&g.label)group.label=g.label;});
    if(state.experiences.length)groups.push({id:'experiences',label:state.experienceHeading,kind:'experience',items:state.experiences.filter(v=>(v.name+' '+v.id+' '+v.searchText).toLowerCase().includes(experienceQuery.toLowerCase()))});
    const used=new Set(),groupNodes=[];
    groups.forEach(group=>{
      let section=elements.get(group.id);if(!section){section=el('section','map-group');section.append(el('h2','section-title'),el('div','map-grid'));elements.set(group.id,section);}
      if(group.id==='experiences'){
        if(!section.querySelector('.experience-search')){const search=el('input','experience-search');search.type='search';search.placeholder='Search your experiences';search.setAttribute('aria-label','Search your experiences');search.title='A name, the first characters of an id, or a map codename.';search.dataset.focusKey='experience-search';search.value=experienceQuery;search.addEventListener('input',()=>{experienceQuery=search.value;render(app.getState());});section.insertBefore(search,section.lastChild);section.insertBefore(el('nav','experience-actions'),section.lastChild);}
        const actions=section.querySelector('.experience-actions');actions.replaceChildren();state.actions.filter(a=>a.visible&&a.placement==='experiences').forEach(a=>{const b=button(a.label.toUpperCase(),'tool',{action:'tool',id:a.id},'tool:'+a.id);b.disabled=(state.busy&&!a.allowWhileBusy)||!a.enabled;b.title=a.tooltip;actions.append(b);});
      }
      section.firstChild.textContent=group.label.toUpperCase();const grid=section.lastChild,nodes=[];
      group.items.forEach(data=>{const key=group.kind+':'+data.id, signature=JSON.stringify([data,state.busy]);used.add(key);let entry=cards.get(key);
        if(!entry||entry.signature!==signature){entry={signature,node:makeCard(data,group.kind,state.busy)};cards.set(key,entry);}nodes.push(entry.node);});
      // Reuse unchanged card nodes, preserving loaded images and focused controls.
      if(nodes.length!==grid.children.length||nodes.some((n,i)=>n!==grid.children[i]))grid.replaceChildren(...nodes);
      groupNodes.push(section);
    });
    const groupHost=byId('groups');if(groupNodes.length!==groupHost.children.length||groupNodes.some((n,i)=>n!==groupHost.children[i]))groupHost.replaceChildren(...groupNodes);
    for(const key of cards.keys())if(!used.has(key))cards.delete(key);
    doc.querySelectorAll('details.resume').forEach(n=>{n.open=opened.has(n.dataset.mapId)&&!state.busy;});
    scroller.scrollTop=scroll;
    if(focused){const next=Array.from(doc.querySelectorAll('[data-focus-key]')).find(n=>n.dataset.focusKey===focused&&!n.disabled);if(next&&next!==doc.activeElement)next.focus({preventScroll:true});}
  }
  app=controller(transport,render);
  root.bf6Home=Object.freeze({setState:app.setState});
  doc.addEventListener('keydown',event=>{if(event.key==='Escape'){doc.querySelectorAll('details[open]').forEach(n=>{n.open=false;n.firstChild.focus();});}});
  render(app.getState());app.dispatch({action:'ready'});
})(typeof window !== 'undefined' ? window : globalThis);
