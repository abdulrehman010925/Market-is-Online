import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const source=new URL('..',import.meta.url);
const legacy=await readFile(new URL('supabase/migrations/20261026193322_disable_legacy_non_pin_transaction_rpcs.sql',source),'utf8');
const protectedRpc=await readFile(new URL('supabase/migrations/20261022170000_restrict_pin_transaction_rpcs.sql',source),'utf8');

for(const signature of [
 'public.mio_transfer(uuid,numeric,text)',
 'public.mio_transfer_to_member_code(text,numeric,text)',
 'public.activate_package_with_mio(text,text)'
]){
 assert.ok(legacy.includes(`revoke all on function ${signature} from public,anon,authenticated;`));
}
assert.ok(protectedRpc.includes('grant execute on function public.mio_transfer(uuid,numeric,text,text) to authenticated;'));
assert.ok(protectedRpc.includes('grant execute on function public.activate_package_with_mio(text,text,text) to authenticated;'));
console.log('PASS legacy transaction RPC grants are revoked and PIN-protected overloads stay available');
