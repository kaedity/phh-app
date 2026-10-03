// 入力候補の削除・復元。食品版・過去の食事の写しは変更しません。
function hubCatalogEntriesSchema_(base) {
  const schema=hubClone_(base);ensure_(!schema.tables.CatalogEntries,'SCHEMA_CONTRACT_MISMATCH');
  schema.tables.CatalogEntries={columns:[['id','string'],['revision','integer'],['status','string'],['created_at','string'],['updated_at','string'],['source_kind','string'],['last_operation_id','string'],['target_kind','string'],['target_id','string']].map(([name,type])=>({name,type,nullable:false}))};return schema;
}
function hubCatalogEntriesEnabled_(){return !!HUB_SCHEMA_.tables.CatalogEntries;}
function hubCatalogEntryValidate_(p){
  hubKeys_(p,['id','targetID','kind','revision','deleted']);
  ensure_(hubIsId_(p.id) && hubIsId_(p.targetID),'INVALID_ID');
  ensure_(['food','preset'].includes(p.kind) && typeof p.deleted==='boolean','INVALID_VALUE');
  ensure_(Number.isSafeInteger(p.revision) && p.revision>0 && p.revision<Number.MAX_SAFE_INTEGER,'INVALID_REVISION');
}
function hubCatalogEntryTarget_(store,kind,id){
  ensure_(kind==='food'?store.find('FoodVersions','food_id',id).length>0:!!store.get('Presets',id),'NOT_FOUND');
}
function hubCatalogEntryApply_(store,op,now){
  hubP4CheckData_(store.config,op);hubCheckRequest_(store.config,op);
  hubKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(hubIsId_(op.operation_id) && hubIsId_(op.entity_id),'INVALID_ID');
  const hash=hubHash_(op),receipt=store.get('Operations',op.operation_id);
  if(receipt){ensure_(receipt.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  let row;
  try{
    ensure_(op.approval_state==='confirmed','CONFIRMATION_REQUIRED');hubCatalogEntryValidate_(op.payload);
    const p=op.payload,old=store.get('CatalogEntries',p.id),idx=store.get('RecordIndex',p.id);
    ensure_(Number.isSafeInteger(op.expected_revision) && op.expected_revision>=0 && p.id===op.entity_id && p.revision===op.expected_revision+1 && (old?.revision ?? 0)===op.expected_revision,'REVISION_CONFLICT');
    ensure_(!idx || idx.table_name==='CatalogEntries','ENTITY_ID_REUSED');
    ensure_(!old || old.target_kind===p.kind && old.target_id===p.targetID,'INVALID_TARGET');
    ensure_(store.find('CatalogEntries','target_id',p.targetID).every(r=>r.target_kind!==p.kind || r.id===p.id),'REVISION_CONFLICT');
    ensure_(old ? (old.status==='active')!==p.deleted : p.deleted,'NO_CHANGE');
    hubCatalogEntryTarget_(store,p.kind,p.targetID);
    const timestamp=new Date(now).toISOString();
    row={id:p.id,revision:p.revision,status:p.deleted?'active':'removed',created_at:old?.created_at || timestamp,updated_at:timestamp,source_kind:'app',last_operation_id:op.operation_id,target_kind:p.kind,target_id:p.targetID};hubRow_('CatalogEntries',row);
  }catch(e){return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,null,e.message,now);}
  hubIndexedPut_(store,'CatalogEntries',row,null,'catalog|'+row.target_kind+'|'+row.target_id,null,op.operation_id,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{...row,type:'CatalogEntries'},null,now);
}
function hubCatalogEntriesBackupValidate_(store,rows){
  const targets=new Set();
  for(const r of rows){hubCatalogEntryValidate_({id:r.id,targetID:r.target_id,kind:r.target_kind,revision:r.revision,deleted:r.status==='active'});hubCatalogEntryTarget_(store,r.target_kind,r.target_id);const key=r.target_kind+'|'+r.target_id;ensure_(!targets.has(key),'BACKUP_CATALOG_DUPLICATE');targets.add(key);}
}
