#!/usr/bin/env python3
"""Capture the owner's running installed engine without printing credentials."""
import argparse, ctypes, hashlib, json, os, pathlib, shutil, struct, subprocess
from install import write

def process_args(pid):
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    mib=(ctypes.c_int*3)(1,49,pid);size=ctypes.c_size_t(1024*1024);buf=ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib,3,buf,ctypes.byref(size),None,0):raise RuntimeError('Could not read own engine arguments')
    data=buf.raw[:size.value];argc=struct.unpack_from('i',data)[0];offset=data.index(b'\0',4)+1
    while offset<len(data) and data[offset]==0:offset+=1
    argv=[]
    for _ in range(argc):
        end=data.index(b'\0',offset);argv.append(os.fsdecode(data[offset:end]));offset=end+1
    env={}
    allowed={'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy','LANG','LC_ALL','LC_CTYPE'}
    for entry in data[offset:].split(b'\0'):
        if b'=' in entry:
            key,value=entry.split(b'=',1)
            if os.fsdecode(key) in allowed:env[os.fsdecode(key)]=os.fsdecode(value)
    return argv,env

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--work-folder',type=pathlib.Path,required=True)
    parser.add_argument('--profile',type=pathlib.Path,help='Select one existing profile when multiple NAS engines are running')
    parser.add_argument('--client',type=pathlib.Path,default=pathlib.Path('/Applications/UGREEN NAS.app'))
    args=parser.parse_args();source=args.client/'Contents/Resources/public/darwin/syncspace/syncspace_pro'
    subprocess.run(['codesign','--verify','--strict',str(source)],check=True)
    active=[]
    for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
        item=line.strip().split(None,1)
        if len(item)==2 and item[1]==str(source):active.append(int(item[0]))
    if not active:raise RuntimeError('Run and configure the installed UGREEN client first')
    snapshots=[]
    for pid in active:
        candidate,environment=process_args(pid)
        homes=[v.split('=',1)[1] for v in candidate if v.startswith(('-home=','--home='))]
        if len(homes)==1 and (args.profile is None or pathlib.Path(homes[0])==args.profile): snapshots.append((pid,candidate,environment,homes[0]))
    if not snapshots or len({item[3] for item in snapshots})!=1:raise RuntimeError('Multiple NAS profiles found; select the intended one with --profile')
    # The engine monitor and its worker may share one profile. Capture its lowest-PID supervisor.
    _,argv,env,_=min(snapshots,key=lambda item:item[0]);profile=[v.split('=',1)[1] for v in argv if v.startswith(('-home=','--home='))]
    gui=[v.split('=',1)[1] for v in argv if v.startswith(('-gui-address=','--gui-address='))]
    if len(profile)!=1 or len(gui)!=1 or not gui[0].startswith('127.0.0.1:'):raise RuntimeError('Expected a single existing loopback profile')
    if not args.work_folder.is_dir():raise RuntimeError('Work folder does not exist')
    root=pathlib.Path.home()/'Library/Application Support/UGOSSync';root.mkdir(parents=True,exist_ok=True,mode=0o700)
    target=root/'engine-settings.json'
    if target.exists():raise RuntimeError('Existing settings found; preserve your installation instead of recapturing it')
    backup=root/'initial-profile-backup';backup.mkdir(mode=0o700)
    for filename in ['config.xml','cert.pem','key.pem','https-cert.pem','https-key.pem']:
        file=pathlib.Path(profile[0])/filename
        if file.is_file():write(backup/filename,file.read_bytes())
    settings={'executable':str(source),'arguments':argv[1:],'environment':env,'configurationDirectory':profile[0],
        'workDirectory':str(args.work_folder.resolve()),'guiPort':int(gui[0].rsplit(':',1)[1]),'engineSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'statusFile':str(root/'engine-status.json')}
    write(target,json.dumps(settings).encode())
    print('Captured engine configuration privately. No credentials were printed.')
if __name__=='__main__':main()
