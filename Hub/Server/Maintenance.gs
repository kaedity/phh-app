// P2-6：承認済みの件数通知と5分処理。10/4：実データ（2章10/3承認）でも動く。環境とSettingsの一致はhubRun_が確かめる。
function hubNotificationPlan_(reviews,lastReminder,now) {
  const open=reviews.filter(r=>r.status==='未対応'),fresh=open.filter(r=>!r.notified_at),today=intakeJstDate_(now),hour=new Date(now+9*3600000).getUTCHours();
  if(fresh.length)return {kind:'new',ids:fresh.map(r=>r.id),subject:'【PHH】要確認が'+fresh.length+'件あります',body:'自動で保存できなかった記録が'+fresh.length+'件あります（未対応は合計'+open.length+'件）。\n内容は結果ブックの「要確認」で確認してください。'};
  if(open.length && hour>=21 && lastReminder!==today)return {kind:'reminder',ids:open.map(r=>r.id),subject:'【PHH】未対応の要確認が'+open.length+'件残っています',body:'未対応の要確認が'+open.length+'件残っています。\n内容は結果ブックの「要確認」で確認してください。'};
  return null;
}
function hubNotifyReviews_() {
  return hubRun_(null,store=>{
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
  const c=hubConfig_();hubCheckACL_(c);hubCheckBookEnvs_(c);ensure_(hubMaintenanceTriggers_().length===0,'MAINTENANCE_ALREADY_RUNNING');
  const props=PropertiesService.getScriptProperties(),started=Date.now(),until=started+hours*3600000;
  props.setProperty('PHH_MAINTENANCE_STOP','');props.setProperty('PHH_MAINTENANCE_UNTIL',String(until));props.setProperty('PHH_MAINTENANCE_STARTED',String(started));props.setProperty('PHH_MAINTENANCE_RUNTIME_MS','0');
  try {ScriptApp.newTrigger('tickHubMaintenance').timeBased().everyMinutes(5).create();ScriptApp.newTrigger('stopHubMaintenance').timeBased().at(new Date(until)).create();ensure_(hubMaintenanceTriggers_().length===2,'MAINTENANCE_TRIGGER_COUNT');}
  catch(e){stopHubMaintenance();throw e;}
  const result={started_at:new Date(started).toISOString(),until:new Date(until).toISOString(),interval_minutes:5,triggers:2};console.log(JSON.stringify({event:'PHH_MAINTENANCE_START',...result}));return result;
}
function hubMaintenanceIntake_() {
  return hubRun_(null,store=>{
    const sh=SpreadsheetApp.openById(store.config.inbox).getSheetByName('受付');ensure_(sh && stable_(sh.getRange(1,1,1,9).getValues()[0])===stable_(INTAKE_HEADERS_),'INBOX_SCHEMA');
    const now=Date.now(),result=hubPollWork_(store,hubIntakeReader_(sh,store.config),sh.getLastRow(),now);
    const plan=hubNotificationPlan_(store.find('Reviews','status','未対応'),hubSetting_(store,'last_reminder_date',''),now);
    return {...result,needs_notification:plan!==null};
  });
}
// 常設（期限なし）の5分処理。1日の実行時間を日ごとに数え、45分を超えたら15分ごとへ間引き、80分を超えたらその日は休む。
// Googleの無料枠（トリガー合計90分/日）を超えないための上限で、停止はしない（10/4）。
function startHubDailyMaintenance() {
  const c=hubConfig_();hubCheckACL_(c);hubCheckBookEnvs_(c);ensure_(hubMaintenanceTriggers_().length===0,'MAINTENANCE_ALREADY_RUNNING');
  const props=PropertiesService.getScriptProperties(),started=Date.now();
  props.setProperty('PHH_MAINTENANCE_STOP','');props.setProperty('PHH_MAINTENANCE_UNTIL','continuous');props.setProperty('PHH_MAINTENANCE_STARTED',String(started));
  props.setProperty('PHH_MAINTENANCE_RUNTIME_MS','0');props.setProperty('PHH_MAINTENANCE_DAY',intakeJstDate_(started));
  try {ScriptApp.newTrigger('tickHubMaintenance').timeBased().everyMinutes(5).create();ensure_(hubMaintenanceTriggers_().length===1,'MAINTENANCE_TRIGGER_COUNT');}
  catch(e){stopHubMaintenance();throw e;}
  const result={started_at:new Date(started).toISOString(),until:'continuous',interval_minutes:5,triggers:1};console.log(JSON.stringify({event:'PHH_MAINTENANCE_START',...result}));return result;
}
function hubDailyMaintenanceSkip_(props,now) {
  const today=intakeJstDate_(now);
  if(props.getProperty('PHH_MAINTENANCE_DAY')!==today){props.setProperty('PHH_MAINTENANCE_DAY',today);props.setProperty('PHH_MAINTENANCE_RUNTIME_MS','0');}
  const runtime=Number(props.getProperty('PHH_MAINTENANCE_RUNTIME_MS') || 0);ensure_(Number.isSafeInteger(runtime) && runtime>=0,'MAINTENANCE_STATE');
  const minute=Math.floor((now+9*3600000)/60000)%1440;
  if(runtime>=80*60000)return 'daily_budget';
  if(runtime>=45*60000 && minute%15>=5)return 'thinned';
  return null;
}
function tickHubMaintenance() {
  const started=Date.now(),props=PropertiesService.getScriptProperties();
  if(props.getProperty('PHH_MAINTENANCE_UNTIL')==='continuous') {
    const skip=hubDailyMaintenanceSkip_(props,started);if(skip)return {skipped:skip};
    return hubMaintenanceWork_(props,started,false);
  }
  const until=Number(props.getProperty('PHH_MAINTENANCE_UNTIL') || 0);
  const runtime=Number(props.getProperty('PHH_MAINTENANCE_RUNTIME_MS') || 0);
  if(!Number.isSafeInteger(until) || until<0 || !Number.isSafeInteger(runtime) || runtime<0) {
    // 保存状態が壊れていても期限/予算の比較をNaNで通過させない。
    stopHubMaintenance();ensure_(false,'MAINTENANCE_STATE');
  }
  if(started>=until || runtime>=60*60000)return stopHubMaintenance();
  return hubMaintenanceWork_(props,started,true);
}
function hubMaintenanceWork_(props,started,measured) {
  let success=false;
  try {
    const c=hubConfig_();
    const intake=hubMaintenanceIntake_();
    if(intake.publication_pending)publishHubResults();
    const notification=intake.needs_notification?hubNotifyReviews_():{mailed:0},today=intakeJstDate_(started);
    if(props.getProperty('PHH_QUERY_ROOT_ID'))runHubExpiryCleanup();
    // 作成に成功したらその日の印を先に付け、整理の失敗で5分ごとに全量バックアップを作り直さない（10/4）。
    if(props.getProperty('PHH_BACKUP_DAY')!==today){hubCreateBackup_();props.setProperty('PHH_BACKUP_DAY',today);}
    if(props.getProperty('PHH_BACKUP_PRUNE_DAY')!==today){props.setProperty('PHH_BACKUP_PRUNE_DAY',today);hubBackupPrune_(hubBackupRoot_(c),c);}
    success=true;return {processed:intake.processed,mailed:notification.mailed};
  } finally {
    const elapsed=Date.now()-started,total=Number(props.getProperty('PHH_MAINTENANCE_RUNTIME_MS') || 0)+elapsed;props.setProperty('PHH_MAINTENANCE_RUNTIME_MS',String(total));
    console.log(JSON.stringify({event:'PHH_MAINTENANCE_TIMING',success,elapsed_ms:elapsed,total_ms:total}));
    // 期限つきの測定では60分で停止する。常設では日ごとの予算で間引く（停止しない）。
    if(measured && total>=60*60000)stopHubMaintenance();
  }
}
// 実データの開始（ROADMAP 2章 10/3承認）。先にバックアップを作り、正本のSettingsとスクリプトのプロパティを続けて切り替える。
// 健康データの外部保存は別の設定（PHH_HEALTH_REAL_ENABLED・PHH_HEALTH_METRICS・PHH_HEALTH_FROM）で開始する。
function enableHubRealData() {
  const before=hubConfig_();ensure_(!before.real_data_enabled,'REAL_DATA_ALREADY_ENABLED');hubCheckACL_(before);hubCheckBookEnvs_(before);
  const backup=hubCreateBackup_();
  hubRun_(null,store=>{hubSet_(store,'real_data_enabled',true,Date.now());return {switched:true};});
  PropertiesService.getScriptProperties().setProperty('PHH_REAL_DATA_ENABLED','true');
  ensure_(hubConfig_().real_data_enabled===true,'REAL_DATA_SWITCH');
  const result={enabled:true,backup:backup?.manifest_id || backup?.id || null};console.log(JSON.stringify({event:'PHH_REAL_DATA_ENABLED',...result}));return result;
}
