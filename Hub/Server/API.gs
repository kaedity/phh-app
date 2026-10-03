function hubMeasure_(metrics,key,work) {
  const start=Date.now();try{return work();}finally{if(metrics)metrics[key]=(metrics[key] || 0)+Date.now()-start;}
}
function hubRun_(query,body,measure=false,health=false) {
  const started=Date.now(),metrics=measure?{event:'PHH_SYNC_TIMING',success:false,config_ms:0,acl_ms:0,book_environment_ms:0,lock_ms:0,state_ms:0,inbox_ms:0,intake_ms:0,delta_ms:0,body_ms:0,commit_ms:0,advanced_read_ms:0,advanced_read_requests:0,advanced_read_ranges:0}:null;
  let lock,acquired=false;
  try {
    const c=hubMeasure_(metrics,'config_ms',()=>{const c=hubConfig_();if(query)hubCheckRequest_(c,query,health);return c;});
    hubMeasure_(metrics,'acl_ms',()=>hubCheckACL_(c));hubMeasure_(metrics,'book_environment_ms',()=>hubCheckBookEnvs_(c));
    lock=LockService.getScriptLock();acquired=hubMeasure_(metrics,'lock_ms',()=>lock.tryLock(1000));ensure_(acquired,'BUSY');
    const store=hubMeasure_(metrics,'state_ms',()=>{const store=new HubSheetsStore(c,metrics);hubEnvironment_(store);return store;});
    const result=hubMeasure_(metrics,'body_ms',()=>body(store));hubMeasure_(metrics,'commit_ms',()=>store.commit());
    if(metrics)metrics.success=true;return result;
  } finally {
    if(acquired)lock.releaseLock();
    // 診断は所要時間/呼出回数だけ。アカウント・ID・セル・記録・URLは含めない。
    if(metrics){metrics.total_ms=Date.now()-started;console.log(JSON.stringify(metrics));}
  }
}
function submitHubOperation(op) { try {return hubRun_(op,store=>hubApplyApp_(store,op,Date.now()),false,op?.action==='save_health_delta');}catch(e){return {schema_version:1,environment:op?.environment || null,operation_id:op?.operation_id || null,status:'rejected',error_code:e.message,entity_ids:[],revisions:[],retryable:['BUSY','STORAGE_UNAVAILABLE','HEALTH_DRIVE_UNAVAILABLE'].includes(e.message)};} }
function getHubOperationResult(q) { return hubRun_(q,store=>{ensure_(hubIsId_(q.operation_id),'INVALID_ID');return hubOperationResult_(store,q.operation_id);}); }
function getHubChanges(q) { return hubRun_(q,store=>hubChanges_(store,q)); }
function syncHubChanges(q) {
  // 先頭ページだけ受付を処理する。後続ページはgetHubChangesで固定snapshotを保つ。
  return hubRun_(q,store=>{
    ensure_(q.snapshot_revision===undefined,'INVALID_CURSOR');
    const sh=hubMeasure_(store.metrics,'inbox_ms',()=>{const sh=SpreadsheetApp.openById(store.config.inbox).getSheetByName('受付');ensure_(sh && stable_(sh.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');return sh;});
    hubMeasure_(store.metrics,'intake_ms',()=>hubPollWork_(store,row=>sh.getRange(row,1,1,9).getValues()[0],sh.getLastRow(),Date.now()));
    // 保存前の同じstoreから、既存行＋未確定行で整合した差分応答を作る。
    // hubRun_の一括保存が成功してから返す。外部API書込後のSpreadsheetApp再読込みを避ける。
    // 応答消失時は次回に同じ受付/操作IDの確定済み結果を返す。
    return hubMeasure_(store.metrics,'delta_ms',()=>hubChanges_(store,q));
  },true);
}
function resolveHubReview(q) {return hubRun_(q,store=>{ensure_(hubIsId_(q.review_id) && ['再送','破棄'].includes(q.resolution),'INVALID_REVIEW');const r=store.get('Reviews',q.review_id);ensure_(r,'NOT_FOUND');r.status='本人確認済み';r.resolution=q.resolution;store.put('Reviews',r);hubSet_(store,'publication_dirty',true,Date.now());hubSet_(store,'publish:'+intakeJstDate_(Date.now()),true,Date.now());return {review_id:r.id,status:r.status,resolution:r.resolution};});}
function hubCheckBookEnvs_(c) {for(const id of [c.inbox,c.results]){const sh=SpreadsheetApp.openById(id).getSheetByName('_PHH');ensure_(sh && stable_(sh.getRange(1,1,1,2).getValues()[0])===stable_(['environment',c.environment]),'ENVIRONMENT_MISMATCH');}}
function hubDayResult_(store,q,state) {
  const limit=q.limit ?? 50;ensure_(Number.isInteger(limit) && limit>=1 && limit<=50,'INVALID_LIMIT');const upper=hubSetting_(store,'next_change',0),hash=hubHash_({local_date:q.local_date,limit}),cursor=q.cursor;
  if(cursor){ensure_(cursor.query_hash===hash && cursor.snapshot_revision===upper,'SNAPSHOT_CHANGED');ensure_(Number.isSafeInteger(cursor.offset) && cursor.offset>=0,'INVALID_CURSOR');}
  const all=Object.values(state.records).sort((a,b)=>a.id.localeCompare(b.id)),start=cursor?.offset || 0;ensure_(start<=all.length,'INVALID_CURSOR');const out={schema_version:1,environment:store.config.environment,local_date:q.local_date,snapshot_revision:upper,records:all.slice(start,start+limit),summary:store.get('DailySummary',q.local_date),total_count:all.length,returned_count:0,has_more:false,next_cursor:null,publication_pending:hubSetting_(store,'publication_dirty',false)};
  const finish=()=>{out.returned_count=out.records.length;out.has_more=start+out.returned_count<all.length;out.next_cursor=out.has_more?{offset:start+out.returned_count,snapshot_revision:upper,query_hash:hash}:null;};finish();
  while(Utilities.newBlob(JSON.stringify(out)).getBytes().length>200000 && out.records.length>1){out.records.pop();finish();}ensure_(Utilities.newBlob(JSON.stringify(out)).getBytes().length<=200000,'RESPONSE_TOO_LARGE');return out;
}
function getHubDay(q) {return hubRun_(q,store=>{const date=intakeDate_(q.local_date),state=hubEmptyState_();hubLoadDate_(store,date,state);return hubDayResult_(store,q,state);});}
function hubPollWork_(store,rows,lastRow,now) {
  let processed=0;const start=hubSetting_(store,'next_inbox_row',2);
  // 新規は最大20行。保留は完了後にも再確認する。受付済みは別の巡回cursorで監査。
  const selected=new Set();for(let row=start;row<=lastRow && selected.size<20;row++)selected.add(row);
  for(const l of store.find('IntakeLedger','status','保留').slice(0,20))selected.add(l.sheet_row);
  const audit=hubSetting_(store,'audit_row',2);for(let row=audit;row<Math.min(start,audit+20,lastRow+1);row++)selected.add(row);
  const inputs=new Map(),keys=[];
  for(const row of selected) {const cells=rows(row);inputs.set(row,cells);keys.push({table:'IntakeScans',id:String(row)},{table:'IntakeLedger',id:intakeCell_(cells[0]) || '#row'+row});}
  store.prefetch(keys);
  for(const row of Array.from(selected).sort((a,b)=>a-b)) {hubProcessIntakeRow_(store,inputs.get(row),row,now);processed++;}
  hubSet_(store,'next_inbox_row',Math.min(lastRow+1,start+20),now);hubSet_(store,'audit_row',audit+20>=Math.min(start,lastRow+1)?2:audit+20,now);
  if(typeof hubP5AutoPlan_==='function')hubP5AutoPlan_(store,now);
  return {processed,publication_pending:hubSetting_(store,'publication_dirty',false)};
}
function processHubIntake(q) {
  return hubRun_(q,store=>{const book=SpreadsheetApp.openById(store.config.inbox),sh=book.getSheetByName('受付');ensure_(sh && stable_(sh.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');const last=sh.getLastRow(),cache={};return hubPollWork_(store,row=>cache[row] || (cache[row]=sh.getRange(row,1,1,9).getValues()[0]),last,Date.now());});
}
function syncHubForApp(q) {
  // 一つのロックで受付処理・保存・取得応答を作る。保存後にロックを取り直さない。
  return hubRun_(q,store=>{const sh=SpreadsheetApp.openById(store.config.inbox).getSheetByName('受付');ensure_(sh && stable_(sh.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');hubPollWork_(store,row=>sh.getRange(row,1,1,9).getValues()[0],sh.getLastRow(),Date.now());const state=hubEmptyState_(),date=intakeDate_(q.local_date);hubLoadDate_(store,date,state);return hubDayResult_(store,q,state);});
}
function setupHub() {
  const lock=LockService.getScriptLock();ensure_(lock.tryLock(1000),'BUSY');
  try {return hubSetupLocked_();} finally {lock.releaseLock();}
}
function hubSetupLocked_() {
  const c=hubConfig_();hubCheckACL_(c);const book=SpreadsheetApp.openById(c.canonical),hasSettings=book.getSheetByName('Settings');
  if(hasSettings?.getLastRow()>1) {const store=new HubSheetsStore(c);hubEnvironment_(store);return {status:'already_initialized',environment:c.environment};}
  ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');
  ensure_(book.getSheets().every(sh=>sh.getLastRow()===0 || sh.getLastRow()===1 && HUB_SCHEMA_.tables[sh.getName()] && stable_(sh.getRange(1,1,1,HUB_SCHEMA_.tables[sh.getName()].columns.length).getValues()[0])===stable_(HUB_SCHEMA_.tables[sh.getName()].columns.map(col=>col.name))),'INITIALIZE_NONEMPTY_BOOK');
  for(const [name,t] of Object.entries(HUB_SCHEMA_.tables)) {const sh=book.getSheetByName(name) || book.insertSheet(name);sh.getRange(1,1,1,t.columns.length).setValues([t.columns.map(col=>col.name)]);sh.setFrozenRows(1);}
  for(const id of [c.inbox,c.results]) {const b=SpreadsheetApp.openById(id),mark=b.getSheetByName('_PHH');if(mark?.getLastRow()){ensure_(stable_(mark.getRange(1,1,1,2).getValues()[0])===stable_(['environment',c.environment]),'ENVIRONMENT_MISMATCH');}else (mark || b.insertSheet('_PHH')).getRange(1,1,1,2).setValues([['environment',c.environment]]);}
  const ib=SpreadsheetApp.openById(c.inbox),inbox=ib.getSheetByName('受付') || ib.insertSheet('受付');if(!inbox.getLastRow())inbox.getRange(1,1,1,9).setValues([INTAKE_HEADERS_]);else ensure_(stable_(inbox.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');inbox.setFrozenRows(1);inbox.getRange(2,1,inbox.getMaxRows()-1,9).setNumberFormat('@');
  const store=new HubSheetsStore(c),now=Date.now();for(const [key,value] of Object.entries({environment:c.environment,schema_version:1,real_data_enabled:false,next_change:0,generation:1,next_inbox_row:2,audit_row:2,publication_dirty:false}))hubSet_(store,key,value,now);store.commit();return {status:'initialized',environment:c.environment,real_data_enabled:false};
}
function hubPublishValues_(book,name,header,rows) {
  const sh=book.getSheetByName(name) || book.insertSheet(name),n=Math.max(1,rows.length+1),width=header.length;
  const requests=[];if(n>sh.getMaxRows())requests.push({appendDimension:{sheetId:sh.getSheetId(),dimension:'ROWS',length:n-sh.getMaxRows()}});
  // 空いた旧行も同じ公開バッチで消す。stringValueなので式として解釈しない。
  requests.push({updateCells:{range:{sheetId:sh.getSheetId(),startRowIndex:0,endRowIndex:Math.max(n,sh.getLastRow()),startColumnIndex:0,endColumnIndex:width},rows:[header,...rows].map(r=>({values:r.map(v=>hubCell_(v ?? null))})),fields:'userEnteredValue'}});
  Sheets.Spreadsheets.batchUpdate({requests},book.getId());sh.setFrozenRows(1);
}
function publishHubResults() {
  return hubRun_(null,store=>{if(!hubSetting_(store,'publication_dirty',false))return {published:false};const book=SpreadsheetApp.openById(store.config.results),scans=store.all('IntakeScans'),reviews=store.all('Reviews');
    hubPublishValues_(book,'受付結果',['行','受付番号','状態','内容または理由'],scans.sort((a,b)=>a.sheet_row-b.sheet_row).map(l=>[l.sheet_row,l.intake_id,l.status,l.message]));
    hubPublishValues_(book,'要確認',['確認番号','受付番号','行','理由','発生','状態'],reviews.map(r=>[r.id,r.intake_id,r.sheet_row,r.message,new Date(r.created_at).toISOString(),r.status]));
    const dirty=store.all('Settings').filter(r=>r.id.startsWith('publish:') && r.bool_value===true);
    const sh=book.getSheetByName('概要') || book.insertSheet('概要');if(!sh.getLastRow())sh.getRange(1,1,1,2).setValues([['日付','本文']]);
    for(const r of dirty) {const date=r.id.slice(8),state=hubEmptyState_();hubLoadDate_(store,date,state);state.reviews=reviews;state.pending_count=store.find('IntakeLedger','status','保留').length;const text=intakeSummaryForHub_(state,date,Date.now(),store);const found=sh.getRange(1,1,Math.max(1,sh.getLastRow()),1).createTextFinder(date).matchEntireCell(true).findAll();ensure_(found.length<=1,'PUBLICATION_INDEX');const row=found[0]?.getRow() || sh.getLastRow()+1;if(row>sh.getMaxRows())sh.insertRowsAfter(sh.getMaxRows(),1);Sheets.Spreadsheets.batchUpdate({requests:[{updateCells:{start:{sheetId:sh.getSheetId(),rowIndex:row-1,columnIndex:0},rows:[{values:[date,text].map(hubCell_)}],fields:'userEnteredValue'}}]},book.getId());hubSet_(store,r.id,false,Date.now());}
    hubSet_(store,'publication_dirty',false,Date.now());return {published:true,receipts:scans.length,reviews:reviews.length};});
}
function intakeSummaryForHub_(state,date,now,store=null) {
  const cancelled=new Set(Object.values(state.records).filter(r=>r.type==='session' && r.date===date && r.lifecycle_state==='cancelled').map(r=>r.session));
  const rs=Object.values(state.records).filter(r=>r.date===date && r.status==='active' && !(r.type==='set' && cancelled.has(r.session))),fmt=v=>v===null?'不明':String(v);
  const meals=rs.filter(r=>r.type==='meal'),fmtTotal=k=>meals.reduce((sum,r)=>sum+(r[k] ?? 0),0)+'（不明'+meals.reduce((n,r)=>n+(r.food_record?r[k+'_missing']:(r[k]===null?1:0)),0)+'件）';
  const lines=['【PHH 概要】'+date+'（更新 '+new Date(now).toISOString()+'）','保存済み既知合計 '+fmtTotal('kcal')+' kcal／P '+fmtTotal('protein_g')+'／F '+fmtTotal('fat_g')+'／C '+fmtTotal('carbohydrate_g')];
  for(const r of rs)lines.push(r.type==='session'?r.session+'｜状態 '+r.lifecycle_state+(r.plan_slot_id?'｜予定枠 '+r.plan_slot_id:''):r.type==='meal'?r.slot+'｜'+r.name+'｜番号'+r.no+'｜'+r.quantity+' '+r.unit+'｜'+fmt(r.kcal)+' kcal P'+fmt(r.protein_g)+' F'+fmt(r.fat_g)+' C'+fmt(r.carbohydrate_g):r.type==='set'?r.session+'｜'+r.exercise+'｜セット'+r.set_no+'｜'+r.weight_kg+'kg×'+r.reps+'｜RPE '+fmt(r.rpe):r.session+'｜'+(r.exercise || 'セッション全体')+'｜補足（'+r.category+'・'+r.speaker+'）'+r.text);
  if(store && typeof hubP5Enabled_==='function' && hubP5Enabled_())lines.push(...hubP5SummaryLines_(store,date));
  lines.push('書き込み完了待ち '+(state.pending_count || 0)+'件');const reviews=state.reviews.filter(r=>r.status==='未対応');lines.push('■要確認：'+reviews.length+'件');
  // 要確認が増えても1セル5万文字を超えて公開が止まらないよう、新しい20件だけ載せる（10/4）。全件は結果ブックの「要確認」タブ。
  const shown=reviews.slice().sort((a,b)=>(b.created_at||0)-(a.created_at||0)).slice(0,20);for(const r of shown)lines.push('要確認 '+r.id+'｜'+String(r.message).slice(0,300));if(reviews.length>shown.length)lines.push('ほか'+(reviews.length-shown.length)+'件は結果ブックの「要確認」タブ');
  const text=lines.join('\n');return text.length>45000?text.slice(0,45000)+'\n（長すぎるため省略。詳細は各タブ）':text;
}
