// P5の局所保存契約。対応広告・API接続は全結合の合格後に行います。
function hubP5Schema_(p4,layout) {
  ensure_(p4.tables.FoodVersions && !p4.tables.GoalRules,'P5_SOURCE_SCHEMA');
  const out=hubClone_(p4),common=p4.tables.Meals.columns.slice(0,7);
  const add=(name,fields,extra=[])=>{out.tables[name]={primary_key:['id'],indexes:[['id'],...(extra.length?[['parent_id']]:[])],columns:[...common,...extra,...fields.map(f=>({name:f.column,type:f.type,nullable:f.nullable}))]};};
  for(const [name,spec]of Object.entries(layout)) {
    add(name,spec.fields);
    for(const child of spec.children)add(child.table,child.fields,[{name:'parent_id',type:'string',nullable:false},{name:'number',type:'integer',nullable:false}]);
  }
  return out;
}
function hubP5MigrationPlan_(p4,books,layout) {
  ensure_(stable_(Object.keys(books).sort())===stable_(Object.keys(p4.tables).sort()),'MIGRATION_TABLE_SET');
  for(const [name,spec]of Object.entries(p4.tables)) {
    const ids=new Set();ensure_(Array.isArray(books[name]),'MIGRATION_TABLE_MISSING');
    for(const row of books[name]) {
      ensure_(typeof row.id==='string' && !ids.has(row.id),'MIGRATION_DUPLICATE_ID');ids.add(row.id);
      ensure_(stable_(Object.keys(row).sort())===stable_(spec.columns.map(c=>c.name).sort()),'MIGRATION_COLUMN_SET');
      for(const c of spec.columns) {const v=row[c.name];ensure_(v===null?c.nullable:c.type==='integer'?Number.isSafeInteger(v):c.type==='number'?Number.isFinite(v):typeof v===c.type,'MIGRATION_COLUMN_TYPE');}
    }
  }
  const schema=hubP5Schema_(p4,layout),out=hubClone_(books);
  for(const name of Object.keys(schema.tables))if(!(name in out))out[name]=[];
  return {schema,books:out,source_tables:Object.keys(p4.tables).length,target_tables:Object.keys(schema.tables).length};
}
function hubP5Actions_(layout) {
  const suffix={goalRule:'goal_rule',dailyGoal:'daily_goal',foodDay:'food_day',product:'supplement_product',plan:'supplement_plan',day:'supplement_day'};
  return Object.fromEntries(Object.entries(layout).map(([table,spec])=>['save_'+suffix[spec.key],{table,spec}]));
}
function hubP5Field_(object,path) {return path.split('.').reduce((v,k)=>v?.[k],object) ?? null;}
function hubP5Text_(v,max=200) {ensure_(typeof v==='string' && v.trim().length>0 && v.length<=max,'INVALID_VALUE');}
function hubP5Amount_(v) {ensure_(Number.isFinite(v) && v>0 && v<=1000000,'INVALID_VALUE');}
function hubP5Values_(v,signed=false) {
  hubKeys_(v,['kcal','protein','fat','carbohydrate']);
  for(const k of ['kcal','protein','fat','carbohydrate']) {
    const n=v[k] ?? null;ensure_(signed?Number.isFinite(n)&&Math.abs(n)<=100000:n===null || Number.isFinite(n)&&n>=0&&n<=100000,'INVALID_VALUE');
  }
}
function hubP5Nutrients_(values) {
  ensure_(Array.isArray(values) && values.length<=200,'INVALID_VALUE');
  const seen=new Set(),units={kcal:'kcal',protein:'g',fat:'g',carbohydrate:'g'};
  for(const n of values) {
    hubKeys_(n,['nutrientID','value','unit','source']);hubP5Text_(n.nutrientID);ensure_(!seen.has(n.nutrientID),'DUPLICATE_NUTRIENT');seen.add(n.nutrientID);
    ensure_(['kcal','g','mg','µg'].includes(n.unit) && (!units[n.nutrientID] || units[n.nutrientID]===n.unit) && MEAL_SOURCES_.includes(n.source),'INVALID_VALUE');
    ensure_(n.value===null || n.value===undefined || Number.isFinite(n.value)&&n.value>=0&&n.value<=100000,'INVALID_VALUE');
  }
  ensure_(Object.keys(units).every(k=>seen.has(k)),'NUTRIENTS_MISSING');
}
function hubP5ValidateModel_(key,v,id,expected) {
  if(key==='goalRule') {
    ensure_(v.id===id && v.revision===expected+1,'REVISION_CONFLICT');
    intakeDate_(v.effectiveFrom);if(v.effectiveThrough!=null){intakeDate_(v.effectiveThrough);ensure_(v.effectiveThrough>=v.effectiveFrom,'INVALID_DATE');}
    ensure_(['gaining','maintaining','cutting'].includes(v.phase),'INVALID_VALUE');hubP5Values_(v.base);ensure_(v.base.kcal!=null,'BASE_NOT_SET');
  } else if(key==='dailyGoal') {
    intakeDate_(v.date);ensure_(hubIsId_(v.ruleID) && Number.isSafeInteger(v.ruleRevision)&&v.ruleRevision>0 && v.calculationVersion==='fixed-manual-v1' && ['gaining','maintaining','cutting'].includes(v.phase) && ['provisional','frozen'].includes(v.state),'INVALID_VALUE');
    hubP5Values_(v.base);hubP5Values_(v.total);ensure_(Array.isArray(v.manual)&&v.manual.length<=200,'INVALID_VALUE');
    const total=hubClone_(v.base),ids=new Set();
    for(const a of v.manual) {
      hubKeys_(a,['id','date','reason','delta']);ensure_(hubIsId_(a.id)&&!ids.has(a.id)&&a.date===v.date,'INVALID_VALUE');ids.add(a.id);hubP5Text_(a.reason);hubP5Values_(a.delta,true);
      for(const k of ['kcal','protein','fat','carbohydrate']) {const b=total[k] ?? null,d=a.delta[k];ensure_(b!==null || d===0,'BASE_NOT_SET');total[k]=b===null?null:b+d;}
      hubP5Values_(total);
    }
    for(const k of ['kcal','protein','fat','carbohydrate'])ensure_((total[k] ?? null)===(v.total[k] ?? null),'GOAL_TOTAL_MISMATCH');
  } else if(key==='foodDay') {
    intakeDate_(v.date);ensure_(v.revision===expected+1 && Number.isSafeInteger(v.foodRevision)&&v.foodRevision>=0 && ['incomplete','completed','changed'].includes(v.status),'INVALID_VALUE');
    if(v.status==='incomplete')ensure_(v.completedAt==null && v.completedFoodRevision==null && v.completionOperationID==null,'INVALID_VALUE');
    else ensure_(Number.isFinite(v.completedAt) && hubIsId_(v.completionOperationID) && Number.isSafeInteger(v.completedFoodRevision)&&v.completedFoodRevision>=0 && (v.status==='completed'?v.completedFoodRevision===v.foodRevision:v.completedFoodRevision<v.foodRevision),'INVALID_VALUE');
  } else if(key==='product') {
    ensure_(v.id===id && expected===0 && hubIsId_(v.productID) && Number.isSafeInteger(v.revision)&&v.revision>0,'IMMUTABLE_PRODUCT_VERSION');hubP5Text_(v.name);hubP5Text_(v.unit);hubP5Amount_(v.referenceAmount);hubP5Nutrients_(v.nutrients);
  } else if(key==='plan') {
    ensure_(v.id===id && expected===0 && hubIsId_(v.planID) && hubIsId_(v.productVersionID) && Number.isSafeInteger(v.revision)&&v.revision>0 && typeof v.autoCount==='boolean','IMMUTABLE_PLAN_VERSION');
    hubP5Amount_(v.dailyAmount);intakeDate_(v.effectiveFrom);if(v.effectiveThrough!=null){intakeDate_(v.effectiveThrough);ensure_(v.effectiveThrough>=v.effectiveFrom,'INVALID_DATE');}
  } else if(key==='day') {
    ensure_(v.id===id && v.revision===expected+1 && [v.planID,v.planVersionID,v.productVersionID].every(hubIsId_) && ['planned','confirmed','excluded'].includes(v.state) && typeof v.dailyOverride==='boolean','INVALID_VALUE');
    intakeDate_(v.date);hubP5Text_(v.productName);hubP5Text_(v.unit);hubP5Amount_(v.amount);hubP5Nutrients_(v.nutrients);
  }
}
function hubP5RowPlan_(op,now,layout) {
  const choice=hubP5Actions_(layout)[op.action];ensure_(choice,'INVALID_ACTION');
  hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(op.schema_version===1 && ['PHH_TEST','PHH_PRODUCTION'].includes(op.environment) && typeof op.synthetic==='boolean' && op.approval_state==='confirmed' && hubIsId_(op.operation_id) && hubIsId_(op.entity_id) && Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0 && op.expected_revision<9007199254740991,'INVALID_OPERATION');
  const {table,spec}=choice;hubKeys_(op.payload,[spec.key]);const v=op.payload[spec.key];
  const allowed=Array.from(new Set(spec.fields.map(f=>f.path.split('.')[0]).concat(spec.children.map(c=>c.path),spec.model_id?['id']:[])));
  hubKeys_(v,allowed);hubP5ValidateModel_(spec.key,v,op.entity_id,op.expected_revision);
  const common={revision:op.expected_revision+1,status:'active',created_at:new Date(now).toISOString(),updated_at:new Date(now).toISOString(),source_kind:'app',last_operation_id:op.operation_id};
  const row=(name,id,fields,object,extra={})=>{const result={...common,id,...extra};for(const f of fields)result[f.column]=hubP5Field_(object,f.path);return {table:name,row:result};};
  const rows=[row(table,op.entity_id,spec.fields,v)];
  for(const child of spec.children) {
    ensure_(Array.isArray(v[child.path])&&v[child.path].length<=200,'INVALID_VALUE');
    v[child.path].forEach((part,i)=>{hubKeys_(part,Array.from(new Set(child.fields.map(f=>f.path.split('.')[0]).concat(child.model_id?['id']:[]))));rows.push(row(child.table,child.model_id?part.id:hubId_(op.entity_id+'|'+child.table+'|'+part.nutrientID),child.fields,part,{parent_id:op.entity_id,number:i+1}));});
  }
  return {table,key:spec.key,model:hubClone_(v),rows};
}
function hubP5ReadPlan_(rows,layout) {
  const result=[],used=new Set(),byId=new Set();
  const put=(o,path,v)=>{const parts=path.split('.');let target=o;for(const k of parts.slice(0,-1))target=target[k] || (target[k]={});target[parts[parts.length-1]]=v;};
  const object=(r,fields,modelId)=>{const o=modelId?{id:r.id}:{};for(const f of fields)put(o,f.path,r[f.column] ?? null);return o;};
  for(const entry of rows){const k=entry.table+'|'+entry.row.id;ensure_(!byId.has(k),'DUPLICATE_ID');byId.add(k);}
  for(const root of rows.filter(r=>layout[r.table])) {
    const spec=layout[root.table],v=object(root.row,spec.fields,spec.model_id);ensure_(root.row.status==='active','INVALID_STATUS');
    for(const child of spec.children) {
      const all=rows.filter(r=>r.table===child.table && r.row.parent_id===root.row.id),parts=all.filter(r=>r.row.status==='active').sort((a,b)=>a.row.number-b.row.number);
      const retired=all.filter(r=>r.row.status==='removed');ensure_(retired.every(p=>p.row.number===0 && p.row.revision<=root.row.revision),'INVALID_MEMBERSHIP');for(const p of retired)used.add(p.table+'|'+p.row.id);
      ensure_(parts.every((p,i)=>p.row.number===i+1 && p.row.revision===root.row.revision),'INVALID_MEMBERSHIP');
      v[child.path]=parts.map(p=>{used.add(p.table+'|'+p.row.id);return object(p.row,child.fields,child.model_id);});
    }
    hubP5ValidateModel_(spec.key,v,root.row.id,root.row.revision-1);used.add(root.table+'|'+root.row.id);result.push({id:root.row.id,revision:root.row.revision,key:spec.key,model:v});
  }
  ensure_(used.size===rows.length,'ORPHAN_PLANNING_ROW');
  const unique=new Set();for(const r of result){let key;if(r.key==='dailyGoal'||r.key==='foodDay')key=r.key+'|'+r.model.date;if(r.key==='day')key='day|'+r.model.planID+'|'+r.model.date;if(r.key==='goalRule')key='goalRule|'+r.model.effectiveFrom;if(key){ensure_(!unique.has(key),'DUPLICATE_DAY');unique.add(key);}}
  const products=result.filter(r=>r.key==='product').map(r=>r.model),plans=result.filter(r=>r.key==='plan').map(r=>r.model);
  const versions=new Set();for(const p of products){const key=p.productID+'|'+p.revision;ensure_(!versions.has(key),'DUPLICATE_VERSION');versions.add(key);}
  const pv=new Set();for(const p of plans){const key=p.planID+'|'+p.revision;ensure_(!pv.has(key),'DUPLICATE_VERSION');pv.add(key);ensure_(products.some(x=>x.id===p.productVersionID),'MISSING_REFERENCE');}
  for(const p of plans){const older=plans.filter(x=>x.planID===p.planID && x.revision<p.revision);ensure_(older.every(x=>x.effectiveFrom<=p.effectiveFrom),'INVALID_EFFECTIVE_ORDER');}
  for(const day of result.filter(r=>r.key==='day').map(r=>r.model)) {
    const plan=plans.find(p=>p.id===day.planVersionID),product=products.find(p=>p.id===day.productVersionID);
    ensure_(plan && product && plan.planID===day.planID && plan.productVersionID===day.productVersionID && day.date>=plan.effectiveFrom && (plan.effectiveThrough==null || day.date<=plan.effectiveThrough),'MISSING_REFERENCE');
    const factor=day.amount/product.referenceAmount,expected=product.nutrients.map(n=>({...n,value:n.value==null?null:n.value*factor}));
    ensure_(day.productName===product.name && day.unit===product.unit && stable_(day.nutrients)===stable_(expected),'SUPPLEMENT_SNAPSHOT_MISMATCH');
  }
  for(const r of result.filter(r=>r.key==='dailyGoal'))ensure_(result.some(g=>g.key==='goalRule' && g.id===r.model.ruleID && g.model.revision>=r.model.ruleRevision),'MISSING_REFERENCE');
  return result;
}
