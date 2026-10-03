// Driveは模擬。外部の保存先・認証情報には接続しない。
const fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
const tests=String.raw`
vm.runInContext(['Backup.gs','BackupDrive.gs'].map(n=>fs.readFileSync(__dirname+'/'+n,'utf8')).join('\n'),ctx);
ctx.DriveApp={Access:{PRIVATE:'private'}};
const owner='s@example.test';
const iter=values=>{let i=0;return {hasNext:()=>i<values.length,next:()=>values[i++]};};
class File {
 constructor(name,body=''){Object.assign(this,{name,body,owner,access:'private',editors:[],viewers:[]});}
 getName(){return this.name;}getOwner(){return {getEmail:()=>this.owner};}getSharingAccess(){return this.access;}
 getEditors(){return this.editors.map(e=>({getEmail:()=>e}));}getViewers(){return this.viewers;}getSize(){return Buffer.byteLength(this.body);}
 getBlob(){return {getDataAsString:()=>this.body};}getId(){return this.name;}
}
class Folder extends File {
 constructor(name){super(name);this.files=[];this.folders=[];this.failAt=0;}
 createFolder(name){const f=new Folder(name);f.failAt=this.childFailAt || 0;this.folders.push(f);return f;}
 createFile(name,body){if(this.failAt===this.files.length+1)throw Error('simulated Drive failure');const f=new File(name,body);this.files.push(f);return f;}
 getFiles(){return iter(this.files);}
 getFolders(){return iter(this.folders.filter(f=>!f.trashed));}setTrashed(v){this.trashed=v;}
}
function example(){const s=fresh();app(s,meal());s.all=t=>[...s.tables[t].values()].map(copy);return s;}
function fixture(){return ctx.hubBackupCapture_(example(),now);}
test('capture includes all16 typed tables without modifying source',()=>{const s=example(),before=JSON.stringify(s.tables),b=ctx.hubBackupCapture_(s,now);assert.equal(b.manifest.tables.length,16);assert.equal(b.manifest.snapshot_revision,7);assert.equal(ctx.hubBackupVerify_(b.manifest,b.objects).DailySummary[0].kcal,100);assert.equal(JSON.stringify(s.tables),before);});
test('Drive readback restores IDs/counts and manifest is written last',()=>{const b=fixture(),root=new Folder('root'),r=ctx.hubBackupWriteFolder_(root,b,owner),folder=root.folders[0];assert.equal(folder.files.at(-1).name,'manifest.json');assert.equal(r.complete,true);assert.equal(r.counts.length,16);const loaded=ctx.hubBackupReadFolder_(folder,owner);assert.deepEqual(copy(loaded.manifest),copy(b.manifest));assert.equal(loaded.tables.Meals[0].id,ctx.hubBackupVerify_(b.manifest,b.objects).Meals[0].id);});
test('interrupted upload preserves partial folder but has no completed manifest',()=>{const root=new Folder('root');root.childFailAt=2;assert.throws(()=>ctx.hubBackupWriteFolder_(root,fixture(),owner),/simulated Drive failure/);assert.equal(root.folders.length,1);assert.equal(root.folders[0].files.length,1);assert.ok(!root.folders[0].files.some(f=>f.name==='manifest.json'));assert.throws(()=>ctx.hubBackupReadFolder_(root.folders[0],owner),/BACKUP_INCOMPLETE/);});
test('public/shared/wrong-owner root refuses writes, shared part refuses reads',()=>{for(const [key,value]of [['access','public'],['editors',['c@example.test']],['viewers',['c@example.test']],['owner','another@example.test']]){const root=new Folder('root');root[key]=value;assert.throws(()=>ctx.hubBackupWriteFolder_(root,fixture(),owner),/BACKUP_ACL/);assert.equal(root.folders.length,0);}const root=new Folder('root');ctx.hubBackupWriteFolder_(root,fixture(),owner);root.folders[0].files[0].viewers=['c@example.test'];assert.throws(()=>ctx.hubBackupReadFolder_(root.folders[0],owner),/BACKUP_ACL/);});
test('corruption, missing manifest, duplicate names and unexpected files refuse restore',()=>{for(const mutate of [f=>f.files[0].body+='corrupt',f=>f.files.pop(),f=>f.files.push(f.files[0]),f=>f.files.push(new File('extra.txt','unexpected'))]){const root=new Folder('root');ctx.hubBackupWriteFolder_(root,fixture(),owner);const f=root.folders[0];mutate(f);assert.throws(()=>ctx.hubBackupReadFolder_(f,owner),/BACKUP_PART_HASH|BACKUP_INCOMPLETE|BACKUP_DUPLICATE_FILE|BACKUP_UNEXPECTED_FILE/);}});
test('unvalidated real-data snapshot cannot create a Drive folder',()=>{const root=new Folder('root'),b=fixture();b.manifest.environment='other';assert.throws(()=>ctx.hubBackupWriteFolder_(root,b,owner),/BACKUP_MANIFEST_HASH/);assert.equal(root.folders.length,0);const s=example();s.config.real_data_enabled=true;assert.throws(()=>ctx.hubBackupCapture_(s,now),/BACKUP_REAL_DATA_DISABLED/);});
const books=new Map(),files=new Map();let batchCalls=0,batchFailure=false,afterBatch,staleReadback=false;
class RestoreSheet {
 constructor(name,index){this.name=name;this.index=index;this.maxRows=1;this.rows=[schema.tables[name].columns.map(c=>c.name)];}
 getName(){return this.name;}getSheetId(){return this.index;}getLastRow(){return this.rows.length;}
 getLastColumn(){return this.rows[0].length;}getMaxRows(){return this.maxRows;}
 getRange(row,col,count,width){return {getValues:()=>{if(staleReadback && this.rows.length>1)throw Error('stale SpreadsheetApp after API write');return Array.from({length:count},(_,i)=>Array.from({length:width},(_,j)=>this.rows[row+i-1]?.[col+j-1] ?? ''));}};}
}
class RestoreBook {
 constructor(id){this.id=id;this.sheets=Object.keys(schema.tables).map((name,index)=>new RestoreSheet(name,index));books.set(id,this);files.set(id,new File(id));}
 getId(){return this.id;}getSheets(){return this.sheets;}getSheetByName(name){return this.sheets.find(s=>s.name===name);}
}
ctx.DriveApp.getFileById=id=>files.get(id);
ctx.Sheets={Spreadsheets:{batchUpdate:({requests},id)=>{
 batchCalls++;if(batchFailure)throw Error('simulated Sheets failure');const book=books.get(id);
 for(const request of requests){if(request.appendDimension){const r=request.appendDimension;book.sheets.find(s=>s.index===r.sheetId).maxRows+=r.length;continue;}
 const r=request.updateCells,sheet=book.sheets.find(s=>s.index===r.start.sheetId);assert.ok(sheet.maxRows>=r.start.rowIndex+r.rows.length);
 r.rows.forEach((row,i)=>{sheet.rows[r.start.rowIndex+i]=row.values.map(v=>v.userEnteredValue ? Object.values(v.userEnteredValue)[0] : '');});}
 if(afterBatch)afterBatch(book);
}}};
ctx.Sheets.Spreadsheets.Values={batchGet:(id,{ranges})=>({valueRanges:ranges.map(range=>{const name=range.split("'")[1],rows=books.get(id).getSheetByName(name).rows.map(r=>r.slice());return {values:rows};})})};
const sourceConfig={canonical:'canonical',inbox:'inbox',results:'results',owner,environment:'PHH_TEST',real_data_enabled:false};
test('separate restore writes all16 tables in one batch and verifies IDs/null/zero/generation',()=>{
 const source=example(),before=JSON.stringify(Object.fromEntries(Object.entries(source.tables).map(([name,rows])=>[name,[...rows.values()]]))),b=ctx.hubBackupCapture_(source,now),book=new RestoreBook('restore'),calls=batchCalls;
 const r=ctx.hubBackupRestoreBook_(book,b,sourceConfig,now+1);assert.equal(batchCalls,calls+1);assert.equal(r.complete,true);assert.equal(r.generation,2);assert.equal(r.counts.length,16);
 const settings=book.getSheetByName('Settings').rows.slice(1).map(row=>ctx.hubDecode_('Settings',row));assert.equal(settings.find(row=>row.id==='generation').number_value,2);
 const nutrients=book.getSheetByName('IntakeNutrients').rows.slice(1).map(row=>ctx.hubDecode_('IntakeNutrients',row));assert.equal(nutrients.find(row=>row.nutrient_id==='fat_g').value,0);assert.equal(nutrients.find(row=>row.nutrient_id==='carbohydrate_g').value,null);
 assert.equal(ctx.hubDecode_('Meals',book.getSheetByName('Meals').rows[1]).id,source.tables.Meals.keys().next().value);assert.equal(JSON.stringify(Object.fromEntries(Object.entries(source.tables).map(([name,rows])=>[name,[...rows.values()]]))),before);
});
test('restore verifies via fresh API values even if SpreadsheetApp readback stays stale',()=>{staleReadback=true;try{assert.equal(ctx.hubBackupRestoreBook_(new RestoreBook('stale'),fixture(),sourceConfig,now).complete,true);}finally{staleReadback=false;}});
test('all three source books, public/shared/foreign targets and environment mismatch refuse writes',()=>{
 for(const id of ['canonical','inbox','results']){const book=new RestoreBook(id),calls=batchCalls;assert.throws(()=>ctx.hubBackupRestoreBook_(book,fixture(),sourceConfig,now),/BACKUP_SOURCE_TARGET/);assert.equal(batchCalls,calls);}
 for(const [key,value]of [['access','public'],['editors',['c@example.test']],['viewers',['c@example.test']],['owner','another@example.test']]){const book=new RestoreBook('acl-'+key);files.get(book.id)[key]=value;const calls=batchCalls;assert.throws(()=>ctx.hubBackupRestoreBook_(book,fixture(),sourceConfig,now),/BACKUP_ACL/);assert.equal(batchCalls,calls);}
 const calls=batchCalls;assert.throws(()=>ctx.hubBackupRestoreBook_(new RestoreBook('environment'),fixture(),{...sourceConfig,environment:'PHH_PRODUCTION'},now),/BACKUP_ENVIRONMENT/);assert.throws(()=>ctx.hubBackupRestoreBook_(new RestoreBook('real'),fixture(),{...sourceConfig,real_data_enabled:true},now),/BACKUP_REAL_DATA_DISABLED/);assert.equal(batchCalls,calls);
});
test('nonempty, wrong-header, missing and extra target tables refuse writes before mutation',()=>{
 for(const mutate of [b=>b.sheets[0].rows.push(['existing']),b=>b.sheets[0].rows[0][0]='wrong',b=>b.sheets.pop(),b=>b.sheets.push({getName:()=> 'private-extra'})]){const book=new RestoreBook('shape-'+batchCalls);mutate(book);const calls=batchCalls;assert.throws(()=>ctx.hubBackupRestoreBook_(book,fixture(),sourceConfig,now),/BACKUP_TARGET_NOT_EMPTY|BACKUP_TARGET_TABLES|COLUMN_TYPE/);assert.equal(batchCalls,calls);}
});
test('corrupt backup refuses a restore before any target write',()=>{
 const book=new RestoreBook('corrupt'),b=fixture(),hash=Object.keys(b.objects)[0],calls=batchCalls;b.objects[hash]+='tampered';assert.throws(()=>ctx.hubBackupRestoreBook_(book,b,sourceConfig,now),/BACKUP_PART_HASH/);assert.equal(batchCalls,calls);assert.ok(book.sheets.every(s=>s.rows.length===1));
});
test('failed batch leaves source intact and does not report completed restore',()=>{
 const source=example(),before=JSON.stringify(Object.fromEntries(Object.entries(source.tables).map(([name,rows])=>[name,[...rows.values()]]))),book=new RestoreBook('failure');batchFailure=true;
 try{assert.throws(()=>ctx.hubBackupRestoreBook_(book,ctx.hubBackupCapture_(source,now),sourceConfig,now),/simulated Sheets failure/);}finally{batchFailure=false;}
 assert.ok(book.sheets.every(s=>s.rows.length===1));assert.equal(JSON.stringify(Object.fromEntries(Object.entries(source.tables).map(([name,rows])=>[name,[...rows.values()]]))),before);
});
test('readback mismatch and ACL change after a write refuse completed restore',()=>{
 const book=new RestoreBook('readback');afterBatch=b=>{const sheet=b.getSheetByName('Settings'),col=sheet.rows[0].indexOf('updated_at');sheet.rows[1][col]='2030-01-01T00:00:00.000Z';};
 try{assert.throws(()=>ctx.hubBackupRestoreBook_(book,fixture(),sourceConfig,now),/BACKUP_RESTORE_READBACK/);}finally{afterBatch=undefined;}
 const shared=new RestoreBook('shared-after');afterBatch=b=>{files.get(b.id).viewers=['c@example.test'];};try{assert.throws(()=>ctx.hubBackupRestoreBook_(shared,fixture(),sourceConfig,now),/BACKUP_ACL/);}finally{afterBatch=undefined;}
});

const propertyValues=new Map(),folders=new Map();ctx.PropertiesService={getScriptProperties:()=>({getProperty:k=>propertyValues.get(k) || null,setProperty:(k,v)=>propertyValues.set(k,v)})};
ctx.DriveApp.createFolder=name=>{const f=new Folder(name);folders.set(f.getId(),f);return f;};ctx.DriveApp.getFolderById=id=>folders.get(id);
test('backup root is created once and a stored shared or foreign root is refused',()=>{
 propertyValues.clear();const root=ctx.hubBackupRoot_(sourceConfig);assert.equal(ctx.hubBackupRoot_(sourceConfig),root);assert.equal(folders.size,1);
 root.viewers=['c@example.test'];assert.throws(()=>ctx.hubBackupRoot_(sourceConfig),/BACKUP_ACL/);root.viewers=[];
 const size=folders.size;assert.throws(()=>ctx.hubBackupRoot_({...sourceConfig,real_data_enabled:true}),/BACKUP_REAL_DATA_DISABLED/);assert.equal(folders.size,size);
});

test('Drive upload and readback start only after the snapshot lock is released',()=>{
 const run=ctx.hubRun_,write=ctx.hubBackupWriteFolder_;let held=false,checked=false;const store=example();store.config={...sourceConfig};
 ctx.hubRun_=(_,work)=>{held=true;try{return work(store);}finally{held=false;}};
 ctx.hubBackupWriteFolder_=(root,bundle,owner)=>{assert.equal(held,false);checked=true;return write(root,bundle,owner);};
 try {assert.equal(ctx.hubCreateBackup_().complete,true);assert.equal(checked,true);assert.equal(held,false);}finally{ctx.hubRun_=run;ctx.hubBackupWriteFolder_=write;}
});
test('restore refuses repeated attempt and backup outside the configured root before creating a target',()=>{
 const run=ctx.hubRun_;ctx.hubRun_=(_,work)=>work({config:sourceConfig});
 try {
  propertyValues.set('PHH_BACKUP_LAST',JSON.stringify({complete:true,folder_id:'outside',sha256:'x'}));propertyValues.set('PHH_BACKUP_RESTORE_TARGET','existing');
  assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_RESTORE_ALREADY_ATTEMPTED/);propertyValues.delete('PHH_BACKUP_RESTORE_TARGET');
  const outside=new Folder('outside');outside.getParents=()=>iter([]);folders.set('outside',outside);
  assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_ROOT_MISMATCH/);assert.ok(!propertyValues.has('PHH_BACKUP_RESTORE_TARGET'));
 } finally {ctx.hubRun_=run;}
});
test('restore orchestration requires unchanged source before recording success',()=>{
 const run=ctx.hubRun_,capture=ctx.hubBackupCapture_,empty=ctx.hubBackupEmptyBook_;ctx.SpreadsheetApp={openById:()=>({})};
 const b=fixture(),root=ctx.hubBackupRoot_(sourceConfig),saved=ctx.hubBackupWriteFolder_(root,b,owner),folder=root.folders.at(-1);
 folder.getParents=()=>iter([root]);folders.set(saved.folder_id,folder);propertyValues.set('PHH_BACKUP_LAST',JSON.stringify({...saved,sha256:b.manifest.sha256}));
 ctx.hubRun_=(_,work)=>work({config:sourceConfig});ctx.hubBackupEmptyBook_=()=>new RestoreBook('entry-restore');
 try {
  let count=0;ctx.hubBackupCapture_=()=>({...b,manifest:{...b.manifest,sha256:++count===1?'before':'after'}});
  assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_SOURCE_CHANGED/);assert.ok(!propertyValues.has('PHH_BACKUP_RESTORE_LAST'));
  propertyValues.delete('PHH_BACKUP_RESTORE_TARGET');propertyValues.delete('PHH_BACKUP_RESTORE_ATTEMPT');ctx.hubBackupCapture_=()=>b;const result=ctx.hubRestoreLastBackup_();assert.equal(result.source_unchanged,true);assert.equal(result.generation,2);assert.equal(JSON.parse(propertyValues.get('PHH_BACKUP_RESTORE_LAST')).complete,true);
 } finally {ctx.hubRun_=run;ctx.hubBackupCapture_=capture;ctx.hubBackupEmptyBook_=empty;}
});

test('retention trashes obsolete independent snapshots but preserves retained references and incomplete folders',()=>{
 const root=new Folder('retention');for(let i=0;i<35;i++)ctx.hubBackupWriteFolder_(root,ctx.hubBackupCapture_(example(),now+i*86400000),owner);
 const partial=root.createFolder('PHH-2026-10-01-00000000-0000-0000-0000-000000000001');const body='{}\n';partial.createFile(ctx.hubHash_(body)+'.jsonl',body);
 const result=ctx.hubBackupPrune_(root,sourceConfig);assert.ok(result.kept<=23 && result.retired>0);assert.equal(result.kept+result.retired,35);assert.equal(result.preserved_incomplete,1);assert.ok(!partial.trashed);const protectedHashes=new Set(root.folders.filter(f=>!f.trashed).flatMap(f=>f.files.filter(x=>x.name!=='manifest.json').map(x=>x.name.slice(0,-6))));assert.equal(result.protected_objects,protectedHashes.size);
 for(const folder of root.folders.filter(f=>!f.trashed && f!==partial))assert.equal(ctx.hubBackupReadFolder_(folder,owner).manifest.complete,true);
});
test('corrupt or shared generation stops retention before any trash move',()=>{
 const root=new Folder('bad-retention');for(let i=0;i<10;i++)ctx.hubBackupWriteFolder_(root,ctx.hubBackupCapture_(example(),now+i*86400000),owner);
 root.folders.at(-1).files[0].body+='tamper';assert.throws(()=>ctx.hubBackupPrune_(root,sourceConfig),/BACKUP_PART_HASH/);assert.ok(root.folders.every(f=>!f.trashed));
});
test('applied batch with lost response retries by exact readback without another write',()=>{
 const book=new RestoreBook('lost-response'),b=fixture();afterBatch=()=>{throw Error('lost response');};
 try{assert.throws(()=>ctx.hubBackupRestoreBook_(book,b,sourceConfig,now),/lost response/);}finally{afterBatch=undefined;}
 const calls=batchCalls,r=ctx.hubBackupRestoreBook_(book,b,sourceConfig,now+60000);
 assert.equal(r.complete,true);assert.equal(batchCalls,calls);
 book.getSheetByName('Meals').rows[1][0]='different';
 assert.throws(()=>ctx.hubBackupRestoreBook_(book,b,sourceConfig,now+60000),/BACKUP_TARGET_NOT_EMPTY|BACKUP_RESTORE_READBACK/);assert.equal(batchCalls,calls);
});
test('Sheets capture refuses duplicate raw Operations rows',()=>{
 const book=new RestoreBook('capture'),s=example();for(const name of Object.keys(schema.tables))book.getSheetByName(name).rows.push(...s.all(name).map(r=>copy(ctx.hubRow_(name,r))));
 const operations=book.getSheetByName('Operations');operations.rows.push(copy(operations.rows[1]));
 ctx.SpreadsheetApp={openById:()=>book};const store=vm.runInContext('new HubSheetsStore({canonical:"capture",environment:"PHH_TEST",real_data_enabled:false})',ctx);
 // Seed settings cache as normal indexed reads do; capture must still use fresh raw rows.
 for(const row of s.all('Settings'))store.cache['Settings\0'+row.id]=row;
 assert.throws(()=>ctx.hubBackupCapture_(store,now),/BACKUP_DUPLICATE_OR_FIELDS/);
});

test('fresh end settings detects revision change despite populated store cache',()=>{
 const book=new RestoreBook('changed'),s=example();for(const name of Object.keys(schema.tables))book.getSheetByName(name).rows.push(...s.all(name).map(r=>copy(ctx.hubRow_(name,r))));
 ctx.SpreadsheetApp={openById:()=>book};const store=vm.runInContext('new HubSheetsStore({canonical:"changed",environment:"PHH_TEST",real_data_enabled:false})',ctx);
 for(const row of s.all('Settings'))store.cache['Settings\0'+row.id]=row;
 const sheet=book.getSheetByName('Settings'),original=sheet.getRange.bind(sheet);let reads=0;
 sheet.getRange=(...args)=>{if(args[0]===2 && ++reads===3){const row=sheet.rows.find(r=>r[0]==='next_change');row[sheet.rows[0].indexOf('number_value')]=8;}return original(...args);};
 assert.throws(()=>ctx.hubBackupCapture_(store,now),/BACKUP_CHANGED/);
});
test('capture book holds script lock through reads and releases after failure or success',()=>{
 const book=new RestoreBook('locked'),s=example();for(const name of Object.keys(schema.tables))book.getSheetByName(name).rows.push(...s.all(name).map(r=>copy(ctx.hubRow_(name,r))));
 let locked=false,releases=0,busy=false;ctx.LockService={getScriptLock:()=>({tryLock:()=>{if(busy)return false;locked=true;return true;},releaseLock:()=>{assert.ok(locked);locked=false;releases++;}})};
 ctx.SpreadsheetApp={openById:()=>{assert.ok(locked);return book;}};
 ctx.hubBackupCaptureBook_(sourceConfig,now);assert.equal(releases,1);
 book.getSheetByName('Operations').rows.push(copy(book.getSheetByName('Operations').rows[1]));
 assert.throws(()=>ctx.hubBackupCaptureBook_(sourceConfig,now),/BACKUP_DUPLICATE_OR_FIELDS/);assert.equal(releases,2);assert.equal(locked,false);
 busy=true;assert.throws(()=>ctx.hubBackupCaptureBook_(sourceConfig,now),/BUSY/);assert.equal(releases,2);
});
test('retention folder boundary refuses tampered manifest and missing part',()=>{
 const root=new Folder('retention');ctx.hubBackupWriteFolder_(root,fixture(),owner);
 assert.equal(ctx.hubBackupRetentionFolders_(root.folders,owner).keep.length,1);
 const folder=root.folders[0],manifest=folder.files.at(-1);manifest.body=manifest.body.replace('PHH_TEST','PHH_PRODUCTION');
 assert.throws(()=>ctx.hubBackupRetentionFolders_(root.folders,owner),/BACKUP_MANIFEST_HASH/);
 const good=new Folder('missing');ctx.hubBackupWriteFolder_(good,fixture(),owner);good.folders[0].files.shift();assert.throws(()=>ctx.hubBackupRetentionFolders_(good.folders,owner),/BACKUP_PART_HASH/);
});

test('immutable backup reader supports the batched settings interface used by latest main',()=>{
 const b=fixture(),tables=ctx.hubBackupVerify_(b.manifest,b.objects),reader=ctx.hubBackupReader_(tables,'PHH_TEST'),before=JSON.stringify(tables);
 reader.prefetch([{table:'Settings',id:'generation'},{table:'Meals',id:tables.Meals[0].id}]);
 assert.equal(ctx.hubSetting_(reader,'generation'),1);assert.equal(JSON.stringify(tables),before);
});

test('retention continues for completed folders while protecting interrupted upload objects',()=>{
 const complete=new Folder('complete');ctx.hubBackupWriteFolder_(complete,fixture(),owner);
 const changed=example(),id=changed.all('Meals')[0].id;app(changed,meal('update_meal',id,1,{quantity:2}));const partial=new Folder('partial');partial.childFailAt=2;assert.throws(()=>ctx.hubBackupWriteFolder_(partial,ctx.hubBackupCapture_(changed,now),owner),/simulated Drive failure/);
 const draft=partial.folders[0],r=ctx.hubBackupRetentionFolders_([...complete.folders,draft],owner);
 assert.equal(r.keep.length,1);assert.equal(r.retire.length,0);const partialHash=draft.files[0].name.slice(0,-6);assert.ok(!complete.folders[0].files.some(f=>f.name===draft.files[0].name));assert.ok(r.protected_objects.includes(partialHash));
 draft.files.push(new File('unknown.txt','unknown'));assert.throws(()=>ctx.hubBackupRetentionFolders_([...complete.folders,draft],owner),/BACKUP_UNEXPECTED_FILE/);
 draft.files.pop();draft.files[0].body+='bad';assert.throws(()=>ctx.hubBackupRetentionFolders_([...complete.folders,draft],owner),/BACKUP_PART_HASH/);
});

test('restore entry recovers an applied lost response using persistent target and manifest binding',()=>{
 const run=ctx.hubRun_,capture=ctx.hubBackupCapture_,empty=ctx.hubBackupEmptyBook_;propertyValues.delete('PHH_BACKUP_RESTORE_TARGET');propertyValues.delete('PHH_BACKUP_RESTORE_ATTEMPT');propertyValues.delete('PHH_BACKUP_RESTORE_LAST');
 const b=fixture(),root=ctx.hubBackupRoot_(sourceConfig),saved=ctx.hubBackupWriteFolder_(root,b,owner),folder=root.folders.at(-1);folder.getParents=()=>iter([root]);folders.set(saved.folder_id,folder);propertyValues.set('PHH_BACKUP_LAST',JSON.stringify({...saved,sha256:b.manifest.sha256}));
 let created=0;ctx.hubRun_=(_,work)=>work({config:sourceConfig});ctx.hubBackupCapture_=()=>b;ctx.hubBackupEmptyBook_=()=>{created++;return new RestoreBook('persistent-retry');};ctx.SpreadsheetApp={openById:id=>books.get(id)};
 try {
  afterBatch=()=>{throw Error('lost entry response');};assert.throws(()=>ctx.hubRestoreLastBackup_(),/lost entry response/);afterBatch=undefined;
  assert.ok(!propertyValues.has('PHH_BACKUP_RESTORE_LAST'));const calls=batchCalls,result=ctx.hubRestoreLastBackup_();assert.equal(result.complete,true);assert.equal(created,1);assert.equal(batchCalls,calls);assert.equal(result.canonical_id,'persistent-retry');
  const savedState=propertyValues.get('PHH_BACKUP_RESTORE_ATTEMPT'),attempt=JSON.parse(savedState);attempt.manifest_sha256='other';propertyValues.set('PHH_BACKUP_RESTORE_ATTEMPT',JSON.stringify(attempt));assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_RESTORE_ATTEMPT_MISMATCH/);assert.equal(batchCalls,calls);
  propertyValues.set('PHH_BACKUP_RESTORE_ATTEMPT',savedState);ctx.hubBackupCapture_=()=>({...b,manifest:{...b.manifest,sha256:'source-changed'}});assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_SOURCE_CHANGED/);assert.equal(batchCalls,calls);ctx.hubBackupCapture_=()=>b;books.get('persistent-retry').getSheetByName('Meals').rows[1][0]='changed';assert.throws(()=>ctx.hubRestoreLastBackup_(),/BACKUP_TARGET_NOT_EMPTY/);assert.equal(batchCalls,calls);
 }finally{afterBatch=undefined;ctx.hubRun_=run;ctx.hubBackupCapture_=capture;ctx.hubBackupEmptyBook_=empty;}
});
test('prune entry rejects unverified partial files before any retirement',()=>{
 for(const mode of ['unknown','corrupt']){const root=new Folder('bad-partial');for(let i=0;i<12;i++)ctx.hubBackupWriteFolder_(root,ctx.hubBackupCapture_(example(),now+i*86400000),owner);
 const partial=root.createFolder('PHH-2026-10-01-00000000-0000-0000-0000-000000000002'),body='{}\n';partial.createFile(mode==='unknown'?'unknown.jsonl':ctx.hubHash_(body)+'.jsonl',mode==='corrupt'?body+'bad':body);
 assert.throws(()=>ctx.hubBackupPrune_(root,sourceConfig),/BACKUP_UNEXPECTED_FILE|BACKUP_PART_HASH/);assert.ok(root.folders.every(f=>!f.trashed));}
});
console.log('Hub backup Drive: '+passed+' PASSED');
`;
vm.runInNewContext(source+tests,{require,console,Buffer,__dirname});
