//! Podman: images, the pod of a run with its limits, the system's scripts in its container. See
//! docs/RUNNER.md.

use std::collections::BTreeMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

use crate::system::{System, subst};

/// The files LXCFS provides so a container sees its own limits instead of the host's.
const LXCFS: &str = "/var/lib/lxcfs";
const LXCFS_PROC: &[&str] = &["cpuinfo", "diskstats", "loadavg", "meminfo", "stat", "swaps", "uptime"];
const BASE_IMAGE: &str = "localhost/dbo-base";

#[derive(Clone)]
pub struct Podman {
    /// podman's storage: images, container layers (the databases' files) and volumes
    root: PathBuf,
    runroot: PathBuf,
    seccomp: PathBuf,
}

impl Podman {
    /// `bench` is the bench directory of the repository.
    pub fn new(bench: &Path) -> Result<Podman> {
        let uid = unsafe { libc::getuid() };
        let p = Podman { root: bench.join("containers/storage"), runroot: PathBuf::from(format!("/run/user/{uid}/dbo-containers")), seccomp: bench.join("seccomp.json") };
        std::fs::create_dir_all(&p.root)?;
        if !Path::new(LXCFS).join("proc/meminfo").exists() {
            bail!("LXCFS is not running ({LXCFS}/proc/meminfo is missing): run bench/host-setup.sh");
        }
        Ok(p)
    }

    pub fn cmd(&self) -> Command {
        let mut c = Command::new("podman");
        c.arg("--root").arg(&self.root).arg("--runroot").arg(&self.runroot);
        c
    }

    /// Run podman and return its standard output.
    pub fn run(&self, args: &[&str]) -> Result<String> {
        let o = self.cmd().args(args).stdin(Stdio::null()).output().context("running podman")?;
        if !o.status.success() {
            bail!("podman {}: {}", args.join(" "), String::from_utf8_lossy(&o.stderr).trim());
        }
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    }

    /// Build an image, showing podman's output only when the build fails.
    fn build(&self, tag: &str, context: &Path, file: &Path, ignore: Option<&Path>) -> Result<()> {
        eprintln!("building image {tag}");
        let mut cmd = self.cmd();
        cmd.args(["build", "-q", "--tag", tag, "--file"]).arg(file);
        if let Some(i) = ignore {
            cmd.arg("--ignorefile").arg(i);
        }
        let o = cmd.arg(context).stdin(Stdio::null()).output().context("running podman build")?;
        if !o.status.success() {
            let err = String::from_utf8_lossy(&o.stderr);
            let tail: Vec<&str> = err.lines().rev().take(40).collect();
            bail!("building image {tag} failed:\n{}", tail.into_iter().rev().collect::<Vec<_>>().join("\n"));
        }
        Ok(())
    }

    /// The image of a system: the base image, the system's directory in /system, the library its
    /// query program uses (systems/dbo) in /dbo, and its `install` (if it has one) run in
    /// /system, with every file of the directory at hand. The image is built again when a file of
    /// either directory changes (its results do not count).
    pub fn system_image(&self, bench: &Path, sys: &System, work: &Path) -> Result<String> {
        self.build(BASE_IMAGE, &bench.join("image"), &bench.join("image/Containerfile"), None)?;
        let tag = format!("localhost/dbo-{}", sys.name);
        let file = work.join("Containerfile");
        let install = if sys.dir.join("install").is_file() { "RUN ./install\n" } else { "" };
        let name = sys.dir.file_name().context("system directory")?.to_string_lossy();
        std::fs::write(&file, format!("FROM {BASE_IMAGE}\nCOPY {name} /system\nCOPY dbo /dbo\n{install}"))?;
        // not part of the system: its results (results/), what a local build of a Rust query
        // program leaves, the library's documentation
        let ignore = work.join("Containerignore");
        std::fs::write(&ignore, "*/results\n**/target\ndbo/README.md\n*/logo.svg\n")?;
        let systems = sys.dir.parent().context("systems directory")?;
        self.build(&tag, systems, &file, Some(&ignore))?;
        Ok(tag)
    }

    /// The image of a system as it is in the storage (built, or loaded from another machine), for a
    /// run that must not build it again.
    pub fn existing_image(&self, sys: &System) -> Result<String> {
        let tag = format!("localhost/dbo-{}", sys.name);
        if !self.cmd().args(["image", "exists", &tag]).status()?.success() {
            bail!("{tag} is not there (--no-build): build it with dbo-bench images, or load it");
        }
        Ok(tag)
    }

    pub fn pull(&self, image: &str) -> Result<()> {
        if self.cmd().args(["image", "exists", image]).status()?.success() {
            return Ok(());
        }
        eprintln!("pulling image {image}");
        self.run(&["pull", "-q", image]).map(|_| ())
    }

    /// What an image is: its registry digest if it was pulled, else its ID.
    pub fn identity(&self, image: &str) -> Result<String> {
        self.run(&["image", "inspect", image, "--format", "{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}"])
    }

    /// Remove a pod with its containers, then the volumes no container uses any more. A removal that
    /// fails is tried again (a pod whose container wrote hundreds of GB has been seen to stay), and
    /// says why: a pod left behind keeps its database's disk space.
    pub fn cleanup(&self, pod: &str) {
        for attempt in 1..=3 {
            match self.run(&["pod", "rm", "--ignore", "-f", "-t", "0", pod]) {
                Ok(_) => break,
                Err(e) if attempt < 3 => {
                    eprintln!("removing pod {pod} failed, trying again in 30 s: {e:#}");
                    std::thread::sleep(Duration::from_secs(30));
                }
                Err(e) => eprintln!("removing pod {pod} failed, it is left behind: {e:#}"),
            }
        }
        if let Err(e) = self.run(&["volume", "prune", "-f"]) {
            eprintln!("removing unused volumes failed: {e:#}");
        }
    }

    /// The pods of earlier runs (all are named dbo-...).
    fn pods(&self) -> Vec<String> {
        self.run(&["pod", "ps", "--format", "{{.Name}}"]).map(|o| o.lines().filter(|n| n.starts_with("dbo-")).map(String::from).collect()).unwrap_or_default()
    }
}

/// The resources of a run.
pub struct Limits {
    pub cpuset: String,
    pub memory: u64,
}

/// Where the data is on the host: mounted read-only in every container.
pub struct Mounts {
    /// at /data
    pub data: PathBuf,
    /// at /data-arrays (the tables with array columns as text), if the system needs it
    pub arrays: Option<PathBuf>,
}

/// A running pod: the system's own container (its scripts and query program) and its other
/// containers.
pub struct Pod {
    podman: Podman,
    pub name: String,
    /// the pod's cgroup directory
    cgroup: PathBuf,
    containers: Vec<String>,
    /// on the host, at /run/dbo in every container: the query program's socket (dbo.sock) and
    /// log (query.log), and the system's own sockets where it has them
    pub sockets: PathBuf,
}

impl Pod {
    /// Create the pod and start its containers: first the ones of the system file, then the
    /// system's own container from `image`.
    pub fn start(podman: &Podman, name: &str, image: &str, sys: &System, limits: &Limits, mounts: &Mounts, env: &BTreeMap<String, String>, vars: &BTreeMap<String, String>) -> Result<Pod> {
        // a run has the machine to itself: every pod an earlier run left behind goes, not only this one's
        let mut pods = podman.pods();
        if !pods.iter().any(|p| p == name) {
            pods.push(name.to_string());
        }
        for p in &pods {
            podman.cleanup(p);
        }
        // no network but the pod's loopback; the limits are each container's own (`container`)
        // shared memory (/dev/shm) is part of a container's memory limit, so it needs no smaller one of its own
        podman.run(&["pod", "create", "--name", name, "--network", "none", "--shm-size", &limits.memory.to_string()])?;
        let cg = podman.run(&["pod", "inspect", name, "--format", "{{.CgroupPath}}"])?;
        let sockets = podman.runroot.with_file_name("dbo-sockets").join(name);
        let _ = std::fs::remove_dir_all(&sockets);
        std::fs::create_dir_all(&sockets)?;
        // writable for the systems' users in the containers
        std::fs::set_permissions(&sockets, std::os::unix::fs::PermissionsExt::from_mode(0o777))?;
        let mut pod = Pod { podman: podman.clone(), name: name.to_string(), cgroup: Path::new("/sys/fs/cgroup").join(cg.trim_start_matches('/')), containers: Vec::new(), sockets };
        for c in &sys.containers {
            podman.pull(&c.image)?;
            // {threads}, {memory_bytes} ... in the command and environment
            let command: Vec<String> = c.command.iter().map(|a| subst(a, vars)).collect::<Result<_>>()?;
            let own: BTreeMap<String, String> = c.env.iter().map(|(k, v)| Ok((k.clone(), subst(v, vars)?))).collect::<Result<_>>()?;
            pod.container(&format!("{name}-{}", c.name), &c.image, &command, &own, &c.ulimits, c.user.as_deref(), c.data_writable, limits, mounts, env)?;
        }
        let main = format!("{name}-system");
        let command: Vec<String> = ["sleep", "infinity"].iter().map(|s| s.to_string()).collect();
        pod.container(&main, image, &command, &BTreeMap::new(), &[], None, false, limits, mounts, env)?;
        // an out-of-memory kill takes the whole container, not one process
        pod.oom_group().context("setting memory.oom.group")?;
        Ok(pod)
    }

    #[allow(clippy::too_many_arguments)]
    fn container(&mut self, name: &str, image: &str, command: &[String], own_env: &BTreeMap<String, String>, ulimits: &[String], user: Option<&str>, data_writable: bool, limits: &Limits, mounts: &Mounts, env: &BTreeMap<String, String>) -> Result<()> {
        let mem = limits.memory.to_string();
        let mut c = self.podman.cmd();
        c.args(["run", "-d", "--init", "--pod", &self.name, "--name", name]);
        c.args(["--cpuset-cpus", &limits.cpuset, "--memory", &mem, "--memory-swap", &mem]);
        c.arg("--security-opt").arg(format!("seccomp={}", self.podman.seccomp.display()));
        c.args(["--ulimit", "memlock=-1:-1"]);
        for u in ulimits {
            c.args(["--ulimit", u]);
        }
        if let Some(u) = user {
            c.args(["--user", u]);
        }
        for f in LXCFS_PROC {
            c.arg("-v").arg(format!("{LXCFS}/proc/{f}:/proc/{f}:ro"));
        }
        c.arg("-v").arg(format!("{LXCFS}/sys/devices/system/cpu:/sys/devices/system/cpu:ro"));
        c.arg("-v").arg(format!("{}:/run/dbo", self.sockets.display()));
        let mode = if data_writable { "rw" } else { "ro" };
        c.arg("-v").arg(format!("{}:/data:{mode}", mounts.data.display()));
        if let Some(a) = &mounts.arrays {
            c.arg("-v").arg(format!("{}:/data-arrays:{mode}", a.display()));
        }
        for (k, v) in env.iter().chain(own_env) {
            c.arg("-e").arg(format!("{k}={v}"));
        }
        c.arg(image).args(command);
        let o = c.stdin(Stdio::null()).output().context("running podman")?;
        if !o.status.success() {
            bail!("starting container {name}: {}", String::from_utf8_lossy(&o.stderr).trim());
        }
        self.containers.push(name.to_string());
        Ok(())
    }

    fn oom_group(&self) -> Result<()> {
        let mut dirs = vec![self.cgroup.clone()];
        while let Some(d) = dirs.pop() {
            let f = d.join("memory.oom.group");
            if f.exists() {
                std::fs::write(&f, "1").with_context(|| f.display().to_string())?;
            }
            for e in std::fs::read_dir(&d)?.flatten() {
                if e.path().is_dir() {
                    dirs.push(e.path());
                }
            }
        }
        Ok(())
    }

    /// Processes killed for memory in the pod so far.
    pub fn oom_kills(&self) -> u64 {
        let text = std::fs::read_to_string(self.cgroup.join("memory.events")).unwrap_or_default();
        text.lines().filter_map(|l| l.strip_prefix("oom_kill ")).filter_map(|v| v.trim().parse().ok()).next().unwrap_or(0)
    }

    /// The highest memory use of the pod so far, all its containers together, in bytes.
    pub fn memory_peak(&self) -> Option<u64> {
        std::fs::read_to_string(self.cgroup.join("memory.peak")).ok()?.trim().parse().ok()
    }

    /// Whether every container of the pod is running.
    pub fn alive(&self) -> bool {
        self.containers.iter().all(|c| self.podman.run(&["container", "inspect", c, "--format", "{{.State.Running}}"]).is_ok_and(|s| s == "true"))
    }

    /// Run a script of the system in its own container, at most `limit`: its exit code and
    /// output, or None if it did not finish in time.
    pub fn script(&self, script: &str, limit: Duration, log: &Path) -> Result<Option<(i32, String)>> {
        let main = self.containers.last().context("no container")?;
        let out = File::create(log)?;
        let mut child = self.podman.cmd().args(["exec", "-w", "/system", main, &format!("./{script}")]).stdin(Stdio::null()).stdout(out.try_clone()?).stderr(out).spawn()?;
        let t0 = Instant::now();
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(Some((status.code().unwrap_or(-1), std::fs::read_to_string(log).unwrap_or_default())));
            }
            if t0.elapsed() > limit {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(None);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The query program's socket, on the host.
    pub fn socket(&self) -> PathBuf {
        self.sockets.join("dbo.sock")
    }

    /// What the query program wrote (start sends it to /run/dbo/query.log).
    pub fn query_log(&self) -> String {
        std::fs::read_to_string(self.sockets.join("query.log")).unwrap_or_default()
    }

    /// The last lines of every container's log, for the report of a failed run.
    pub fn logs(&self) -> String {
        let mut s = String::new();
        for c in &self.containers {
            let o = self.podman.cmd().args(["logs", "--tail", "50", c]).stdin(Stdio::null()).output();
            if let Ok(o) = o {
                s += &format!("--- {c}\n{}{}\n", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
            }
        }
        s
    }

    /// Bytes the containers wrote: their writable layers and volumes.
    pub fn storage_bytes(&self) -> Result<u64> {
        let mut dirs = Vec::new();
        for c in &self.containers {
            dirs.push(self.podman.run(&["container", "inspect", c, "--format", "{{.GraphDriver.Data.UpperDir}}"])?);
            let vols = self.podman.run(&["container", "inspect", c, "--format", "{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Source}}\n{{end}}{{end}}"])?;
            dirs.extend(vols.lines().map(str::to_string));
        }
        let mut total = 0;
        for d in dirs.iter().filter(|d| !d.is_empty()) {
            // the files belong to the containers' users: read them in podman's user namespace
            let out = self.podman.run(&["unshare", "du", "-sb", d])?;
            total += out.split_whitespace().next().and_then(|n| n.parse::<u64>().ok()).with_context(|| format!("du {d}: {out}"))?;
        }
        Ok(total)
    }

    /// Kill and remove the pod with everything it wrote.
    pub fn remove(&self) {
        self.podman.cleanup(&self.name);
        let _ = std::fs::remove_dir_all(&self.sockets);
    }
}

impl Drop for Pod {
    fn drop(&mut self) {
        self.remove();
    }
}
