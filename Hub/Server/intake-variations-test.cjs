// ChatGPTの書き方の揺れ（10/4レビュー）と、想定外のエラー行が受付全体を止めないこと。
const fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
const tests=String.raw`
test('units, thousands separators, comma lists, なし and math minus are accepted',()=>{
 const c=ctx.intakeContent_('重量kg=60kg、回数=8回, RPE=なし');assert.equal(c['重量kg'],'60kg');assert.equal(c['回数'],'8回');
 assert.equal(ctx.intakeNumber_(c,'重量kg',{min:0,max:500}),60);assert.equal(ctx.intakeNumber_(c,'回数',{min:0,max:100,int:true}),8);
 assert.equal(ctx.intakeNumber_(c,'RPE',{min:0,max:10}),undefined);assert.equal(ctx.intakeNumber_(c,'RPE',{min:0,max:10,clearable:true}),null);
 assert.equal(ctx.intakeNumber_({kcal:'1,050'},'kcal',{min:0,max:5000}),1050);assert.equal(ctx.intakeNumber_({d:'−5'},'d',{min:-10,max:10}),-5);
 assert.deepEqual(Object.keys(ctx.intakeContent_('kcal=1,050; P=20')),['kcal','P']);
 assert.throws(()=>ctx.intakeNumber_({w:'60ポンド'},'w',{min:0,max:500}),/INVALID_VALUE/);
});
test('session spacing, 1.0 numbers and slash dates are normalized',()=>{
 assert.equal(ctx.intakeSession_('Push 2'),'Push2');assert.equal(ctx.intakeNo_('1.0'),1);assert.throws(()=>ctx.intakeNo_('1.5'),/INVALID_NUMBER_COLUMN/);
 assert.equal(ctx.intakeNormalizeDate_('2026/10/5'),'2026-10-05');assert.equal(ctx.intakeNormalizeDate_('2026-10-05'),'2026-10-05');assert.equal(ctx.intakeNormalizeDate_('10/5'),'10/5');
});
test('a whole session written with units still saves every set',()=>{
 const s=fresh();const r=intake(s,['1004-2025-01','記録','筋トレ','2026/10/04','Push 2','ベンチプレス','1','重量kg=60kg、回数=8回',''],2);
 assert.equal(r.status,'保存済み');const rec=s.tables.TrainingSets.get(r.record_id);assert.equal(rec.weight_kg,60);assert.equal(rec.reps,8);
});
test('an unexpected error on one row becomes a review and later rows still save',()=>{
 const s=fresh(),orig=ctx.hubValidateMeal_;ctx.hubValidateMeal_=()=>{throw Error('CELL_TOO_LARGE');};
 try {const bad=intake(s,['1004-1200-01','記録','食事','2026-10-04','昼食','架空の食事','','量=1; 単位=個; kcal=100',''],2);assert.equal(bad.status,'要確認');} finally {ctx.hubValidateMeal_=orig;}
 const ok=intake(s,['1004-1200-02','記録','食事','2026-10-04','夕食','架空の夕食','','量=1; 単位=個; kcal=200',''],3);assert.equal(ok.status,'保存済み');
 assert.ok([...s.tables.Reviews.values()].some(r=>r.reason==='INTERNAL' && r.message.includes('CELL_TOO_LARGE')));
 ctx.hubValidateMeal_=()=>{throw Error('Exception: Service Spreadsheets timed out');};try {assert.throws(()=>intake(s,['1004-1200-03','記録','食事','2026-10-04','間食','架空','','量=1; 単位=個; kcal=50',''],4),/Service/);} finally {ctx.hubValidateMeal_=orig;}
});
test('formula error text in a cell becomes a review instead of a saved note',()=>{
 const s=fresh();const r=intake(s,['1004-2030-01','補足','筋トレ','2026-10-04','Push','','','分類=備考; 発言者=本人','#ERROR!'],2);assert.equal(r.status,'要確認');
});
console.log('Hub intake variations: '+passed+' PASSED');
`;
vm.runInNewContext(source+tests,{require,console,Buffer,__dirname});
