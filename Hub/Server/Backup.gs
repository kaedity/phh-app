// P2-6：分割スナップショット・参照保護・別先復元の純粋処理。
// Googleの採取/保存/削除や本番の接続切替はこのファイルから行わない。
const HUB_BACKUP_P5_TABLES_ = HUB_SCHEMA_.tables.GoalRules ? ['GoalRules','DailyGoals','DailyGoalAdjustments','FoodDays','SupplementProducts','SupplementProductNutrients','SupplementPlans','SupplementDays','SupplementDayNutrients'] : [];
const HUB_BACKUP_HEALTH_TABLES_ = HUB_SCHEMA_.tables.HealthBatches?['HealthBatches','HealthArchives','HealthDaily']:[];
const HUB_BACKUP_TABLES_ = ['Meals','MealItems','IntakeNutrients','TrainingSessions','TrainingSets','TrainingNotes',...(HUB_SCHEMA_.tables.TrainingCycles?['TrainingCycles','TrainingPlanSlots']:[]),...(HUB_SCHEMA_.tables.FoodVersions?['FoodVersions','FoodNutrients','Categories','Presets','PresetItems']:[]),...HUB_BACKUP_P5_TABLES_,...HUB_BACKUP_HEALTH_TABLES_,...(HUB_SCHEMA_.tables.WaterIntakes?['WaterIntakes']:[])];
function hubBackupReader_(tables,environment) {
  const maps={};for(const name of Object.keys(HUB_SCHEMA_.tables))maps[name]=new Map(tables[name].map((r,i)=>[r.id,{row:r,position:i+2}]));
  return {config:{environment,real_data_enabled:false},prefetch:()=>{},get:(t,id)=>maps[t]?.get(id)?.row || null,find:(t,k,v)=>tables[t].filter(r=>r[k]===v),position:(t,id)=>maps[t]?.get(id)?.position};
}
function hubBackupValidate_(tables,meta) {
  ensure_(meta.schema_version===1 && ['PHH_TEST','PHH_PRODUCTION'].includes(meta.environment),'BACKUP_ENVIRONMENT');
  ensure_(Number.isSafeInteger(meta.generation) && meta.generation>0 && Number.isSafeInteger(meta.snapshot_revision) && meta.snapshot_revision>=0,'BACKUP_GENERATION');
  ensure_(stable_(Object.keys(tables).sort())===stable_(Object.keys(HUB_SCHEMA_.tables).sort()),'BACKUP_TABLE_SET');
  for(const [name,spec] of Object.entries(HUB_SCHEMA_.tables)) {
    ensure_(Array.isArray(tables[name]),'BACKUP_ROWS');const ids=new Set(),keys=spec.columns.map(c=>c.name).sort();
    for(const r of tables[name]) {ensure_(r && stable_(Object.keys(r).sort())===stable_(keys) && typeof r.id==='string' && r.id.length>0 && !ids.has(r.id),'BACKUP_DUPLICATE_OR_FIELDS');hubRow_(name,r);ids.add(r.id);}
  }
  const store=hubBackupReader_(tables,meta.environment);hubEnvironment_(store);
  ensure_(hubSetting_(store,'real_data_enabled',true)===false,'BACKUP_REAL_DATA_DISABLED');
  ensure_(hubSetting_(store,'generation')===meta.generation && hubSetting_(store,'next_change')===meta.snapshot_revision,'BACKUP_SETTINGS_MISMATCH');
  const indexed=new Set();
  for(const idx of tables.RecordIndex) {
    ensure_(HUB_BACKUP_TABLES_.includes(idx.table_name),'BACKUP_INDEX_TABLE');const r=store.get(idx.table_name,idx.id);
    ensure_(r && r.revision===idx.revision && r.status===idx.status && store.position(idx.table_name,idx.id)===idx.sheet_row,'BACKUP_INDEX');
    const parent=idx.table_name==='MealItems'?r.meal_id:idx.table_name==='IntakeNutrients'?r.item_id:['TrainingSets','TrainingNotes'].includes(idx.table_name)?r.session_id:idx.table_name==='TrainingPlanSlots'?r.cycle_id:idx.table_name==='FoodNutrients'?r.food_version_id:idx.table_name==='PresetItems'?r.preset_id:['DailyGoalAdjustments','SupplementProductNutrients','SupplementDayNutrients'].includes(idx.table_name)?r.parent_id:null;
    const date=idx.table_name==='MealItems'?store.get('Meals',parent)?.local_date:idx.table_name==='IntakeNutrients'?store.get('Meals',store.get('MealItems',parent)?.meal_id)?.local_date:['TrainingSets','TrainingNotes'].includes(idx.table_name)?store.get('TrainingSessions',parent)?.local_date:idx.table_name==='DailyGoalAdjustments'?store.get('DailyGoals',parent)?.local_date:idx.table_name==='SupplementDayNutrients'?store.get('SupplementDays',parent)?.local_date:(r.local_date ?? null);
    ensure_(idx.parent_id===parent && idx.local_date===date,'BACKUP_INDEX_REFERENCE');indexed.add(idx.table_name+'|'+idx.id);
  }
  for(const t of HUB_BACKUP_TABLES_)for(const r of tables[t]) {
    ensure_((t==='TrainingPlanSlots' ? hubIsId_(r.cycle_id) && Number.isInteger(r.number) && r.number>=1 && r.number<=9 && r.id===r.cycle_id+'#'+r.number : hubIsId_(r.id)) && Number.isSafeInteger(r.revision) && r.revision>0 && ['active','removed'].includes(r.status) && indexed.has(t+'|'+r.id),'BACKUP_RECORD');
    if(t==='WaterIntakes') {hubHydrationValidate_({id:r.id,date:r.local_date,revision:r.revision,amountML:r.amount_ml,removed:r.status==='removed'});ensure_(r.time_zone==='Asia/Tokyo','BACKUP_WATER');}
    if(t==='MealItems') {const p=store.get('Meals',r.meal_id);ensure_(p && (p.status===r.status && p.revision===r.revision || HUB_SCHEMA_.tables.FoodVersions && p.food_name!=null && r.number==null && r.status==='removed' && r.revision<=p.revision),'BACKUP_ORPHAN');}
    if(t==='IntakeNutrients') {const p=store.get('MealItems',r.item_id);ensure_(p && p.status===r.status && p.revision===r.revision,'BACKUP_ORPHAN');ensure_(['kcal','protein_g','fat_g','carbohydrate_g'].includes(r.nutrient_id) && r.unit===(r.nutrient_id==='kcal'?'kcal':'g') && (r.value===null ? r.value_status==='unknown' : Number.isFinite(r.value) && r.value>=0 && r.value<=(HUB_SCHEMA_.tables.FoodVersions?100000:10000) && ['reference','estimated','label'].includes(r.value_status)),'BACKUP_NUTRIENT');}
    if(t==='TrainingSets' || t==='TrainingNotes')ensure_(store.get('TrainingSessions',r.session_id),'BACKUP_ORPHAN');
  }
  if(HUB_SCHEMA_.tables.TrainingCycles) {
    for(const r of tables.TrainingSessions)hubP3ValidateSession_(store,hubP3SessionRecord_(r));
    for(const cycle of tables.TrainingCycles) { const slots=store.find('TrainingPlanSlots','cycle_id',cycle.id).sort((a,b)=>a.number-b.number);ensure_(stable_(slots.map(r=>r.number))===stable_([1,2,3,4,5,6,7,8,9]) && slots.every(r=>['Push','Pull','Leg'].includes(r.kind) && r.label.length>0),'BACKUP_PLAN_SLOTS'); }
    for(const slot of tables.TrainingPlanSlots)ensure_(store.get('TrainingCycles',slot.cycle_id),'BACKUP_ORPHAN');
  }
  if(HUB_SCHEMA_.tables.FoodVersions)hubP4ValidateCatalogRows_(store,tables);
  if(HUB_SCHEMA_.tables.GoalRules)hubP5ReadPlan_(HUB_BACKUP_P5_TABLES_.flatMap(table=>tables[table].map(row=>({table,row}))),HUB_PLANNING_LAYOUT_);
  if(HUB_SCHEMA_.tables.HealthBatches)hubHealthBackupValidate_(tables,meta);
  for(const r of tables.Meals) {if(HUB_SCHEMA_.tables.FoodVersions && r.food_name!=null) {const state=hubEmptyState_();hubLoadDate_(store,r.local_date,state);const meal=hubP4Snapshot_(state.records[r.id]);for(const item of meal.items)ensure_(!item.versionID || store.get('FoodVersions',item.versionID),'BACKUP_FOOD_REFERENCE');if(meal.presetID)ensure_(store.get('Presets',meal.presetID)?.revision>=meal.presetRevision,'BACKUP_FOOD_REFERENCE');continue;}const items=store.find('MealItems','meal_id',r.id);ensure_(items.length===1,'BACKUP_MEAL_ITEMS');const ns=store.find('IntakeNutrients','item_id',items[0].id);ensure_(ns.length===4 && new Set(ns.map(n=>n.nutrient_id)).size===4,'BACKUP_NUTRIENTS');}
  for(const r of tables.OperationEntities) {ensure_(store.get('Operations',r.operation_id)?.status==='committed' && ['Meals','TrainingSets','TrainingNotes',...(HUB_SCHEMA_.tables.TrainingCycles?['TrainingCycles','TrainingSessions']:[]),...(HUB_SCHEMA_.tables.FoodVersions?['FoodVersions','Categories','Presets']:[]),...(HUB_SCHEMA_.tables.GoalRules?['GoalRules','DailyGoals','FoodDays','SupplementProducts','SupplementPlans','SupplementDays']:[]),...(HUB_SCHEMA_.tables.HealthBatches?['HealthBatches']:[]),...(HUB_SCHEMA_.tables.WaterIntakes?['WaterIntakes']:[])].includes(r.table_name) && store.get(r.table_name,r.entity_id)?.revision>=r.revision,'BACKUP_OPERATION_REFERENCE');}
  const changes=tables.SyncChanges.slice().sort((a,b)=>a.change_number-b.change_number);
  ensure_(changes.length===meta.snapshot_revision,'BACKUP_CHANGE_GAP');
  changes.forEach((c,i)=>{const r=store.get(c.table_name,c.entity_id);ensure_(c.id===String(i+1) && c.change_number===i+1 && [...HUB_BACKUP_TABLES_,'DailySummary'].includes(c.table_name) && r && c.revision>0 && c.revision<=r.revision,'BACKUP_CHANGE_GAP');});
  const dates=new Set(tables.RecordIndex.filter(r=>['Meals','MealItems','IntakeNutrients','TrainingSessions','TrainingSets','TrainingNotes'].includes(r.table_name)).map(r=>r.local_date).filter(Boolean));for(const r of tables.DailySummary){ensure_(r.id===r.local_date,'BACKUP_SUMMARY');dates.add(r.local_date);}
  for(const date of dates) {
    intakeDate_(date);const state=hubEmptyState_();hubLoadDate_(store,date,state);const active=Object.values(state.records).filter(r=>r.status==='active'),meals=active.filter(r=>r.type==='meal'),summary=store.get('DailySummary',date);
    ensure_(summary && summary.meal_count===meals.length && summary.training_set_count===active.filter(r=>r.type==='set' && !(typeof hubP3Enabled_==='function' && hubP3Enabled_() && store.get('TrainingSessions',hubP3SessionId_(store,r.date,r.session))?.lifecycle_state==='cancelled')).length,'BACKUP_SUMMARY');
    for(const [k,u] of [['kcal','kcal_unknown'],['protein_g','protein_unknown'],['fat_g','fat_unknown'],['carbohydrate_g','carbohydrate_unknown']]) {
      const sum=meals.reduce((n,r)=>n+(r[k] ?? 0),0);ensure_(Math.abs(sum-summary[k])<=1e-8 && summary[u]===meals.reduce((n,r)=>n+(r.food_record?r[k+'_missing']:(r[k]===null || r[k]===undefined?1:0)),0),'BACKUP_SUMMARY');
    }
    for(const r of meals)hubValidateMeal_(r);
  }
  return store;
}
function hubBackupCreate_(tables,meta,maximumBytes=500000) {
  ensure_(meta.start_revision===meta.end_revision && meta.start_generation===meta.end_generation,'BACKUP_CHANGED');
  ensure_(Number.isSafeInteger(maximumBytes) && maximumBytes>=1000 && maximumBytes<=1000000,'BACKUP_PART_SIZE');
  const manifest={format:'PHH_BACKUP_1',schema_version:1,environment:meta.environment,generation:meta.start_generation,snapshot_revision:meta.start_revision,created_at:new Date(meta.now).toISOString(),complete:true,tables:[]},objects={};
  hubBackupValidate_(tables,manifest);
  for(const [name,rows] of Object.entries(tables)) {
    const parts=[];let text='',count=0;
    const flush=()=>{if(!count)return;const sha256=hubHash_(text),bytes=Utilities.newBlob(text).getBytes().length;objects[sha256]=text;parts.push({sha256,bytes,count});text='';count=0;};
    for(const row of rows) {const line=stable_(row)+'\n';ensure_(Utilities.newBlob(line).getBytes().length<=maximumBytes,'BACKUP_ROW_TOO_LARGE');if(count && Utilities.newBlob(text+line).getBytes().length>maximumBytes)flush();text+=line;count++;}
    flush();manifest.tables.push({name,count:rows.length,parts});
  }
  manifest.sha256=hubHash_(manifest);manifest.id=hubId_(manifest.sha256);return {manifest,objects};
}
function hubBackupVerify_(manifest,objects) {
  ensure_(manifest?.format==='PHH_BACKUP_1' && manifest.complete===true,'BACKUP_INCOMPLETE');const core=hubClone_(manifest);delete core.sha256;delete core.id;
  ensure_(hubHash_(core)===manifest.sha256 && hubId_(manifest.sha256)===manifest.id,'BACKUP_MANIFEST_HASH');const tables={};
  for(const t of manifest.tables) {
    ensure_(!Object.prototype.hasOwnProperty.call(tables,t.name) && Object.prototype.hasOwnProperty.call(HUB_SCHEMA_.tables,t.name) && Number.isSafeInteger(t.count) && t.count>=0 && Array.isArray(t.parts),'BACKUP_TABLE_SET');tables[t.name]=[];
    for(const p of t.parts) {
      const text=objects[p.sha256];ensure_(typeof text==='string' && hubHash_(text)===p.sha256 && Utilities.newBlob(text).getBytes().length===p.bytes && p.bytes<=1000000 && text.endsWith('\n'),'BACKUP_PART_HASH');
      const lines=text.slice(0,-1).split('\n');ensure_(lines.length===p.count,'BACKUP_PART_COUNT');for(const line of lines)tables[t.name].push(JSON.parse(line));
    }
    ensure_(tables[t.name].length===t.count,'BACKUP_PART_COUNT');
  }
  const upgraded=hubBackupUpgradeTables_(tables);hubBackupValidate_(upgraded,manifest);if(HUB_SCHEMA_.tables.HealthBatches)hubHealthBackupVerifyFiles_(manifest,objects,upgraded);return upgraded;
}
// 古い完成世代の元manifest/partsを検証してから、既存の付加移行で読取用の表を作ります。
// 旧世代のファイル・元データ・manifestは変更しません。
function hubBackupUpgradeTables_(tables) {
  const names=s=>Object.keys(s.tables).sort(),same=(a,b)=>stable_(a)===stable_(b);
  if(same(Object.keys(tables).sort(),names(HUB_SCHEMA_)))return tables;
  const schemas={},current=hubClone_(HUB_SCHEMA_);schemas[Object.keys(current.tables).length]=hubClone_(current);
  if(current.tables.WaterIntakes){delete current.tables.WaterIntakes;schemas[36]=hubClone_(current);}
  if(current.tables.HealthBatches){for(const name of ['HealthBatches','HealthArchives','HealthDaily','HealthPreparations'])delete current.tables[name];schemas[32]=hubClone_(current);}
  if(current.tables.GoalRules) {for(const name of HUB_BACKUP_P5_TABLES_)delete current.tables[name];schemas[23]=hubClone_(current);}
  if(current.tables.FoodVersions) {
    for(const name of ['FoodVersions','FoodNutrients','Categories','Presets','PresetItems'])delete current.tables[name];
    current.tables.Meals.columns=current.tables.Meals.columns.filter(c=>!['food_name','food_quantity','food_unit','preset_id','preset_revision'].includes(c.name));
    current.tables.MealItems.columns=current.tables.MealItems.columns.filter(c=>!['preparation','confidence','number'].includes(c.name));schemas[18]=hubClone_(current);
  }
  if(current.tables.TrainingCycles) {
    delete current.tables.TrainingCycles;delete current.tables.TrainingPlanSlots;
    current.tables.TrainingSessions.columns=current.tables.TrainingSessions.columns.filter(c=>!['lifecycle_state','plan_slot_id'].includes(c.name));
    current.tables.TrainingSets.columns=current.tables.TrainingSets.columns.filter(c=>!['equipment_key','variant','max_attempt','successful'].includes(c.name));schemas[16]=hubClone_(current);
  }
  let count=Object.keys(tables).length,schema=schemas[count],out=hubClone_(tables);
  ensure_(schema && same(Object.keys(tables).sort(),names(schema)),'BACKUP_TABLE_SET');
  for(const [name,spec]of Object.entries(schema.tables)) {
    const fields=spec.columns.map(c=>c.name).sort(),ids=new Set();ensure_(Array.isArray(out[name]),'BACKUP_ROWS');
    for(const row of out[name]) {
      ensure_(row && same(Object.keys(row).sort(),fields) && typeof row.id==='string' && row.id.length>0 && !ids.has(row.id),'BACKUP_DUPLICATE_OR_FIELDS');ids.add(row.id);
      for(const c of spec.columns){const v=row[c.name];ensure_(v===null?c.nullable:c.type==='integer'?Number.isSafeInteger(v):c.type==='number'?Number.isFinite(v):typeof v===c.type,'BACKUP_COLUMN_TYPE');}
    }
  }
  const target=Object.keys(HUB_SCHEMA_.tables).length;
  while(count<target) {
    const plan=count===16?hubP3MigrationPlan_(schema,out):count===18?hubP4MigrationPlan_(schema,out):count===23?hubP5MigrationPlan_(schema,out,HUB_PLANNING_LAYOUT_):count===32?hubHealthP6MigrationPlan_(schema,out):count===36 && HUB_SCHEMA_.tables.WaterIntakes?{target_tables:37,schema:HUB_SCHEMA_,books:{...out,WaterIntakes:[]}}:null;
    ensure_(plan && plan.target_tables>count,'BACKUP_TABLE_SET');out=plan.books;schema=plan.schema;count=plan.target_tables;
  }
  ensure_(count===target && same(names(schema),names(HUB_SCHEMA_)),'BACKUP_TABLE_SET');return out;
}
function hubBackupRestorePlan_(manifest,objects,now) {
  const tables=hubBackupVerify_(manifest,objects),store=hubBackupReader_(tables,manifest.environment);const generation=store.get('Settings','generation');generation.number_value++;generation.revision++;generation.updated_at=new Date(now).toISOString();
  // 別の空の復元先で、ヘッダーの次に書く行番号。元の正本には書き込まない。
  for(const idx of tables.RecordIndex)idx.sheet_row=store.position(idx.table_name,idx.id);
  hubBackupValidate_(tables,{...manifest,generation:manifest.generation+1});return {environment:manifest.environment,generation:manifest.generation+1,next_change:manifest.snapshot_revision,tables};
}
function hubBackupRetention_(manifests) {
  const complete=manifests.filter(m=>m.complete===true).slice().sort((a,b)=>Date.parse(b.created_at)-Date.parse(a.created_at)),keep=new Set();
  const dateKey=m=>new Date(Date.parse(m.created_at)+9*3600000).toISOString().slice(0,10);
  const buckets=[{limit:7,key:dateKey},{limit:4,key:m=>{const d=new Date(dateKey(m)+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-((d.getUTCDay()+6)%7));return d.toISOString().slice(0,10);}},{limit:12,key:m=>dateKey(m).slice(0,7)}];
  for(const b of buckets){const seen=new Set();for(const m of complete){const k=b.key(m);if(!seen.has(k) && seen.size<b.limit){seen.add(k);keep.add(m.id);}}}
  // 未完了の採取も参照を保護。保持判定は削除を実行しない。
  const protectedManifests=manifests.filter(m=>keep.has(m.id) || !m.complete),protectedObjects=new Set(protectedManifests.flatMap(m=>[...m.tables.flatMap(t=>t.parts.map(p=>p.sha256)),...(m.health_files || []).map(f=>'gzip:'+f.gzip_sha256)]));
  return {keep:Array.from(keep),retire:complete.filter(m=>!keep.has(m.id)).map(m=>m.id),protected_objects:Array.from(protectedObjects)};
}
