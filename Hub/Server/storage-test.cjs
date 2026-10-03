const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const schema=JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8'));
let readRequests=0,finderRequests=0,displayRequests=0,failDisplay=false;
let sheetID=1,batches=[],failCanonical=false,failPublication=false,locked=false,acquisitions=0,releases=0,staleChanges=false,cachedChanges=null,staleScans=false;
class Range {
 constructor(sh,row,col,n,width){assert.ok(row>=1 && row+n-1<=sh.maxRows,'out of allocated grid');Object.assign(this,{sh,row,col,n,width});}
 getValues(){if(staleScans && this.sh.name==='IntakeScans' && this.row>=2)throw Error('stale scan read');const rows=staleChanges && this.sh.name==='SyncChanges' && cachedChanges ? cachedChanges : this.sh.rows;return Array.from({length:this.n},(_,i)=>Array.from({length:this.width},(_,j)=>rows[this.row+i-1]?.[this.col+j-1] ?? ''));}
 getDisplayValues(){displayRequests++;if(failDisplay)throw Error('DISPLAY_UNAVAILABLE');return this.getValues().map((row,i)=>row.map((v,j)=>this.sh.display?.[this.row+i-1]?.[this.col+j-1] ?? String(v)));}
 setValues(values){for(let i=0;i<values.length;i++){this.sh.rows[this.row+i-1] ||= [];for(let j=0;j<values[i].length;j++)this.sh.rows[this.row+i-1][this.col+j-1]=values[i][j];}return this;}
 getRow(){return this.row;}
 setNumberFormat(){return this;}
 createTextFinder(value){const r=this;return {matchEntireCell(){return this;},matchCase(){return this;},useRegularExpression(){return this;},findAll(){finderRequests++;const out=[];for(let i=0;i<r.n;i++)if((r.sh.display?.[r.row+i-1]?.[r.col-1] ?? String(r.sh.rows[r.row+i-1]?.[r.col-1] ?? ''))===value)out.push(new Range(r.sh,r.row+i,r.col,1,1));return out;}};}
}
class Sheet {constructor(name,header=[]){this.name=name;this.id=sheetID++;this.maxRows=100;this.rows=header.length?[header]:[];}getName(){return this.name;}getRange(...a){return new Range(this,...a);}getLastRow(){return this.rows.length;}getSheetId(){return this.id;}getMaxRows(){return this.maxRows;}setFrozenRows(){}insertRowsAfter(_,n){this.maxRows+=n;} }
class Book {constructor(id){this.id=id;this.sheets=new Map();}getId(){return this.id;}getSheetByName(n){return this.sheets.get(n);}getSheets(){return [...this.sheets.values()];}insertSheet(n){const s=new Sheet(n);this.sheets.set(n,s);return s;}}
const books={canonical:new Book('canonical'),inbox:new Book('inbox'),results:new Book('results')};
for(const [name,t]of Object.entries(schema.tables))books.canonical.sheets.set(name,new Sheet(name,t.columns.map(c=>c.name)));
books.inbox.sheets.set('受付',new Sheet('受付',['受付番号','種別','分野','日付','区分','名称','番号','内容','本文']));
for(const id of ['inbox','results'])books[id].sheets.set('_PHH',new Sheet('_PHH',['environment','PHH_TEST']));
const props={PHH_ENVIRONMENT:'PHH_TEST',PHH_OWNER_EMAIL:'s@example.test',PHH_CHAT_EMAIL:'c@example.test',PHH_NOTIFY_TO:'s@example.test',PHH_CANONICAL:'canonical',PHH_INBOX:'inbox',PHH_RESULTS:'results',PHH_REAL_DATA_ENABLED:'false'};
const viewers={canonical:[],inbox:[],results:['c@example.test']},editors={canonical:[],inbox:['c@example.test'],results:[]};
const profileLogs=[];const logger={log(value){if(typeof value==='string' && value.startsWith('{') && value.includes('PHH_SYNC_TIMING'))profileLogs.push(JSON.parse(value));else console.log(value);}};
const ctx=vm.createContext({console:logger,Utilities:{DigestAlgorithm:{SHA_256:'sha256'},Charset:{UTF_8:'utf8'},computeDigest:(_,v)=>[...crypto.createHash('sha256').update(v).digest()],getUuid:()=>crypto.randomUUID(),newBlob:v=>({getBytes:()=>[...Buffer.from(v)]})},PropertiesService:{getScriptProperties:()=>({getProperties:()=>({...props})})},Session:{getEffectiveUser:()=>({getEmail:()=>props.PHH_OWNER_EMAIL})},DriveApp:{Access:{PRIVATE:'PRIVATE'},getFileById:id=>({getOwner:()=>({getEmail:()=>props.PHH_OWNER_EMAIL}),getSharingAccess:()=> 'PRIVATE',getEditors:()=>editors[id].map(e=>({getEmail:()=>e})),getViewers:()=>viewers[id].map(e=>({getEmail:()=>e}))})},LockService:{getScriptLock:()=>({tryLock:()=>{acquisitions++;if(locked)return false;locked=true;return true;},releaseLock:()=>{assert.equal(locked,true);locked=false;releases++;}})},SpreadsheetApp:{openById:id=>books[id]},Sheets:{Spreadsheets:{Values:{batchGet:(id,query)=>{readRequests++;assert.equal(query.valueRenderOption,'UNFORMATTED_VALUE');return {valueRanges:query.ranges.map(range=>{const m=/^'([^']+)'!A(\d+):[A-Z]+(\d*)$/.exec(range);assert.ok(m);const sh=books[id].getSheetByName(m[1]);const values=sh.rows.slice(Number(m[2])-1,m[3]?Number(m[3]):sh.rows.length).map(row=>{const v=row.slice();while(v.at(-1)==='' || v.at(-1)===null)v.pop();return v;});while(values.at(-1)?.length===0)values.pop();return {values};})};}},batchUpdate:(request,id)=>{assert.equal(locked || id==='canonical',true);batches.push({id,request:JSON.parse(JSON.stringify(request))});if(failCanonical && id==='canonical' || failPublication && id==='results')throw Error('STORAGE_UNAVAILABLE');if(staleChanges && id==='canonical' && !cachedChanges)cachedChanges=JSON.parse(JSON.stringify(books[id].getSheetByName('SyncChanges').rows));const copies=new Map(books[id].getSheets().map(sh=>[sh.id,{sh,rows:JSON.parse(JSON.stringify(sh.rows)),maxRows:sh.maxRows}]));for(const req of request.requests){if(req.appendDimension){copies.get(req.appendDimension.sheetId).maxRows+=req.appendDimension.length;continue;}const u=req.updateCells;assert.ok(u);const start=u.start || {sheetId:u.range.sheetId,rowIndex:u.range.startRowIndex,columnIndex:u.range.startColumnIndex},target=copies.get(start.sheetId);assert.ok(target);if(u.range){for(let i=u.range.startRowIndex;i<u.range.endRowIndex;i++){target.rows[i] ||= [];for(let j=u.range.startColumnIndex;j<u.range.endColumnIndex;j++)target.rows[i][j]='';}}for(let i=0;i<u.rows.length;i++){const row=start.rowIndex+i;assert.ok(row<target.maxRows);target.rows[row] ||= [];for(let j=0;j<u.rows[i].values.length;j++){const cell=u.rows[i].values[j].userEnteredValue || {};assert.ok(!('formulaValue' in cell));target.rows[row][start.columnIndex+j]=cell.stringValue ?? cell.numberValue ?? cell.boolValue ?? '';}}}for(const {sh,rows,maxRows}of copies.values()){sh.rows=rows;sh.maxRows=maxRows;}return {};}}}});
vm.runInContext('const HUB_SCHEMA_='+JSON.stringify(schema)+';'+['Core.gs','IntakeRules.gs','Storage.gs','Engine.gs','API.gs'].map(n=>fs.readFileSync(__dirname+'/'+n,'utf8')).join('\n')+'\nglobalThis.Store=HubSheetsStore;',ctx);
const cfg=ctx.hubConfig_(),baseStore=new ctx.Store(cfg);for(const [k,v]of Object.entries({environment:'PHH_TEST',schema_version:1,real_data_enabled:false,generation:1,next_change:0,next_inbox_row:2,audit_row:2,publication_dirty:false}))ctx.hubSet_(baseStore,k,v,Date.now());baseStore.commit();batches=[];
let passed=0;function test(name,f){f();passed++;console.log('ok '+name);}
const op={schema_version:1,environment:'PHH_TEST',synthetic:true,approval_state:'confirmed',operation_id:crypto.randomUUID(),entity_id:crypto.randomUUID(),expected_revision:0,action:'confirm_meal',payload:{local_date:'2026-10-01',slot:'昼食',name:'=架空の食事',quantity:1,unit:'食',kcal:100,protein_g:10,fat_g:0,carbohydrate_g:null,source:'本人'}};
test('Values API omitted trailing blanks preserve required strings and reject missing numbers',()=>{
 const row={id:'receipt',intake_id:'receipt',sheet_row:2,content_hash:'hash',first_seen:1,status:'保存済み',message:'',record_id:null,operation_id:null,undone:false,flagged_hashes:''};
 for(let i=0;i<9;i++)row['original_'+i]=i===0?'receipt':'';
 const cells=JSON.parse(JSON.stringify(ctx.hubRow_('IntakeLedger',row)));while(cells.at(-1)==='' || cells.at(-1)===null)cells.pop();
 assert.deepEqual(JSON.parse(JSON.stringify(ctx.hubDecode_('IntakeLedger',cells))),row);
 assert.throws(()=>ctx.hubDecode_('DailySummary',['2026-10-02']),/NULL_REQUIRED/);
 const settings=ctx.hubDecode_('Settings',['x','boolean','','',false,1,'t']);assert.equal(settings.bool_value,false);assert.equal(settings.number_value,null);
});
test('real adapter commits graph/ledger/changes/summary in one canonical batch',()=>{const before=acquisitions,result=ctx.submitHubOperation(op);assert.equal(result.status,'committed');assert.equal(batches.length,1);assert.equal(batches[0].id,'canonical');const names=new Set(batches[0].request.requests.filter(r=>r.updateCells).map(r=>books.canonical.getSheets().find(s=>s.id===r.updateCells.start.sheetId).name));for(const n of ['Meals','MealItems','IntakeNutrients','RecordIndex','Operations','OperationEntities','SyncChanges','DailySummary'])assert.ok(names.has(n));assert.equal(acquisitions-before,1);assert.equal(acquisitions,releases);assert.equal(locked,false);assert.equal(books.canonical.getSheetByName('Meals').rows[1][1],1);});
test('real adapter replay emits no duplicate append or changed outcome',()=>{batches=[];const old=JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),r=ctx.submitHubOperation(op);assert.equal(r.status,'committed');assert.equal(batches.length,0);assert.equal(JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),old);});
test('real adapter failure applies nothing and safe same-id retry succeeds',()=>{const next={...op,operation_id:crypto.randomUUID(),entity_id:crypto.randomUUID()};const old=JSON.stringify(books.canonical.getSheets().map(s=>s.rows));failCanonical=true;assert.equal(ctx.submitHubOperation(next).error_code,'STORAGE_UNAVAILABLE');assert.equal(JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),old);failCanonical=false;assert.equal(ctx.submitHubOperation(next).status,'committed');});
test('ACL additions rejected before reading/writing canonical',()=>{const old=batches.length;viewers.canonical.push('other@example.test');assert.equal(ctx.submitHubOperation({...op,operation_id:crypto.randomUUID()}).error_code,'ACL_UNEXPECTED_MEMBER');viewers.canonical=[];assert.equal(batches.length,old);});
test('wrong index row position stops write',()=>{const ix=books.canonical.getSheetByName('RecordIndex'),col=schema.tables.RecordIndex.columns.findIndex(c=>c.name==='sheet_row'),r=ix.rows.find(r=>r[0]===op.entity_id),value=r[col];r[col]=999;const next={...op,operation_id:crypto.randomUUID(),action:'update_meal',expected_revision:1,payload:{kcal:200}};assert.equal(ctx.submitHubOperation(next).error_code,'INDEX_CORRUPT');r[col]=value;});
test('publication failure leaves canonical committed and dirty, retries same data',()=>{const old=books.canonical.getSheetByName('Meals').rows.length;failPublication=true;assert.throws(()=>ctx.publishHubResults(),/STORAGE_UNAVAILABLE/);assert.equal(books.canonical.getSheetByName('Meals').rows.length,old);assert.equal(ctx.hubSetting_(new ctx.Store(cfg),'publication_dirty'),true);failPublication=false;assert.equal(ctx.publishHubResults().published,true);assert.equal(ctx.hubSetting_(new ctx.Store(cfg),'publication_dirty'),false);const summary=books.results.getSheetByName('概要').rows[1][1];assert.ok(summary.includes('不明2件'));assert.ok(summary.includes('=架空の食事'));});
test('one-lock intake/save/response, numeric types survive and result duplicates',()=>{const sh=books.inbox.getSheetByName('受付'),row=['r1','記録','筋トレ','2026-10-01','Pull','架空種目','1','重量kg=10; 回数=8',''];sh.rows.push(row,row);batches=[];const before=acquisitions;const result=ctx.syncHubForApp({schema_version:1,environment:'PHH_TEST',synthetic:true,local_date:'2026-10-01'});assert.ok(result.records.some(r=>r.type==='set' && r.reps===8));assert.equal(acquisitions-before,1);assert.equal(batches.filter(b=>b.id==='canonical').length,1);ctx.publishHubResults();assert.equal(books.results.getSheetByName('受付結果').rows[2][2],'重複');});
test('publication after intake uses fresh API scans instead of stale SpreadsheetApp body',()=>{const store=new ctx.Store(cfg);ctx.hubSet_(store,'publication_dirty',true,Date.now());store.commit();staleScans=true;try{assert.equal(ctx.publishHubResults().published,true);}finally{staleScans=false;}});
test('combined intake delta survives stale SpreadsheetApp reads after Advanced Sheets write',()=>{
 staleChanges=true;cachedChanges=null;
 const sh=books.inbox.getSheetByName('受付'),beforeCursor=ctx.hubSetting_(new ctx.Store(cfg),'next_change');
 sh.rows.push(['combined-r1','記録','筋トレ','2026-10-01','Pull','架空の同期試験','1','重量kg=12; 回数=9','']);
 const q={schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after:beforeCursor,limit:1},before=acquisitions;
 const first=ctx.syncHubChanges(q);assert.equal(acquisitions-before,1);assert.equal(locked,false);
 assert.equal(first.has_more,true);assert.ok(first.snapshot_revision>beforeCursor);assert.equal(first.next_cursor,beforeCursor+1);
 assert.ok(cachedChanges);cachedChanges=null; // 次のGAS実行は新しい読み取りcache
 const rest=ctx.getHubChanges({...q,after:first.next_cursor,limit:100,snapshot_revision:first.snapshot_revision});
 assert.ok([...first.changes,...rest.changes].some(c=>c.record.exercise==='架空の同期試験' && c.record.reps===9));
 assert.equal(rest.has_more,false);assert.equal(rest.next_cursor,first.snapshot_revision);
 cachedChanges=null;
 const replay=ctx.syncHubChanges({...q,after:rest.next_cursor,limit:100});assert.equal(replay.changes.length,0);
 assert.equal(replay.snapshot_revision,rest.next_cursor);assert.equal(acquisitions,releases);
 const old=JSON.stringify(books.canonical.getSheets().map(s=>s.rows));assert.throws(()=>ctx.syncHubChanges({...q,snapshot_revision:rest.next_cursor}),/INVALID_CURSOR/);
 assert.equal(JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),old);
 staleChanges=false;cachedChanges=null;
});
test('combined response is not returned when atomic commit fails; same intake recovers once',()=>{
 const sh=books.inbox.getSheetByName('受付'),after=ctx.hubSetting_(new ctx.Store(cfg),'next_change');
 sh.rows.push(['combined-failure','記録','筋トレ','2026-10-01','Pull','架空の保存失敗','1','重量kg=10; 回数=8','']);
 const q={schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after,limit:100};
 const old=JSON.stringify(books.canonical.getSheets().map(s=>s.rows));failCanonical=true;
 assert.throws(()=>ctx.syncHubChanges(q),/STORAGE_UNAVAILABLE/);assert.equal(JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),old);
 failCanonical=false;const page=ctx.syncHubChanges(q);assert.ok(page.changes.some(c=>c.record.exercise==='架空の保存失敗'));
 const fixed=JSON.stringify(books.canonical.getSheetByName('TrainingSets').rows);ctx.syncHubChanges({...q,after:page.next_cursor});
 assert.equal(JSON.stringify(books.canonical.getSheetByName('TrainingSets').rows),fixed);assert.equal(acquisitions,releases);
});
test('bounded intake audit and delta coalesce point reads below a minute quota',()=>{
 const sh=books.inbox.getSheetByName('受付');
 for(let i=0;i<3;i++)ctx.submitHubOperation({...op,operation_id:crypto.randomUUID(),entity_id:crypto.randomUUID(),payload:{...op.payload,local_date:'2026-10-02'}});
 const q={schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after:0,limit:100};
 sh.rows.push(['quota-set','記録','筋トレ','2026-10-02','Pull','架空の同期試験','1','重量kg=12; 回数=10','']);ctx.syncHubChanges(q);
 sh.rows.push(['quota-note','補足','筋トレ','2026-10-02','Pull','架空の同期試験','','分類=身体状態; 発言者=本人','架空の試験メモ']);
 readRequests=0;const page=ctx.syncHubChanges(q);assert.ok(page.changes.some(c=>c.record.text==='架空の試験メモ'));assert.ok(readRequests<=20,'read requests: '+readRequests);
 readRequests=0;const replay=ctx.syncHubChanges({...q,after:page.next_cursor});assert.equal(replay.changes.length,0);assert.ok(readRequests<=10,'audit read requests: '+readRequests);
 const before=JSON.stringify(books.canonical.getSheets().map(s=>s.rows));const store=new ctx.Store(cfg);
 store.prefetch([{table:'TrainingNotes',id:'absent'},{table:'TrainingSets',id:op.entity_id},{table:'Meals',id:op.entity_id}]);
 assert.equal(store.get('TrainingNotes','absent'),null);assert.equal(store.get('TrainingSets',op.entity_id),null);
 const meal=store.get('Meals',op.entity_id);assert.equal(meal.id,op.entity_id);meal.name='changed';assert.notEqual(store.get('Meals',op.entity_id).name,'changed');
 assert.equal(JSON.stringify(books.canonical.getSheets().map(s=>s.rows)),before);
});
test('sync profiling returns unchanged delta and logs only fixed numeric fields',()=>{
 const after=ctx.hubSetting_(new ctx.Store(cfg),'next_change'),q={schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after,limit:100};
 readRequests=0;const result=ctx.syncHubChanges(q),log=profileLogs.at(-1);
 assert.equal(result.changes.length,0);assert.equal(result.next_cursor,after);assert.equal(result.snapshot_revision,after);
 assert.equal(log.event,'PHH_SYNC_TIMING');assert.equal(log.success,true);assert.equal(log.advanced_read_requests,readRequests);
 const fields=['config_ms','acl_ms','book_environment_ms','lock_ms','state_ms','inbox_ms','intake_ms','delta_ms','body_ms','commit_ms','advanced_read_ms','advanced_read_requests','advanced_read_ranges','total_ms'];
 assert.deepEqual(Object.keys(log).sort(),['event','success',...fields].sort());for(const key of fields)assert.ok(Number.isSafeInteger(log[key]) && log[key]>=0);
 failCanonical=true;assert.throws(()=>ctx.syncHubChanges(q),/STORAGE_UNAVAILABLE/);failCanonical=false;assert.equal(profileLogs.at(-1).success,false);assert.equal(locked,false);
});
test('unchanged audit skips undo reads but an actual undo can load them lazily',()=>{
 const after=ctx.hubSetting_(new ctx.Store(cfg),'next_change'),q={schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after,limit:100};
 readRequests=0;const result=ctx.syncHubChanges(q);assert.equal(result.changes.length,0);assert.ok(readRequests<=2,'idle requests: '+readRequests);
 const store=new ctx.Store(cfg),state=ctx.hubEmptyState_();readRequests=0;
 const lazy=ctx.hubLoadLedger_(store,'combined-r1',state,false);assert.equal(lazy.status,'保存済み');assert.equal(lazy.undo,undefined);const first=readRequests;
 const full=ctx.hubLoadLedger_(store,'combined-r1',state);assert.ok(full.undo);assert.equal(full.undo.record_id,full.record_id);assert.equal(full.undo.before,null);assert.equal(readRequests,first+1);
 const cached=ctx.hubLoadLedger_(store,'combined-r1',state);assert.equal(cached,full);assert.equal(readRequests,first+1);
});
test('insert after row 100 expands the grid once, all pointers stay stable',()=>{const s=new ctx.Store(cfg);const now=Date.now();for(let i=0;i<105;i++)ctx.hubSet_(s,'grid-'+i,i,now);batches=[];s.commit();const expansions=batches[0].request.requests.filter(r=>r.appendDimension);assert.equal(expansions.length,1);const r=new ctx.Store(cfg);assert.equal(ctx.hubSetting_(r,'grid-104'),104);});
test('header mismatch aborts before mutation',()=>{const sh=books.canonical.getSheetByName('Meals'),old=sh.rows[0][0];sh.rows[0][0]='wrong';assert.equal(ctx.submitHubOperation({...op,operation_id:crypto.randomUUID(),entity_id:crypto.randomUUID()}).error_code,'HEADER_MISMATCH');sh.rows[0][0]=old;});
test('inbox or results from another environment rejected before commit',()=>{const marker=books.inbox.getSheetByName('_PHH');marker.rows[0][1]='PHH_PRODUCTION';const n=batches.length;assert.equal(ctx.submitHubOperation({...op,operation_id:crypto.randomUUID()}).error_code,'ENVIRONMENT_MISMATCH');assert.equal(batches.length,n);marker.rows[0][1]='PHH_TEST';});
test('initializer resumes headers-only setup, all three books marked, no real data',()=>{const previous={...props};for(const id of ['emptycanonical','emptyinbox','emptyresults']){books[id]=new Book(id);editors[id]=id==='emptyinbox'?['c@example.test']:[];viewers[id]=id==='emptyresults'?['c@example.test']:[];}books.emptycanonical.sheets.set('Settings',new Sheet('Settings',schema.tables.Settings.columns.map(c=>c.name)));props.PHH_CANONICAL='emptycanonical';props.PHH_INBOX='emptyinbox';props.PHH_RESULTS='emptyresults';const result=ctx.setupHub();assert.equal(result.status,'initialized');assert.equal(result.real_data_enabled,false);assert.equal(books.emptycanonical.getSheets().length,16);assert.equal(books.emptyinbox.getSheetByName('受付').rows[0].length,9);assert.equal(books.emptyresults.getSheetByName('_PHH').rows[0][1],'PHH_TEST');assert.equal(ctx.setupHub().status,'already_initialized');Object.assign(props,previous);});
books.canonical.getSheetByName('Settings').maxRows+=10;
test('Settings prefetch preserves order, missing, pending and cached rows with one key scan',()=>{
 const store=new ctx.Store(cfg),keys=['environment','schema_version','real_data_enabled','generation','next_change','next_inbox_row','audit_row','publication_dirty'];
 finderRequests=displayRequests=readRequests=0;
 store.prefetch(keys.slice().reverse().concat('environment','absent').map(id=>({table:'Settings',id})));
 assert.equal(store.get('Settings','absent'),null);
 for(const key of keys){assert.equal(store.get('Settings',key).id,key);assert.equal(store.position('Settings',key),books.canonical.getSheetByName('Settings').rows.findIndex(r=>r[0]===key)+1);}
 assert.equal(readRequests,1);
 console.log('SETTINGS_LOOKUPS '+JSON.stringify({finderRequests,displayRequests,bodyRequests:readRequests}));
 if(process.env.PHH_SETTINGS_INDEX_EXPECT==='1'){assert.equal(displayRequests,1);assert.equal(finderRequests,1);}
 const before=[finderRequests,displayRequests,readRequests];store.prefetch(keys.map(id=>({table:'Settings',id})));assert.deepEqual([finderRequests,displayRequests,readRequests],before);
 ctx.hubSet_(store,'generation',99,Date.now());store.prefetch(keys.map(id=>({table:'Settings',id})));assert.equal(ctx.hubSetting_(store,'generation'),99);
});
test('Settings blank rows and header-only grid keep exact missing semantics',()=>{
 const sh=books.canonical.getSheetByName('Settings'),old=sh.rows;
 try {
  sh.rows=[old[0]];displayRequests=readRequests=finderRequests=0;
  const empty=new ctx.Store(cfg);empty.prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);assert.equal(empty.get('Settings','environment'),null);assert.equal(readRequests+displayRequests+finderRequests,0);
  sh.rows=[old[0],[],old.find(r=>r[0]==='environment'),[],old.find(r=>r[0]==='schema_version')];
  const store=new ctx.Store(cfg);store.prefetch([{table:'Settings',id:'schema_version'},{table:'Settings',id:'environment'}]);assert.equal(store.position('Settings','environment'),3);assert.equal(store.position('Settings','schema_version'),5);
  assert.throws(()=>new ctx.Store(cfg).prefetch([{table:'Settings',id:''}]),/INDEX_CORRUPT/);
 }finally{sh.rows=old;}
});
test('Settings duplicate requested ID stops before body read; unrelated duplicate is tolerated',()=>{
 const sh=books.canonical.getSheetByName('Settings'),old=sh.rows;
 try {
  const row=old.find(r=>r[0]==='environment');sh.rows=old.concat([row.slice()]);readRequests=0;
  assert.throws(()=>new ctx.Store(cfg).prefetch([{table:'Settings',id:'schema_version'},{table:'Settings',id:'environment'}]),/INDEX_CORRUPT/);assert.equal(readRequests,0);
  sh.rows=old.concat([['unrelated','string','x','','',1,'t'],['unrelated','string','x','','',1,'t']]);
  new ctx.Store(cfg).prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);
 }finally{sh.rows=old;}
});
test('Settings key display formatting and case remain exact, decoded key is revalidated',()=>{
 const sh=books.canonical.getSheetByName('Settings'),old=sh.rows;
 try {
  sh.rows=old.map(r=>r.slice());const index=sh.rows.findIndex(r=>r[0]==='environment');
  sh.display={[index]:['Environment']};const store=new ctx.Store(cfg);store.prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);assert.equal(store.get('Settings','environment'),null);
  sh.display={[index]:['environment']};sh.rows[index][0]='another';
  assert.throws(()=>new ctx.Store(cfg).prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]),/INDEX_CORRUPT/);
  sh.rows[index][0]=123;assert.throws(()=>new ctx.Store(cfg).prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]),/COLUMN_TYPE/);
 }finally{sh.rows=old;delete sh.display;}
});
test('Settings non-ASCII keys use finder and fresh calls observe uncached changes',()=>{
 const sh=books.canonical.getSheetByName('Settings'),old=sh.rows;
 try {
  sh.rows=old.concat([['架空設定','string','x','','',1,'t']]);finderRequests=displayRequests=0;
  new ctx.Store(cfg).prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);assert.equal(finderRequests,2);
  sh.rows=old.map(r=>r.slice());const store=new ctx.Store(cfg);store.prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);
  sh.rows.find(r=>r[0]==='generation')[3]=123;
  store.prefetch([{table:'Settings',id:'generation'},{table:'Settings',id:'next_change'}]);assert.equal(ctx.hubSetting_(store,'generation'),123);
 }finally{sh.rows=old;}
});
test('Settings failed key scan remains retryable without cache or writes',()=>{
 if(process.env.PHH_SETTINGS_INDEX_EXPECT!=='1')return;
 const store=new ctx.Store(cfg),before=batches.length;failDisplay=true;
 try{assert.throws(()=>store.prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]),/DISPLAY_UNAVAILABLE/);}finally{failDisplay=false;}
 assert.equal(Object.keys(store.cache).length,0);assert.equal(batches.length,before);
 store.prefetch([{table:'Settings',id:'environment'},{table:'Settings',id:'schema_version'}]);assert.equal(store.get('Settings','environment').string_value,'PHH_TEST');
});
console.log('Hub storage: '+passed+' PASSED');
