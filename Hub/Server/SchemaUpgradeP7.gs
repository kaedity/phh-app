// P7-5：合成段階の既知16/18/23/32表へ、表/nullable列/見出しだけを付加します。
// 呼出前の採取/バックアップは、旧物理schema対応コードでの保存・読戻し手順が前提です。
function setupHubSchemaP7() {
  return hubRun_(null,store=>{
    ensure_(store.config.real_data_enabled===false && store.config.health_real_enabled===false,'SCHEMA_SYNTHETIC_ONLY');
    const before=hubSchemaInventoryP7_(store),plan=hubSchemaPlanP7_(before);
    if(plan.requests.length)Sheets.Spreadsheets.batchUpdate({requests:plan.requests},store.config.canonical);
    const after=hubSchemaInventoryP7_(store,false),expected=hubSchemaHeadersP7_(HUB_SCHEMA_);
    ensure_(stable_(after.map(s=>[s.name,s.columns]).sort((a,b)=>a[0].localeCompare(b[0])))===stable_(expected),'SCHEMA_READBACK_MISMATCH');
    // Sheets batchUpdateで反映済みです。通常のstore.commitへ書込を残しません。
    return {environment:store.config.environment,status:plan.requests.length?'schema_upgraded':'schema_ready',source_tables:plan.source_tables,target_tables:36,preserved_blank_sheet_ids:before.preserved_blank_sheet_ids,added_tables:plan.added_tables,added_columns:plan.added_columns,request_count:plan.requests.length,header_sha256:hubHash_(expected)};
  });
}
function hubSchemaHeadersP7_(schema) {
  return Object.entries(schema.tables).map(([name,spec])=>[name,spec.columns.map(c=>c.name)]).sort((a,b)=>a[0].localeCompare(b[0]));
}
function hubSchemaVersionsP7_() {
  const schemas=[HUB_BASE_SCHEMA_,HUB_P3_SCHEMA_,HUB_P4_SCHEMA_,HUB_P5_SCHEMA_,HUB_SCHEMA_],counts=[16,18,23,32,36];
  schemas.forEach((s,i)=>ensure_(s.schema_version===1 && Object.keys(s.tables).length===counts[i],'SCHEMA_CONTRACT_MISMATCH'));
  // 実装の付加列がnullableでなくなった場合も、物理移行を始める前に拒否します。
  for(const source of schemas)for(const [name,spec]of Object.entries(source.tables)){
    const target=HUB_SCHEMA_.tables[name];ensure_(target && target.columns.length>=spec.columns.length && stable_(target.columns.slice(0,spec.columns.length))===stable_(spec.columns) && target.columns.slice(spec.columns.length).every(c=>c.nullable===true),'SCHEMA_NOT_ADDITIVE');
  }
  return schemas;
}
function hubSchemaInventoryP7_(store,checkUsedColumns=true) {
  const metadata=Sheets.Spreadsheets.get(store.config.canonical,{includeGridData:false,fields:'sheets(properties(sheetId,title,sheetType,gridProperties(columnCount,rowCount)))'}),sheets=metadata.sheets?.map(s=>s.properties);
  ensure_(Array.isArray(sheets) && sheets.length>0,'SCHEMA_INVENTORY_MISSING');
  ensure_(new Set(sheets.map(s=>s.title)).size===sheets.length && new Set(sheets.map(s=>s.sheetId)).size===sheets.length,'SCHEMA_INVENTORY_DUPLICATE');
  const blank=[];
  for(const s of sheets){
    ensure_(typeof s.title==='string','SCHEMA_UNKNOWN_TABLE');
    ensure_(Number.isSafeInteger(s.sheetId) && s.sheetId>=0 && (s.sheetType===undefined || s.sheetType==='GRID') && Number.isSafeInteger(s.gridProperties?.columnCount) && s.gridProperties.columnCount>=1 && Number.isSafeInteger(s.gridProperties.rowCount) && s.gridProperties.rowCount>=1,'SCHEMA_GRID_INVALID');
    if(!HUB_SCHEMA_.tables[s.title]){
      const sh=store.book.getSheetByName(s.title);
      // Googleが作った初期シートだけを、完全な空欄を毎回確認して保持します。
      ensure_(['シート1','Sheet1'].includes(s.title) && s.sheetId===0 && sh?.getSheetId()===0 && sh.getLastRow()===0 && sh.getLastColumn()===0,'SCHEMA_UNKNOWN_TABLE');blank.push(s.sheetId);
    }
  }
  const data=sheets.filter(s=>HUB_SCHEMA_.tables[s.title]);ensure_(data.length>0,'SCHEMA_INVENTORY_MISSING');
  const ranges=data.map(s=>"'"+s.title+"'!A1:"+hubColumn_(s.gridProperties.columnCount)+'1'),read=Sheets.Spreadsheets.Values.batchGet(store.config.canonical,{ranges,valueRenderOption:'FORMULA'});
  ensure_(read.valueRanges?.length===data.length,'SCHEMA_HEADER_READBACK');
  const inventory=data.map((s,i)=>{const values=read.valueRanges[i].values || [];ensure_(values.length<=1 && (!values.length || Array.isArray(values[0])),'SCHEMA_HEADER_READBACK');const columns=(values[0] || []).slice();while(columns.length && (columns.at(-1)==='' || columns.at(-1)===null))columns.pop();ensure_(columns.length<=s.gridProperties.columnCount,'SCHEMA_HEADER_READBACK');let used_columns=null;if(checkUsedColumns){const sh=store.book.getSheetByName(s.title);ensure_(sh?.getSheetId()===s.sheetId,'SCHEMA_INVENTORY_CHANGED');used_columns=sh.getLastColumn();ensure_(Number.isSafeInteger(used_columns) && used_columns>=0 && used_columns<=columns.length,'SCHEMA_UNKNOWN_COLUMN');}return {name:s.title,sheet_id:s.sheetId,grid_columns:s.gridProperties.columnCount,used_columns,columns};});
  inventory.preserved_blank_sheet_ids=blank;return inventory;
}
function hubSchemaPlanP7_(inventory) {
  const versions=hubSchemaVersionsP7_(),names=inventory.map(s=>s.name).sort(),candidates=versions.filter(s=>stable_(Object.keys(s.tables).sort())===stable_(names));
  ensure_(candidates.length===1,'SCHEMA_TABLE_SET_MISMATCH');const source=candidates[0];
  for(const item of inventory)ensure_(stable_(item.columns)===stable_(source.tables[item.name].columns.map(c=>c.name)),'SCHEMA_HEADER_MISMATCH');
  const byName=new Map(inventory.map(s=>[s.name,s])),used=new Set([...inventory.map(s=>s.sheet_id),...(inventory.preserved_blank_sheet_ids || [])]),requests=[],added_tables=[],added_columns={};
  for(const [name,spec]of Object.entries(HUB_SCHEMA_.tables)){
    const old=byName.get(name),columns=spec.columns.map(c=>c.name);
    if(old){
      const extra=columns.slice(old.columns.length);if(!extra.length)continue;
      if(old.grid_columns<columns.length)requests.push({appendDimension:{sheetId:old.sheet_id,dimension:'COLUMNS',length:columns.length-old.grid_columns}});
      requests.push({updateCells:{start:{sheetId:old.sheet_id,rowIndex:0,columnIndex:old.columns.length},rows:[{values:extra.map(hubCell_)}],fields:'userEnteredValue'}});added_columns[name]=extra;
    }else{
      let sheetId=0;while(used.has(sheetId))sheetId++;used.add(sheetId);
      requests.push({addSheet:{properties:{sheetId,title:name,gridProperties:{rowCount:1000,columnCount:columns.length,frozenRowCount:1}}}},{updateCells:{start:{sheetId,rowIndex:0,columnIndex:0},rows:[{values:columns.map(hubCell_)}],fields:'userEnteredValue'}});added_tables.push(name);
    }
  }
  return {source_tables:inventory.length,requests,added_tables,added_columns};
}
