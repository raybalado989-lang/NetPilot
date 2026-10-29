# ByeDPI Windows Loopback Runtime Lab R32

Status: **LAB_ONLY / PRODUCTION BLOCK / NO WIN DIVERT / NO SYSTEM PROXY CHANGE**

## Goal

R32 is the first controlled execution of the reviewed ByeDPI v0.17.3 candidate on Windows. It does **not** admit ByeDPI for production and does not integrate it into `NetPilot.Service`.

The lab proves only the narrow boundary required before adapter work:

- exact reviewed source and patchset build;
- exact Windows candidate binary identity;
- loopback-only listener;
- local SOCKS5 method negotiation;
- no non-loopback established TCP connection;
- deterministic forced-stop cleanup;
- restart on the same port;
- final no-process/no-listener cleanup.

## Exact candidate

- Upstream: `hufrea/byedpi`
- Release: `v0.17.3`
- Commit: `7efde1b1296eaaa187b70e951894dde17527489c`
- Tree: `8d13f6f5939190cd27ee68696247073a00b3e7dc`
- NetPilot reviewed patches: `0001` through `0007`
- Expected deterministic Windows SHA-256:
  `866e99c3c7690326cc6e365fe02980f06ae2b394c045555674fb95db52b0dbdd`

If the rebuilt binary hash differs, execution is blocked.

## Runtime boundary

The candidate is launched as a normal process on a GitHub-hosted Windows runner with a fixed internal argument model equivalent to:

```text
-i 127.0.0.1 -p <ephemeral-loopback-port> -N -U -c 8 -x 0
```

The lab does not accept user-provided arguments, paths, raw data, bind addresses, configuration files, URLs, or scripts.

The selected port is an unused local ephemeral TCP port chosen by the harness immediately before launch.

## What is prohibited

R32 must fail if any of the following is required or observed:

- elevation/admin token;
- Windows service installation;
- WinDivert or any driver installation/load;
- firewall mutation;
- registry mutation;
- system proxy mutation;
- persistence/autostart;
- wildcard listener;
- LAN listener;
- established non-loopback candidate connection;
- residual candidate process or listener after cleanup.

## Local protocol check

The harness connects only to `127.0.0.1:<lab-port>` and sends the minimal SOCKS5 method-negotiation greeting:

```text
05 01 00
```

Expected response:

```text
05 00
```

No SOCKS CONNECT request is sent. Therefore this gate does not request any destination outside the runner.

## Lifecycle check

1. Start the exact candidate.
2. Confirm listener ownership and `127.0.0.1` binding.
3. Complete local SOCKS5 greeting.
4. Confirm the candidate has no established non-loopback TCP connection.
5. Terminate the process.
6. Confirm its listener disappears.
7. Restart the exact same binary on the exact same port.
8. Repeat listener and SOCKS5 checks.
9. Terminate again.
10. Confirm final no-listener/no-process cleanup.

This is intentionally a forced-termination cleanup test. Graceful service-owned lifecycle is a later gate after the typed NetPilot adapter exists.

## Artifact handling

The Windows executable is a temporary inter-job transfer artifact with minimum retention and is not a release artifact.

The retained R32 evidence artifact contains only text evidence/logs. A PASS does not authorize downloading or deploying the temporary candidate as a NetPilot engine.

## PASS effect

A successful R32 run means only:

```text
BYEDPI_WINDOWS_LOOPBACK_RUNTIME = PASS
PRODUCTION_ADMISSION = BLOCK
PRODUCTION_INTEGRATION = BLOCK
TRANSPARENT_ROUTING = NOT_TESTED
REAL_EXTERNAL_SERVICE_TEST = NOT_PERFORMED
```

After PASS the next work item is a typed service-owned ByeDPI adapter with bounded lifecycle/resource policy, followed by a local synthetic HTTP/SOCKS functional lab.
