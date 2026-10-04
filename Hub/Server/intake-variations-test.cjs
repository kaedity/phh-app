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
test('blank content waits, completes once and times out after ten minutes',()=>{
 const s=fresh(),row=set('h-empty');row[7]='';assert.equal(intake(s,row,2).status,'保留');assert.equal(s.tables.Reviews.size,0);
 assert.equal(intake(s,set('h-empty'),2,now+1000).status,'保存済み');assert.equal(s.tables.TrainingSets.size,1);assert.equal(s.tables.Operations.size,1);
 const expired=set('h-expired');expired[7]='';assert.equal(intake(s,expired,3).status,'保留');assert.equal(intake(s,expired,3,now+600001).status,'要確認');
 assert.equal([...s.tables.Reviews.values()][0].reason,'INCOMPLETE');
});
test('cancel is valid with blank content',()=>{
 const s=fresh(),first=intake(s,set('c-first'),2),cancel=set('c-cancel');cancel[1]='取消';cancel[7]='';assert.equal(intake(s,cancel,3).status,'保存済み');assert.equal(s.tables.TrainingSets.get(first.record_id).status,'removed');
});
test('empty unseen rows are ignored but cleared accepted rows are reviewed once',()=>{
 const s=fresh(),empty=Array(9).fill('');assert.equal(intake(s,empty,2),null);assert.equal(s.tables.IntakeScans.size,0);
 const first=intake(s,set('clear'),2),original=copy(s.tables.IntakeLedger.get('clear'));
 assert.equal(intake(s,empty,2).status,'要確認');assert.equal(intake(s,empty,2).status,'要確認');assert.equal(s.tables.Reviews.size,1);
 assert.equal(s.tables.TrainingSets.get(first.record_id).reps,8);assert.equal(s.tables.IntakeScans.get('2').intake_id,'clear');
 assert.equal(s.tables.IntakeLedger.get('clear').original_7,original.original_7);assert.equal(s.tables.IntakeLedger.get('clear').status,'保存済み');
});
test('replacing an accepted ID and body cannot append a different record',()=>{
 const s=fresh(),first=intake(s,set('old'),2),replacement=set('new',99);replacement[5]='架空の別種目';
 const r=intake(s,replacement,2);assert.equal(r.status,'要確認');assert.equal(r.intake_id,'old');assert.equal(s.tables.TrainingSets.size,1);assert.equal(s.tables.TrainingSets.get(first.record_id).reps,8);
 assert.equal(s.tables.IntakeLedger.has('new'),false);assert.equal([...s.tables.Reviews.values()][0].reason,'ROW_EDITED');
});
test('delete at tail keeps a bounded audit across several polling runs',()=>{
 const s=fresh();intake(s,set('tail'),50);ctx.hubSet_(s,'next_inbox_row',51,now);ctx.hubSet_(s,'audit_row',2,now);s.commit();
 const touched=[];for(let i=0;i<3;i++){let count=0;ctx.hubPollWork_(s,row=>{count++;touched.push(row);return Array(9).fill('');},1,now+i*1000);s.commit();assert.ok(count<=20);}
 assert.ok(touched.includes(50));assert.equal(s.tables.IntakeScans.get('50').status,'要確認');assert.equal(s.tables.Reviews.size,1);assert.equal(ctx.hubSetting_(s,'inbox_audit_end'),50);
});
test('reader uses empty cells for previously used rows outside shrunken grid',()=>{
 const reads=[],reader=ctx.hubIntakeReader_({getMaxRows:()=>10,getRange:(row)=>{reads.push(row);return {getValues:()=>[set('in-grid')]};}});
 assert.equal(reader(10)[0],'in-grid');assert.deepEqual(copy(reader(50)),Array(9).fill(''));assert.deepEqual(reads,[10]);
});
test('duplicate row clearing is a review without cancelling the original',()=>{
 const s=fresh(),first=intake(s,set('same'),2);assert.equal(intake(s,set('same'),3).status,'重複');assert.equal(intake(s,Array(9).fill(''),3).status,'要確認');
 assert.equal(s.tables.TrainingSets.get(first.record_id).status,'active');assert.equal(s.tables.TrainingSets.size,1);assert.equal([...s.tables.Reviews.values()][0].reason,'ROW_EDITED');
});
test('assigning an ID last retires the temporary pending row without a second save',()=>{
 const s=fresh(),partial=set('');assert.equal(intake(s,partial,2).status,'保留');assert.equal(s.find('IntakeLedger','status','保留').length,1);
 assert.equal(intake(s,set('completed-last'),2,now+1000).status,'保存済み');assert.equal(s.find('IntakeLedger','status','保留').length,0);
 assert.equal(s.tables.IntakeLedger.get('#row2').status,'重複');assert.equal(s.tables.Operations.size,1);assert.equal(s.tables.TrainingSets.size,1);
 assert.equal(intake(s,set('completed-last'),2,now+2000).status,'保存済み');assert.equal(s.tables.Operations.size,1);
});
test('cleared pending row times out once with the original receipt ID',()=>{
 const s=fresh(),partial=set('pending-clear');partial[7]='';intake(s,partial,2);
 const empty=Array(9).fill('');assert.equal(intake(s,empty,2,now+1000).status,'保留');assert.equal(intake(s,empty,2,now+600001).status,'要確認');
 assert.equal(intake(s,empty,2,now+700000).status,'要確認');assert.equal(s.find('IntakeLedger','status','保留').length,0);assert.equal(s.tables.Reviews.size,1);
 assert.equal([...s.tables.Reviews.values()][0].intake_id,'pending-clear');assert.equal(s.tables.IntakeScans.get('2').intake_id,'pending-clear');
});
test('clearing or replacing dates republishes the original receipt day',()=>{
 const s=fresh();intake(s,set('date-clear'),2);ctx.hubSet_(s,'publish:2026-10-01',false,now);s.commit();const replaced=set('date-new');replaced[3]='2027-01-01';
 assert.equal(intake(s,replaced,2,now+1000).status,'要確認');assert.equal(ctx.hubSetting_(s,'publish:2026-10-01'),true);assert.equal(ctx.hubSetting_(s,'publish:2027-01-01'),true);
});
test('new year-qualified receipt IDs coexist with legacy IDs',()=>{
 const s=fresh();assert.equal(intake(s,set('1001-1200-01'),2).status,'保存済み');const next=set('20271001-1200-01');next[3]='2027-10-01';
 assert.equal(intake(s,next,3).status,'保存済み');assert.equal(s.tables.TrainingSets.size,2);assert.equal(s.tables.IntakeLedger.size,2);
});
test('summary still respects the cell limit and points to omitted reviews',()=>{
 const state=ctx.hubEmptyState_();state.reviews=Array.from({length:1000},(_,i)=>({id:'review-'+i,status:'未対応',created_at:i,message:'確認内容'.repeat(100)}));
 const text=ctx.intakeSummaryForHub_(state,'2026-10-01',now);assert.ok(text.length<50000);assert.ok(text.includes('ほか980件'));assert.ok(text.includes('review-999'));assert.ok(!text.includes('要確認 review-0｜'));
});
test('partial resend of a committed receipt retires its temporary hold',()=>{
 const s=fresh();intake(s,set('committed'),2);assert.equal(intake(s,set(''),3).status,'保留');
 assert.equal(intake(s,set('committed'),3,now+1000).status,'重複');assert.equal(s.find('IntakeLedger','status','保留').length,0);
 assert.equal(s.tables.TrainingSets.size,1);assert.equal(s.tables.Operations.size,1);assert.equal(s.tables.Reviews.size,0);
});
console.log('Hub intake variations: '+passed+' PASSED');
`;
vm.runInNewContext(source+tests,{require,console,Buffer,__dirname});
