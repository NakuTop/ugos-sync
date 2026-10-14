#!/usr/bin/env python3
"""Install only our controller. Vendor engine and private profile are never distributed."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, time

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp=path.with_name('.write-'+str(os.getpid()))
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream: stream.write(data)
    os.replace(tmp,path)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--replace-agent',action='append',default=[],help='Explicit legacy LaunchAgent label to back up and disable')
    parser.add_argument('--settings',type=pathlib.Path,required=True,help='Existing private engine settings, captured locally from your installed client')
    args=parser.parse_args()
    home=pathlib.Path.home(); root=home/'Library/Application Support/UGOSSync'
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    if root.is_symlink(): raise RuntimeError('Private root must not be a symlink')
    st=args.settings.lstat()
    if st.st_uid!=os.getuid() or st.st_mode&0o077: raise RuntimeError('Settings must be private to the current user')
    settings=json.loads(args.settings.read_text())
    engine=pathlib.Path(settings['executable'])
    subprocess.run(['codesign','--verify','--strict',str(engine)],check=True)
    if hashlib.sha256(engine.read_bytes()).hexdigest()!=settings['engineSHA256']:raise RuntimeError('Engine changed')
    bundle=pathlib.Path(__file__).resolve().parent.parent/'dist/UGOS Sync.app'
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    app=home/'Applications/UGOS Sync.app';app.parent.mkdir(exist_ok=True)
    backup=root/'backups'/str(time.time_ns());backup.mkdir(parents=True,mode=0o700)
    if app.exists(): shutil.make_archive(str(backup/'app'), 'zip', app.parent, app.name);shutil.rmtree(app)
    shutil.copytree(bundle,app)
    binroot=root/'bin';binroot.mkdir(exist_ok=True,mode=0o700)
    destination=binroot/'syncspace_pro'
    if engine!=destination: shutil.copy2(engine,destination)
    settings['executable']=str(destination);settings['statusFile']=str(root/'engine-status.json')
    write(root/'engine-settings.json',json.dumps(settings).encode())
    labels=['com.nakutop.ugos-sync.engine','com.nakutop.ugos-sync.daemon','com.nakutop.ugos-sync.ui']
    programs=[['UGOSSyncEngine',str(root/'engine-settings.json')],['UGOSSyncDaemon'],['UGOSSync','--background']]
    agents=home/'Library/LaunchAgents';agents.mkdir(exist_ok=True)
    domain='gui/'+str(os.getuid())
    # Preserve previous prototypes; bootout stops their owned child and prevents duplicate profile use.
    for label in args.replace_agent+labels:
        path=agents/(label+'.plist')
        if path.exists():
            shutil.copy2(path,backup/path.name)
            subprocess.run(['launchctl','bootout',domain,str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if label in args.replace_agent:path.rename(backup/('disabled-'+path.name))
    for label,argv in zip(labels,programs):
        path=agents/(label+'.plist')
        values={'Label':label,'ProgramArguments':[str(app/'Contents/MacOS'/argv[0])]+argv[1:],'RunAtLoad':True,'KeepAlive':not label.endswith('.ui'),'ThrottleInterval':15,'ProcessType':'Background'}
        write(path,plistlib.dumps(values))
        subprocess.run(['launchctl','bootstrap',domain,str(path)],check=True)
    print('Installed UGOS Sync with independent engine, heartbeat and menu bar services.')
if __name__=='__main__':main()
