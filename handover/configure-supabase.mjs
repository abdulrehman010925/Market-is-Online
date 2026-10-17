import { copyFile, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const projectUrl=process.env.MIO_SUPABASE_URL?.trim();
const publishableKey=process.env.MIO_SUPABASE_PUBLISHABLE_KEY?.trim();

if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(projectUrl||'')){
  throw new Error('Set MIO_SUPABASE_URL to the new https://PROJECT_REF.supabase.co URL.');
}
if(!publishableKey||publishableKey.length<20||/^eyJ/i.test(publishableKey)&&publishableKey.split('.').length!==3){
  throw new Error('Set MIO_SUPABASE_PUBLISHABLE_KEY to the new project publishable key. Never use service_role.');
}

const target=resolve('dist/app.js');
const backup=resolve('dist/app.js.before-supabase-change');
const source=await readFile(target,'utf8');
const next=source
  .replace(/const SUPABASE_URL='[^']*';/,`const SUPABASE_URL='${projectUrl}';`)
  .replace(/const SUPABASE_PUBLISHABLE_KEY='[^']*';/,`const SUPABASE_PUBLISHABLE_KEY='${publishableKey.replaceAll("'",'')}';`);

if(next===source)throw new Error('Supabase configuration constants were not found in dist/app.js.');
await copyFile(target,backup);
await writeFile(target,next);
console.log('Updated dist/app.js. Backup: dist/app.js.before-supabase-change');
