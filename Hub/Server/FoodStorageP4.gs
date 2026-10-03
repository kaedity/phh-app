// P4の行別保存。UndoValuesへは明細の各値を型付きの別行として保持します。
function hubP4Enabled_() {return !!HUB_SCHEMA_.tables.FoodVersions;}
const P4_NUTRIENTS_=[['kcal','kcal'],['protein','protein_g'],['fat','fat_g'],['carbohydrate','carbohydrate_g']];
function hubP4Flatten_(r,meal) {
  for(const key of Object.keys(r))if(key.startsWith('food_item_'))delete r[key];
  r.food_record=true;r.food_count=meal.items.length;r.food_preset_id=meal.presetID ?? null;r.food_preset_revision=meal.presetRevision ?? null;r.food_basis_quantity=r.quantity;
  meal.items.forEach((item,i)=>{const prefix='food_item_'+(i+1)+'_';for(const key of ['id','name','quantity','unit','preparation','source','versionID','confidence'])r[prefix+key]=item[key] ?? null;for(const [wire]of P4_NUTRIENTS_)r[prefix+wire]=item.nutrients[wire] ?? null;});
  const totals=hubP4DayTotal_([{...meal,removed:false}],meal.date);
  for(const [wire,key]of P4_NUTRIENTS_){r[key]=totals.known[wire];r[key+'_missing']=totals.missing[wire];}
  return r;
}
function hubP4Snapshot_(r) {
  const items=[];for(let i=1;i<=r.food_count;i++){const prefix='food_item_'+i+'_',item={nutrients:{}};for(const key of ['id','name','quantity','unit','preparation','source','versionID','confidence']){const v=r[prefix+key];if(v!==null && v!==undefined)item[key]=v;}for(const [wire]of P4_NUTRIENTS_)item.nutrients[wire]=r[prefix+wire] ?? null;items.push(item);}
  const meal={id:r.id,revision:r.revision,date:r.date,slot:r.slot,items,removed:r.status==='removed'};if(r.food_preset_id){meal.presetID=r.food_preset_id;meal.presetRevision=r.food_preset_revision;}hubP4ValidateMealSnapshot_(meal);return meal;
}
function hubP4RootRecord_(meal,prior,now) {
  const one=meal.items.length===1,first=meal.items[0];
  const r={id:meal.id,type:'meal',revision:meal.revision,status:meal.removed?'removed':'active',date:meal.date,slot:meal.slot,
    name:one?first.name:first.name+' ほか'+(meal.items.length-1)+'品',quantity:one?first.quantity:1,unit:one?first.unit:'食',source:one?first.source:'本人',
    no:prior?.no ?? 1,created_at:prior?.created_at || new Date(now).toISOString(),last_app_edit_at:now,last_changed_at:now,last_source:'app',last_intake:null};
  return hubP4Flatten_(r,meal);
}
function hubP4ReadMeal_(store,root,base) {
  const all=store.find('MealItems','meal_id',root.id),items=all.filter(r=>r.number!==null && r.number!==undefined).sort((a,b)=>a.number-b.number);
  ensure_(items.length>0 && items.length<=50 && items.every((r,i)=>r.number===i+1 && r.revision===root.revision && r.status===root.status),'P4_ITEM_MEMBERSHIP');
  ensure_(all.filter(r=>!items.some(x=>x.id===r.id)).every(r=>r.status==='removed' && r.revision<=root.revision),'P4_ITEM_MEMBERSHIP');
  const snapshots=items.map(item=>{
    const ns=store.find('IntakeNutrients','item_id',item.id);ensure_(ns.length===4 && new Set(ns.map(n=>n.nutrient_id)).size===4 && ns.every(n=>n.revision===root.revision && n.status===root.status),'P4_NUTRIENT_COUNT');
    const nutrients={};for(const [wire,key]of P4_NUTRIENTS_){const n=ns.find(n=>n.nutrient_id===key);ensure_(n && n.unit===(key==='kcal'?'kcal':'g') && (n.value===null?n.value_status==='unknown':['estimated','label','reference'].includes(n.value_status)),'P4_NUTRIENT_VALUE');nutrients[wire]=n.value;}
    const out={id:item.id,name:item.name,quantity:item.quantity,unit:item.unit,preparation:item.preparation,source:item.source,nutrients};if(item.reference_version)out.versionID=item.reference_version;if(item.confidence)out.confidence=item.confidence;return out;
  });
  Object.assign(base,{slot:root.slot,no:root.number,name:root.food_name,quantity:root.food_quantity,unit:root.food_unit,source:snapshots.length===1?snapshots[0].source:'本人',last_app_edit_at:root.last_app_edit_at});
  return hubP4Flatten_(base,{id:root.id,revision:root.revision,date:root.local_date,slot:root.slot,items:snapshots,removed:root.status==='removed',presetID:root.preset_id,presetRevision:root.preset_revision});
}
function hubP4Reconcile_(r,before,explicit={}) {
  if(!r.food_record)return;
  intakeCheck_(r.food_count===1 || !before || r.unit===before.unit,'INVALID_VALUE','複数食品の単位変更はアプリで食品を指定してください');
  const meal=hubP4Snapshot_(r),factor=r.quantity/r.food_basis_quantity;intakeCheck_(Number.isFinite(factor) && factor>0,'INVALID_VALUE','量');
  for(const item of meal.items){item.quantity*=factor;for(const [wire]of P4_NUTRIENTS_)if(item.nutrients[wire]!==null)item.nutrients[wire]*=factor;}
  const totals=hubP4DayTotal_([{...meal,removed:false}],meal.date);
  for(const [wire,key]of P4_NUTRIENTS_){
    // 共通受付の丸めによる差は補正します。複数明細の合計だけの変更は割り振りが決まらないため要確認へ。
    const desired=r[key],sum=totals.known[wire],rounded=Math.round(sum*10)/10;
    if(meal.items.length===1){if(explicit[key] || desired!==rounded && desired!==sum)meal.items[0].nutrients[wire]=desired;}
    else intakeCheck_(!explicit[key] && (desired===sum || desired===rounded),'INVALID_VALUE','複数食品の成分修正はアプリで食品を指定してください');
  }
  if(meal.items.length===1){meal.items[0].name=r.name;meal.items[0].unit=r.unit;meal.items[0].source=r.source;}
  else if(before && before.source!==r.source)for(const item of meal.items)item.source=r.source;
  try{hubP4ValidateMealSnapshot_(meal);}catch(_){intakeFail_('INVALID_VALUE','食品明細');}
  hubP4Flatten_(r,meal);
}
function hubP4PersistMeal_(store,r,op,now) {
  const meal=hubP4Snapshot_(r),plan=hubP4MealRows_(meal,store.config.environment,op,now,r.no,r.created_at),c=hubCommon_(r,op,now);
  const currentIDs=new Set(meal.items.map(i=>i.id));
  for(const old of store.find('MealItems','meal_id',r.id).filter(x=>!currentIDs.has(x.id))){
    hubIndexedPut_(store,'MealItems',{...old,...c,id:old.id,status:'removed',number:null},r.date,'item|'+r.id,r.id,op,now);
    for(const n of store.find('IntakeNutrients','item_id',old.id))hubIndexedPut_(store,'IntakeNutrients',{...n,...c,id:n.id,status:'removed'},r.date,'nutrient|'+old.id+'|'+n.nutrient_id,old.id,op,now);
  }
  for(const entry of plan.rows){const row={...entry.record,...c,id:entry.record.id};let key,parent=null;
    if(entry.table==='IntakeNutrients'){const previous=store.find('IntakeNutrients','item_id',row.item_id).filter(n=>n.nutrient_id===row.nutrient_id);ensure_(previous.length<=1,'P4_NUTRIENT_COUNT');if(previous[0])row.id=previous[0].id;}
    if(entry.table==='Meals'){Object.assign(row,{last_app_edit_at:r.last_app_edit_at ?? null,food_name:r.name,food_quantity:r.quantity,food_unit:r.unit});key='meal|'+[r.date,r.slot,r.name,r.no].join('|');}
    else if(entry.table==='MealItems'){parent=r.id;key='item|'+r.id;}
    else{parent=row.item_id;key='nutrient|'+parent+'|'+row.nutrient_id;}
    hubIndexedPut_(store,entry.table,row,r.date,key,parent,op,now);
  }
}
function hubP4ApplyMeal_(store,op,now) {
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');const hash=hubHash_(op),old=store.get('Operations',op.operation_id);if(old){ensure_(old.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  const state=hubEmptyState_(),idx=store.get('RecordIndex',op.entity_id);if(idx?.local_date)hubLoadDate_(store,idx.local_date,state);const prior=state.records[op.entity_id];let r,foodChanges=[];
  try{
    ensure_(op.approval_state==='confirmed' && op.synthetic===true,'CONFIRMATION_REQUIRED');hubP4ValidateMealSnapshot_(op.payload);
    ensure_(op.payload.id===op.entity_id && Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0 && op.payload.revision===op.expected_revision+1,'INVALID_REVISION');
    const expected=op.expected_revision===0?'confirm_food_meal':op.payload.removed?'remove_food_meal':'update_food_meal';ensure_(op.action===expected && (prior || !op.payload.removed),'INVALID_ACTION');ensure_((prior?.revision ?? 0)===op.expected_revision && (op.expected_revision===0?!idx:prior?.type==='meal' && prior.status==='active'),'REVISION_CONFLICT');
    for(const item of op.payload.items){const owner=store.get('MealItems',item.id),index=store.get('RecordIndex',item.id);ensure_((!owner || owner.meal_id===op.entity_id) && (!index || index.table_name==='MealItems' && index.parent_id===op.entity_id),'ITEM_ID_REUSED');if(item.versionID)ensure_(store.get('FoodVersions',item.versionID),'MISSING_FOOD_VERSION');}
    if(op.payload.presetID){const p=store.get('Presets',op.payload.presetID);ensure_(p && p.revision>=op.payload.presetRevision,'MISSING_PRESET');}
    r=hubP4RootRecord_(op.payload,prior,now);hubLoadDate_(store,r.date,state);const others=Object.values(state.records).filter(x=>x.id!==r.id && x.type==='meal' && x.status==='active' && x.date===r.date && x.slot===r.slot && x.name===r.name);if(others.some(x=>x.no===r.no))r.no=Math.max(...others.map(x=>x.no))+1;
    if(typeof hubP5Enabled_==='function' && hubP5Enabled_())foodChanges=hubP5FoodChangePlan_(store,[r.date,prior?.date],op.operation_id,now,'app');
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  r.last_operation_id=op.operation_id;state.records[r.id]=r;hubP4PersistMeal_(store,r,op.operation_id,now);if(foodChanges.length)hubP5PersistFoodChanges_(store,foodChanges,op.operation_id,now);for(const date of new Set([r.date,prior?.date].filter(Boolean)))hubAggregate_(store,state,date,now);return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,r,null,now);
}

// カタログの変更は摂取済み明細を変更しません。食品版は追加のみです。
function hubP4CatalogTable_(action) {return {save_food_version:'FoodVersions',save_food_category:'Categories',save_food_preset:'Presets'}[action];}
function hubP4ApplyCatalog_(store,op,now) {
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');const table=hubP4CatalogTable_(op.action);ensure_(table,'INVALID_ACTION');
  const hash=hubHash_(op),receipt=store.get('Operations',op.operation_id);if(receipt){ensure_(receipt.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  const old=store.get(table,op.entity_id);let rows,root;
  try{
    ensure_(op.approval_state==='confirmed' && op.synthetic===true,'CONFIRMATION_REQUIRED');ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0 && (old?.revision ?? 0)===op.expected_revision,'REVISION_CONFLICT');
    const p=op.payload;ensure_(p?.id===op.entity_id,'INVALID_ID');const index=store.get('RecordIndex',p.id);ensure_(!index || index.table_name===table,'ENTITY_ID_REUSED');
    const common={id:p.id,revision:op.expected_revision+1,status:'active',created_at:old?.created_at || new Date(now).toISOString(),updated_at:new Date(now).toISOString(),source_kind:'app',last_operation_id:op.operation_id};
    ensure_(typeof p.name==='string' && p.name.trim().length>0 && p.name.length<=200,'INVALID_VALUE');
    if(table==='FoodVersions'){
      hubKeys_(p,['id','foodID','revision','name','quantity','unit','preparation','source','nutrients']);ensure_(!old && op.expected_revision===0 && hubIsId_(p.foodID),'IMMUTABLE_FOOD_VERSION');
      const versions=store.find('FoodVersions','food_id',p.foodID);ensure_(Number.isSafeInteger(p.revision) && p.revision===Math.max(0,...versions.map(v=>v.food_revision))+1,'REVISION_CONFLICT');
      hubP4ValidateMealSnapshot_({id:hubId_('catalog-validator|'+p.id),revision:1,date:'2000-01-01',slot:'間食',removed:false,items:[{id:p.id,name:p.name,quantity:p.quantity,unit:p.unit,preparation:p.preparation,source:p.source,nutrients:p.nutrients}]});
      root={...common,food_id:p.foodID,food_revision:p.revision,name:p.name,quantity:p.quantity,unit:p.unit,preparation:p.preparation,source:p.source};rows=[{table,row:root}];
      for(const [wire,key]of P4_NUTRIENTS_)rows.push({table:'FoodNutrients',row:{...common,id:hubId_(store.config.environment+'|food-version-nutrient|'+p.id+'|'+key),food_version_id:p.id,nutrient_id:key,unit:key==='kcal'?'kcal':'g',value:p.nutrients[wire] ?? null}});
    }else if(table==='Categories'){
      hubKeys_(p,['id','name','archived']);ensure_(typeof p.archived==='boolean','INVALID_VALUE');root={...common,status:p.archived?'removed':'active',name:p.name};rows=[{table,row:root}];
    }else{
      hubKeys_(p,['id','revision','name','categoryID','components','archived']);ensure_(p.revision===common.revision && typeof p.archived==='boolean','INVALID_REVISION');ensure_(p.categoryID==null || hubIsId_(p.categoryID) && store.get('Categories',p.categoryID),'MISSING_CATEGORY');
      ensure_(Array.isArray(p.components) && p.components.length>0 && p.components.length<=50,'INVALID_ITEMS');const ids=new Set();
      for(const item of p.components){hubKeys_(item,['versionID','factor']);ensure_(hubIsId_(item.versionID) && !ids.has(item.versionID) && store.get('FoodVersions',item.versionID),'MISSING_FOOD_VERSION');ids.add(item.versionID);ensure_(Number.isFinite(item.factor) && item.factor>0 && item.factor<=1e6,'INVALID_QUANTITY');}
      root={...common,status:p.archived?'removed':'active',name:p.name,category_id:p.categoryID ?? null};rows=[{table,row:root}];
      p.components.forEach((item,i)=>rows.push({table:'PresetItems',row:{...common,status:root.status,id:hubId_(store.config.environment+'|preset-item|'+p.id+'|'+item.versionID),preset_id:p.id,food_version_id:item.versionID,factor:item.factor,number:i+1}}));
      const current=new Set(rows.map(r=>r.row.id));for(const item of store.find('PresetItems','preset_id',p.id).filter(i=>!current.has(i.id)))rows.push({table:'PresetItems',row:{...item,...common,id:item.id,status:'removed',number:0}});
    }
    // 全行の型とIDの所有先を先に検証し、失敗したカタログを部分保存しません。
    for(const {table,row}of rows){hubRow_(table,row);const idx=store.get('RecordIndex',row.id);ensure_(!idx || idx.table_name===table,'ENTITY_ID_REUSED');}
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  for(const {table,row}of rows){const parent=table==='FoodNutrients'?row.food_version_id:table==='PresetItems'?row.preset_id:null;hubIndexedPut_(store,table,row,null,table+'|'+row.id,parent,op.operation_id,now);}
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{...root,type:table},null,now);
}

// バックアップの行/参照/明細所属を確認。現在の辞書から過去の栄養を再計算しません。
function hubP4ValidateCatalogRows_(store,tables) {
  for(const r of tables.FoodVersions){
    ensure_(r.status==='active' && r.revision===1 && hubIsId_(r.food_id) && Number.isSafeInteger(r.food_revision) && r.food_revision>0,'BACKUP_FOOD_VERSION');
    const ns=store.find('FoodNutrients','food_version_id',r.id);ensure_(ns.length===4 && new Set(ns.map(n=>n.nutrient_id)).size===4,'BACKUP_FOOD_NUTRIENTS');const nutrients={};
    for(const [wire,key]of P4_NUTRIENTS_){const n=ns.find(n=>n.nutrient_id===key);ensure_(n && n.unit===(key==='kcal'?'kcal':'g') && n.revision===r.revision && n.status===r.status,'BACKUP_FOOD_NUTRIENTS');nutrients[wire]=n.value;}
    hubP4ValidateMealSnapshot_({id:hubId_('catalog-validator|'+r.id),revision:1,date:'2000-01-01',slot:'間食',removed:false,items:[{id:r.id,name:r.name,quantity:r.quantity,unit:r.unit,preparation:r.preparation,source:r.source,nutrients}]});
  }
  ensure_(new Set(tables.FoodVersions.map(v=>v.food_id+'|'+v.food_revision)).size===tables.FoodVersions.length,'BACKUP_FOOD_VERSION');
  for(const n of tables.FoodNutrients)ensure_(store.get('FoodVersions',n.food_version_id),'BACKUP_ORPHAN');
  for(const c of tables.Categories)ensure_(c.name.trim().length>0 && c.name.length<=200,'BACKUP_CATEGORY');
  for(const p of tables.Presets){
    ensure_(p.name.trim().length>0 && p.name.length<=200 && (p.category_id===null || store.get('Categories',p.category_id)),'BACKUP_PRESET');
    const all=store.find('PresetItems','preset_id',p.id),cs=all.filter(c=>c.number>0).sort((a,b)=>a.number-b.number);
    ensure_(cs.length>0 && cs.length<=50 && new Set(cs.map(c=>c.food_version_id)).size===cs.length && cs.every((c,i)=>c.number===i+1 && c.revision===p.revision && c.status===p.status) && all.filter(c=>c.number<=0).every(c=>c.number===0 && c.status==='removed' && c.revision<=p.revision),'BACKUP_PRESET_ITEMS');
  }
  for(const c of tables.PresetItems)ensure_(store.get('Presets',c.preset_id) && store.get('FoodVersions',c.food_version_id) && Number.isFinite(c.factor) && c.factor>0 && c.factor<=1e6,'BACKUP_ORPHAN');
}
