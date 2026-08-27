// What each table can be ranked by, and the verbs that act on a row.
//
// Moved out of monitor/mod.rs, which had grown to 6007 lines. Same code,
// same order; only the file it lives in changed.

/// Which slot in the strip a view sits in, by name.
///
/// What a container row can be ranked by, and how to read the value out.
///
/// docker renders these as strings ("12.34%", "469.7MiB / 7.595GiB"), which is
/// what the table shows; ranking needs a number, so each column says how to
/// get one from its own text. ←/→ walks this list the way it walks the process
/// header.
pub(crate) const CTR_SORT: &[(&str, &str)] = &[
    ("CPU%", "cpu"),
    ("MEM%", "mem_pct"),
    ("MEM USED", "mem"),
    ("CONTAINER", "name"),
    ("BLOCK I/O", "block"),
    ("NET I/O", "net"),
    ("PIDS", "pids"),
    ("ON DISK", "image_size"),
    // STATUS is the uptime column — docker writes it as "Up 18 minutes" — and
    // it was the one header here you could not rank by. Sorting it answers
    // "what restarted recently", which is the first question after something
    // breaks, and it groups everything not running together at the other end.
    ("STATUS", "status"),
];

/// What a fleet row can be ranked by, and where to read the value.
///
/// Same shape as CTR_SORT. PEER and RTT come off the Peer itself rather than
/// its snapshot, because a machine that never answered still has a name and a
/// probe result — and those are exactly the rows you want to sort to the top.
pub(crate) const FLEET_SORT: &[(&str, &str)] = &[
    ("CPU%", "cpu"),
    ("MEM%", "mem"),
    ("SWAP%", "swap"),
    ("DISK%", "disk"),
    ("RAM", "mem_detail.total"),
    ("LOAD", "load1"),
    ("PSI", "psi.cpu.some10"),
    ("PROCS", "proc_table"),
    ("CPUS", "cores"),
    ("RTT", "rtt"),
    ("PEER", "name"),
];

/// What an image row can be ranked by. Same idea as CTR_SORT: the strings
/// docker renders are what the table shows, and each column says how to get a
/// number out of its own text.
pub(crate) const IMG_SORT: &[(&str, &str)] = &[
    ("SIZE", "size"),
    ("CREATED", "created"),
    ("IMAGE", "repo"),
    // The last column, and the one worth ranking by: "what is this costing me
    // on disk" is answered by the images NOTHING runs, and they are scattered
    // through a list sorted any other way. No field of its own — an image does
    // not know whether a container references it, so this is computed against
    // the container list, exactly as the column itself is.
    ("IN USE", ""),
];

/// What can be done to a container. No `rm`: stopping one is reversible and
/// removing one is not, and a keystroke is the wrong weight for that.
pub(crate) const CTR_ACTIONS: [(&str, &str); 7] = [
    ("restart", "stop it and bring it back"),
    ("stop", "take it down"),
    ("start", "bring it up"),
    ("pause", "freeze it, keeping its memory"),
    ("unpause", "thaw one you froze"),
    // Ordered by how much they take away, and the two that take the most sit
    // last so the finger that overshoots by one row lands on a milder verb.
    // `kill` is not a louder `stop`: stop asks and then insists, kill does not
    // ask, which is the difference between a clean shutdown and whatever the
    // process was midway through.
    ("kill", "SIGKILL it — no clean shutdown"),
    // Deletes the container, not the image and not its named volumes. Docker
    // refuses while it runs, which is the guard: there is no path here that
    // destroys something still working.
    ("rm", "delete it — refused while it runs"),
];

/// What can be done to an image. `rm` is here because an unused image is dead
/// weight and removing it is the point of looking — docker itself refuses if a
/// container still references it, which is the guard.
pub(crate) const IMG_ACTIONS: [(&str, &str); 4] = [
    // `up`, never `run`: docker run <image> is a valid command that produces
    // a container with none of the ports, volumes or environment the service
    // needs. The only way back up is through the file that declared it.
    ("up", "start the service this image belongs to, from its compose file"),
    ("pull", "fetch the current version of this tag"),
    ("rm", "delete it — refused while a container uses it"),
    // Takes no image: prune is defined by what is NOT referenced, so it acts on
    // the whole dangling set at once. Every redeploy untags the previous
    // :latest and leaves it behind, which is why that set is most of a long
    // image list and none of a useful one.
    ("prune", "delete every dangling <none> image"),
];

/// One row under `v`: either a group heading or a declared unit.
#[derive(Clone, Debug)]
pub(crate) struct UnitRow {
    pub(crate) heading: Option<&'static str>,
    pub(crate) name: String,
    pub(crate) scope: String,
    pub(crate) state: String,
}

/// What the unit modal can ask systemd to do. Deliberately the four verbs a
/// person reaches for and no more — `enable` changes what happens at the NEXT
/// boot rather than now, which is a different kind of decision and does not
/// belong on a key you press while looking at a dead service.
pub(crate) const UNIT_ACTIONS: [(&str, &str); 4] = [
    ("start", "bring it up now"),
    ("restart", "stop it and bring it back"),
    ("stop", "take it down"),
    ("reset-failed", "clear the failed state so it can start again"),
];

/// What can be done to ONE declared service, from the file that declared it.
///
/// Per-service, never per-project: `docker compose down` on a project takes
/// down everything in it including the container you are not looking at, and
/// the row under the cursor is a service. The verbs here all name that service
/// explicitly, so the blast radius is what the cursor says it is.
///
/// No `down` and no `rm`. Bringing a service back up is one keypress from
/// here; the destructive pair belongs on a page where the thing being removed
/// is the subject, not on the one you land on to see what is declared.
pub(crate) const CMP_ACTIONS: [(&str, &str); 5] = [
    ("up", "create it from the file and start it"),
    ("restart", "stop and start it, same container"),
    ("stop", "stop it, keep the container"),
    ("start", "start the container it already has"),
    ("pull", "fetch the image this service pins"),
];
