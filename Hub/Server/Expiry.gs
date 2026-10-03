// P2-6：派生ページの7日回収アダプター。公開元の保存済みmanifestだけを渡す。
// 公開側の保存済みmanifestを結果一覧へ接続する。Cloud試験/配置はA-3後。
function hubExpiryPlan_(manifest,c,now) {
  ensure_(manifest && manifest.schema_version===1 && manifest.environment===c.environment,'EXPIRY_ENVIRONMENT');
  ensure_(hubIsId_(manifest.request_id) && hubIsId_(manifest.generation),'EXPIRY_ID');
  const made=Date.parse(manifest.last_generated_at),expiry=Date.parse(manifest.expires_at);
  ensure_(Number.isFinite(now) && Number.isFinite(made) && Number.isFinite(expiry) && expiry===made+7*86400000,'EXPIRY_TIME');
  ensure_(Array.isArray(manifest.pages) && manifest.pages.length>0 && manifest.pages.length<=100,'EXPIRY_PAGES');
  const ids=new Set();
  for(const [i,p] of manifest.pages.entries()) {
    ensure_(p && typeof p.id==='string' && p.id && !ids.has(p.id) && p.index===i && /^[a-f0-9]{64}$/.test(p.sha256) && Number.isInteger(p.bytes) && p.bytes>=0 && p.bytes<=50000,'EXPIRY_PAGE');ids.add(p.id);
    ensure_(p.name==='PHH_QUERY_'+c.environment+'_'+manifest.request_id+'_'+manifest.generation+'_p'+i+'.txt','EXPIRY_NAME');
  }
  return {expired:now>=expiry,pages:manifest.pages,request_id:manifest.request_id};
}
function hubExpireDerivedPages_(manifest,c,root,now,preview=false) {
  ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');hubBackupPrivate_(root,c.owner);
  ensure_(![c.canonical,c.inbox,c.results].includes(root.getId()),'EXPIRY_SOURCE');
  const plan=hubExpiryPlan_(manifest,c,now);if(!plan.expired)return {status:'ready',expired:false,pages:plan.pages.length};
  const files=hubCheckDerivedPages_(plan,c,root);
  if(preview)return {status:'ready',expired:true,pages:files.length,preview:true};
  for(const f of files) {
    if(f.getViewers().some(u=>u.getEmail()===c.chat))f.removeViewer(c.chat);
    hubBackupPrivate_(f,c.owner);
    if(!f.isTrashed())f.setTrashed(true);
    ensure_(f.isTrashed(),'EXPIRY_NOT_TRASHED');
  }
  return {status:'expired',expired:true,pages:files.length};
}

function hubCheckDerivedPages_(plan,c,root) {
  const files=[];
  // 全ページの出自/本文/共有を検査してから共有解除する。部分失敗の再実行を許容する。
  for(const p of plan.pages) {
    ensure_(![c.canonical,c.inbox,c.results].includes(p.id),'EXPIRY_SOURCE');
    const f=DriveApp.getFileById(p.id),parents=f.getParents(),parentIds=[];
    while(parents.hasNext())parentIds.push(parents.next().getId());
    ensure_(parentIds.length===1 && parentIds[0]===root.getId(),'EXPIRY_PARENT');
    ensure_(f.getOwner().getEmail()===c.owner && f.getSharingAccess()===DriveApp.Access.PRIVATE && f.getEditors().every(u=>u.getEmail()===c.owner) && f.getViewers().every(u=>u.getEmail()===c.chat),'EXPIRY_ACL');
    ensure_(f.getName()===p.name && f.getSize()===p.bytes,'EXPIRY_CONTENT');
    const body=f.getBlob().getDataAsString('UTF-8');ensure_(hubHash_(body)===p.sha256,'EXPIRY_CONTENT');files.push(f);
  }
  return files;
}
const HUB_DERIVED_RESULT_HEADERS_=['request_id','generation','status','expires_at','page_count','page_urls'];
function hubDerivedJobName_(m,c){return 'PHH_QUERY_'+c.environment+'_'+m.request_id+'_'+m.generation;}
function hubDerivedJobFiles_(folder,c) {
  hubBackupPrivate_(folder,c.owner);const out=[],it=folder.getFiles();
  while(it.hasNext()){ensure_(out.length<101,'EXPIRY_JOB_SIZE');out.push(it.next());}
  return out;
}
function hubReadDerivedJob_(folder,c) {
  const all=hubDerivedJobFiles_(folder,c),matches=all.filter(f=>f.getName()==='expiry-manifest.json');ensure_(matches.length===1,'EXPIRY_JOB_MANIFEST');
  const file=matches[0];hubBackupPrivate_(file,c.owner);ensure_(file.getSize()<=40000,'EXPIRY_JOB_SIZE');
  let job;try {job=JSON.parse(file.getBlob().getDataAsString('UTF-8'));}catch(e){throw Error('EXPIRY_JOB_MANIFEST');}
  ensure_(job && ['ready','expired'].includes(job.status) && job.manifest,'EXPIRY_JOB_MANIFEST');hubExpiryPlan_(job.manifest,c,Date.now());
  ensure_(folder.getName()===hubDerivedJobName_(job.manifest,c),'EXPIRY_JOB_NAME');
  const ids=new Set(job.manifest.pages.map(p=>p.id));ensure_(all.every(f=>f===file || ids.has(f.getId())) && all.length<=ids.size+1,'EXPIRY_JOB_FILES');
  return {job,file};
}
function hubSaveDerivedJob_(manifest,c,folder) {
  ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');hubBackupPrivate_(folder,c.owner);
  ensure_(folder.getName()===hubDerivedJobName_(manifest,c),'EXPIRY_JOB_NAME');
  const plan=hubExpiryPlan_(manifest,c,Date.now());hubCheckDerivedPages_(plan,c,folder);
  const all=hubDerivedJobFiles_(folder,c),saved=all.filter(f=>f.getName()==='expiry-manifest.json');
  if(saved.length) {const existing=hubReadDerivedJob_(folder,c);ensure_(stable_(existing.job.manifest)===stable_(manifest),'EXPIRY_JOB_CHANGED');return existing.job;}
  ensure_(all.length===manifest.pages.length && all.every(f=>manifest.pages.some(p=>p.id===f.getId())),'EXPIRY_JOB_FILES');
  ensure_(all.every(f=>!f.isTrashed() && f.getViewers().some(u=>u.getEmail()===c.chat)),'EXPIRY_NOT_READABLE');
  const job={status:'ready',manifest},body=stable_(job);ensure_(Utilities.newBlob(body).getBytes().length<=40000,'EXPIRY_JOB_SIZE');
  const file=folder.createFile('expiry-manifest.json',body,MimeType.PLAIN_TEXT);hubBackupPrivate_(file,c.owner);
  ensure_(stable_(hubReadDerivedJob_(folder,c).job)===stable_(job),'EXPIRY_JOB_READBACK');return job;
}
function hubWriteDerivedResult_(job,c) {
  const book=SpreadsheetApp.openById(c.results),sh=book.getSheetByName('QueryResults') || book.insertSheet('QueryResults'),m=job.manifest;
  const values=Sheets.Spreadsheets.Values.batchGet(c.results,{ranges:["'QueryResults'!A1:F1","'QueryResults'!A2:B"],valueRenderOption:'UNFORMATTED_VALUE'}).valueRanges;
  ensure_(values?.length===2,'EXPIRY_RESULT_READ');const header=values[0].values?.[0] || [];
  ensure_(header.length===0 || stable_(header)===stable_(HUB_DERIVED_RESULT_HEADERS_),'EXPIRY_RESULT_HEADER');
  const keys=values[1].values || [];ensure_(header.length>0 || keys.length===0 && sh.getLastRow()===0,'EXPIRY_RESULT_HEADER');
  const matches=keys.map((r,i)=>r[0]===m.request_id && r[1]===m.generation?i+2:0).filter(Boolean);
  ensure_(matches.length<=1,'EXPIRY_RESULT_INDEX');const row=matches[0] || keys.length+2,record=[m.request_id,m.generation,job.status,m.expires_at,m.pages.length,job.status==='expired'?'':m.pages.map(p=>'https://drive.google.com/file/d/'+encodeURIComponent(p.id)+'/view').join('\n')];
  if(matches.length){const previous=Sheets.Spreadsheets.Values.batchGet(c.results,{ranges:["'QueryResults'!A"+row+':F'+row],valueRenderOption:'UNFORMATTED_VALUE'}).valueRanges?.[0]?.values?.[0] || [];while(previous.length<6)previous.push('');if(stable_(previous)===stable_(record))return row;}
  const requests=[];if(row>sh.getMaxRows())requests.push({appendDimension:{sheetId:sh.getSheetId(),dimension:'ROWS',length:row-sh.getMaxRows()}});
  for(const [pos,data] of [[1,HUB_DERIVED_RESULT_HEADERS_],[row,record]])requests.push({updateCells:{start:{sheetId:sh.getSheetId(),rowIndex:pos-1,columnIndex:0},rows:[{values:data.map(hubCell_)}],fields:'userEnteredValue'}});
  Sheets.Spreadsheets.batchUpdate({requests},book.getId());
  const read=Sheets.Spreadsheets.Values.batchGet(c.results,{ranges:["'QueryResults'!A"+row+':F'+row],valueRenderOption:'UNFORMATTED_VALUE'}).valueRanges?.[0]?.values?.[0] || [];while(read.length<6)read.push('');ensure_(stable_(read)===stable_(record),'EXPIRY_RESULT_READBACK');return row;
}
function hubCompleteDerivedJob_(folder,c,now,preview=false) {
  const {job,file}=hubReadDerivedJob_(folder,c);if(job.status==='expired')now=Math.max(now,Date.parse(job.manifest.expires_at));
  const result=hubExpireDerivedPages_(job.manifest,c,folder,now,preview);
  if(!result.expired)ensure_(hubCheckDerivedPages_(hubExpiryPlan_(job.manifest,c,now),c,folder).every(f=>!f.isTrashed() && f.getViewers().some(u=>u.getEmail()===c.chat)),'EXPIRY_NOT_READABLE');
  if(preview)return result;
  if(result.expired && job.status!=='expired'){
    job.status='expired';file.setContent(stable_(job));hubBackupPrivate_(file,c.owner);
    ensure_(stable_(hubReadDerivedJob_(folder,c).job)===stable_(job),'EXPIRY_JOB_READBACK');
  }
  // manifest保存後に結果公開が失敗しても、次回は同じIDの結果行を修復する。
  hubWriteDerivedResult_(job,c);return result;
}
function hubCleanupDerivedJobs_(c,root,now,preview=false) {
  ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');hubBackupPrivate_(root,c.owner);
  const folders=[],it=root.getFolders();while(it.hasNext()){ensure_(folders.length<1000,'EXPIRY_JOB_INDEX_LIMIT');folders.push(it.next());}
  ensure_(new Set(folders.map(f=>f.getName())).size===folders.length,'EXPIRY_JOB_INDEX');
  folders.sort((a,b)=>a.getName().localeCompare(b.getName()));const props=PropertiesService.getScriptProperties(),cursor=props.getProperty('PHH_QUERY_CLEANUP_CURSOR') || '';
  const next=folders.filter(f=>f.getName()>cursor).slice(0,1),chosen=next.length?next:folders.slice(0,1),results=[];
  for(const f of chosen){const parents=f.getParents(),ids=[];while(parents.hasNext())ids.push(parents.next().getId());ensure_(ids.length===1 && ids[0]===root.getId(),'EXPIRY_PARENT');const saved=hubDerivedJobFiles_(f,c).filter(file=>file.getName()==='expiry-manifest.json');
    results.push(saved.length?hubCompleteDerivedJob_(f,c,now,preview):{status:'processing',expired:false});}
  if(!preview && chosen.length)props.setProperty('PHH_QUERY_CLEANUP_CURSOR',chosen[0].getName());return {processed:results.length,expired:results.filter(r=>r.expired).length,preview};
}
function runHubExpiryCleanup() {
  const c=hubConfig_();ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');hubCheckACL_(c);hubCheckBookEnvs_(c);
  const id=PropertiesService.getScriptProperties().getProperty('PHH_QUERY_ROOT_ID');if(!id)return {configured:false,processed:0};
  // 同期用ScriptLockをDrive作業中に占有しない。派生ジョブ/結果一覧はUserLockで直列化する。
  const lock=LockService.getUserLock();ensure_(lock.tryLock(1000),'BUSY');try{return hubCleanupDerivedJobs_(c,DriveApp.getFolderById(id),Date.now());}finally{lock.releaseLock();}
}
