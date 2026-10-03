// P3先行コード。hub-p3結合時だけ有効。P2の配置/16表スキーマを変更しません。
function hubP3Schema_(baseline) {
  const s=hubClone_(baseline),column=(name,type,nullable=true)=>({name,type,nullable});
  s.tables.TrainingSessions.columns.push(column('lifecycle_state','string'),column('plan_slot_id','string'));
  s.tables.TrainingSets.columns.push(column('equipment_key','string'),column('variant','string'),column('max_attempt','boolean'),column('successful','boolean'));
  const common=baseline.tables.TrainingSessions.columns.slice(0,7);
  s.tables.TrainingCycles={primary_key:['id'],indexes:[['id']],columns:[...common,column('name','string',false),column('source_path','string',false),column('source_sha256','string',false)]};
  s.tables.TrainingPlanSlots={primary_key:['id'],indexes:[['id'],['cycle_id']],columns:[...common,column('cycle_id','string',false),column('number','integer',false),column('label','string',false),column('kind','string',false)]};
  return s;
}
function hubP3Enabled_() { return !!HUB_SCHEMA_.tables.TrainingCycles; }
function hubP3SessionId_(store,date,session) { return hubId_(store.config.environment+'|session|'+date+'|'+session); }
function hubP3SessionRecord_(row) {
  return {id:row.id,type:'session',status:row.status,revision:row.revision,created_at:row.created_at,last_changed_at:Date.parse(row.updated_at),last_source:row.source_kind==='app'?'app':'gpt',last_intake:null,last_operation_id:row.last_operation_id,date:row.local_date,session:row.session,cycle_id:row.cycle_id,plan_slot_id:row.plan_slot_id ?? null,lifecycle_state:row.lifecycle_state ?? 'in_progress',started_at:row.started_at,ended_at:row.ended_at};
}
function hubP3ValidateSession_(store,r) {
  intakeDate_(r.date);intakeSession_(r.session);
  intakeCheck_(['planned','in_progress','completed','cancelled'].includes(r.lifecycle_state),'INVALID_VALUE','状態');
  for(const key of ['started_at','ended_at'])intakeCheck_(r[key]==null || typeof r[key]==='string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/.test(r[key]) && Number.isFinite(Date.parse(r[key])),'INVALID_VALUE',key);
  if(r.started_at && r.ended_at)intakeCheck_(Date.parse(r.started_at)<=Date.parse(r.ended_at),'INVALID_VALUE','時刻の順序');
  intakeCheck_(!r.plan_slot_id || r.cycle_id,'INVALID_VALUE','CycleID');
  if(r.cycle_id) { const c=store.get('TrainingCycles',r.cycle_id);intakeCheck_(c?.status==='active','NOT_FOUND','Cycle'); }
  if(r.plan_slot_id) { const slot=store.get('TrainingPlanSlots',r.plan_slot_id);intakeCheck_(slot?.status==='active' && slot.cycle_id===r.cycle_id && r.session.replace(/\d+$/,'')===slot.kind,'INVALID_VALUE','予定枠'); }
}
function hubP3IntakeSession_(store,state,row,now) {
  const [id,kind,,date,section,,no,raw]=row,d=intakeDate_(date),session=intakeSession_(section),content=intakeContent_(raw);
  intakeCheck_(no==='','INVALID_NUMBER_COLUMN');intakeCheck_(['記録','修正','取消'].includes(kind),'INVALID_KIND');
  intakeAllow_(content,kind==='取消'?[]:['状態','CycleID','予定枠','開始時刻','終了時刻']);
  const sid=hubP3SessionId_(store,d,session),existing=state.records[sid];
  intakeCheck_(kind==='記録' || existing,'NOT_FOUND','セッション');
  const before=intakeCopy_(existing),r=existing ? intakeCopy_(existing):{id:sid,type:'session',status:'active',date:d,session,lifecycle_state:'in_progress',cycle_id:null,plan_slot_id:null,started_at:null,ended_at:null};
  if(kind==='取消')r.lifecycle_state='cancelled';
  else {
    intakeCheck_(Object.keys(content).length>0,'NO_CHANGE');
    const states={'予定':'planned','途中':'in_progress','完了':'completed','取消':'cancelled'};
    if('状態' in content){intakeCheck_(content['状態'] in states,'INVALID_VALUE','状態');r.lifecycle_state=states[content['状態']];}
    for(const [key,field] of [['CycleID','cycle_id'],['予定枠','plan_slot_id'],['開始時刻','started_at'],['終了時刻','ended_at']])if(key in content)r[field]=content[key]==='未設定'?null:content[key];
  }
  hubP3ValidateSession_(store,r);intakeTouch_(r,id,now);state.records[sid]=r;
  return {record_id:sid,undo:{record_id:sid,before},summary:d+' '+session+' '+r.lifecycle_state};
}
function hubP3Intake_(store,state,row,now,firstSeen) {
  if(row[2]!=='筋トレ' || row[1]==='戻す')return intakeApply_(state,row,now,firstSeen);
  if(row[5]==='セッション')return hubP3IntakeSession_(store,state,row,now);
  if(row[1]==='記録')intakeCheck_(store.get('TrainingSessions',hubP3SessionId_(store,row[3],intakeSession_(row[4])))?.lifecycle_state!=='cancelled','INVALID_VALUE','取消したセッションは先に状態を戻してください');
  const extra=['機器','変種','最大試技','成功'],content=intakeContent_(row[7]),values={};
  if(['記録','修正'].includes(row[1]))for(const k of extra)if(k in content) {const v=content[k];if(['最大試技','成功'].includes(k))intakeCheck_(['はい','いいえ'].includes(v),'INVALID_VALUE',k);else intakeCheck_(v.length>0 && v.length<=200,'INVALID_VALUE',k);values[k]=v;delete content[k];}
  const cells=row.slice();cells[7]=Object.entries(content).map(([k,v])=>k+'='+v).join('; ');
  let result;
  if(row[1]==='修正' && Object.keys(content).length===0 && Object.keys(values).length>0) {
    const d=intakeDate_(row[3]),session=intakeSession_(row[4]),no=intakeNo_(row[6]);intakeCheck_(row[5] && no,'INCOMPLETE');
    const r=intakeOne_(intakeActive_(state,r=>r.type==='set' && r.date===d && r.session===session && r.exercise===row[5] && r.set_no===no),row[5]),before=intakeCopy_(r);intakeTouch_(r,row[0],now);result={record_id:r.id,undo:{record_id:r.id,before},summary:d+' '+session+' '+row[5]};
  }else result=intakeApply_(state,cells,now,firstSeen);
  const r=state.records[result.record_id];
  if(r.type==='set')for(const [k,field] of [['機器','equipment_key'],['変種','variant'],['最大試技','max_attempt'],['成功','successful']])if(k in values)r[field]=['最大試技','成功'].includes(k)?values[k]==='はい':values[k];
  return result;
}
function hubP3PersistSession_(store,r,op,now) {
  hubP3ValidateSession_(store,r);
  hubIndexedPut_(store,'TrainingSessions',{...hubCommon_(r,op,now),local_date:r.date,time_zone:'Asia/Tokyo',session:r.session,cycle_id:r.cycle_id ?? null,started_at:r.started_at ?? null,ended_at:r.ended_at ?? null,lifecycle_state:r.lifecycle_state ?? 'in_progress',plan_slot_id:r.plan_slot_id ?? null},r.date,'session|'+r.date+'|'+r.session,null,op,now);
}
function hubP3ApplyCycle_(store,op,now) {
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0,'INVALID_REVISION');
  const hash=hubHash_(op),old=store.get('Operations',op.operation_id);if(old){ensure_(old.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  let record;
  try {
    ensure_(op.action==='register_training_cycle' && op.approval_state==='confirmed','CONFIRMATION_REQUIRED');
    const p=op.payload;hubKeys_(p,['name','source_path','source_sha256','slots']);
    ensure_(typeof p.name==='string' && p.name.trim().length>0 && p.name.length<=200 && typeof p.source_path==='string' && p.source_path.length>0 && p.source_path.length<=2000 && /^[a-f0-9]{64}$/.test(p.source_sha256),'INVALID_PLAN_REFERENCE');
    ensure_(Array.isArray(p.slots) && p.slots.length===9,'INVALID_PLAN_SLOTS');
    p.slots.forEach((slot,i)=>{hubKeys_(slot,['number','label','kind']);ensure_(slot.number===i+1 && typeof slot.label==='string' && slot.label.length>0 && slot.label.length<=200 && ['Push','Pull','Leg'].includes(slot.kind),'INVALID_PLAN_SLOTS');});
    ensure_(!store.get('TrainingCycles',op.entity_id) && op.expected_revision===0,'ENTITY_EXISTS');
    record={...hubCommon_({id:op.entity_id,revision:1,status:'active',last_source:'app'},op.operation_id,now),name:p.name,source_path:p.source_path,source_sha256:p.source_sha256};
    hubIndexedPut_(store,'TrainingCycles',record,null,'cycle|'+record.id,null,op.operation_id,now);
    for(const slot of p.slots)hubIndexedPut_(store,'TrainingPlanSlots',{...hubCommon_({id:record.id+'#'+slot.number,revision:1,status:'active',last_source:'app'},op.operation_id,now),cycle_id:record.id,number:slot.number,label:slot.label,kind:slot.kind},null,'slot|'+record.id+'|'+slot.number,record.id,op.operation_id,now);
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{...record,type:'cycle'},null,now);
}
// 完了を推測しない付加移行。元セル/台帳/操作IDは保持。Google操作はP3-6で別途行う。
function hubP3MigrationPlan_(baseline,books) {
  ensure_(stable_(Object.keys(books).sort())===stable_(Object.keys(baseline.tables).sort()),'MIGRATION_TABLE_SET');
  const target=hubP3Schema_(baseline),out=hubClone_(books);
  for(const [table,def] of Object.entries(baseline.tables)) {
    ensure_(Array.isArray(out[table]),'MIGRATION_TABLE_MISSING');const ids=new Set();
    for(const row of out[table]) {ensure_(!ids.has(row.id),'MIGRATION_DUPLICATE_ID');ids.add(row.id);ensure_(Object.keys(row).every(key=>def.columns.some(c=>c.name===key)),'MIGRATION_UNKNOWN_COLUMN');for(const c of def.columns){const v=row[c.name];ensure_(v==null ? c.nullable : typeof v===c.type || c.type==='integer' && Number.isSafeInteger(v),'MIGRATION_COLUMN_TYPE');}for(const c of target.tables[table].columns)if(!(c.name in row))row[c.name]=null;}
  }
  out.TrainingCycles=[];out.TrainingPlanSlots=[];
  return {schema:target,books:out,source_tables:Object.keys(baseline.tables).length,target_tables:Object.keys(target.tables).length};
}
function hubP3ApplySession_(store,op,now) {
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>0,'INVALID_REVISION');
  const hash=hubHash_(op),old=store.get('Operations',op.operation_id);if(old){ensure_(old.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  let r;
  try {
    ensure_(op.action==='update_training_session' && op.approval_state==='confirmed','CONFIRMATION_REQUIRED');
    const row=store.get('TrainingSessions',op.entity_id);ensure_(row?.status==='active','NOT_FOUND');ensure_(row.revision===op.expected_revision,'REVISION_CONFLICT');
    hubKeys_(op.payload,['lifecycle_state','cycle_id','plan_slot_id']);r=hubP3SessionRecord_(row);
    for(const key of ['lifecycle_state','cycle_id','plan_slot_id'])if(key in op.payload)r[key]=op.payload[key];
    hubP3ValidateSession_(store,r);r.revision++;r.last_source='app';r.last_changed_at=now;r.last_operation_id=op.operation_id;r.last_intake=null;
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  hubP3PersistSession_(store,r,op.operation_id,now);const state=hubEmptyState_();hubLoadDate_(store,r.date,state);hubAggregate_(store,state,r.date,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,r,null,now);
}
