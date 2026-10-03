// P6の純粋契約。通信・ファイル・全標本読取は行わず、Core.gsのhash/型ヘルパだけを使う。
const HUB_HEALTH_P6_LIMIT_ = {records:500,bytes:200*1024};
const HUB_HEALTH_METRICS_ = {
  bodyMass:{unit:'kg',cumulative:false},bodyFatPercentage:{unit:'fraction',cumulative:false},
  bodyMassIndex:{unit:'count',cumulative:false},leanBodyMass:{unit:'kg',cumulative:false},
  stepCount:{unit:'count',cumulative:true},activeEnergyBurned:{unit:'kcal',cumulative:true},
  basalEnergyBurned:{unit:'kcal',cumulative:true},sleepAnalysis:{unit:'interval',cumulative:false}
};
function hubHealthP6Schema_(p5) {
  const names=['HealthBatches','HealthArchives','HealthDaily','HealthPreparations'];
  ensure_(p5 && p5.schema_version===1 && p5.tables && Object.keys(p5.tables).length===32 && p5.tables.SupplementDays && p5.tables.Meals && names.every(n=>!p5.tables[n]),'P6_SOURCE_SCHEMA');
  const out=hubClone_(p5),common=p5.tables.Meals.columns.slice(0,7);
  ensure_(stable_(common.map(c=>c.name))===stable_(['id','revision','status','created_at','updated_at','source_kind','last_operation_id']),'P6_COMMON_COLUMNS');
  const add=(name,fields,indexes=[])=>{out.tables[name]={primary_key:['id'],indexes:[['id'],...indexes.map(n=>[n])],columns:[...hubClone_(common),...fields.map(([name,type,nullable=false])=>({name,type,nullable}))]};};
  add('HealthBatches',[
    ['metric','string'],['request_hash','string'],['added_count','integer'],['deleted_count','integer'],['statistics_count','integer'],
    ['file_id','string'],['raw_sha256','string'],['gzip_sha256','string'],['raw_bytes','integer'],['gzip_bytes','integer'],['record_count','integer'],['format_version','integer']
  ]);
  add('HealthArchives',[
    ['kind','string'],['metric','string'],['partition_key','string'],['source_id','string',true],['local_date','string',true],['part_number','integer'],
    ['file_id','string'],['raw_sha256','string'],['gzip_sha256','string'],['raw_bytes','integer'],['gzip_bytes','integer'],['record_count','integer'],['active_count','integer'],['format_version','integer']
  ],['partition_key','kind','metric','local_date']);
  add('HealthDaily',[
    ['metric','string'],['local_date','string'],['source_id','string',true],['value','number',true],['unit','string'],['method','string'],['measured_at_utc','number',true],
    ['known_count','integer'],['unknown_count','integer'],['minimum','number',true],['maximum','number',true],['representative_id','string',true],['sample_revision','integer']
  ],['local_date','metric']);
  add('HealthPreparations',[
    ['operation_id','string'],['request_hash','string'],['kind','string'],['partition_key','string'],['part_number','integer'],['stage','string'],
    ['file_id','string',true],['raw_sha256','string'],['raw_bytes','integer'],['record_count','integer'],['gzip_sha256','string',true],['gzip_bytes','integer',true]
  ],['operation_id','stage']);
  out.health_real_enabled_default=false;
  return out;
}
function hubHealthP6MigrationPlan_(p5,books) {
  const schema=hubHealthP6Schema_(p5),names=Object.keys(p5.tables);
  hubKeys_(books,names);ensure_(stable_(Object.keys(books).sort())===stable_(names.sort()),'MIGRATION_TABLE_SET');
  for(const [name,spec]of Object.entries(p5.tables)) {
    ensure_(Array.isArray(books[name]),'MIGRATION_TABLE_MISSING');const ids=new Set();
    for(const row of books[name]) {
      hubKeys_(row,spec.columns.map(c=>c.name));
      ensure_(typeof row.id==='string' && !ids.has(row.id),'MIGRATION_DUPLICATE_ID');ids.add(row.id);
      ensure_(stable_(Object.keys(row).sort())===stable_(spec.columns.map(c=>c.name).sort()),'MIGRATION_COLUMN_SET');
      for(const c of spec.columns) {const v=row[c.name];ensure_(v===null?c.nullable:c.type==='integer'?Number.isSafeInteger(v):c.type==='number'?Number.isFinite(v):typeof v===c.type,'MIGRATION_COLUMN_TYPE');}
    }
  }
  const out=hubClone_(books);for(const name of Object.keys(schema.tables))if(!(name in out))out[name]=[];
  return {schema,books:out,source_tables:32,target_tables:36};
}
function hubHealthMetric_(metric) {
  ensure_(typeof metric==='string' && Object.prototype.hasOwnProperty.call(HUB_HEALTH_METRICS_,metric),'HEALTH_INVALID_METRIC');
  return hubClone_(HUB_HEALTH_METRICS_[metric]);
}
function hubHealthFiniteJSON_(v,parents=new Set()) {
  if(v===null || typeof v==='string' || typeof v==='boolean')return;
  if(typeof v==='number'){ensure_(Number.isFinite(v),'HEALTH_NONFINITE');return;}
  ensure_(v && typeof v==='object' && (Array.isArray(v) || Object.prototype.toString.call(v)==='[object Object]') && !parents.has(v),'HEALTH_INVALID_JSON');
  ensure_(Object.getOwnPropertySymbols(v).length===0,'HEALTH_INVALID_JSON');
  const keys=Object.keys(v);
  if(Array.isArray(v))ensure_(keys.length===v.length && keys.every((k,i)=>k===String(i)),'HEALTH_INVALID_JSON');
  parents.add(v);for(const k of keys)hubHealthFiniteJSON_(v[k],parents);parents.delete(v);
}
function hubHealthKeys_(v,allowed,required=allowed) {
  hubKeys_(v,allowed);ensure_(required.every(k=>Object.prototype.hasOwnProperty.call(v,k)),'HEALTH_REQUIRED_FIELD');
}
function hubHealthBytes_(body) {return Utilities.newBlob(body).getBytes().length;}
function hubHealthDate_(date) {
  ensure_(typeof date==='string' && /^\d{4}-\d{2}-\d{2}$/.test(date) && date>='0001-01-01' && Number.isFinite(Date.parse(date+'T00:00:00Z')) && new Date(date+'T00:00:00Z').toISOString().slice(0,10)===date,'HEALTH_INVALID_DATE');
  return date;
}
function hubHealthUTC_(seconds) {
  ensure_(typeof seconds==='number' && Number.isFinite(seconds) && seconds>=Date.parse('0001-01-01T00:00:00Z')/1000 && seconds<=Date.parse('9999-12-31T14:59:59.999Z')/1000,'HEALTH_INVALID_TIME');
  return seconds;
}
function hubHealthLocalDate_(seconds) {return hubHealthDate_(new Date((hubHealthUTC_(seconds)+9*3600)*1000).toISOString().slice(0,10));}
function hubHealthText_(value,empty=false) {ensure_(typeof value==='string' && (empty || value.length>0) && value.length<=500,'HEALTH_INVALID_SOURCE');}
function hubHealthValue_(value,metric) {
  ensure_(value===null || typeof value==='number' && Number.isFinite(value) && value>=0,'HEALTH_INVALID_VALUE');
  if(value!==null && metric==='bodyFatPercentage')ensure_(value<=1,'HEALTH_INVALID_VALUE');
  if(value!==null && metric==='stepCount')ensure_(Number.isSafeInteger(value),'HEALTH_INVALID_VALUE');
}
function hubHealthValidateSample_(sample,metric) {
  hubHealthFiniteJSON_(sample);
  hubHealthKeys_(sample,['id','metric','source','start_utc','end_utc','value','unit','sleepStage'],['id','metric','source','start_utc','end_utc','unit']);
  const spec=hubHealthMetric_(sample.metric);ensure_(metric===undefined || sample.metric===metric,'HEALTH_METRIC_MISMATCH');
  ensure_(hubIsId_(sample.id),'HEALTH_INVALID_ID');ensure_(sample.unit===spec.unit,'HEALTH_INVALID_UNIT');
  hubHealthKeys_(sample.source,['id','name','device'],['id','name']);hubHealthText_(sample.source.id);hubHealthText_(sample.source.name);
  const device=sample.source.device ?? null;if(device!==null)hubHealthText_(device,true);
  const start=hubHealthUTC_(sample.start_utc),end=hubHealthUTC_(sample.end_utc),value=sample.value ?? null,stage=sample.sleepStage ?? null;
  ensure_(end>=start,'HEALTH_INVALID_TIME');hubHealthValue_(value,sample.metric);
  if(sample.metric==='sleepAnalysis')ensure_(end>start && value===null && ['inBed','awake','asleep','core','deep','rem'].includes(stage),'HEALTH_INVALID_SLEEP');
  else ensure_(stage===null,'HEALTH_INVALID_SLEEP');
  return {id:sample.id.toLowerCase(),metric:sample.metric,source:{id:sample.source.id,name:sample.source.name,device},start_utc:start,end_utc:end,value,unit:spec.unit,sleepStage:stage};
}
function hubHealthAffectedDates_(sample) {
  const s=hubHealthValidateSample_(sample),start=hubHealthLocalDate_(s.start_utc);
  if(s.metric==='sleepAnalysis')return [hubHealthLocalDate_(s.end_utc)];
  const dates=[start];let next=Date.parse(start+'T00:00:00+09:00')/1000+86400;
  while(next<s.end_utc){dates.push(hubHealthLocalDate_(next));next+=86400;}
  return dates;
}
function hubHealthValidateStatistic_(stat,metric) {
  hubHealthFiniteJSON_(stat);hubHealthKeys_(stat,['metric','date','value','unit','method','measured_at_utc'],['metric','date','unit','method','measured_at_utc']);
  const spec=hubHealthMetric_(stat.metric);ensure_(spec.cumulative,'HEALTH_STATISTICS_METRIC');ensure_(metric===undefined || stat.metric===metric,'HEALTH_METRIC_MISMATCH');
  ensure_(stat.unit===spec.unit,'HEALTH_INVALID_UNIT');ensure_(stat.method==='healthkit-statistics-v1','HEALTH_INVALID_METHOD');
  const value=stat.value ?? null;hubHealthValue_(value,stat.metric);hubHealthDate_(stat.date);hubHealthUTC_(stat.measured_at_utc);
  return {metric:stat.metric,date:stat.date,value,unit:spec.unit,method:stat.method,measured_at_utc:stat.measured_at_utc};
}
function hubHealthPolicy_(config={}) {
  ensure_(config && typeof config==='object' && !Array.isArray(config),'HEALTH_INVALID_CONFIG');
  for(const key of ['real_data_enabled','health_real_enabled'])if(key in config)ensure_(typeof config[key]==='boolean','HEALTH_INVALID_CONFIG');
  const metrics='health_metrics' in config?config.health_metrics:[];ensure_(Array.isArray(metrics) && new Set(metrics).size===metrics.length,'HEALTH_INVALID_CONFIG');metrics.forEach(hubHealthMetric_);
  const from=config.health_from ?? null;if(from!==null)hubHealthDate_(from);
  return {real_data_enabled:config.real_data_enabled===true,health_real_enabled:config.health_real_enabled===true,health_metrics:metrics,health_from:from};
}
function hubHealthValidateDelta_(op,config={}) {
  hubHealthFiniteJSON_(op);
  hubHealthKeys_(op,['schema_version','environment','operation_id','action','entity_id','expected_revision','approval_state','synthetic','payload']);
  ensure_(op.schema_version===1 && ['PHH_TEST','PHH_PRODUCTION'].includes(op.environment) && typeof op.synthetic==='boolean','INVALID_OPERATION');
  ensure_(op.action==='save_health_delta','INVALID_ACTION');ensure_(op.expected_revision===0,'REVISION_CONFLICT');
  ensure_(op.approval_state==='confirmed','CONFIRMATION_REQUIRED');ensure_(hubIsId_(op.operation_id) && op.operation_id===op.entity_id,'HEALTH_INVALID_ID');
  const policy=hubHealthPolicy_(config);
  if(config.environment!==undefined)ensure_(config.environment===op.environment,'ENVIRONMENT_MISMATCH');
  ensure_(hubHealthBytes_(stable_(op))<=HUB_HEALTH_P6_LIMIT_.bytes,'HEALTH_REQUEST_TOO_LARGE');
  const p=op.payload;hubHealthKeys_(p,['id','metric','added','deletedIDs','affectedDates','statistics'],['id','metric','added','deletedIDs','affectedDates']);
  ensure_(p.id===op.operation_id,'HEALTH_INVALID_ID');hubHealthMetric_(p.metric);
  const statistics=Object.prototype.hasOwnProperty.call(p,'statistics')?p.statistics:[];ensure_(Array.isArray(p.added) && Array.isArray(p.deletedIDs) && Array.isArray(p.affectedDates) && Array.isArray(statistics),'HEALTH_INVALID_ARRAY');
  ensure_(p.added.length+p.deletedIDs.length+statistics.length<=HUB_HEALTH_P6_LIMIT_.records,'HEALTH_RECORD_LIMIT');
  const dates=new Set();for(const date of p.affectedDates){hubHealthDate_(date);ensure_(!dates.has(date),'HEALTH_DUPLICATE_DATE');dates.add(date);}
  const ids=new Set(),required=new Set(),added=p.added.map(s=>{
    const sample=hubHealthValidateSample_(s,p.metric);ensure_(!ids.has(sample.id),'HEALTH_DUPLICATE_ID');ids.add(sample.id);
    // 宣言された日数より広い区間を展開しない。削除以外の影響日を省略させない。
    if(sample.metric!=='sleepAnalysis')ensure_(Math.ceil((sample.end_utc-Date.parse(hubHealthLocalDate_(sample.start_utc)+'T00:00:00+09:00')/1000)/86400)<=Math.max(1,dates.size),'HEALTH_AFFECTED_DATES_MISMATCH');
    for(const date of hubHealthAffectedDates_(sample))required.add(date);return sample;
  });
  const deletedIDs=p.deletedIDs.map(id=>{ensure_(hubIsId_(id),'HEALTH_INVALID_ID');id=id.toLowerCase();ensure_(!ids.has(id),'HEALTH_DUPLICATE_ID');ids.add(id);return id;});
  const statisticDates=new Set(),stats=statistics.map(s=>{
    const stat=hubHealthValidateStatistic_(s,p.metric);ensure_(!statisticDates.has(stat.date),'HEALTH_DUPLICATE_STATISTIC');statisticDates.add(stat.date);required.add(stat.date);return stat;
  });
  ensure_([...required].every(d=>dates.has(d)) && (deletedIDs.length>0 || required.size===dates.size),'HEALTH_AFFECTED_DATES_MISMATCH');
  if(!op.synthetic) {
    ensure_(policy.health_real_enabled,'REAL_DATA_DISABLED');ensure_(policy.health_metrics.includes(p.metric),'HEALTH_METRIC_NOT_APPROVED');
    ensure_(policy.health_from!==null && [...required].every(date=>date>=policy.health_from),'HEALTH_PERIOD_NOT_APPROVED');
  }
  return {id:p.id,metric:p.metric,added,deletedIDs,affectedDates:[...dates].sort(),statistics:stats};
}
function hubHealthJSONL_(rows) {
  ensure_(Array.isArray(rows) && rows.length<=HUB_HEALTH_P6_LIMIT_.records,'HEALTH_RECORD_LIMIT');hubHealthFiniteJSON_(rows);
  const body=rows.map(stable_).map(line=>line+'\n').join(''),bytes=hubHealthBytes_(body);
  ensure_(bytes<=HUB_HEALTH_P6_LIMIT_.bytes,'HEALTH_REQUEST_TOO_LARGE');return {body,count:rows.length,sha256:hubHash_(body),bytes};
}
function hubHealthParseJSONL_(body,metadata) {
  ensure_(typeof body==='string','HEALTH_INVALID_JSONL');hubHealthKeys_(metadata,['raw_sha256','raw_bytes','record_count']);
  ensure_(typeof metadata.raw_sha256==='string' && /^[0-9a-f]{64}$/.test(metadata.raw_sha256),'HEALTH_INVALID_HASH');
  ensure_(Number.isSafeInteger(metadata.raw_bytes) && metadata.raw_bytes>=0 && metadata.raw_bytes<=HUB_HEALTH_P6_LIMIT_.bytes && Number.isSafeInteger(metadata.record_count) && metadata.record_count>=0 && metadata.record_count<=HUB_HEALTH_P6_LIMIT_.records,'HEALTH_INVALID_MANIFEST');
  ensure_(hubHealthBytes_(body)===metadata.raw_bytes,'HEALTH_BYTES_MISMATCH');ensure_(hubHash_(body)===metadata.raw_sha256,'HEALTH_HASH_MISMATCH');
  ensure_(body==='' || body.endsWith('\n') && !body.includes('\r'),'HEALTH_INVALID_JSONL');
  const lines=body===''?[]:body.slice(0,-1).split('\n');ensure_(lines.length===metadata.record_count,'HEALTH_RECORD_COUNT_MISMATCH');
  return lines.map(line=>{ensure_(line.length>0,'HEALTH_INVALID_JSONL');let row;try{row=JSON.parse(line);}catch(_){throw Error('HEALTH_INVALID_JSONL');}hubHealthFiniteJSON_(row);return row;});
}
