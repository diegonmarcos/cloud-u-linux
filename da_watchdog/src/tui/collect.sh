# Collect one my-konsole snapshot from a machine that does NOT run the hub.
#
# The peers run a disk-usage watchdog, not the my-konsole publisher — only the
# desktop is the hub. So the hub collects: this script is fed to `ssh <peer>
# sh -s` and prints the same JSON shape the daemon publishes locally, built out
# of /proc alone. Nothing is installed on the peer and nothing is left behind.
#
# A peer that DOES publish natively wins: the file is preferred, so if the VM
# watchdog ever grows this it takes over with no change here.
#
# Two samples one second apart, because cpu is a delta and there is no earlier
# sample to diff against on a machine we are visiting once. USER_HZ is 100 on
# every Linux target, so over a 1s window a process's tick delta IS its percent.
#
# Fields the hub cannot get this way — per-process io and network, btrfs
# storage, cgroup slices, systemd units — are emitted empty rather than faked,
# so those boxes read as "no data" instead of "all zero".
# Same order the watchdog itself resolves: XDG_RUNTIME_DIR, then
# /run/user/<uid>, then /tmp. A non-interactive ssh session has no
# XDG_RUNTIME_DIR, which is precisely the session this script runs in.
for f in "${XDG_RUNTIME_DIR:-}/my-konsole-watchdog.json" \
         "/run/user/$(id -u)/my-konsole-watchdog.json" \
         "/tmp/my-konsole-$(id -u)/my-konsole-watchdog.json"; do
  [ -r "$f" ] && { cat "$f"; exit 0; }
done
# Unique per run. The same machine is reachable at several addresses and the
# hub collects them concurrently, so fixed paths meant two runs on one host
# overwrote each other's samples — which showed up as a peer reporting one
# core and no processes.
T=/tmp/.mk.$$

# df once, for the root filesystem percentage the fleet view shows.
> $T.df df -P / 2>/dev/null

# Every real filesystem, for the storage box. A peer has no btrfs qgroup data
# gathered over ssh, so this is df's view, labelled as such rather than dressed
# up in the columns qgroups would have filled.
# -PT only. No -x and no -l: df on these peers is BusyBox, which has neither,
# so the whole call failed and the storage box came back empty for a machine
# whose filesystems df can read perfectly well. Pseudo-filesystems are filtered
# in awk instead, where the shape of df is not a portability question.
> $T.dfa df -PT 2>/dev/null

# Raw output, parsed in awk. Every attempt to pre-format these with a nested
# awk inside sh -c inside a single-quoted script turned into a quoting problem
# with no good end; the parsing belongs in the one awk program either way.
{
  cat /proc/sys/kernel/hostname 2>/dev/null || echo
  ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}" )
  cat /proc/sys/kernel/osrelease 2>/dev/null || echo
  id -un 2>/dev/null || echo
} > $T.host 2>/dev/null
ip -o addr show > $T.addr 2>/dev/null || : > $T.addr
ip -o route show default > $T.route 2>/dev/null || : > $T.route
cat /etc/resolv.conf > $T.resolv 2>/dev/null || : > $T.resolv

# docker or podman, whichever answers first. Both speak the same --format, and
# a peer running neither simply produces nothing.
#
# HARD TIMEOUT, and it is not optional. `docker stats` samples every container
# twice to get a cpu delta and blocks on the daemon socket, so on a loaded box
# — or one where this user cannot reach the socket — it simply never returns,
# and the whole collector hangs with it. That is not a hypothetical: it wedged
# oci-apps until the ssh timeout killed it, and the hub saw a peer that had
# gone silent rather than a peer with no container data.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 6"
: > $T.ctr; : > $T.ctrps; : > $T.img
: > $T.vol; : > $T.voldang; : > $T.net; : > $T.cmp
for engine in docker podman; do
  command -v "$engine" >/dev/null 2>&1 || continue
  # ps FIRST, and it is the authoritative list: it is fast and it always
  # works, where `stats` can spend twenty seconds and hand back "--" in every
  # column, which is exactly what oci-apps does. A list of containers with no
  # numbers beside them is far more useful than no list at all.
  $TO "$engine" ps --format '{{.Names}}	{{.Status}}	{{.Image}}	{{.Ports}}	{{.RunningFor}}	{{.Command}}	{{.State}}' > $T.ctrps 2>/dev/null || continue
  [ -s $T.ctrps ] || continue
  # Images, running or not: a container list cannot answer "what is this
  # costing me on disk", because the images nothing is running are exactly
  # the ones nobody notices.
  $TO "$engine" images --format '{{.Repository}}	{{.Tag}}	{{.Size}}	{{.CreatedSince}}	{{.ID}}' > $T.img 2>/dev/null
  # Volumes, networks and the compose labels. All three are cheap list calls
  # against the daemon's own metadata — no per-container inspect — and all
  # three were missing here, which is why the volumes/network/compose pages
  # were blank for every peer whose my-watchdog was not running: the HTTP fast
  # path has them, this ssh fallback did not, and a peer only ever falls back.
  $TO "$engine" volume ls --format '{{.Name}}	{{.Driver}}	{{.Mountpoint}}' > $T.vol 2>/dev/null
  # The dangling set is the same question docker asks: a volume no container
  # references. Deriving it from the container list instead would miss the
  # ones referenced by a container that no longer exists.
  $TO "$engine" volume ls -q --filter dangling=true > $T.voldang 2>/dev/null
  $TO "$engine" network ls --format '{{.Name}}	{{.Driver}}	{{.Scope}}	{{.ID}}' > $T.net 2>/dev/null
  # -a, because a stopped container still carries the labels that say which
  # file declared it, and that is exactly the row worth being able to bring up.
  $TO "$engine" ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.project.config_files"}}	{{.Names}}	{{.State}}' > $T.cmp 2>/dev/null
  $TO "$engine" stats --no-stream \
    --format '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}	{{.MemPerc}}	{{.NetIO}}	{{.BlockIO}}	{{.PIDs}}' \
    > $T.ctr 2>/dev/null
  break
done

# GPU memory. amdgpu publishes both kinds through sysfs; nvidia publishes
# neither, so nvidia-smi is the only way in and it is bounded like the
# container calls. Intel i915 exposes usage only through debugfs, which is
# root, so those boxes report absent rather than a guessed number.
: > $T.gpu
for c in /sys/class/drm/card[0-9]*/device; do
  [ -r "$c/mem_info_vram_used" ] && echo "VU $(cat "$c/mem_info_vram_used" 2>/dev/null)" >> $T.gpu
  [ -r "$c/mem_info_vram_total" ] && echo "VT $(cat "$c/mem_info_vram_total" 2>/dev/null)" >> $T.gpu
  [ -r "$c/mem_info_gtt_used" ] && echo "GU $(cat "$c/mem_info_gtt_used" 2>/dev/null)" >> $T.gpu
  [ -r "$c/mem_info_gtt_total" ] && echo "GT $(cat "$c/mem_info_gtt_total" 2>/dev/null)" >> $T.gpu
done
if ! grep -q '^VT' $T.gpu 2>/dev/null && command -v nvidia-smi >/dev/null 2>&1; then
  $TO nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
    | head -1 | tr -d ' ' | awk -F, 'NF==2{printf "VU %.0f\nVT %.0f\n", $1*1048576, $2*1048576}' >> $T.gpu
fi

> $T.1 cat /proc/stat
> $T.p1 sh -c 'for f in /proc/[0-9]*/stat; do p=${f%/stat}; p=${p##*/}; s=$(cat "$f" 2>/dev/null) || continue; echo "$p ${s#*) }"; done'
sleep 1
> $T.2 cat /proc/stat
> $T.p2 sh -c 'for f in /proc/[0-9]*/stat; do p=${f%/stat}; p=${p##*/}; s=$(cat "$f" 2>/dev/null) || continue; echo "$p ${s#*) }"; done'

awk -v NOW="$(date +%s)" -v T="$T" '
function j(k,v){ printf "%s\"%s\":%s", sep, k, v; sep="," }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
function psi(f, l,a,r){ r="{}"; while((getline l < f)>0){
    split(l,a," "); t=a[1]
    for(i=2;i<=4;i++){ split(a[i],kv,"="); P[t kv[1]]=kv[2] } } close(f)
  return sprintf("{\"some10\":%s,\"some60\":%s,\"some300\":%s,\"full10\":%s,\"full60\":%s,\"full300\":%s}",
    P["someavg10"]+0,P["someavg60"]+0,P["someavg300"]+0,P["fullavg10"]+0,P["fullavg60"]+0,P["fullavg300"]+0) }
BEGIN{
  # ── cpu, two samples ────────────────────────────────────────────────
  while((getline l < (T ".1"))>0){ n=split(l,a," "); if(a[1]~/^cpu/){ tot=0; for(i=2;i<=n;i++)tot+=a[i]; T1[a[1]]=tot; I1[a[1]]=a[5]+a[6]; for(i=2;i<=n;i++) M1[a[1],i]=a[i] } }
  close(T ".1")
  while((getline l < (T ".2"))>0){ n=split(l,a," "); if(a[1]~/^cpu/){ tot=0; for(i=2;i<=n;i++)tot+=a[i]; T2[a[1]]=tot; I2[a[1]]=a[5]+a[6]; for(i=2;i<=n;i++) M2[a[1],i]=a[i]; if(a[1]!="cpu"){ order[++nc]=a[1] } } }
  close(T ".2")
  dt=T2["cpu"]-T1["cpu"]; if(dt<=0)dt=1
  cpu=100*(1-(I2["cpu"]-I1["cpu"])/dt)
  det=sprintf("{\"user\":%.1f,\"nice\":%.1f,\"system\":%.1f,\"iowait\":%.1f,\"irq\":%.1f,\"steal\":%.1f}",
    100*(M2["cpu",2]-M1["cpu",2])/dt, 100*(M2["cpu",3]-M1["cpu",3])/dt,
    100*(M2["cpu",4]-M1["cpu",4])/dt, 100*(M2["cpu",6]-M1["cpu",6])/dt,
    100*(M2["cpu",7]-M1["cpu",7])/dt, 100*(M2["cpu",9]-M1["cpu",9])/dt)
  cores="["
  for(k=1;k<=nc;k++){ c=order[k]; d=T2[c]-T1[c]; if(d<=0)d=1
    cores=cores sprintf("%s%.1f",(k>1?",":""),100*(1-(I2[c]-I1[c])/d)) }
  cores=cores "]"

  # ── meminfo ─────────────────────────────────────────────────────────
  while((getline l < "/proc/meminfo")>0){ split(l,a,":"); g=a[2]; gsub(/[^0-9]/,"",g); MEM[a[1]]=g+0 }
  close("/proc/meminfo")
  G=1048576.0
  mt=MEM["MemTotal"]; ma=MEM["MemAvailable"]; used=mt-ma
  st=MEM["SwapTotal"]; sf=MEM["SwapFree"]
  memd=sprintf("{\"total\":%.2f,\"used\":%.2f,\"free\":%.2f,\"available\":%.2f,\"cached\":%.2f,\"buffers\":%.2f,\"shmem\":%.2f,\"dirty\":%.2f,\"writeback\":%.2f,\"kernel\":%.2f,\"anon\":%.2f,\"commit\":%.2f,\"commit_limit\":%.2f}",
    mt/G,used/G,MEM["MemFree"]/G,ma/G,MEM["Cached"]/G,MEM["Buffers"]/G,MEM["Shmem"]/G,
    MEM["Dirty"]/G,MEM["Writeback"]/G,(MEM["Slab"]+MEM["KernelStack"])/G,MEM["AnonPages"]/G,
    MEM["Committed_AS"]/G,MEM["CommitLimit"]/G)
  swapd=sprintf("{\"total\":%.2f,\"used\":%.2f,\"free\":%.2f,\"cached\":%.2f,\"zswap\":0,\"zswapped\":0}",
    st/G,(st-sf)/G,sf/G,MEM["SwapCached"]/G)

  getline la < "/proc/loadavg"; close("/proc/loadavg"); split(la,L," ")
  getline up < "/proc/uptime"; close("/proc/uptime"); split(up,U," ")

  # ── totals since boot ───────────────────────────────────────────────
  # Same counters the rates come from, published whole. The daemon does
  # this arithmetic locally; here the collector does it, so both answer
  # the question the same way.
  while((getline l < "/proc/net/dev")>0){ if(l !~ /:/) continue
    split(l,a,":"); ifn=a[1]; gsub(/ /,"",ifn); if(ifn=="lo") continue
    split(a[2],b," "); NRX+=b[1]; NTX+=b[9] } close("/proc/net/dev")
  while((getline l < "/proc/diskstats")>0){ n=split(l,a," ")
    # whole devices only: partitions would double-count their parent
    if(a[3] ~ /[0-9]$/ && a[3] ~ /(sd|vd|hd)[a-z][0-9]/) continue
    if(a[3] ~ /^(loop|ram|dm-|zram)/) continue
    DR+=a[6]; DW+=a[10] } close("/proc/diskstats")

  # ── processes ───────────────────────────────────────────────────────
  while((getline l < (T ".p1"))>0){ split(l,a," "); C1[a[1]]=a[12]+a[13] } close(T ".p1")
  np=0
  while((getline l < (T ".p2"))>0){ split(l,a," "); pid=a[1]
    if(!(pid in C1)) continue
    tick=(a[12]+a[13])-C1[pid]; if(tick<0)tick=0
    np++; PID[np]=pid; PCT[np]=tick     # USER_HZ=100, 1s window -> ticks == percent
  } close(T ".p2")
  # top 40 by cpu, simple selection sort (np is a few thousand at most)
  n=(np<40?np:40)
  # bi, not b: b is an array in the totals block above and awk has one
  # namespace, so reusing the name as a scalar is fatal on mawk and busybox.
  for(i=1;i<=n;i++){ bi=i; for(k=i+1;k<=np;k++) if(PCT[k]>PCT[bi]) bi=k
    t=PID[i];PID[i]=PID[bi];PID[bi]=t; t=PCT[i];PCT[i]=PCT[bi];PCT[bi]=t }
  pt="["
  for(i=1;i<=n;i++){ pid=PID[i]; f="/proc/" pid "/status"
    nm="?"; rss=0; uid=0; pp=0; sc="?"
    while((getline l < f)>0){ split(l,a,":"); v=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",v)
      if(a[1]=="Name")nm=v; else if(a[1]=="VmRSS"){ gsub(/[^0-9]/,"",v); rss=v+0 }
      else if(a[1]=="Uid"){ split(v,u," "); uid=u[1] }
      else if(a[1]=="PPid")pp=v; else if(a[1]=="State"){ split(v,ss," "); sc=ss[1] } }
    close(f)
    mp=(mt>0? 100.0*rss/mt : 0)
    av=sprintf("{\"cpu_pct\":%.1f,\"mem_pct\":%.2f,\"mem_rss_bytes\":%.0f,\"read_bytes_per_s\":0,\"write_bytes_per_s\":0,\"runq_wait_pct\":0}",PCT[i],mp,rss*1024)
    pt=pt sprintf("%s{\"pid\":%s,\"ppid\":%s,\"state\":\"%s\",\"slice\":\"\",\"name\":\"%s\",\"user\":\"%s\",\"cpu_pct\":%.1f,\"mem_rss_bytes\":%.0f,\"mem_pss_bytes\":null,\"mem_pct\":%.2f,\"read_bytes_per_s\":0,\"write_bytes_per_s\":0,\"net_rx_bytes_per_s\":0,\"net_tx_bytes_per_s\":0,\"runq_wait_pct\":0,\"protected\":false,\"protected_reason\":null,\"avg\":{\"10s\":%s,\"1m\":%s,\"5m\":%s,\"15m\":%s}}",
      (i>1?",":""),pid,pp,esc(sc),esc(nm),esc(uid),PCT[i],rss*1024,mp,av,av,av,av) }
  pt=pt "]"

  sep=""
  printf "{"
  # ── gpu memory ──────────────────────────────────────────────────────
  vu=""; vt=""; gu=""; gt=""; gsrc="none"
  while((getline l < (T ".gpu"))>0){ split(l,a," ")
    if(a[1]=="VU") vu=a[2]; else if(a[1]=="VT") vt=a[2]
    else if(a[1]=="GU") gu=a[2]; else if(a[1]=="GT") gt=a[2] }
  close(T ".gpu")
  if(vt!="" || gt!="") gsrc="sysfs"
  ded = (vt!="" && vt+0>0) ? sprintf("{\"used\":%.0f,\"total\":%.0f}",vu+0,vt+0) : "null"
  shr = (gt!="" && gt+0>0) ? sprintf("{\"used\":%.0f,\"total\":%.0f}",gu+0,gt+0) : "null"
  j("vram_detail",sprintf("{\"dedicated\":%s,\"shared\":%s,\"source\":\"%s\"}",ded,shr,gsrc))

  j("cpu",sprintf("%.1f",cpu)); j("cores",cores); j("cpu_detail",det)
  j("mem",sprintf("%.1f",(mt>0?100.0*used/mt:0))); j("swap",sprintf("%.1f",(st>0?100.0*(st-sf)/st:0)))
  j("mem_detail",memd); j("swap_detail",swapd)
  while((getline l < (T ".df"))>0){ n=split(l,a," "); if(a[n]=="/"){ DP=a[n-1]; gsub(/%/,"",DP) } }
  close(T ".df")
  j("disk",DP+0); j("disk_r",0); j("disk_w",0); j("disks","[]")
  j("net_rx",0); j("net_tx",0)
  j("load1",L[1]+0); j("load5",L[2]+0); j("load15",L[3]+0)
  j("psi",sprintf("{\"cpu\":%s,\"io\":%s,\"memory\":%s}",psi("/proc/pressure/cpu"),psi("/proc/pressure/io"),psi("/proc/pressure/memory")))
  # ── who this machine is ────────────────────────────────────────────
  hl=0
  while((getline l < (T ".host"))>0){ hl++
    if(hl==1) hn=l; else if(hl==2) osn=l; else if(hl==3) kern=l; else if(hl==4) usr=l }
  close(T ".host")
  nif=0; pubip=""
  while((getline l < (T ".addr"))>0){ n=split(l,a," ")
    nm=a[2]; if(nm=="lo") continue
    ad=""
    for(i=3;i<=n;i++) if(a[i]=="inet" || a[i]=="inet6"){ ad=a[i+1]; break }
    if(ad=="" || ad ~ /^fe80:/) continue
    IFN[++nif]=nm; IFA[nif]=ad
    ip=ad; sub(/\/.*/,"",ip)
    # Globally routable? Everything RFC1918, CGNAT, loopback, link-local and
    # unique-local is not, and on this fleet that is exactly the set that
    # means "not reachable from the internet".
    if(pubip=="" && nm !~ /^wg/ && ip !~ /^10\./ && ip !~ /^127\./ && ip !~ /^192\.168\./ \
       && ip !~ /^169\.254\./ && ip !~ /^172\.(1[6-9]|2[0-9]|3[01])\./ \
       && ip !~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ \
       && ip !~ /^f[cd]/ && ip != "::1") pubip=ip }
  close(T ".addr")
  gw=""; wif=""
  while((getline l < (T ".route"))>0){ n=split(l,a," ")
    for(i=1;i<=n;i++){ if(a[i]=="via") gw=a[i+1]; if(a[i]=="dev") wif=a[i+1] } }
  close(T ".route")
  nd=0; ns=0
  while((getline l < (T ".resolv"))>0){ n=split(l,a," ")
    if(a[1]=="nameserver") DNS[++nd]=a[2]
    else if(a[1]=="search") for(i=2;i<=n;i++) SRCH[++ns]=a[i] }
  close(T ".resolv")
  # mtu/state from sysfs; wg keys and handshakes are root-only and simply not
  # available here, which the panel says rather than showing blanks.
  ifj=""
  for(i=1;i<=nif;i++){
    mtu=""; st=""
    if((getline mline < ("/sys/class/net/" IFN[i] "/mtu"))>0) mtu=mline
    close("/sys/class/net/" IFN[i] "/mtu")
    if((getline sline < ("/sys/class/net/" IFN[i] "/operstate"))>0) st=sline
    close("/sys/class/net/" IFN[i] "/operstate")
    ifj=ifj sprintf("%s{\"name\":\"%s\",\"addr\":\"%s\",\"mtu\":\"%s\",\"state\":\"%s\",\"mesh\":%s}",
      (i>1?",":""),esc(IFN[i]),esc(IFA[i]),esc(mtu),esc(st),(IFN[i] ~ /^wg/ ? "true" : "false"))
  }
  dnj=""; for(i=1;i<=nd;i++) dnj=dnj sprintf("%s\"%s\"",(i>1?",":""),esc(DNS[i]))
  srj=""; for(i=1;i<=ns;i++) srj=srj sprintf("%s\"%s\"",(i>1?",":""),esc(SRCH[i]))
  j("host_info",sprintf("{\"host\":\"%s\",\"os\":\"%s\",\"kernel\":\"%s\",\"user\":\"%s\",\"gateway\":\"%s\",\"wan_if\":\"%s\",\"public\":\"%s\",\"ifaces\":[%s],\"dns\":[%s],\"search\":[%s]}",
    esc(hn),esc(osn),esc(kern),esc(usr),esc(gw),esc(wif),esc(pubip),ifj,dnj,srj))

  # ── filesystems ────────────────────────────────────────────────────
  # Labelled "df" on purpose: these are df numbers, and used-as-referenced is
  # only honest while the source is named. A peer collected over ssh has no
  # qgroup data gathered, and dressing df up in qgroup columns would hide that.
  vols=""; nv=0; troot=0; uroot=0
  while((getline l < (T ".dfa"))>0){ n=split(l,a," ")
    if(a[1]=="Filesystem" || n<7) continue
    if(a[2] ~ /^(tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|cgroup2|ramfs|autofs|nsfs|tracefs|debugfs|securityfs|pstore|bpf|configfs|efivarfs|mqueue|hugetlbfs|binfmt_misc|fusectl|devpts)$/) continue
    # -PT columns: Filesystem Type 1K-blocks Used Available Capacity Mount.
    # The mount is the LAST field rather than the seventh, because a device
    # path containing a space shifts everything before it.
    mp=a[n]; sz=a[3]*1024; us=a[4]*1024
    if(sz<=0) continue
    nv++
    vols=vols sprintf("%s{\"mount\":\"%s\",\"subvol\":\"%s\",\"referenced\":%.0f,\"exclusive\":%.0f,\"limit\":%.0f}",
      (nv>1?",":""),esc(mp),esc(a[2]),us,us,sz)
    if(mp=="/"){ troot=sz; uroot=us } }
  close(T ".dfa")
  if(nv>0) j("storage",sprintf("[{\"label\":\"df\",\"dev_size\":%.0f,\"alloc\":%.0f,\"alloc_used\":%.0f,\"data_total\":%.0f,\"data_used\":%.0f,\"meta_total\":0,\"meta_used\":0,\"volumes\":[%s]}]",troot,troot,uroot,troot,uroot,vols))
  else j("storage","[]")

  # ── containers ─────────────────────────────────────────────────────
  # "--" is what docker prints when it cannot read a container cgroup, so it
  # is dropped rather than carried through: "--%" in a percentage column reads
  # as a value, and it is the absence of one.
  while((getline l < (T ".ctr"))>0){ n=split(l,a,"\t"); if(n<7 || a[2]=="--") continue
    SC[a[1]]=a[2]; SM[a[1]]=a[3]; SMP[a[1]]=a[4]; SN[a[1]]=a[5]; SB[a[1]]=a[6]; SPI[a[1]]=a[7] }
  close(T ".ctr")
  nim=0; imj=""
  while((getline l < (T ".img"))>0){ n=split(l,a,"\t"); if(n<5) continue
    nim++
    ISZ[a[1] ":" a[2]]=a[3]
    imj=imj sprintf("%s{\"repo\":\"%s\",\"tag\":\"%s\",\"size\":\"%s\",\"created\":\"%s\",\"id\":\"%s\"}",
      (nim>1?",":""),esc(a[1]),esc(a[2]),esc(a[3]),esc(a[4]),esc(a[5])) }
  close(T ".img")
  j("images",sprintf("[%s]",imj))
  ncc=0; ctj=""
  while((getline l < (T ".ctrps"))>0){ n=split(l,a,"\t"); if(a[1]=="") continue
    nm=a[1]; ncc++
    ctj=ctj sprintf("%s{\"name\":\"%s\",\"cpu\":\"%s\",\"mem\":\"%s\",\"mem_pct\":\"%s\",\"net\":\"%s\",\"block\":\"%s\",\"pids\":\"%s\",\"status\":\"%s\",\"image\":\"%s\",\"image_size\":\"%s\",\"ports\":\"%s\",\"uptime\":\"%s\",\"command\":\"%s\",\"state\":\"%s\"}",
      (ncc>1?",":""),esc(nm),esc(SC[nm]),esc(SM[nm]),esc(SMP[nm]),esc(SN[nm]),esc(SB[nm]),esc(SPI[nm]),
      esc(a[2]),esc(a[3]),esc(ISZ[a[3]]),esc(a[4]),esc(a[5]),esc(a[6]),esc(a[7])) }
  close(T ".ctrps")
  j("containers",sprintf("[%s]",ctj))

  # ── volumes, networks, compose ──────────────────────────────────────
  while((getline l < (T ".voldang"))>0){ gsub(/[ \t\r]+$/,"",l); if(l!="") DANG[l]=1 }
  close(T ".voldang")
  nv2=0; vj=""
  while((getline l < (T ".vol"))>0){ n=split(l,a,"\t"); if(n<1 || a[1]=="") continue
    nv2++
    vj=vj sprintf("%s{\"name\":\"%s\",\"driver\":\"%s\",\"mount\":\"%s\",\"in_use\":%s",
      (nv2>1?",":""),esc(a[1]),esc(a[2]),esc(a[3]),(DANG[a[1]]?"false":"true")) "}" }
  close(T ".vol")
  j("volumes",sprintf("[%s]",vj))
  nn=0; nj=""
  while((getline l < (T ".net"))>0){ n=split(l,a,"\t"); if(n<1 || a[1]=="") continue
    nn++
    nj=nj sprintf("%s{\"name\":\"%s\",\"driver\":\"%s\",\"scope\":\"%s\",\"id\":\"%s\"}",
      (nn>1?",":""),esc(a[1]),esc(a[2]),esc(a[3]),esc(a[4])) }
  close(T ".net")
  j("networks",sprintf("[%s]",nj))
  # declared = compose wrote a project label on it. A container with none is
  # not a gap in this collector: it is one nobody deployed the declared way.
  nk=0; kj=""
  while((getline l < (T ".cmp"))>0){ n=split(l,a,"\t"); if(n<5 || a[4]=="") continue
    nk++
    kj=kj sprintf("%s{\"project\":\"%s\",\"service\":\"%s\",\"file\":\"%s\",\"container\":\"%s\",\"state\":\"%s\",\"declared\":%s}",
      (nk>1?",":""),esc(a[1]),esc(a[2]),esc(a[3]),esc(a[4]),esc(a[5]),(a[1]==""?"false":"true")) }
  close(T ".cmp")
  j("compose",sprintf("[%s]",kj))

  j("slices","[]"); j("services","[]")
  # %.0f, not %d: the %d of mawk and busybox awk is a 32-bit int, so every one
  # of these byte counts would saturate at 2147483647 — which is exactly what
  # a 2.1 GB reading from every peer turned out to be.
  j("totals",sprintf("{\"net_rx_bytes\":%.0f,\"net_tx_bytes\":%.0f,\"disk_read_bytes\":%.0f,\"disk_write_bytes\":%.0f,\"since_s\":%.0f}",NRX,NTX,DR*512,DW*512,U[1]))
  j("procs","[]"); j("proc_table",pt)
  j("ts",NOW+0)
  printf "}\n"
}' < /dev/null
rm -f "$T".*
