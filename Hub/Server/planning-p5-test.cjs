const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {ctx,copy,id,now,schema:p4}=require('./food-storage-p4-test.cjs');
vm.runInContext(fs.readFileSync(__dirname+'/PlanningP5.gs','utf8'),ctx);
const resource=__dirname+'/../Core/Sources/PHHHubCore/Resources/',layout=JSON.parse(fs.readFileSync(resource+'planning-p5-layout.json','utf8'));
const p5=copy(ctx.hubP5Schema_(p4,layout));
const base={kcal:2000,protein:100,fat:50,carbohydrate:250};
const nutrients=[{nutrientID:'kcal',value:10,unit:'kcal',source:'商品表示'},{nutrientID:'protein',value:null,unit:'g',source:'商品表示'},{nutrientID:'fat',value:0,unit:'g',source:'商品表示'},{nutrientID:'carbohydrate',value:2,unit:'g',source:'商品表示'},{nutrientID:'vitamin_b12',value:3,unit:'µg',source:'商品表示'}];
const models={goalRule:{id:id(200),revision:1,effectiveFrom:'2026-10-01',phase:'maintaining',base},
 dailyGoal:{date:'2026-10-03',ruleID:id(200),ruleRevision:1,calculationVersion:'fixed-manual-v1',phase:'maintaining',base,manual:[{id:id(210),date:'2026-10-03',reason:'架空手動',delta:{kcal:100,protein:0,fat:0,carbohydrate:0}}],total:{...base,kcal:2100},state:'frozen'},
 foodDay:{date:'2026-10-03',revision:1,foodRevision:0,status:'completed',completedFoodRevision:0,completedAt:1,completionOperationID:id(302)},
 product:{id:id(203),productID:id(220),revision:1,name:'架空サプリ',referenceAmount:1,unit:'粒',nutrients},
 plan:{id:id(204),planID:id(221),revision:1,productVersionID:id(203),dailyAmount:2,effectiveFrom:'2026-10-01',autoCount:true},
 day:{id:id(205),planID:id(221),date:'2026-10-03',planVersionID:id(204),productVersionID:id(203),productName:'架空サプリ',amount:2,unit:'粒',nutrients:nutrients.map(n=>({...n,value:n.value===null?null:n.value*2})),revision:1,state:'planned',dailyOverride:false}};
const actions={goalRule:'save_goal_rule',dailyGoal:'save_daily_goal',foodDay:'save_food_day',product:'save_supplement_product',plan:'save_supplement_plan',day:'save_supplement_day'};
const operations=Object.entries(models).map(([key,v],i)=>({schema_version:1,environment:'PHH_TEST',synthetic:true,approval_state:'confirmed',action:actions[key],operation_id:id(300+i),entity_id:v.id || id(200+i),expected_revision:0,payload:{[key]:copy(v)}}));
const planned=()=>operations.flatMap(o=>copy(ctx.hubP5RowPlan_(o,now,layout)).rows);
let passed=0;const test=(name,f)=>{f();passed++;console.log('ok '+name);};
test('P4 to P5 is additive and matches Swift bundled schema exactly',()=>{
 assert.deepEqual(p5,JSON.parse(fs.readFileSync(resource+'planning-p5-schema.json','utf8')));
 const books=Object.fromEntries(Object.keys(p4.tables).map(t=>[t,[]]));
 books.Meals=[Object.fromEntries(p4.tables.Meals.columns.map(c=>[c.name,c.nullable?null:c.type==='integer'?1:c.name==='id'?id(90):'保全']))];
 const result=copy(ctx.hubP5MigrationPlan_(p4,books,layout));assert.equal(result.source_tables,23);assert.equal(result.target_tables,32);
 for(const t of Object.keys(books))assert.deepEqual(result.books[t],books[t]);assert.deepEqual(result.books.SupplementDays,[]);
});
test('typed roots and nutrient manual child rows reconstruct every model exactly',()=>{
 const rows=planned(),read=copy(ctx.hubP5ReadPlan_(rows,layout));assert.equal(read.length,6);
 for(const r of read){const expected=copy(models[r.key]);if(r.key==='goalRule'||r.key==='plan')expected.effectiveThrough=null;assert.deepEqual(r.model,expected);}
 for(const item of rows){const spec=p5.tables[item.table];assert.deepEqual(Object.keys(item.row).sort(),spec.columns.map(c=>c.name).sort());for(const c of spec.columns){const v=item.row[c.name];assert.ok(v===null?c.nullable:c.type==='integer'?Number.isSafeInteger(v):typeof v===c.type);}}
 assert.deepEqual(planned(),rows);assert.equal(rows.find(r=>r.table==='SupplementDayNutrients' && r.row.nutrient_id==='fat').row.value,0);
 assert.equal(rows.find(r=>r.table==='SupplementDayNutrients' && r.row.nutrient_id==='protein').row.value,null);
});
test('unapproved real data unknown fields invalid numeric and dates reject before planning rows',()=>{
 {const o=copy(operations[0]);o.synthetic=false;assert.throws(()=>ctx.hubCheckRequest_({environment:o.environment,real_data_enabled:false},o),/REAL_DATA/);assert.doesNotThrow(()=>ctx.hubCheckRequest_({environment:o.environment,real_data_enabled:true},o));}
 for(const mutate of [o=>o.synthetic='no',o=>o.approval_state='draft',o=>o.payload.goalRule.base.kcal=-1,o=>o.payload.goalRule.effectiveFrom='2026-02-30',o=>o.payload.goalRule.base.hidden=1]){const o=copy(operations[0]);mutate(o);assert.throws(()=>ctx.hubP5RowPlan_(o,now,layout));}
});
test('calculated goal food completion and macro units cannot be forged',()=>{
 let o=copy(operations[1]);o.payload.dailyGoal.total.kcal=999;assert.throws(()=>ctx.hubP5RowPlan_(o,now,layout),/GOAL_TOTAL_MISMATCH/);
 o=copy(operations[2]);o.payload.foodDay.completedFoodRevision=1;assert.throws(()=>ctx.hubP5RowPlan_(o,now,layout),/INVALID_VALUE/);
 o=copy(operations[3]);o.payload.product.nutrients[1].unit='mg';assert.throws(()=>ctx.hubP5RowPlan_(o,now,layout),/INVALID_VALUE/);
});
test('missing or duplicated children ordinals and duplicate completion dates reject',()=>{
 const rows=planned();assert.throws(()=>ctx.hubP5ReadPlan_(rows.filter(r=>r.table!=='SupplementDayNutrients'),layout),/NUTRIENTS_MISSING/);
 const bad=copy(rows),n=bad.find(r=>r.table==='DailyGoalAdjustments');n.row.number=2;assert.throws(()=>ctx.hubP5ReadPlan_(bad,layout),/INVALID_MEMBERSHIP/);
 const duplicate=copy(rows.find(r=>r.table==='FoodDays'));duplicate.row.id=id(998);assert.throws(()=>ctx.hubP5ReadPlan_([...rows,duplicate],layout),/DUPLICATE_DAY/);
});
test('migration malformed sets types and duplicate existing ids never modify input',()=>{
 const books=Object.fromEntries(Object.keys(p4.tables).map(t=>[t,[]]));delete books.Meals;const before=copy(books);assert.throws(()=>ctx.hubP5MigrationPlan_(p4,books,layout),/MIGRATION_TABLE_SET/);assert.deepEqual(books,before);
});
if(process.argv.includes('--fixture')) {
 const rows=planned(),page={schema_version:1,environment:'PHH_PRODUCTION',generation:1,planning_contract:1,food_contract:1,training_contract:1,snapshot_revision:rows.length,next_cursor:rows.length,has_more:false,
 changes:rows.map((r,i)=>({change:{change_number:i+1,table_name:r.table,entity_id:r.row.id,revision:r.row.revision,indexed_revision:r.row.revision,removed:false,local_date:r.row.local_date ?? null},record:r.row}))};
 fs.writeFileSync(__dirname+'/planning-p5-fixture.json',JSON.stringify({page,operations:operations.map(o=>({...o,environment:'PHH_PRODUCTION'}))},null,2)+'\n');
}
console.log(`planning P5: ${passed} passed`);
