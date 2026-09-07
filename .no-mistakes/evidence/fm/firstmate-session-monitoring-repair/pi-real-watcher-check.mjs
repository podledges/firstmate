import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
process.title='pi';
process.argv.splice(1,process.argv.length,'pi','--continue');
delete process.env.NO_MISTAKES_GATE;
delete process.env.CLAUDECODE;
const root=process.env.FM_HOME;
const evidence='/home/podles/.no-mistakes/evidence/01M1YRT3TM565HJQ1A1JB3NBMB';
const transcript=[];
const record=(s)=>{transcript.push(s); writeFileSync(`${evidence}/pi-resume-real-watcher.txt`,transcript.join('\n\n')+'\n');};
const get=(p)=>existsSync(`${root}/state/${p}`)?readFileSync(`${root}/state/${p}`,'utf8').trim():'';
const alive=(pid)=>{try{process.kill(Number(pid),0);return true;}catch{return false;}};
const wait=async(f,label)=>{for(let i=0;i<600;i++){if(f())return;await new Promise(r=>setTimeout(r,50));}throw Error(`Timeout: ${label}`);};
writeFileSync(`${root}/state/.lock`,'2147483647\n');
writeFileSync(`${root}/state/task.meta`,'kind=ship\nharness=pi\n');

const handlers=new Map(); let delivered=[];
const pi={
 on(name,handler){handlers.set(name,[...(handlers.get(name)||[]),handler]);},
 registerTool(){},registerCommand(){},events:{on(){}},
 sendMessage(message){writeFileSync(`${evidence}/pi-resumed-startup-digest.txt`,message.content);},
 sendUserMessage(message){
 const successor=get('.watch.lock/pid');
 record(`Pi operational notification:\n${message}\nWatcher PID at delivery: ${successor}; live=${alive(successor)}`);
 delivered.push({message,successor});
 }
};
const emit=async(name,reason)=>{for(const fn of handlers.get(name)||[])await fn({type:name,reason},{sessionManager:{getHeader:()=>({timestamp:'2000-01-01T00:00:00.000Z'})}});};
record('Isolated executable-interface acceptance check. Pi event dispatch/UI are simulated; both tracked extensions, session-start routing/lock acquisition, watch-arm, watcher, inbox and wake persistence are real. Bootstrap and deferred network are disabled in the disposable fixture. No production process or Herdr runtime is used.');
for(const name of ['fm-primary-pi-watch','fm-primary-turnend-guard']) (await import(pathToFileURL(`${root}/.pi/extensions/${name}.ts`))).default(pi);
let first, replacement;
try{
 await emit('session_start','startup');
 assert.equal(get('.lock'),String(process.pid));
 assert.equal(get('.session-start-complete'),String(process.pid));
 record(`Restored --continue session started with a stale lock. Actual startup acquired lock PID ${get('.lock')} and published matching completion receipt.`);
 await emit('resources_discover','startup');
 await wait(()=>get('.watch.lock/pid') && get('.last-watcher-beat')!==undefined && existsSync(`${root}/state/.last-watcher-beat`),'automatic real watcher');
 first=get('.watch.lock/pid'); assert(alive(first));
 record(`Automatic first watcher: PID ${first}, live=${alive(first)}, beacon exists. No arm tool invocation.`);
 await emit('session_compact','manual');
 await emit('resources_discover','startup');
 assert.equal(get('.watch.lock/pid'),first);
 record(`Compaction and repeated discovery retained watcher PID ${first}.`);
 const note=spawnSync('bash',[`${root}/bin/fm-inbox.sh`,'note','Acceptance check: monitoring resumed without a manual arm.'],{encoding:'utf8'});
 assert.equal(note.status,0,note.stderr);record(`$ fm-inbox.sh note 'Acceptance check: monitoring resumed without a manual arm.'\n${note.stdout}${note.stderr}`);
 await wait(()=>delivered.length>0,'queued wake notification');
 replacement=delivered[0].successor;
 assert(replacement && replacement!==first && alive(replacement),'successor must be live before notification');
 record(`Durable wake queue:\n${get('.wake-queue')}\n\nCycle lifecycle ledger:\n${get('.watch-cycle-exits.log')}`);
 assert(get('.wake-queue').includes('inbox'));
 const inbox=spawnSync('bash',[`${root}/bin/fm-inbox.sh`,'drain'],{encoding:'utf8'});
 assert.equal(inbox.status,0,inbox.stderr); assert(inbox.stdout.includes('Acceptance check: monitoring resumed'));
 record(`$ fm-inbox.sh drain\n${inbox.stdout}${inbox.stderr}`);
}finally{
 await emit('session_shutdown','quit');
 await wait(()=>!get('.watch.lock/pid')||!alive(get('.watch.lock/pid')),'isolated watcher retirement');
 record('Session shutdown retired the isolated watcher. Late discovery is tested by the targeted lifecycle matrix.');
}
