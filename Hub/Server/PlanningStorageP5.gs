// P5の行ストア結合。まだ対応広告を出さず、5c/5dの結合を待ちます。
function hubP5Enabled_() {return !!HUB_SCHEMA_.tables.GoalRules && typeof HUB_PLANNING_LAYOUT_!=='undefined';}
function hubP5Tables_() {return Object.entries(HUB_PLANNING_LAYOUT_).flatMap(([name,spec])=>[name,...spec.children.map(c=>c.table)]);}
function hubP5RelatedRows_(store,plan) {
  const roots=new Map(),v=plan.model,add=(table,row)=>{if(row)roots.set(table+'|'+row.id,{table,row});};
  const find=(table,field,value)=>{for(const row of store.find(table,field,value))add(table,row);};
  add(plan.table,store.get(plan.table,v.id || plan.rows[0].row.id));
  // 設定の版は同じ商品/予定だけ。日別の本文は指定した1日だけ読みます。
  if(plan.key==='goalRule')find('GoalRules','effective_from',v.effectiveFrom);
  if(plan.key==='dailyGoal'||plan.key==='foodDay')find(plan.table,'local_date',v.date);
  if(plan.key==='product')find('SupplementProducts','product_id',v.productID);
  if(plan.key==='plan'||plan.key==='day')find('SupplementPlans','plan_id',v.planID);
  if(plan.key==='day')for(const row of store.find('SupplementDays','local_date',v.date).filter(r=>r.plan_id===v.planID))add('SupplementDays',row);
  const reference=(table,id)=>{const row=store.get(table,id);ensure_(row,'MISSING_REFERENCE');add(table,row);};
  if(plan.key==='dailyGoal')reference('GoalRules',v.ruleID);
  if(plan.key==='plan')reference('SupplementProducts',v.productVersionID);
  if(plan.key==='day')reference('SupplementPlans',v.planVersionID);
  const seen=new Set();
  while([...roots.keys()].some(k=>!seen.has(k)))for(const [key,{table,row}]of [...roots])if(!seen.has(key)) {
    seen.add(key);
    if(table==='DailyGoals')reference('GoalRules',row.rule_id);
    if(table==='SupplementPlans')reference('SupplementProducts',row.product_version_id);
    if(table==='SupplementDays'){reference('SupplementPlans',row.plan_version_id);reference('SupplementProducts',row.product_version_id);}
  }
  const out=[...roots.values()];
  for(const {table,row}of roots.values())for(const child of HUB_PLANNING_LAYOUT_[table].children)
    out.push(...store.find(child.table,'parent_id',row.id).map(r=>({table:child.table,row:r})));
  return out;
}
function hubP5Apply_(store,op,now) {
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');
  const hash=hubHash_(op),receipt=store.get('Operations',op.operation_id);
  if(receipt){ensure_(receipt.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  let plan,root,rows,foodChanges=[];
  try {
    plan=hubP5RowPlan_(op,now,HUB_PLANNING_LAYOUT_);
    const old=store.get(plan.table,op.entity_id),all=hubP5RelatedRows_(store,plan),records=hubP5ReadPlan_(all,HUB_PLANNING_LAYOUT_);
    const previous=records.find(r=>r.id===op.entity_id && r.key===plan.key)?.model;
    ensure_((old?.revision ?? 0)===op.expected_revision,'REVISION_CONFLICT');
    if(plan.key==='product') {
      ensure_(!old,'IMMUTABLE_PRODUCT_VERSION');
      ensure_(plan.model.revision===Math.max(0,...records.filter(r=>r.key==='product' && r.model.productID===plan.model.productID).map(r=>r.model.revision))+1,'REVISION_CONFLICT');
    }
    if(plan.key==='plan') {
      ensure_(!old,'IMMUTABLE_PLAN_VERSION');
      ensure_(plan.model.revision===Math.max(0,...records.filter(r=>r.key==='plan' && r.model.planID===plan.model.planID).map(r=>r.model.revision))+1,'REVISION_CONFLICT');
    }
    if(plan.key==='dailyGoal') {
      ensure_(!previous || previous.state!=='frozen','FROZEN_DAY');
      ensure_(!previous || previous.date===plan.model.date,'DAY_KEY_IMMUTABLE');
      ensure_(records.some(r=>r.key==='goalRule' && r.id===plan.model.ruleID && r.model.revision>=plan.model.ruleRevision),'MISSING_REFERENCE');
    }
    if(plan.key==='foodDay') {
      ensure_(!previous || previous.date===plan.model.date,'DAY_KEY_IMMUTABLE');
      ensure_(plan.model.foodRevision===(previous?.foodRevision ?? 0),'REVISION_CONFLICT');
      if(plan.model.status==='completed')ensure_(plan.model.completionOperationID===op.operation_id,'INVALID_COMPLETION_OPERATION');
    }
    if(plan.key==='day') {
      const today=new Date(now+9*3600000).toISOString().slice(0,10),v=plan.model;
      ensure_(!previous || previous.planID===v.planID && previous.date===v.date,'DAY_KEY_IMMUTABLE');
      if(previous && (previous.date<today || previous.dailyOverride || previous.state==='confirmed'))
        ensure_(v.productVersionID===previous.productVersionID && v.planVersionID===previous.planVersionID && v.dailyOverride,'PAST_OR_EXPLICIT_SNAPSHOT');
      if(!v.dailyOverride) {
        const latest=records.filter(r=>r.key==='plan' && r.model.planID===v.planID && r.model.effectiveFrom<=v.date).sort((a,b)=>b.model.revision-a.model.revision)[0]?.model;
        const stopped=latest && (!latest.autoCount || latest.effectiveThrough!=null && latest.effectiveThrough<v.date);
        ensure_(v.date<=today && (v.state==='planned' && !stopped || v.state==='excluded' && previous && stopped),'INVALID_AUTO_PLAN');
      }
    }
    rows=plan.rows.map(({table,row})=>({table,row:{...row,created_at:store.get(table,row.id)?.created_at ?? row.created_at}}));
    const keep=new Set(rows.map(r=>r.table+'|'+r.row.id));
    for(const child of HUB_PLANNING_LAYOUT_[plan.table].children) {
      for(const r of store.find(child.table,'parent_id',op.entity_id).filter(r=>!keep.has(child.table+'|'+r.id)))
        rows.push({table:child.table,row:{...r,revision:op.expected_revision+1,status:'removed',number:0,updated_at:new Date(now).toISOString(),last_operation_id:op.operation_id}});
    }
    ensure_(new Set(rows.map(r=>r.row.id)).size===rows.length,'ENTITY_ID_REUSED');
    for(const {table,row}of rows) {
      hubRow_(table,row);const idx=store.get('RecordIndex',row.id);
      ensure_(!idx || idx.table_name===table && (row.parent_id==null || idx.parent_id===row.parent_id),'ENTITY_ID_REUSED');
    }
    const candidate=all.filter(r=>r.table!==plan.table || r.row.id!==op.entity_id)
      .filter(r=>!HUB_PLANNING_LAYOUT_[plan.table].children.some(c=>c.table===r.table && r.row.parent_id===op.entity_id)).concat(rows);
    hubP5ReadPlan_(candidate,HUB_PLANNING_LAYOUT_);root=rows[0].row;
    if(plan.key==='day' && (!previous || previous.amount!==plan.model.amount || (previous.state==='excluded') !== (plan.model.state==='excluded') || previous.productVersionID!==plan.model.productVersionID))foodChanges=hubP5FoodChangePlan_(store,[plan.model.date],op.operation_id,now,'app');
  } catch(e) {return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  for(const {table,row}of rows)hubIndexedPut_(store,table,row,root.local_date ?? null,table+'|'+row.id,row.parent_id ?? null,op.operation_id,now);
  hubP5PersistFoodChanges_(store,foodChanges,op.operation_id,now);
  hubSet_(store,'publication_dirty',true,now);hubSet_(store,'publish:'+(root.local_date ?? intakeJstDate_(now)),true,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{...root,type:plan.table},null,now);
}

// 食事/計上対象の変更と同じatomic書込に日版を含めます。筋トレだけでは更新しません。
function hubP5FoodChangePlan_(store,dates,op,now,source) {
  if(!hubP5Enabled_())return [];
  return [...new Set(dates.filter(Boolean))].map(date=>{
    const matches=store.find('FoodDays','local_date',date);ensure_(matches.length<=1,'DUPLICATE_DAY');
    const old=matches[0],id=old?.id ?? hubId_(store.config.environment+'|food-day|'+date);
    if(old)hubP5ReadPlan_([{table:'FoodDays',row:old}],HUB_PLANNING_LAYOUT_);
    const model={date,revision:(old?.revision ?? 0)+1,foodRevision:(old?.food_revision ?? 0)+1,
      status:old?.day_state==='completed' || old?.day_state==='changed'?'changed':'incomplete',
      completedFoodRevision:old?.completed_food_revision ?? null,completedAt:old?.completed_at ?? null,completionOperationID:old?.completion_operation_id ?? null};
    const plan=hubP5RowPlan_({schema_version:1,environment:store.config.environment,operation_id:op,action:'save_food_day',entity_id:id,expected_revision:model.revision-1,approval_state:'confirmed',synthetic:true,payload:{foodDay:model}},now,HUB_PLANNING_LAYOUT_);
    const row={...plan.rows[0].row,created_at:old?.created_at ?? new Date(now).toISOString(),source_kind:source,last_operation_id:op};
    hubRow_('FoodDays',row);const idx=store.get('RecordIndex',id);ensure_(!idx || idx.table_name==='FoodDays','ENTITY_ID_REUSED');
    return row;
  });
}
function hubP5PersistFoodChanges_(store,rows,op,now) {
  for(const row of rows)hubIndexedPut_(store,'FoodDays',row,row.local_date,'FoodDays|'+row.id,null,op,now);
}
