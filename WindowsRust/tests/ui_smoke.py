"""Browser interaction tests with an EXPLICITLY MOCKED Tauri bridge.
These tests do not compile Rust or prove Windows screen/audio recording.
Requires Python playwright and an installed Chromium browser.
"""
from pathlib import Path
import json, shutil, os, re
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'tests' / 'artifacts'
ARTIFACTS.mkdir(parents=True, exist_ok=True)
MOCK = r"""
window.__calls=[]; window.__listeners={};
window.__mock={phase:'idle',ffmpeg:true,failStart:false,projects:[]};
const sample={id:'display:1',label:'测试显示器（模拟接口）',kind:'display',width:1920,height:1080,x:0,y:0};
window.__TAURI__={
  core:{convertFileSrc:p=>p,invoke:async(command,args={})=>{
    window.__calls.push({command,args}); const s=window.__mock;
    switch(command){
      case 'app_info':return {version:'0.1.0-test',libraryPath:'C:\\Test\\Lens-Windows',ffmpegAvailable:s.ffmpeg};
      case 'list_sources':return [sample,{...sample,id:'window:2',kind:'window',label:'测试窗口',width:1280,height:720}];
      case 'record_status':return {phase:s.phase,elapsedSeconds:s.phase==='idle'?0:12.3,projectPath:null,message:'模拟状态：'+s.phase,systemLevel:20,microphoneLevel:35,freeGiB:128.6};
      case 'list_projects':return s.projects;
      case 'start_recording':if(s.failStart)throw '模拟：捕获设备不可用';s.phase='starting';await new Promise(r=>setTimeout(r,180));s.phase='recording';return null;
      case 'pause_recording':s.phase='paused';return null;
      case 'resume_recording':s.phase='recording';return null;
      case 'stop_recording':s.phase='processing';await new Promise(r=>setTimeout(r,80));s.phase='idle';return 'C:\\Test\\project.lens';
      case 'take_screenshot':return 'C:\\Test\\shot.lens';
      case 'select_region':window.__listeners['region-picked']?.({payload:{sourceId:args.sourceId,crop:{x:10,y:20,width:640,height:360}}});return null;
      case 'open_project':return null;
      case 'retry_export':return null;
      case 'region_context':return sample;
      case 'finish_region':return null;
      default:throw 'Unexpected mock command: '+command;
    }
  }},
  event:{listen:async(name,handler)=>{window.__listeners[name]=handler;return ()=>{};}}
};
"""
results=[]
def passed(name):
    results.append({'name':name,'status':'passed','scope':'mocked frontend / browser only'})
    print('PASS', name)

def load_local(page, filename='index.html'):
    # Render local content directly; no HTTP server access or external network is needed.
    html=(ROOT/'frontend'/filename).read_text(encoding='utf-8')
    html=re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>', '', html)
    html=re.sub(r'<link[^>]*rel="stylesheet"[^>]*>', '', html)
    page.set_content(html)
    stem='region' if filename=='region.html' else 'app'
    css='region.css' if stem=='region' else 'styles.css'
    page.add_style_tag(content=(ROOT/'frontend'/css).read_text(encoding='utf-8'))
    utilities=(ROOT/'frontend'/'utils.mjs').read_text(encoding='utf-8').replace('export ', '')
    javascript=(ROOT/'frontend'/(stem+'.mjs')).read_text(encoding='utf-8')
    javascript=re.sub(r"^import .*?;\n", '', javascript, count=1)
    page.add_script_tag(content=utilities+'\n'+javascript, type='module')
try:
  with sync_playwright() as p:
    browser=p.chromium.launch(headless=True, executable_path=os.environ.get("CHROMIUM") or shutil.which("chromium"))
    # Real browser fallback: no injected bridge and therefore NO fake recorder.
    preview=browser.new_page(viewport={'width':1200,'height':900},device_scale_factor=1)
    load_local(preview);expect(preview.locator('#preview-banner')).to_be_visible();expect(preview.locator('#record')).to_be_disabled()
    preview.screenshot(path=str(ROOT/'docs'/'UI-PREVIEW.png'),full_page=True)
    passed('Browser-only preview displays warning and refuses recording')
    preview.close()
    page=browser.new_page(viewport={'width':1200,'height':900})
    errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
    page.evaluate(MOCK);load_local(page)
    expect(page.locator('#record')).to_be_enabled()
    expect(page.locator('#source')).to_have_value('display:1')
    passed('Native-bridge source list is bound to the selector')
    page.locator('[data-mode="window"]').click();expect(page.locator('#source')).to_have_value('window:2')
    page.locator('[data-mode="region"]').click();expect(page.locator('#record')).to_be_disabled()
    page.locator('#pick-region').click();expect(page.locator('#source-caption')).to_have_text('区域 640 × 360');expect(page.locator('#record')).to_be_enabled()
    passed('Region mode prevents recording until a crop is selected')
    page.locator('[data-fps="60"]').click();page.locator('#microphone').check()
    page.evaluate("document.getElementById('record').click();document.getElementById('record').click()")
    expect(page.locator('#phase-label')).to_have_text('正在录制')
    starts=page.evaluate("window.__calls.filter(c=>c.command==='start_recording')")
    assert len(starts)==1 and starts[0]['args']['options']['fps']==60 and starts[0]['args']['options']['microphone']
    assert starts[0]['args']['options']['crop']=={'x':10,'y':20,'width':640,'height':360}
    expect(page.locator('#source')).to_be_disabled()
    passed('Start forwards real option shape and prevents duplicate commands')
    page.locator('#pause').click();expect(page.locator('#phase-label')).to_have_text('已暂停')
    page.locator('#pause').click();expect(page.locator('#phase-label')).to_have_text('正在录制')
    passed('Pause and resume reflect backend states rather than local timers')
    page.evaluate("window.__listeners['close-blocked']({payload:'请先停止录制'})")
    expect(page.locator('#toast')).to_contain_text('请先停止录制')
    passed('Close protection event is visibly presented')
    page.locator('#stop').click();expect(page.locator('#record')).to_be_enabled()
    passed('Stop returns to idle after the mocked processing response')
    page.locator('#screenshot').click();expect(page.locator('#toast')).to_contain_text('截图已保存')
    assert page.evaluate("window.__calls.some(c=>c.command==='take_screenshot')")
    passed('Screenshot button invokes native command, not browser getDisplayMedia')
    page.evaluate("window.__mock.failStart=true")
    page.locator('#record').click();expect(page.locator('#toast')).to_contain_text('捕获设备不可用');expect(page.locator('#record')).to_be_enabled()
    passed('Capture errors are surfaced and do not show fake success')
    page.evaluate(r"""window.__mock.projects=[{path:'C:\\Test\\p.lens',manifest:{title:'<img src=x onerror=alert(1)>',kind:'recording',createdAt:'2026-09-08T00:00:00Z',state:'interrupted',durationSeconds:9,dimensions:{width:1920,height:1080}},thumbnail:null,preview:null,recoverable:true}]""")
    page.locator('[data-page="library"]').click();expect(page.locator('.project-card')).to_have_count(1)
    expect(page.locator('.project-copy h3')).to_have_text('<img src=x onerror=alert(1)>')
    expect(page.locator('.project-copy img')).to_have_count(0)
    page.locator('#search').fill('not-found');expect(page.locator('.project-card')).to_have_count(0)
    passed('Library titles are escaped as text and literal search filters results')
    assert errors==[], errors
    passed('No unhandled browser exceptions in the normal interaction flow')
    page.close()
    # Missing optional FFmpeg is a real capability state, not a decorative toggle.
    page=browser.new_page();page.evaluate(MOCK+"\nwindow.__mock.ffmpeg=false;");load_local(page)
    expect(page.locator('#record')).to_be_enabled();expect(page.locator('#system-audio')).to_be_disabled();expect(page.locator('#microphone')).to_be_disabled();expect(page.locator('#media-warning')).to_be_visible()
    page.locator('#record').click();expect(page.locator('#phase-label')).to_have_text('正在录制');expect(page.locator('#pause')).to_be_disabled();expect(page.locator('#stop')).to_be_enabled()
    passed('Missing FFmpeg disables audio and pause but permits silent single-segment recording')
    page.close()
    # Exercise the actual region-page coordinate conversion with mocked native output.
    page=browser.new_page(viewport={'width':960,'height':540});page.evaluate(MOCK);load_local(page, 'region.html')
    page.wait_for_timeout(150);page.mouse.move(10,20);page.mouse.down();page.mouse.move(210,120);page.mouse.up()
    page.wait_for_function("window.__calls.some(c=>c.command==='finish_region')")
    args=page.evaluate("window.__calls.find(c=>c.command==='finish_region').args")
    assert args['crop']=={'x':20,'y':40,'width':400,'height':200},args
    passed('Region overlay converts CSS drag bounds to physical pixels')
    browser.close()
finally:
  pass
(ARTIFACTS/'ui-smoke-results.json').write_text(json.dumps({'scope':'Browser tests using a mocked Tauri bridge. NOT Windows capture tests.','results':results},ensure_ascii=False,indent=2),encoding='utf-8')
print(f'{len(results)} mocked-frontend checks passed; Windows native capture NOT RUN.')
