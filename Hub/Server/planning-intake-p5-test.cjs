const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(__dirname+'/planning-storage-p5-test.cjs','utf8').split('let passed=0;')[0];
const h={exports:{}};new Function('require','module','__dirname',source+'\nmodule.exports={ctx,copy,fresh,app,intake,data,snapshot,ops,now,id};')(require,h,__dirname);
const {ctx,copy,fresh,app,intake,data,snapshot,ops,now,id}=h.exports;vm.runInContext(fs.readFileSync(__dirname+'/PlanningIntakeP5.gs','utf8'),ctx);
const row=(key,kind,slot,content='',date='2026-10-03',name='架空サプリ')=>[key,kind,'サプリ',date,slot,name,'',content,''];
const create=(s,key='plan')=>intake(s,row(key,'記録','予定','基準量=1; 単位=錠; 日量=2; 自動計上=はい; kcal=10; P=なし; F=0; C=1; 成分:ビタミンC=3; 単位:ビタミンC=mg; 根拠=商品表示'),2,now);
const auto=(s,time=now)=>{const r=ctx.hubP5AutoPlan_(s,time);s.commit();return copy(r);};
const day=s=>snapshot(s).find(r=>r.key==='day')?.model;
let passed=0;const test=(name,f)=>{f();passed++;console.log('ok '+name);};
test('B2 settings plain columns immutable versions auto once preserves unknown true zero and micronutrients',()=>{
 const s=fresh();assert.equal(create(s).status,'保存済み');assert.equal(auto(s).planned,1);assert.equal(auto(s).planned,0);
 assert.equal(day(s).state,'planned');assert.equal(day(s).nutrients[0].value,20);assert.equal(day(s).nutrients[1].value,null);assert.equal(day(s).nutrients[2].value,0);assert.equal(day(s).nutrients[4].value,6);
 const before=data(s);assert.equal(create(s).status,'保存済み');assert.deepEqual(data(s),before);
});
test('same planned day manual report exclusion amount exception and undo never adds another day',()=>{
 const s=fresh();create(s);auto(s);assert.equal(intake(s,row('reported','記録','服用'),3,now+1).status,'保存済み');assert.equal(day(s).state,'confirmed');
 assert.equal(intake(s,row('amount','修正','服用','量=3'),4,now+2).status,'保存済み');assert.equal(day(s).amount,3);
 assert.equal(intake(s,row('exclude','取消','服用'),5,now+3).status,'保存済み');assert.equal(day(s).state,'excluded');assert.equal(auto(s).planned,0);
 const undo=row('undo','戻す','','対象受付番号=exclude','','');assert.equal(intake(s,undo,6,now+4).status,'保存済み');assert.equal(day(s).state,'confirmed');assert.equal(day(s).amount,3);assert.equal(s.tables.SupplementDays.size,1);
 assert.equal(intake(s,row('undo-again','戻す','','対象受付番号=exclude','',''),7,now+5).status,'要確認');
});
test('plan revision changes untouched today retains old past day stop and compensated undo',()=>{
 const s=fresh();create(s);auto(s);const oldProduct=day(s).productVersionID;auto(s,now+86400000);const past=copy([...s.tables.SupplementDays.values()].find(r=>r.local_date==='2026-10-03'));
 assert.equal(intake(s,row('new-product','修正','予定','kcal=30','2026-10-04'),3,now+86400000).status,'保存済み');assert.equal(auto(s,now+86400000).planned,1);
 assert.deepEqual([...s.tables.SupplementDays.values()].find(r=>r.local_date==='2026-10-03'),past);const current=snapshot(s).find(r=>r.key==='day'&&r.model.date==='2026-10-04');assert.notEqual(current.model.productVersionID,oldProduct);assert.equal(current.model.nutrients[0].value,60);
 assert.equal(intake(s,row('stop','取消','予定','','2026-10-04'),4,now+86400001).status,'保存済み');assert.equal(auto(s,now+86400001).planned,1);
 assert.equal(intake(s,row('restore','戻す','','対象受付番号=stop','',''),5,now+86400002).status,'保存済み');assert.equal(auto(s,now+86400002).planned,1);assert.equal(s.tables.SupplementPlans.size,4);
});
test('completion materializes current planned intake first and food change requires explicit recompletion',()=>{
 const s=fresh();create(s);const done=key=>[key,'記録','記録日','2026-10-03','食事','記録完了','','',''];
 assert.equal(intake(s,done('done'),3,now).status,'保存済み');assert.equal(day(s).state,'planned');assert.equal(snapshot(s).find(r=>r.key==='foodDay').model.status,'completed');
 assert.equal(intake(s,row('less','修正','服用','量=1'),4,now+1).status,'保存済み');assert.equal(snapshot(s).find(r=>r.key==='foodDay').model.status,'changed');
 assert.equal(intake(s,done('done-again'),5,now+2).status,'保存済み');assert.equal(snapshot(s).find(r=>r.key==='foodDay').model.status,'completed');
 assert.equal(intake(s,['undo-done','戻す','記録日','','','','','対象受付番号=done-again',''],6,now+3).status,'保存済み');assert.equal(snapshot(s).find(r=>r.key==='foodDay').model.status,'changed');
});
test('invalid settings discard staged product rows ambiguous targets and accepted row editing become review',()=>{
 const s=fresh();assert.equal(intake(s,row('bad','記録','予定','基準量=1; 単位=錠; 自動計上=はい; kcal=10'),2,now).status,'要確認');assert.equal(data(s).length,0);
 assert.equal(intake(s,row('units','記録','予定','基準量=1; 単位=錠; 日量=2; 自動計上=はい; 成分:ビタミンC=3'),3,now).status,'要確認');assert.equal(data(s).length,0);
 create(s);auto(s);const before=data(s);assert.equal(intake(s,row('absent','記録','服用','','2026-10-03','存在しない'),4,now).status,'要確認');assert.deepEqual(data(s),before);
 const edited=row('plan','記録','予定','基準量=1; 単位=錠; 日量=99; 自動計上=はい');assert.equal(intake(s,edited,2,now).status,'要確認');assert.deepEqual(data(s),before);
});
test('future plan stays unapplied past manual reports use old product and incomplete input is retained',()=>{
 const s=fresh();const r=row('future','記録','予定','基準量=1; 単位=錠; 日量=2; 自動計上=はい; kcal=10','2026-10-04');assert.equal(intake(s,r,2,now).status,'保存済み');assert.equal(auto(s).planned,0);
 assert.equal(intake(s,['pending','記録','サプリ','','','','','',''],3,now).status,'保留');assert.equal(s.tables.IntakeLedger.get('pending').status,'保留');
 assert.equal(intake(s,row('early','記録','服用'),4,now).status,'要確認');assert.equal(s.tables.SupplementDays.size,0);
});
test('failed common commit leaves settings day ledger and undo absent then retry succeeds',()=>{
 const s=fresh(),r=row('failure','記録','予定','基準量=1; 単位=錠; 日量=2; 自動計上=はい; kcal=10');ctx.hubProcessIntakeRow_(s,r,2,now);s.fail=true;assert.throws(()=>s.commit(),/STORAGE_UNAVAILABLE/);
 for(const table of ['SupplementProducts','SupplementPlans','IntakeLedger','UndoValues','Operations'])assert.equal(s.tables[table].size,0);s.fail=false;assert.equal(intake(s,r,2,now).status,'保存済み');auto(s);assert.equal(s.tables.SupplementDays.size,1);
});
test('bounded poll generates today summary separates planned confirmed excluded and ambiguous plans need ID',()=>{
 const s=fresh();create(s);assert.equal(copy(ctx.hubPollWork_(s,()=>['','','','','','','','',''],1,now)).processed,0);s.commit();assert.equal(day(s).state,'planned');
 const lines=copy(ctx.hubP5SummaryLines_(s,'2026-10-03')).join('\n');assert.match(lines,/服用確認なし/);assert.match(lines,/P不明 F0/);assert.match(lines,/ビタミンC 6 mg/);assert.match(lines,/未完了/);
 const product=copy(ops[3]);product.payload.product.name='架空サプリ';assert.equal(app(s,product,now).status,'committed');assert.equal(app(s,ops[4],now).status,'committed');
 const ambiguous=intake(s,row('ambiguous','記録','服用'),3,now);assert.equal(ambiguous.status,'要確認');assert.match(ambiguous.message,/複数/);
 const planID=day(s).planID;assert.equal(intake(s,row('identified','記録','服用','予定ID='+planID),4,now).status,'保存済み');
 assert.match(copy(ctx.hubP5SummaryLines_(s,'2026-10-03')).join('\n'),/服用確認済み/);
});
test('undo cannot overwrite a later day edit and recent app changes require review',()=>{
 const s=fresh();create(s);auto(s);intake(s,row('first','記録','服用'),3,now);intake(s,row('second','修正','服用','量=3'),4,now+1);
 assert.equal(intake(s,row('stale-undo','戻す','','対象受付番号=first','',''),5,now+2).status,'要確認');assert.equal(day(s).amount,3);
 const model=day(s),o={...ops[5],operation_id:id(9876),entity_id:model.id,expected_revision:model.revision,payload:{day:{...model,revision:model.revision+1,amount:4,nutrients:model.nutrients.map(n=>({...n,value:n.value==null?null:n.value*4/3}))}}};assert.equal(app(s,o,now+3).status,'committed');
 assert.equal(intake(s,row('app-conflict','修正','服用','量=1'),6,now+4).status,'要確認');assert.equal(day(s).amount,4);
});
console.log(`planning intake P5: ${passed} passed`);
module.exports={ctx,copy,fresh,app,intake,data,snapshot,ops,now,id,row,create,auto};
