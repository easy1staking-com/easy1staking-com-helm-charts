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
⛔ REQUIRED, and the reason is the failure mode, not tidiness: heimdall refuses
to start without a network, and an UNRESOLVABLE one is TREATED AS MAINNET.
*/}}
{{- define "heimdall.port" -}}
{{- required "heimdall: `port` is REQUIRED and has no default. This node's URL is registered ON CHAIN and the port inside that URL is the port the daemon binds, so changing it later is a chain write. Choose it together with the URL." .Values.port -}}
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
