# VAAYU MATLAB Agent for Aircraft Fleet Health Monitoring

VAAYU, the Voice-assisted Agent for Aircraft Yield & Uptime, is an end-to-end MATLAB demo for aircraft fleet health monitoring. It shows how a voice agent can sit on top of trusted engineering analytics: listening to an operator, routing questions through a local LLM, calling deterministic fleet tools, and speaking answers that match the live dashboard state.

The demo is built around a fleet of aircraft engines with lifecycle data, diagnostic failure classes, health indicators, remaining useful life estimates, operating states, and dashboard-visible risk buckets. The goal is not just to make an assistant talk about fleet health; the goal is to keep the assistant, dashboard, trained models, and hosted inference service aligned to the same operational truth.

## What The Demo Shows

VAAYU combines four experiences into one MATLAB workflow:

- A reactive MATLAB neural interface for typed and spoken interaction.
- A Fleet Analytics dashboard that streams engine observations, tracks operating state, and prioritizes risk.
- Trained diagnostics and prognostics models that return fault class, confidence, RUL, and health indicator.
- A MATLAB Production Server backend path for serving the inference function behind the dashboard and agent.

In a typical demo, the operator can ask VAAYU for fleet status, top-risk engines, degrading assets, maintenance or airborne counts, and single-engine reports. Fleet-wide answers keep the neural interface in focus. Engine-specific answers can open a turbofan diagnostic view so the spoken explanation, selected asset, failure class, RUL, health indicator, and visual context stay together.

## Why It Is Trustworthy

The FleetAnalytics data and model artifacts are the source of truth. Dashboard summaries and VAAYU responses are downstream views of that state, not separate calculations.

The workflow preserves a few important boundaries:

- RUL is a prognostic model output, not a scaled health indicator.
- Health indicators stay on the `0..1` scale.
- Healthy, degrading, critical, early-failure, and maintenance buckets are mutually exclusive dashboard categories.
- The voice agent reads the dashboard snapshot and model-backed tool results before forming operational answers.
- Local inference and hosted inference can be compared for class, confidence, RUL, and health-indicator parity.

The validation target is that VAAYU answers, dashboard KPIs, synchronized dashboard state, local inference, and hosted inference agree within documented tolerances.

## Analytics Workflow

The demo follows a deterministic fleet-health pipeline:

1. Curate fleet lifecycle data from normalized engine cycles.
2. Train diagnostic models for healthy and failure-mode classification.
3. Design mode-specific health indicators from high-dimensional sensor behavior.
4. Estimate RUL using degradation-based prognostic models.
5. Serve analytical outputs through the `monitorEngineFleet` production function.
6. Synchronize the rendered dashboard state for VAAYU tool responses.

The production inference contract is fixed:

- Input: `Nx362` numeric payload.
- Output 1: `faultClass`
- Output 2: `confidenceScores`
- Output 3: `rulEstimates`
- Output 4: `healthIndicators`

## Operator Experience

The dashboard gives a risk-first fleet view: health buckets, maintenance count, operating state, route context, ranked risk candidates, and selected-engine detail. The selected-engine view keeps class, confidence, RUL, HI, cycle context, and trend history together.

VAAYU uses a local LLM router to decide whether a user request is general chat or a fleet tool call. Fleet tool calls are executed deterministically against approved MATLAB functions. Final spoken summaries are grounded in those tool results so the operator hears the same numbers shown by the dashboard.

## Prerequisites

- MATLAB with the products required by the project and FleetAnalytics workflows.
- **Large Language Models (LLMs) with MATLAB** add-on installed.
- **Audio Toolbox Interface for SpeechBrain and Torchaudio Libraries** add-on installed.
- Docker Desktop for Windows. Request the required license before using local microservice image hosting.
- Ollama and a local LLM, such as Gemma, for offline LLM workflow demos to customers. Request legal approval before using this mode in customer-facing demos.
- Access to the central MATLAB Production Server endpoint used by the dashboard and deployment configuration.

## Important Files

- `VAAYU_MATLAB_Agent.prj`: MATLAB project entry point.
- `VaayuBrain.m`: VAAYU neural interface, speech workflow, LLM routing, tool execution, and response path.
- `FleetAnalytics/EngineFleetDashboard.m`: streaming fleet dashboard and dashboard snapshot publisher.
- `FleetAnalytics/monitorEngineFleet.m`: production inference entry point with the four-output contract.
- `FleetAnalytics/queryFleetHealth.m`: deterministic VAAYU query layer over the latest dashboard snapshot.
- `FleetAnalytics/deploymentWorkflow.mlx`: deployment workflow for Docker and MATLAB Production Server artifacts.
- `FleetAnalytics/verifyVaayuDeterminism.m`: dashboard/VAAYU and local/hosted parity check.
- `TurbofanDiagnosticsWindow.m`: MATLAB-launched turbofan diagnostic view for selected engine contexts.

## Running The Demo

Open `VAAYU_MATLAB_Agent.prj` in MATLAB, then run:

```matlab
VaayuBrain
```

To launch the dashboard directly:

```matlab
cd FleetAnalytics
EngineFleetDashboard
```

To run the deterministic verification:

```matlab
cd FleetAnalytics
verifyVaayuDeterminism
```

Generated Docker and MATLAB Production Server package folders are intentionally not committed. They are recreated from `FleetAnalytics/deploymentWorkflow.mlx` when needed.

## Repository Notes

This repository intentionally excludes local API keys, audit logs, runtime snapshots, generated Docker/MPS package folders, local Whisper model folders, presentation source folders, and local-only development notes.
