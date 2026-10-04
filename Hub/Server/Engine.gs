function hubCommon_(r,op,now) { return {id:r.id,revision:r.revision,status:r.status,created_at:r.created_at || new Date(now).toISOString(),updated_at:new Date(r.last_changed_at || now).toISOString(),source_kind:r.last_source==='app'?'app':'conversation',last_operation_id:op}; }
function hubIndexedPut_(store,table,row,date,key,parent,op,now) {
  const old=store.get(table,row.id); if(old && stable_(old)===stable_(row))return;
  store.put(table,row);store.put('RecordIndex',{id:row.id,table_name:table,sheet_row:store.position(table,row.id),local_date:date || null,lookup_key:key,parent_id:parent || null,revision:row.revision,status:row.status});
  const seq=hubSetting_(store,'next_change',0)+1;hubSet_(store,'next_change',seq,now);
  store.put('SyncChanges',{id:String(seq),change_number:seq,operation_id:op,table_name:table,entity_id:row.id,revision:row.revision,removed:row.status==='removed',local_date:date || null,changed_at:new Date(now).toISOString()});
}
function hubPersistRecord_(store,r,op,now) {
  const c=hubCommon_(r,op,now),ctx=store.config.environment;
  if(typeof hubP3Enabled_==='function' && hubP3Enabled_() && r.type==='session')return hubP3PersistSession_(store,r,op,now);
  if(typeof hubP4Enabled_==='function' && hubP4Enabled_() && r.food_record)return hubP4PersistMeal_(store,r,op,now);
  if(r.type==='meal') {
    const root={...c,local_date:r.date,time_zone:'Asia/Tokyo',slot:r.slot,number:r.no,confirmed_at:c.created_at,last_app_edit_at:r.last_app_edit_at ?? null};
    hubIndexedPut_(store,'Meals',root,r.date,'meal|'+[r.date,r.slot,r.name,r.no].join('|'),null,op,now);
    const itemId=hubId_(ctx+'|item|'+r.id),item={...c,id:itemId,meal_id:r.id,name:r.name,quantity:r.quantity,unit:r.unit,source:r.source,reference_version:null,source_note:null};
    hubIndexedPut_(store,'MealItems',item,r.date,'item|'+r.id,r.id,op,now);
    for(const k of ['kcal','protein_g','fat_g','carbohydrate_g']) {const v=r[k] ?? null;const n={...c,id:hubId_(ctx+'|nutrient|'+r.id+'|'+k),item_id:itemId,nutrient_id:k,unit:k==='kcal'?'kcal':'g',value:v,value_status:v===null?'unknown':r.source==='推定'?'estimated':r.source==='商品表示'?'label':'reference'};hubIndexedPut_(store,'IntakeNutrients',n,r.date,'nutrient|'+itemId+'|'+k,itemId,op,now);}
  } else {
    const sid=hubId_(ctx+'|session|'+r.date+'|'+r.session),old=store.get('TrainingSessions',sid);
    if(!old) hubIndexedPut_(store,'TrainingSessions',{...c,id:sid,revision:1,status:'active',local_date:r.date,time_zone:'Asia/Tokyo',session:r.session,cycle_id:null,started_at:null,ended_at:null,...(typeof hubP3Enabled_==='function' && hubP3Enabled_()?{lifecycle_state:'in_progress',plan_slot_id:null}:{})},r.date,'session|'+r.date+'|'+r.session,null,op,now);
    const row=r.type==='set'?{...c,session_id:sid,exercise:r.exercise,set_no:r.set_no,weight_kg:r.weight_kg,reps:r.reps,rpe:r.rpe,rir:r.rir,weight_basis:r.weight_basis,occurred_at:null,...(typeof hubP3Enabled_==='function' && hubP3Enabled_()?{equipment_key:r.equipment_key ?? null,variant:r.variant ?? null,max_attempt:r.max_attempt ?? null,successful:r.successful ?? null}:{})}:{...c,session_id:sid,exercise:r.exercise || null,set_no:r.set_no ?? null,category:r.category,speaker:r.speaker,text:r.text};
    hubIndexedPut_(store,r.type==='set'?'TrainingSets':'TrainingNotes',row,r.date,r.type+'|'+[r.date,r.session,r.exercise || '',r.set_no || ''].join('|'),sid,op,now);
  }
}
function hubAggregate_(store,state,date,now) {
  const records=Object.values(state.records).filter(r=>r.date===date && r.status==='active'),meals=records.filter(r=>r.type==='meal');
  const old=store.get('DailySummary',date),summary={id:date,local_date:date,revision:(old?.revision || 0)+1,meal_count:meals.length,training_set_count:records.filter(r=>r.type==='set' && !(typeof hubP3Enabled_==='function' && hubP3Enabled_() && store.get('TrainingSessions',hubP3SessionId_(store,r.date,r.session))?.lifecycle_state==='cancelled')).length,updated_at:new Date(now).toISOString()};
  for(const [key,unknown] of [['kcal','kcal_unknown'],['protein_g','protein_unknown'],['fat_g','fat_unknown'],['carbohydrate_g','carbohydrate_unknown']]) {summary[key]=meals.reduce((sum,r)=>sum+(r[key] ?? 0),0);summary[unknown]=meals.reduce((n,r)=>n+(r.food_record?r[key+'_missing']:(r[key]===null || r[key]===undefined?1:0)),0);}
  store.put('DailySummary',summary);
  const seq=hubSetting_(store,'next_change',0)+1;hubSet_(store,'next_change',seq,now);store.put('SyncChanges',{id:String(seq),change_number:seq,operation_id:records[0]?.last_operation_id || hubId_('summary|'+date+'|'+seq),table_name:'DailySummary',entity_id:date,revision:summary.revision,removed:false,local_date:date,changed_at:new Date(now).toISOString()});
  hubSet_(store,'publish:'+date,true,now);hubSet_(store,'publication_dirty',true,now);
}
function hubOperationResult_(store,id) {const op=store.get('Operations',id); if(!op)return {operation_id:id,status:'not_found',retryable:true};const es=store.find('OperationEntities','operation_id',id);return {environment:store.config.environment,operation_id:id,status:op.status,error_code:op.error_code,entity_ids:es.map(e=>e.entity_id),revisions:es.map(e=>e.revision),committed_at:op.committed_at,change_number:op.change_number,retryable:false};}
function hubSaveOperation_(store,id,hash,actor,action,record,error,now) {
  store.put('Operations',{id,content_hash:hash,actor,action,status:error?'rejected':'committed',error_code:error || null,committed_at:new Date(now).toISOString(),change_number:hubSetting_(store,'next_change',0)});
  if(record)store.put('OperationEntities',{id:hubId_(id+'|'+record.id),operation_id:id,table_name:record.type==='meal'?'Meals':record.type==='set'?'TrainingSets':record.type==='session'?'TrainingSessions':record.type==='cycle'?'TrainingCycles':['FoodVersions','Categories','Presets','GoalRules','DailyGoals','FoodDays','SupplementProducts','SupplementPlans','SupplementDays','HealthBatches','WaterIntakes','CatalogEntries'].includes(record.type)?record.type:'TrainingNotes',entity_id:record.id,revision:record.revision});
  return hubOperationResult_(store,id);
}
function hubValidateMeal_(r) {
  if(r.food_record){hubP4Snapshot_(r);return;}
  intakeDate_(r.date);ensure_(MEAL_SLOTS_.includes(r.slot),'INVALID_SLOT');ensure_(typeof r.name==='string' && r.name.trim().length>0 && r.name.length<1000,'INVALID_NAME');ensure_(typeof r.unit==='string' && r.unit.trim().length>0 && r.unit.length<100,'INVALID_UNIT');
  ensure_(Number.isFinite(r.quantity) && r.quantity>=0.01 && r.quantity<=10000,'INVALID_VALUE');ensure_(MEAL_SOURCES_.includes(r.source),'INVALID_SOURCE');
  for(const k of ['kcal','protein_g','fat_g','carbohydrate_g'])ensure_(r[k]===null || Number.isFinite(r[k]) && r[k]>=0 && r[k]<=10000,'INVALID_VALUE');
}
function hubApplyApp_(store,op,now) {
  if(typeof hubCatalogEntriesEnabled_==='function' && hubCatalogEntriesEnabled_() && op?.action==='save_food_catalog_entry')return hubCatalogEntryApply_(store,op,now);
  if(typeof hubHydrationEnabled_==='function' && hubHydrationEnabled_() && ['confirm_water','update_water','remove_water'].includes(op?.action))return hubHydrationApply_(store,op,now);
  if(typeof hubHealthEnabled_==='function' && hubHealthEnabled_() && op?.action==='save_health_delta')return hubHealthApply_(store,op,now);
  if(typeof hubP5Enabled_==='function' && hubP5Enabled_() && hubP5Actions_(HUB_PLANNING_LAYOUT_)[op?.action])return hubP5Apply_(store,op,now);
  if(typeof hubP4Enabled_==='function' && hubP4Enabled_() && hubP4CatalogTable_(op?.action))return hubP4ApplyCatalog_(store,op,now);
  if(typeof hubP4Enabled_==='function' && hubP4Enabled_() && ['confirm_food_meal','update_food_meal','remove_food_meal'].includes(op?.action))return hubP4ApplyMeal_(store,op,now);
  if(typeof hubP3Enabled_==='function' && hubP3Enabled_() && ['register_training_cycle','update_training_session'].includes(op?.action))return op.action==='register_training_cycle' ? hubP3ApplyCycle_(store,op,now):hubP3ApplySession_(store,op,now);
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');ensure_(['confirm_meal','update_meal','remove_meal'].includes(op.action),'INVALID_ACTION');ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0,'INVALID_REVISION');
  const hash=hubHash_(op),old=store.get('Operations',op.operation_id);
  if(old) {ensure_(old.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  const state=hubEmptyState_(),idx=store.get('RecordIndex',op.entity_id); if(idx?.local_date)hubLoadDate_(store,idx.local_date,state);
  const existing=state.records[op.entity_id];let record,foodChanges=[];
  try {
    ensure_(op.approval_state==='confirmed','CONFIRMATION_REQUIRED');
    if(op.action==='confirm_meal') {
      ensure_(!idx && op.expected_revision===0,'ENTITY_EXISTS');
      const p=op.payload;hubKeys_(p,['local_date','slot','name','quantity','unit','kcal','protein_g','fat_g','carbohydrate_g','source']);
      record={id:op.entity_id,type:'meal',status:'active',date:p.local_date,slot:p.slot,name:p.name,quantity:p.quantity,unit:p.unit,source:p.source || '本人',kcal:p.kcal ?? null,protein_g:p.protein_g ?? null,fat_g:p.fat_g ?? null,carbohydrate_g:p.carbohydrate_g ?? null};hubValidateMeal_(record);hubLoadDate_(store,record.date,state);
      record.no=Math.max(0,...Object.values(state.records).filter(r=>r.type==='meal' && r.status==='active' && r.date===record.date && r.slot===record.slot && r.name===record.name).map(r=>r.no))+1;record.created_at=new Date(now).toISOString();record.revision=1;
    } else {
      ensure_(existing?.type==='meal' && existing.status==='active','NOT_FOUND');ensure_(existing.revision===op.expected_revision,'REVISION_CONFLICT');record=hubClone_(existing);
      if(op.action==='remove_meal') {ensure_(op.payload===null || stable_(op.payload)==='{}','INVALID_DELETE');record.status='removed';}
      else {
        const p=op.payload;hubKeys_(p,['local_date','slot','name','quantity','unit','kcal','protein_g','fat_g','carbohydrate_g','source']);ensure_(Object.keys(p).length>0,'NO_CHANGE');
        if('quantity' in p)for(const k of ['kcal','protein_g','fat_g','carbohydrate_g'])if(!(k in p) && record[k]!==null)record[k]*=p.quantity/record.quantity;
        for(const k of ['slot','name','quantity','unit','kcal','protein_g','fat_g','carbohydrate_g','source'])if(k in p)record[k]=p[k];if('local_date' in p)record.date=p.local_date;hubValidateMeal_(record);hubLoadDate_(store,record.date,state);
        const others=Object.values(state.records).filter(r=>r.id!==record.id && r.type==='meal' && r.status==='active' && r.date===record.date && r.slot===record.slot && r.name===record.name);if(others.some(r=>r.no===record.no))record.no=Math.max(...others.map(r=>r.no))+1;
      }
      record.revision++;
      if(record.food_record)hubP4Reconcile_(record,existing,Object.fromEntries(['kcal','protein_g','fat_g','carbohydrate_g'].filter(k=>op.payload && k in op.payload).map(k=>[k,true])));
    }
    if(typeof hubP5Enabled_==='function' && hubP5Enabled_())foodChanges=hubP5FoodChangePlan_(store,[record.date,existing?.date],op.operation_id,now,'app');
  } catch(e) {return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  record.last_source='app';record.last_app_edit_at=now;record.last_changed_at=now;record.last_intake=null;record.last_operation_id=op.operation_id;
  state.records[record.id]=record;hubPersistRecord_(store,record,op.operation_id,now);if(foodChanges.length)hubP5PersistFoodChanges_(store,foodChanges,op.operation_id,now);
  for(const date of new Set([record.date,existing?.date].filter(Boolean)))hubAggregate_(store,state,date,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,record,null,now);
}
function hubProcessIntakeRow_(store,input,sheetRow,now) {
  const cells=INTAKE_HEADERS_.map((_,i)=>intakeCell_(input[i])),oldScan=store.get('IntakeScans',String(sheetRow));
  if(cells.every(x=>x==='') && !oldScan)return null;cells[3]=intakeNormalizeDate_(cells[3]);
  // 受付番号を消す/変える操作も、同じ物理行の受領済み台帳に照合する。
  const state=hubEmptyState_(),rowKey=oldScan?.intake_id || '#row'+sheetRow,rowPrior=oldScan?hubLoadLedger_(store,rowKey,state,false):null;
  const acceptedRow=!!rowPrior && oldScan.status!=='保留' && rowPrior.status!=='保留';
  const key=acceptedRow?rowKey:cells[0] || rowKey,prior=acceptedRow?rowPrior:hubLoadLedger_(store,key,state,false),hash=hubHash_(cells),firstSeen=prior?.first_seen ?? oldScan?.first_seen ?? now;
  const scan={id:String(sheetRow),sheet_row:sheetRow,intake_id:acceptedRow?oldScan.intake_id:cells[0] || oldScan?.intake_id || '',content_hash:hash,first_seen:firstSeen,checked_at:now,status:'保留',message:'',record_id:null};
  const retirePending=(recordId,operationId)=>{if(rowPrior?.status==='保留' && rowKey!==key){const alias=store.get('IntakeLedger',rowKey);Object.assign(alias,{status:'重複',message:'同じ行の受付番号 '+scan.intake_id+' へ引き継ぎ',record_id:recordId || null,operation_id:operationId || null});store.put('IntakeLedger',alias);}};
  const saveScan=(status,message,recordId)=>{scan.status=status;scan.message=message || '';scan.record_id=recordId || null;store.put('IntakeScans',scan);if(!oldScan || oldScan.content_hash!==hash || oldScan.status!==status){
    hubSet_(store,'publication_dirty',true,now);const days=new Set();
    for(const candidate of [cells[3],acceptedRow?store.get('IntakeLedger',key).original_3:null])try{days.add(intakeDate_(candidate));}catch(_){}
    if(!days.size)days.add(intakeJstDate_(now));for(const day of days)hubSet_(store,'publish:'+day,true,now);
  }};
  if(prior && prior.status!=='保留') {
    if(hubHash_(prior.fp)===hubHash_(stable_(cells))) {const status=prior.sheet_row===sheetRow?prior.status:'重複';retirePending(prior.record_id,prior.operation_id);saveScan(status,status==='重複'?'同じ受付番号・同じ内容の行が既にある':prior.message,prior.record_id);return {status,intake_id:scan.intake_id,duplicate:prior.sheet_row!==sheetRow};}
    const reason=acceptedRow || prior.sheet_row===sheetRow?'ROW_EDITED':'ID_REUSED';
    if(!prior.flagged[hash]) {const rv=intakeReview_(state,scan.intake_id,sheetRow,reason,'',now);store.put('Reviews',{id:rv.review_id,intake_id:rv.intake_id,sheet_row:rv.sheet_row,reason:rv.reason,message:rv.message,created_at:rv.created_at,status:rv.status,resolution:null,notified_at:null,renotified_date:null});const raw=store.get('IntakeLedger',key);raw.flagged_hashes=[raw.flagged_hashes,hash].filter(Boolean).join(';');store.put('IntakeLedger',raw);hubSet_(store,'publication_dirty',true,now);}
    retirePending(prior.record_id,prior.operation_id);saveScan('要確認',INTAKE_REASONS_[reason],prior.record_id);return {status:'要確認',intake_id:scan.intake_id};
  }
  const opId=hubId_(store.config.environment+'|intake|'+key);let applied,foodChanges=[],reason=null,message='',status='保存済み';
  try {
    // 本文が「=」などで始まりSheetsが数式として扱ったセルは、エラー表示の文字列を記録にしない（10/4）。
    intakeCheck_(!cells.some(c=>/^#(ERROR!|NAME\?|VALUE!|REF!|N\/A|DIV\/0!|NUM!)/.test(c)),'INVALID_CONTENT','セルが数式のエラーになっています。先頭の「=」を外すか全角にして書き直してください');
    if(cells[1]==='戻す') {
      const content=intakeContent_(cells[7]),target=content['対象受付番号'],ledger=target && hubLoadLedger_(store,target,state);
      if(ledger?.record_id) {const idx=store.get('RecordIndex',ledger.record_id);if(idx?.local_date)hubLoadDate_(store,idx.local_date,state);}
    } else if(cells[3])hubLoadDate_(store,cells[3],state);
    intakeCheck_([cells[0],cells[1],cells[2],cells[1]==='戻す'?'x':cells[3],cells[1]==='戻す'?'x':cells[4]].every(x=>x!==''),'INCOMPLETE');
    const allowsEmptyContent=cells[1]==='記録' && (cells[2]==='記録日' || cells[2]==='サプリ' && cells[4]==='服用');
    const needsContent=['記録','修正','補足','戻す'].includes(cells[1]) && !allowsEmptyContent;
    intakeCheck_(!needsContent || cells[7]!=='','INCOMPLETE','内容');
    const planning=typeof hubP5Enabled_==='function' && hubP5Enabled_() && ['サプリ','記録日'].includes(cells[2]);
    const candidate=planning?hubP5Intake_(store,cells,opId,now,firstSeen):typeof hubP3Enabled_==='function' && hubP3Enabled_()?hubP3Intake_(store,state,cells,now,firstSeen):intakeApply_(state,cells,now,firstSeen);
    if(!planning){
      const changed=state.records[candidate.record_id];
      if(changed.type==='meal')hubValidateMeal_(changed);
      if(changed.food_record && cells[1]!=='戻す')hubP4Reconcile_(changed,candidate.undo?.before,Object.fromEntries([['kcal','kcal'],['P','protein_g'],['F','fat_g'],['C','carbohydrate_g']].filter(([k])=>k in intakeContent_(cells[7])).map(([,k])=>[k,true])));
      if(changed.type==='meal' && typeof hubP5Enabled_==='function' && hubP5Enabled_()){
        try{foodChanges=hubP5FoodChangePlan_(store,[changed.date,store.get('RecordIndex',changed.id)?.local_date],opId,now,'conversation');}catch(e){intakeFail_('INVALID_VALUE','記録日の状態：'+e.message);}
      }
    }
    applied=candidate;message=applied.summary;
  } catch(e) {
    // 想定外のコードでも、その行だけ要確認にして後ろの行と同期を止めない（10/4）。Googleの一時エラーなどコード形式でないものは再試行に回す。
    let [code,...detail]=String(e.message).split(':');
    if(!(code in INTAKE_REASONS_)) {if(!/^[A-Z][A-Z0-9_]+$/.test(code) || ['BUSY','STORAGE_UNAVAILABLE'].includes(code))throw e;detail=[code,...detail];code='INTERNAL';}
    if(code==='INCOMPLETE' && now-firstSeen<INTAKE_WAIT_MS_) {status='保留';message='書き込みの完了を待っています';}
    else {status='要確認';reason=code;message=(INTAKE_REASONS_[code] || code)+(detail.length?'：'+detail.join(':'):'');store.put('Reviews',{id:hubUUID_(),intake_id:scan.intake_id,sheet_row:sheetRow,reason,message,created_at:now,status:'未対応',resolution:null,notified_at:null,renotified_date:null});}
  }
  if(applied?.planning){
    applied.stage.flush();for(const row of applied.undoRows)store.put('UndoValues',row);
    if(applied.undoLedger)store.put('IntakeLedger',{...applied.undoLedger,undone:true});
    hubSaveOperation_(store,opId,hash,'conversation',cells[1],applied.record,null,now);
  } else if(applied) {
    const record=state.records[applied.record_id];const oldIdx=store.get('RecordIndex',record.id);record.last_operation_id=opId;hubPersistRecord_(store,record,opId,now);if(foodChanges.length)hubP5PersistFoodChanges_(store,foodChanges,opId,now);
    for(const date of new Set([record.date,oldIdx?.local_date].filter(Boolean))) {hubLoadDate_(store,date,state);hubAggregate_(store,state,date,now);}
    if(applied.undo) {
      const before=applied.undo.before || {__absent__:true};for(const [field,v] of Object.entries(before))store.put('UndoValues',{id:hubId_(opId+'|'+field),operation_id:opId,record_id:record.id,field_name:field,value_type:v===null?'null':typeof v,string_value:typeof v==='string'?v:null,number_value:typeof v==='number'?v:null,bool_value:typeof v==='boolean'?v:null});
    }
    if(cells[1]==='戻す') {const target=intakeContent_(cells[7])['対象受付番号'],raw=store.get('IntakeLedger',target);raw.undone=true;store.put('IntakeLedger',raw);}
    hubSaveOperation_(store,opId,hash,'conversation',cells[1],record,null,now);
  } else if(reason)hubSaveOperation_(store,opId,hash,'conversation',cells[1],null,reason,now);
  const ledger={id:key,intake_id:scan.intake_id,sheet_row:sheetRow,content_hash:hash,first_seen:firstSeen,status,message,record_id:applied?.record_id || null,operation_id:status==='保留'?null:opId,undone:false,flagged_hashes:''};cells.forEach((v,i)=>ledger['original_'+i]=v);store.put('IntakeLedger',ledger);
  // 番号が最後に書かれた行の仮台帳を保留のまま残さない。確定操作は新番号の1件だけ。
  retirePending(ledger.record_id,ledger.operation_id);
  saveScan(status,message,applied?.record_id);hubSet_(store,'publication_dirty',true,now);
  return {status,intake_id:scan.intake_id,record_id:applied?.record_id || null,message};
}
function hubChanges_(store,q) {
  hubCheckRequest_(store.config,q);ensure_(Number.isSafeInteger(q.after) && q.after>=0 && Number.isInteger(q.limit) && q.limit>=1 && q.limit<=500,'INVALID_CURSOR');
  const upper=hubSetting_(store,'next_change',0),generation=hubSetting_(store,'generation',1);ensure_(q.generation===generation,'CURSOR_EXPIRED');ensure_(q.after<=upper,'INVALID_CURSOR');ensure_(q.snapshot_revision===undefined || q.snapshot_revision===upper,'SNAPSHOT_CHANGED');
  const changes=store.range('SyncChanges',q.after+2,q.limit);store.prefetch(changes.map(c=>({table:c.table_name,id:c.entity_id})));const records=changes.map(c=>{const r=store.get(c.table_name,c.entity_id);ensure_(r && r.revision>=c.revision,'INDEX_CORRUPT');return {change:{...c,indexed_revision:c.revision,revision:r.revision,removed:r.status==='removed'},record:r};});
  const out={environment:store.config.environment,schema_version:1,generation,snapshot_revision:upper,changes:records,next_cursor:changes.length?changes[changes.length-1].change_number:q.after,has_more:q.after+changes.length<upper};
  if(typeof hubP3Enabled_==='function' && hubP3Enabled_())out.training_contract=1;
  // P4の行別保存/受付/共通Outbox/復元のローカル結合を確認済み。
  if(typeof hubP4Enabled_==='function' && hubP4Enabled_())out.food_contract=1;
  if(typeof hubP5Enabled_==='function' && hubP5Enabled_())out.planning_contract=1;
  if(typeof hubHealthEnabled_==='function' && hubHealthEnabled_())out.health_contract=1;
  if(typeof hubHydrationEnabled_==='function' && hubHydrationEnabled_())out.hydration_contract=1;
  if(typeof hubCatalogEntriesEnabled_==='function' && hubCatalogEntriesEnabled_())out.catalog_entry_contract=1;
  while(Utilities.newBlob(JSON.stringify(out)).getBytes().length>200000 && out.changes.length>1) {out.changes.pop();out.next_cursor=out.changes[out.changes.length-1].change.change_number;out.has_more=true;}
  ensure_(Utilities.newBlob(JSON.stringify(out)).getBytes().length<=200000,'RESPONSE_TOO_LARGE');return out;
}
