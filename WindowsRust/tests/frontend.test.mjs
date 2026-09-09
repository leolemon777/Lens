import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {formatDuration,cropFromDrag,controlsFor,filterProjects,sourceCaption,phaseLabels} from '../frontend/utils.mjs';

test('clock formats zero',()=>assert.equal(formatDuration(0),'00:00'));
test('clock formats hours without losing minutes',()=>assert.equal(formatDuration(3723.9),'01:02:03'));
test('clock rejects nonfinite values',()=>assert.equal(formatDuration(Infinity),'00:00'));
test('clock clamps negative values',()=>assert.equal(formatDuration(-3),'00:00'));
test('crop maps 200 percent DPI to physical pixels',()=>assert.deepEqual(cropFromDrag({x:10,y:20},{x:210,y:120},3840,2160,1920,1080),{x:20,y:40,width:400,height:200}));
test('crop accepts dragging from bottom-right',()=>assert.deepEqual(cropFromDrag({x:200,y:100},{x:0,y:0},1920,1080,1920,1080),{x:0,y:0,width:200,height:100}));
test('crop rounds inward at fractional DPI',()=>assert.deepEqual(cropFromDrag({x:1,y:1},{x:10,y:10},1250,1250,1000,1000),{x:2,y:2,width:10,height:10}));
test('crop clamps to capture bounds',()=>assert.deepEqual(cropFromDrag({x:-2,y:-1},{x:110,y:120},100,100,100,100),{x:0,y:0,width:100,height:100}));
test('crop rejects an empty selection',()=>assert.throws(()=>cropFromDrag({x:1,y:1},{x:1,y:2},100,100,100,100)));
test('crop rejects invalid viewport',()=>assert.throws(()=>cropFromDrag({x:0,y:0},{x:9,y:9},100,100,0,100)));
test('crop rejects NaN',()=>assert.throws(()=>cropFromDrag({x:NaN,y:0},{x:9,y:9},100,100,100,100)));
test('idle allows start with a source',()=>assert.equal(controlsFor('idle',false,true,true).record,true));
test('record disabled without a source',()=>assert.equal(controlsFor('idle',false,false,true).record,false));
test('busy prevents repeated starts',()=>assert.equal(controlsFor('idle',true,true,true).record,false));
test('recording cannot change source',()=>assert.equal(controlsFor('recording',false,true,true).configure,false));
test('pause needs the media component',()=>assert.equal(controlsFor('recording',false,true,false).pause,false));
test('paused allows stop and resume',()=>{const c=controlsFor('paused',false,true,true);assert.equal(c.stop,true);assert.equal(c.pause,true);assert.equal(c.record,false)});
test('processing cannot be stopped twice',()=>assert.equal(controlsFor('processing',false,true,true).stop,false));
test('title search is literal and case-insensitive',()=>assert.equal(filterProjects([{manifest:{title:'Lens DEMO'}},{manifest:{title:'<script>demo</script>'}}],'LENS').length,1));
test('selected crop is reflected in source caption',()=>assert.equal(sourceCaption({label:'Screen'},{width:200,height:100}),'区域 200 × 100'));
test('all native phases have a display label',()=>{for(const p of ['idle','starting','recording','pausing','paused','stopping','processing'])assert.ok(phaseLabels[p])});
test('statically named frontend commands are registered in Rust',()=>{
  const main=readFileSync(new URL('../src-tauri/src/main.rs',import.meta.url),'utf8');
  const js=['app.mjs','region.mjs'].map(f=>readFileSync(new URL('../frontend/'+f,import.meta.url),'utf8')).join('\n');
  const commands=[...js.matchAll(/(?:invoke|action)\('([a-z_]+)'/g)].map(m=>m[1]);
  for(const command of new Set(commands)){assert.match(main,new RegExp('fn '+command+'\\('));assert.ok(main.slice(main.indexOf('generate_handler!')).includes(command),`${command} registered`)}
});
test('browser preview never implements a fake record function',()=>{
  const js=readFileSync(new URL('../frontend/app.mjs',import.meta.url),'utf8');
  assert.ok(js.includes('if (!native) throw new Error'));assert.ok(js.includes('const hasSource = native &&'));
});
