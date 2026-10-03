// 通知本文/再通知抑制・期限・部分予約失敗・既存トリガー保護を模擬する。
const fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/server-test.cjs','utf8').split("test('B2 normal set")[0];
const tests=String.raw`
vm.runInContext(fs.readFileSync(__dirname+'/Maintenance.gs','utf8'),ctx);
const originalNotify=ctx.hubNotifyReviews_;
const now21=Date.parse('2026-10-02T12:01:00Z'),now20=Date.parse('2026-10-02T11:59:00Z');
const open={id:'review-1',status:'未対応',notified_at:null,message:'秘密の食事名123kcal',reason:'private reason'};
test('notification sends only counts and fresh reviews take precedence over reminders',()=>{
 const p=ctx.hubNotificationPlan_([open,{...open,id:'r2',status:'本人確認済み'}],'',now21);assert.equal(p.kind,'new');assert.deepEqual(copy(p.ids),['review-1']);assert.ok(p.subject.includes('1件'));assert.ok(!JSON.stringify([p.subject,p.body]).includes(open.message));assert.ok(!p.body.includes(open.id));
});
test('reminders start after21JST and repeat at most once per JST date',()=>{
 const rows=[{...open,notified_at:'2026-10-02T00:00:00Z'}];assert.equal(ctx.hubNotificationPlan_(rows,'',now20),null);assert.equal(ctx.hubNotificationPlan_(rows,'',now21).kind,'reminder');assert.equal(ctx.hubNotificationPlan_(rows,'2026-10-02',now21),null);assert.equal(ctx.hubNotificationPlan_([], '',now21),null);
});
let triggers=[],next=0,failHandler='',deleted=[];const props=new Map();
ctx.PropertiesService={getScriptProperties:()=>({getProperty:k=>props.get(k) || null,setProperty:(k,v)=>props.set(k,v)})};
ctx.ScriptApp={getProjectTriggers:()=>triggers.slice(),deleteTrigger:t=>{deleted.push(t.name);triggers=triggers.filter(x=>x!==t);},newTrigger:name=>({timeBased(){return this;},everyMinutes(n){assert.equal(n,5);return this;},at(date){assert.ok(date instanceof Date || Number.isFinite(date.getTime()));return this;},create(){if(name===failHandler)throw Error('trigger creation failed');const t={name,id:++next,getHandlerFunction:()=>name};triggers.push(t);return t;}})};
ctx.hubConfig_=()=>({environment:'PHH_TEST',real_data_enabled:false});ctx.hubCheckACL_=()=>{};ctx.hubCheckBookEnvs_=()=>{};

test('email adapter saves numeric notification timestamps, rejects wrong recipient and preserves state after send failure',()=>{
 const s=fresh();s.config.chat='c@example.test';s.seed('Reviews',{id:'review-1',intake_id:'synthetic-1',sheet_row:2,reason:'private',message:'private body',created_at:now,status:'未対応',resolution:null,notified_at:null,renotified_date:null});
 const run=ctx.hubRun_;ctx.hubRun_=(_,work)=>{const r=work(s);s.commit();return r;};let sent=[];
 ctx.MailApp={getRemainingDailyQuota:()=>100,sendEmail:(to,subject,body)=>sent.push({to,subject,body})};
 try {
  assert.equal(ctx.hubNotifyReviews_().configured,false);props.set('PHH_NOTIFY_TO','wrong@example.test');assert.throws(()=>ctx.hubNotifyReviews_(),/NOTIFY_RECIPIENT/);assert.equal(sent.length,0);
  props.set('PHH_NOTIFY_TO',s.config.chat);ctx.MailApp.sendEmail=()=>{throw Error('mail failure');};assert.throws(()=>ctx.hubNotifyReviews_(),/mail failure/);assert.equal(s.get('Reviews','review-1').notified_at,null);
  ctx.MailApp.sendEmail=(to,subject,body)=>sent.push({to,subject,body});const result=ctx.hubNotifyReviews_();assert.equal(result.mailed,1);assert.equal(typeof s.get('Reviews','review-1').notified_at,'number');assert.ok(!JSON.stringify(sent).includes('private body'));assert.ok(!JSON.stringify(sent).includes('review-1'));
 } finally {ctx.hubRun_=run;}
});
test('bounded start creates exactly two managed triggers and preserves an unrelated one',()=>{
 triggers=[{name:'existingExpiry',getHandlerFunction:()=> 'existingExpiry'}];const r=ctx.startHubMaintenance();assert.equal(r.interval_minutes,5);assert.equal(props.get('PHH_MAINTENANCE_STOP'),'');assert.equal(Date.parse(r.until)-Date.parse(r.started_at),24*3600000);assert.equal(triggers.length,3);assert.throws(()=>ctx.startHubMaintenance(),/MAINTENANCE_ALREADY_RUNNING/);
 const stop=ctx.stopHubMaintenance();assert.equal(stop.triggers_remaining,0);assert.equal(triggers.length,1);assert.equal(triggers[0].name,'existingExpiry');assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'0');
});
test('invalid durations and real-data setup create no triggers',()=>{
 for(const h of [0,25,Infinity,NaN,-1])assert.throws(()=>ctx.startHubMaintenance(h),/INVALID_DURATION/);
 assert.equal(triggers.length,1);
});
test('second trigger creation failure removes only the partial managed reservation',()=>{
 failHandler='stopHubMaintenance';try{assert.throws(()=>ctx.startHubMaintenance(),/trigger creation failed/);}finally{failHandler='';}assert.equal(triggers.length,1);assert.equal(triggers[0].name,'existingExpiry');assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'0');
});
test('expired tick never processes rows or sends email',()=>{
 let processed=0;ctx.hubMaintenanceIntake_=()=>{processed++;};props.set('PHH_MAINTENANCE_UNTIL','1');ctx.tickHubMaintenance();assert.equal(processed,0);
});
test('normal tick publishes first, then notifies and backs up once per date',()=>{
 const calls=[];props.set('PHH_MAINTENANCE_UNTIL',String(Date.now()+3600000));props.set('PHH_MAINTENANCE_RUNTIME_MS','0');props.delete('PHH_BACKUP_DAY');ctx.hubMaintenanceIntake_=()=>{calls.push('intake');return {processed:2,publication_pending:true,needs_notification:true};};ctx.publishHubResults=()=>calls.push('publish');ctx.hubNotifyReviews_=()=>{calls.push('notify');return {mailed:0};};ctx.hubCreateBackup_=()=>calls.push('backup');ctx.hubRun_=(_,work)=>work({config:{environment:'PHH_TEST',owner:'s@example.test',real_data_enabled:false}});ctx.hubBackupRoot_=()=>({});ctx.hubBackupPrune_=()=>calls.push('retention');ctx.tickHubMaintenance();assert.deepEqual(calls,['intake','publish','notify','backup','retention']);calls.length=0;ctx.tickHubMaintenance();assert.deepEqual(calls,['intake','publish','notify']);
});
test('no new review before21 skips repeated publication and notification calls',()=>{ctx.hubMaintenanceIntake_=()=>({processed:0,publication_pending:false,needs_notification:false});ctx.hubNotifyReviews_=()=>{throw Error('unneeded mail call');};assert.equal(ctx.tickHubMaintenance().mailed,0);});
test('configured derived cleanup runs in the normal tick without adding triggers',()=>{
 const before=triggers.length;let calls=0;props.set('PHH_QUERY_ROOT_ID','derived-root');ctx.runHubExpiryCleanup=()=>{calls++;};
 try {ctx.tickHubMaintenance();assert.equal(calls,1);assert.equal(triggers.length,before);}finally{props.delete('PHH_QUERY_ROOT_ID');}
});
test('60minute budget or a failed backup preserves diagnostics and stops or retries appropriately',()=>{
 props.set('PHH_MAINTENANCE_RUNTIME_MS',String(60*60000));ctx.tickHubMaintenance();assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'0');
 props.set('PHH_MAINTENANCE_UNTIL',String(Date.now()+3600000));props.set('PHH_MAINTENANCE_RUNTIME_MS','0');props.delete('PHH_BACKUP_DAY');ctx.hubCreateBackup_=()=>{throw Error('Drive unavailable');};assert.throws(()=>ctx.tickHubMaintenance(),/Drive unavailable/);assert.ok(!props.has('PHH_BACKUP_DAY'));assert.ok(props.has('PHH_MAINTENANCE_RUNTIME_MS'));
});

test('corrupt persisted deadline or runtime stops managed triggers before any intake, mail or backup',()=>{
 for(const [key,value] of [['PHH_MAINTENANCE_UNTIL','NaN'],['PHH_MAINTENANCE_UNTIL','Infinity'],['PHH_MAINTENANCE_RUNTIME_MS','bad'],['PHH_MAINTENANCE_RUNTIME_MS','-1']]){
  props.set('PHH_MAINTENANCE_UNTIL',String(Date.now()+3600000));props.set('PHH_MAINTENANCE_RUNTIME_MS','0');props.set(key,value);
  triggers=[{name:'tickHubMaintenance',getHandlerFunction:()=> 'tickHubMaintenance'},{name:'stopHubMaintenance',getHandlerFunction:()=> 'stopHubMaintenance'},{name:'existingExpiry',getHandlerFunction:()=> 'existingExpiry'}];
  let calls=0;ctx.hubMaintenanceIntake_=()=>{calls++;};ctx.hubNotifyReviews_=()=>{calls++;};ctx.hubCreateBackup_=()=>{calls++;};
  assert.throws(()=>ctx.tickHubMaintenance(),/MAINTENANCE_STATE/);assert.equal(calls,0);assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'0');assert.equal(triggers.length,1);assert.equal(triggers[0].name,'existingExpiry');assert.equal(JSON.parse(props.get('PHH_MAINTENANCE_STOP')).triggers_remaining,0);
 }
});

test('notification quota refusal and post-send commit failure leave the same review eligible for retry',()=>{
 const s=fresh();s.config.chat='c@example.test';s.seed('Reviews',{id:'synthetic-review',intake_id:'synthetic-intake',sheet_row:2,reason:'private',message:'synthetic private body',created_at:now,status:'未対応',resolution:null,notified_at:null,renotified_date:null});
 const run=ctx.hubRun_,mail=ctx.MailApp,notify=ctx.hubNotifyReviews_;ctx.hubNotifyReviews_=originalNotify;ctx.hubRun_=(_,work)=>{const result=work(s);s.commit();return result;};props.set('PHH_NOTIFY_TO',s.config.chat);let sent=0,quota=0;
 ctx.MailApp={getRemainingDailyQuota:()=>quota,sendEmail:()=>sent++};
 try {
  assert.throws(()=>ctx.hubNotifyReviews_(),/NOTIFY_QUOTA/);assert.equal(sent,0);assert.equal(s.get('Reviews','synthetic-review').notified_at,null);
  quota=1;s.fail=true;assert.throws(()=>ctx.hubNotifyReviews_(),/STORAGE_UNAVAILABLE/);assert.equal(sent,1);assert.equal(s.get('Reviews','synthetic-review').notified_at,null);
  s.fail=false;assert.equal(ctx.hubNotifyReviews_().mailed,1);assert.equal(sent,2);assert.equal(typeof s.get('Reviews','synthetic-review').notified_at,'number');
 }finally{ctx.hubRun_=run;ctx.MailApp=mail;ctx.hubNotifyReviews_=notify;}
});

test('persisted runtime at or above60minutes stops before intake, publication, mail and backup',()=>{
 for(const runtime of [60*60000,60*60000+1]){
  props.set('PHH_MAINTENANCE_UNTIL',String(Date.now()+3600000));props.set('PHH_MAINTENANCE_RUNTIME_MS',String(runtime));
  triggers=[{name:'tickHubMaintenance',getHandlerFunction:()=> 'tickHubMaintenance'},{name:'stopHubMaintenance',getHandlerFunction:()=> 'stopHubMaintenance'},{name:'existingExpiry',getHandlerFunction:()=> 'existingExpiry'}];let calls=0;
  ctx.hubMaintenanceIntake_=()=>{calls++;};ctx.publishHubResults=()=>{calls++;};ctx.hubNotifyReviews_=()=>{calls++;};ctx.hubCreateBackup_=()=>{calls++;};ctx.runHubExpiryCleanup=()=>{calls++;};
  const result=ctx.tickHubMaintenance();assert.equal(result.stopped,true);assert.equal(result.triggers_remaining,0);assert.equal(calls,0);assert.equal(triggers.length,1);assert.equal(triggers[0].name,'existingExpiry');assert.equal(props.get('PHH_MAINTENANCE_RUNTIME_MS'),String(runtime));
 }
});
console.log('Hub maintenance: '+passed+' PASSED');
test('continuous maintenance never stops, resets the budget each JST day, thins after45 minutes and rests after80',()=>{
 triggers=[];props.set('PHH_MAINTENANCE_UNTIL','continuous');let runs=0;ctx.hubMaintenanceIntake_=()=>{runs++;return {processed:0,publication_pending:false,needs_notification:false};};ctx.hubCreateBackup_=()=>({});ctx.hubBackupPrune_=()=>{};ctx.hubBackupRoot_=()=>({});
 const day=ctx.intakeJstDate_(Date.now());props.set('PHH_BACKUP_DAY',day);props.set('PHH_BACKUP_PRUNE_DAY',day);
 props.set('PHH_MAINTENANCE_DAY','2000-01-01');props.set('PHH_MAINTENANCE_RUNTIME_MS',String(90*60000));ctx.tickHubMaintenance();assert.equal(runs,1);assert.equal(props.get('PHH_MAINTENANCE_DAY'),day);
 props.set('PHH_MAINTENANCE_RUNTIME_MS',String(81*60000));assert.equal(ctx.tickHubMaintenance().skipped,'daily_budget');assert.equal(runs,1);assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'continuous');
 props.set('PHH_MAINTENANCE_RUNTIME_MS',String(50*60000));const r=ctx.tickHubMaintenance();assert.ok(r.skipped==='thinned' || runs===2);assert.equal(props.get('PHH_MAINTENANCE_UNTIL'),'continuous');
});
test('a failed prune keeps the day mark so the next tick does not create another full backup',()=>{
 props.set('PHH_MAINTENANCE_UNTIL','continuous');props.set('PHH_MAINTENANCE_RUNTIME_MS','0');props.delete('PHH_BACKUP_DAY');props.delete('PHH_BACKUP_PRUNE_DAY');
 let created=0;ctx.hubCreateBackup_=()=>{created++;return {};};ctx.hubBackupPrune_=()=>{throw Error('prune failed');};ctx.hubMaintenanceIntake_=()=>({processed:0,publication_pending:false,needs_notification:false});
 assert.throws(()=>ctx.tickHubMaintenance(),/prune failed/);ctx.hubBackupPrune_=()=>{};ctx.tickHubMaintenance();assert.equal(created,1);
});

`;
vm.runInNewContext(source+tests,{require,console,Buffer,__dirname});
