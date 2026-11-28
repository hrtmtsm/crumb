// Runs only in an isolated, disposable PostgreSQL/WASM database. Never connects to Supabase.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth; create schema storage; create schema extensions;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth,storage to authenticated,anon,service_role;
grant execute on function auth.uid() to authenticated,anon,service_role;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);
alter table storage.objects enable row level security;
grant select,insert,update,delete on storage.objects to authenticated;
-- PGlite lacks pgcrypto. Use core SHA-256 and UUID randomness solely for the SQL access-control tests.
-- This adapter does not test production pgcrypto's entropy implementation.
create function extensions.digest(value text, algorithm text) returns bytea language sql as $$ select sha256(convert_to(value,'UTF8')) $$;
create function extensions.gen_random_bytes(n integer) returns bytea language sql as $$ select substring(decode(replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),'hex') from 1 for n) $$;
`);
let sql = readFileSync(new URL('../migrations/202611280001_library_and_plans.sql', import.meta.url),'utf8');
sql = sql.replace('create extension if not exists pgcrypto with schema extensions;', '');
await db.exec(sql);
const alice='11111111-1111-4111-8111-111111111111', bob='22222222-2222-4222-8222-222222222222', eve='33333333-3333-4333-8333-333333333333';
await db.query('insert into auth.users values($1),($2),($3)',[alice,bob,eve]);
async function as(user,fn) {
 await db.exec('set role authenticated');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
 try { return await fn(); } finally { await db.exec('reset role'); }
}
async function one(sql,args=[]) { return (await db.query(sql,args)).rows[0]?.value; }
async function denied(fn) { await assert.rejects(fn); }
const empty={recipes:[]};
const mine=await as(alice,()=>one("select public.crumb_create_book('default','My Menu') as value"));
assert.equal(mine.owner_plus,false);
await as(alice,async()=>{
 await denied(()=>one("select public.crumb_create_book('extra','Dinner') as value"));
 await denied(()=>one('select public.crumb_save_book($1,1,$2) as value',[mine.id,empty]));
 await denied(()=>db.query("insert into public.crumb_plan_access(user_id,valid_until,revoked,event_at,source) values($1,now()+interval '1 year',false,now(),'beta')",[alice]));
 await denied(()=>one("select public.crumb_apply_store_event($1,now()+interval '1 year',false,now(),'forged') as value",[alice]));
});
await db.query("insert into public.crumb_plan_access(user_id,valid_until,event_at,source) values($1,now()+interval '1 day',now(),'beta')",[alice]);
const dinner=await as(alice,()=>one("select public.crumb_create_book('extra','Dinner') as value"));
assert.equal(dinner.owner_plus,true);
await as(eve,async()=>{
 assert.equal(await one('select public.crumb_can_read_book($1) as value',[dinner.id]),false);
 assert.equal((await db.query('select * from public.crumb_books')).rows.length,0);
 await denied(()=>one('select public.crumb_save_book($1,1,$2) as value',[dinner.id,empty]));
 await denied(()=>one('select public.crumb_create_invite($1) as value',[dinner.id]));
});
const token=await as(alice,()=>one('select public.crumb_create_invite($1) as value',[dinner.id]));
assert.match(token,/^[0-9a-f]{64}$/);
await as(bob,async()=>{
 assert.equal(await one('select public.crumb_accept_invite($1) as value',[token]),dinner.id);
 assert.equal(await one('select public.crumb_can_write_book($1) as value',[dinner.id]),true);
 assert.equal(await one('select public.crumb_save_book($1,1,$2) as value',[dinner.id,empty]),2);
 assert.equal(await one('select public.crumb_my_plan() as value').then(x=>x.active),false);
 await denied(()=>one('select public.crumb_create_invite($1) as value',[dinner.id]));
});
await as(eve,()=>denied(()=>one('select public.crumb_accept_invite($1) as value',[token])));
const token2=await as(alice,()=>one('select public.crumb_create_invite($1) as value',[dinner.id]));
await as(alice,()=>one('select public.crumb_revoke_invites($1) as value',[dinner.id]));
await as(eve,()=>denied(()=>one('select public.crumb_accept_invite($1) as value',[token2])));
// A multi-book move fails atomically when any revision is stale.
await as(alice,()=>denied(()=>one('select public.crumb_save_library($1) as value',[[{id:mine.id,revision:1,snapshot:{recipes:[{id:'test'}]}},{id:dinner.id,revision:1,snapshot:empty}]])));
assert.equal((await db.query('select revision from public.crumb_books where id=$1',[mine.id])).rows[0].revision,1);
// Storage is private. Read/write uses the book owner's plan, never the invited member's plan.
await as(bob,async()=>{
 assert.equal(await one('select public.crumb_storage_access($1,false) as value',[`b/${dinner.id}/photo.jpg`]),true);
 assert.equal(await one('select public.crumb_storage_access($1,true) as value',[`u/${alice}/photo.jpg`]),false);
});
await db.query("update public.crumb_plan_access set valid_until=now()-interval '1 second' where user_id=$1",[alice]);
await as(bob,async()=>{
 assert.equal(await one('select public.crumb_can_read_book($1) as value',[dinner.id]),true);
 assert.equal(await one('select public.crumb_can_write_book($1) as value',[dinner.id]),false);
 await denied(()=>one('select public.crumb_save_book($1,2,$2) as value',[dinner.id,empty]));
});
await as(alice,()=>one('select public.crumb_remove_member($1,$2) as value',[dinner.id,bob]));
await as(bob,()=>one('select public.crumb_can_read_book($1) as value',[dinner.id]).then(x=>assert.equal(x,false)));
// Old renewal replays cannot override a newer refund.
await db.exec("update public.crumb_plan_access set event_at='2020-01-01' where user_id='"+alice+"'");
await db.query("select public.crumb_apply_store_event($1,now()+interval '1 month',true,now(),'original')",[alice]);
await db.query("select public.crumb_apply_store_event($1,now()+interval '1 year',false,now()-interval '1 minute','original')",[alice]);
assert.equal(await as(alice,()=>one('select public.crumb_my_plan() as value')).then(x=>x.active),false);
await db.close();
console.log('PASS: Free/Plus, RLS isolation, owner-paid collaboration, single-use/revoked invites, atomic CAS, private storage, expiry, member removal, refund replay');
