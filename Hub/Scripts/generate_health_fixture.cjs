// GASの合成保存結果をSwiftの行/操作/台帳境界へ渡す。実Googleには接続しません。
const fs = require('node:fs'), path = require('node:path');
const f = require('../Server/health-storage-p6-test.cjs');
const {h, copy, id, now, sample, statistic, operation, save, mockFiles} = f;
const store = h.fresh(), files = mockFiles(h);
store.config.environment = 'PHH_PRODUCTION';
h.ctx.hubSet_(store, 'environment', 'PHH_PRODUCTION', now); store.commit();
const weight = operation('bodyMass', [sample('bodyMass', 1)]); weight.environment = 'PHH_PRODUCTION';
const weightReceipt = save(store, files, weight);
const steps = operation('stepCount', [], [], [statistic('stepCount', '2026-10-03', 0)]); steps.environment = 'PHH_PRODUCTION';
const stepsReceipt = save(store, files, steps);
const query = {schema_version: 1, environment: 'PHH_PRODUCTION', synthetic: true, generation: 1, after: 0, limit: 100};
const delta = copy(h.ctx.hubChanges_(store, query));
const output = path.resolve(__dirname, '../Core/Tests/PHHHubCoreTests/Resources/health-server-fixture.json');
fs.writeFileSync(output, JSON.stringify({operations: [weight, steps], receipts: [weightReceipt, stepsReceipt], delta}, null, 2) + '\n');
console.log('health fixture: '+delta.changes.length+' changes, '+delta.health_contract+' contract');
