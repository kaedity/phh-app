const fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const copy=v=>JSON.parse(JSON.stringify(v)),id=n=>'00000000-0000-4000-a000-'+String(n).padStart(12,'0');
const now=Date.parse('2026-10-03T01:00:00Z'),utc=v=>Date.parse(v)/1000;
const ctx=vm.createContext({console,Utilities:{DigestAlgorithm:{SHA_256:'sha256'},Charset:{UTF_8:'utf8'},computeDigest:(_,v)=>[...crypto.createHash('sha256').update(v).digest()],getUuid:()=>crypto.randomUUID(),newBlob:v=>({getBytes:()=>[...Buffer.from(v)]})}});
vm.runInContext(['Core.gs','HealthP6.gs'].map(n=>fs.readFileSync(__dirname+'/'+n,'utf8')).join('\n'),ctx);
const p5=JSON.parse(fs.readFileSync(__dirname+'/../Core/Sources/PHHHubCore/Resources/planning-p5-schema.json','utf8')),schema=copy(ctx.hubHealthP6Schema_(p5));
const source={id:'synthetic.example.device',name:'架空の情報源',device:null};
function sample(metric='bodyMass',n=1,extra={}) {
  return {id:id(n),metric,source:copy(source),start_utc:utc('2026-10-02T16:00:00Z'),end_utc:utc('2026-10-02T16:00:00Z'),value:metric==='bodyFatPercentage'?0.2:metric==='sleepAnalysis'?null:metric==='stepCount'?100:65,unit:ctx.hubHealthMetric_(metric).unit,sleepStage:null,...(metric==='sleepAnalysis'?{end_utc:utc('2026-10-02T23:00:00Z'),sleepStage:'asleep'}:{}),...extra};
}
function operation(metric='bodyMass',extra={}) {
  const s=sample(metric);return {schema_version:1,environment:'PHH_TEST',synthetic:true,approval_state:'confirmed',operation_id:id(900),entity_id:id(900),expected_revision:0,action:'save_health_delta',payload:{id:id(900),metric,added:[s],deletedIDs:[],affectedDates:copy(ctx.hubHealthAffectedDates_(s))},...extra};
}
const statistic=(metric='stepCount',date='2026-10-03',value=100)=>({metric,date,value,unit:ctx.hubHealthMetric_(metric).unit,method:'healthkit-statistics-v1',measured_at_utc:now/1000});
const manifest=j=>({raw_sha256:j.sha256,raw_bytes:j.bytes,record_count:j.count});
const rejected=(op,mutate,pattern,config)=>{const bad=copy(op);mutate(bad);assert.throws(()=>ctx.hubHealthValidateDelta_(bad,config),pattern);};
function runTests() {
  let passed=0;const test=(name,f)=>{f();passed++;console.log('ok '+name);};
  test('P5 migration preserves every old table and adds exactly four typed metadata tables',()=>{
    const names=['HealthBatches','HealthArchives','HealthDaily','HealthPreparations'];assert.equal(Object.keys(schema.tables).length,36);assert.equal(schema.health_real_enabled_default,false);
    assert.deepEqual(schema,JSON.parse(fs.readFileSync(__dirname+'/health-p6-schema.json','utf8')));
    for(const name of Object.keys(p5.tables))assert.deepEqual(schema.tables[name],p5.tables[name]);
    const fields={HealthBatches:'metric request_hash added_count deleted_count statistics_count file_id raw_sha256 gzip_sha256 raw_bytes gzip_bytes record_count format_version',HealthArchives:'kind metric partition_key source_id local_date part_number file_id raw_sha256 gzip_sha256 raw_bytes gzip_bytes record_count active_count format_version',HealthDaily:'metric local_date source_id value unit method measured_at_utc known_count unknown_count minimum maximum representative_id sample_revision',HealthPreparations:'operation_id request_hash kind partition_key part_number stage file_id raw_sha256 raw_bytes record_count gzip_sha256 gzip_bytes'};
    for(const name of names){const table=schema.tables[name];assert.deepEqual(table.columns.slice(0,7),p5.tables.Meals.columns.slice(0,7));assert.deepEqual(table.columns.slice(7).map(c=>c.name),fields[name].split(' '));assert.equal(new Set(table.columns.map(c=>c.name)).size,table.columns.length);}
    assert.deepEqual(schema.tables.HealthArchives.indexes,[['id'],['partition_key'],['kind'],['metric'],['local_date']]);
    assert.deepEqual(schema.tables.HealthDaily.indexes,[['id'],['local_date'],['metric']]);assert.deepEqual(schema.tables.HealthPreparations.indexes,[['id'],['operation_id'],['stage']]);
    assert.equal(schema.tables.HealthDaily.columns.find(c=>c.name==='value').nullable,true);assert.equal(schema.tables.HealthPreparations.columns.find(c=>c.name==='file_id').nullable,true);
    const books=Object.fromEntries(Object.keys(p5.tables).map(t=>[t,[]]));books.Meals=[Object.fromEntries(p5.tables.Meals.columns.map(c=>[c.name,c.nullable?null:c.type==='integer'?1:c.type==='number'?0:c.type==='boolean'?false:c.name==='id'?id(1):'架空保全']))];
    const before=copy(books),result=copy(ctx.hubHealthP6MigrationPlan_(p5,books));assert.equal(result.source_tables,32);assert.equal(result.target_tables,36);assert.deepEqual(books,before);
    for(const name of Object.keys(books))assert.deepEqual(result.books[name],books[name]);for(const name of names)assert.deepEqual(result.books[name],[]);
    result.books.Meals[0].name='独立';assert.deepEqual(books,before);
  });
  test('migration rejects missing extra duplicate malformed rows without changing source',()=>{
    const empty=()=>Object.fromEntries(Object.keys(p5.tables).map(t=>[t,[]]));
    for(const mutate of [b=>delete b.Meals,b=>b.Unexpected=[],b=>b.Meals={},b=>b.Meals=[{id:id(1)}],b=>b.Settings=[{id:'x',value_type:'number',string_value:null,number_value:Infinity,bool_value:null,revision:1,updated_at:'x'}]]){const b=empty();mutate(b);assert.throws(()=>ctx.hubHealthP6MigrationPlan_(p5,b));}
    const b=empty();b.Settings=[{id:'x',value_type:'number',string_value:null,number_value:0,bool_value:null,revision:1,updated_at:'x'}];b.Settings.push(copy(b.Settings[0]));const before=copy(b);assert.throws(()=>ctx.hubHealthP6MigrationPlan_(p5,b),/MIGRATION_DUPLICATE_ID/);assert.deepEqual(b,before);
    assert.throws(()=>ctx.hubHealthP6Schema_(schema),/P6_SOURCE_SCHEMA/);
  });
  test('all eight metrics use fixed units and cumulative declarations',()=>{
    const units={bodyMass:'kg',bodyFatPercentage:'fraction',bodyMassIndex:'count',leanBodyMass:'kg',stepCount:'count',activeEnergyBurned:'kcal',basalEnergyBurned:'kcal',sleepAnalysis:'interval'};
    for(const [metric,unit]of Object.entries(units)){assert.deepEqual(copy(ctx.hubHealthMetric_(metric)),{unit,cumulative:['stepCount','activeEnergyBurned','basalEnergyBurned'].includes(metric)});assert.equal(ctx.hubHealthValidateDelta_(operation(metric)).metric,metric);}
    for(const metric of ['height','constructor','__proto__',null,1])assert.throws(()=>ctx.hubHealthMetric_(metric),/HEALTH_INVALID_METRIC/);
  });
  test('JST day intervals cross leap month year boundaries and exclude exact midnight ends',()=>{
    const s=(start,end)=>sample('stepCount',1,{start_utc:utc(start),end_utc:utc(end)});
    assert.deepEqual(copy(ctx.hubHealthAffectedDates_(s('2026-10-02T14:59:59Z','2026-10-02T15:00:00Z'))),['2026-10-02']);
    assert.deepEqual(copy(ctx.hubHealthAffectedDates_(s('2026-10-02T14:59:59Z','2026-10-02T15:00:00.001Z'))),['2026-10-02','2026-10-03']);
    assert.deepEqual(copy(ctx.hubHealthAffectedDates_(s('2028-02-28T15:00:00Z','2028-03-01T15:00:00Z'))),['2028-02-29','2028-03-01']);
    assert.deepEqual(copy(ctx.hubHealthAffectedDates_(s('2026-12-31T14:00:00Z','2027-01-01T16:00:00Z'))),['2026-12-31','2027-01-01','2027-01-02']);
    assert.deepEqual(copy(ctx.hubHealthAffectedDates_(sample('sleepAnalysis',1,{start_utc:utc('2026-10-01T14:00:00Z'),end_utc:utc('2026-10-03T15:00:00Z')}))),['2026-10-04']);
  });
  test('sample validators preserve unknown values and normalize optional fields UUID casing',()=>{
    const o=operation();delete o.payload.added[0].value;delete o.payload.added[0].sleepStage;delete o.payload.added[0].source.device;o.payload.added[0].id=id(0).toUpperCase();
    const before=copy(o),p=copy(ctx.hubHealthValidateDelta_(o));assert.equal(p.added[0].value,null);assert.equal(p.added[0].source.device,null);assert.equal(p.added[0].sleepStage,null);assert.deepEqual(p.statistics,[]);assert.deepEqual(o,before);
    o.payload.added[0].value=0;assert.equal(ctx.hubHealthValidateDelta_(o).added[0].value,0);
  });
  test('envelope requires fixed action matching ids confirmed state schema revision and environment',()=>{
    for(const mutate of [o=>o.schema_version=2,o=>o.environment='unknown',o=>o.action='ingest_health_batch',o=>o.expected_revision=1,o=>o.expected_revision='0',o=>o.approval_state='draft',o=>o.operation_id='bad',o=>o.entity_id=id(901),o=>o.payload.id=id(902),o=>o.synthetic='true',o=>o.anchor='private',o=>delete o.payload.added])rejected(operation(),mutate);
    assert.throws(()=>ctx.hubHealthValidateDelta_(operation(),{environment:'PHH_PRODUCTION'}),/ENVIRONMENT_MISMATCH/);
    const o=operation('bodyMass',{environment:'PHH_PRODUCTION'});assert.equal(ctx.hubHealthValidateDelta_(o).added.length,1);
  });
  test('source numeric units time stages and unexpected fields are rejected before normalization',()=>{
    for(const mutate of [o=>o.payload.added[0].metric='leanBodyMass',o=>o.payload.added[0].unit='lb',o=>o.payload.added[0].id='bad',o=>o.payload.added[0].value=-1,o=>o.payload.added[0].value='65',o=>o.payload.added[0].end_utc=0,o=>o.payload.added[0].start_utc='1',o=>o.payload.added[0].source.name='',o=>o.payload.added[0].source.id=4,o=>o.payload.added[0].source.device=12,o=>o.payload.added[0].source.id='x'.repeat(501),o=>o.payload.added[0].sleepStage='core',o=>o.payload.added[0].extra=true])rejected(operation(),mutate);
    rejected(operation('bodyFatPercentage'),o=>o.payload.added[0].value=1.01,/HEALTH_INVALID_VALUE/);rejected(operation('stepCount'),o=>o.payload.added[0].value=1.2,/HEALTH_INVALID_VALUE/);
    for(const mutate of [o=>o.payload.added[0].value=0,o=>o.payload.added[0].sleepStage='unknown',o=>o.payload.added[0].end_utc=o.payload.added[0].start_utc])rejected(operation('sleepAnalysis'),mutate,/HEALTH_INVALID_SLEEP/);
    for(const stage of ['inBed','awake','asleep','core','deep','rem']){const o=operation('sleepAnalysis');o.payload.added[0].sleepStage=stage;assert.equal(ctx.hubHealthValidateDelta_(o).added[0].sleepStage,stage);}
  });
  test('UUID duplicates across additions deletions and mixed casing reject',()=>{
    rejected(operation(),o=>o.payload.added.push(copy(o.payload.added[0])),/HEALTH_DUPLICATE_ID/);
    rejected(operation(),o=>o.payload.deletedIDs=[o.payload.added[0].id.toUpperCase()],/HEALTH_DUPLICATE_ID/);
    rejected(operation(),o=>o.payload.deletedIDs=[id(2),id(2).toUpperCase()],/HEALTH_DUPLICATE_ID/);
    rejected(operation(),o=>o.payload.deletedIDs=['not UUID'],/HEALTH_INVALID_ID/);
  });
  test('affected dates validate calendar uniqueness inclusion and forbid unrelated added-only days',()=>{
    for(const value of ['2026-02-30','2026-2-03','0000-01-01','2026-10-03x',3])rejected(operation(),o=>o.payload.affectedDates=[value],/HEALTH_INVALID_DATE/);
    rejected(operation(),o=>o.payload.affectedDates=[],/HEALTH_AFFECTED_DATES_MISMATCH/);
    rejected(operation(),o=>o.payload.affectedDates.push(o.payload.affectedDates[0]),/HEALTH_DUPLICATE_DATE/);
    rejected(operation(),o=>o.payload.affectedDates.push('2026-10-04'),/HEALTH_AFFECTED_DATES_MISMATCH/);
    const o=operation();o.payload.deletedIDs=[id(2)];o.payload.affectedDates=['2026-10-04','2026-10-03'];assert.deepEqual(copy(ctx.hubHealthValidateDelta_(o).affectedDates),['2026-10-03','2026-10-04']);
    const long=operation('stepCount');long.payload.added[0].end_utc=utc('9999-12-31T00:00:00Z');assert.throws(()=>ctx.hubHealthValidateDelta_(long),/HEALTH_AFFECTED_DATES_MISMATCH/);
  });
  test('statistics use only HealthKit cumulative results and never replace unknown with zero',()=>{
    for(const metric of ['stepCount','activeEnergyBurned','basalEnergyBurned']){const o=operation(metric);o.payload.statistics=[statistic(metric,'2026-10-03',null)];assert.equal(ctx.hubHealthValidateDelta_(o).statistics[0].value,null);o.payload.statistics[0].value=0;assert.equal(ctx.hubHealthValidateDelta_(o).statistics[0].value,0);}
    const o=operation('stepCount');o.payload.statistics=[statistic()];
    for(const mutate of [x=>x.payload.statistics[0].metric='activeEnergyBurned',x=>x.payload.statistics[0].date='2026-02-30',x=>x.payload.statistics[0].unit='steps',x=>x.payload.statistics[0].method='sum-samples',x=>x.payload.statistics[0].measured_at_utc='now',x=>x.payload.statistics[0].value=1.5,x=>x.payload.statistics[0].hidden=1,x=>x.payload.statistics=null,x=>x.payload.statistics.push(copy(x.payload.statistics[0]))])rejected(o,mutate);
    rejected(o,x=>x.payload.statistics[0].date='2026-10-04',/HEALTH_AFFECTED_DATES_MISMATCH/);
    const body=operation();body.payload.statistics=[statistic('bodyMass')];assert.throws(()=>ctx.hubHealthValidateDelta_(body),/HEALTH_STATISTICS_METRIC/);
  });
  test('real health policy defaults disabled and independently requires metric and every added day',()=>{
    const o=operation('bodyMass',{synthetic:false}),config={environment:'PHH_TEST',real_data_enabled:false,health_real_enabled:true,health_metrics:['bodyMass'],health_from:'2026-10-03'};
    assert.throws(()=>ctx.hubHealthValidateDelta_(o),/REAL_DATA_DISABLED/);assert.equal(ctx.hubHealthValidateDelta_(o,config).metric,'bodyMass');
    const independent=copy(config);delete independent.real_data_enabled;assert.equal(ctx.hubHealthValidateDelta_(o,independent).metric,'bodyMass');
    for(const mutate of [c=>delete c.health_real_enabled,c=>c.health_real_enabled=false,c=>c.health_metrics=[],c=>c.health_from='2026-10-04',c=>delete c.health_from]){const c=copy(config);mutate(c);assert.throws(()=>ctx.hubHealthValidateDelta_(o,c));}
    const cross=operation('stepCount',{synthetic:false});cross.payload.added[0].start_utc=utc('2026-10-02T14:00:00Z');cross.payload.affectedDates=['2026-10-02','2026-10-03'];assert.throws(()=>ctx.hubHealthValidateDelta_(cross,{...config,health_metrics:['stepCount']}),/HEALTH_PERIOD_NOT_APPROVED/);
    const sleep=operation('sleepAnalysis',{synthetic:false});sleep.payload.added[0].start_utc=utc('2026-10-01T16:00:00Z');assert.equal(ctx.hubHealthValidateDelta_(sleep,{...config,health_metrics:['sleepAnalysis']}).metric,'sleepAnalysis');
  });
  test('real statistics obey approved period while unknown deletions can have no affected day',()=>{
    const config={real_data_enabled:false,health_real_enabled:true,health_metrics:['stepCount'],health_from:'2026-10-03'};
    const o=operation('stepCount',{synthetic:false});o.payload.added=[];o.payload.deletedIDs=[id(8)];o.payload.affectedDates=[];
    assert.equal(ctx.hubHealthValidateDelta_(o,config).deletedIDs[0],id(8));assert.throws(()=>ctx.hubHealthValidateDelta_(o,{...config,health_metrics:[]}),/HEALTH_METRIC_NOT_APPROVED/);
    o.payload.statistics=[statistic('stepCount','2026-10-02')];o.payload.affectedDates=['2026-10-02'];assert.throws(()=>ctx.hubHealthValidateDelta_(o,config),/HEALTH_PERIOD_NOT_APPROVED/);
    delete o.payload.statistics;assert.equal(ctx.hubHealthValidateDelta_(o,config).statistics.length,0);
  });
  test('policy fields reject type coercion unknown metrics duplicates and invalid dates',()=>{
    for(const config of [null,[],{real_data_enabled:'true'},{health_real_enabled:'true'},{health_metrics:null},{health_metrics:'bodyMass'},{health_metrics:['height']},{health_metrics:['bodyMass','bodyMass']},{health_from:'2026-02-30'}])assert.throws(()=>ctx.hubHealthValidateDelta_(operation(),config));
  });
  test('combined 500 item cap applies to additions deletions and statistics',()=>{
    const o=operation('stepCount');o.payload.added=[];o.payload.deletedIDs=Array.from({length:499},(_,i)=>id(i+1));o.payload.statistics=[statistic()];assert.equal(ctx.hubHealthValidateDelta_(o).deletedIDs.length,499);
    o.payload.deletedIDs.push(id(500));assert.throws(()=>ctx.hubHealthValidateDelta_(o),/HEALTH_RECORD_LIMIT/);
    const added=operation();added.payload.added=Array.from({length:500},(_,i)=>sample('bodyMass',i+1));assert.equal(ctx.hubHealthValidateDelta_(added).added.length,500);added.payload.added.push(sample('bodyMass',501));assert.throws(()=>ctx.hubHealthValidateDelta_(added),/HEALTH_RECORD_LIMIT/);
  });
  test('UTF8 request cap includes the envelope and rejects large text before planning',()=>{
    const o=operation();o.payload.added=Array.from({length:110},(_,i)=>sample('bodyMass',i+1,{source:{id:'a'.repeat(500),name:'架'.repeat(500),device:'b'.repeat(500)}}));assert.throws(()=>ctx.hubHealthValidateDelta_(o),/HEALTH_REQUEST_TOO_LARGE/);
  });
  test('JSONL exact UTF8 hash count and LF round trip known zero null and Unicode',()=>{
    const rows=[{id:id(1),name:'架空😀',value:0,unknown:null},{sample:sample('sleepAnalysis'),deleted:false}],j=copy(ctx.hubHealthJSONL_(rows));
    assert.equal(j.count,2);assert.equal(j.bytes,Buffer.byteLength(j.body));assert.equal(j.sha256,crypto.createHash('sha256').update(j.body).digest('hex'));assert.ok(j.body.endsWith('\n'));
    assert.deepEqual(copy(ctx.hubHealthParseJSONL_(j.body,manifest(j))),rows);
    const reversed=[{unknown:null,value:0,name:'架空😀',id:id(1)},rows[1]];assert.deepEqual(copy(ctx.hubHealthJSONL_(reversed)),j);
    const empty=copy(ctx.hubHealthJSONL_([]));assert.equal(empty.body,'');assert.deepEqual(copy(ctx.hubHealthParseJSONL_('',manifest(empty))),[]);
  });
  test('JSONL corruption hash manifest line endings malformed lines and nonfinite JSON reject',()=>{
    const j=copy(ctx.hubHealthJSONL_([{value:0}]));
    for(const metadata of [{...manifest(j),raw_sha256:'bad'},{...manifest(j),raw_sha256:'0'.repeat(64)},{...manifest(j),raw_bytes:j.bytes+1},{...manifest(j),record_count:2},{...manifest(j),record_count:'1'},{...manifest(j),raw_bytes:-1},{...manifest(j),extra:1}])assert.throws(()=>ctx.hubHealthParseJSONL_(j.body,metadata));
    const parse=body=>ctx.hubHealthParseJSONL_(body,{raw_sha256:crypto.createHash('sha256').update(body).digest('hex'),raw_bytes:Buffer.byteLength(body),record_count:1});
    for(const body of ['{}','{}\r\n','\n','{\n','{"value":1e400}\n'])assert.throws(()=>parse(body));
    for(const rows of [[{value:NaN}],[{value:Infinity}],[{value:undefined}],[{value:1n}],[{value:()=>0}],[new Date()],[,]])assert.throws(()=>ctx.hubHealthJSONL_(rows));
    const cycle={};cycle.self=cycle;assert.throws(()=>ctx.hubHealthJSONL_([cycle]),/HEALTH_INVALID_JSON/);
    const op=operation();op.payload.added[0].value=Infinity;assert.throws(()=>ctx.hubHealthValidateDelta_(op),/HEALTH_NONFINITE/);
  });
  test('JSONL exact byte and 500 line limits are enforced before parsing or encoding',()=>{
    const padding=204800-Buffer.byteLength('{"x":""}\n'),j=copy(ctx.hubHealthJSONL_([{x:'a'.repeat(padding)}]));assert.equal(j.bytes,204800);assert.equal(ctx.hubHealthParseJSONL_(j.body,manifest(j)).length,1);
    assert.throws(()=>ctx.hubHealthJSONL_([{x:'a'.repeat(padding+1)}]),/HEALTH_REQUEST_TOO_LARGE/);
    const lines=Array.from({length:500},(_,i)=>({i}));assert.equal(ctx.hubHealthJSONL_(lines).count,500);lines.push({i:500});assert.throws(()=>ctx.hubHealthJSONL_(lines),/HEALTH_RECORD_LIMIT/);
    assert.throws(()=>ctx.hubHealthParseJSONL_(j.body,{...manifest(j),record_count:501}),/HEALTH_INVALID_MANIFEST/);
  });
  console.log(`health P6: ${passed} passed`);return passed;
}
if(require.main===module) {
  if(process.argv.includes('--write-schema'))fs.writeFileSync(__dirname+'/health-p6-schema.json',JSON.stringify(schema,null,2)+'\n');
  runTests();
}
module.exports={ctx,copy,id,now,utc,p5,schema,source,sample,operation,statistic,manifest,runTests};
