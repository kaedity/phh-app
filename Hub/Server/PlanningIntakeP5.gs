// 9列の受付をP5契約へ変換。全操作を事前検証してから共通のatomic保存へ渡します。
function hubP5Stage_(base) {
  const pending=new Map();return {config:base.config,pending,
    get:(t,id)=>hubClone_(pending.get(t+'\0'+id) || base.get(t,id)),
    find:(t,k,v)=>{const out=new Map(base.find(t,k,v).map(r=>[r.id,r]));for(const [key,r]of pending)if(key.startsWith(t+'\0')){out.delete(r.id);if(r[k]===v)out.set(r.id,r);}return [...out.values()].map(hubClone_);},
    put:(t,r)=>{hubRow_(t,r);pending.set(t+'\0'+r.id,hubClone_(r));},
    position:(t,id)=>base.position(t,id) || 2,
    flush:()=>{for(const [key,value]of pending){const t=key.split('\0')[0],r=hubClone_(value);if(t==='RecordIndex')r.sheet_row=base.position(r.table_name,r.id);base.put(t,r);}}
  };
}
function hubP5Model_(store,table,row) {
  if(!row)return null;
  const spec=HUB_PLANNING_LAYOUT_[table],model={};for(const f of spec.fields){const parts=f.path.split('.');let out=model;for(const key of parts.slice(0,-1))out=out[key] || (out[key]={});out[parts.at(-1)]=row[f.column];}
  if(spec.model_id)model.id=row.id;
  return hubP5ReadPlan_(hubP5RelatedRows_(store,{table,key:spec.key,model,rows:[{table,row}]}),HUB_PLANNING_LAYOUT_).find(r=>r.id===row.id && r.key===spec.key)?.model;
}
function hubP5StageApply_(stage,key,value,op,now,id,expected=0,source='conversation') {
  const [table,spec]=Object.entries(HUB_PLANNING_LAYOUT_).find(([,s])=>s.key===key);
  const request={schema_version:1,environment:stage.config.environment,synthetic:stage.config.real_data_enabled!==true,approval_state:'confirmed',operation_id:op,action:Object.keys(hubP5Actions_(HUB_PLANNING_LAYOUT_)).find(a=>hubP5Actions_(HUB_PLANNING_LAYOUT_)[a].spec.key===key),entity_id:id,expected_revision:expected,payload:{[key]:value}};
  const receipt=hubP5Apply_(stage,request,now);intakeCheck_(receipt.status==='committed','INVALID_VALUE',receipt.error_code);
  for(const [k,r]of stage.pending)if(r.last_operation_id===op && 'source_kind' in r)stage.put(k.split('\0')[0],{...r,source_kind:source});
  const saved=stage.get('Operations',op);stage.put('Operations',{...saved,actor:source});return {table,row:stage.get(table,id)};
}
function hubP5Plans_(store,date,name,planID) {
  const versions=planID?store.find('SupplementPlans','plan_id',planID):store.find('SupplementPlans','status','active');
  intakeCheck_(versions.length<=2000,'INVALID_VALUE','予定版の上限');const latest=new Map();
  for(const row of versions.filter(r=>r.effective_from<=date)){const old=latest.get(row.plan_id);if(!old || old.model_revision<row.model_revision)latest.set(row.plan_id,row);}
  return [...latest.values()].filter(r=>!name || store.get('SupplementProducts',r.product_version_id)?.name===name);
}
function hubP5DayModel_(store,plan,date,id,amount,state,override,revision) {
  const product=hubP5Model_(store,'SupplementProducts',store.get('SupplementProducts',plan.productVersionID));intakeCheck_(product,'NOT_FOUND','商品版');
  return {id,planID:plan.planID,date,planVersionID:plan.id,productVersionID:product.id,productName:product.name,amount,unit:product.unit,nutrients:product.nutrients.map(n=>({...n,value:n.value==null?null:n.value*(amount/product.referenceAmount)})),revision,state,dailyOverride:override};
}
function hubP5AutoPlan_(store,now) {
  if(typeof hubP5Enabled_!=='function' || !hubP5Enabled_())return {planned:0};
  const date=intakeJstDate_(now),plans=hubP5Plans_(store,date,null,null);let count=0;
  for(const row of plans){
    const plan=hubP5Model_(store,'SupplementPlans',row),matches=store.find('SupplementDays','local_date',date).filter(d=>d.plan_id===plan.planID);ensure_(matches.length<=1,'DUPLICATE_DAY');
    const old=matches[0],previous=hubP5Model_(store,'SupplementDays',old);if(previous && (previous.dailyOverride || previous.state==='confirmed'))continue;
    const stopped=!plan.autoCount || plan.effectiveThrough!=null && plan.effectiveThrough<date;if(stopped && !previous)continue;
    let next;if(stopped)next={...previous,revision:previous.revision+1,state:'excluded'};
    else next=hubP5DayModel_(store,plan,date,old?.id ?? hubId_(store.config.environment+'|supplement-day|'+plan.planID+'|'+date),plan.dailyAmount,'planned',false,(old?.revision ?? 0)+1);
    if(previous && stable_({...previous,revision:next.revision})===stable_(next))continue;
    const stage=hubP5Stage_(store),op=hubId_(store.config.environment+'|auto-supplement|'+date+'|'+plan.id+'|'+next.id+'|'+next.revision);
    hubP5StageApply_(stage,'day',next,op,now,next.id,old?.revision ?? 0,'system');stage.flush();count++;
  }
  return {planned:count};
}
function hubP5SaveUndo_(store,parent,record,old,now) {
  const rows=old?[{table:record.table,row:old},...HUB_PLANNING_LAYOUT_[record.table].children.flatMap(c=>store.find(c.table,'parent_id',old.id).map(row=>({table:c.table,row})))]:[];
  const fields={p5_table:record.table,p5_after_revision:record.row.revision,p5_absent:!old};
  for(const entry of rows)for(const [key,value]of Object.entries(entry.row))fields['p5|'+entry.table+'|'+entry.row.id+'|'+key]=value;
  return Object.entries(fields).map(([field,v])=>({id:hubId_(parent+'|'+field),operation_id:parent,record_id:record.row.id,field_name:field,value_type:v===null?'null':typeof v,string_value:typeof v==='string'?v:null,number_value:typeof v==='number'?v:null,bool_value:typeof v==='boolean'?v:null}));
}
function hubP5UndoIntake_(store,stage,cells,op,now) {
  const values=intakeContent_(cells[7]);intakeAllow_(values,['対象受付番号']);const ledger=store.get('IntakeLedger',values['対象受付番号']);
  intakeCheck_(ledger?.status==='保存済み' && !ledger.undone && ledger.original_2===cells[2],'UNDO_INVALID');
  const fields={};for(const row of store.find('UndoValues','operation_id',ledger.operation_id))fields[row.field_name]=row.value_type==='null'?null:row.value_type==='number'?row.number_value:row.value_type==='boolean'?row.bool_value:row.string_value;
  const table=fields.p5_table,current=table && store.get(table,ledger.record_id);intakeCheck_(current && current.revision===fields.p5_after_revision,'UNDO_NOT_LATEST');
  const saved=new Map();for(const [key,value]of Object.entries(fields).filter(([k])=>k.startsWith('p5|'))){const [,t,id,field]=key.split('|'),k=t+'|'+id;if(!saved.has(k))saved.set(k,{table:t,row:{}});saved.get(k).row[field]=value;}
  let before=null;if(!fields.p5_absent){const old=[...saved.values()].find(r=>r.table===table)?.row;intakeCheck_(old,'UNDO_INVALID');before=hubP5Model_({get:(t,id)=>saved.get(t+'|'+id)?.row || store.get(t,id),find:(t,k,v)=>{const rows=new Map(store.find(t,k,v).map(r=>[r.id,r]));for(const entry of saved.values())if(entry.table===t){rows.delete(entry.row.id);if(entry.row[k]===v)rows.set(entry.row.id,entry.row);}return [...rows.values()];},config:store.config},table,old);}
  let next,key,id=ledger.record_id,expected=current.revision;
  if(table==='SupplementPlans'){
    const all=store.find(table,'plan_id',current.plan_id);intakeCheck_(all.every(r=>r.model_revision<=current.model_revision),'UNDO_NOT_LATEST');
    const previous=hubP5Model_(store,table,current);id=hubId_(op+'|restore-plan');expected=0;key='plan';next={...(before || previous),id,revision:current.model_revision+1,effectiveFrom:current.effective_from,autoCount:before?.autoCount ?? false};
  }else if(table==='SupplementDays'){key='day';next={...(before || hubP5Model_(store,table,current)),revision:current.revision+1,dailyOverride:true};if(!before)next.state='excluded';}
  else if(table==='FoodDays'){key='foodDay';next={...(before || hubP5Model_(store,table,current)),revision:current.revision+1};if(!before)Object.assign(next,{status:'incomplete',completedAt:null,completedFoodRevision:null,completionOperationID:null});if(next.status==='completed')next.completionOperationID=op;}
  else intakeFail_('UNDO_INVALID');
  const record=hubP5StageApply_(stage,key,next,op,now,id,expected);return {record,old:current,undoLedger:ledger};
}
function hubP5Intake_(store,cells,op,now,firstSeen) {
  const stage=hubP5Stage_(store),[receipt,kind,domain,date,slot,name,no,content,text]=cells;let record,old=null,undoLedger;
  intakeCheck_(INTAKE_KINDS_.includes(kind),'INVALID_KIND');intakeCheck_(!no && !text,'UNKNOWN_FIELD','番号/本文');
  if(kind==='戻す')({record,old,undoLedger}=hubP5UndoIntake_(store,stage,cells,op,now));
  else {
    intakeDate_(date);const values=intakeContent_(content);
    if(domain==='記録日'){
      intakeCheck_(kind==='記録' && slot==='食事' && name==='記録完了','INVALID_VALUE','記録日');intakeAllow_(values,[]);
      hubP5AutoPlan_(stage,now);const matches=stage.find('FoodDays','local_date',date);intakeCheck_(matches.length<=1,'AMBIGUOUS');old=matches[0] || null;const id=old?.id ?? hubId_(store.config.environment+'|food-day|'+date),revision=(old?.revision ?? 0)+1;
      record=hubP5StageApply_(stage,'foodDay',{date,revision,foodRevision:old?.food_revision ?? 0,status:'completed',completedFoodRevision:old?.food_revision ?? 0,completedAt:now/1000-978307200,completionOperationID:op},op,now,id,old?.revision ?? 0);
    }else if(slot==='予定'){
      intakeCheck_(name && ['記録','修正','取消'].includes(kind),'INVALID_VALUE','予定');
      intakeAllow_(values,['予定ID','基準量','単位','日量','終了日','自動計上','kcal','P','F','C','根拠',...Object.keys(values).filter(k=>k.startsWith('成分:')||k.startsWith('単位:'))]);
      const found=hubP5Plans_(store,date,name,values['予定ID']);if(kind!=='記録')intakeCheck_(found.length===1,found.length?'AMBIGUOUS':'NOT_FOUND');else intakeCheck_(!found.length,'ALREADY_EXISTS');
      old=found[0] || null;if(!old)intakeCheck_('自動計上' in values,'MISSING_FIELD','自動計上');const previous=hubP5Model_(store,'SupplementPlans',old),product=previous?hubP5Model_(store,'SupplementProducts',store.get('SupplementProducts',previous.productVersionID)):null;
      const nutrientEdit=['基準量','単位','kcal','P','F','C','根拠'].some(k=>k in values)||Object.keys(values).some(k=>k.startsWith('成分:')||k.startsWith('単位:'));
      let productID=product?.id;
      if(!product || nutrientEdit){
        const id=hubId_(op+'|product'),source=intakeChoice_(values,'根拠',MEAL_SOURCES_) || product?.nutrients[0].source || '本人';
        const nutrients=product?hubClone_(product.nutrients):[['kcal','kcal'],['protein','g'],['fat','g'],['carbohydrate','g']].map(([nutrientID,unit])=>({nutrientID,unit,value:null,source}));
        for(const [wire,key]of [['kcal','kcal'],['P','protein'],['F','fat'],['C','carbohydrate']])if(wire in values)Object.assign(nutrients.find(n=>n.nutrientID===key),{value:intakeNumber_(values,wire,{min:0,max:100000,clearable:true}),source});
        for(const field of Object.keys(values).filter(k=>k.startsWith('成分:'))){const key=field.slice(3),unit=values['単位:'+key];intakeCheck_(unit && !['kcal','protein','fat','carbohydrate'].includes(key),'MISSING_FIELD','成分単位');const n={nutrientID:key,unit,value:intakeNumber_(values,field,{min:0,max:100000,clearable:true}),source},index=nutrients.findIndex(n=>n.nutrientID===key);if(index<0)nutrients.push(n);else nutrients[index]=n;}
        for(const field of Object.keys(values).filter(k=>k.startsWith('単位:')))intakeCheck_(('成分:'+field.slice(3)) in values,'MISSING_FIELD','成分値');
        const next={id,productID:product?.productID ?? hubId_(op+'|product-root'),revision:(product?.revision ?? 0)+1,name,referenceAmount:intakeNumber_(values,'基準量',{min:0.000001,max:1000000}) ?? product?.referenceAmount,unit:values['単位'] || product?.unit,nutrients};
        intakeCheck_(next.referenceAmount && next.unit,'MISSING_FIELD','基準量・単位');hubP5StageApply_(stage,'product',next,hubId_(op+'|product-save'),now,id);productID=id;
      }
      const id=hubId_(op+'|plan'),next={id,planID:previous?.planID ?? hubId_(op+'|plan-root'),revision:(previous?.revision ?? 0)+1,productVersionID:productID,dailyAmount:intakeNumber_(values,'日量',{min:0.000001,max:1000000}) ?? previous?.dailyAmount,effectiveFrom:date,effectiveThrough:values['終了日']==='なし'?null:values['終了日'] ?? previous?.effectiveThrough ?? null,autoCount:kind==='取消'?false:intakeChoice_(values,'自動計上',['はい','いいえ'])===undefined?previous?.autoCount ?? false:values['自動計上']==='はい'};
      intakeCheck_(next.dailyAmount,'MISSING_FIELD','日量');record=hubP5StageApply_(stage,'plan',next,op,now,id);
    }else if(slot==='服用'){
      intakeCheck_(name && ['記録','修正','取消'].includes(kind),'INVALID_VALUE','服用');intakeAllow_(values,['予定ID','量']);const found=hubP5Plans_(store,date,name,values['予定ID']);intakeCheck_(found.length===1,found.length?'AMBIGUOUS':'NOT_FOUND');
      const plan=hubP5Model_(store,'SupplementPlans',found[0]),days=store.find('SupplementDays','local_date',date).filter(r=>r.plan_id===plan.planID);intakeCheck_(days.length<=1,'AMBIGUOUS');old=days[0] || null;
      if(old?.source_kind==='app')intakeCheck_(firstSeen-Date.parse(old.updated_at)>=APP_EDIT_WINDOW_MS_,'RECENT_APP_EDIT');
      const previous=hubP5Model_(store,'SupplementDays',old),ref=previous?hubP5Model_(store,'SupplementPlans',store.get('SupplementPlans',previous.planVersionID)):plan,id=old?.id ?? hubId_(store.config.environment+'|supplement-day|'+plan.planID+'|'+date);
      record=hubP5StageApply_(stage,'day',hubP5DayModel_(store,ref,date,id,intakeNumber_(values,'量',{min:0.000001,max:1000000}) ?? previous?.amount ?? plan.dailyAmount,kind==='取消'?'excluded':'confirmed',true,(old?.revision ?? 0)+1),op,now,id,old?.revision ?? 0);
    }else intakeFail_('INVALID_VALUE','区分は予定/服用');
  }
  const undoRows=hubP5SaveUndo_(store,op,record,old,now);
  return {planning:true,stage,record_id:record.row.id,record:{...record.row,type:record.table},undoRows,undoLedger,summary:(date || record.row.local_date || '')+' '+(name || '元に戻しました')};
}
function hubP5SummaryLines_(store,date) {
  const out=[],fmt=v=>v==null?'不明':String(v),days=store.find('FoodDays','local_date',date);ensure_(days.length<=1,'DUPLICATE_DAY');
  out.push('食事の記録日：'+({incomplete:'未完了',completed:'記録完了',changed:'変更あり'}[days[0]?.day_state] || '未完了'));
  for(const root of store.find('SupplementDays','local_date',date)){
    const day=hubP5Model_(store,'SupplementDays',root),get=k=>fmt(day.nutrients.find(n=>n.nutrientID===k)?.value);
    const state=day.state==='excluded'?'除外':day.state==='confirmed'?'服用確認済み':'予定から自動計上・服用確認なし';
    out.push('サプリ｜'+day.productName+'｜'+day.amount+' '+day.unit+'｜'+state+'｜'+get('kcal')+' kcal P'+get('protein')+' F'+get('fat')+' C'+get('carbohydrate')+'｜予定ID '+day.planID);
    for(const n of day.nutrients.filter(n=>!['kcal','protein','fat','carbohydrate'].includes(n.nutrientID)))out.push('成分｜'+n.nutrientID+' '+fmt(n.value)+' '+n.unit+'｜'+n.source);
  }
  return out;
}
