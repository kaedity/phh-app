// P2-6：承認済みの件数通知と期限付き5分処理。実データはまだ拒否する。
function hubNotificationPlan_(reviews,lastReminder,now) {
  const open=reviews.filter(r=>r.status==='未対応'),fresh=open.filter(r=>!r.notified_at),today=intakeJstDate_(now),hour=new Date(now+9*3600000).getUTCHours();
  if(fresh.length)return {kind:'new',ids:fresh.map(r=>r.id),subject:'【PHH】要確認が'+fresh.length+'件あります',body:'自動で保存できなかった記録が'+fresh.length+'件あります（未対応は合計'+open.length+'件）。\n内容は結果ブックの「要確認」で確認してください。'};
  if(open.length && hour>=21 && lastReminder!==today)return {kind:'reminder',ids:open.map(r=>r.id),subject:'【PHH】未対応の要確認が'+open.length+'件残っています',body:'未対応の要確認が'+open.length+'件残っています。\n内容は結果ブックの「要確認」で確認してください。'};
  return null;
}
function hubNotifyReviews_() {
  return hubRun_(null,store=>{
    ensure_(!store.config.real_data_enabled,'REAL_DATA_DISABLED');
    const to=PropertiesService.getScriptProperties().getProperty('PHH_NOTIFY_TO');if(!to)return {mailed:0,configured:false};
    ensure_(to===store.config.chat,'NOTIFY_RECIPIENT');const reviews=store.find('Reviews','status','未対応'),now=Date.now(),plan=hubNotificationPlan_(reviews,hubSetting_(store,'last_reminder_date',''),now);
    if(!plan)return {mailed:0,configured:true};ensure_(MailApp.getRemainingDailyQuota()>0,'NOTIFY_QUOTA');
    // 送信後の保存失敗は次回再送する。任意の記録本文・数値・IDはメールに入れない。
    MailApp.sendEmail(to,plan.subject,plan.body);
    for(const r of reviews.filter(r=>plan.ids.includes(r.id))) {if(plan.kind==='new')r.notified_at=now;else r.renotified_date=intakeJstDate_(now);store.put('Reviews',r);}
    if(plan.kind==='reminder')hubSet_(store,'last_reminder_date',intakeJstDate_(now),now);
    return {mailed:1,kind:plan.kind,count:plan.ids.length};
  });
}
const HUB_MAINTENANCE_HANDLERS_=['tickHubMaintenance','stopHubMaintenance'];
function hubMaintenanceTriggers_(){return ScriptApp.getProjectTriggers().filter(t=>HUB_MAINTENANCE_HANDLERS_.includes(t.getHandlerFunction()));}
function stopHubMaintenance() {
  const props=PropertiesService.getScriptProperties();props.setProperty('PHH_MAINTENANCE_UNTIL','0');
  for(const t of hubMaintenanceTriggers_())ScriptApp.deleteTrigger(t);
  const result={stopped:true,triggers_remaining:hubMaintenanceTriggers_().length};props.setProperty('PHH_MAINTENANCE_STOP',JSON.stringify({...result,stopped_at:new Date().toISOString()}));console.log(JSON.stringify({event:'PHH_MAINTENANCE_STOP',...result}));return result;
}
function startHubMaintenance(hours=24) {
  ensure_(Number.isFinite(hours) && hours>0 && hours<=24,'INVALID_DURATION');
  const c=hubConfig_();ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');hubCheckACL_(c);hubCheckBookEnvs_(c);ensure_(hubMaintenanceTriggers_().length===0,'MAINTENANCE_ALREADY_RUNNING');
  const props=PropertiesService.getScriptProperties(),started=Date.now(),until=started+hours*3600000;
  props.setProperty('PHH_MAINTENANCE_STOP','');props.setProperty('PHH_MAINTENANCE_UNTIL',String(until));props.setProperty('PHH_MAINTENANCE_STARTED',String(started));props.setProperty('PHH_MAINTENANCE_RUNTIME_MS','0');
  try {ScriptApp.newTrigger('tickHubMaintenance').timeBased().everyMinutes(5).create();ScriptApp.newTrigger('stopHubMaintenance').timeBased().at(new Date(until)).create();ensure_(hubMaintenanceTriggers_().length===2,'MAINTENANCE_TRIGGER_COUNT');}
  catch(e){stopHubMaintenance();throw e;}
  const result={started_at:new Date(started).toISOString(),until:new Date(until).toISOString(),interval_minutes:5,triggers:2};console.log(JSON.stringify({event:'PHH_MAINTENANCE_START',...result}));return result;
}
function hubMaintenanceIntake_() {
  return hubRun_(null,store=>{
    ensure_(!store.config.real_data_enabled,'REAL_DATA_DISABLED');
    const sh=SpreadsheetApp.openById(store.config.inbox).getSheetByName('受付');ensure_(sh && stable_(sh.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');
    const now=Date.now(),result=hubPollWork_(store,row=>sh.getRange(row,1,1,9).getValues()[0],sh.getLastRow(),now);
    const plan=hubNotificationPlan_(store.find('Reviews','status','未対応'),hubSetting_(store,'last_reminder_date',''),now);
    return {...result,needs_notification:plan!==null};
  });
}
function tickHubMaintenance() {
  const started=Date.now(),props=PropertiesService.getScriptProperties(),until=Number(props.getProperty('PHH_MAINTENANCE_UNTIL') || 0);
  const runtime=Number(props.getProperty('PHH_MAINTENANCE_RUNTIME_MS') || 0);
  if(!Number.isSafeInteger(until) || until<0 || !Number.isSafeInteger(runtime) || runtime<0) {
    // 保存状態が壊れていても期限/予算の比較をNaNで通過させない。
    stopHubMaintenance();ensure_(false,'MAINTENANCE_STATE');
  }
  if(started>=until || runtime>=60*60000)return stopHubMaintenance();
  let success=false;
  try {
    const c=hubConfig_();ensure_(!c.real_data_enabled,'REAL_DATA_DISABLED');
    const intake=hubMaintenanceIntake_();
    if(intake.publication_pending)publishHubResults();
    const notification=intake.needs_notification?hubNotifyReviews_():{mailed:0},today=intakeJstDate_(started);
    if(props.getProperty('PHH_QUERY_ROOT_ID'))runHubExpiryCleanup();
    if(props.getProperty('PHH_BACKUP_DAY')!==today){hubCreateBackup_();hubBackupPrune_(hubBackupRoot_(c),c);props.setProperty('PHH_BACKUP_DAY',today);}
    success=true;return {processed:intake.processed,mailed:notification.mailed};
  } finally {
    const elapsed=Date.now()-started,total=Number(props.getProperty('PHH_MAINTENANCE_RUNTIME_MS') || 0)+elapsed;props.setProperty('PHH_MAINTENANCE_RUNTIME_MS',String(total));
    console.log(JSON.stringify({event:'PHH_MAINTENANCE_TIMING',success,elapsed_ms:elapsed,total_ms:total}));
    // 60分は内部予算。超えたら停止し、間隔変更は本人判断へ渡す。
    if(total>=60*60000)stopHubMaintenance();
  }
}
