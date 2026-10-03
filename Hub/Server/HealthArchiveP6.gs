// P6-4：本人だけのgzip JSONL。作成応答が失われても名前と内容を照合して再利用します。
function hubHealthBytesHash_(bytes) {return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(n=>(n&255).toString(16).padStart(2,'0')).join('');}
function hubHealthFileMeta_(blob,raw) {const bytes=blob.getBytes();return {raw_sha256:raw.sha256,raw_bytes:raw.bytes,record_count:raw.count,gzip_sha256:hubHealthBytesHash_(bytes),gzip_bytes:bytes.length,format_version:1};}
function hubHealthReadBlob_(blob,meta) {
  const bytes=blob.getBytes();ensure_(bytes.length===meta.gzip_bytes && bytes.length<=250000 && hubHealthBytesHash_(bytes)===meta.gzip_sha256,'HEALTH_GZIP_HASH');
  let body;try {body=Utilities.ungzip(blob).getDataAsString('UTF-8');}catch(e){throw Error('HEALTH_GZIP_INVALID');}
  return hubHealthParseJSONL_(body,{raw_sha256:meta.raw_sha256,raw_bytes:meta.raw_bytes,record_count:meta.record_count});
}
function hubHealthFolder_(config) {
  const props=PropertiesService.getScriptProperties(),key='PHH_HEALTH_ROOT_ID';let id=props.getProperty(key);
  if(!id){const folder=DriveApp.createFolder('Personal Health Hub — '+config.environment+' Health');hubBackupPrivate_(folder,config.owner);id=folder.getId();props.setProperty(key,id);}
  const folder=DriveApp.getFolderById(id);hubBackupPrivate_(folder,config.owner);return folder;
}
function hubHealthBelongs_(file,folder) {const parents=file.getParents();let found=false;while(parents.hasNext())if(parents.next().getId()===folder.getId())found=true;ensure_(found,'HEALTH_FILE_PARENT');}
function hubHealthDriveGuard_(work) {try{return work();}catch(e){if(/^(HEALTH_|BACKUP_ACL)/.test(e.message))throw e;throw Error('HEALTH_DRIVE_UNAVAILABLE');}}
function hubHealthArchiveAdapter_(config,selectedFolder=null) {
  const folder=hubHealthDriveGuard_(()=>selectedFolder || hubHealthFolder_(config));hubHealthDriveGuard_(()=>hubBackupPrivate_(folder,config.owner));
  const read=meta=>{const file=DriveApp.getFileById(meta.file_id);hubBackupPrivate_(file,config.owner);hubHealthBelongs_(file,folder);ensure_(file.getSize()<=250000,'HEALTH_FILE_SIZE');return hubHealthReadBlob_(file.getBlob(),meta);};
  const write=(prep,raw)=>{
    const name='phh-'+prep.id+'-'+raw.sha256+'.jsonl.gz',it=folder.getFilesByName(name),candidates=[];
    while(it.hasNext())candidates.push(it.next());ensure_(candidates.length<=1,'HEALTH_DUPLICATE_FILE');
    const gzip=Utilities.gzip(Utilities.newBlob(raw.body,'application/x-ndjson',name.slice(0,-3))),expected=hubHealthFileMeta_(gzip,raw);
    const file=candidates[0] || folder.createFile(gzip.setName(name));hubBackupPrivate_(file,config.owner);hubHealthBelongs_(file,folder);
    // 再利用時も、生の本文だけでなくgzipバイト列まで準備済み内容と一致させます。
    const actual=file.getBlob(),meta={...expected,file_id:file.getId(),gzip_sha256:hubHealthBytesHash_(actual.getBytes()),gzip_bytes:actual.getBytes().length};const rows=read(meta);ensure_(stable_(rows)===stable_(hubHealthParseJSONL_(raw.body,{raw_sha256:raw.sha256,raw_bytes:raw.bytes,record_count:raw.count})),'HEALTH_READBACK');return meta;
  };
  return {read:meta=>hubHealthDriveGuard_(()=>read(meta)),write:(prep,raw)=>hubHealthDriveGuard_(()=>write(prep,raw)),folder_id:folder.getId()};
}
