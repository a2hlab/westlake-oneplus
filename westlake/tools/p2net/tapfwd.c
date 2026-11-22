// tapfwd: give a phone without Wi-Fi a network over a TCP stream.
//
// Creates a TAP interface (default "eth0", which OH's EthernetManager adopts and
// runs DHCP on) and carries its Ethernet frames over TCP to 127.0.0.1:PORT,
// which `hdc rport tcp:PORT tcp:PORT` forwards to the PC. On the PC, passt
// (user-space NAT with DHCP and DNS) answers. Framing is the QEMU "stream"
// netdev protocol passt speaks: a 32-bit big-endian length before each frame.
//
// The TAP stays open across TCP reconnects, so the interface (and OH's view of
// it) survives a dropped forward; frames read while disconnected are dropped.
// Exiting removes the interface (it is not persistent).
//
// Build: zig cc -target aarch64-linux-musl -static -O2 -s -o tapfwd tapfwd.c
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAXF 65550 /* largest frame we accept from either side */

static void logf_(const char *fmt, ...) {
  char ts[32];
  time_t t = time(NULL);
  struct tm tm;
  localtime_r(&t, &tm);
  strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
  fprintf(stderr, "%s tapfwd: ", ts);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  fflush(stderr);
}

static int write_all(int fd, const uint8_t *p, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

static int parse_mac(const char *s, uint8_t mac[6]) {
  unsigned v[6];
  if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return -1;
  for (int i = 0; i < 6; i++) {
    if (v[i] > 255) return -1;
    mac[i] = (uint8_t)v[i];
  }
  return 0;
}

static int open_tap(const char *name, const uint8_t *mac, int up) {
  const char *paths[] = {"/dev/net/tun", "/dev/tun"};
  int fd = -1;
  for (unsigned i = 0; i < 2 && fd < 0; i++) fd = open(paths[i], O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    logf_("open tun device: %s", strerror(errno));
    return -1;
  }
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    logf_("TUNSETIFF %s: %s", name, strerror(errno));
    close(fd);
    return -1;
  }
  int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (s >= 0) {
    if (mac) {
      struct ifreq hw;
      memset(&hw, 0, sizeof hw);
      snprintf(hw.ifr_name, IFNAMSIZ, "%s", ifr.ifr_name);
      hw.ifr_hwaddr.sa_family = 1; /* ARPHRD_ETHER */
      memcpy(hw.ifr_hwaddr.sa_data, mac, 6);
      if (ioctl(s, SIOCSIFHWADDR, &hw) < 0) logf_("set MAC: %s", strerror(errno));
    }
    if (up) {
      struct ifreq fl;
      memset(&fl, 0, sizeof fl);
      snprintf(fl.ifr_name, IFNAMSIZ, "%s", ifr.ifr_name);
      if (ioctl(s, SIOCGIFFLAGS, &fl) == 0) {
        fl.ifr_flags |= IFF_UP;
        if (ioctl(s, SIOCSIFFLAGS, &fl) < 0) logf_("set up: %s", strerror(errno));
      }
    }
    close(s);
  }
  logf_("tap %s ready (fd %d)", ifr.ifr_name, fd);
  return fd;
}

static int connect_port(int port) {
  int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (s < 0) return -1;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
    close(s);
    return -1;
  }
  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  int buf = 1 << 20;
  setsockopt(s, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
  setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
  return s;
}

static void usage(void) {
  fprintf(stderr,
          "usage: tapfwd [-d] [-l LOG] [-i IFNAME] [-m MAC] [-u] PORT\n"
          "  -d daemonize (log to LOG, default /data/local/tmp/tapfwd.log)\n"
          "  -i interface name (default eth0)  -m MAC  -u bring the link up ourselves\n");
  exit(2);
}

int main(int argc, char **argv) {
  const char *ifname = "eth0", *logpath = "/data/local/tmp/tapfwd.log";
  uint8_t mac[6], *macp = NULL;
  int daemon_ = 0, up = 0, c;
  while ((c = getopt(argc, argv, "dl:i:m:u")) != -1) {
    switch (c) {
      case 'd': daemon_ = 1; break;
      case 'l': logpath = optarg; break;
      case 'i': ifname = optarg; break;
      case 'm':
        if (parse_mac(optarg, mac) < 0) usage();
        macp = mac;
        break;
      case 'u': up = 1; break;
      default: usage();
    }
  }
  if (optind != argc - 1) usage();
  int port = atoi(argv[optind]);
  if (port <= 0 || port > 65535) usage();

  signal(SIGPIPE, SIG_IGN);
  if (daemon_) {
    pid_t p = fork();
    if (p < 0) return 1;
    if (p > 0) {
      printf("%d\n", (int)p);
      return 0;
    }
    setsid();
    int lf = open(logpath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    int nul = open("/dev/null", O_RDWR);
    if (nul >= 0) dup2(nul, 0);
    if (lf >= 0) {
      dup2(lf, 1);
      dup2(lf, 2);
    }
    if (chdir("/") != 0) {}
  }

  int tap = open_tap(ifname, macp, up);
  if (tap < 0) return 1;

  static uint8_t out[MAXF + 4];
  static uint8_t in[2 * (MAXF + 4)];
  size_t have = 0;
  int sock = -1;
  unsigned long long tx = 0, rx = 0, dropped = 0;
  time_t next_try = 0;
  /* Attempts since the last session that got a frame back. With the rport in
     place but nothing behind it on the PC, hdcd accepts and then closes at
     once, every second: log only the first attempt of such a series. */
  int quiet = 0;

  for (;;) {
    if (sock < 0 && time(NULL) >= next_try) {
      sock = connect_port(port);
      if (sock >= 0) {
        have = 0;
        tx = rx = 0;
        if (quiet == 0) logf_("connected to 127.0.0.1:%d", port);
      } else {
        if (quiet++ == 0) logf_("connect 127.0.0.1:%d failed (%s); retrying every second", port, strerror(errno));
        next_try = time(NULL) + 1;
      }
    }
    struct pollfd pf[2] = {{tap, POLLIN, 0}, {sock, POLLIN, 0}};
    int n = poll(pf, sock >= 0 ? 2 : 1, 1000);
    if (n < 0) {
      if (errno == EINTR) continue;
      logf_("poll: %s", strerror(errno));
      return 1;
    }
    if (pf[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
      logf_("tap error, exiting");
      return 1;
    }
    if (pf[0].revents & POLLIN) {
      ssize_t r = read(tap, out + 4, MAXF);
      if (r > 0) {
        if (sock >= 0) {
          uint32_t be = htonl((uint32_t)r);
          memcpy(out, &be, 4);
          if (write_all(sock, out, (size_t)r + 4) < 0) {
            if (rx > 0 || quiet == 0) logf_("send failed (%s) after tx %llu rx %llu", strerror(errno), tx, rx);
            if (rx > 0) quiet = 0; else quiet++;
            close(sock);
            sock = -1;
            next_try = time(NULL) + 1;
          } else {
            tx++;
          }
        } else {
          dropped++;
        }
      }
    }
    if (sock >= 0 && (pf[1].revents & (POLLIN | POLLERR | POLLHUP))) {
      ssize_t r = read(sock, in + have, sizeof in - have);
      if (r <= 0) {
        if (r < 0 && errno == EINTR) continue;
        if (rx > 0) {
          logf_("disconnected (%s) after tx %llu rx %llu dropped %llu", r == 0 ? "EOF" : strerror(errno), tx,
                rx, dropped);
          quiet = 0;
        } else if (quiet++ == 0) {
          logf_("forward closed with no reply (%s): PC side down? retrying every second, quietly",
                r == 0 ? "EOF" : strerror(errno));
        }
        close(sock);
        sock = -1;
        next_try = time(NULL) + 1;
        continue;
      }
      have += (size_t)r;
      size_t off = 0;
      int bad = 0;
      while (have - off >= 4) {
        uint32_t be;
        memcpy(&be, in + off, 4);
        uint32_t len = ntohl(be);
        if (len == 0 || len > MAXF) {
          bad = 1;
          break;
        }
        if (have - off < 4 + (size_t)len) break;
        if (write(tap, in + off + 4, len) < 0 && errno != EAGAIN) logf_("tap write: %s", strerror(errno));
        if (rx++ == 0 && quiet > 0) {
          logf_("link back after %d empty attempts", quiet);
          quiet = 0;
        }
        off += 4 + len;
      }
      if (bad) {
        logf_("bad frame length, reconnecting");
        close(sock);
        sock = -1;
        have = 0;
        next_try = time(NULL) + 1;
        continue;
      }
      if (off > 0) {
        memmove(in, in + off, have - off);
        have -= off;
      }
    }
  }
}
