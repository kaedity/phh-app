// B2の純粋な入力ルール。Probe/ServerAccess/Intake.gs（815f677）のルールを継承。
// 本番の永続化/権限/上限はStorage.gs/API.gsが担当。全状態JSONは保存しない。
// ChatGPTは受付シートへ行を書き足すだけ。IDの採番・重複・対象の特定・版・集計はここで行う。
// Probe/Shared/Core.gs（ensure_・stable_）と同じGASプロジェクトへ配置する。
const INTAKE_HEADERS_ = ['受付番号','種別','分野','日付','区分','名称','番号','内容','本文'];
const INTAKE_KINDS_ = ['記録','修正','補足','取消','戻す'];
const INTAKE_DOMAINS_ = ['筋トレ','食事'];
const MEAL_SLOTS_ = ['朝食','昼食','夕食','間食'];
const NOTE_CATEGORIES_ = ['身体状態','動作・効き','備考','メニュー変更'];
const NOTE_SPEAKERS_ = ['本人','GPT'];
const WEIGHT_BASES_ = ['通常','自重','加重','補助'];
const MEAL_SOURCES_ = ['推定','商品表示','成分表','レシピ','プリセット','本人'];
const INTAKE_WAIT_MS_ = 10 * 60000;      // 未完成の行を要確認にするまで待つ時間
const APP_EDIT_WINDOW_MS_ = 10 * 60000;  // アプリの変更直後に会話から直したら要確認にする時間
const INTAKE_REASONS_ = {
  INCOMPLETE:'必須の列が空のまま', INVALID_KIND:'種別が不明（記録/修正/補足/取消/戻す）', INVALID_DOMAIN:'分野が不明（筋トレ/食事）',
  INVALID_DATE:'日付の形式が違う（YYYY-MM-DD）', INVALID_SESSION:'区分が不明（Push/Pull/Leg。同じ日の2回目はPush2）',
  INVALID_SLOT:'区分が不明（朝食/昼食/夕食/間食）', INVALID_NUMBER_COLUMN:'番号は1以上の整数',
  INVALID_CONTENT:'内容の書き方が違う（項目=値; 項目=値）', UNKNOWN_FIELD:'内容に使えない項目がある', INVALID_VALUE:'値が不正',
  MISSING_FIELD:'内容に必要な項目がない', NO_CHANGE:'修正する項目がない', MISSING_TEXT:'本文が空',
  NOT_FOUND:'対象が見つからない', AMBIGUOUS:'対象が複数ある（番号を指定する）', ALREADY_EXISTS:'同じ対象が既にある（直すときは修正）',
  ID_REUSED:'同じ受付番号で内容が違う行がある', ROW_EDITED:'受付済みの行が書き換えられた（書き換え後の内容は保存していない）',
  UNDO_INVALID:'戻せる受付ではない', UNDO_NOT_LATEST:'戻す対象の後に別の変更がある',
  RECENT_APP_EDIT:'アプリで直前に変更された記録（どちらを残すか確認）',
  INTERNAL:'この行だけ処理できなかった（理由のコードを確認。ほかの行の保存は続けています）',
};

function intakeEmpty_() { return {seq:0, records:{}, ledger:{}, reviews:[]}; }
function intakeFail_(code, detail) { throw Error(code + (detail ? ':' + detail : '')); }
function intakeCheck_(ok, code, detail) { if (!ok) intakeFail_(code, detail); }

// Sheetsの値を比較可能な文字列へそろえる。日付はSheetsがDateへ自動変換することがある。
function intakeCell_(v) {
  if (v === null || v === undefined) return '';
  if (Object.prototype.toString.call(v) === '[object Date]') return intakeJstDate_(v.getTime());
  return String(v).normalize('NFKC').trim();
}
// 日付の書き方の揺れ（2026/10/05・2026-10-5・2026.10.05）を YYYY-MM-DD へそろえる。それ以外はそのまま返して検査で落とす。
function intakeNormalizeDate_(v) {
  const m = /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/.exec(v || '');
  return m ? m[1] + '-' + m[2].padStart(2, '0') + '-' + m[3].padStart(2, '0') : v;
}
function intakeJstDate_(ms) { return new Date(ms + 9 * 3600000).toISOString().slice(0, 10); }
function intakeJstTime_(ms) { return new Date(ms + 9 * 3600000).toISOString().slice(0, 16).replace('T', ' '); }

const INTAKE_KEY_ALIASES_ = {rpe:'RPE', rir:'RIR', p:'P', f:'F', c:'C', kcal:'kcal', '重量':'重量kg'};
function intakeContent_(text) {
  const out = {};
  if (!text) return out;
  // 区切りは ; と改行。「、」「,」は次に「項目=」が続くときだけ区切りとして扱う（1,050 のような数値は分けない）。
  for (const part of text.split(/[;\n]|[、,](?=\s*[^=;、,\s][^=;、,]*=)/)) {
    const item = part.trim();
    if (!item) continue;
    const at = item.indexOf('=');
    intakeCheck_(at > 0, 'INVALID_CONTENT', item);
    let key = item.slice(0, at).trim();
    key = INTAKE_KEY_ALIASES_[key.toLowerCase()] || INTAKE_KEY_ALIASES_[key] || key;
    intakeCheck_(!(key in out), 'INVALID_CONTENT', key + 'が2回');
    out[key] = item.slice(at + 1).trim();
  }
  return out;
}
function intakeAllow_(content, keys) {
  Object.keys(content).forEach(k => intakeCheck_(keys.includes(k), 'UNKNOWN_FIELD', k));
}
// 数値。clearable の項目は「なし」で未報告（null）へ戻せる。
function intakeNumber_(content, key, opts) {
  if (!(key in content)) return undefined;
  let raw = content[key];
  // 「なし・未報告・不明」は未報告。clearable の項目は null（消す）、それ以外は書かれていないものとして扱う。
  if (['なし', '未報告', '不明'].includes(raw)) return opts.clearable ? null : undefined;
  // 書き方の揺れ：数学のマイナス記号、桁区切りのカンマ、末尾の単位（kg・kcal・g・回・個・杯・本・枚・分・秒・%）。
  raw = raw.replace(/^[\u2212\u2013]/, '-');
  if (/^-?\d{1,3}(,\d{3})+(\.\d+)?/.test(raw)) raw = raw.replace(/,/g, '');
  raw = raw.replace(/^(-?\d+(?:\.\d+)?)\s*(kg|kcal|g|回|個|杯|本|枚|分|秒|%)$/i, '$1');
  intakeCheck_(/^-?\d+(\.\d+)?$/.test(raw), 'INVALID_VALUE', key + '=' + content[key]);
  const n = Number(raw);
  intakeCheck_(n >= opts.min && n <= opts.max && (!opts.int || Number.isInteger(n)), 'INVALID_VALUE', key + '=' + content[key]);
  return n;
}
function intakeChoice_(content, key, choices) {
  if (!(key in content)) return undefined;
  intakeCheck_(choices.includes(content[key]), 'INVALID_VALUE', key + '=' + content[key]);
  return content[key];
}
function intakeDate_(v) {
  intakeCheck_(/^\d{4}-\d{2}-\d{2}$/.test(v) && intakeJstDate_(Date.parse(v + 'T00:00:00+09:00')) === v, 'INVALID_DATE', v);
  return v;
}
function intakeSession_(v) {
  const m = /^(push|pull|leg)\s*([2-9])?$/i.exec(v);
  intakeCheck_(m, 'INVALID_SESSION', v);
  return m[1][0].toUpperCase() + m[1].slice(1).toLowerCase() + (m[2] || '');
}
function intakeNo_(v) {
  if (v === '') return null;
  intakeCheck_(/^\d+(\.0+)?$/.test(v) && Number(v) >= 1, 'INVALID_NUMBER_COLUMN', v);
  return Number(v);
}

function intakeActive_(state, pred) { return Object.values(state.records).filter(r => r.status === 'active' && pred(r)); }
function intakeOne_(found, what) {
  intakeCheck_(found.length > 0, 'NOT_FOUND', what);
  intakeCheck_(found.length === 1, 'AMBIGUOUS', what);
  return found[0];
}
function intakeNewId_(state, prefix) { state.seq++; return hubUUID_(); }
function intakeCopy_(r) { return r ? JSON.parse(JSON.stringify(r)) : null; }
function intakeTouch_(r, intakeId, now) { r.created_at = r.created_at || new Date(now).toISOString(); r.revision = (r.revision || 0) + 1; r.last_intake = intakeId; r.last_source = 'gpt'; r.last_changed_at = now; }

// 行の本文を検査して適用する。失敗は Error('<理由コード>:<詳しく>') で返す。
function intakeApply_(state, row, now, firstSeen) {
  const [id, kind, domain, date, slot, name, no, contentText, text] = row;
  intakeCheck_(INTAKE_KINDS_.includes(kind), 'INVALID_KIND', kind);
  intakeCheck_(INTAKE_DOMAINS_.includes(domain), 'INVALID_DOMAIN', domain);
  const content = intakeContent_(contentText);
  if (kind === '戻す') return intakeUndo_(state, id, content, now);
  const d = intakeDate_(date);
  if (domain === '筋トレ') {
    const session = intakeSession_(slot), setNo = intakeNo_(no);
    const what = [d, session, name, setNo].filter(x => x !== '' && x !== null).join(' ');
    if (kind === '記録') {
      intakeCheck_(name && setNo, 'INCOMPLETE', '名称・番号');
      intakeAllow_(content, ['重量kg','回数','RPE','RIR','重量基準']);
      const weight = intakeNumber_(content, '重量kg', {min:0, max:500}), reps = intakeNumber_(content, '回数', {min:0, max:200, int:true});
      intakeCheck_(weight !== undefined && reps !== undefined, 'MISSING_FIELD', '重量kg・回数');
      intakeCheck_(!intakeActive_(state, r => r.type === 'set' && r.date === d && r.session === session && r.exercise === name && r.set_no === setNo).length, 'ALREADY_EXISTS', what);
      const r = {id:intakeNewId_(state, 'set'), type:'set', status:'active', date:d, session, exercise:name, set_no:setNo,
        weight_kg:weight, reps, rpe:intakeNumber_(content, 'RPE', {min:0, max:10}) ?? null, rir:intakeNumber_(content, 'RIR', {min:0, max:20, int:true}) ?? null,
        weight_basis:intakeChoice_(content, '重量基準', WEIGHT_BASES_) || '通常'};
      intakeTouch_(r, id, now); state.records[r.id] = r;
      return {record_id:r.id, undo:{record_id:r.id, before:null}, summary:what + ' ' + weight + 'kg×' + reps};
    }
    if (kind === '修正') {
      intakeCheck_(name && setNo, 'INCOMPLETE', '名称・番号');
      intakeAllow_(content, ['重量kg','回数','RPE','RIR','重量基準']);
      const target = intakeOne_(intakeActive_(state, r => r.type === 'set' && r.date === d && r.session === session && r.exercise === name && r.set_no === setNo), what);
      const changes = {weight_kg:intakeNumber_(content, '重量kg', {min:0, max:500}), reps:intakeNumber_(content, '回数', {min:0, max:200, int:true}),
        rpe:intakeNumber_(content, 'RPE', {min:0, max:10, clearable:true}), rir:intakeNumber_(content, 'RIR', {min:0, max:20, int:true, clearable:true}),
        weight_basis:intakeChoice_(content, '重量基準', WEIGHT_BASES_)};
      intakeCheck_(Object.values(changes).some(v => v !== undefined), 'NO_CHANGE', what);
      const before = intakeCopy_(target);
      Object.keys(changes).forEach(k => { if (changes[k] !== undefined) target[k] = changes[k]; });
      intakeTouch_(target, id, now);
      return {record_id:target.id, undo:{record_id:target.id, before}, summary:what};
    }
    if (kind === '取消') {
      intakeCheck_(name && setNo, 'INCOMPLETE', '名称・番号');
      intakeAllow_(content, []);
      const target = intakeOne_(intakeActive_(state, r => r.type === 'set' && r.date === d && r.session === session && r.exercise === name && r.set_no === setNo), what);
      const before = intakeCopy_(target); target.status = 'removed'; intakeTouch_(target, id, now);
      return {record_id:target.id, undo:{record_id:target.id, before}, summary:what};
    }
    // 補足：セッション全体（名称・番号なし）はセットがまだなくてもよい。種目・セットは実在が必要。
    intakeAllow_(content, ['分類','発言者']);
    const category = intakeChoice_(content, '分類', NOTE_CATEGORIES_), speaker = intakeChoice_(content, '発言者', NOTE_SPEAKERS_);
    intakeCheck_(category && speaker, 'MISSING_FIELD', '分類・発言者');
    intakeCheck_(text, 'MISSING_TEXT');
    intakeCheck_(!(setNo && !name), 'INCOMPLETE', '名称');
    if (name) intakeOne_(intakeActive_(state, r => r.type === 'set' && r.date === d && r.session === session && r.exercise === name && (!setNo || r.set_no === setNo)).slice(0, 1), what);
    const r = {id:intakeNewId_(state, 'note'), type:'note', status:'active', date:d, session, exercise:name || null, set_no:setNo, category, speaker, text};
    intakeTouch_(r, id, now); state.records[r.id] = r;
    return {record_id:r.id, undo:{record_id:r.id, before:null}, summary:what + ' 補足（' + category + '）'};
  }
  // 食事
  intakeCheck_(MEAL_SLOTS_.includes(slot), 'INVALID_SLOT', slot);
  intakeCheck_(name, 'INCOMPLETE', '名称');
  const mealNo = intakeNo_(no), what = [d, slot, name, mealNo].filter(x => x !== null).join(' ');
  const nutrientOpts = {min:0, max:10000, clearable:true};
  const readNutrients = () => ({kcal:intakeNumber_(content, 'kcal', nutrientOpts), protein_g:intakeNumber_(content, 'P', nutrientOpts),
    fat_g:intakeNumber_(content, 'F', nutrientOpts), carbohydrate_g:intakeNumber_(content, 'C', nutrientOpts)});
  if (kind === '記録') {
    intakeAllow_(content, ['量','単位','kcal','P','F','C','根拠']);
    const quantity = intakeNumber_(content, '量', {min:0.01, max:10000});
    intakeCheck_(quantity !== undefined && content['単位'], 'MISSING_FIELD', '量・単位');
    const same = intakeActive_(state, r => r.type === 'meal' && r.date === d && r.slot === slot && r.name === name);
    intakeCheck_(!(mealNo && same.some(r => r.no === mealNo)), 'ALREADY_EXISTS', what);
    const n = readNutrients();
    const r = {id:intakeNewId_(state, 'meal'), type:'meal', status:'active', date:d, slot, name, no:mealNo || (Math.max(0, ...same.map(x => x.no)) + 1),
      quantity, unit:content['単位'], kcal:n.kcal ?? null, protein_g:n.protein_g ?? null, fat_g:n.fat_g ?? null, carbohydrate_g:n.carbohydrate_g ?? null,
      source:intakeChoice_(content, '根拠', MEAL_SOURCES_) || '推定', last_app_edit_at:null};
    intakeTouch_(r, id, now); state.records[r.id] = r;
    return {record_id:r.id, undo:{record_id:r.id, before:null}, summary:d + ' ' + slot + ' ' + name + ' ' + r.no};
  }
  const target = intakeOne_(intakeActive_(state, r => r.type === 'meal' && r.date === d && r.slot === slot && r.name === name && (!mealNo || r.no === mealNo)), what);
  intakeCheck_(!(target.last_app_edit_at && firstSeen - target.last_app_edit_at < APP_EDIT_WINDOW_MS_), 'RECENT_APP_EDIT', what);
  const before = intakeCopy_(target);
  if (kind === '取消') {
    intakeAllow_(content, []);
    target.status = 'removed'; intakeTouch_(target, id, now);
    return {record_id:target.id, undo:{record_id:target.id, before}, summary:what};
  }
  if (kind === '修正') {
    intakeAllow_(content, ['量','単位','kcal','P','F','C','根拠','日付','区分']);
    const quantity = intakeNumber_(content, '量', {min:0.01, max:10000}), n = readNutrients();
    const newDate = '日付' in content ? intakeDate_(content['日付']) : undefined;
    const newSlot = '区分' in content ? content['区分'] : undefined;
    intakeCheck_(newSlot === undefined || MEAL_SLOTS_.includes(newSlot), 'INVALID_SLOT', newSlot);
    const source = intakeChoice_(content, '根拠', MEAL_SOURCES_);
    intakeCheck_([quantity, content['単位'], newDate, newSlot, source, ...Object.values(n)].some(v => v !== undefined), 'NO_CHANGE', what);
    if (quantity !== undefined) {
      // 量だけの変更は、保存時の成分を比例計算する（DESIGN 2.2）。明示された成分はその値を使う。
      const factor = quantity / target.quantity;
      ['kcal','protein_g','fat_g','carbohydrate_g'].forEach(k => {
        if (n[k] === undefined && target[k] !== null) target[k] = Math.round(target[k] * factor * 10) / 10;
      });
      target.quantity = quantity;
    }
    Object.keys(n).forEach(k => { if (n[k] !== undefined) target[k] = n[k]; });
    if (content['単位']) target.unit = content['単位'];
    if (source) target.source = source;
    if (newDate !== undefined || newSlot !== undefined) {
      target.date = newDate || target.date; target.slot = newSlot || target.slot;
      const others = intakeActive_(state, r => r !== target && r.type === 'meal' && r.date === target.date && r.slot === target.slot && r.name === target.name);
      if (others.some(r => r.no === target.no)) target.no = Math.max(...others.map(r => r.no)) + 1;
    }
    intakeTouch_(target, id, now);
    return {record_id:target.id, undo:{record_id:target.id, before}, summary:what};
  }
  intakeFail_('INVALID_KIND', kind + '（食事）');
}

function intakeUndo_(state, id, content, now) {
  intakeAllow_(content, ['対象受付番号']);
  const targetId = content['対象受付番号'];
  intakeCheck_(targetId, 'MISSING_FIELD', '対象受付番号');
  const L = state.ledger[targetId];
  intakeCheck_(L && L.status === '保存済み' && L.undo && !L.undone, 'UNDO_INVALID', targetId);
  const record = state.records[L.undo.record_id];
  intakeCheck_(record && record.last_intake === targetId, 'UNDO_NOT_LATEST', targetId);
  if (L.undo.before) {
    const revision = record.revision;
    Object.keys(record).forEach(k => delete record[k]);
    Object.assign(record, intakeCopy_(L.undo.before));
    record.revision = revision;
  } else {
    record.status = 'removed';
  }
  intakeTouch_(record, id, now);
  L.undone = true;
  return {record_id:record.id, undo:null, summary:'戻す ' + targetId};
}

function intakeReview_(state, intakeId, sheetRow, code, detail, now) {
  state.seq++;
  const review = {review_id:hubUUID_(), intake_id:intakeId, sheet_row:sheetRow, reason:code,
    message:(INTAKE_REASONS_[code] || code) + (detail ? '：' + detail : ''), created_at:now, status:'未対応', notified_at:null};
  state.reviews.push(review);
  return review;
}

