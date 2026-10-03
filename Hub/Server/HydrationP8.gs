// F11: 食事と独立したml記録。既存の操作ID・版・差分・バックアップに載せます。
function hubHydrationSchema_(base) {
  const schema=hubClone_(base);
  ensure_(!schema.tables.WaterIntakes,'SCHEMA_CONTRACT_MISMATCH');
  schema.tables.WaterIntakes={columns:[
    ['id','string'],['revision','integer'],['status','string'],['created_at','string'],['updated_at','string'],['source_kind','string'],['last_operation_id','string'],
    ['local_date','string'],['time_zone','string'],['amount_ml','number'],['confirmed_at','string']
  ].map(([name,type])=>({name,type,nullable:false}))};return schema;
}
function hubHydrationEnabled_(){return !!HUB_SCHEMA_.tables.WaterIntakes;}
function hubHydrationValidate_(p){
  hubKeys_(p,['id','date','revision','amountML','removed']);
  ensure_(hubIsId_(p.id) && Number.isSafeInteger(p.revision) && p.revision>0 && p.revision<Number.MAX_SAFE_INTEGER,'INVALID_REVISION');
  intakeDate_(p.date);ensure_(typeof p.removed==='boolean' && Number.isFinite(p.amountML) && p.amountML>0,'INVALID_VALUE');
}
function hubHydrationApply_(store,op,now){
  hubCheckRequest_(store.config,op);hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');
  const hash=hubHash_(op),receipt=store.get('Operations',op.operation_id);
  if(receipt){ensure_(receipt.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  let row;
  try{
    ensure_(op.approval_state==='confirmed','CONFIRMATION_REQUIRED');hubHydrationValidate_(op.payload);
    const p=op.payload,old=store.get('WaterIntakes',op.entity_id),idx=store.get('RecordIndex',op.entity_id);
    ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0 && p.id===op.entity_id && p.revision===op.expected_revision+1,'INVALID_REVISION');
    ensure_(op.action===(op.expected_revision===0?'confirm_water':p.removed?'remove_water':'update_water') && (op.expected_revision>0 || !p.removed),'INVALID_ACTION');
    ensure_((old?.revision ?? 0)===op.expected_revision && (!idx || idx.table_name==='WaterIntakes') && (old || !idx),'REVISION_CONFLICT');
    const timestamp=new Date(now).toISOString();
    row={id:p.id,revision:p.revision,status:p.removed?'removed':'active',created_at:old?.created_at || timestamp,updated_at:timestamp,source_kind:'app',last_operation_id:op.operation_id,local_date:p.date,time_zone:'Asia/Tokyo',amount_ml:p.amountML,confirmed_at:old?.confirmed_at || timestamp};
    hubRow_('WaterIntakes',row);
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  hubIndexedPut_(store,'WaterIntakes',row,row.local_date,'water|'+row.local_date,null,op.operation_id,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{...row,type:'WaterIntakes'},null,now);
}
