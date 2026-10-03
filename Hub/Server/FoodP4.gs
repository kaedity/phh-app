// P4の付加スキーマ・純粋な移行/操作検証。配置・既存APIの切替はP4-6で行います。
function hubP4Schema_(p3) {
  const out=hubClone_(p3),column=(name,type,nullable=false)=>({name,type,nullable}),common=p3.tables.Meals.columns.slice(0,7);
  ensure_(p3.tables.TrainingCycles && !p3.tables.FoodVersions,'P4_SOURCE_SCHEMA');
  out.tables.Meals.columns.push(column('food_name','string',true),column('food_quantity','number',true),column('food_unit','string',true),column('preset_id','string',true),column('preset_revision','integer',true));
  out.tables.MealItems.columns.push(column('preparation','string',true),column('confidence','string',true),column('number','integer',true));
  const table=(columns,indexes=[])=>({primary_key:['id'],indexes:[['id'],...indexes],columns:[...common,...columns]});
  out.tables.FoodVersions=table([column('food_id','string'),column('food_revision','integer'),column('name','string'),column('quantity','number'),column('unit','string'),column('preparation','string'),column('source','string')],[['food_id']]);
  out.tables.FoodNutrients=table([column('food_version_id','string'),column('nutrient_id','string'),column('unit','string'),column('value','number',true)],[['food_version_id']]);
  out.tables.Categories=table([column('name','string')]);
  out.tables.Presets=table([column('name','string'),column('category_id','string',true)]);
  out.tables.PresetItems=table([column('preset_id','string'),column('food_version_id','string'),column('factor','number'),column('number','integer')],[['preset_id']]);
  return out;
}
function hubP4MigrationPlan_(p3,books) {
  ensure_(stable_(Object.keys(books).sort())===stable_(Object.keys(p3.tables).sort()),'MIGRATION_TABLE_SET');
  const target=hubP4Schema_(p3),out=hubClone_(books);
  for(const [table,def] of Object.entries(p3.tables)) {
    ensure_(Array.isArray(out[table]),'MIGRATION_TABLE_MISSING');const ids=new Set();
    for(const row of out[table]) {
      ensure_(typeof row.id==='string' && !ids.has(row.id),'MIGRATION_DUPLICATE_ID');ids.add(row.id);
      ensure_(stable_(Object.keys(row).sort())===stable_(def.columns.map(c=>c.name).sort()),'MIGRATION_COLUMN_SET');
      for(const c of def.columns) {const v=row[c.name];ensure_(v===null ? c.nullable : c.type==='integer' ? Number.isSafeInteger(v) : c.type==='number' ? typeof v==='number' && Number.isFinite(v) : typeof v===c.type,'MIGRATION_COLUMN_TYPE');}
      for(const c of target.tables[table].columns)if(!(c.name in row))row[c.name]=null;
    }
  }
  for(const table of Object.keys(target.tables))if(!(table in out))out[table]=[];
  return {schema:target,books:out,source_tables:18,target_tables:23};
}
function hubP4ValidateMealSnapshot_(meal) {
  hubKeys_(meal,['id','revision','date','slot','items','removed','presetID','presetRevision']);
  ensure_(hubIsId_(meal.id) && Number.isSafeInteger(meal.revision) && meal.revision>0,'INVALID_REVISION');
  intakeDate_(meal.date);ensure_(['朝食','昼食','夕食','間食'].includes(meal.slot) && typeof meal.removed==='boolean','INVALID_VALUE');
  const preset=meal.presetID ?? null,revision=meal.presetRevision ?? null;ensure_((preset===null)===(revision===null) && (preset===null || hubIsId_(preset) && Number.isSafeInteger(revision) && revision>0),'INVALID_PRESET');
  ensure_(Array.isArray(meal.items) && meal.items.length>0 && meal.items.length<=50,'INVALID_ITEMS');const ids=new Set();
  for(const item of meal.items) {
    hubKeys_(item,['id','name','quantity','unit','preparation','source','versionID','confidence','nutrients']);
    ensure_(hubIsId_(item.id) && item.id!==meal.id && !ids.has(item.id),'INVALID_ITEM_ID');ids.add(item.id);
    for(const key of ['name','unit','preparation','source'])ensure_(typeof item[key]==='string' && item[key].trim().length>0 && item[key].length<=200,'INVALID_VALUE');
    ensure_(typeof item.quantity==='number' && Number.isFinite(item.quantity) && item.quantity>0 && item.quantity<=1e6,'INVALID_QUANTITY');
    ensure_(MEAL_SOURCES_.includes(item.source),'INVALID_SOURCE');
    ensure_(item.versionID==null || hubIsId_(item.versionID),'INVALID_REFERENCE');ensure_(item.confidence==null || ['高','中','低'].includes(item.confidence),'INVALID_CONFIDENCE');
    hubKeys_(item.nutrients,['kcal','protein','fat','carbohydrate']);
    for(const k of ['kcal','protein','fat','carbohydrate']) {const v=item.nutrients[k];ensure_(v==null || typeof v==='number' && Number.isFinite(v) && v>=0 && v<=1e5,'INVALID_NUTRIENT');}
  }
}
function hubP4DayTotal_(records,date) {
  const sum={kcal:0,protein:0,fat:0,carbohydrate:0},missing={kcal:0,protein:0,fat:0,carbohydrate:0};
  for(const meal of records.filter(m=>m.date===date && !m.removed))for(const item of meal.items)for(const k of Object.keys(sum)){const v=item.nutrients[k];if(v==null)missing[k]++;else sum[k]+=v;}
  return {known:sum,missing};
}
// ローカル契約の状態遷移。Googleのストア/既存Outboxへは未接続です。
function hubP4CheckData_(config,op) {
  ensure_(typeof op.synthetic==='boolean','INVALID_OPERATION');
  ensure_(op.synthetic || config?.real_data_enabled===true,'REAL_DATA_DISABLED');
}
function hubP4Transition_(state,op,config=null) {
  hubKeys_(op,['schema_version','environment','operation_id','entity_id','expected_revision','action','approval_state','synthetic','payload']);
  ensure_(op.schema_version===1 && ['PHH_TEST','PHH_PRODUCTION'].includes(op.environment) && state.environment===op.environment,'ENVIRONMENT_MISMATCH');
  hubP4CheckData_(config,op);ensure_(op.approval_state==='confirmed','CONFIRMATION_REQUIRED');
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0,'INVALID_REVISION');
  ensure_(Array.isArray(state.records) && state.operations && typeof state.operations==='object','INVALID_STATE');const ids=new Set();for(const meal of state.records){hubP4ValidateMealSnapshot_(meal);ensure_(!ids.has(meal.id),'INVALID_STATE');ids.add(meal.id);}
  const previous=state.operations[op.operation_id],hash=hubHash_(op);if(previous){ensure_(previous.hash===hash,'OPERATION_ID_REUSED');return {state:hubClone_(state),receipt:hubClone_(previous.receipt)};}
  hubP4ValidateMealSnapshot_(op.payload);ensure_(op.entity_id===op.payload.id && op.payload.revision===op.expected_revision+1,'INVALID_REVISION');
  const current=state.records.find(m=>m.id===op.entity_id);ensure_((current?.revision ?? 0)===op.expected_revision,'REVISION_CONFLICT');
  const expectedAction=op.expected_revision===0 ? 'confirm_food_meal':op.payload.removed ? 'remove_food_meal':'update_food_meal';ensure_(op.action===expectedAction && (current || !op.payload.removed),'INVALID_ACTION');
  const next=hubClone_(state);next.records=next.records.filter(m=>m.id!==op.entity_id);next.records.push(hubClone_(op.payload));
  const receipt={schema_version:1,environment:op.environment,operation_id:op.operation_id,status:'committed',entity_ids:[op.entity_id],revisions:[op.payload.revision],error_code:null,retryable:false};
  next.operations[op.operation_id]={hash,receipt};const dates=[...new Set([current?.date,op.payload.date].filter(Boolean))];const totals={};for(const date of dates)totals[date]=hubP4DayTotal_(next.records,date);
  return {state:next,receipt,totals};
}

// P4-5b：保存する行の純粋計画。呼出元が索引・台帳・集計を同じcommitへ加えます。
function hubP4MealRows_(meal,environment,operationId,now,number=1,createdAt=new Date(now).toISOString()) {
  hubP4ValidateMealSnapshot_(meal);
  ensure_(['PHH_TEST','PHH_PRODUCTION'].includes(environment) && hubIsId_(operationId),'ENVIRONMENT_MISMATCH');
  ensure_(Number.isSafeInteger(number) && number>0 && Number.isFinite(now) && Number.isFinite(Date.parse(createdAt)),'INVALID_VALUE');
  const common={revision:meal.revision,status:meal.removed?'removed':'active',created_at:createdAt,updated_at:new Date(now).toISOString(),source_kind:'app',last_operation_id:operationId};
  const rows=[{table:'Meals',record:{...common,id:meal.id,local_date:meal.date,time_zone:'Asia/Tokyo',slot:meal.slot,number,confirmed_at:createdAt,last_app_edit_at:now,food_name:meal.items.length===1?meal.items[0].name:meal.items[0].name+' ほか'+(meal.items.length-1)+'品',food_quantity:meal.items.length===1?meal.items[0].quantity:1,food_unit:meal.items.length===1?meal.items[0].unit:'食',preset_id:meal.presetID ?? null,preset_revision:meal.presetRevision ?? null}}];
  meal.items.forEach((item,i)=>{
    rows.push({table:'MealItems',record:{...common,id:item.id,meal_id:meal.id,name:item.name,quantity:item.quantity,unit:item.unit,source:item.source,reference_version:item.versionID ?? null,source_note:null,preparation:item.preparation,confidence:item.confidence ?? null,number:i+1}});
    for(const [wire,key] of [['kcal','kcal'],['protein','protein_g'],['fat','fat_g'],['carbohydrate','carbohydrate_g']]) {
      const value=item.nutrients[wire] ?? null;
      rows.push({table:'IntakeNutrients',record:{...common,id:hubId_(environment+'|food-nutrient|'+meal.id+'|'+item.id+'|'+key),item_id:item.id,nutrient_id:key,unit:key==='kcal'?'kcal':'g',value,value_status:value===null?'unknown':item.source==='推定'?'estimated':item.source==='商品表示'?'label':'reference'}});
    }
  });
  return {rows,known:hubP4DayTotal_([meal],meal.date).known,missing:hubP4DayTotal_([meal],meal.date).missing};
}
