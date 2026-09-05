# c3-watchdog, as a container.
#
# WHY A CONTAINER AT ALL
# A fleet is not all NixOS and not all the same distro. The flake beside this
# covers the Nix machines; the rolling release covers anyone who can download a
# static binary; this covers a box where the only thing you are sure of is that
# it runs containers. Three ways in, because an app that installs exactly one
# way is an app with a prerequisite.
#
# FROM scratch, and that is the whole design: the fleet binary is already a
# static musl build with no libc to link and no interpreter to find. Wrapping
# it in a distro image would add a package manager, a shell and a CVE feed to
# ship one 800KB file.

FROM alpine:3.20 AS fetch
ARG TARGETARCH
ARG RELEASE=c3-watchdog-latest
RUN apk add --no-cache curl
# aarch64 in this project's release names, arm64 in Docker's — the mapping is
# explicit rather than assumed, because a wrong guess produces an image that
# builds fine and cannot exec its own entrypoint.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) asset=c3-watchdog-x86_64 ;; \
      arm64) asset=c3-watchdog-aarch64 ;; \
      *) echo "no static build published for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /c3-watchdog-d \
      "https://github.com/diegonmarcos/cloud-u-linux/releases/download/${RELEASE}/${asset}"; \
    chmod +x /c3-watchdog-d; \
    /c3-watchdog-d --help >/dev/null 2>&1 || true

FROM scratch
COPY --from=fetch /c3-watchdog-d /c3-watchdog-d

# The sampler, not the panel: a container has no terminal to draw in, and what
# a container is FOR here is publishing a snapshot the panel elsewhere reads.
# --no-tray because there is no session bus in here to put an icon on.
ENTRYPOINT ["/c3-watchdog-d"]
CMD ["--no-tray"]
