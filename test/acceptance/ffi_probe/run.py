"""Run paired standalone transport samples; these are NOT bootstrap adoption results."""
import argparse,hashlib,json,math,re,statistics,subprocess,time
from pathlib import Path

def run(apk,serial,out,rounds=20,batches=2,stop_mode='force-stop'):
    out.mkdir(parents=True,exist_ok=False)
    report=dict(status='running',scope='transport_probe_only',apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),
        rounds=rounds,batches=batches,stop_mode=stop_mode,samples=[],completed=[])
    adb=['adb','-s',serial];package='com.example.wp24_probe'
    def call(args):return subprocess.check_output(adb+args,text=True,stderr=subprocess.STDOUT,timeout=120)
    def save():(out/'result.json').write_text(json.dumps(report,indent=2))
    logger=None
    try:
        install=call(['install','-r',str(apk)]);(out/'install.log').write_text(install)
        if 'Success' not in install:raise RuntimeError('Installation failed')
        with (out/'logcat.txt').open('w',encoding='utf-8') as log:
            logger=subprocess.Popen(adb+['logcat','-T','1','-v','epoch','flutter:I','AndroidRuntime:E','*:S'],stdout=log)
            for batch in range(batches):
                for index in range(rounds):
                    sizes=[0,65536,2097152,16777216]
                    sizes=sizes[index%4:]+sizes[:index%4]
                    for size in sizes:
                        modes=['channel','ffi'] if (batch+index)%2==0 else ['ffi','channel']
                        for mode in modes:
                            if stop_mode=='background-kill':
                                call(['shell','am','start','-W','-a','android.intent.action.MAIN','-c','android.intent.category.HOME'])
                                time.sleep(1)
                                call(['shell','am','kill',package])
                                deadline=time.monotonic()+5
                                while time.monotonic()<deadline:
                                    p=subprocess.run(adb+['shell','pidof',package],capture_output=True,text=True,timeout=5)
                                    if p.returncode==1 and not p.stdout.strip():break
                                    time.sleep(.25)
                                else:raise RuntimeError('Background process did not exit; no force-stop fallback')
                            else:call(['shell','am','force-stop',package])
                            time.sleep(3)
                            offset=(out/'logcat.txt').stat().st_size
                            started=call(['shell','am','start','-W','-f','0x10008000','-n',package+'/.MainActivity','--es','probe_mode',f'{mode}:{size}'])
                            (out/f'{batch}-{index}-{size}-{mode}.start').write_text(started)
                            deadline=time.monotonic()+40
                            while time.monotonic()<deadline:
                                with (out/'logcat.txt').open('rb') as reader:
                                    reader.seek(offset);text=reader.read().decode('utf-8',errors='replace')
                                if 'WP24_DONE:' in text:break
                                time.sleep(.25)
                            else:raise RuntimeError(f'Probe timed out {batch}/{index}/{size}/{mode}')
                            samples=[];done=[]
                            for line in text.splitlines():
                                if 'WP24_SAMPLE: ' in line:samples.append(json.loads(line.split('WP24_SAMPLE: ',1)[1]))
                                if 'WP24_DONE: ' in line:done.append(json.loads(line.split('WP24_DONE: ',1)[1]))
                            if len(done)!=1 or done[0]['ownership']!='passed' or len(samples)!=2 or {r['phase'] for r in samples}!={'cold','post_frame'}:
                                raise RuntimeError('Incomplete paired trace')
                            if any(r['mode']!=mode or r['size']!=size or r['pid']!=done[0]['pid'] for r in samples):raise RuntimeError('Trace identity mismatch')
                            time.sleep(3)
                            if call(['shell','pidof',package]).strip()!=str(done[0]['pid']):raise RuntimeError('Process did not survive first-frame dwell')
                            report['samples'].extend(dict(r,batch=batch,round=index) for r in samples)
                            report['completed'].append(dict(done[0],batch=batch,round=index,size=size,mode=mode))
                            save()
                    print(f'batch {batch+1}/{batches}, round {index+1}/{rounds}: passed',flush=True)
        report['status']='passed'
    except BaseException as error:
        report['status']='interrupted' if isinstance(error,KeyboardInterrupt) else 'failed'
        exits=subprocess.run(adb+['shell','dumpsys','activity','exit-info',package],capture_output=True,text=True,timeout=15)
        (out/'exit-info.txt').write_text(exits.stdout,encoding='utf-8')
        report['error']=str(error);raise
    finally:
        if logger:logger.terminate();logger.wait(timeout=10)
        save()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['apk','out']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--serial',required=True);p.add_argument('--rounds',type=int,default=20);p.add_argument('--batches',type=int,default=2)
    p.add_argument('--stop-mode',choices=['force-stop','background-kill'],default='force-stop')
    a=p.parse_args()
    if a.rounds<1 or a.batches<1:p.error('Positive sample counts required')
    run(**vars(a))
