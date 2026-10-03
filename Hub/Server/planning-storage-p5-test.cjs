const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const resource=__dirname+'/../Core/Sources/PHHHubCore/Resources/',schema=JSON.parse(fs.readFileSync(resource+'planning-p5-schema.json','utf8')),layout=JSON.parse(fs.readFileSync(resource+'planning-p5-layout.json','utf8'));
const prefix=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
const source=prefix.replace("JSON.parse(fs.readFileSync(__dirname+'/schema.json','utf8'))",JSON.stringify(schema)).replace("'Engine.gs','API.gs'","'Engine.gs','API.gs','TrainingP3.gs','FoodP4.gs','FoodStorageP4.gs','PlanningP5.gs','PlanningStorageP5.gs'");
const h={exports:{}};new Function('require','module','__dirname',source+'\nmodule.exports={ctx,copy,fresh,app,intake,meal};')(require,h,__dirname);
const {ctx,copy,fresh,app,intake,meal}=h.exports;vm.runInContext('const HUB_PLANNING_LAYOUT_='+JSON.stringify(layout),ctx);
const fixture=JSON.parse(fs.readFileSync(__dirname+'/planning-p5-fixture.json','utf8')),ops=fixture.operations.map(o=>({...o,environment:'PHH_TEST'}));
const now=Date.parse('2026-10-03T03:00:00Z'),id=n=>`00000000-0000-4000-a000-${String(n).padStart(12,'0')}`;
let sequence=1000;const change=(i,revision,modify)=>{const op=copy(ops[i]);op.operation_id=id(sequence++);op.expected_revision=revision;modify(op);return op;};
const setup=()=>{const s=fresh();for(const o of ops){const r=app(s,o,now);assert.equal(r.status,'committed',o.action+':'+r.error_code);}return s;};
// 証拠の照合は架空MemoryStoreの確定Mapを直接読む。APIにはall()を許可しません。
const data=s=>copy(Object.entries(schema.tables).filter(([table])=>ctx.hubP5Tables_().includes(table)).flatMap(([table])=>[...s.tables[table].values()].map(row=>({table,row}))));
const snapshot=s=>copy(ctx.hubP5ReadPlan_(data(s),layout));
let passed=0;const test=(n,f)=>{f();passed++;console.log('ok '+n);};
test('all six operations commit rows indexes correct receipts and deduplicate exactly',()=>{
 const s=setup(),a=app(s,ops[5],now);assert.deepEqual(app(s,ops[5],now),a);assert.equal(s.tables.Operations.size,6);
 assert.deepEqual([...s.tables.OperationEntities.values()].map(e=>e.table_name),['GoalRules','DailyGoals','FoodDays','SupplementProducts','SupplementPlans','SupplementDays']);
 assert.equal(snapshot(s).length,6);assert.equal(s.tables.SupplementDayNutrients.size,5);
 const delta=copy(ctx.hubChanges_(s,{schema_version:1,environment:'PHH_TEST',synthetic:true,generation:1,after:0,limit:500}));
 assert.equal(delta.changes.length,18);assert.equal(delta.planning_contract,1);
});
test('daily exception keeps root id and micronutrients while stale revisions retain both days',()=>{
 const s=setup(),next=change(5,1,o=>{o.payload.day.revision=2;o.payload.day.amount=3;o.payload.day.state='confirmed';o.payload.day.dailyOverride=true;o.payload.day.nutrients=o.payload.day.nutrients.map(n=>({...n,value:n.value===null?null:n.value*1.5}));});
 assert.equal(app(s,next,now).status,'committed');assert.equal(s.tables.SupplementDays.size,1);
 assert.equal(snapshot(s).find(r=>r.key==='day').model.nutrients[4].value,9);
 const before=data(s);assert.equal(app(s,change(5,0,o=>{}),now).error_code,'REVISION_CONFLICT');assert.deepEqual(data(s),before);
});
test('frozen goals conflicting completion and invalid snapshots reject before any domain write',()=>{
 const s=setup(),before=data(s);
 assert.equal(app(s,change(1,1,o=>{}),now).error_code,'FROZEN_DAY');
 assert.equal(app(s,change(2,1,o=>{o.payload.foodDay.revision=2;o.payload.foodDay.foodRevision=1;o.payload.foodDay.completedFoodRevision=1;o.payload.foodDay.completionOperationID=o.operation_id;}),now).error_code,'REVISION_CONFLICT');
 assert.equal(app(s,change(5,1,o=>{o.payload.day.revision=2;o.payload.day.dailyOverride=true;o.payload.day.nutrients[0].value=999;}),now).error_code,'SUPPLEMENT_SNAPSHOT_MISMATCH');assert.deepEqual(data(s),before);
});
test('product plan revisions retain old day and past planned edits require explicit exception',()=>{
 const s=setup(),before=snapshot(s).find(r=>r.key==='day');
 const p=change(3,0,o=>{o.entity_id=id(900);o.payload.product.id=o.entity_id;o.payload.product.revision=2;o.payload.product.nutrients[0].value=30;});assert.equal(app(s,p,now).status,'committed');
 const plan=change(4,0,o=>{o.entity_id=id(901);o.payload.plan.id=o.entity_id;o.payload.plan.revision=2;o.payload.plan.effectiveFrom='2026-10-04';o.payload.plan.productVersionID=p.entity_id;});assert.equal(app(s,plan,now).status,'committed');
 assert.deepEqual(snapshot(s).find(r=>r.key==='day'),before);
 assert.equal(app(s,change(5,1,o=>{o.payload.day.revision=2;}),now+86400000).error_code,'PAST_OR_EXPLICIT_SNAPSHOT');
});
test('different id same day missing references reused IDs and operation tampering reject',()=>{
 const s=setup(),before=data(s);
 assert.equal(app(s,change(5,0,o=>{o.entity_id=id(902);o.payload.day.id=o.entity_id;}),now).error_code,'DUPLICATE_DAY');
 assert.equal(app(s,change(4,0,o=>{o.entity_id=id(903);o.payload.plan.id=o.entity_id;o.payload.plan.revision=2;o.payload.plan.productVersionID=id(999);}),now).error_code,'MISSING_REFERENCE');
 const forged=copy(ops[3]);forged.payload.product.name='改ざん';assert.throws(()=>app(s,forged,now),/OPERATION_ID_REUSED/);assert.deepEqual(data(s),before);
});
test('failed commit retains complete retryable batch with no partial planning rows',()=>{
 const s=fresh(),o=ops[0];ctx.hubApplyApp_(s,o,now);s.fail=true;assert.throws(()=>s.commit(),/STORAGE_UNAVAILABLE/);
 assert.equal(s.tables.GoalRules.size,0);assert.equal(s.tables.Operations.size,0);s.fail=false;assert.equal(app(s,o,now).status,'committed');assert.equal(s.tables.GoalRules.size,1);
});
const day=(s,date)=>snapshot(s).find(r=>r.key==='foodDay' && r.model.date===date);
const complete=(s,date,time=now)=>{const old=day(s,date),o=copy(ops[2]);o.entity_id=old?.id ?? id(sequence++);o.operation_id=id(sequence++);o.expected_revision=old?.revision ?? 0;o.payload.foodDay={date,revision:o.expected_revision+1,foodRevision:old?.model.foodRevision ?? 0,status:'completed',completedFoodRevision:old?.model.foodRevision ?? 0,completedAt:time/1000-978307200,completionOperationID:o.operation_id};assert.equal(app(s,o,time).status,'committed');return o;};
test('native meal replay move remove invalidate exactly the affected completed days',()=>{
 const s=fresh(),o=meal();assert.equal(app(s,o,now).status,'committed');assert.equal(day(s,'2026-10-01').model.status,'incomplete');complete(s,'2026-10-01');complete(s,'2026-10-02');
 const moved=meal('update_meal',o.entity_id,1,{local_date:'2026-10-02'});assert.equal(app(s,moved,now+1).status,'committed');
 for(const date of ['2026-10-01','2026-10-02'])assert.equal(day(s,date).model.status,'changed');const before=data(s);assert.equal(app(s,moved,now+2).status,'committed');assert.deepEqual(data(s),before);
 complete(s,'2026-10-02',now+3);const oldRev=day(s,'2026-10-01').revision;app(s,meal('remove_meal',o.entity_id,2,null),now+4);assert.equal(day(s,'2026-10-02').model.status,'changed');assert.equal(day(s,'2026-10-01').revision,oldRev);
 const training=['train','記録','筋トレ','2026-10-01','Pull','架空種目','1','重量kg=10; 回数=8',''];assert.equal(intake(s,training,2,now+5).status,'保存済み');assert.equal(day(s,'2026-10-01').revision,oldRev);
});
test('P4 multiple items and B2 edit cancel undo keep completed metadata and invalidate day',()=>{
 const s=fresh(),m={id:id(800),revision:1,date:'2026-10-01',slot:'昼食',items:[{id:id(801),name:'架空A',quantity:1,unit:'個',preparation:'未指定',source:'本人',nutrients:{kcal:100,protein:10,fat:0,carbohydrate:15}}],removed:false};
 const o={...ops[0],action:'confirm_food_meal',operation_id:id(sequence++),entity_id:m.id,expected_revision:0,payload:m};assert.equal(app(s,o,now).status,'committed');const c=complete(s,m.date);
 const row=(key,kind,content='')=>[key,kind,'食事',m.date,'昼食','架空A','1',content,''];assert.equal(intake(s,row('resize','修正','量=2'),2,now+600001).status,'保存済み');
 assert.equal(day(s,m.date).model.status,'changed');assert.equal(day(s,m.date).model.completionOperationID,c.operation_id);assert.equal(s.tables.DailySummary.get(m.date).kcal,200);
 complete(s,m.date,now+600002);assert.equal(intake(s,row('cancel','取消'),3,now+600003).status,'保存済み');assert.equal(day(s,m.date).model.status,'changed');
 complete(s,m.date,now+600004);assert.equal(intake(s,row('undo','戻す','対象受付番号=cancel'),4,now+600005).status,'保存済み');assert.equal(day(s,m.date).model.status,'changed');assert.equal(s.tables.DailySummary.get(m.date).kcal,200);
});
test('confirmation without nutrient change preserves completion but excluding supplement invalidates it',()=>{
 const s=setup();complete(s,'2026-10-03');const before=day(s,'2026-10-03');
 const confirmed=change(5,1,o=>{o.payload.day.revision=2;o.payload.day.state='confirmed';o.payload.day.dailyOverride=true;});assert.equal(app(s,confirmed,now).status,'committed');assert.deepEqual(day(s,'2026-10-03'),before);
 const excluded=change(5,2,o=>{o.payload.day.revision=3;o.payload.day.state='excluded';o.payload.day.dailyOverride=true;});assert.equal(app(s,excluded,now+1).status,'committed');assert.equal(day(s,'2026-10-03').model.status,'changed');
});
console.log(`planning storage P5: ${passed} passed`);
