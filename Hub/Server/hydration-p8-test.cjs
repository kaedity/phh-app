const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const prefix=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
const base={exports:{}};new Function('require','module','__dirname',prefix+'\nmodule.exports={ctx,copy};')(require,base,__dirname);
vm.runInContext(fs.readFileSync(__dirname+'/HydrationP8.gs','utf8'),base.exports.ctx);
const health=JSON.parse(fs.readFileSync(__dirname+'/../Core/Sources/PHHHubCore/Resources/health-p6-schema.json','utf8'));
const target=base.exports.copy(base.exports.ctx.hubHydrationSchema_(health));
const source=prefix.replace("JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8'))",JSON.stringify(target)).replace("'Engine.gs','API.gs'","'Engine.gs','API.gs','HydrationP8.gs'");
const h={exports:{}};new Function('require','module','__dirname',source+'\nmodule.exports={ctx,copy,fresh,app,now};')(require,h,__dirname);
const {ctx,copy,fresh,app,now}=h.exports,id=n=>`00000000-0000-4000-a000-${String(n).padStart(12,'0')}`;
const water=(rev=1,removed=false)=>({id:id(1),date:'2026-10-03',revision:rev,amountML:250,removed});
const op=(p=water(),n=100)=>({schema_version:1,environment:'PHH_TEST',synthetic:true,approval_state:'confirmed',operation_id:id(n),entity_id:p.id,expected_revision:p.revision-1,action:p.revision===1?'confirm_water':p.removed?'remove_water':'update_water',payload:copy(p)});
let passed=0;function test(name,f){f();passed++;console.log('ok '+name);}
test('schema adds only independent water table preserving all 36',()=>{assert.equal(Object.keys(target.tables).length,37);for(const [name,table]of Object.entries(health.tables))assert.deepEqual(target.tables[name],table);const client=JSON.parse(fs.readFileSync(__dirname+'/../Core/Sources/PHHHubCore/Resources/hydration-p8-schema.json','utf8'));assert.deepEqual(target.tables.WaterIntakes,client.tables.WaterIntakes);});
test('typed water commits and replays original receipt without food or summary',()=>{const s=fresh(),o=op(),receipt=app(s,o);assert.equal(receipt.status,'committed');assert.deepEqual(app(s,o),receipt);assert.equal(s.tables.WaterIntakes.size,1);assert.equal(s.get('WaterIntakes',id(1)).amount_ml,250);assert.equal(s.tables.Meals.size,0);assert.equal(s.tables.DailySummary.size,0);assert.equal(s.get('RecordIndex',id(1)).table_name,'WaterIntakes');assert.equal([...s.tables.OperationEntities.values()][0].table_name,'WaterIntakes');const d=ctx.hubChanges_(s,{schema_version:1,environment:'PHH_TEST',synthetic:true,after:0,limit:100,generation:1});assert.equal(d.hydration_contract,1);assert.equal(d.changes.length,1);assert.equal(d.changes[0].record.amount_ml,250);});
test('edit date move cancel and restore keep same ID monotonic revision',()=>{const s=fresh();app(s,op());const p=water(2);p.amountML=500;p.date='2026-10-02';assert.equal(app(s,op(p,101)).status,'committed');p.revision=3;p.removed=true;assert.equal(app(s,op(p,102)).status,'committed');assert.equal(s.get('WaterIntakes',id(1)).status,'removed');p.revision=4;p.removed=false;assert.equal(app(s,op(p,103)).status,'committed');assert.equal(s.get('WaterIntakes',id(1)).revision,4);assert.equal(s.get('RecordIndex',id(1)).local_date,p.date);});
test('invalid amounts unknown payload and stale revisions preserve last value',()=>{const s=fresh();app(s,op());const original=copy(s.get('WaterIntakes',id(1)));for(const [i,amount]of [0,-1,Infinity,NaN].entries()){const p=water(2);p.amountML=amount;assert.equal(app(s,op(p,200+i)).status,'rejected');}const p=water(2);p.kcal=100;assert.equal(app(s,op(p,204)).status,'rejected');assert.equal(app(s,op(water(),205)).error_code,'REVISION_CONFLICT');assert.deepEqual(s.get('WaterIntakes',id(1)),original);});
test('operation reuse and failed transaction cannot create partial water',()=>{const s=fresh(),o=op();ctx.hubApplyApp_(s,o,now);s.fail=true;assert.throws(()=>s.commit(),/STORAGE_UNAVAILABLE/);assert.equal(s.tables.WaterIntakes.size,0);assert.equal(s.tables.Operations.size,0);s.fail=false;app(s,o);const changed=copy(o);changed.payload.amountML=500;assert.throws(()=>app(s,changed),/OPERATION_ID_REUSED/);assert.equal(s.get('WaterIntakes',id(1)).amount_ml,250);});
test('real data gate and synthetic marker are separate',()=>{const s=fresh(),o=op();o.synthetic=false;assert.throws(()=>app(s,o),/REAL_DATA_DISABLED/);s.config.real_data_enabled=true;assert.equal(app(s,o).status,'committed');});
test('37 table backup restoration and old36 upgrade preserve water and original bundles',()=>{
 const server=require('./health-storage-p6-test.cjs'),hh=server.harness(target);vm.runInContext(fs.readFileSync(__dirname+'/HydrationP8.gs','utf8'),hh.ctx);
 const s=hh.fresh();hh.app(s,op());const tables=server.book(s,hh),bundle=copy(hh.ctx.hubBackupCreate_(tables,server.meta(s,hh)));
 const complete=copy(hh.ctx.hubHealthBackupAttach_(bundle,tables,()=>{throw Error('no health files')}));
 assert.deepEqual(copy(hh.ctx.hubBackupVerify_(complete.manifest,complete.objects)),tables);
 const restore=copy(hh.ctx.hubBackupRestorePlan_(complete.manifest,complete.objects,now));assert.equal(restore.tables.WaterIntakes[0].amount_ml,250);assert.equal(restore.generation,2);
 const bad=copy(tables);bad.WaterIntakes[0].amount_ml=0;assert.throws(()=>hh.ctx.hubBackupCreate_(bad,server.meta(s,hh)),/INVALID_VALUE/);
 const old=server.harness(health),os=old.fresh(),oldTables=server.book(os,old),original=copy(oldTables),oldBundle=copy(old.ctx.hubHealthBackupAttach_(old.ctx.hubBackupCreate_(oldTables,server.meta(os,old)),oldTables,()=>{}));
 const upgraded=copy(hh.ctx.hubBackupVerify_(oldBundle.manifest,oldBundle.objects));assert.deepEqual(upgraded.WaterIntakes,[]);for(const [t,rows]of Object.entries(original))assert.deepEqual(upgraded[t],rows);assert.deepEqual(oldTables,original);
});
test('schema upgrade recognizes36 and adds water header without touching existing cells',()=>{
 const baseSchema=JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8')),res=__dirname+'/../Core/Sources/PHHHubCore/Resources/';
 const named={HUB_BASE_SCHEMA_:baseSchema,HUB_P3_SCHEMA_:JSON.parse(fs.readFileSync(res+'training-p3-schema.json','utf8')),HUB_P4_SCHEMA_:JSON.parse(fs.readFileSync(res+'food-p4-schema.json','utf8')),HUB_P5_SCHEMA_:JSON.parse(fs.readFileSync(res+'planning-p5-schema.json','utf8')),HUB_HEALTH_SCHEMA_:health};
 vm.runInContext(Object.entries(named).map(([n,v])=>'const '+n+'='+JSON.stringify(v)+';').join('\n')+fs.readFileSync(__dirname+'/SchemaUpgradeP7.gs','utf8'),ctx);
 const inventory=Object.entries(health.tables).map(([name,t],i)=>({name,sheet_id:i+1,grid_columns:t.columns.length,columns:t.columns.map(c=>c.name)}));
 const plan=copy(ctx.hubSchemaPlanP7_(inventory));assert.equal(plan.source_tables,36);assert.deepEqual(plan.added_tables,['WaterIntakes']);assert.deepEqual(plan.added_columns,{});assert.equal(plan.requests.length,2);assert.ok(plan.requests.every(r=>r.addSheet || r.updateCells.start.rowIndex===0));
});
console.log(`hydration P8: ${passed} passed`);
module.exports={ctx,copy,fresh,app,water,op,id,now,target};
