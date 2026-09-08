{{/*
Name helpers — standard `helm create` scaffold, matching kupo/ogmios/
ft-aquarium-node in this repo. cardano-node/amaru are hand-rolled; do not
normalise one style into the other.
*/}}
{{- define "heimdall.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "heimdall.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "heimdall.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
⛔ THE IMAGE TAG IS REQUIRED AND HAS NO DEFAULT — the roster decides it, not
this chart. See Chart.yaml for why there is no appVersion to fall back on.
*/}}
{{- define "heimdall.imageTag" -}}
{{- required "heimdall: image.tag is REQUIRED and has no default. Run the build THE ROSTER runs — every peer's /health must report the same `version` and `blueprint_digest`, and a mismatched node is dropped from the ceremony. Ask the roster which build is current; do not take the newest release." .Values.image.tag -}}
{{- end }}

{{- define "heimdall.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "heimdall.imageTag" .) -}}
{{- end }}

{{/*
The port the daemon BINDS. Distinct from the port inside the advertised URL —
see heimdall.advertisedUrl below, which enforces the one case where they must
agree.
*/}}
{{- define "heimdall.listenPort" -}}
{{- required "heimdall: `listenPort` is REQUIRED and has no default. It is the port the daemon binds inside the container. Note it is NOT necessarily the port peers dial: with TLS terminated in front, `advertisedUrl` carries no port at all." .Values.listenPort -}}
{{- end }}

{{/*
The URL peers dial, registered ON CHAIN.

⛔ THE INVARIANT: if this URL carries an EXPLICIT PORT there is no proxy in
front, so that port must be the one the daemon binds. A mismatch registers an
address nobody answers on — and because the URL is on chain, discovering it
later costs a chain write, not a values edit. A URL with no port is the
terminate-TLS-in-front shape and is left alone.
*/}}
{{- define "heimdall.advertisedUrl" -}}
{{- $url := required "heimdall: `advertisedUrl` is REQUIRED and has no default. It is what peers dial and it is written ON CHAIN at registration, so changing it later is a chain write. Both `https://host` (TLS terminated in front) and `http://host:PORT` (no proxy) are documented shapes." .Values.advertisedUrl -}}
{{- $hostport := $url | replace "https://" "" | replace "http://" "" | trimSuffix "/" -}}
{{- $hostport = (splitList "/" $hostport) | first -}}
{{- if contains ":" $hostport -}}
{{- $urlPort := (splitList ":" $hostport) | last -}}
{{- $listen := printf "%v" (include "heimdall.listenPort" $) -}}
{{- if ne $urlPort $listen -}}
{{- fail (printf "heimdall: advertisedUrl names port %s but listenPort is %s. A URL carrying an explicit port means NO PROXY IN FRONT, so peers dial that port directly and the daemon must bind it. Registering a port nothing listens on costs a CHAIN WRITE to correct, not a values edit. Either make them equal, or drop the port from advertisedUrl if TLS is terminated in front." $urlPort $listen) -}}
{{- end -}}
{{- end -}}
{{- $url -}}
{{- end }}

{{/*
`app.kubernetes.io/version` is labelled from the IMAGE TAG, not from
.Chart.AppVersion, because this chart deliberately has no appVersion. The label
therefore states what is actually running rather than what the chart was
packaged alongside.
*/}}
{{- define "heimdall.labels" -}}
helm.sh/chart: {{ include "heimdall.chart" . }}
{{ include "heimdall.selectorLabels" . }}
app.kubernetes.io/version: {{ include "heimdall.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "heimdall.selectorLabels" -}}
app.kubernetes.io/name: {{ include "heimdall.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
The claim the pod mounts: an adopted existing one, or the one this chart creates.
*/}}
{{- define "heimdall.claimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-state" (include "heimdall.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
⛔ INTEGER-SAFE RENDERING. Do not emit a number into the TOML without this.

Helm parses numbers from a VALUES FILE as float64, so `min_stake_lovelace:
1000000000` renders as `1e+09` — which TOML reads as a FLOAT, not the integer
count of lovelace the daemon expects. `--set` yields an int64 and renders fine,
so the two paths DISAGREE and the values-file path is the broken one.

Caught live while writing this chart, by reading the rendered TOML rather than
the exit code: the render succeeded and the file was wrong. The same trap
shipped in ft-aquarium-node 0.1.0-0.2.0 for the same reason.
*/}}
{{- define "heimdall.num" -}}
{{- $v := . -}}
{{- if kindIs "float64" $v -}}
{{- if eq $v (floor $v) -}}{{- printf "%.0f" $v -}}{{- else -}}{{- printf "%v" $v -}}{{- end -}}
{{- else -}}
{{- printf "%v" $v -}}
{{- end -}}
{{- end }}
