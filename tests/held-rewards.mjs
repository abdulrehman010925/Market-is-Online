import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const source=new URL('..',import.meta.url).pathname.replace(/\/$/,'');
const output='/workspace/scratch/5eb5b713d378/network-simulation-4';
const db=new PGlite();
const q=(sql,args=[])=>db.query(sql,args), scalar=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0];
const uid=n=>{const h=createHash('sha256').update('MIO simulation seed 20261002:'+n).digest('hex').slice(0,32);return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`};
let seed=20261002;const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)/4294967296};
const int=(a,b)=>a+Math.floor(random()*(b-a+1));
const as=async id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb,raw_app_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
alter default privileges grant execute on functions to anon,authenticated,service_role;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid() to anon,authenticated;`);
const files=(await readdir(source+'/schema')).filter(x=>/^\d+.*\.sql$/.test(x)).sort();
for(const file of files)await db.exec(await readFile(source+'/schema/'+file,'utf8'));
await db.exec(await readFile(source+'/drafts/held-first-level-rewards.sql','utf8'));
console.log('Loaded exact website migrations:',files.length);
await db.exec('begin');
const company=uid(0),root=uid(1);
await q("update private.operator_setup set email='simulation-company@example.invalid'");
await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,'simulation-company@example.invalid','{\"full_name\":\"Simulation company\"}','{\"provider\":\"google\"}')",[company]);
await q("insert into public.user_roles(user_id,role) values($1,'admin')",[company]);
await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[company]);
const companyRef=await scalar('select referral_code from public.member_profiles where user_id=$1',[company]);
await q('insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)',[root,'simulation-root@example.invalid',JSON.stringify({full_name:'SIM-0001 Premium root',phone:'00000000',terms_accepted:true,referral_code:companyRef}),'{}']);
await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
await as(company);
const rootCode=await scalar('select member_code from public.member_profiles where user_id=$1',[root]);
await q('select public.admin_place_binary_member($1,null,null)',[rootCode]);
await q('insert into private.network_foundation values(true,$1,$2)',[company,root]);
await q("select public.admin_mint_own_mio(550,'Simulation root funding','simulation-root-mint-20261002')");
await q("select public.mio_transfer($1,550,'simulation-root-transfer-20261002')",[root]);
await as(root);const rootActivation=await scalar("select public.activate_package_with_mio('PREMIUM','simulation-root-package-20261002')");
await q("update public.package_activations set activated_at='2026-09-28T12:00:00Z' where id=$1",[rootActivation]);
const nodes=[null,{i:1,id:root,parent:null,level:0,name:'SIM-0001',side:null,target:'PREMIUM',ref:await scalar('select referral_code from public.member_profiles where user_id=$1',[root]),initialQty:0,repeatQty:0}];
for(let i=2;i<=31;i++){
 const parent=Math.floor(i/2),side=i%2===0?'LEFT':'RIGHT',level=Math.floor(Math.log2(i));
 // Exactly half the members at each full level are shopping-activated; membership is randomly shuffled.
 nodes.push({i,id:uid(i),parent,level,name:'SIM-'+String(i).padStart(4,'0'),side});
}
for(let level=1;level<=4;level++){
 const members=nodes.filter(n=>n?.level===level);for(let j=members.length-1;j>0;j--){const k=int(0,j);[members[j],members[k]]=[members[k],members[j]]}
 for(let j=0;j<members.length;j++){
  const n=members[j];if(j<members.length/2){const roll=random();n.target=roll<.30?'BASIC_1':roll<.55?'BASIC_2':roll<.80?'ADVANCED_1':'ADVANCED_2';const range={BASIC_1:[10,15],BASIC_2:[19,42],ADVANCED_1:[46,88],ADVANCED_2:[92,96]}[n.target];n.initialQty=int(...range)}else{n.target='FREE';n.initialQty=int(1,5)}n.repeatQty=int(1,3);
 }
}
await as(company);await q("select public.set_company_delivery(0,'Local simulation only: merchandise funding excludes shipping')");
const vendor=await scalar("select public.create_company_brand('Allure Care',null,'Local isolated simulation')");
await q("update public.vendors set source_url='https://allurecarein.com/',commission_rate=.30,sale_distribution='{\"company\":5,\"buyer_discount\":0,\"affiliate\":0,\"sponsor\":0,\"second_upline\":0,\"introducer\":0,\"network_rewards\":25,\"unallocated\":0}' where id=$1",[vendor]);
const product=await scalar("select public.save_product_listing(null,$1,'Allure Care 1595 simulation','SIM-ALLURE-1595','One actual price used for clear arithmetic','Simulation',1595,1000000,'[\"https://example.invalid/photo.png\"]',true)",[vendor]);
await q('select public.admin_review_product($1,true,1.1962)',[product]);
for(const n of nodes.slice(2)){if(n.level<4&&n.target==='FREE'){n.target='BASIC_1';n.initialQty=12}}

await q("update public.vendors set sale_distribution='{\"company\":5,\"buyer_discount\":0,\"affiliate\":5,\"sponsor\":0,\"second_upline\":0,\"introducer\":0,\"network_rewards\":20,\"unallocated\":0}' where id=$1",[vendor]);
const free=uid(2),child=uid(4);
const signup=async(id,name,ref)=>q('insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)',[id,name+'@example.invalid',JSON.stringify({full_name:name,phone:'00000000',terms_accepted:true,referral_code:ref}),'{}']);
await signup(free,'Free affiliate',nodes[1].ref+'-L');
const freeRef=await scalar('select referral_code from public.member_profiles where user_id=$1',[free]);
await signup(child,'Referred customer',freeRef+'-L');
assert.equal(await scalar('select status from public.member_profiles where user_id=$1',[free]),'inactive');
assert.equal(await scalar('select sponsor_id from public.member_profiles where user_id=$1',[child]),free);
const order=async(buyer,qty,aff,key)=>{await as(buyer);const oid=await scalar('select public.place_affiliate_order($1,$2,$3,$4,$5,$6,$7)',[JSON.stringify([{product_id:product,quantity:qty}]),'Buyer','00000000','Delivery address','City',key,aff]);await as(company);await q('select public.admin_confirm_order_payment($1)',[oid]);return oid};
const oid=await order(child,1,freeRef,'held-affiliate-order-0001');
assert.equal(Number(await scalar('select balance from public.mio_wallet_accounts where member_id=$1',[free])),0);
const held=(await q('select * from public.commission_allocations where order_item_id in(select id from public.order_items where order_id=$1) and share_kind=\'affiliate\'',[oid])).rows[0];
assert.equal(held.status,'held');assert.equal(held.beneficiary_id,free);assert.equal(Number(held.amount_pkr),79.75);
assert.equal(Number(await scalar("select count(*) from public.bonus_transactions where beneficiary_id=$1 and method='direct' and status='pending'",[free])),1);
assert.equal(Number(await scalar('select count(*) from public.reward_point_credits where member_id=$1',[free])),0);
await q('savepoint denied_payment');let blocked=false;try{await q("select public.record_commission_payment($1,'bank-reference-0001')",[held.id])}catch(e){blocked=true}await q('rollback to savepoint denied_payment');assert.ok(blocked);
await as(company);await q("select public.admin_mint_own_mio(11,'Isolated child activation test','held-child-mint-0001')");await q("select public.mio_transfer($1,11,'held-child-package-funding')",[child]);await as(child);const ca=await scalar("select public.activate_package_with_mio('BASIC_1','held-child-package-activation')");assert.equal(Number(await scalar("select payable_amount from public.bonus_transactions where beneficiary_id=$1 and source_activation_id=$2 and method='direct' and status='pending'",[free,ca])),2);assert.equal(Number(await scalar('select balance from public.mio_wallet_accounts where member_id=$1',[free])),0);
await as(free);const preview=await scalar('select public.my_reward_holds()');assert.equal(preview.withdrawal_unlocked,false);assert.ok(Number(preview.held_ppv)>0);assert.ok(Number(preview.held_bv)>0);
const pending=Number(preview.direct_mio);assert.ok(pending>0);await order(free,12,null,'own-shopping-activation-0001');
assert.equal(await scalar('select status from public.member_profiles where user_id=$1',[free]),'active');assert.ok(await scalar('select private.current_package_code($1)',[free]));
assert.equal(Number(await scalar('select balance from public.mio_wallet_accounts where member_id=$1',[free])),pending);
assert.equal(await scalar('select status from public.commission_allocations where id=$1',[held.id]),'earned');
const points=Number(await scalar('select count(*) from public.reward_point_credits where member_id=$1',[free]));assert.equal(points,3);
await q('select private.release_member_holds($1)',[free]);await q('select public.admin_confirm_order_payment($1)',[oid]);
assert.equal(Number(await scalar('select balance from public.mio_wallet_accounts where member_id=$1',[free])),pending);assert.equal(Number(await scalar('select count(*) from public.reward_point_credits where member_id=$1',[free])),points);
assert.equal(Number(await scalar("select count(*) from public.bonus_transactions b join public.orders o on o.id=b.source_order_id where b.beneficiary_id=o.buyer_id")),0);
assert.equal(Number(await scalar("select count(*) from public.shopping_reward_events where direct_generation_mio+single_line_mio+binary_reserve_mio>bv")),0);
// Featured selection replacement and clear remain bounded; rollback keeps actual products untouched.
await q('select public.set_featured_products($1)',[[product]]);await q('select public.set_featured_products($1)',[[product]]);assert.equal(Number(await scalar('select count(*) from public.featured_products')),1);await q('select public.set_featured_products($1)',[[]]);assert.equal(Number(await scalar('select count(*) from public.featured_products')),0);
console.log('PASS free signup/referral, inactive affiliate and minimum direct held, no cash/points before activation, withdrawal denied, own shopping activation, exact release, duplicate release/payment immunity, source funding, featured replace/clear');
await db.exec('rollback');await db.close();
