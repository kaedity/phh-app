// P6-4：標本を日/出所のpartへ、UUID索引を必要なprefix枝だけへ保存します。
function hubHealthEnabled_() {return !!HUB_SCHEMA_.tables.HealthBatches;}
// 既存32表の本文を読まず、見出しを照合して4表だけを付加します。データ/設定は移行しません。
function setupHubHealthP6() {
  return hubRun_(null,store=>{
    ensure_(hubHealthEnabled_(),'HEALTH_SCHEMA_REQUIRED');const names=['HealthBatches','HealthArchives','HealthDaily','HealthPreparations'],existing=store.book.getSheets(),used=new Set(existing.map(s=>s.getSheetId())),requests=[];
    for(const [name,spec]of Object.entries(HUB_SCHEMA_.tables)){const sh=store.book.getSheetByName(name),cols=spec.columns.map(c=>c.name);if(sh){ensure_(sh.getLastColumn()===cols.length && stable_(sh.getRange(1,1,1,cols.length).getValues()[0])===stable_(cols),'HEADER_MISMATCH');continue;}ensure_(names.includes(name),'HEALTH_SOURCE_SCHEMA_MISSING');let sid=0;while(used.has(sid))sid++;used.add(sid);requests.push({addSheet:{properties:{sheetId:sid,title:name,gridProperties:{rowCount:1000,columnCount:cols.length,frozenRowCount:1}}}},{updateCells:{start:{sheetId:sid,rowIndex:0,columnIndex:0},rows:[{values:cols.map(hubCell_)}],fields:'userEnteredValue'}});}
    if(requests.length)Sheets.Spreadsheets.batchUpdate({requests},store.config.canonical);
    const ranges=names.map(n=>"'"+n+"'!A1:"+hubColumn_(HUB_SCHEMA_.tables[n].columns.length)+'1'),read=Sheets.Spreadsheets.Values.batchGet(store.config.canonical,{ranges,valueRenderOption:'UNFORMATTED_VALUE'});ensure_(read.valueRanges?.length===4,'HEALTH_SCHEMA_READBACK');read.valueRanges.forEach((r,i)=>ensure_(stable_(r.values?.[0])===stable_(HUB_SCHEMA_.tables[names[i]].columns.map(c=>c.name)),'HEALTH_SCHEMA_READBACK'));
    return {environment:store.config.environment,status:requests.length?'health_tables_added':'health_tables_ready',source_tables:32,target_tables:36,health_real_enabled:store.config.health_real_enabled===true};
  });
}
function hubHealthArchiveId_(store,key,part=1) {return hubId_(store.config.environment+'|health-archive|'+key+'|'+part);}
function hubHealthIndexKey_(metric,prefix) {return 'uuid|'+metric+'|'+prefix;}
function hubHealthSampleKey_(metric,date,source) {return 'sample|'+metric+'|'+date+'|'+hubHash_(source);}
function hubHealthCommon_(old,id,op,now,status='active') {return {id,revision:(old?.revision || 0)+1,status,created_at:old?.created_at || new Date(now).toISOString(),updated_at:new Date(now).toISOString(),source_kind:'health',last_operation_id:op};}
function hubHealthResetReadCache_(store,jobs,maximum) {
  // 書いた行番号からfresh APIで準備行を読み戻します。SpreadsheetAppの同一実行cacheは使いません。
  if(store instanceof HubSheetsStore){const ranges=jobs.map(j=>{const p=store.position('HealthPreparations',j.prep.id);ensure_(Number.isInteger(p) && p>=2,'HEALTH_PREPARATION_CORRUPT');return "'HealthPreparations'!A"+p+':'+hubColumn_(HUB_SCHEMA_.tables.HealthPreparations.columns.length)+p;}),read=store.readBatch_(ranges);ensure_(read.valueRanges?.length===jobs.length,'HEALTH_PREPARATION_READBACK');jobs.forEach((j,i)=>{const row=hubDecode_('HealthPreparations',read.valueRanges[i].values?.[0] || []);ensure_(stable_(row)===stable_(j.prep),'HEALTH_PREPARATION_READBACK');store.cache['HealthPreparations\0'+row.id]=row;});store.healthDiskMax=maximum;for(const t of Object.keys(store.sheets))store.diskLast[t]=store.last[t];store.healthStaged=true;}
}
function hubHealthPlan_(store,delta,files,approval) {
  const pages=new Map(),indexPages=new Map(),changed=new Set(),retired=new Map(),affected=new Set(delta.affectedDates);
  const approveDates=dates=>{if(approval.synthetic!==true)ensure_(approval.health_from!==null && [...dates].every(d=>d>=approval.health_from),'HEALTH_PERIOD_NOT_APPROVED');};approveDates(affected);
  const load=meta=>{if(meta.kind==='coverage'){const primary=store.get('HealthArchives',meta.partition_key.slice(9));ensure_(primary?.kind==='samples' && primary.status==='active','HEALTH_COVERAGE_CORRUPT');meta=primary;}if(!pages.has(meta.id)){const rows=files.read(meta);pages.set(meta.id,{old:meta,key:meta.partition_key,part:meta.part_number,kind:meta.kind,metric:meta.metric,date:meta.local_date,source:meta.source_id,rows,dates:new Set(rows.filter(r=>r.sample && !r.removed).flatMap(r=>hubHealthAffectedDates_(r.sample)))});}return pages.get(meta.id);};
  const create=(key,part,kind,date=null,source=null)=>{const id=hubHealthArchiveId_(store,key,part),old=store.get('HealthArchives',id);ensure_(!old || old.status==='removed','HEALTH_ARCHIVE_EXISTS');const p={old,key,part,kind,metric:delta.metric,date,source,rows:[],dates:new Set(date?[date]:[])};pages.set(id,p);return p;};
  const index=id=>{
    const hash=hubHash_(id);for(let length=2;length<=64;length++) {
      const prefix=hash.slice(0,length),key=hubHealthIndexKey_(delta.metric,prefix),aid=hubHealthArchiveId_(store,key);
      if(indexPages.has(aid))return {page:indexPages.get(aid),id:aid};
      const meta=store.get('HealthArchives',aid);if(meta?.status==='removed')continue;
      const p=meta?load(meta):create(key,1,'uuid_index');indexPages.set(aid,p);return {page:p,id:aid};
    }throw Error('HEALTH_INDEX_LIMIT');
  };
  const lookup=id=>{const p=index(id).page;return {p,row:p.rows.find(r=>r.id===id)};};
  const validateIndex=(r,p)=>{ensure_(r && hubIsId_(r.id) && r.metric===delta.metric && typeof r.removed==='boolean' && (r.archive_id===null || hubIsId_(r.archive_id)) && (r.removed || r.archive_id),'HEALTH_INDEX_CORRUPT');ensure_(hubHealthIndexKey_(r.metric,hubHash_(r.id).slice(0,p.key.split('|')[2].length))===p.key,'HEALTH_INDEX_CORRUPT');};
  const samplePage=row=>{const meta=store.get('HealthArchives',row.archive_id);ensure_(meta?.kind==='samples' && meta.status==='active' && meta.metric===delta.metric,'HEALTH_INDEX_CORRUPT');return load(meta);};
  for(const id of delta.deletedIDs) {
    const {p,row}=lookup(id);if(row)validateIndex(row,p);if(row?.removed)continue;
    if(row?.archive_id){const page=samplePage(row),r=page.rows.find(r=>r.id===id);ensure_(r && !r.removed && r.sample,'HEALTH_INDEX_CORRUPT');hubHealthValidateSample_(r.sample,delta.metric);const dates=hubHealthAffectedDates_(r.sample);approveDates(dates);for(const date of dates)affected.add(date);r.removed=true;r.sample=null;changed.add(hubHealthArchiveId_(store,page.key,page.part));}
    if(row)row.removed=true;else p.rows.push({id,metric:delta.metric,removed:true,archive_id:null});changed.add(hubHealthArchiveId_(store,p.key,p.part));
  }
  for(const sample of delta.added) {
    const {p,row}=lookup(sample.id);if(row)validateIndex(row,p);
    // 削除済UUIDを履歴の再取得で復活させません。同じ有効UUIDの異なる原値も拒否します。
    if(row?.removed)continue;
    if(row){const page=samplePage(row),r=page.rows.find(r=>r.id===sample.id);ensure_(r && !r.removed && stable_(r.sample)===stable_(sample),'HEALTH_UUID_REUSED');continue;}
    const date=hubHealthAffectedDates_(sample)[0],key=hubHealthSampleKey_(delta.metric,date,sample.source.id);
    const existing=store.find('HealthArchives','partition_key',key).filter(r=>r.kind==='samples' && r.status==='active').sort((a,b)=>a.part_number-b.part_number),last=existing.at(-1),candidates=last?[load(last)]:[];
    for(const page of pages.values())if(page.kind==='samples' && page.key===key && !candidates.includes(page))candidates.push(page);
    candidates.sort((a,b)=>a.part-b.part);let page=candidates.at(-1),entry={id:sample.id,metric:delta.metric,removed:false,sample};
    if(!page || page.rows.length>=500 || Utilities.newBlob(page.rows.map(stable_).join('\n')+'\n'+stable_(entry)+'\n').getBytes().length>200*1024)page=create(key,(page?.part || 0)+1,'samples',date,sample.source.id);
    page.rows.push(entry);for(const d of hubHealthAffectedDates_(sample))page.dates.add(d);const aid=hubHealthArchiveId_(store,key,page.part);changed.add(aid);p.rows.push({id:sample.id,metric:delta.metric,removed:false,archive_id:aid});changed.add(hubHealthArchiveId_(store,p.key,p.part));
  }
  // 満杯のUUID枝だけを分割。各lookupは1つの有効leaf本文を読みます。
  const split=aid=>{const p=pages.get(aid);if(p.rows.length<=500 && Utilities.newBlob(p.rows.map(stable_).join('\n')+'\n').getBytes().length<=200*1024)return;
    const prefix=p.key.split('|')[2];ensure_(prefix.length<64,'HEALTH_INDEX_LIMIT');const buckets=new Map();for(const r of p.rows){const k=hubHealthIndexKey_(delta.metric,hubHash_(r.id).slice(0,prefix.length+1));if(!buckets.has(k))buckets.set(k,[]);buckets.get(k).push(r);}
    if(p.old)retired.set(aid,p.old);changed.delete(aid);pages.delete(aid);
    // 既存leafの削除metadataを残し、探索が次のprefixへ進むようにします。
    if(!p.old)retired.set(aid,{id:aid,revision:0,status:'removed',partition_key:p.key,kind:'uuid_index',metric:delta.metric,source_id:null,local_date:null,part_number:1,file_id:'',raw_sha256:hubHash_(''),gzip_sha256:hubHash_(''),raw_bytes:0,gzip_bytes:0,record_count:0,active_count:0,format_version:1});
    for(const [key,rows]of buckets){const child=create(key,1,'uuid_index');child.rows=rows;const id=hubHealthArchiveId_(store,key);changed.add(id);split(id);}
  };
  for(const aid of [...changed])if(pages.get(aid)?.kind==='uuid_index')split(aid);
  const daily=[];
  if(!hubHealthMetric_(delta.metric).cumulative)for(const date of [...affected].sort()) {
    const groups=new Map();const metas=store.find('HealthArchives','local_date',date).filter(r=>['samples','coverage'].includes(r.kind) && r.status==='active' && r.metric===delta.metric);
    for(const m of metas)load(m);for(const p of pages.values())if(p.kind==='samples' && p.metric===delta.metric && (p.date===date || p.dates.has(date))){const active=p.rows.filter(r=>!r.removed && hubHealthAffectedDates_(r.sample).includes(date)).map(r=>hubHealthValidateSample_(r.sample,delta.metric));if(!groups.has(p.source))groups.set(p.source,[]);groups.get(p.source).push(...active);}
    for(const [source,rows]of groups)daily.push(hubHealthDailyPlan_(store,delta.metric,date,source,rows));
  }
  for(const stat of delta.statistics)daily.push({id:hubId_(store.config.environment+'|health-day|'+stat.metric+'|'+stat.date+'|statistics'),metric:stat.metric,local_date:stat.date,source_id:null,value:stat.value,unit:stat.unit,method:stat.method,measured_at_utc:stat.measured_at_utc,known_count:stat.value===null?0:1,unknown_count:stat.value===null?1:0,minimum:null,maximum:null,representative_id:null,sample_revision:0});
  // 再取得された統計が欠ける日は、以前の値を削除後の確定値として使いません。
  if(hubHealthMetric_(delta.metric).cumulative)for(const date of affected)if(!delta.statistics.some(s=>s.date===date))daily.push({id:hubId_(store.config.environment+'|health-day|'+delta.metric+'|'+date+'|statistics'),metric:delta.metric,local_date:date,source_id:null,value:null,unit:hubHealthMetric_(delta.metric).unit,method:'healthkit-statistics-v1',measured_at_utc:null,known_count:0,unknown_count:1,minimum:null,maximum:null,representative_id:null,sample_revision:0});
  return {pages:[...changed].map(id=>({id,...pages.get(id),raw:hubHealthJSONL_(pages.get(id).rows.slice().sort((a,b)=>a.id.localeCompare(b.id)))})),retired:[...retired.values()],daily,affected:[...affected].sort()};
}
function hubHealthDailyPlan_(store,metric,date,source,rows) {
  const id=hubId_(store.config.environment+'|health-day|'+metric+'|'+date+'|'+source),ordered=rows.slice().sort((a,b)=>a.start_utc-b.start_utc || a.id.localeCompare(b.id)),known=ordered.filter(r=>r.value!==null);
  let value=ordered.at(-1)?.value ?? null,minimum=known.length?Math.min(...known.map(r=>r.value)):null,maximum=known.length?Math.max(...known.map(r=>r.value)):null,representative=ordered.at(-1)?.id ?? null;
  if(metric==='sleepAnalysis') {
    const intervals=rows.filter(r=>!['inBed','awake'].includes(r.sleepStage)).map(r=>[r.start_utc,r.end_utc]).sort((a,b)=>a[0]-b[0]);let end=null,total=0;for(const [a,b]of intervals){if(end===null || a>end){total+=b-a;end=b;}else if(b>end){total+=b-end;end=b;}}value=rows.length?total:null;minimum=null;maximum=null;representative=null;
  }
  return {id,metric,local_date:date,source_id:source,value,unit:metric==='sleepAnalysis'?'s':hubHealthMetric_(metric).unit,method:metric==='sleepAnalysis'?'source-interval-union-v1':'source-latest-v1',measured_at_utc:null,known_count:metric==='sleepAnalysis'?rows.length:known.length,unknown_count:metric==='sleepAnalysis'?0:rows.length-known.length,minimum,maximum,representative_id:representative,sample_revision:0};
}
function hubHealthApply_(store,op,now,files=null) {
  const delta=hubHealthValidateDelta_(op,store.config),hash=hubHash_(op),old=store.get('Operations',op.operation_id);if(old){ensure_(old.content_hash===hash,'OPERATION_ID_REUSED');return hubOperationResult_(store,op.operation_id);}
  const previous=store.find('HealthPreparations','operation_id',op.operation_id);ensure_(previous.every(r=>r.request_hash===hash),'OPERATION_ID_REUSED');
  // adapter/rootの作成は同意と契約検証が済んだ後です。
  files=files || hubHealthArchiveAdapter_(store.config);const approval={synthetic:op.synthetic,health_from:hubHealthPolicy_(store.config).health_from},plan=hubHealthPlan_(store,delta,files,approval),batchRaw=hubHealthJSONL_([op.payload]);
  const jobs=[...plan.pages.map(p=>({kind:p.kind,key:p.key,part:p.part,raw:p.raw,page:p})),{kind:'batch',key:op.operation_id,part:1,raw:batchRaw}];
  for(const job of jobs) {
    const id=hubId_(op.operation_id+'|'+job.kind+'|'+job.key+'|'+job.part+'|'+job.raw.sha256),prior=store.get('HealthPreparations',id);
    const prep={...hubHealthCommon_(prior,id,op.operation_id,now),operation_id:op.operation_id,request_hash:hash,kind:job.kind,partition_key:job.key,part_number:job.part,stage:'prepared',file_id:null,raw_sha256:job.raw.sha256,raw_bytes:job.raw.bytes,record_count:job.raw.count,gzip_sha256:null,gzip_bytes:null};
    if(prior)ensure_(prior.request_hash===hash && prior.raw_sha256===job.raw.sha256 && prior.stage!=='committed','HEALTH_PREPARATION_CORRUPT');else store.put('HealthPreparations',prep);job.prep=prior || prep;
  }
  const maximum=store instanceof HubSheetsStore?Object.fromEntries(Object.entries(store.sheets).map(([t,sh])=>[t,Math.max(sh.getMaxRows(),store.last[t])])):null;store.commit();hubHealthResetReadCache_(store,jobs,maximum);
  // 全ファイルの読み戻しが済むまで、正本・差分番号・Operationsを変更しません。
  for(const job of jobs){job.file=files.write(job.prep,job.raw);const rows=files.read(job.file);ensure_(stable_(rows)===stable_(hubHealthParseJSONL_(job.raw.body,{raw_sha256:job.file.raw_sha256,raw_bytes:job.file.raw_bytes,record_count:job.file.record_count})),'HEALTH_READBACK');}
  for(const job of jobs) {
    if(job.page){const p=job.page,row={...hubHealthCommon_(p.old,p.id,op.operation_id,now),kind:p.kind,metric:delta.metric,partition_key:p.key,source_id:p.source,local_date:p.date,part_number:p.part,...job.file,active_count:p.rows.filter(r=>!r.removed).length};hubIndexedPut_(store,'HealthArchives',row,p.date,'health|'+p.key,null,op.operation_id,now);
      if(p.kind==='samples'){const key='coverage|'+p.id,oldAliases=store.find('HealthArchives','partition_key',key),dates=new Set(p.rows.filter(r=>!r.removed).flatMap(r=>hubHealthAffectedDates_(r.sample)).filter(d=>d!==p.date));for(const date of new Set([...dates,...oldAliases.map(r=>r.local_date)])){const id=hubId_(store.config.environment+'|health-coverage|'+p.id+'|'+date),prior=store.get('HealthArchives',id),active=dates.has(date),alias={...row,...hubHealthCommon_(prior,id,op.operation_id,now,active?'active':'removed'),kind:'coverage',partition_key:key,local_date:date,active_count:active?p.rows.filter(r=>!r.removed && hubHealthAffectedDates_(r.sample).includes(date)).length:0};hubIndexedPut_(store,'HealthArchives',alias,date,'health|'+key,null,op.operation_id,now);}}
    }
    const current=store.get('HealthPreparations',job.prep.id);store.put('HealthPreparations',{...current,revision:current.revision+1,stage:'committed',updated_at:new Date(now).toISOString(),file_id:job.file.file_id,gzip_sha256:job.file.gzip_sha256,gzip_bytes:job.file.gzip_bytes});
  }
  for(const prior of plan.retired){const row={...prior,...hubHealthCommon_(prior,prior.id,op.operation_id,now,'removed')};hubIndexedPut_(store,'HealthArchives',row,null,'health|'+prior.partition_key,null,op.operation_id,now);}
  for(const day of plan.daily){const prior=store.get('HealthDaily',day.id),row={...hubHealthCommon_(prior,day.id,op.operation_id,now),...day,sample_revision:(prior?.sample_revision || 0)+1};hubIndexedPut_(store,'HealthDaily',row,day.local_date,'health-day|'+day.metric+'|'+day.local_date,null,op.operation_id,now);}
  const file=jobs.at(-1).file,batch={...hubHealthCommon_(null,op.entity_id,op.operation_id,now),metric:delta.metric,request_hash:hash,added_count:delta.added.length,deleted_count:delta.deletedIDs.length,statistics_count:delta.statistics.length,...file};hubIndexedPut_(store,'HealthBatches',batch,null,'health-batch|'+delta.metric,null,op.operation_id,now);
  return hubSaveOperation_(store,op.operation_id,hash,'app',op.action,{id:op.entity_id,type:'HealthBatches',revision:1},null,now);
}
function getHubHealthDetails(q) {
  const query={...q,action:'get_health_details'};return hubRun_(query,store=>hubHealthDetails_(store,query,hubHealthArchiveAdapter_(store.config)),false,true);
}
function hubHealthDetails_(store,q,files) {
  hubCheckRequest_(store.config,q,true);hubHealthMetric_(q.metric);const limit=q.limit ?? 50;ensure_(Number.isInteger(limit) && limit>=1 && limit<=50,'INVALID_LIMIT');
  if(q.synthetic!==true){const policy=hubHealthPolicy_(store.config);ensure_(policy.health_real_enabled && policy.health_metrics.includes(q.metric) && policy.health_from,'HEALTH_METRIC_NOT_APPROVED');}
  if(q.ids===undefined)return hubHealthPeriodDetails_(store,q,files,limit);
  ensure_(Array.isArray(q.ids) && q.ids.length>=1 && q.ids.length<=50 && q.ids.every(hubIsId_) && new Set(q.ids).size===q.ids.length,'INVALID_IDS');const out=[];
  for(const id of q.ids){let index;const hash=hubHash_(id.toLowerCase());for(let len=2;len<=64;len++){const meta=store.get('HealthArchives',hubHealthArchiveId_(store,hubHealthIndexKey_(q.metric,hash.slice(0,len))));if(meta?.status==='removed')continue;if(meta)index=files.read(meta).find(r=>r.id===id.toLowerCase());break;}
    if(!index || index.removed){out.push({id,removed:!!index?.removed,sample:null});continue;}const meta=store.get('HealthArchives',index.archive_id);ensure_(meta?.kind==='samples' && meta.status==='active','HEALTH_INDEX_CORRUPT');const entry=files.read(meta).find(r=>r.id===id.toLowerCase());ensure_(entry && !entry.removed,'HEALTH_INDEX_CORRUPT');const sample=hubHealthValidateSample_(entry.sample,q.metric);if(q.synthetic!==true)ensure_(hubHealthAffectedDates_(sample).every(d=>d>=store.config.health_from),'HEALTH_PERIOD_NOT_APPROVED');out.push({id,removed:false,sample});
  }const result={environment:store.config.environment,schema_version:1,health_contract:1,records:out.slice(0,limit),returned_count:Math.min(limit,out.length),has_more:out.length>limit};ensure_(Utilities.newBlob(stable_(result)).getBytes().length<=200*1024,'RESPONSE_TOO_LARGE');return result;
}
function hubHealthPeriodDetails_(store,q,files,limit) {
  const from=hubHealthDate_(q.date_from),to=hubHealthDate_(q.date_to),days=(Date.parse(to+'T00:00:00Z')-Date.parse(from+'T00:00:00Z'))/86400000+1;ensure_(days>=1 && days<=31,'HEALTH_PERIOD_LIMIT');if(q.synthetic!==true)ensure_(from>=store.config.health_from,'HEALTH_PERIOD_NOT_APPROVED');
  ensure_(q.source_id===undefined || typeof q.source_id==='string' && q.source_id.length>0,'HEALTH_INVALID_SOURCE');const snapshot=hubSetting_(store,'next_change',0),request=hubHash_({metric:q.metric,from,to,source:q.source_id ?? null}),metas=[];
  for(let day=0;day<days;day++){const date=new Date(Date.parse(from+'T00:00:00Z')+day*86400000).toISOString().slice(0,10);metas.push(...store.find('HealthArchives','local_date',date).filter(r=>r.metric===q.metric && ['samples','coverage'].includes(r.kind) && r.status==='active' && (q.source_id===undefined || r.source_id===q.source_id)));}
  metas.sort((a,b)=>a.local_date.localeCompare(b.local_date) || a.partition_key.localeCompare(b.partition_key) || a.part_number-b.part_number);let m=0,offset=0;
  if(q.cursor){hubKeys_(q.cursor,['snapshot_revision','request_hash','archive_id','offset']);ensure_(q.cursor.snapshot_revision===snapshot,'SNAPSHOT_CHANGED');ensure_(q.cursor.request_hash===request && Number.isSafeInteger(q.cursor.offset) && q.cursor.offset>=0,'INVALID_CURSOR');m=metas.findIndex(r=>r.id===q.cursor.archive_id);ensure_(m>=0,'INVALID_CURSOR');offset=q.cursor.offset;}
  const records=[];while(m<metas.length && records.length<limit){const rows=files.read(metas[m]);ensure_(offset<=rows.length,'INVALID_CURSOR');while(offset<rows.length && records.length<limit){const entry=rows[offset++];if(!entry.removed && hubHealthAffectedDates_(entry.sample).filter(d=>d>=from && d<=to)[0]===metas[m].local_date){const sample=hubHealthValidateSample_(entry.sample,q.metric);if(q.synthetic!==true)ensure_(hubHealthAffectedDates_(sample).every(d=>d>=store.config.health_from),'HEALTH_PERIOD_NOT_APPROVED');records.push({id:entry.id,removed:false,sample});}}if(offset===rows.length){m++;offset=0;}}
  const cursor=m<metas.length?{snapshot_revision:snapshot,request_hash:request,archive_id:metas[m].id,offset}:null,out={environment:store.config.environment,schema_version:1,health_contract:1,snapshot_revision:snapshot,records,returned_count:records.length,has_more:cursor!==null,next_cursor:cursor};ensure_(Utilities.newBlob(stable_(out)).getBytes().length<=200*1024,'RESPONSE_TOO_LARGE');return out;
}
