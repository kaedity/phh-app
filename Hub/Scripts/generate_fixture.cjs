// 本番サーバーの既存試験アダプターから、Swift境界用の架空応答を生成する。外部接続なし。
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),server=path.join(root,'Hub/Server');
let counter=0;const deterministicCrypto={...crypto,randomUUID:()=>`00000000-0000-4000-8000-${String(++counter).padStart(12,'0')}`};
const source=fs.readFileSync(path.join(server,'server-test.cjs'),'utf8').split("test('B2 normal set")[0];
const build=`
const s=fresh();s.config.environment='PHH_PRODUCTION';ctx.hubSet_(s,'environment','PHH_PRODUCTION',now);s.commit();
const p={local_date:'2026-10-01',slot:'間食',name:'記録テスト',quantity:1,unit:'個',source:'本人',kcal:100,protein_g:10,fat_g:0,carbohydrate_g:15};
const op=meal('confirm_meal',crypto.randomUUID(),0,p);op.environment='PHH_PRODUCTION';const receipt=app(s,op);
const q={schema_version:1,environment:'PHH_PRODUCTION',synthetic:true,generation:1,after:0,limit:100};const initial=copy(ctx.hubChanges_(s,q));
const update=meal('update_meal',op.entity_id,1,{...p,quantity:2,kcal:200,protein_g:20,carbohydrate_g:30});update.environment='PHH_PRODUCTION';app(s,update);
intake(s,set('swift-contract-set'),2);
const latest=copy(ctx.hubChanges_(s,q));
const removal=meal('remove_meal',op.entity_id,2,null);removal.environment='PHH_PRODUCTION';const removalReceipt=app(s,removal);
const removed=copy(ctx.hubChanges_(s,{...q,after:latest.next_cursor}));
fs.writeFileSync(output,JSON.stringify({operation:op,receipt,initial,latest,removal,removalReceipt,removed},null,2)+'\\n');
`;
const output=path.join(root,'Hub/Core/Tests/PHHHubCoreTests/Resources/server-fixture.json');fs.mkdirSync(path.dirname(output),{recursive:true});
vm.runInNewContext(source+build,{require:n=>n==='node:crypto'?deterministicCrypto:require(n),console,Buffer,__dirname:server,output});
console.log('Synthetic server fixture generated');
