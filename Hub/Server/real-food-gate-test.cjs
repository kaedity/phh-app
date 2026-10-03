// 架空fixtureのみ。Google・実食品データ・実設定への接続はありません。
const {ctx,copy,fresh,app,id,food,op,snapshot}=require('./food-storage-p4-test.cjs');
const assert=require('node:assert/strict');
let serial=7000,passed=0;
const version=()=>({id:id(601),foodID:id(600),revision:1,name:'架空食品版',quantity:100,unit:'g',preparation:'未指定',source:'商品表示',nutrients:{kcal:100,protein:10,fat:0,carbohydrate:null}});
const category=()=>({id:id(602),name:'架空カテゴリ',archived:false});
const preset=()=>({id:id(603),revision:1,name:'架空プリセット',categoryID:id(602),components:[{versionID:id(601),factor:1.5}],archived:false});
const request=(action,p,rev=0)=>({schema_version:1,environment:'PHH_TEST',synthetic:false,approval_state:'confirmed',operation_id:id(serial++),entity_id:p.id,expected_revision:rev,action,payload:copy(p)});
const catalogs=()=>[['save_food_version',version()],['save_food_category',category()],['save_food_preset',preset()]].map(([a,p])=>request(a,p));
function test(name,f){f();passed++;console.log('ok '+name);}
test('real food and all catalog actions refuse disabled or merely truthy setting without writes',()=>{
 for(const setting of [false,undefined,1,'true'])for(const o of [{...op(food(),serial++),synthetic:false},...catalogs()]){
  const s=fresh();s.config.real_data_enabled=setting;
  assert.throws(()=>app(s,o),/REAL_DATA_DISABLED/);
  for(const table of ['Meals','FoodVersions','FoodNutrients','Categories','Presets','PresetItems','Operations'])assert.equal(s.tables[table].size,0);
  assert.equal(s.config.real_data_enabled,setting);
 }
});
test('explicit true permits confirmed real catalogs and meal edit cancel restore with unknowns intact',()=>{
 const s=fresh();s.config.real_data_enabled=true;
 for(const o of catalogs())assert.equal(app(s,o).status,'committed');
 const meal=food();meal.items[0].versionID=id(601);meal.presetID=id(603);meal.presetRevision=1;
 const original=copy(meal),first={...op(meal,serial++),synthetic:false};
 assert.equal(app(s,first).status,'committed');assert.deepEqual(app(s,first),app(s,first));
 meal.revision=2;meal.date='2026-10-02';meal.items[0].quantity=2;meal.items[0].nutrients.kcal=200;
 assert.equal(app(s,{...op(meal,serial++),synthetic:false}).status,'committed');
 meal.revision=3;meal.removed=true;assert.equal(app(s,{...op(meal,serial++),synthetic:false}).status,'committed');
 const restore={...original,revision:4};assert.equal(app(s,{...op(restore,serial++),synthetic:false}).status,'committed');
 assert.deepEqual(snapshot(s),restore);assert.equal(snapshot(s).items[1].nutrients.kcal,null);assert.equal(snapshot(s).items[1].nutrients.fat,0);
 assert.equal(s.config.real_data_enabled,true);
});
test('real data still requires explicit confirmation valid revision and immutable food versions',()=>{
 const s=fresh();s.config.real_data_enabled=true;
 for(const o of [{...op(food(),serial++),synthetic:false},...catalogs()]){
  o.approval_state='draft';assert.equal(app(s,o).error_code,'CONFIRMATION_REQUIRED');
 }
 assert.equal(s.tables.Meals.size,0);assert.equal(s.tables.FoodVersions.size,0);
 for(const o of catalogs())assert.equal(app(s,o).status,'committed');
 const first={...op(food(),serial++),synthetic:false};app(s,first);
 assert.equal(app(s,{...op(food(),serial++),synthetic:false}).error_code,'REVISION_CONFLICT');
 assert.equal(app(s,request('save_food_version',{...version(),name:'書換'},1)).error_code,'IMMUTABLE_FOOD_VERSION');
 const changed=copy(first);changed.synthetic=true;assert.throws(()=>app(s,changed),/OPERATION_ID_REUSED/);
 assert.equal(s.tables.FoodVersions.get(id(601)).name,'架空食品版');
});
test('non boolean markers reject even when real data enabled and pure transition also requires config',()=>{
 const s=fresh();s.config.real_data_enabled=true;
 for(const marker of [undefined,null,0,1,'false'])for(const o of [{...op(food(),serial++),synthetic:marker},...catalogs().map(o=>({...o,synthetic:marker}))])assert.throws(()=>app(s,o),/INVALID_OPERATION/);
 const state={environment:'PHH_TEST',records:[],operations:{}},o={...op(food(),serial++),synthetic:false};
 assert.throws(()=>ctx.hubP4Transition_(state,o),/REAL_DATA_DISABLED/);
 assert.throws(()=>ctx.hubP4Transition_(state,o,{real_data_enabled:'true'}),/REAL_DATA_DISABLED/);
 assert.equal(ctx.hubP4Transition_(state,o,{real_data_enabled:true}).receipt.status,'committed');
 assert.deepEqual(state.records,[]);
});
console.log(`real food gate: ${passed} passed`);
