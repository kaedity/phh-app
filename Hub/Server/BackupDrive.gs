// P2-6の保存アダプター。呼出入口・定期実行はP2-5合格後に配置する。
// 保存/読戻しは本人だけのフォルダー内。共有変更・削除・原本への復元は行わない。
function hubBackupPrivate_(item,owner) {
  ensure_(item.getOwner().getEmail()===owner && item.getSharingAccess()===DriveApp.Access.PRIVATE && item.getEditors().every(u=>u.getEmail()===owner) && item.getViewers().length===0,'BACKUP_ACL');
}
function hubBackupCapture_(store,now) {
  ensure_(!store.config.real_data_enabled,'BACKUP_REAL_DATA_DISABLED');
  // SheetsのMap/cache/pendingを経由しない。物理行と設定を毎回読む。
  const read=name=>store instanceof HubSheetsStore ? hubBackupReadSheet_(store.book.getSheetByName(name),name) : store.all(name);
  const settings=()=>hubBackupReader_({ ...Object.fromEntries(Object.keys(HUB_SCHEMA_.tables).map(n=>[n,[]])),Settings:read('Settings')},store.config.environment);
  const start=settings(),start_revision=hubSetting_(start,'next_change'),start_generation=hubSetting_(start,'generation'),tables={};
  for(const name of Object.keys(HUB_SCHEMA_.tables))tables[name]=read(name);
  hubEnvironment_(start);
  const end=settings();
  const bundle=hubBackupCreate_(tables,{environment:store.config.environment,start_revision,start_generation,end_revision:hubSetting_(end,'next_change'),end_generation:hubSetting_(end,'generation'),now});return HUB_SCHEMA_.tables.HealthBatches?hubHealthBackupCapture_(bundle,tables,store.config):bundle;
}

function hubBackupReadSheet_(sheet,name) {
  const columns=HUB_SCHEMA_.tables[name].columns.map(c=>c.name);
  ensure_(sheet && sheet.getLastColumn()===columns.length && stable_(sheet.getRange(1,1,1,columns.length).getValues()[0])===stable_(columns),'BACKUP_TARGET_NOT_EMPTY');
  const count=sheet.getLastRow()-1;
  return count ? sheet.getRange(2,1,count,columns.length).getValues().map(r=>hubDecode_(name,r)) : [];
}
// 新しいstoreをロック取得後に作る。API/受付と同じscript lockを採取完了まで保持。
function hubBackupCaptureBook_(config,now) {
  const lock=LockService.getScriptLock();ensure_(lock.tryLock(1000),'BUSY');
  try{return hubBackupCapture_(new HubSheetsStore(config),now);}finally{lock.releaseLock();}
}
// 保持計画へ入れる完成世代は、ファイルとmanifestの全検証を通す。
function hubBackupRetentionFolders_(folders,owner) {
  const manifests=folders.map(folder=>{
    hubBackupPrivate_(folder,owner);
    // manifestのない途中失敗だけを未完世代として扱う。完成manifestの破損は停止。
    const files=folder.getFiles(),parts=[],seen=new Set();let hasManifest=false;
    while(files.hasNext()) {
      const file=files.next(),name=file.getName();hubBackupPrivate_(file,owner);
      ensure_(!seen.has(name),'BACKUP_DUPLICATE_FILE');seen.add(name);
      if(name==='manifest.json'){hasManifest=true;continue;}
      if(typeof hubHealthBackupFileKey_==='function' && hubHealthBackupFileKey_(name)){ensure_(file.getSize()<=250000 && hubHealthBytesHash_(file.getBlob().getBytes())===name.slice(0,-9),'HEALTH_GZIP_HASH');parts.push({sha256:hubHealthBackupFileKey_(name)});continue;}
      ensure_(/^[a-f0-9]{64}\.jsonl$/.test(name),'BACKUP_UNEXPECTED_FILE');
      ensure_(file.getSize()<=1000000,'BACKUP_FILE_TOO_LARGE');
      const body=file.getBlob().getDataAsString('UTF-8'),sha256=name.slice(0,-6);
      ensure_(hubHash_(body)===sha256,'BACKUP_PART_HASH');parts.push({sha256});
    }
    if(hasManifest)return hubBackupReadFolder_(folder,owner).manifest;
    // 未完世代はretireへ入れず、存在する全オブジェクトの参照を保護する。
    return {id:'unfinished:'+folder.getId(),complete:false,tables:[{parts}]};
  });
  return hubBackupRetention_(manifests);
}

function hubBackupReadFolder_(folder,owner) {
  hubBackupPrivate_(folder,owner);
  const files=folder.getFiles(),objects={},seen=new Set();let manifest;
  while(files.hasNext()) {
    const file=files.next();hubBackupPrivate_(file,owner);const name=file.getName();
    ensure_(!seen.has(name),'BACKUP_DUPLICATE_FILE');seen.add(name);
    ensure_(file.getSize()<=1000000,'BACKUP_FILE_TOO_LARGE');
    const healthKey=typeof hubHealthBackupFileKey_==='function'?hubHealthBackupFileKey_(name):null;if(healthKey){objects[healthKey]=Utilities.base64Encode(file.getBlob().getBytes());continue;}
    const body=file.getBlob().getDataAsString('UTF-8');
    if(name==='manifest.json')manifest=JSON.parse(body);
    else {ensure_(/^[a-f0-9]{64}\.jsonl$/.test(name),'BACKUP_UNEXPECTED_FILE');objects[name.slice(0,-6)]=body;}
  }
  const tables=hubBackupVerify_(manifest,objects);
  const referenced=new Set([...manifest.tables.flatMap(t=>t.parts.map(p=>p.sha256)),...(manifest.health_files || []).map(f=>'gzip:'+f.gzip_sha256)]);
  ensure_(stable_(Object.keys(objects).sort())===stable_(Array.from(referenced).sort()),'BACKUP_UNEXPECTED_FILE');
  return {manifest,objects,tables};
}
function hubBackupWriteFolder_(root,bundle,owner) {
  hubBackupPrivate_(root,owner);hubBackupVerify_(bundle.manifest,bundle.objects);
  const folder=root.createFolder('PHH-'+bundle.manifest.created_at.slice(0,10)+'-'+bundle.manifest.id);
  hubBackupPrivate_(folder,owner);
  // 完了manifestは最後に保存。途中失敗のフォルダーは残し、復元の対象にしない。
  for(const [hash,body] of Object.entries(bundle.objects)) {
    if(hash.startsWith('gzip:')){const file=folder.createFile(Utilities.newBlob(Utilities.base64Decode(body),'application/gzip',hash.slice(5)+'.jsonl.gz'));hubBackupPrivate_(file,owner);ensure_(hubHealthBytesHash_(file.getBlob().getBytes())===hash.slice(5),'HEALTH_GZIP_HASH');continue;}
    const file=folder.createFile(hash+'.jsonl',body,'text/plain');hubBackupPrivate_(file,owner);
    ensure_(file.getBlob().getDataAsString('UTF-8')===body,'BACKUP_WRITE_MISMATCH');
  }
  const manifest=folder.createFile('manifest.json',JSON.stringify(bundle.manifest),'application/json');hubBackupPrivate_(manifest,owner);
  const verified=hubBackupReadFolder_(folder,owner);
  ensure_(verified.manifest.sha256===bundle.manifest.sha256,'BACKUP_WRITE_MISMATCH');
  return {folder_id:folder.getId(),manifest_id:verified.manifest.id,complete:true,counts:verified.manifest.tables.map(t=>({table:t.name,count:t.count}))};
}
function hubBackupRestoreBook_(book,bundle,sourceConfig,now) {
  // 復元先は既存3ブックと異なる、全16表が見出しだけの本人限定ブック。
  // 接続設定は切り替えない。失敗した復元先も残し、元の正本を変更しない。
  ensure_(!sourceConfig.real_data_enabled,'BACKUP_REAL_DATA_DISABLED');
  ensure_(![sourceConfig.canonical,sourceConfig.inbox,sourceConfig.results].includes(book.getId()),'BACKUP_SOURCE_TARGET');
  const plan=hubBackupRestorePlan_(bundle.manifest,bundle.objects,now);
  ensure_(plan.environment===sourceConfig.environment,'BACKUP_ENVIRONMENT');
  const file=DriveApp.getFileById(book.getId());hubBackupPrivate_(file,sourceConfig.owner);
  const names=Object.keys(HUB_SCHEMA_.tables);
  ensure_(stable_(book.getSheets().map(s=>s.getName()).sort())===stable_(names.slice().sort()),'BACKUP_TARGET_TABLES');
  const existing=Object.fromEntries(names.map(name=>[name,hubBackupReadSheet_(book.getSheetByName(name),name)]));
  if(names.some(name=>existing[name].length)) {
    // 再試行時刻が異なっても、最初の復元のgeneration更新時刻だけを引き継ぐ。
    const generation=existing.Settings.find(r=>r.id==='generation');
    ensure_(generation && Number.isFinite(Date.parse(generation.updated_at)),'BACKUP_TARGET_NOT_EMPTY');
    const previous=hubBackupRestorePlan_(bundle.manifest,bundle.objects,Date.parse(generation.updated_at));
    ensure_(stable_(existing)===stable_(previous.tables),'BACKUP_TARGET_NOT_EMPTY');
    hubBackupValidate_(existing,{...bundle.manifest,generation:plan.generation});
    hubBackupPrivate_(file,sourceConfig.owner);
    return {canonical_id:book.getId(),generation:plan.generation,next_change:plan.next_change,complete:true,counts:names.map(table=>({table,count:existing[table].length}))};
  }
  const requests=[];
  for(const name of names) {
    const sheet=book.getSheetByName(name),columns=HUB_SCHEMA_.tables[name].columns.map(c=>c.name),rows=plan.tables[name];
    ensure_(sheet.getLastRow()===1 && sheet.getLastColumn()===columns.length && stable_(sheet.getRange(1,1,1,columns.length).getValues()[0])===stable_(columns),'BACKUP_TARGET_NOT_EMPTY');
    if(rows.length+1>sheet.getMaxRows())requests.push({appendDimension:{sheetId:sheet.getSheetId(),dimension:'ROWS',length:rows.length+1-sheet.getMaxRows()}});
    if(rows.length)requests.push({updateCells:{start:{sheetId:sheet.getSheetId(),rowIndex:1,columnIndex:0},rows:rows.map(r=>({values:hubRow_(name,r).map(hubCell_)})),fields:'userEnteredValue'}});
  }
  ensure_(Utilities.newBlob(JSON.stringify(requests)).getBytes().length<=8000000,'BACKUP_RESTORE_BATCH_TOO_LARGE');
  Sheets.Spreadsheets.batchUpdate({requests},book.getId());
  hubBackupPrivate_(file,sourceConfig.owner);
  return hubBackupVerifyRestored_(book,bundle,sourceConfig,now);
}
function hubBackupVerifyRestored_(book,bundle,sourceConfig,now) {
  ensure_(!sourceConfig.real_data_enabled && ![sourceConfig.canonical,sourceConfig.inbox,sourceConfig.results].includes(book.getId()),'BACKUP_SOURCE_TARGET');
  hubBackupPrivate_(DriveApp.getFileById(book.getId()),sourceConfig.owner);
  const plan=hubBackupRestorePlan_(bundle.manifest,bundle.objects,now),names=Object.keys(HUB_SCHEMA_.tables);
  ensure_(plan.environment===sourceConfig.environment,'BACKUP_ENVIRONMENT');
  ensure_(stable_(book.getSheets().map(s=>s.getName()).sort())===stable_(names.slice().sort()),'BACKUP_TARGET_TABLES');
  // 書込後は同じAdvanced APIから取得する。SpreadsheetAppの古い読取キャッシュを使わない。
  const ranges=names.map(name=>"'"+name+"'!A1:"+hubColumn_(HUB_SCHEMA_.tables[name].columns.length)+(plan.tables[name].length+1));
  const result=Sheets.Spreadsheets.Values.batchGet(book.getId(),{ranges,valueRenderOption:'UNFORMATTED_VALUE'}),restored={};
  ensure_(result.valueRanges?.length===names.length,'BACKUP_RESTORE_READBACK');
  names.forEach((name,i)=>{
    const rows=result.valueRanges[i].values || [],columns=HUB_SCHEMA_.tables[name].columns.map(c=>c.name);
    ensure_(stable_(rows[0])===stable_(columns) && rows.length===plan.tables[name].length+1,'BACKUP_RESTORE_READBACK');
    restored[name]=rows.slice(1).map(r=>hubDecode_(name,r));
  });
  hubBackupValidate_(restored,{...bundle.manifest,generation:plan.generation});
  ensure_(stable_(restored)===stable_(plan.tables),'BACKUP_RESTORE_READBACK');
  return {canonical_id:book.getId(),generation:plan.generation,next_change:plan.next_change,complete:true,counts:names.map(table=>({table,count:restored[table].length}))};
}

// 実行入口はprivateの検証関数から呼ぶ。稼働先の設定や世代は変更しない。
function hubBackupRoot_(config) {
  ensure_(!config.real_data_enabled,'BACKUP_REAL_DATA_DISABLED');
  const properties=PropertiesService.getScriptProperties();let id=properties.getProperty('PHH_BACKUP_ROOT_ID');
  if(!id) {const folder=DriveApp.createFolder('Personal Health Hub — '+config.environment+' Backups');hubBackupPrivate_(folder,config.owner);id=folder.getId();properties.setProperty('PHH_BACKUP_ROOT_ID',id);}
  const root=DriveApp.getFolderById(id);hubBackupPrivate_(root,config.owner);return root;
}
function hubCreateBackup_() {
  // 一貫した16表の採取だけ同期ロック内。Drive保存・読戻しは採取済みの不変bundleで行う。
  const captured=hubRun_(null,store=>({bundle:hubBackupCapture_(store,Date.now()),config:store.config}));
  const {bundle,config}=captured,root=hubBackupRoot_(config),saved=hubBackupWriteFolder_(root,bundle,config.owner);
  const receipt={...saved,created_at:bundle.manifest.created_at,sha256:bundle.manifest.sha256,snapshot_revision:bundle.manifest.snapshot_revision,generation:bundle.manifest.generation};
  PropertiesService.getScriptProperties().setProperty('PHH_BACKUP_LAST',JSON.stringify(receipt));return receipt;
}

function hubBackupEmptyBook_(root,owner,manifestId) {
  const book=SpreadsheetApp.create('PHH Separate Restore — '+manifestId),file=DriveApp.getFileById(book.getId());
  // 失敗した復元先のIDを先に保持し、自動的な再作成/上書きを避ける。
  PropertiesService.getScriptProperties().setProperty('PHH_BACKUP_RESTORE_TARGET',book.getId());
  hubBackupPrivate_(file,owner);file.moveTo(root);
  Object.entries(HUB_SCHEMA_.tables).forEach(([name,spec],i)=>{
    const sheet=i===0?book.getSheets()[0].setName(name):book.insertSheet(name),width=spec.columns.length;
    if(sheet.getMaxColumns()<width)sheet.insertColumnsAfter(sheet.getMaxColumns(),width-sheet.getMaxColumns());
    sheet.getRange(1,1,1,width).setValues([spec.columns.map(c=>c.name)]);sheet.setFrozenRows(1);
  });
  SpreadsheetApp.flush();return book;
}
function hubRestoreLastBackup_() {
  return hubRun_(null,store=>{
    ensure_(!store.config.real_data_enabled,'BACKUP_REAL_DATA_DISABLED');
    const props=PropertiesService.getScriptProperties(),saved=JSON.parse(props.getProperty('PHH_BACKUP_LAST') || 'null');
    ensure_(saved?.complete===true,'BACKUP_INCOMPLETE');
    const target=props.getProperty('PHH_BACKUP_RESTORE_TARGET'),attempt=JSON.parse(props.getProperty('PHH_BACKUP_RESTORE_ATTEMPT') || 'null');
    ensure_(!target || attempt,'BACKUP_RESTORE_ALREADY_ATTEMPTED');
    const root=hubBackupRoot_(store.config),folder=DriveApp.getFolderById(saved.folder_id),parents=folder.getParents();let belongs=false;
    while(parents.hasNext())if(parents.next().getId()===root.getId())belongs=true;
    ensure_(belongs,'BACKUP_ROOT_MISMATCH');
    const bundle=hubBackupReadFolder_(folder,store.config.owner);ensure_(bundle.manifest.sha256===saved.sha256,'BACKUP_MANIFEST_HASH');
    const config_sha256=hubHash_(store.config);
    if(target)ensure_(attempt.target_id===target && attempt.folder_id===saved.folder_id && attempt.manifest_sha256===bundle.manifest.sha256 && attempt.config_sha256===config_sha256 && Number.isFinite(attempt.started_at),'BACKUP_RESTORE_ATTEMPT_MISMATCH');
    const now=target ? attempt.started_at : Date.now(),before=hubBackupCapture_(store,now);
    if(target)ensure_(before.manifest.sha256===attempt.source_sha256,'BACKUP_SOURCE_CHANGED');
    const book=target ? SpreadsheetApp.openById(target) : hubBackupEmptyBook_(root,store.config.owner,bundle.manifest.id);
    if(!target) {
      // 復元書込みより先に対象/manifest/原本/設定を永続化。応答消失後も同じ対象だけを照合する。
      props.setProperty('PHH_BACKUP_RESTORE_TARGET',book.getId());
      props.setProperty('PHH_BACKUP_RESTORE_ATTEMPT',JSON.stringify({target_id:book.getId(),folder_id:saved.folder_id,manifest_sha256:bundle.manifest.sha256,config_sha256,source_sha256:before.manifest.sha256,started_at:now}));
    }
    let restoreBundle=bundle,healthFolderId=null;
    if(bundle.manifest.health_files?.length){const folder=hubHealthRestoreFolder_(store.config.owner,book.getId());healthFolderId=folder.getId();restoreBundle=hubHealthBackupRestoreFiles_(bundle,folder,store.config);}
    const restored=hubBackupRestoreBook_(book,restoreBundle,store.config,now),after=hubBackupCapture_(new HubSheetsStore(store.config),now);
    ensure_(before.manifest.sha256===after.manifest.sha256,'BACKUP_SOURCE_CHANGED');
    const receipt={...restored,manifest_id:bundle.manifest.id,...(healthFolderId?{health_folder_id:healthFolderId}:{}),source_unchanged:true,source_configuration_unchanged:true};
    props.setProperty('PHH_BACKUP_RESTORE_LAST',JSON.stringify(receipt));return receipt;
  });
}

function hubBackupPrune_(root,config) {
  ensure_(!config.real_data_enabled,'BACKUP_REAL_DATA_DISABLED');hubBackupPrivate_(root,config.owner);
  const it=root.getFolders(),complete=[],incomplete=[],allFolders=[];
  while(it.hasNext()) {
    const folder=it.next();allFolders.push(folder);ensure_(/^PHH-\d{4}-\d{2}-\d{2}-[a-f0-9-]{36}$/.test(folder.getName()),'BACKUP_UNEXPECTED_FOLDER');hubBackupPrivate_(folder,config.owner);
    const files=folder.getFiles();let hasManifest=false;while(files.hasNext())if(files.next().getName()==='manifest.json')hasManifest=true;
    if(!hasManifest){incomplete.push(folder);continue;}
    const bundle=hubBackupReadFolder_(folder,config.owner);complete.push({folder,bundle});
  }
  const plan=hubBackupRetentionFolders_(allFolders,config.owner),retained=complete.filter(x=>plan.keep.includes(x.bundle.manifest.id)),remainingObjects=new Set(retained.flatMap(x=>Object.keys(x.bundle.objects)));
  for(const folder of incomplete){const files=folder.getFiles();while(files.hasNext()){const name=files.next().getName();remainingObjects.add(typeof hubHealthBackupFileKey_==='function' && hubHealthBackupFileKey_(name) || name.slice(0,-6));}}
  ensure_(plan.protected_objects.every(h=>remainingObjects.has(h)),'BACKUP_PROTECTED_REFERENCE');
  // 現在の低頻度16表は世代フォルダー内の独立コピー。保持世代が使うコピーは触らない。
  // 詳細ファイルの共通オブジェクト領域を導入するときは、その参照回収を別に実装する。
  let retired=0;for(const item of complete.filter(x=>plan.retire.includes(x.bundle.manifest.id))){hubBackupPrivate_(item.folder,config.owner);item.folder.setTrashed(true);retired++;}
  return {kept:retained.length,retired,preserved_incomplete:incomplete.length,protected_objects:plan.protected_objects.length};
}
