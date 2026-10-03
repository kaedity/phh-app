// 32表のバックアップ/別先復元。Drive/Sheetsは模擬で実ファイルへ接続しません。
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const resource=__dirname+'/../Core/Sources/PHHHubCore/Resources/',layout=JSON.parse(fs.readFileSync(resource+'planning-p5-layout.json','utf8'));
const schema=JSON.parse(fs.readFileSync(resource+'planning-p5-schema.json','utf8'));
const prefix=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
function harness(target) {
 const source=prefix.replace("JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8'))",JSON.stringify(target)).replace("'Engine.gs','API.gs'","'Engine.gs','API.gs','TrainingP3.gs','FoodP4.gs','FoodStorageP4.gs','PlanningP5.gs','PlanningStorageP5.gs','PlanningIntakeP5.gs'");
 const h={exports:{}};new Function('require','module','__dirname',source+'\nmodule.exports={ctx,copy,fresh,app,intake,meal,MemoryStore};')(require,h,__dirname);
 vm.runInContext('const HUB_PLANNING_LAYOUT_='+JSON.stringify(layout)+';'+fs.readFileSync(__dirname+'/Backup.gs','utf8'),h.exports.ctx);return {...h.exports,schema:target};
}
const h=harness(schema),{ctx,copy,fresh,app,intake,meal}=h;
const now=Date.parse('2026-10-03T03:00:00Z'),id=n=>`00000000-0000-4000-a000-${String(n).padStart(12,'0')}`;
const fixture=JSON.parse(fs.readFileSync(__dirname+'/planning-p5-fixture.json','utf8')),ops=fixture.operations.map(o=>({...o,environment:'PHH_TEST'}));let sequence=1000;
const book=(s,hh=h)=>Object.fromEntries(Object.keys(hh.schema.tables).map(t=>[t,[...s.tables[t].values()].map(r=>Object.fromEntries(hh.schema.tables[t].columns.map(c=>[c.name,r[c.name]??null])))]));
const meta=(s,hh=h)=>({environment:s.config.environment,start_generation:hh.ctx.hubSetting_(s,'generation'),end_generation:hh.ctx.hubSetting_(s,'generation'),start_revision:hh.ctx.hubSetting_(s,'next_change'),end_revision:hh.ctx.hubSetting_(s,'next_change'),now});
const p5=tables=>copy(ctx.hubP5ReadPlan_(Object.keys(layout).flatMap(t=>[t,...layout[t].children.map(c=>c.table)]).flatMap(table=>tables[table].map(row=>({table,row}))),layout));
const setup=()=>{const s=fresh();for(const o of ops){const r=app(s,o,now);assert.equal(r.status,'committed',o.action+':'+r.error_code);}return s;};
const changed=(i,expected,mutate)=>{const o=copy(ops[i]);o.operation_id=id(sequence++);o.expected_revision=expected;mutate(o);return o;};
const save=(s,o)=>{const r=app(s,o,now);assert.equal(r.status,'committed',o.action+':'+r.error_code);return r;};
let passed=0;function test(name,f){f();passed++;console.log('ok '+name);}
test('32 table split backup separate restore preserves frozen goals versions micronutrients null zero receipts and source',()=>{
 const s=setup(),food=meal();save(s,food);const before=book(s),b=copy(ctx.hubBackupCreate_(before,meta(s),1800)),restored=copy(ctx.hubBackupRestorePlan_(b.manifest,b.objects,now+1));
 assert.equal(b.manifest.tables.length,32);assert.ok(b.manifest.tables.some(t=>t.parts.length>1));assert.equal(restored.generation,2);
 for(const t of Object.keys(before).filter(t=>t!=='Settings'))assert.deepEqual(restored.tables[t],before[t]);assert.deepEqual(p5(restored.tables),p5(before));assert.deepEqual(book(s),before);
 const ns=restored.tables.SupplementDayNutrients;assert.equal(ns.find(n=>n.nutrient_id==='protein').value,null);assert.equal(ns.find(n=>n.nutrient_id==='fat').value,0);assert.equal(ns.find(n=>n.nutrient_id==='vitamin_b12').value,6);
 assert.equal(restored.tables.FoodDays.find(d=>d.local_date==='2026-10-03').day_state,'changed');assert.equal(restored.tables.DailyGoals[0].goal_state,'frozen');assert.equal(restored.tables.DailyGoalAdjustments[0].reason,'架空手動');
});
test('new product and plan versions keep past day reference and snapshots in the restored bundle',()=>{
 const s=setup(),old=copy(book(s).SupplementDays[0]);const product=changed(3,0,o=>{o.entity_id=id(900);o.payload.product.id=o.entity_id;o.payload.product.revision=2;o.payload.product.nutrients[0].value=30;});save(s,product);
 save(s,changed(4,0,o=>{o.entity_id=id(901);o.payload.plan.id=o.entity_id;o.payload.plan.revision=2;o.payload.plan.productVersionID=product.entity_id;o.payload.plan.effectiveFrom='2026-10-04';}));
 const b=copy(ctx.hubBackupCreate_(book(s),meta(s))),target=copy(ctx.hubBackupRestorePlan_(b.manifest,b.objects,now+1));assert.equal(target.tables.SupplementProducts.length,2);assert.equal(target.tables.SupplementPlans.length,2);assert.deepEqual(target.tables.SupplementDays[0],old);assert.equal(p5(target.tables).filter(r=>r.key==='day')[0].model.nutrients[0].value,20);
});
test('retired adjustment and nutrient children remain indexed tombstones and are not live members',()=>{
 const s=setup(),daily=changed(1,0,o=>{o.entity_id=id(910);o.payload.dailyGoal.date='2026-10-04';o.payload.dailyGoal.state='provisional';o.payload.dailyGoal.manual[0].id=id(911);o.payload.dailyGoal.manual[0].date='2026-10-04';});save(s,daily);
 daily.operation_id=id(sequence++);daily.expected_revision=1;daily.payload.dailyGoal.manual=[];daily.payload.dailyGoal.total=copy(daily.payload.dailyGoal.base);save(s,daily);
 const product=changed(3,0,o=>{o.entity_id=id(920);o.payload.product.id=o.entity_id;o.payload.product.revision=2;o.payload.product.nutrients.pop();});save(s,product);
 const plan=changed(4,0,o=>{o.entity_id=id(921);o.payload.plan.id=o.entity_id;o.payload.plan.revision=2;o.payload.plan.productVersionID=product.entity_id;o.payload.plan.effectiveFrom='2026-10-03';});save(s,plan);
 save(s,changed(5,1,o=>{o.payload.day.revision=2;o.payload.day.planVersionID=plan.entity_id;o.payload.day.productVersionID=product.entity_id;o.payload.day.nutrients.pop();}));
 const b=copy(ctx.hubBackupCreate_(book(s),meta(s))),restored=copy(ctx.hubBackupRestorePlan_(b.manifest,b.objects,now+1));
 for(const t of ['DailyGoalAdjustments','SupplementDayNutrients'])assert.ok(restored.tables[t].some(r=>r.status==='removed' && r.number===0));
 assert.equal(p5(restored.tables).find(r=>r.key==='dailyGoal' && r.model.date==='2026-10-04').model.manual.length,0);assert.equal(p5(restored.tables).find(r=>r.key==='day').model.nutrients.length,4);
});
test('P5 only dates need no DailySummary while real meal summary mismatches are rejected',()=>{
 const s=setup();assert.equal(s.tables.DailySummary.size,0);assert.equal(ctx.hubBackupCreate_(book(s),meta(s)).manifest.complete,true);
 save(s,meal());const bad=book(s);bad.DailySummary[0].kcal++;assert.throws(()=>ctx.hubBackupCreate_(bad,meta(s)),/BACKUP_SUMMARY/);
});
test('missing parents references false totals snapshots and index dates refuse backup before restore',()=>{
 const s=setup(),before=book(s);
 const cases=[b=>b.SupplementDayNutrients.pop(),b=>b.DailyGoals[0].total_kcal++,b=>b.SupplementPlans[0].product_version_id=id(999),b=>b.SupplementDays[0].product_name='偽の名前',b=>b.RecordIndex.find(r=>r.table_name==='SupplementDayNutrients').local_date='2026-10-02',b=>b.RecordIndex.find(r=>r.table_name==='DailyGoalAdjustments').parent_id=id(999)];
 for(const mutate of cases){const bad=copy(before);mutate(bad);assert.throws(()=>ctx.hubBackupCreate_(bad,meta(s)));}assert.deepEqual(book(s),before);
});
test('B2 scalar typed undo fields and committed ledger retain values without field name restriction',()=>{
 const s=setup(),m=meal();save(s,m);
 const row=(key,kind,content)=>[key,kind,'食事','2026-10-01','昼食','架空の食事','1',content,''];assert.equal(intake(s,row('resize','修正','量=2'),2,now+600001).status,'保存済み');
 const operation=[...s.tables.Operations.values()].find(r=>r.actor==='conversation').id;
 for(const [field,value]of [['p5_kind','day'],['p5_amount',0],['p5_override',true],['p5_missing',null]])s.put('UndoValues',{id:ctx.hubId_(operation+'|'+field),operation_id:operation,record_id:m.entity_id,field_name:field,value_type:value===null?'null':typeof value,string_value:typeof value==='string'?value:null,number_value:typeof value==='number'?value:null,bool_value:typeof value==='boolean'?value:null});s.commit();
 const before=book(s),b=copy(ctx.hubBackupCreate_(before,meta(s))),target=copy(ctx.hubBackupRestorePlan_(b.manifest,b.objects,now+1));assert.deepEqual(target.tables.UndoValues,before.UndoValues);assert.deepEqual(target.tables.IntakeLedger,before.IntakeLedger);assert.deepEqual(target.tables.Operations,before.Operations);
});
test('actual P5 B2 settings exceptions completion and undo survive separate restore',()=>{
 const s=fresh(),row=(key,kind,slot,content='',date='2026-10-03',name='架空サプリ')=>[key,kind,'サプリ',date,slot,name,'',content,''];
 assert.equal(intake(s,row('plan','記録','予定','基準量=1; 単位=錠; 日量=2; 自動計上=はい; kcal=10; P=なし; F=0; C=1; 成分:ビタミンC=3; 単位:ビタミンC=mg'),2,now).status,'保存済み');ctx.hubP5AutoPlan_(s,now);s.commit();
 assert.equal(intake(s,row('reported','記録','服用','量=3'),3,now+1).status,'保存済み');
 assert.equal(intake(s,['done','記録','記録日','2026-10-03','食事','記録完了','','',''],4,now+2).status,'保存済み');
 assert.equal(intake(s,row('excluded','取消','服用'),5,now+3).status,'保存済み');
 const before=book(s),bundle=copy(ctx.hubBackupCreate_(before,meta(s))),restored=copy(ctx.hubBackupRestorePlan_(bundle.manifest,bundle.objects,now+4)),target=new h.MemoryStore();
 for(const [table,rows]of Object.entries(restored.tables))for(const r of rows)target.seed(table,r);
 assert.deepEqual(p5(restored.tables),p5(before));assert.deepEqual(restored.tables.UndoValues,before.UndoValues);
 assert.equal(intake(target,row('restore-exclusion','戻す','','対象受付番号=excluded','',''),6,now+5).status,'保存済み');
 const day=p5(book(target)).find(r=>r.key==='day').model;assert.equal(day.state,'confirmed');assert.equal(day.amount,3);assert.equal(day.nutrients[1].value,null);assert.equal(day.nutrients[2].value,0);assert.deepEqual(book(s),before);
});
const baselines=[JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8')),JSON.parse(fs.readFileSync(resource+'training-p3-schema.json','utf8')),JSON.parse(fs.readFileSync(resource+'food-p4-schema.json','utf8'))];
const oldBundles=baselines.map(target=>{const old=harness(target),s=old.fresh();old.app(s,old.meal());old.intake(s,['old-set','記録','筋トレ','2026-10-01','Pull','ダンベルカール','1','重量kg=10; 回数=8',''],2);return {old,source:book(s,old),bundle:copy(old.ctx.hubBackupCreate_(book(s,old),meta(s,old)))};});
test('16 18 and 23 table original bundles verify hashes then migrate through existing additive plans',()=>{
 for(const {source,bundle}of oldBundles){const original=copy(bundle),out=copy(ctx.hubBackupVerify_(bundle.manifest,bundle.objects)),restored=copy(ctx.hubBackupRestorePlan_(bundle.manifest,bundle.objects,now+1));
  assert.equal(Object.keys(out).length,32);assert.equal(restored.generation,2);for(const [table,rows]of Object.entries(source))for(let i=0;i<rows.length;i++)for(const [field,value]of Object.entries(rows[i]))assert.deepEqual(out[table][i][field],value,table+'.'+field);
  assert.equal(out.GoalRules.length,0);assert.equal(out.FoodDays.length,0);assert.equal(out.TrainingSessions[0].lifecycle_state,source.TrainingSessions[0].lifecycle_state??null);assert.deepEqual(bundle,original);
  const retained=ctx.hubBackupRetention_([bundle.manifest]);assert.deepEqual(copy(retained.keep),[bundle.manifest.id]);
 }
});
// 改ざんデータのhashを付け直す攻撃も、旧列/型や現在のドメイン検証で拒否します。
function uncheckedBundle(tables,original) {
 const manifest=copy(original.manifest),objects={};manifest.tables=[];delete manifest.sha256;delete manifest.id;
 for(const [name,rows]of Object.entries(tables)){const body=rows.map(r=>ctx.stable_(r)+'\n').join(''),parts=[];if(rows.length){const sha256=ctx.hubHash_(body);objects[sha256]=body;parts.push({sha256,bytes:Buffer.byteLength(body),count:rows.length});}manifest.tables.push({name,count:rows.length,parts});}
 manifest.sha256=ctx.hubHash_(manifest);manifest.id=ctx.hubId_(manifest.sha256);return {manifest,objects};
}
test('legacy missing tables wrong old columns types rehashed false summary and hash tampering are rejected',()=>{
 for(const {source,bundle}of oldBundles){const bad=copy(bundle),hash=Object.keys(bad.objects)[0];bad.objects[hash]+='tamper';assert.throws(()=>ctx.hubBackupVerify_(bad.manifest,bad.objects),/BACKUP_PART_HASH/);}
 const {source,bundle}=oldBundles[0];for(const mutate of [b=>delete b.Reviews,b=>b.Meals[0].food_name='混入',b=>b.TrainingSets[0].reps='8',b=>b.DailySummary[0].kcal++]){const bad=copy(source);mutate(bad);const b=uncheckedBundle(bad,bundle);assert.throws(()=>ctx.hubBackupVerify_(b.manifest,b.objects),/BACKUP_TABLE_SET|BACKUP_DUPLICATE_OR_FIELDS|BACKUP_COLUMN_TYPE|BACKUP_SUMMARY/);}
 const altered=copy(bundle);altered.manifest.tables[0].count++;assert.throws(()=>ctx.hubBackupVerify_(altered.manifest,altered.objects),/BACKUP_MANIFEST_HASH/);
});
// 模擬Drive/Sheetsで、32表と旧世代の保存/読戻し/別先復元を確認します。
vm.runInContext(fs.readFileSync(__dirname+'/BackupDrive.gs','utf8'),ctx);
const iter=values=>{let i=0;return {hasNext:()=>i<values.length,next:()=>values[i++]};},owner='s@example.test';
class File{constructor(name,body=''){this.name=name;this.body=body;}getName(){return this.name;}getId(){return this.name;}getSize(){return Buffer.byteLength(this.body);}getOwner(){return {getEmail:()=>owner};}getSharingAccess(){return 'private';}getEditors(){return [];}getViewers(){return [];}getBlob(){return {getDataAsString:()=>this.body};}}
class Folder extends File{constructor(name){super(name);this.files=[];this.folders=[];}createFolder(name){const f=new Folder(name);this.folders.push(f);return f;}createFile(name,body){const f=new File(name,body);this.files.push(f);return f;}getFiles(){return iter(this.files);}}
const books=new Map();let writes=0;
class Sheet{constructor(name,index){this.name=name;this.index=index;this.maxRows=1;this.rows=[schema.tables[name].columns.map(c=>c.name)];}getName(){return this.name;}getSheetId(){return this.index;}getLastRow(){return this.rows.length;}getLastColumn(){return this.rows[0].length;}getMaxRows(){return this.maxRows;}getRange(r,c,n,w){return {getValues:()=>Array.from({length:n},(_,i)=>Array.from({length:w},(_,j)=>this.rows[r+i-1]?.[c+j-1]??''))};}}
class Book{constructor(id){this.id=id;this.sheets=Object.keys(schema.tables).map((n,i)=>new Sheet(n,i));books.set(id,this);}getId(){return this.id;}getSheets(){return this.sheets;}getSheetByName(n){return this.sheets.find(s=>s.name===n);}}
ctx.DriveApp={Access:{PRIVATE:'private'},getFileById:id=>new File(id)};
ctx.Sheets={Spreadsheets:{batchUpdate:({requests},id)=>{writes++;const b=books.get(id);for(const q of requests){if(q.appendDimension){b.sheets.find(s=>s.index===q.appendDimension.sheetId).maxRows+=q.appendDimension.length;continue;}const r=q.updateCells,s=b.sheets.find(s=>s.index===r.start.sheetId);assert.ok(s.maxRows>=r.rows.length+1);r.rows.forEach((row,i)=>s.rows[i+1]=row.values.map(v=>v.userEnteredValue?Object.values(v.userEnteredValue)[0]:''));}},Values:{batchGet:(id,{ranges})=>({valueRanges:ranges.map(r=>({values:books.get(id).getSheetByName(r.split("'")[1]).rows.map(r=>r.slice())}))})}}};
const config={canonical:'canonical',inbox:'inbox',results:'results',owner,environment:'PHH_TEST',real_data_enabled:false};
test('mock Drive readback and one batch separate restore include all32 tables for current and legacy snapshots',()=>{
 const s=setup(),before=book(s);s.all=t=>copy(before[t]);const bundle=copy(ctx.hubBackupCapture_(s,now)),root=new Folder('root');assert.equal(bundle.manifest.tables.length,32);for(const b of [bundle,...oldBundles.map(x=>x.bundle)]){
  const saved=ctx.hubBackupWriteFolder_(root,b,owner),folder=root.folders.at(-1);assert.equal(folder.files.at(-1).name,'manifest.json');assert.equal(saved.complete,true);const loaded=ctx.hubBackupReadFolder_(folder,owner);assert.equal(Object.keys(loaded.tables).length,32);assert.equal(loaded.manifest.sha256,b.manifest.sha256);
  const target=new Book('target-'+writes),count=writes,result=ctx.hubBackupRestoreBook_(target,b,config,now+1);assert.equal(writes,count+1);assert.equal(result.complete,true);assert.equal(result.counts.length,32);assert.equal(result.generation,2);
  assert.equal(ctx.hubBackupRestoreBook_(target,b,config,now+2).complete,true);assert.equal(writes,count+1);
 }const retention=ctx.hubBackupRetentionFolders_(root.folders,owner);assert.ok(retention.keep.length>0);assert.equal(retention.keep.length+retention.retire.length,4);assert.deepEqual(book(s),before);
});
console.log(`planning backup P5: ${passed} passed`);
