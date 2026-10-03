// キー列/索引列を検索し、必要な行だけを読む。書込はcommit()の1バッチだけ。
function hubCheckACL_(c) {
  for (const [id, editors, viewers] of [[c.canonical,[],[]],[c.inbox,[c.chat],[]],[c.results,[],[c.chat]]]) {
    const f=DriveApp.getFileById(id);
    ensure_(f.getOwner().getEmail() === c.owner && f.getSharingAccess() === DriveApp.Access.PRIVATE, 'ACL_PUBLIC_OR_OWNER');
    const es=f.getEditors().map(u=>u.getEmail()).filter(x=>x!==c.owner).sort();
    const vs=f.getViewers().map(u=>u.getEmail()).filter(x=>x!==c.owner).sort();
    ensure_(stable_(es)===stable_(editors.slice().sort()) && stable_(vs)===stable_(viewers.slice().sort()),'ACL_UNEXPECTED_MEMBER');
  }
}
class HubSheetsStore {
  constructor(config,metrics=null) { this.metrics=metrics; this.config=config; this.book=SpreadsheetApp.openById(config.canonical); this.sheets={}; this.cache={}; this.pending=new Map(); this.positions=new Map(); this.last={}; this.diskLast={}; }
  sheet(table) {
    if (!this.sheets[table]) {
      const sh=this.book.getSheetByName(table); ensure_(sh && HUB_SCHEMA_.tables[table], 'SCHEMA_MISSING');
      const cols=HUB_SCHEMA_.tables[table].columns.map(c=>c.name);
      ensure_(stable_(sh.getRange(1,1,1,cols.length).getValues()[0])===stable_(cols),'HEADER_MISMATCH');
      this.sheets[table]=sh; this.last[table]=this.diskLast[table]=Math.max(1,sh.getLastRow());
    }
    return this.sheets[table];
  }
  readBatch_(ranges) {
    if(this.metrics){this.metrics.advanced_read_requests++;this.metrics.advanced_read_ranges+=ranges.length;}
    return hubMeasure_(this.metrics,'advanced_read_ms',()=>Sheets.Spreadsheets.Values.batchGet(this.config.canonical,{ranges,valueRenderOption:'UNFORMATTED_VALUE'}));
  }
  prefetch(entries) {
    // 1実行のロック内だけで、指定IDの行をまとめて読む。未確定行と既読行は優先する。
    const targets=[],seen=new Set(),requested=Array.from(entries);
    // Settingsの固定キーだけをまとめる。表示文字列を使い、特殊文字は従来検索へ戻す。
    // 索引はこのprefetch呼出しだけで使い、次回へ保持しない。
    const settingKeys=new Set(['environment','schema_version','real_data_enabled','generation','next_change','next_inbox_row','audit_row','publication_dirty']);
    const settingsBatch=new Set(requested.filter(e=>e.table==='Settings' && settingKeys.has(e.id) && !this.pending.has('Settings\0'+e.id) && !('Settings\0'+e.id in this.cache)).map(e=>e.id)).size>1;
    let settingsIndex;
    for(const {table,id} of requested) {
      const key=table+'\0'+id;if(seen.has(key) || this.pending.has(key) || key in this.cache)continue;seen.add(key);
      const sh=this.sheet(table);if(this.diskLast[table]<2){this.cache[key]=null;continue;}
      let found;
      if(table==='Settings' && settingsBatch && settingKeys.has(id)) {
        if(settingsIndex===undefined) {
          const ids=sh.getRange(2,1,this.diskLast[table]-1,1).getDisplayValues();
          settingsIndex=ids.every(r=>/^[\x20-\x7e]*$/.test(r[0])) ? new Map() : null;
          if(settingsIndex)ids.forEach((r,i)=>{const positions=settingsIndex.get(r[0]) || [];positions.push(i+2);settingsIndex.set(r[0],positions);});
        }
        if(settingsIndex)found=(settingsIndex.get(id) || []).map(pos=>({getRow:()=>pos}));
      }
      if(!found)found=sh.getRange(2,1,this.diskLast[table]-1,1).createTextFinder(String(id)).matchEntireCell(true).matchCase(true).useRegularExpression(false).findAll();
      ensure_(found.length<=1,'INDEX_CORRUPT');if(!found.length){this.cache[key]=null;continue;}
      const pos=found[0].getRow(),width=HUB_SCHEMA_.tables[table].columns.length;
      targets.push({table,id,key,pos,range:"'"+table+"'!A"+pos+':'+hubColumn_(width)+pos});
    }
    if(!targets.length)return;
    const result=this.readBatch_(targets.map(t=>t.range));
    ensure_(result.valueRanges?.length===targets.length,'INDEX_CORRUPT');
    targets.forEach((t,i)=>{const row=hubDecode_(t.table,result.valueRanges[i].values?.[0] || []);ensure_(row.id===t.id,'INDEX_CORRUPT');this.positions.set(t.key,t.pos);this.cache[t.key]=row;});
  }
  matching(table, field, value) {
    // 同じ実行の中で同じ検索をくり返さない（10/4：セッション終了時の20行で日付の索引を毎行読み直していた）。
    // ディスク上の結果だけを覚え、未確定の行はfind()が重ねる。commitでディスクが変わるので忘れる。
    const memoKey=table+'\0'+field+'\0'+String(value);if(!this.matchMemo)this.matchMemo=new Map();
    if(this.matchMemo.has(memoKey))return this.matchMemo.get(memoKey).map(hubClone_);
    const rows=this.matchingFromDisk_(table,field,value);this.matchMemo.set(memoKey,rows.map(hubClone_));return rows;
  }
  matchingFromDisk_(table, field, value) {
    const sh=this.sheet(table), col=HUB_SCHEMA_.tables[table].columns.findIndex(c=>c.name===field);
    ensure_(col>=0,'INDEX_FIELD'); if(this.diskLast[table]<2)return [];
    const found=sh.getRange(2,col+1,this.diskLast[table]-1,1).createTextFinder(String(value)).matchEntireCell(true).matchCase(true).useRegularExpression(false).findAll();
    if(!found.length)return [];
    const names=HUB_SCHEMA_.tables[table].columns.length, ranges=found.map(r=>"'"+table+"'!A"+r.getRow()+':'+hubColumn_(names)+r.getRow());
    const result=this.readBatch_(ranges);
    const rows=found.map((r,i)=>{ const v=hubDecode_(table,result.valueRanges[i].values?.[0] || []); this.positions.set(table+'\0'+v.id,r.getRow()); this.cache[table+'\0'+v.id]=v; return v; });ensure_(new Set(rows.map(r=>r.id)).size===rows.length,'INDEX_CORRUPT');return rows;
  }
  get(table,id) {
    const key=table+'\0'+id;if(this.pending.has(key))return hubClone_(this.pending.get(key));
    if(key in this.cache)return this.cache[key] ? hubClone_(this.cache[key]):null;
    const matches=this.matching(table,'id',id);ensure_(matches.length<=1,'INDEX_CORRUPT'); this.cache[key]=matches[0] || null; return matches[0] ? hubClone_(matches[0]):null;
  }
  find(table,field,value) {
    const all=new Map(this.matching(table,field,value).map(r=>[r.id,r]));
    for(const [key,r] of this.pending) if(key.startsWith(table+'\0')) {all.delete(r.id);if(r[field]===value)all.set(r.id,r);}
    return Array.from(all.values()).map(hubClone_);
  }
  all(table) {
    this.sheet(table);const width=HUB_SCHEMA_.tables[table].columns.length;
    // 全件が必要な公開/バックアップでも、API保存後の古いSpreadsheetApp値を読まない。
    const values=this.readBatch_(["'"+table+"'!A2:"+hubColumn_(width)]).valueRanges?.[0]?.values || [],rows=values.map(r=>hubDecode_(table,r));
    ensure_(new Set(rows.map(r=>r.id)).size===rows.length,'INDEX_CORRUPT');
    this.diskLast[table]=rows.length+1;this.last[table]=Math.max(this.last[table],this.diskLast[table]);
    const out=new Map(rows.map(r=>[r.id,r]));for(const [k,r] of this.pending)if(k.startsWith(table+'\0'))out.set(r.id,r);return Array.from(out.values());
  }
  range(table,start,count) {
    const sh=this.sheet(table),n=Math.min(count,this.last[table]-start+1);if(n<1)return [];
    const diskCount=Math.max(0,Math.min(n,this.diskLast[table]-start+1));
    const disk=diskCount ? sh.getRange(start,1,diskCount,HUB_SCHEMA_.tables[table].columns.length).getValues() : [];
    const overlay=new Map();
    for(const [key,row] of this.pending)if(key.startsWith(table+'\0'))overlay.set(this.positions.get(key),row);
    return Array.from({length:n},(_,i)=>overlay.has(start+i) ? hubClone_(overlay.get(start+i)) : hubDecode_(table,disk[i] || []));
  }
  put(table,row) { hubRow_(table,row); const key=table+'\0'+row.id;this.get(table,row.id);if(!this.positions.has(key))this.positions.set(key,++this.last[table]);this.pending.set(key,hubClone_(row)); }
  position(table,id) { return this.positions.get(table+'\0'+id); }
  commit() {
    this.matchMemo=new Map();
    const requests=[],fresh=new Map();
    if(this.healthStaged){const rows=[...this.pending].filter(([key,row])=>this.cache[key] && stable_(this.cache[key])!==stable_(row)),ranges=rows.map(([key])=>{const t=key.split('\0')[0],p=this.positions.get(key);return "'"+t+"'!A"+p+':'+hubColumn_(HUB_SCHEMA_.tables[t].columns.length)+p;});if(rows.length){const read=this.readBatch_(ranges);ensure_(read.valueRanges?.length===rows.length,'HEALTH_STATE_READBACK');rows.forEach(([key],i)=>fresh.set(key,hubDecode_(key.split('\0')[0],read.valueRanges[i].values?.[0] || [])));}}
    for(const table of Object.keys(this.sheets)) {const sh=this.sheets[table],maximum=this.healthDiskMax?.[table] ?? sh.getMaxRows();if(this.last[table]>maximum)requests.push({appendDimension:{sheetId:sh.getSheetId(),dimension:'ROWS',length:this.last[table]-maximum}});}
    for(const [key,row] of this.pending) {
      const table=key.split('\0')[0],sh=this.sheet(table),old=this.cache[key];
      if(old && stable_(old)===stable_(row))continue;
      const pos=this.positions.get(key);
      if(old) { const current=this.healthStaged?fresh.get(key):hubDecode_(table,sh.getRange(pos,1,1,HUB_SCHEMA_.tables[table].columns.length).getValues()[0]); ensure_(stable_(current)===stable_(old),'INDEX_CORRUPT'); }
      requests.push({updateCells:{start:{sheetId:sh.getSheetId(),rowIndex:pos-1,columnIndex:0},rows:[{values:hubRow_(table,row).map(hubCell_)}],fields:'userEnteredValue'}});
    }
    if(requests.length) Sheets.Spreadsheets.batchUpdate({requests},this.config.canonical);
    this.pending.clear(); return requests.length;
  }
}
function hubColumn_(n) { let s='';for(;n>0;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s; }
function hubSetting_(store,key,fallback) { const r=store.get('Settings',key); if(!r)return fallback;return r.value_type==='number'?r.number_value:r.value_type==='boolean'?r.bool_value:r.string_value; }
function hubSet_(store,key,value,now) { const old=store.get('Settings',key); store.put('Settings',{id:key,value_type:typeof value,string_value:typeof value==='string'?value:null,number_value:typeof value==='number'?value:null,bool_value:typeof value==='boolean'?value:null,revision:(old?.revision || 0)+1,updated_at:new Date(now).toISOString()}); }
function hubEnvironment_(store) { store.prefetch(['environment','schema_version','real_data_enabled','generation','next_change','next_inbox_row','audit_row','publication_dirty'].map(id=>({table:'Settings',id}))); ensure_(hubSetting_(store,'environment',null)===store.config.environment && hubSetting_(store,'schema_version',null)===1,'ENVIRONMENT_MISMATCH'); ensure_(hubSetting_(store,'real_data_enabled',false)===store.config.real_data_enabled,'REAL_DATA_SETTING_MISMATCH'); }
function hubLoadDate_(store,date,state) {
  if(state.loaded_dates.has(date))return;state.loaded_dates.add(date);
  const ix=store.find('RecordIndex','local_date',date);
  if(typeof hubP3Enabled_==='function' && hubP3Enabled_())for(const idx of ix.filter(r=>r.table_name==='TrainingSessions')) {const row=store.get('TrainingSessions',idx.id);ensure_(row && row.revision===idx.revision && store.position('TrainingSessions',idx.id)===idx.sheet_row,'INDEX_CORRUPT');const r=hubP3SessionRecord_(row);const l=store.find('IntakeLedger','operation_id',r.last_operation_id).find(l=>l.status==='保存済み');if(l)r.last_intake=l.intake_id;state.records[r.id]=r;}
  store.prefetch(ix.filter(r=>['Meals','TrainingSets','TrainingNotes'].includes(r.table_name)).map(r=>({table:r.table_name,id:r.id})));
  for(const idx of ix) {
    if(!['Meals','TrainingSets','TrainingNotes'].includes(idx.table_name))continue;
    const r=store.get(idx.table_name,idx.id);ensure_(r && r.id===idx.id && r.revision===idx.revision && store.position(idx.table_name,idx.id)===idx.sheet_row,'INDEX_CORRUPT');
    const base={id:r.id,type:idx.table_name==='Meals'?'meal':idx.table_name==='TrainingSets'?'set':'note',status:r.status,revision:r.revision,created_at:r.created_at,last_changed_at:Date.parse(r.updated_at),last_source:r.source_kind==='app'?'app':'gpt',last_intake:null,last_operation_id:r.last_operation_id,date};
    const intake=store.find('IntakeLedger','operation_id',r.last_operation_id).find(l=>l.status==='保存済み');if(intake)base.last_intake=intake.intake_id;
    if(base.type==='meal' && r.food_name!==undefined && r.food_name!==null){state.records[r.id]=hubP4ReadMeal_(store,r,base);continue;}
    if(base.type==='meal') {
      const items=store.find('MealItems','meal_id',r.id);ensure_(items.length===1,'P2_MEAL_ITEM_COUNT');const item=items[0],ns=store.find('IntakeNutrients','item_id',item.id);
      Object.assign(base,{slot:r.slot,no:r.number,name:item.name,quantity:item.quantity,unit:item.unit,source:item.source,last_app_edit_at:r.last_app_edit_at});
      for(const k of ['kcal','protein_g','fat_g','carbohydrate_g'])base[k]=ns.find(n=>n.nutrient_id===k)?.value ?? null;
    } else { const session=store.get('TrainingSessions',r.session_id);ensure_(session,'INDEX_CORRUPT');Object.assign(base,{session:session.session,exercise:r.exercise});
      if(base.type==='set')Object.assign(base,{set_no:r.set_no,weight_kg:r.weight_kg,reps:r.reps,rpe:r.rpe,rir:r.rir,weight_basis:r.weight_basis,...(typeof hubP3Enabled_==='function' && hubP3Enabled_()?{equipment_key:r.equipment_key ?? null,variant:r.variant ?? null,max_attempt:r.max_attempt ?? null,successful:r.successful ?? null}:{})});
      else Object.assign(base,{set_no:r.set_no,category:r.category,speaker:r.speaker,text:r.text});
    }
    state.records[r.id]=base;
  }
}
function hubEmptyState_() { return {seq:0,records:{},ledger:{},reviews:[],loaded_dates:new Set()}; }
function hubLoadLedger_(store,key,state,includeUndo=true) {
  if(state.ledger[key] && (!includeUndo || 'undo' in state.ledger[key]))return state.ledger[key];const l=store.get('IntakeLedger',key);if(!l)return null;
  const original=Array.from({length:9},(_,i)=>l['original_'+i]);
  const undo=includeUndo ? store.find('UndoValues','operation_id',l.operation_id || '') : [];let before={};
  for(const f of undo)before[f.field_name]=f.value_type==='null'?null:f.value_type==='number'?f.number_value:f.value_type==='boolean'?f.bool_value:f.string_value;
  if('__absent__' in before)before=null;
  const out={fp:stable_(original),first_seen:l.first_seen,sheet_row:l.sheet_row,status:l.status,message:l.message,record_id:l.record_id,operation_id:l.operation_id,undone:l.undone,flagged:{}};
  if(includeUndo)out.undo=l.record_id && undo.length ? {record_id:l.record_id,before}:null;
  for(const hash of l.flagged_hashes.split(';').filter(Boolean))out.flagged[hash]=true;
  state.ledger[key]=out; return out;
}
