// P2の共通処理。表の列はschema.jsonから配置時に生成する。
function ensure_(ok, code) { if (!ok) throw Error(code); }
function stable_(v) { return v === null || typeof v !== 'object' ? JSON.stringify(v) : Array.isArray(v) ? '[' + v.map(stable_).join(',') + ']' : '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + stable_(v[k])).join(',') + '}'; }
function hubHash_(v) { return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, typeof v === 'string' ? v : stable_(v), Utilities.Charset.UTF_8).map(n => (n & 255).toString(16).padStart(2, '0')).join(''); }
function hubUUID_() { return Utilities.getUuid(); }
function hubId_(v) { const h = hubHash_(v); return h.slice(0,8)+'-'+h.slice(8,12)+'-5'+h.slice(13,16)+'-a'+h.slice(17,20)+'-'+h.slice(20,32); }
function hubIsId_(v) { return typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v); }
function hubKeys_(v, allowed) { ensure_(v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).every(k => allowed.includes(k)), 'UNKNOWN_FIELD'); }
function hubClone_(v) { return JSON.parse(JSON.stringify(v)); }
function hubRow_(table, record) {
  const cols = HUB_SCHEMA_.tables[table].columns;
  ensure_(record && Object.keys(record).every(k => cols.some(c => c.name === k)), 'UNKNOWN_COLUMN');
  return cols.map(c => {
    const v = record[c.name];
    if (v === null || v === undefined) { ensure_(c.nullable, 'NULL_REQUIRED:'+table+'.'+c.name); return null; }
    ensure_(typeof v === c.type || c.type === 'integer' && Number.isSafeInteger(v), 'COLUMN_TYPE:'+table+'.'+c.name);
    if (c.type === 'number') ensure_(Number.isFinite(v), 'NONFINITE');
    if (c.type === 'string') ensure_(v.length < 45000, 'CELL_TOO_LARGE');
    return v;
  });
}
function hubDecode_(table, cells) {
  const out = {};
  HUB_SCHEMA_.tables[table].columns.forEach((c,i) => {
    const v=cells[i], blank=v === '' || v === undefined || v === null;
    // Values APIは末尾の空セルを省略する。必須文字列の空欄は空文字へ戻す。
    // 数値/booleanの欠落は補完せず、nullable列だけnullとして保持する。
    out[c.name] = blank && c.nullable ? null : blank && c.type === 'string' ? '' : v;
  });
  hubRow_(table,out); return out;
}
function hubConfig_() {
  const p = PropertiesService.getScriptProperties().getProperties();
  ensure_(['PHH_TEST','PHH_PRODUCTION'].includes(p.PHH_ENVIRONMENT), 'ENVIRONMENT_NOT_CONFIGURED');
  ensure_(p.PHH_OWNER_EMAIL && p.PHH_CHAT_EMAIL && p.PHH_NOTIFY_TO, 'ACCOUNT_NOT_CONFIGURED');
  ensure_(['PHH_CANONICAL','PHH_INBOX','PHH_RESULTS'].every(k => p[k]), 'BOOKS_NOT_CONFIGURED');
  ensure_(new Set([p.PHH_CANONICAL,p.PHH_INBOX,p.PHH_RESULTS]).size === 3, 'BOOKS_NOT_SEPARATE');
  ensure_(Session.getEffectiveUser().getEmail() === p.PHH_OWNER_EMAIL, 'OWNER_REQUIRED');
  return {environment:p.PHH_ENVIRONMENT, real_data_enabled:p.PHH_REAL_DATA_ENABLED === 'true', canonical:p.PHH_CANONICAL,inbox:p.PHH_INBOX,results:p.PHH_RESULTS,owner:p.PHH_OWNER_EMAIL,chat:p.PHH_CHAT_EMAIL,notify_to:p.PHH_NOTIFY_TO,
    health_real_enabled:p.PHH_HEALTH_REAL_ENABLED === 'true',health_metrics:(p.PHH_HEALTH_METRICS || '').split(',').map(s=>s.trim()).filter(Boolean),health_from:p.PHH_HEALTH_FROM || null,intake_layout:p.PHH_INTAKE_LAYOUT || ''};
}
function hubCheckRequest_(config, q,health=false) { ensure_(q && q.environment === config.environment && q.schema_version === 1, 'ENVIRONMENT_MISMATCH'); ensure_(config.real_data_enabled || q.synthetic === true || health && config.health_real_enabled === true && ['save_health_delta','get_health_details'].includes(q.action), 'REAL_DATA_DISABLED'); }
function hubCell_(v) { return v === null ? {} : {userEnteredValue:typeof v === 'boolean' ? {boolValue:v} : typeof v === 'number' ? {numberValue:v} : {stringValue:String(v)}}; }
