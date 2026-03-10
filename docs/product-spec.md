# PrinterBridge

## Product Spec

### Document Status
- Status: Draft v1
- Minimum supported target: macOS 15+
- Primary verification targets: macOS 15.7.4 on Intel and macOS 26.x on Apple Silicon
- Supported architectures: Universal binary (`arm64` and `x86_64`)
- Compatibility posture: Support modern macOS first, but do not make the product Tahoe-only. The support floor starts at macOS 15. If the implementation naturally works on older releases without extra architectural complexity, that is acceptable, but not a v1 promise.
- Development topology: Primary development on an Apple Silicon Mac running macOS 26.x, with repeatable deployment and verification on a remote Intel Mac mini running macOS 15.7.4 over `ssh`/`scp`.
- Remote access assumption: The Intel verification machine is reachable through the existing SSH config alias `macmini`, for example `ssh macmini` and `scp <artifact> macmini:<path>`.
- Primary initial target printer: Brother HL-2170W series
- Longer-term target: Generic support for legacy non-AirPrint printers available to macOS through CUPS

## 1. Summary

Build a modern macOS Swift app that exposes one or more non-AirPrint printers to iPhone, iPad, and other Apple devices by advertising an AirPrint-compatible IPP service on the local network and routing jobs through the Mac's existing CUPS printer queues.

The initial product should solve one concrete problem reliably:
- A Brother HL-2170W series printer that is reachable from a Mac and printable via CUPS should appear to Apple clients as an AirPrint printer without relying on unsupported third-party software such as Printopia.

The product should be designed so that the Brother use case is the first-class MVP, while the architecture remains generic enough to support other printers later.

## 2. Problem Statement

Legacy printers often work on macOS through vendor drivers or CUPS queues but do not expose the Bonjour/AirPrint service profile Apple devices expect. Users are then forced to rely on unsupported utilities that:
- may stop working on future macOS releases
- are opaque and hard to verify
- are difficult to troubleshoot
- often include extra product surface unrelated to the core need

The gap is not basic printing on the Mac. The gap is discovery and compatibility for Apple devices on the network.

## 3. What We Believe Is Happening Today

Based on local investigation of the existing setup:
- The Brother printer is not natively AirPrint-capable.
- The printer is available to macOS through a normal CUPS queue.
- The existing legacy software exposes a separate AirPrint-facing IPP endpoint on the Mac.
- That endpoint appears to proxy or forward jobs into the local CUPS queue.
- The essential user-visible behavior is that Apple devices discover an `_ipp._tcp,_universal` service and can print to it successfully.

This means the replacement product does not need to reinvent print drivers. It needs to:
- discover usable CUPS queues
- determine whether they are suitable for AirPrint exposure
- advertise them with correct Bonjour TXT records
- accept AirPrint jobs and route them to the backing queue
- report status clearly enough to diagnose failures

## 4. Product Goals

### Primary Goals
- Replace Printopia for the target Brother printer.
- Be stable across modern macOS releases.
- Ship as a universal macOS app and helper for Intel and Apple Silicon Macs.
- Be inspectable and testable.
- Require minimal user intervention after setup.
- Support startup-before-login operation.

### Secondary Goals
- Support additional non-AirPrint printers backed by CUPS.
- Provide a clean Swift-native macOS experience.
- Provide enough diagnostics that a technical user can verify what the app is doing.
- Keep the bridge core structured so Linux host support remains a realistic future phase.

### Non-Goals
- Scanning support.
- Cloud printing.
- Windows support.
- Remote printing outside the local network.
- Complex enterprise access control in v1.
- Replacing vendor print drivers.

## 5. Users

### Primary User
- A technically comfortable Mac user with an older printer that works on macOS but does not show up on iPhone or iPad.

### Secondary User
- A household or small office user who wants a set-it-and-forget-it AirPrint bridge for one or more printers.

## 6. Product Principles

- Do the minimum needed for reliable AirPrint bridging.
- Prefer real printer and queue capabilities over guessed capabilities.
- Expose internals when useful: queue URI, advertised service name, TXT records, last registration time, helper status.
- Separate UI concerns from privileged/background behavior.
- Make the Brother path excellent before optimizing for every printer.

## 7. High-Level Solution

The product will consist of two cooperating components:

### 7.1 Foreground App
- SwiftUI macOS app
- setup flow
- printer selection and exposure toggles
- status dashboard
- logs and diagnostics view
- test and verification tooling

### 7.1.1 Development Diagnostics CLI
- Separate macOS command-line target for development, SSH validation, and automation.
- Not part of the default end-user release artifact.
- Can be deployed independently to the Mac mini for repeated validation runs.
- Should expose queue inspection, Bonjour discovery inspection, and bridge health checks without requiring the GUI to launch.

### 7.2 Background Service
- `SMAppService`-managed daemon/helper with XPC interface
- runs without user login
- monitors configured printers
- advertises AirPrint-compatible Bonjour services
- hosts or bridges IPP endpoints for Apple clients
- forwards jobs into local CUPS queues

### 7.3 Development and Deployment Topology
- Primary implementation work happens on the MacBook Pro development machine.
- The MacBook Pro is expected to be faster and run the newest local toolchain and SDKs.
- The Mac mini acts as the primary real-world verification host because it is:
  - Intel-based
  - on macOS 15.7.4
  - connected to the target Brother printer environment
- The normal loop should support:
  - local build on the MacBook Pro
  - remote deploy to the Mac mini over `scp`, using the configured alias `macmini`
  - remote install, launch, and log capture over `ssh`, using `ssh macmini`
  - repeated verification without requiring full manual setup on the Mac mini each time

## 8. Proposed Architecture

### 8.1 App Layer
- SwiftUI for UI
- `SMAppService`-managed helper installation and lifecycle
- XPC client for talking to the helper
- persistent configuration in app group container or a root-owned config location depending on helper model

### 8.2 Helper Layer
- Swift daemon/helper managed through `SMAppService` and launchd
- privileged operations isolated here
- responsibilities:
  - inspect CUPS queues
  - evaluate queue suitability
  - publish/unpublish AirPrint services
  - host AirPrint-facing IPP endpoint or manage registration against an existing IPP endpoint
  - submit and monitor jobs through CUPS APIs or shell-compatible system interfaces

### 8.3 System Integrations
- CUPS / IPP
  - enumerate printers
  - read printer attributes
  - submit jobs
  - observe printer state
- Bonjour / DNS-SD
  - advertise `_ipp._tcp,_universal`
  - maintain TXT records
  - handle hostname and interface changes
- Security / Service Management
  - install helper
  - manage privileges cleanly

### 8.3.1 Portability Boundary
- Keep printer inspection, capability mapping, and bridge-state modeling in shared Swift code.
- Keep macOS-specific service installation, Bonjour publishing details, and UI code behind platform boundaries.
- This preserves a credible path to Linux host support later using CUPS plus Avahi, while keeping v1 squarely focused on macOS.

### 8.4 Distribution and Entitlements
- Direct distribution outside the Mac App Store is the default assumption for v1.
- App and helper should be Developer ID signed, notarized, and built as universal binaries.
- Sandboxing should not be assumed as a requirement for v1.
- Entitlements and helper-install behavior must be planned in Phase 0, not deferred until late UX polish.

### 8.5 Development Workflow Requirements
- The project should support building universal binaries from the Apple Silicon development machine.
- The project should support remote deployment of the app bundle and helper-related assets to the Mac mini.
- The project should support scripted remote actions over `ssh`, including:
  - copying artifacts
  - replacing previous test builds
  - launching or registering the helper
  - collecting logs and diagnostic output
- The default remote target notation in internal docs and scripts should use the `macmini` SSH alias rather than hardcoded hostnames.
- The project should treat the Mac mini as a first-class target for iterative verification, not only as a late-stage QA machine.

## 9. Core Technical Decision

There are two viable implementation paths:

### Option A: Advertise Existing CUPS Queue Directly
- Use macOS CUPS as the actual IPP endpoint.
- Advertise the CUPS queue as an AirPrint service with correct TXT records.
- Lowest complexity.
- Requires deliberate handling of CUPS LAN exposure, firewall behavior, and possible Bonjour auto-advertisement conflicts.

### Option B: Run a Dedicated Bridging IPP Server
- Expose a separate local IPP endpoint from the helper.
- Accept AirPrint jobs there.
- Normalize formats and forward jobs to CUPS.
- Higher complexity, but more control and closer to what Printopia appears to do.

### Recommendation
- Phase 1 should attempt Option A first for the Brother HL-2170W.
- If verification shows Apple clients print reliably via direct CUPS exposure, keep this as the default architecture.
- If Apple clients require behavior that CUPS exposure cannot satisfy consistently, Phase 2 should adopt Option B for bridging.

This keeps the MVP small while preserving a clear escalation path.

## 10. Scope by Phase

## Phase 0: Technical Validation

### Goal
Confirm the minimal bridge architecture that works for the Brother printer and define the exact requirements for the product.

### Deliverables
- reproducible notes on the Brother queue and capabilities
- verified list of required Bonjour TXT records
- validated CUPS filter chain for the Brother path, including PDF/URF/PWG input to backing queue behavior
- captured working `device-uri` and `printer-uri-supported` patterns for supported queues
- recorded behavior for existing CUPS or system auto-advertisement to avoid duplicate announcements
- recorded multi-interface behavior for Wi-Fi and Ethernet hosts
- documented local-build and remote-deploy workflow for the MacBook Pro to Mac mini loop
- decision memo: direct CUPS exposure vs dedicated proxy endpoint
- repeatable local verification checklist
- development CLI commands that can capture the required local and remote diagnostics over `ssh`

### Acceptance Criteria
- We can prove, on the target Mac, which AirPrint advertisement shape Apple clients accept.
- We can document the exact queue attributes and formats used by the Brother path.
- We can show whether direct CUPS exposure creates security, firewall, or duplicate-advertisement issues.
- We can verify successful print discovery and at least one successful print job from an Apple client.

## Phase 1: Brother-First MVP

### Goal
Ship a minimal working macOS app that exposes one selected printer, optimized first for the Brother HL-2170W series.

### User Experience
- Install app.
- Grant/setup required helper permissions.
- App shows available local CUPS printers.
- User selects `Brother_HL_2170W_series`.
- User clicks `Enable AirPrint`.
- App shows:
  - service status
  - advertised name
  - endpoint details
  - last successful registration
  - current printer state

### Functional Requirements
- detect installed printers from CUPS
- support one enabled printer at a time
- advertise a single AirPrint service
- persist configuration across reboot
- start service before login
- basic diagnostics page
- ship signed and notarized universal builds for direct installation
- support repeatable development deployment from the MacBook Pro to the Mac mini without requiring manual file copying steps
- support a development-only CLI for scripted validation and regression checks

### Non-Functional Requirements
- bridge survives reboot
- bridge re-registers after network changes
- bridge recovers if printer is turned off and back on
- no manual terminal usage required after setup

### Acceptance Criteria
- Brother printer appears from iPhone/iPad print sheet within 10 seconds on the same network.
- A standard PDF job prints successfully.
- App correctly reports success/failure states.
- Reboot does not require reconfiguration.
- The app and helper build and run on both `arm64` and `x86_64` Macs on target modern macOS versions.

## Phase 2: Generic Multi-Printer Support

### Goal
Expand the product from Brother-specific MVP to a generic AirPrint bridge for multiple legacy printers.

### Additions
- support multiple exposed printers
- printer compatibility evaluation
- per-printer naming
- per-printer enable/disable
- capability normalization
- handling for vendor-driver queues and generic queues

### Compatibility Model
Each queue gets a status:
- Supported
- Likely Supported
- Unsupported
- Needs Advanced Mode

### Acceptance Criteria
- At least three queue types can be evaluated correctly:
  - vendor-driver queue
  - generic PCL/PS queue
  - IPP Everywhere / driverless queue
- Multiple printers can be advertised without collisions.
- App surfaces when a queue is unsuitable and why.

## Phase 3: Product Hardening and UX

### Goal
Make the product dependable enough for regular use by non-technical users.

### Additions
- onboarding wizard
- richer error messages
- built-in verification actions
- exportable diagnostics bundle
- activity log
- update mechanism

### Acceptance Criteria
- First-run setup can be completed without Terminal.
- Common failure states are understandable:
  - helper not installed
  - firewall/network blocking
  - queue missing
  - printer offline
  - Bonjour registration failed
- Logs are sufficient for remote debugging.

## Phase 5: Cross-Platform Host Exploration

### Goal
Evaluate whether the same bridge model can be extended beyond macOS without compromising the macOS-first product.

### Linux Track
- Reuse shared bridge/core logic where practical.
- Replace Bonjour publishing with Avahi integration as needed.
- Replace launchd/`SMAppService` service management with systemd packaging.

### Windows Track
- Investigate feasibility only after macOS is stable.
- Expect a different service-install and print-backend model than CUPS-based hosts.

### Acceptance Criteria
- We can identify which subsystems are already portable and which remain macOS-specific.
- We can document a credible Linux host path without blocking macOS delivery.

## Phase 4: Advanced Bridging

### Goal
Add deeper compatibility features if required by real-world printers.

### Possible Additions
- dedicated proxy IPP server
- format conversion pipeline when needed
- richer media mapping
- access control
- print job history
- analytics-free telemetry for local diagnostics only

### Acceptance Criteria
- Printers that fail with direct CUPS exposure can still be supported through proxy mode.
- The app can choose the correct mode automatically or recommend one.

## 11. Functional Requirements

### Printer Discovery
- enumerate CUPS printers
- show queue name, display name, device URI, make/model, sharing state
- detect whether queue appears already AirPrint-capable

### Capability Inspection
- inspect IPP printer attributes
- prefer real IPP attributes over PPD parsing when possible
- derive AirPrint-advertisable properties from queue capabilities

### Service Advertisement
- register and unregister Bonjour services
- maintain correct TXT records for AirPrint visibility
- avoid duplicate or conflicting advertisements

### Bridging
- expose a usable IPP endpoint for Apple clients
- route jobs to the backing CUPS queue
- preserve printer state reporting where feasible

### State and Diagnostics
- show helper installation state
- show current published services
- show queue health
- show recent job attempts and last error

## 12. Non-Functional Requirements

### Platform Compatibility
- Build and ship as a universal binary for `arm64` and `x86_64`.
- Set the formal support floor at macOS 15+.
- Validate specifically on macOS 15.7.4 Intel hosts and current macOS 26.x Apple Silicon hosts.
- Avoid product decisions that depend on macOS 26-only APIs when an equivalent macOS 15-compatible path exists.
- Allow opportunistic compatibility with older macOS releases where practical, but do not make broad backward-compatibility commitments in v1.

### Reliability
- automatically recover from:
  - network interface changes
  - daemon restart
  - printer temporary unavailability

### Security
- minimize privileged surface area
- isolate privileged actions to helper only
- avoid unnecessary remote admin exposure for CUPS
- if Option A is used, expose only the minimum LAN-reachable IPP behavior required for local AirPrint clients
- no cloud dependency

### Performance
- near-zero idle CPU usage
- low memory footprint
- no polling-heavy architecture when event-driven alternatives exist

### Transparency
- visible diagnostics for all important decisions
- easy to inspect generated configuration and advertised records

## 13. Risks

### CUPS Behavior Differences Across macOS Versions
Mitigation:
- test on current supported macOS releases
- avoid brittle config file mutation where possible

### CUPS LAN Exposure and Firewall Friction
Mitigation:
- make firewall and network exposure part of setup flow and diagnostics
- prefer helper-controlled exposure over broad system-wide changes where possible

### Duplicate or Conflicting Bonjour Advertisement
Mitigation:
- detect existing CUPS or system advertisements before publishing our own
- make duplicate advertisement state visible in diagnostics

### Multi-Interface Network Advertising
Mitigation:
- test on Wi-Fi-only, Ethernet-only, and dual-interface Macs
- make selected/active advertisement interfaces visible in diagnostics

### Bonjour / TXT Record Fragility
Mitigation:
- create protocol-level integration tests
- maintain a known-good attribute set for the Brother printer

### Vendor Driver Variability
Mitigation:
- treat Brother as golden path
- add generic compatibility layer only after MVP is stable

### Privileged Helper Complexity
Mitigation:
- keep helper narrow
- keep business logic mostly shared and testable outside privilege boundary

## 14. Open Technical Questions

- Can the Brother path be shipped reliably using direct CUPS exposure alone?
- Which exact TXT records are truly required for the Brother queue to appear consistently across iOS and iPadOS versions?
- Do we need a dedicated proxy endpoint for any Apple client or only for problematic printers?
- What exact helper-install and entitlement constraints apply on macOS 26 for the chosen distribution model?

## 15. Testing and Verification Strategy

## 15.1 Unit Tests
- queue model parsing
- capability mapping
- TXT record generation
- configuration persistence
- helper/app XPC contracts

## 15.2 Integration Tests
- enumerate real and mocked CUPS printers
- register/unregister Bonjour service
- verify service visibility on local network
- submit print job to a test queue
- validate behavior with existing CUPS advertisements present and absent

## 15.3 End-to-End Tests
- install helper
- expose Brother printer
- verify discovery from Apple client
- send test PDF
- confirm job enters CUPS queue and completes
- repeat on both `arm64` and `x86_64` host Macs
- validate the standard developer loop of local build on the MacBook Pro followed by remote deployment and verification on the Mac mini

## 15.4 Manual Verification Matrix
- Apple Silicon Mac host
- Intel Mac host
- build on Apple Silicon, deploy to Intel over `ssh`/`scp`
- macOS reboot
- user logged out
- printer power cycled
- Wi‑Fi changed
- Ethernet changed
- Wi‑Fi and Ethernet both active
- multiple Apple clients discovering printer simultaneously
- printer removed and re-added

## 15.5 Observability
- structured app logs
- structured helper logs
- visible last-known queue attributes
- visible Bonjour registration details

## 16. Suggested Milestones

### Milestone A
- complete Phase 0
- choose architecture path

### Milestone B
- Phase 1 app with one-printer MVP for Brother

### Milestone C
- harden install and reboot behavior
- complete end-to-end verification

### Milestone D
- generic multi-printer support

## 17. Initial Success Metrics

- Brother HL-2170W appears in Apple print sheet on first setup without Terminal.
- At least 95% successful discovery rate after reboot in test environment.
- At least 95% successful print completion rate for standard PDF test jobs in MVP test runs.
- Setup time under 5 minutes for a technical user.

## 18. Recommended Next Step

After this spec, the next step should be a short technical design document for Phase 0 and Phase 1 only. That document should answer:
- which endpoint model we are implementing first
- what helper architecture we are using
- what exact verification harness will prove the Brother path works
- what the standard remote deployment workflow is from the MacBook Pro to the Mac mini
